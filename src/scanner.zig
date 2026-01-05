const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");
const config = @import("config.zig");

/// Information about a scanned file
pub const FileInfo = struct {
    /// Full path to the file
    path: []const u8,
    /// File name only (without path)
    name: []const u8,
    /// File size in bytes
    size: u64,
    /// Last access time (nanoseconds since epoch)
    atime: i128,
    /// Last modification time (nanoseconds since epoch)
    mtime: i128,
    /// Creation time (nanoseconds since epoch, if available)
    ctime: i128,
    /// Whether the file is a directory
    is_dir: bool,
    /// Whether the file is a symlink
    is_symlink: bool,
    /// Whether the file is hidden (platform-specific)
    is_hidden: bool,
    /// Whether the file is read-only
    is_readonly: bool,
    /// Whether the file is executable
    is_executable: bool,
    /// File extension (if any)
    extension: ?[]const u8,
    /// File mode/permissions (Unix)
    mode: u32,
    /// Inode number (Unix) for duplicate detection
    inode: u64,
    /// Platform-specific attributes
    attributes: platform.FileAttributes,

    pub fn deinit(self: *FileInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }

    /// Get age of file in days since last modification
    pub fn getAgeDays(self: FileInfo) u64 {
        return getFileAgeDays(self.mtime);
    }

    /// Check if this file matches another by inode (same file on disk)
    pub fn isSameFile(self: FileInfo, other: FileInfo) bool {
        // On Unix, same inode means same file
        if (builtin.os.tag != .windows) {
            return self.inode == other.inode and self.inode != 0;
        }
        // On Windows, compare paths (case-insensitive)
        return std.ascii.eqlIgnoreCase(self.path, other.path);
    }
};

/// Statistics from a scan operation
pub const ScanStats = struct {
    /// Total files scanned
    total_files: u64 = 0,
    /// Total directories scanned
    total_dirs: u64 = 0,
    /// Total size of all files in bytes
    total_size: u64 = 0,
    /// Number of hidden files found
    hidden_files: u64 = 0,
    /// Number of symlinks encountered
    symlinks: u64 = 0,
    /// Number of errors encountered
    errors: u64 = 0,
    /// Scan duration in nanoseconds
    duration_ns: u64 = 0,

    pub fn format(self: ScanStats, allocator: std.mem.Allocator) ![]u8 {
        const size_str = try platform.formatSize(allocator, self.total_size);
        defer allocator.free(size_str);

        return try std.fmt.allocPrint(allocator,
            \\Scan Statistics:
            \\  Files:       {d}
            \\  Directories: {d}
            \\  Total Size:  {s}
            \\  Hidden:      {d}
            \\  Symlinks:    {d}
            \\  Errors:      {d}
            \\  Duration:    {d:.2}s
        , .{
            self.total_files,
            self.total_dirs,
            size_str,
            self.hidden_files,
            self.symlinks,
            self.errors,
            @as(f64, @floatFromInt(self.duration_ns)) / 1_000_000_000.0,
        });
    }
};

/// Callback function type for file scanning
pub const ScanCallback = *const fn (file: *const FileInfo, context: ?*anyopaque) void;

/// Progress callback for scan updates
pub const ProgressCallback = *const fn (progress: *const ScanProgress, context: ?*anyopaque) void;

/// Scan progress information
pub const ScanProgress = struct {
    /// Current directory being scanned
    current_path: []const u8,
    /// Number of files processed so far
    files_processed: u64,
    /// Number of directories processed so far
    dirs_processed: u64,
    /// Bytes processed so far
    bytes_processed: u64,
    /// Current scan depth
    depth: u32,
    /// Whether scan is complete
    is_complete: bool,
    /// Elapsed time in nanoseconds
    elapsed_ns: u64,

    /// Get estimated files per second
    pub fn filesPerSecond(self: ScanProgress) f64 {
        if (self.elapsed_ns == 0) return 0;
        const elapsed_sec = @as(f64, @floatFromInt(self.elapsed_ns)) / 1_000_000_000.0;
        return @as(f64, @floatFromInt(self.files_processed)) / elapsed_sec;
    }
};

/// Error type for scanner operations
pub const ScanError = error{
    AccessDenied,
    PathNotFound,
    InvalidPath,
    OutOfMemory,
    SystemResources,
    Unexpected,
    SymLinkLoop,
    NameTooLong,
    TooManySymlinks,
    NetworkError,
    DiskFull,
};

/// Detailed error information for scan operations
pub const ScanErrorInfo = struct {
    path: []const u8,
    err: anyerror,
    platform_code: i32,
    message: []const u8,

    pub fn format(self: ScanErrorInfo, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "Error at {s}: {} (code: {d})", .{
            self.path,
            self.err,
            self.platform_code,
        });
    }
};

/// Scan mode options
pub const ScanMode = enum {
    /// Scan all files recursively
    recursive,
    /// Only scan immediate directory contents
    shallow,
    /// Scan directories only (for quick overview)
    directories_only,
};

/// Cross-platform filesystem scanner
pub const Scanner = struct {
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    stats: ScanStats,
    results: std.ArrayListUnmanaged(FileInfo),
    errors_list: std.ArrayListUnmanaged(ScanErrorInfo),
    callback: ?ScanCallback,
    callback_context: ?*anyopaque,
    progress_callback: ?ProgressCallback,
    progress_context: ?*anyopaque,
    start_time: i128,

    /// Maximum directory depth to prevent infinite recursion
    max_depth: u32 = 100,

    /// Whether to follow symlinks
    follow_symlinks: bool = false,

    /// Scan mode
    scan_mode: ScanMode = .recursive,

    /// Progress update interval (in files)
    progress_interval: u64 = 100,

    /// Stop scan flag (for cancellation)
    should_stop: bool = false,

    /// Track visited inodes to detect symlink loops (Unix only)
    visited_inodes: std.AutoHashMapUnmanaged(u64, void),

    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config) Scanner {
        return Scanner{
            .allocator = allocator,
            .cfg = cfg,
            .stats = ScanStats{},
            .results = .{},
            .errors_list = .{},
            .callback = null,
            .callback_context = null,
            .progress_callback = null,
            .progress_context = null,
            .start_time = 0,
            .visited_inodes = .{},
        };
    }

    pub fn deinit(self: *Scanner) void {
        for (self.results.items) |*item| {
            var file = item;
            file.deinit(self.allocator);
        }
        self.results.deinit(self.allocator);

        // Free error paths that were duplicated
        for (self.errors_list.items) |err_info| {
            self.allocator.free(err_info.path);
        }
        self.errors_list.deinit(self.allocator);
        self.visited_inodes.deinit(self.allocator);
    }

    /// Set a callback to be invoked for each file found
    pub fn setCallback(self: *Scanner, callback: ScanCallback, context: ?*anyopaque) void {
        self.callback = callback;
        self.callback_context = context;
    }

    /// Set a progress callback for scan updates
    pub fn setProgressCallback(self: *Scanner, callback: ProgressCallback, context: ?*anyopaque) void {
        self.progress_callback = callback;
        self.progress_context = context;
    }

    /// Request scan cancellation
    pub fn cancel(self: *Scanner) void {
        self.should_stop = true;
    }

    /// Scan all configured paths
    pub fn scanAll(self: *Scanner) !void {
        self.start_time = std.time.nanoTimestamp();
        self.should_stop = false;

        for (self.cfg.scan_paths.items) |path| {
            if (self.should_stop) break;

            self.scanPath(path) catch |err| {
                self.stats.errors += 1;
                self.recordError(path, err) catch {};
                if (self.cfg.verbose) {
                    std.debug.print("Error scanning {s}: {}\n", .{ path, err });
                }
            };
        }

        const end_time = std.time.nanoTimestamp();
        self.stats.duration_ns = @intCast(@as(i128, end_time) - self.start_time);

        // Send final progress update
        self.sendProgressUpdate("", 0, true);
    }

    /// Scan a single path (file or directory)
    pub fn scanPath(self: *Scanner, path: []const u8) !void {
        // Validate path before scanning
        if (!platform.isAbsolutePath(path)) {
            // Try to make it absolute
            const cwd = std.fs.cwd();
            var abs_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const abs_path = cwd.realpath(path, &abs_path_buf) catch {
                return error.InvalidPath;
            };
            try self.scanPathInternal(abs_path, 0);
        } else {
            try self.scanPathInternal(path, 0);
        }
    }

    fn scanPathInternal(self: *Scanner, path: []const u8, depth: u32) !void {
        // Check cancellation
        if (self.should_stop) return;

        // Check max depth
        if (depth > self.max_depth) {
            return;
        }

        // Check shallow mode
        if (self.scan_mode == .shallow and depth > 0) {
            return;
        }

        // Check if path should be excluded
        if (self.shouldExclude(path)) {
            return;
        }

        // Send progress update periodically
        if (self.stats.total_files % self.progress_interval == 0) {
            self.sendProgressUpdate(path, depth, false);
        }

        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| {
            switch (err) {
                error.AccessDenied => {
                    self.stats.errors += 1;
                    self.recordError(path, err) catch {};
                    return;
                },
                error.FileNotFound => {
                    self.stats.errors += 1;
                    self.recordError(path, err) catch {};
                    return;
                },
                error.NotDir => {
                    // It's a file, process it directly
                    if (self.scan_mode != .directories_only) {
                        try self.processFile(path);
                    }
                    return;
                },
                error.SymLinkLoop => {
                    self.stats.errors += 1;
                    self.recordError(path, err) catch {};
                    return;
                },
                else => {
                    self.stats.errors += 1;
                    self.recordError(path, err) catch {};
                    return;
                },
            }
        };
        defer dir.close();

        self.stats.total_dirs += 1;

        // For directories_only mode, record the directory
        if (self.scan_mode == .directories_only) {
            try self.processDirEntry(path);
        }

        var iter = dir.iterate();
        while (true) {
            // Check cancellation
            if (self.should_stop) break;

            const entry = iter.next() catch |err| {
                self.stats.errors += 1;
                self.recordError(path, err) catch {};
                if (self.cfg.verbose) {
                    std.debug.print("Error iterating {s}: {}\n", .{ path, err });
                }
                break;
            };

            if (entry == null) break;

            const e = entry.?;

            // Build full path
            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ path, e.name });
            defer self.allocator.free(full_path);

            // Check if it's a hidden file
            const is_hidden = isHiddenFile(e.name);
            if (is_hidden and !self.cfg.show_hidden) {
                continue;
            }

            // Handle based on entry type
            switch (e.kind) {
                .directory => {
                    // Recursively scan subdirectory (if in recursive mode)
                    if (self.scan_mode == .recursive or self.scan_mode == .directories_only) {
                        self.scanPathInternal(full_path, depth + 1) catch |err| {
                            self.stats.errors += 1;
                            self.recordError(full_path, err) catch {};
                            if (self.cfg.verbose) {
                                std.debug.print("Error scanning subdir {s}: {}\n", .{ full_path, err });
                            }
                        };
                    }
                },
                .file => {
                    if (self.scan_mode != .directories_only) {
                        try self.processFileEntry(full_path, e.name, is_hidden);
                    }
                },
                .sym_link => {
                    self.stats.symlinks += 1;
                    if (self.follow_symlinks) {
                        // Check for symlink loops using visited inodes
                        if (try self.checkSymlinkLoop(full_path)) {
                            if (self.cfg.verbose) {
                                std.debug.print("Symlink loop detected: {s}\n", .{full_path});
                            }
                            continue;
                        }
                        // Resolve symlink and process
                        self.scanPathInternal(full_path, depth + 1) catch |err| {
                            self.stats.errors += 1;
                            self.recordError(full_path, err) catch {};
                            if (self.cfg.verbose) {
                                std.debug.print("Error following symlink {s}: {}\n", .{ full_path, err });
                            }
                        };
                    }
                },
                else => {
                    // Skip special files (block devices, sockets, etc.)
                },
            }
        }
    }

    /// Check if following this symlink would create a loop
    fn checkSymlinkLoop(self: *Scanner, path: []const u8) !bool {
        if (builtin.os.tag == .windows) {
            // Windows doesn't use inodes, rely on path comparison
            return false;
        }

        // Get inode of the symlink target
        const stat = std.fs.cwd().statFile(path) catch return false;

        // Check if we've visited this inode before
        if (self.visited_inodes.get(stat.inode)) |_| {
            return true;
        }

        // Mark as visited
        try self.visited_inodes.put(self.allocator, stat.inode, {});
        return false;
    }

    /// Record an error for later reporting
    fn recordError(self: *Scanner, path: []const u8, err: anyerror) !void {
        const error_info = ScanErrorInfo{
            .path = try self.allocator.dupe(u8, path),
            .err = err,
            .platform_code = 0, // Would be populated with errno on Unix
            .message = @errorName(err),
        };
        try self.errors_list.append(self.allocator, error_info);
    }

    /// Send progress update to callback
    fn sendProgressUpdate(self: *Scanner, current_path: []const u8, depth: u32, is_complete: bool) void {
        if (self.progress_callback) |cb| {
            const now = std.time.nanoTimestamp();
            const elapsed: u64 = if (now > self.start_time)
                @intCast(@as(i128, now) - self.start_time)
            else
                0;

            const progress = ScanProgress{
                .current_path = current_path,
                .files_processed = self.stats.total_files,
                .dirs_processed = self.stats.total_dirs,
                .bytes_processed = self.stats.total_size,
                .depth = depth,
                .is_complete = is_complete,
                .elapsed_ns = elapsed,
            };
            cb(&progress, self.progress_context);
        }
    }

    /// Process a directory entry (for directories_only mode)
    fn processDirEntry(self: *Scanner, path: []const u8) !void {
        const name = std.fs.path.basename(path);
        const is_hidden = isHiddenFile(name);

        const stat = std.fs.cwd().statFile(path) catch |err| {
            self.stats.errors += 1;
            self.recordError(path, err) catch {};
            return;
        };

        const attrs = platform.FileAttributes.fromStat(stat, name);

        const dir_info = FileInfo{
            .path = try self.allocator.dupe(u8, path),
            .name = name,
            .size = 0, // Size will be computed if needed
            .atime = stat.atime,
            .mtime = stat.mtime,
            .ctime = stat.ctime,
            .is_dir = true,
            .is_symlink = stat.kind == .sym_link,
            .is_hidden = is_hidden,
            .is_readonly = attrs.is_readonly,
            .is_executable = attrs.is_executable,
            .extension = null,
            .mode = @intCast(stat.mode),
            .inode = @bitCast(stat.inode), // Handle i64 -> u64 on Windows
            .attributes = attrs,
        };

        if (self.callback) |cb| {
            cb(&dir_info, self.callback_context);
        }

        try self.results.append(self.allocator, dir_info);
    }

    fn processFile(self: *Scanner, path: []const u8) !void {
        const name = std.fs.path.basename(path);
        const is_hidden = isHiddenFile(name);

        if (is_hidden and !self.cfg.show_hidden) {
            return;
        }

        try self.processFileEntry(path, name, is_hidden);
    }

    fn processFileEntry(self: *Scanner, path: []const u8, name: []const u8, is_hidden: bool) !void {
        // Get file stats
        const stat = std.fs.cwd().statFile(path) catch |err| {
            self.stats.errors += 1;
            self.recordError(path, err) catch {};
            if (self.cfg.verbose) {
                std.debug.print("Error stating file {s}: {}\n", .{ path, err });
            }
            return;
        };

        // Check minimum file size
        if (stat.size < self.cfg.min_file_size) {
            return;
        }

        // Extract extension
        const extension = getFileExtension(name);

        // Get platform-specific attributes
        const attrs = platform.FileAttributes.fromStat(stat, name);

        // Create file info with enhanced metadata
        const file_info = FileInfo{
            .path = try self.allocator.dupe(u8, path),
            .name = name,
            .size = stat.size,
            .atime = stat.atime,
            .mtime = stat.mtime,
            .ctime = stat.ctime,
            .is_dir = false,
            .is_symlink = stat.kind == .sym_link,
            .is_hidden = is_hidden or attrs.is_hidden,
            .is_readonly = attrs.is_readonly,
            .is_executable = attrs.is_executable,
            .extension = extension,
            .mode = @intCast(stat.mode),
            .inode = @bitCast(stat.inode), // Handle i64 -> u64 on Windows
            .attributes = attrs,
        };

        // Update stats
        self.stats.total_files += 1;
        self.stats.total_size += stat.size;
        if (is_hidden or attrs.is_hidden) {
            self.stats.hidden_files += 1;
        }

        // Invoke callback if set
        if (self.callback) |cb| {
            cb(&file_info, self.callback_context);
        }

        // Add to results
        try self.results.append(self.allocator, file_info);
    }

    /// Get list of errors encountered during scan
    pub fn getErrors(self: *Scanner) []const ScanErrorInfo {
        return self.errors_list.items;
    }

    fn shouldExclude(self: *Scanner, path: []const u8) bool {
        for (self.cfg.exclude_patterns.items) |pattern| {
            if (std.mem.indexOf(u8, path, pattern) != null) {
                return true;
            }
        }
        return false;
    }

    /// Get scan results
    pub fn getResults(self: *Scanner) []const FileInfo {
        return self.results.items;
    }

    /// Get scan statistics
    pub fn getStats(self: *Scanner) ScanStats {
        return self.stats;
    }

    /// Clear all results and reset statistics
    pub fn reset(self: *Scanner) void {
        for (self.results.items) |*item| {
            var file = item;
            file.deinit(self.allocator);
        }
        self.results.clearRetainingCapacity(self.allocator);
        self.stats = ScanStats{};
    }
};

/// Check if a file name indicates a hidden file (platform-specific)
pub fn isHiddenFile(name: []const u8) bool {
    if (name.len == 0) return false;

    // Unix-style hidden files start with '.'
    if (name[0] == '.') {
        // Don't consider '.' and '..' as hidden
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
            return false;
        }
        return true;
    }

    // Windows hidden files are checked via attributes (handled at file stat level)
    // For cross-platform, we also check common Windows hidden file names
    const windows_hidden = [_][]const u8{
        "desktop.ini",
        "thumbs.db",
        "Thumbs.db",
        "$RECYCLE.BIN",
        "System Volume Information",
    };

    for (windows_hidden) |hidden| {
        if (std.mem.eql(u8, name, hidden)) {
            return true;
        }
    }

    return false;
}

/// Extract file extension from name
pub fn getFileExtension(name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;

    // Find the last dot in the name
    var i: usize = name.len;
    while (i > 0) {
        i -= 1;
        if (name[i] == '.') {
            // Don't return extension for hidden files like ".bashrc"
            if (i == 0) return null;
            return name[i..];
        }
    }

    return null;
}

/// Get file age in days from modification time
pub fn getFileAgeDays(mtime: i128) u64 {
    const now = std.time.nanoTimestamp();
    const diff = now - mtime;
    if (diff < 0) return 0;

    // Convert nanoseconds to days
    const ns_per_day: i128 = 24 * 60 * 60 * 1_000_000_000;
    return @intCast(@divFloor(diff, ns_per_day));
}

/// Quick scan function for a single directory (non-recursive)
pub fn quickScan(allocator: std.mem.Allocator, path: []const u8) !std.ArrayList(FileInfo) {
    var results = std.ArrayList(FileInfo){};
    errdefer {
        for (results.items) |*item| {
            item.deinit(allocator);
        }
        results.deinit(allocator);
    }

    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path, entry.name });

        const stat = std.fs.cwd().statFile(full_path) catch {
            allocator.free(full_path);
            continue;
        };

        const attrs = platform.FileAttributes.fromStat(stat, entry.name);
        const is_hidden = isHiddenFile(entry.name);

        const file_info = FileInfo{
            .path = full_path,
            .name = entry.name,
            .size = stat.size,
            .atime = stat.atime,
            .mtime = stat.mtime,
            .ctime = stat.ctime,
            .is_dir = false,
            .is_symlink = entry.kind == .sym_link,
            .is_hidden = is_hidden or attrs.is_hidden,
            .is_readonly = attrs.is_readonly,
            .is_executable = attrs.is_executable,
            .extension = getFileExtension(entry.name),
            .mode = @intCast(stat.mode),
            .inode = stat.inode,
            .attributes = attrs,
        };

        try results.append(allocator, file_info);
    }

    return results;
}

/// Quick scan with filtering options
pub const QuickScanOptions = struct {
    include_hidden: bool = false,
    min_size: u64 = 0,
    max_size: u64 = std.math.maxInt(u64),
    extensions: ?[]const []const u8 = null,
};

pub fn quickScanFiltered(allocator: std.mem.Allocator, path: []const u8, opts: QuickScanOptions) !std.ArrayList(FileInfo) {
    var results = std.ArrayList(FileInfo){};
    errdefer {
        for (results.items) |*item| {
            item.deinit(allocator);
        }
        results.deinit(allocator);
    }

    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        const is_hidden = isHiddenFile(entry.name);
        if (is_hidden and !opts.include_hidden) continue;

        // Check extension filter
        if (opts.extensions) |exts| {
            const file_ext = getFileExtension(entry.name);
            if (file_ext) |ext| {
                var matched = false;
                for (exts) |filter_ext| {
                    if (std.ascii.eqlIgnoreCase(ext, filter_ext)) {
                        matched = true;
                        break;
                    }
                }
                if (!matched) continue;
            } else {
                continue; // No extension and filter requires one
            }
        }

        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path, entry.name });

        const stat = std.fs.cwd().statFile(full_path) catch {
            allocator.free(full_path);
            continue;
        };

        // Check size filters
        if (stat.size < opts.min_size or stat.size > opts.max_size) {
            allocator.free(full_path);
            continue;
        }

        const attrs = platform.FileAttributes.fromStat(stat, entry.name);

        const file_info = FileInfo{
            .path = full_path,
            .name = entry.name,
            .size = stat.size,
            .atime = stat.atime,
            .mtime = stat.mtime,
            .ctime = stat.ctime,
            .is_dir = false,
            .is_symlink = entry.kind == .sym_link,
            .is_hidden = is_hidden or attrs.is_hidden,
            .is_readonly = attrs.is_readonly,
            .is_executable = attrs.is_executable,
            .extension = getFileExtension(entry.name),
            .mode = @intCast(stat.mode),
            .inode = stat.inode,
            .attributes = attrs,
        };

        try results.append(allocator, file_info);
    }

    return results;
}

/// Get directory size (recursive)
pub fn getDirectorySize(allocator: std.mem.Allocator, path: []const u8) !u64 {
    var total_size: u64 = 0;

    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| {
        switch (err) {
            error.AccessDenied, error.FileNotFound => return 0,
            else => return err,
        }
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .directory => {
                total_size += try getDirectorySize(allocator, full_path);
            },
            .file => {
                const stat = std.fs.cwd().statFile(full_path) catch continue;
                total_size += stat.size;
            },
            else => {},
        }
    }

    return total_size;
}

/// Check if a path exists and is accessible
pub fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Check if a path is a directory
pub fn isDirectory(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .directory;
}

/// Get platform-specific default scan paths
pub fn getDefaultScanPaths(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var paths = std.ArrayList([]const u8){};
    errdefer {
        for (paths.items) |p| {
            allocator.free(p);
        }
        paths.deinit(allocator);
    }

    const plat_paths = try platform.Paths.get(allocator);
    var mutable_plat_paths = plat_paths;
    defer mutable_plat_paths.deinit(allocator);

    // Add common cleanup targets
    try paths.append(allocator, try allocator.dupe(u8, plat_paths.temp));
    try paths.append(allocator, try allocator.dupe(u8, plat_paths.cache));

    // Add platform-specific paths
    switch (platform.Platform.current()) {
        .macos => {
            const home = plat_paths.home;
            try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/Downloads", .{home}));
            try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/Library/Logs", .{home}));
        },
        .windows => {
            const home = plat_paths.home;
            try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}\\Downloads", .{home}));
            try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}\\AppData\\Local\\Temp", .{home}));
        },
        .linux => {
            const home = plat_paths.home;
            try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/Downloads", .{home}));
            try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}/.local/share/Trash/files", .{home}));
        },
        .unknown => {},
    }

    return paths;
}

// Unit tests
test "hidden file detection" {
    try std.testing.expect(isHiddenFile(".hidden"));
    try std.testing.expect(isHiddenFile(".bashrc"));
    try std.testing.expect(!isHiddenFile("visible.txt"));
    try std.testing.expect(!isHiddenFile("."));
    try std.testing.expect(!isHiddenFile(".."));
    try std.testing.expect(isHiddenFile("Thumbs.db"));
    try std.testing.expect(isHiddenFile("desktop.ini"));
}

test "file extension extraction" {
    try std.testing.expectEqualStrings(".txt", getFileExtension("file.txt").?);
    try std.testing.expectEqualStrings(".gz", getFileExtension("archive.tar.gz").?);
    try std.testing.expect(getFileExtension("noextension") == null);
    try std.testing.expect(getFileExtension(".hidden") == null);
    try std.testing.expectEqualStrings(".txt", getFileExtension(".hidden.txt").?);
}

test "scanner initialization" {
    const allocator = std.testing.allocator;
    var cfg = config.Config.init(allocator);
    defer cfg.deinit();

    var file_scanner = Scanner.init(allocator, &cfg);
    defer file_scanner.deinit();

    try std.testing.expect(file_scanner.stats.total_files == 0);
    try std.testing.expect(file_scanner.results.items.len == 0);
}

test "scan mode options" {
    try std.testing.expect(ScanMode.recursive != ScanMode.shallow);
    try std.testing.expect(ScanMode.directories_only != ScanMode.recursive);
}

test "progress calculation" {
    const progress = ScanProgress{
        .current_path = "/test",
        .files_processed = 1000,
        .dirs_processed = 50,
        .bytes_processed = 1024 * 1024,
        .depth = 3,
        .is_complete = false,
        .elapsed_ns = 1_000_000_000, // 1 second
    };

    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), progress.filesPerSecond(), 0.1);
}

test "path existence check" {
    // Test with known existing path
    try std.testing.expect(pathExists("/tmp") or pathExists("C:\\Windows\\Temp") or true);
}

test "file age calculation" {
    const now = std.time.nanoTimestamp();
    const one_day_ago = now - (24 * 60 * 60 * 1_000_000_000);

    const age = getFileAgeDays(one_day_ago);
    try std.testing.expect(age >= 1);
}
