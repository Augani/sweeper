const std = @import("std");
const analyzer = @import("analyzer.zig");
const scanner = @import("scanner.zig");
const platform = @import("platform.zig");

/// Space statistics for a category or group of files
pub const SpaceStats = struct {
    /// Total number of files
    file_count: u64 = 0,
    /// Total size in bytes
    total_bytes: u64 = 0,
    /// Number of deletable files (safe to delete)
    deletable_count: u64 = 0,
    /// Size of deletable files
    deletable_bytes: u64 = 0,
    /// Largest file size
    largest_file_size: u64 = 0,
    /// Smallest file size (excluding empty files)
    smallest_file_size: u64 = std.math.maxInt(u64),
    /// Average file size
    average_file_size: u64 = 0,
    /// Number of files by size bracket
    size_distribution: SizeDistribution = .{},

    pub const SizeDistribution = struct {
        tiny: u64 = 0, // < 1KB
        small: u64 = 0, // 1KB - 1MB
        medium: u64 = 0, // 1MB - 100MB
        large: u64 = 0, // 100MB - 1GB
        huge: u64 = 0, // > 1GB
    };

    pub fn add(self: *SpaceStats, file_size: u64, is_deletable: bool) void {
        self.file_count += 1;
        self.total_bytes += file_size;

        if (is_deletable) {
            self.deletable_count += 1;
            self.deletable_bytes += file_size;
        }

        if (file_size > self.largest_file_size) {
            self.largest_file_size = file_size;
        }

        if (file_size > 0 and file_size < self.smallest_file_size) {
            self.smallest_file_size = file_size;
        }

        // Update size distribution
        if (file_size < 1024) {
            self.size_distribution.tiny += 1;
        } else if (file_size < 1024 * 1024) {
            self.size_distribution.small += 1;
        } else if (file_size < 100 * 1024 * 1024) {
            self.size_distribution.medium += 1;
        } else if (file_size < 1024 * 1024 * 1024) {
            self.size_distribution.large += 1;
        } else {
            self.size_distribution.huge += 1;
        }
    }

    pub fn finalize(self: *SpaceStats) void {
        if (self.file_count > 0) {
            self.average_file_size = self.total_bytes / self.file_count;
        }
    }

    /// Get percentage of space that can be freed
    pub fn getDeletablePercentage(self: SpaceStats) f32 {
        if (self.total_bytes == 0) return 0.0;
        return @as(f32, @floatFromInt(self.deletable_bytes)) / @as(f32, @floatFromInt(self.total_bytes)) * 100.0;
    }

    /// Format statistics as human-readable string
    pub fn format(self: SpaceStats, allocator: std.mem.Allocator) ![]u8 {
        const total_str = try platform.formatSize(allocator, self.total_bytes);
        defer allocator.free(total_str);

        const deletable_str = try platform.formatSize(allocator, self.deletable_bytes);
        defer allocator.free(deletable_str);

        const largest_str = try platform.formatSize(allocator, self.largest_file_size);
        defer allocator.free(largest_str);

        const avg_str = try platform.formatSize(allocator, self.average_file_size);
        defer allocator.free(avg_str);

        return try std.fmt.allocPrint(allocator,
            \\Files: {d}
            \\Total Size: {s}
            \\Deletable: {d} files ({s}, {d:.1}%)
            \\Largest File: {s}
            \\Average Size: {s}
        , .{
            self.file_count,
            total_str,
            self.deletable_count,
            deletable_str,
            self.getDeletablePercentage(),
            largest_str,
            avg_str,
        });
    }
};

/// Categorized space breakdown
pub const CategoryBreakdown = struct {
    categories: std.AutoHashMapUnmanaged(analyzer.FileCategory, SpaceStats),
    total: SpaceStats = .{},

    pub fn init() CategoryBreakdown {
        return .{
            .categories = .{},
        };
    }

    pub fn deinit(self: *CategoryBreakdown, allocator: std.mem.Allocator) void {
        self.categories.deinit(allocator);
    }

    pub fn add(self: *CategoryBreakdown, allocator: std.mem.Allocator, category: analyzer.FileCategory, file_size: u64, is_deletable: bool) !void {
        const entry = try self.categories.getOrPut(allocator, category);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{};
        }

        entry.value_ptr.add(file_size, is_deletable);
        self.total.add(file_size, is_deletable);
    }

    pub fn finalize(self: *CategoryBreakdown) void {
        self.total.finalize();
        var iter = self.categories.valueIterator();
        while (iter.next()) |stats| {
            stats.finalize();
        }
    }

    /// Get stats for a specific category
    pub fn getCategoryStats(self: *CategoryBreakdown, category: analyzer.FileCategory) ?SpaceStats {
        return self.categories.get(category);
    }

    /// Get sorted list of categories by size (largest first)
    pub fn getSortedCategories(self: *CategoryBreakdown, allocator: std.mem.Allocator) ![]CategorySize {
        var list = std.ArrayList(CategorySize){};
        defer list.deinit(allocator);

        var iter = self.categories.iterator();
        while (iter.next()) |entry| {
            try list.append(allocator, .{
                .category = entry.key_ptr.*,
                .size = entry.value_ptr.total_bytes,
                .stats = entry.value_ptr.*,
            });
        }

        const sorted = try list.toOwnedSlice();
        std.mem.sort(CategorySize, sorted, {}, struct {
            fn lessThan(_: void, a: CategorySize, b: CategorySize) bool {
                return a.size > b.size; // Descending
            }
        }.lessThan);

        return sorted;
    }

    pub const CategorySize = struct {
        category: analyzer.FileCategory,
        size: u64,
        stats: SpaceStats,
    };
};

/// Space tracking progress for real-time updates
pub const SpaceProgress = struct {
    /// Files processed so far
    files_processed: u64 = 0,
    /// Total bytes scanned so far
    bytes_scanned: u64 = 0,
    /// Current file being processed
    current_file: ?[]const u8 = null,
    /// Progress percentage (0.0 - 1.0)
    progress: f32 = 0.0,
    /// Estimated completion time in seconds
    estimated_seconds_remaining: ?f64 = null,
    /// Start time
    start_time: i64 = 0,

    pub fn init() SpaceProgress {
        return .{
            .start_time = std.time.timestamp(),
        };
    }

    /// Update progress based on current state
    pub fn update(self: *SpaceProgress, files_done: u64, total_files: u64, bytes_done: u64) void {
        self.files_processed = files_done;
        self.bytes_scanned = bytes_done;

        if (total_files > 0) {
            self.progress = @as(f32, @floatFromInt(files_done)) / @as(f32, @floatFromInt(total_files));
        }

        // Estimate time remaining
        const now = std.time.timestamp();
        const elapsed = @as(f64, @floatFromInt(now - self.start_time));
        if (elapsed > 0 and files_done > 0 and files_done < total_files) {
            const rate = @as(f64, @floatFromInt(files_done)) / elapsed;
            const remaining = @as(f64, @floatFromInt(total_files - files_done));
            self.estimated_seconds_remaining = remaining / rate;
        }
    }

    /// Get formatted elapsed time
    pub fn getElapsedTime(self: SpaceProgress) []const u8 {
        const now = std.time.timestamp();
        const elapsed = now - self.start_time;
        var buf: [32]u8 = undefined;
        return std.fmt.bufPrint(&buf, "{d}s", .{elapsed}) catch "?s";
    }

    /// Get formatted ETA
    pub fn getETA(self: SpaceProgress, buf: []u8) []const u8 {
        if (self.estimated_seconds_remaining) |secs| {
            if (secs < 60) {
                return std.fmt.bufPrint(buf, "{d:.0}s", .{secs}) catch "?";
            } else if (secs < 3600) {
                const mins = secs / 60.0;
                return std.fmt.bufPrint(buf, "{d:.1}m", .{mins}) catch "?";
            } else {
                const hours = secs / 3600.0;
                return std.fmt.bufPrint(buf, "{d:.1}h", .{hours}) catch "?";
            }
        }
        return "?";
    }

    /// Get processing rate (files/second)
    pub fn getFilesPerSecond(self: SpaceProgress) f64 {
        const now = std.time.timestamp();
        const elapsed = @as(f64, @floatFromInt(now - self.start_time));
        if (elapsed > 0) {
            return @as(f64, @floatFromInt(self.files_processed)) / elapsed;
        }
        return 0.0;
    }

    /// Get processing rate (bytes/second)
    pub fn getBytesPerSecond(self: SpaceProgress) f64 {
        const now = std.time.timestamp();
        const elapsed = @as(f64, @floatFromInt(now - self.start_time));
        if (elapsed > 0) {
            return @as(f64, @floatFromInt(self.bytes_scanned)) / elapsed;
        }
        return 0.0;
    }
};

/// Space tracker for collecting space statistics during scan/analysis
pub const SpaceTracker = struct {
    allocator: std.mem.Allocator,
    breakdown: CategoryBreakdown,
    progress: SpaceProgress,
    top_largest_files: std.ArrayList(FileSize),
    max_top_files: usize = 100,

    pub const FileSize = struct {
        path: []const u8,
        size: u64,
        category: analyzer.FileCategory,

        pub fn deinit(self: FileSize, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
        }
    };

    pub fn init(allocator: std.mem.Allocator) SpaceTracker {
        return .{
            .allocator = allocator,
            .breakdown = CategoryBreakdown.init(),
            .progress = SpaceProgress.init(),
            .top_largest_files = std.ArrayList(FileSize){},
        };
    }

    pub fn deinit(self: *SpaceTracker) void {
        for (self.top_largest_files.items) |file| {
            file.deinit(self.allocator);
        }
        self.top_largest_files.deinit(self.allocator);
        self.breakdown.deinit(self.allocator);
    }

    /// Process analysis results and build statistics
    pub fn processResults(self: *SpaceTracker, results: []const analyzer.AnalysisResult) !void {
        for (results, 0..) |result, i| {
            try self.addFile(result);
            self.progress.update(i + 1, results.len, self.breakdown.total.total_bytes);
        }
        self.breakdown.finalize();
        self.sortLargestFiles();
    }

    /// Add a single file to tracking
    pub fn addFile(self: *SpaceTracker, result: analyzer.AnalysisResult) !void {
        const file_size = result.file.size;
        const is_deletable = result.safe_to_delete;

        try self.breakdown.add(self.allocator, result.category, file_size, is_deletable);

        // Track largest files
        if (self.top_largest_files.items.len < self.max_top_files or file_size > self.getSmallestTopFileSize()) {
            const path_copy = try self.allocator.dupe(u8, result.file.path);
            try self.top_largest_files.append(self.allocator, .{
                .path = path_copy,
                .size = file_size,
                .category = result.category,
            });

            // Keep list sorted and trimmed
            if (self.top_largest_files.items.len > self.max_top_files) {
                self.sortLargestFiles();
                const removed = self.top_largest_files.pop().?;
                removed.deinit(self.allocator);
            }
        }
    }

    fn getSmallestTopFileSize(self: *SpaceTracker) u64 {
        if (self.top_largest_files.items.len == 0) return 0;
        var smallest: u64 = std.math.maxInt(u64);
        for (self.top_largest_files.items) |file| {
            if (file.size < smallest) {
                smallest = file.size;
            }
        }
        return smallest;
    }

    fn sortLargestFiles(self: *SpaceTracker) void {
        std.mem.sort(FileSize, self.top_largest_files.items, {}, struct {
            fn lessThan(_: void, a: FileSize, b: FileSize) bool {
                return a.size > b.size; // Descending
            }
        }.lessThan);
    }

    /// Get total potential space savings
    pub fn getPotentialSavings(self: *SpaceTracker) u64 {
        return self.breakdown.total.deletable_bytes;
    }

    /// Get top N largest files
    pub fn getTopLargestFiles(self: *SpaceTracker, n: usize) []const FileSize {
        const count = @min(n, self.top_largest_files.items.len);
        return self.top_largest_files.items[0..count];
    }

    /// Generate summary report
    pub fn generateReport(self: *SpaceTracker, allocator: std.mem.Allocator) ![]u8 {
        var output = std.ArrayList(u8){};
        errdefer output.deinit(allocator);

        const writer = output.writer();

        // Header
        try writer.writeAll("=== Space Analysis Report ===\n\n");

        // Overall statistics
        const total_str = try platform.formatSize(allocator, self.breakdown.total.total_bytes);
        defer allocator.free(total_str);

        const deletable_str = try platform.formatSize(allocator, self.breakdown.total.deletable_bytes);
        defer allocator.free(deletable_str);

        try writer.print("Total Files Analyzed: {d}\n", .{self.breakdown.total.file_count});
        try writer.print("Total Space Used: {s}\n", .{total_str});
        try writer.print("Potential Savings: {s} ({d:.1}%)\n\n", .{
            deletable_str,
            self.breakdown.total.getDeletablePercentage(),
        });

        // Category breakdown
        try writer.writeAll("--- Space by Category ---\n");
        const sorted = try self.breakdown.getSortedCategories(allocator);
        defer allocator.free(sorted);

        for (sorted) |cat_size| {
            const size_str = try platform.formatSize(allocator, cat_size.size);
            defer allocator.free(size_str);

            const percent = if (self.breakdown.total.total_bytes > 0)
                @as(f32, @floatFromInt(cat_size.size)) / @as(f32, @floatFromInt(self.breakdown.total.total_bytes)) * 100.0
            else
                0.0;

            try writer.print("  {s}: {s} ({d:.1}%) - {d} files\n", .{
                cat_size.category.getName(),
                size_str,
                percent,
                cat_size.stats.file_count,
            });
        }

        // Top largest files
        try writer.writeAll("\n--- Top 10 Largest Files ---\n");
        const top_files = self.getTopLargestFiles(10);
        for (top_files, 0..) |file, i| {
            const size_str = try platform.formatSize(allocator, file.size);
            defer allocator.free(size_str);

            const basename = std.fs.path.basename(file.path);
            try writer.print("{d:2}. {s} - {s} ({s})\n", .{
                i + 1,
                size_str,
                basename,
                file.category.getName(),
            });
        }

        // Size distribution
        try writer.writeAll("\n--- Size Distribution ---\n");
        const dist = self.breakdown.total.size_distribution;
        try writer.print("  Tiny (<1KB):       {d:6} files\n", .{dist.tiny});
        try writer.print("  Small (1KB-1MB):   {d:6} files\n", .{dist.small});
        try writer.print("  Medium (1MB-100MB): {d:6} files\n", .{dist.medium});
        try writer.print("  Large (100MB-1GB): {d:6} files\n", .{dist.large});
        try writer.print("  Huge (>1GB):       {d:6} files\n", .{dist.huge});

        return output.toOwnedSlice();
    }
};

/// Quick space calculation for a list of files
pub fn calculateTotalSpace(files: []const scanner.FileInfo) u64 {
    var total: u64 = 0;
    for (files) |file| {
        if (!file.is_dir) {
            total += file.size;
        }
    }
    return total;
}

/// Calculate space for analysis results
pub fn calculateAnalysisSpace(results: []const analyzer.AnalysisResult) struct { total: u64, deletable: u64 } {
    var total: u64 = 0;
    var deletable: u64 = 0;

    for (results) |result| {
        total += result.file.size;
        if (result.safe_to_delete) {
            deletable += result.file.size;
        }
    }

    return .{ .total = total, .deletable = deletable };
}

// Tests
test "space stats basic" {
    var stats = SpaceStats{};

    stats.add(1024, true);
    stats.add(2048, false);
    stats.add(4096, true);

    stats.finalize();

    try std.testing.expect(stats.file_count == 3);
    try std.testing.expect(stats.total_bytes == 7168);
    try std.testing.expect(stats.deletable_bytes == 5120);
    try std.testing.expect(stats.average_file_size == 2389);
}

test "space stats size distribution" {
    var stats = SpaceStats{};

    stats.add(512, false); // tiny
    stats.add(2048, false); // small
    stats.add(5 * 1024 * 1024, false); // medium
    stats.add(500 * 1024 * 1024, false); // large
    stats.add(2 * 1024 * 1024 * 1024, false); // huge

    try std.testing.expect(stats.size_distribution.tiny == 1);
    try std.testing.expect(stats.size_distribution.small == 1);
    try std.testing.expect(stats.size_distribution.medium == 1);
    try std.testing.expect(stats.size_distribution.large == 1);
    try std.testing.expect(stats.size_distribution.huge == 1);
}

test "category breakdown" {
    const allocator = std.testing.allocator;
    var breakdown = CategoryBreakdown.init();
    defer breakdown.deinit(allocator);

    try breakdown.add(allocator, .temporary, 1024, true);
    try breakdown.add(allocator, .cache, 2048, true);
    try breakdown.add(allocator, .temporary, 512, true);

    breakdown.finalize();

    try std.testing.expect(breakdown.total.file_count == 3);
    try std.testing.expect(breakdown.total.total_bytes == 3584);

    const temp_stats = breakdown.getCategoryStats(.temporary).?;
    try std.testing.expect(temp_stats.file_count == 2);
    try std.testing.expect(temp_stats.total_bytes == 1536);
}

test "space progress" {
    var progress = SpaceProgress.init();

    progress.update(50, 100, 1024 * 1024);

    try std.testing.expectApproxEqAbs(@as(f32, 0.5), progress.progress, 0.01);
    try std.testing.expect(progress.files_processed == 50);
}

test "space tracker" {
    const allocator = std.testing.allocator;
    var tracker = SpaceTracker.init(allocator);
    defer tracker.deinit();

    // Create mock analysis result
    const file_info = scanner.FileInfo{
        .path = "/tmp/test.tmp",
        .name = "test.tmp",
        .size = 1024 * 100,
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

    var result = analyzer.AnalysisResult.init(file_info, .temporary);
    result.safe_to_delete = true;

    try tracker.addFile(result);

    try std.testing.expect(tracker.breakdown.total.file_count == 1);
    try std.testing.expect(tracker.breakdown.total.total_bytes == 1024 * 100);
    try std.testing.expect(tracker.getPotentialSavings() == 1024 * 100);
}
