const std = @import("std");
const builtin = @import("builtin");

/// Platform-specific initialization and utilities
pub const Platform = enum {
    macos,
    windows,
    linux,
    unknown,

    pub fn current() Platform {
        return switch (builtin.os.tag) {
            .macos => .macos,
            .windows => .windows,
            .linux => .linux,
            else => .unknown,
        };
    }

    pub fn name(self: Platform) []const u8 {
        return switch (self) {
            .macos => "macOS",
            .windows => "Windows",
            .linux => "Linux",
            .unknown => "Unknown",
        };
    }

    /// Check if platform supports extended attributes
    pub fn supportsExtendedAttributes(self: Platform) bool {
        return switch (self) {
            .macos, .linux => true,
            .windows => false, // Windows uses ADS (Alternate Data Streams)
            .unknown => false,
        };
    }

    /// Check if platform uses case-sensitive filesystem by default
    pub fn isCaseSensitiveFs(self: Platform) bool {
        return switch (self) {
            .linux => true,
            .macos, .windows => false,
            .unknown => true,
        };
    }
};

/// Platform-specific paths
pub const Paths = struct {
    home: []const u8,
    temp: []const u8,
    cache: []const u8,
    trash: []const u8,

    pub fn get(allocator: std.mem.Allocator) !Paths {
        const platform = Platform.current();

        // Cross-platform home directory detection
        const home = getHomeDir(allocator) catch switch (platform) {
            .windows => "C:\\Users\\Default",
            else => "/tmp",
        };

        // Cross-platform temp directory
        const temp = getTempDir(allocator) catch switch (platform) {
            .windows => "C:\\Windows\\Temp",
            else => "/tmp",
        };

        return switch (platform) {
            .macos => Paths{
                .home = home,
                .temp = temp,
                .cache = try std.fmt.allocPrint(allocator, "{s}/Library/Caches", .{home}),
                .trash = try std.fmt.allocPrint(allocator, "{s}/.Trash", .{home}),
            },
            .windows => Paths{
                .home = home,
                .temp = temp,
                .cache = try std.fmt.allocPrint(allocator, "{s}\\AppData\\Local\\Temp", .{home}),
                .trash = try std.fmt.allocPrint(allocator, "{s}\\$Recycle.Bin", .{home}),
            },
            .linux => Paths{
                .home = home,
                .temp = temp,
                .cache = try std.fmt.allocPrint(allocator, "{s}/.cache", .{home}),
                .trash = try std.fmt.allocPrint(allocator, "{s}/.local/share/Trash", .{home}),
            },
            .unknown => Paths{
                .home = home,
                .temp = temp,
                .cache = "/tmp",
                .trash = "/tmp/trash",
            },
        };
    }

    /// Get home directory cross-platform
    fn getHomeDir(allocator: std.mem.Allocator) ![]const u8 {
        if (builtin.os.tag == .windows) {
            return std.process.getEnvVarOwned(allocator, "USERPROFILE");
        } else {
            return std.process.getEnvVarOwned(allocator, "HOME");
        }
    }

    /// Get temp directory cross-platform
    fn getTempDir(allocator: std.mem.Allocator) ![]const u8 {
        if (builtin.os.tag == .windows) {
            return std.process.getEnvVarOwned(allocator, "TEMP") catch
                std.process.getEnvVarOwned(allocator, "TMP");
        } else {
            return allocator.dupe(u8, "/tmp");
        }
    }

    pub fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        // Free allocated strings
        const platform = Platform.current();
        switch (platform) {
            .macos, .linux => {
                allocator.free(self.cache);
                allocator.free(self.trash);
            },
            .windows => {
                allocator.free(self.cache);
                allocator.free(self.trash);
            },
            .unknown => {},
        }
    }
};

/// Terminal capabilities for TUI
pub const Terminal = struct {
    width: u16,
    height: u16,
    supports_color: bool,
    supports_unicode: bool,

    pub fn detect() Terminal {
        var term = Terminal{
            .width = 80,
            .height = 24,
            .supports_color = true,
            .supports_unicode = true,
        };

        // Try to get terminal size using ioctl on Unix platforms
        if (builtin.os.tag != .windows) {
            var ws: std.posix.winsize = undefined;
            const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
            if (rc == 0) {
                if (ws.col > 0) term.width = ws.col;
                if (ws.row > 0) term.height = ws.row;
            }
        }

        // Check for color support
        if (std.posix.getenv("NO_COLOR")) |_| {
            term.supports_color = false;
        }

        // Check terminal type for unicode support
        if (std.posix.getenv("TERM")) |t| {
            if (std.mem.indexOf(u8, t, "xterm") != null or
                std.mem.indexOf(u8, t, "256color") != null or
                std.mem.indexOf(u8, t, "kitty") != null or
                std.mem.indexOf(u8, t, "alacritty") != null)
            {
                term.supports_unicode = true;
            }
        }

        return term;
    }
};

/// Initialize platform-specific features
pub fn init() !void {
    const platform = Platform.current();

    switch (platform) {
        .windows => {
            // Enable virtual terminal processing on Windows
            // This would use Windows API in full implementation
        },
        .macos, .linux => {
            // Unix platforms typically work out of the box
        },
        .unknown => {},
    }
}

/// Cleanup platform-specific resources
pub fn deinit() void {
    // Cleanup if needed
}

/// Get the path separator for the current platform
pub fn pathSeparator() u8 {
    return if (builtin.os.tag == .windows) '\\' else '/';
}

/// Normalize path separators for the current platform
pub fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, path.len);
    const sep = pathSeparator();
    const other_sep: u8 = if (sep == '/') '\\' else '/';

    for (path, 0..) |c, i| {
        result[i] = if (c == other_sep) sep else c;
    }

    return result;
}

/// Join paths using platform-appropriate separator
pub fn joinPath(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    if (parts.len == 0) return try allocator.dupe(u8, "");

    var total_len: usize = 0;
    for (parts) |part| {
        total_len += part.len + 1; // +1 for separator
    }
    total_len -= 1; // No trailing separator

    var result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    const sep = pathSeparator();

    for (parts, 0..) |part, i| {
        @memcpy(result[pos .. pos + part.len], part);
        pos += part.len;
        if (i < parts.len - 1) {
            result[pos] = sep;
            pos += 1;
        }
    }

    return result;
}

/// Check if a path is absolute
pub fn isAbsolutePath(path: []const u8) bool {
    if (path.len == 0) return false;

    if (builtin.os.tag == .windows) {
        // Windows: C:\ or \\server
        if (path.len >= 3 and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) {
            return true;
        }
        if (path.len >= 2 and path[0] == '\\' and path[1] == '\\') {
            return true;
        }
        return false;
    } else {
        // Unix: starts with /
        return path[0] == '/';
    }
}

/// Get the parent directory of a path
pub fn parentDir(path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;

    var end = path.len;
    // Skip trailing separators
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) {
        end -= 1;
    }

    // Find last separator
    while (end > 0 and path[end - 1] != '/' and path[end - 1] != '\\') {
        end -= 1;
    }

    if (end == 0) return null;

    // Skip trailing separator of parent
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) {
        end -= 1;
    }

    return path[0..end];
}

/// Extended file attributes (platform-specific metadata)
pub const FileAttributes = struct {
    /// File is hidden (Unix dot-file or Windows hidden attribute)
    is_hidden: bool = false,
    /// File is a system file (Windows-specific)
    is_system: bool = false,
    /// File is read-only
    is_readonly: bool = false,
    /// File is a symbolic link
    is_symlink: bool = false,
    /// File is a directory
    is_directory: bool = false,
    /// File is a regular file
    is_file: bool = false,
    /// File owner can execute (Unix)
    is_executable: bool = false,
    /// File creation time (if available, nanoseconds since epoch)
    creation_time: ?i128 = null,

    /// Get file attributes from a stat result
    pub fn fromStat(stat: std.fs.File.Stat, name: []const u8) FileAttributes {
        var attrs = FileAttributes{
            .is_directory = stat.kind == .directory,
            .is_file = stat.kind == .file,
            .is_symlink = stat.kind == .sym_link,
        };

        // Unix hidden file detection (starts with dot)
        if (name.len > 0 and name[0] == '.') {
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                attrs.is_hidden = true;
            }
        }

        // Check for executable permission on Unix (mode contains execute bits)
        if (builtin.os.tag != .windows) {
            // Check if any execute bit is set (owner, group, or other)
            const mode = stat.mode;
            attrs.is_executable = (mode & 0o111) != 0;
            attrs.is_readonly = (mode & 0o222) == 0; // No write bits
        }

        return attrs;
    }
};

/// Check if we have read access to a path
pub fn canRead(path: []const u8) bool {
    std.fs.cwd().access(path, .{ .mode = .read_only }) catch return false;
    return true;
}

/// Check if we have write access to a path
pub fn canWrite(path: []const u8) bool {
    std.fs.cwd().access(path, .{ .mode = .read_write }) catch return false;
    return true;
}

/// Get disk space information for a path
pub const DiskSpace = struct {
    total_bytes: u64,
    free_bytes: u64,
    available_bytes: u64,

    pub fn percentUsed(self: DiskSpace) f64 {
        if (self.total_bytes == 0) return 0;
        const used = self.total_bytes - self.free_bytes;
        return @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(self.total_bytes)) * 100.0;
    }
};

/// Get disk space for the filesystem containing the given path
pub fn getDiskSpace(path: []const u8) !DiskSpace {
    _ = path;
    // For now, return placeholder - real implementation would use statvfs on Unix
    // or GetDiskFreeSpaceEx on Windows
    return DiskSpace{
        .total_bytes = 0,
        .free_bytes = 0,
        .available_bytes = 0,
    };
}

/// Convert bytes to human-readable size string
pub fn formatSize(allocator: std.mem.Allocator, bytes: u64) ![]u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var size: f64 = @floatFromInt(bytes);
    var unit_index: usize = 0;

    while (size >= 1024 and unit_index < units.len - 1) {
        size /= 1024;
        unit_index += 1;
    }

    return try std.fmt.allocPrint(allocator, "{d:.2} {s}", .{ size, units[unit_index] });
}

test "platform detection" {
    const platform = Platform.current();
    try std.testing.expect(platform != .unknown or builtin.os.tag == .freestanding);
}

test "path separator" {
    const sep = pathSeparator();
    if (builtin.os.tag == .windows) {
        try std.testing.expect(sep == '\\');
    } else {
        try std.testing.expect(sep == '/');
    }
}

test "format size" {
    const allocator = std.testing.allocator;

    const small = try formatSize(allocator, 512);
    defer allocator.free(small);
    try std.testing.expectEqualStrings("512.00 B", small);

    const kb = try formatSize(allocator, 1024);
    defer allocator.free(kb);
    try std.testing.expectEqualStrings("1.00 KB", kb);

    const mb = try formatSize(allocator, 1024 * 1024);
    defer allocator.free(mb);
    try std.testing.expectEqualStrings("1.00 MB", mb);
}

test "path normalization" {
    const allocator = std.testing.allocator;

    const normalized = try normalizePath(allocator, "foo/bar/baz");
    defer allocator.free(normalized);

    // Result depends on platform
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("foo\\bar\\baz", normalized);
    } else {
        try std.testing.expectEqualStrings("foo/bar/baz", normalized);
    }
}

test "is absolute path" {
    if (builtin.os.tag == .windows) {
        try std.testing.expect(isAbsolutePath("C:\\Users\\test"));
        try std.testing.expect(isAbsolutePath("\\\\server\\share"));
        try std.testing.expect(!isAbsolutePath("relative\\path"));
    } else {
        try std.testing.expect(isAbsolutePath("/home/user"));
        try std.testing.expect(!isAbsolutePath("relative/path"));
    }
}

test "parent directory" {
    try std.testing.expectEqualStrings("/home", parentDir("/home/user").?);
    try std.testing.expectEqualStrings("/", parentDir("/home").?);
    try std.testing.expect(parentDir("relative") == null);
}

test "file attributes detection" {
    // Test hidden file detection logic
    const hidden_stat = std.fs.File.Stat{
        .kind = .file,
        .size = 100,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
        .inode = 0,
        .mode = 0o644,
    };

    const attrs = FileAttributes.fromStat(hidden_stat, ".hidden");
    try std.testing.expect(attrs.is_hidden);
    try std.testing.expect(attrs.is_file);
    try std.testing.expect(!attrs.is_directory);

    const visible_attrs = FileAttributes.fromStat(hidden_stat, "visible.txt");
    try std.testing.expect(!visible_attrs.is_hidden);
}
