const std = @import("std");
const builtin = @import("builtin");
const scanner = @import("scanner.zig");
const config = @import("config.zig");
const platform = @import("platform.zig");

/// Category of file for cleanup purposes
pub const FileCategory = enum {
    /// Temporary files (.tmp, .temp, .bak, etc.)
    temporary,
    /// Cache files and directories
    cache,
    /// Log files
    log,
    /// Duplicate file (has identical content to another file)
    duplicate,
    /// Large file (above size threshold)
    large,
    /// Unused file (not accessed for a long time)
    unused,
    /// Old download (in downloads folder, old)
    old_download,
    /// Development artifact (node_modules, build dirs, etc.)
    dev_artifact,
    /// Browser cache/data
    browser_data,
    /// Normal file (doesn't match cleanup criteria)
    normal,

    pub fn getName(self: FileCategory) []const u8 {
        return switch (self) {
            .temporary => "Temporary",
            .cache => "Cache",
            .log => "Log",
            .duplicate => "Duplicate",
            .large => "Large",
            .unused => "Unused",
            .old_download => "Old Download",
            .dev_artifact => "Dev Artifact",
            .browser_data => "Browser Data",
            .normal => "Normal",
        };
    }

    pub fn getDescription(self: FileCategory) []const u8 {
        return switch (self) {
            .temporary => "Temporary files that can be safely deleted",
            .cache => "Cached data that can be regenerated",
            .log => "Log files that accumulate over time",
            .duplicate => "Files with identical content",
            .large => "Files exceeding size threshold",
            .unused => "Files not accessed recently",
            .old_download => "Downloads that haven't been used",
            .dev_artifact => "Build outputs and dependencies",
            .browser_data => "Browser cache and temporary data",
            .normal => "Regular files",
        };
    }
};

/// Result of analyzing a single file
pub const AnalysisResult = struct {
    /// The file info from scanner
    file: scanner.FileInfo,
    /// Primary category
    category: FileCategory,
    /// Additional categories that apply (max 8)
    additional_categories: [8]?FileCategory,
    additional_categories_count: u8,
    /// Confidence score 0.0-1.0 for cleanup recommendation
    confidence: f32,
    /// If duplicate, path to original file
    duplicate_of: ?[]const u8,
    /// Hash of file content (for duplicate detection)
    content_hash: ?u64,
    /// Whether this file is safe to delete
    safe_to_delete: bool,
    /// Reason for categorization
    reason: []const u8,

    pub fn init(file: scanner.FileInfo, category: FileCategory) AnalysisResult {
        return AnalysisResult{
            .file = file,
            .category = category,
            .additional_categories = [_]?FileCategory{null} ** 8,
            .additional_categories_count = 0,
            .confidence = 0.5,
            .duplicate_of = null,
            .content_hash = null,
            .safe_to_delete = false,
            .reason = "",
        };
    }

    /// Add an additional category
    pub fn addCategory(self: *AnalysisResult, cat: FileCategory) void {
        if (self.additional_categories_count < 8) {
            self.additional_categories[self.additional_categories_count] = cat;
            self.additional_categories_count += 1;
        }
    }

    /// Check if file has a specific category
    pub fn hasCategory(self: AnalysisResult, cat: FileCategory) bool {
        if (self.category == cat) return true;
        var i: u8 = 0;
        while (i < self.additional_categories_count) : (i += 1) {
            if (self.additional_categories[i]) |c| {
                if (c == cat) return true;
            }
        }
        return false;
    }
};

/// Statistics from analysis
pub const AnalysisStats = struct {
    total_analyzed: u64 = 0,
    by_category: [@typeInfo(FileCategory).@"enum".fields.len]CategoryStats = [_]CategoryStats{.{}} ** @typeInfo(FileCategory).@"enum".fields.len,

    pub const CategoryStats = struct {
        count: u64 = 0,
        total_size: u64 = 0,
    };

    pub fn recordFile(self: *AnalysisStats, result: *const AnalysisResult) void {
        self.total_analyzed += 1;
        const idx = @intFromEnum(result.category);
        self.by_category[idx].count += 1;
        self.by_category[idx].total_size += result.file.size;
    }

    pub fn getCategoryStats(self: AnalysisStats, category: FileCategory) CategoryStats {
        return self.by_category[@intFromEnum(category)];
    }

    pub fn format(self: AnalysisStats, allocator: std.mem.Allocator) ![]u8 {
        var output: std.ArrayListUnmanaged(u8) = .{};
        defer output.deinit(allocator);
        const writer = output.writer(allocator);

        try writer.print("Analysis Results:\n", .{});
        try writer.print("  Total files analyzed: {d}\n\n", .{self.total_analyzed});
        try writer.print("  By Category:\n", .{});

        inline for (@typeInfo(FileCategory).@"enum".fields, 0..) |field, i| {
            const stats = self.by_category[i];
            if (stats.count > 0) {
                const size_str = try platform.formatSize(allocator, stats.total_size);
                defer allocator.free(size_str);
                const cat: FileCategory = @enumFromInt(i);
                try writer.print("    {s}: {d} files ({s})\n", .{ cat.getName(), stats.count, size_str });
            }
            _ = field;
        }

        return output.toOwnedSlice(allocator);
    }
};

/// Configuration for file analysis
pub const AnalyzerConfig = struct {
    /// Size threshold for "large" files (default 100MB)
    large_file_threshold: u64 = 100 * 1024 * 1024,
    /// Days since last access to consider "unused" (default 90 days)
    unused_days_threshold: u32 = 90,
    /// Days since last access for old downloads (default 30 days)
    old_download_days: u32 = 30,
    /// Enable duplicate detection (requires reading file content)
    detect_duplicates: bool = true,
    /// Maximum file size to hash for duplicate detection (default 1GB)
    max_hash_size: u64 = 1024 * 1024 * 1024,
    /// Categories to detect
    categories: config.ScanCategories = .{},
};

/// File analyzer for identifying cleanup candidates
pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    config: AnalyzerConfig,
    stats: AnalysisStats,
    results: std.ArrayListUnmanaged(AnalysisResult),

    /// Hash map for duplicate detection: hash -> first file path
    hash_to_path: std.AutoHashMapUnmanaged(u64, []const u8),
    /// Hash map for size-based pre-filtering: size -> list of files
    size_to_files: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged([]const u8)),

    pub fn init(allocator: std.mem.Allocator, cfg: AnalyzerConfig) Analyzer {
        return Analyzer{
            .allocator = allocator,
            .config = cfg,
            .stats = .{},
            .results = .{},
            .hash_to_path = .{},
            .size_to_files = .{},
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.results.deinit(self.allocator);

        // Clean up hash_to_path
        var hash_iter = self.hash_to_path.iterator();
        while (hash_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.hash_to_path.deinit(self.allocator);

        // Clean up size_to_files
        var size_iter = self.size_to_files.iterator();
        while (size_iter.next()) |entry| {
            for (entry.value_ptr.items) |path| {
                self.allocator.free(path);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.size_to_files.deinit(self.allocator);
    }

    /// Analyze a batch of files from scanner results
    pub fn analyzeFiles(self: *Analyzer, files: []const scanner.FileInfo) !void {
        for (files) |file| {
            const result = try self.analyzeFile(file);
            try self.results.append(self.allocator, result);
            self.stats.recordFile(&result);
        }
    }

    /// Analyze a single file
    pub fn analyzeFile(self: *Analyzer, file: scanner.FileInfo) !AnalysisResult {
        var result = AnalysisResult.init(file, .normal);

        // Skip directories
        if (file.is_dir) {
            return result;
        }

        // Check categories in order of priority

        // 1. Check if temporary file
        if (self.config.categories.temp_files and self.isTemporaryFile(file)) {
            result.category = .temporary;
            result.confidence = 0.9;
            result.safe_to_delete = true;
            result.reason = "Matches temporary file pattern";
        }

        // 2. Check if cache file
        if (self.config.categories.cache_files and self.isCacheFile(file)) {
            if (result.category == .normal) {
                result.category = .cache;
                result.confidence = 0.85;
                result.safe_to_delete = true;
                result.reason = "Located in cache directory";
            } else {
                result.addCategory(.cache);
            }
        }

        // 3. Check if log file
        if (self.config.categories.log_files and self.isLogFile(file)) {
            if (result.category == .normal) {
                result.category = .log;
                result.confidence = 0.7;
                result.safe_to_delete = true;
                result.reason = "Log file";
            } else {
                result.addCategory(.log);
            }
        }

        // 4. Check if large file
        if (self.config.categories.large_files and file.size >= self.config.large_file_threshold) {
            if (result.category == .normal) {
                result.category = .large;
                result.confidence = 0.5;
                result.safe_to_delete = false;
                result.reason = "File size exceeds threshold";
            } else {
                result.addCategory(.large);
            }
        }

        // 5. Check if unused file
        if (self.config.categories.old_downloads) {
            const age_days = file.getAgeDays();
            if (age_days >= self.config.unused_days_threshold) {
                if (result.category == .normal) {
                    result.category = .unused;
                    result.confidence = 0.6;
                    result.safe_to_delete = false;
                    result.reason = "Not accessed recently";
                } else {
                    result.addCategory(.unused);
                    result.confidence = @min(result.confidence + 0.1, 1.0);
                }
            }
        }

        // 6. Check for old downloads
        if (self.config.categories.old_downloads and self.isOldDownload(file)) {
            if (result.category == .normal) {
                result.category = .old_download;
                result.confidence = 0.65;
                result.safe_to_delete = false;
                result.reason = "Old file in downloads folder";
            } else {
                result.addCategory(.old_download);
            }
        }

        // 7. Check for dev artifacts
        if (self.config.categories.dev_artifacts and self.isDevArtifact(file)) {
            if (result.category == .normal) {
                result.category = .dev_artifact;
                result.confidence = 0.8;
                result.safe_to_delete = true;
                result.reason = "Development build artifact";
            } else {
                result.addCategory(.dev_artifact);
            }
        }

        // 8. Check for duplicates (requires content hashing)
        if (self.config.detect_duplicates and file.size > 0 and file.size <= self.config.max_hash_size) {
            if (try self.checkDuplicate(&result)) {
                if (result.category == .normal) {
                    result.category = .duplicate;
                }
                result.addCategory(.duplicate);
                result.confidence = 0.95;
            }
        }

        return result;
    }

    /// Check if file is a temporary file based on extension/name
    fn isTemporaryFile(self: *Analyzer, file: scanner.FileInfo) bool {
        _ = self;

        // Extract name from path (path is properly owned memory)
        const name = std.fs.path.basename(file.path);

        // Extract extension from name
        if (getExtensionFromName(name)) |ext| {
            for (config.FilePatterns.temp_extensions) |temp_ext| {
                if (std.ascii.eqlIgnoreCase(ext, temp_ext)) {
                    return true;
                }
            }
        }

        // Check name patterns

        // Files ending with ~
        if (name.len > 0 and name[name.len - 1] == '~') {
            return true;
        }

        // Core dump files
        if (std.mem.startsWith(u8, name, "core.") or std.mem.eql(u8, name, "core")) {
            return true;
        }

        // Vim swap files
        if (std.mem.startsWith(u8, name, ".") and std.mem.endsWith(u8, name, ".swp")) {
            return true;
        }

        // Windows temp files
        if (std.mem.startsWith(u8, name, "~$")) {
            return true;
        }

        // macOS junk files (.DS_Store, ._, etc.)
        for (config.FilePatterns.macos_junk) |junk| {
            if (std.mem.eql(u8, name, junk)) {
                return true;
            }
            // Check for resource fork files (._filename)
            if (std.mem.startsWith(u8, name, junk)) {
                return true;
            }
        }

        return false;
    }

    /// Check if file is in a cache directory
    fn isCacheFile(self: *Analyzer, file: scanner.FileInfo) bool {
        _ = self;
        const path = file.path;

        for (config.FilePatterns.cache_dirs) |cache_dir| {
            if (std.mem.indexOf(u8, path, cache_dir) != null) {
                return true;
            }
        }

        // Check for common cache patterns in path
        const cache_patterns = [_][]const u8{
            "/Cache/",
            "/cache/",
            "/.cache/",
            "/Caches/",
            "\\Cache\\",
            "\\cache\\",
        };

        for (cache_patterns) |pattern| {
            if (std.mem.indexOf(u8, path, pattern) != null) {
                return true;
            }
        }

        // macOS-specific: ~/Library/Caches/
        if (std.mem.indexOf(u8, path, "/Library/Caches/") != null) {
            return true;
        }

        // macOS-specific waste directories
        for (config.FilePatterns.macos_library_waste) |waste_dir| {
            var buf: [256]u8 = undefined;
            const pattern = std.fmt.bufPrint(&buf, "/Library/{s}/", .{waste_dir}) catch continue;
            if (std.mem.indexOf(u8, path, pattern) != null) {
                return true;
            }
        }

        // Developer package manager caches
        for (config.FilePatterns.dev_cache_dirs) |cache_dir| {
            var buf: [256]u8 = undefined;
            const with_slash = std.fmt.bufPrint(&buf, "/{s}/", .{cache_dir}) catch continue;
            if (std.mem.indexOf(u8, path, with_slash) != null) {
                return true;
            }
        }

        return false;
    }

    /// Check if file is a log file
    fn isLogFile(self: *Analyzer, file: scanner.FileInfo) bool {
        _ = self;

        const path = file.path;
        const name = std.fs.path.basename(path);

        // Extract extension from name
        if (getExtensionFromName(name)) |ext| {
            for (config.FilePatterns.log_extensions) |log_ext| {
                if (std.ascii.eqlIgnoreCase(ext, log_ext)) {
                    return true;
                }
            }
        }

        // Check for log patterns in path
        const log_patterns = [_][]const u8{
            "/logs/",
            "/Logs/",
            "\\logs\\",
            "\\Logs\\",
            "/var/log/",
        };

        for (log_patterns) |pattern| {
            if (std.mem.indexOf(u8, path, pattern) != null) {
                return true;
            }
        }

        return false;
    }

    /// Check if file is an old download
    fn isOldDownload(self: *Analyzer, file: scanner.FileInfo) bool {
        const path = file.path;

        // Check if in downloads directory
        const download_patterns = [_][]const u8{
            "/Downloads/",
            "\\Downloads\\",
            "/downloads/",
            "\\downloads\\",
        };

        var in_downloads = false;
        for (download_patterns) |pattern| {
            if (std.mem.indexOf(u8, path, pattern) != null) {
                in_downloads = true;
                break;
            }
        }

        if (!in_downloads) return false;

        // Check age
        const age_days = file.getAgeDays();
        return age_days >= self.config.old_download_days;
    }

    /// Check if file is a development artifact
    fn isDevArtifact(self: *Analyzer, file: scanner.FileInfo) bool {
        _ = self;
        const path = file.path;

        for (config.FilePatterns.dev_artifact_dirs) |artifact_dir| {
            // Build patterns with separators
            var buf: [256]u8 = undefined;
            const with_slash = std.fmt.bufPrint(&buf, "/{s}/", .{artifact_dir}) catch continue;
            if (std.mem.indexOf(u8, path, with_slash) != null) {
                return true;
            }

            const with_backslash = std.fmt.bufPrint(&buf, "\\{s}\\", .{artifact_dir}) catch continue;
            if (std.mem.indexOf(u8, path, with_backslash) != null) {
                return true;
            }
        }

        // Check for common compiled file extensions
        if (file.extension) |ext| {
            const compiled_exts = [_][]const u8{
                ".o",
                ".obj",
                ".pyc",
                ".pyo",
                ".class",
                ".dll",
                ".so",
                ".dylib",
                ".a",
                ".lib",
                ".pdb",
            };
            for (compiled_exts) |comp_ext| {
                if (std.ascii.eqlIgnoreCase(ext, comp_ext)) {
                    return true;
                }
            }
        }

        // Xcode-specific directories
        const xcode_patterns = [_][]const u8{
            "/DerivedData/",
            "/Build/Intermediates/",
            "/Build/Products/",
            "/ModuleCache/",
            "/iOS DeviceSupport/",
            "/watchOS DeviceSupport/",
            "/CoreSimulator/",
        };
        for (xcode_patterns) |pattern| {
            if (std.mem.indexOf(u8, path, pattern) != null) {
                return true;
            }
        }

        return false;
    }

    /// Check if file is a duplicate using content hashing
    fn checkDuplicate(self: *Analyzer, result: *AnalysisResult) !bool {
        const file = result.file;

        // First, check if any other files have the same size
        // (optimization: only hash files with matching sizes)
        const size = file.size;

        // Compute hash of file content
        const hash = try self.computeFileHash(file.path);
        result.content_hash = hash;

        // Check if we've seen this hash before
        if (self.hash_to_path.get(hash)) |original_path| {
            result.duplicate_of = original_path;
            result.safe_to_delete = true;
            result.reason = "Duplicate of another file";
            return true;
        }

        // Register this file's hash
        const path_copy = try self.allocator.dupe(u8, file.path);
        try self.hash_to_path.put(self.allocator, hash, path_copy);

        // Also track by size for future optimization
        const size_entry = try self.size_to_files.getOrPut(self.allocator, size);
        if (!size_entry.found_existing) {
            size_entry.value_ptr.* = .{};
        }
        const another_path_copy = try self.allocator.dupe(u8, file.path);
        try size_entry.value_ptr.append(self.allocator, another_path_copy);

        return false;
    }

    /// Compute xxHash of file content
    fn computeFileHash(self: *Analyzer, path: []const u8) !u64 {
        _ = self;

        const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| {
            return switch (err) {
                error.AccessDenied, error.FileNotFound => 0,
                else => err,
            };
        };
        defer file.close();

        // Use xxHash for fast hashing
        var hasher = std.hash.XxHash64.init(0);

        var buf: [8192]u8 = undefined;
        while (true) {
            const bytes_read = file.read(&buf) catch |err| {
                return switch (err) {
                    error.AccessDenied => 0,
                    else => err,
                };
            };
            if (bytes_read == 0) break;
            hasher.update(buf[0..bytes_read]);
        }

        return hasher.final();
    }

    /// Get analysis results
    pub fn getResults(self: *Analyzer) []const AnalysisResult {
        return self.results.items;
    }

    /// Get analysis statistics
    pub fn getStats(self: *Analyzer) AnalysisStats {
        return self.stats;
    }

    /// Get results filtered by category
    pub fn getResultsByCategory(self: *Analyzer, category: FileCategory) !std.ArrayList(AnalysisResult) {
        var filtered = std.ArrayList(AnalysisResult){};
        for (self.results.items) |result| {
            if (result.hasCategory(category)) {
                try filtered.append(self.allocator, result);
            }
        }
        return filtered;
    }

    /// Get total space that could be reclaimed
    pub fn getPotentialSavings(self: *Analyzer) u64 {
        var total: u64 = 0;
        for (self.results.items) |result| {
            if (result.safe_to_delete) {
                total += result.file.size;
            }
        }
        return total;
    }

    /// Get results sorted by size (largest first)
    pub fn getResultsSortedBySize(self: *Analyzer) ![]AnalysisResult {
        const sorted = try self.allocator.alloc(AnalysisResult, self.results.items.len);
        @memcpy(sorted, self.results.items);

        std.mem.sort(AnalysisResult, sorted, {}, struct {
            fn lessThan(_: void, a: AnalysisResult, b: AnalysisResult) bool {
                return a.file.size > b.file.size; // Descending
            }
        }.lessThan);

        return sorted;
    }

    /// Get results sorted by confidence (highest first)
    pub fn getResultsSortedByConfidence(self: *Analyzer) ![]AnalysisResult {
        const sorted = try self.allocator.alloc(AnalysisResult, self.results.items.len);
        @memcpy(sorted, self.results.items);

        std.mem.sort(AnalysisResult, sorted, {}, struct {
            fn lessThan(_: void, a: AnalysisResult, b: AnalysisResult) bool {
                return a.confidence > b.confidence; // Descending
            }
        }.lessThan);

        return sorted;
    }

    /// Reset analyzer state
    pub fn reset(self: *Analyzer) void {
        self.results.clearRetainingCapacity();
        self.stats = .{};

        // Clear hash maps
        var hash_iter = self.hash_to_path.iterator();
        while (hash_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.hash_to_path.clearRetainingCapacity();

        var size_iter = self.size_to_files.iterator();
        while (size_iter.next()) |entry| {
            for (entry.value_ptr.items) |path| {
                self.allocator.free(path);
            }
            entry.value_ptr.clearRetainingCapacity();
        }
        self.size_to_files.clearRetainingCapacity();
    }
};

/// Quick analysis function for a list of files
pub fn quickAnalyze(allocator: std.mem.Allocator, files: []const scanner.FileInfo) !AnalysisStats {
    var analyzer = Analyzer.init(allocator, .{});
    defer analyzer.deinit();

    try analyzer.analyzeFiles(files);
    return analyzer.stats;
}

/// Helper to extract extension from filename
fn getExtensionFromName(name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    var i: usize = name.len;
    while (i > 0) {
        i -= 1;
        if (name[i] == '.') {
            if (i == 0) return null;
            return name[i..];
        }
    }
    return null;
}

// Unit tests
test "file category names" {
    try std.testing.expectEqualStrings("Temporary", FileCategory.temporary.getName());
    try std.testing.expectEqualStrings("Duplicate", FileCategory.duplicate.getName());
}

test "analyzer initialization" {
    const allocator = std.testing.allocator;
    var analyzer = Analyzer.init(allocator, .{});
    defer analyzer.deinit();

    try std.testing.expect(analyzer.stats.total_analyzed == 0);
    try std.testing.expect(analyzer.results.items.len == 0);
}

test "temporary file detection" {
    const allocator = std.testing.allocator;
    var analyzer = Analyzer.init(allocator, .{});
    defer analyzer.deinit();

    // Test .tmp extension
    const tmp_file = scanner.FileInfo{
        .path = "/tmp/test.tmp",
        .name = "test.tmp",
        .size = 100,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
        .is_dir = false,
        .is_symlink = false,
        .is_hidden = false,
        .is_readonly = false,
        .is_executable = false,
        .extension = ".tmp",
        .mode = 0o644,
        .inode = 1,
        .attributes = platform.FileAttributes{},
    };

    try std.testing.expect(analyzer.isTemporaryFile(tmp_file));

    // Test backup file
    const bak_file = scanner.FileInfo{
        .path = "/home/user/file.bak",
        .name = "file.bak",
        .size = 100,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
        .is_dir = false,
        .is_symlink = false,
        .is_hidden = false,
        .is_readonly = false,
        .is_executable = false,
        .extension = ".bak",
        .mode = 0o644,
        .inode = 2,
        .attributes = platform.FileAttributes{},
    };

    try std.testing.expect(analyzer.isTemporaryFile(bak_file));
}

test "cache file detection" {
    const allocator = std.testing.allocator;
    var analyzer = Analyzer.init(allocator, .{});
    defer analyzer.deinit();

    const cache_file = scanner.FileInfo{
        .path = "/home/user/.cache/something/file.dat",
        .name = "file.dat",
        .size = 100,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
        .is_dir = false,
        .is_symlink = false,
        .is_hidden = false,
        .is_readonly = false,
        .is_executable = false,
        .extension = ".dat",
        .mode = 0o644,
        .inode = 1,
        .attributes = platform.FileAttributes{},
    };

    try std.testing.expect(analyzer.isCacheFile(cache_file));
}

test "log file detection" {
    const allocator = std.testing.allocator;
    var analyzer = Analyzer.init(allocator, .{});
    defer analyzer.deinit();

    const log_file = scanner.FileInfo{
        .path = "/var/log/system.log",
        .name = "system.log",
        .size = 100,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
        .is_dir = false,
        .is_symlink = false,
        .is_hidden = false,
        .is_readonly = false,
        .is_executable = false,
        .extension = ".log",
        .mode = 0o644,
        .inode = 1,
        .attributes = platform.FileAttributes{},
    };

    try std.testing.expect(analyzer.isLogFile(log_file));
}

test "dev artifact detection" {
    const allocator = std.testing.allocator;
    var analyzer = Analyzer.init(allocator, .{});
    defer analyzer.deinit();

    const node_modules_file = scanner.FileInfo{
        .path = "/home/user/project/node_modules/package/index.js",
        .name = "index.js",
        .size = 100,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
        .is_dir = false,
        .is_symlink = false,
        .is_hidden = false,
        .is_readonly = false,
        .is_executable = false,
        .extension = ".js",
        .mode = 0o644,
        .inode = 1,
        .attributes = platform.FileAttributes{},
    };

    try std.testing.expect(analyzer.isDevArtifact(node_modules_file));
}

test "analysis result categories" {
    var result = AnalysisResult.init(scanner.FileInfo{
        .path = "/tmp/test",
        .name = "test",
        .size = 0,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
        .is_dir = false,
        .is_symlink = false,
        .is_hidden = false,
        .is_readonly = false,
        .is_executable = false,
        .extension = null,
        .mode = 0,
        .inode = 0,
        .attributes = platform.FileAttributes{},
    }, .temporary);

    result.addCategory(.large);

    try std.testing.expect(result.hasCategory(.temporary));
    try std.testing.expect(result.hasCategory(.large));
    try std.testing.expect(!result.hasCategory(.duplicate));
}

test "analysis stats" {
    var stats = AnalysisStats{};

    var result = AnalysisResult.init(scanner.FileInfo{
        .path = "/tmp/test",
        .name = "test",
        .size = 1024,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
        .is_dir = false,
        .is_symlink = false,
        .is_hidden = false,
        .is_readonly = false,
        .is_executable = false,
        .extension = null,
        .mode = 0,
        .inode = 0,
        .attributes = platform.FileAttributes{},
    }, .temporary);

    stats.recordFile(&result);

    try std.testing.expect(stats.total_analyzed == 1);
    const temp_stats = stats.getCategoryStats(.temporary);
    try std.testing.expect(temp_stats.count == 1);
    try std.testing.expect(temp_stats.total_size == 1024);
}
