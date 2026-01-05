const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");

/// Cross-platform trash/recycle bin implementation
/// Supports macOS Trash, Windows Recycle Bin, and Linux FreeDesktop.org Trash

/// Trash operation result
pub const TrashResult = struct {
    /// Whether the operation was successful
    success: bool,
    /// Path where the file was moved in trash
    trash_path: ?[]const u8,
    /// Original path of the file
    original_path: []const u8,
    /// Error message if any
    error_message: ?[]const u8,
    /// Timestamp when file was trashed
    trashed_at: i64,

    pub fn deinit(self: *TrashResult, allocator: std.mem.Allocator) void {
        if (self.trash_path) |p| allocator.free(p);
        allocator.free(self.original_path);
        if (self.error_message) |m| allocator.free(m);
    }
};

/// Information about a trashed file
pub const TrashedFileInfo = struct {
    /// Original path before deletion
    original_path: []const u8,
    /// Path in trash directory
    trash_path: []const u8,
    /// When file was moved to trash
    deletion_time: i64,
    /// Original file size
    size: u64,
    /// Unique trash entry ID
    trash_id: []const u8,

    pub fn deinit(self: *TrashedFileInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.original_path);
        allocator.free(self.trash_path);
        allocator.free(self.trash_id);
    }
};

/// Trash operation error types
pub const TrashError = error{
    TrashNotSupported,
    TrashDirectoryNotFound,
    PermissionDenied,
    FileNotFound,
    AlreadyExists,
    DiskFull,
    IoError,
    InvalidPath,
    RestoreFailed,
    OutOfMemory,
};

/// Cross-platform trash manager
pub const TrashManager = struct {
    allocator: std.mem.Allocator,
    trash_dir: []const u8,
    info_dir: []const u8,
    files_dir: []const u8,
    platform_type: platform.Platform,

    pub fn init(allocator: std.mem.Allocator) !TrashManager {
        const plat = platform.Platform.current();
        const paths = try platform.Paths.get(allocator);
        var mutable_paths = paths;
        defer mutable_paths.deinit(allocator);

        var manager = TrashManager{
            .allocator = allocator,
            .trash_dir = undefined,
            .info_dir = undefined,
            .files_dir = undefined,
            .platform_type = plat,
        };

        switch (plat) {
            .macos => {
                // macOS uses ~/.Trash
                manager.trash_dir = try allocator.dupe(u8, paths.trash);
                manager.files_dir = try allocator.dupe(u8, paths.trash);
                // macOS doesn't use separate info dir like Linux
                manager.info_dir = try allocator.dupe(u8, paths.trash);
            },
            .linux => {
                // Linux FreeDesktop.org Trash spec
                // ~/.local/share/Trash/{files,info}
                manager.trash_dir = try allocator.dupe(u8, paths.trash);
                manager.files_dir = try std.fmt.allocPrint(allocator, "{s}/files", .{paths.trash});
                manager.info_dir = try std.fmt.allocPrint(allocator, "{s}/info", .{paths.trash});
            },
            .windows => {
                // Windows Recycle Bin - more complex, uses shell API
                // For this implementation, we'll use a simpler approach
                manager.trash_dir = try allocator.dupe(u8, paths.trash);
                manager.files_dir = try allocator.dupe(u8, paths.trash);
                manager.info_dir = try allocator.dupe(u8, paths.trash);
            },
            .unknown => {
                // Fallback to simple trash directory
                manager.trash_dir = try std.fmt.allocPrint(allocator, "{s}/.trash", .{paths.home});
                manager.files_dir = try std.fmt.allocPrint(allocator, "{s}/.trash/files", .{paths.home});
                manager.info_dir = try std.fmt.allocPrint(allocator, "{s}/.trash/info", .{paths.home});
            },
        }

        // Ensure trash directories exist
        try manager.ensureTrashDirs();

        return manager;
    }

    pub fn deinit(self: *TrashManager) void {
        self.allocator.free(self.trash_dir);
        if (!std.mem.eql(u8, self.files_dir, self.trash_dir)) {
            self.allocator.free(self.files_dir);
        }
        if (!std.mem.eql(u8, self.info_dir, self.trash_dir) and !std.mem.eql(u8, self.info_dir, self.files_dir)) {
            self.allocator.free(self.info_dir);
        }
    }

    /// Ensure trash directories exist
    fn ensureTrashDirs(self: *TrashManager) !void {
        // Create main trash directory
        std.fs.makeDirAbsolute(self.trash_dir) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            }
        };

        // For Linux, create subdirectories
        if (self.platform_type == .linux) {
            std.fs.makeDirAbsolute(self.files_dir) catch |err| {
                switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                }
            };
            std.fs.makeDirAbsolute(self.info_dir) catch |err| {
                switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                }
            };
        }
    }

    /// Move a file to trash
    pub fn trash(self: *TrashManager, path: []const u8) !TrashResult {
        const timestamp = std.time.timestamp();
        const original_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(original_path);

        // Verify file exists
        std.fs.cwd().access(path, .{}) catch {
            return TrashResult{
                .success = false,
                .trash_path = null,
                .original_path = original_path,
                .error_message = try self.allocator.dupe(u8, "File not found"),
                .trashed_at = timestamp,
            };
        };

        // Generate unique trash name
        const basename = std.fs.path.basename(path);
        const trash_name = try self.generateTrashName(basename, timestamp);
        defer self.allocator.free(trash_name);

        // Build destination path
        const dest_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.files_dir, trash_name });
        errdefer self.allocator.free(dest_path);

        // For Linux, create .trashinfo file
        if (self.platform_type == .linux) {
            try self.writeTrashInfo(trash_name, path, timestamp);
        }

        // Move file to trash
        std.fs.renameAbsolute(path, dest_path) catch |err| {
            const err_msg = switch (err) {
                error.AccessDenied => "Permission denied",
                error.FileNotFound => "File not found",
                error.PathAlreadyExists => "File already exists in trash",
                else => "Failed to move file to trash",
            };

            return TrashResult{
                .success = false,
                .trash_path = null,
                .original_path = original_path,
                .error_message = try self.allocator.dupe(u8, err_msg),
                .trashed_at = timestamp,
            };
        };

        return TrashResult{
            .success = true,
            .trash_path = dest_path,
            .original_path = original_path,
            .error_message = null,
            .trashed_at = timestamp,
        };
    }

    /// Generate a unique name for the trashed file
    fn generateTrashName(self: *TrashManager, basename: []const u8, timestamp: i64) ![]u8 {
        // Format: originalname.timestamp.random
        var random_bytes: [4]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        const random_hex = std.fmt.bytesToHex(random_bytes, .lower);

        return try std.fmt.allocPrint(self.allocator, "{s}.{d}.{s}", .{
            basename,
            timestamp,
            random_hex,
        });
    }

    /// Write Linux .trashinfo file
    fn writeTrashInfo(self: *TrashManager, trash_name: []const u8, original_path: []const u8, timestamp: i64) !void {
        const info_filename = try std.fmt.allocPrint(self.allocator, "{s}.trashinfo", .{trash_name});
        defer self.allocator.free(info_filename);

        const info_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.info_dir, info_filename });
        defer self.allocator.free(info_path);

        // URL-encode the path
        const encoded_path = try urlEncode(self.allocator, original_path);
        defer self.allocator.free(encoded_path);

        // Format deletion date
        const deletion_date = try formatDateTime(self.allocator, timestamp);
        defer self.allocator.free(deletion_date);

        // Write the .trashinfo file
        const info_content = try std.fmt.allocPrint(self.allocator,
            \\[Trash Info]
            \\Path={s}
            \\DeletionDate={s}
            \\
        , .{ encoded_path, deletion_date });
        defer self.allocator.free(info_content);

        const file = try std.fs.createFileAbsolute(info_path, .{});
        defer file.close();
        try file.writeAll(info_content);
    }

    /// Restore a file from trash
    pub fn restore(self: *TrashManager, trash_path: []const u8, original_path: []const u8) !bool {
        // Check if trash file exists
        std.fs.cwd().access(trash_path, .{}) catch {
            return false;
        };

        // Check if original location is available
        std.fs.cwd().access(original_path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    // Good - the original location is available
                },
                else => return false,
            }
        };

        // Ensure parent directory exists
        if (platform.parentDir(original_path)) |parent| {
            std.fs.makeDirAbsolute(parent) catch |err| {
                switch (err) {
                    error.PathAlreadyExists => {},
                    else => return false,
                }
            };
        }

        // Move file back to original location
        std.fs.renameAbsolute(trash_path, original_path) catch {
            return false;
        };

        // Remove .trashinfo file on Linux
        if (self.platform_type == .linux) {
            const basename = std.fs.path.basename(trash_path);
            const info_filename = std.fmt.allocPrint(self.allocator, "{s}.trashinfo", .{basename}) catch return true;
            defer self.allocator.free(info_filename);

            const info_path = std.fs.path.join(self.allocator, &[_][]const u8{ self.info_dir, info_filename }) catch return true;
            defer self.allocator.free(info_path);

            std.fs.deleteFileAbsolute(info_path) catch {};
        }

        return true;
    }

    /// Permanently delete a file from trash
    pub fn permanentlyDelete(self: *TrashManager, trash_path: []const u8) !bool {
        _ = self;
        // Check if it's a directory or file
        const stat = std.fs.cwd().statFile(trash_path) catch {
            return false;
        };

        if (stat.kind == .directory) {
            std.fs.deleteTreeAbsolute(trash_path) catch {
                return false;
            };
        } else {
            std.fs.deleteFileAbsolute(trash_path) catch {
                return false;
            };
        }

        return true;
    }

    /// Empty the entire trash
    pub fn emptyTrash(self: *TrashManager) !u64 {
        var deleted_count: u64 = 0;

        var dir = std.fs.openDirAbsolute(self.files_dir, .{ .iterate = true }) catch {
            return 0;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.files_dir, entry.name });
            defer self.allocator.free(full_path);

            if (entry.kind == .directory) {
                std.fs.deleteTreeAbsolute(full_path) catch continue;
            } else {
                std.fs.deleteFileAbsolute(full_path) catch continue;
            }
            deleted_count += 1;
        }

        // Also clean up .trashinfo files on Linux
        if (self.platform_type == .linux) {
            var info_dir = std.fs.openDirAbsolute(self.info_dir, .{ .iterate = true }) catch {
                return deleted_count;
            };
            defer info_dir.close();

            var info_iter = info_dir.iterate();
            while (try info_iter.next()) |entry| {
                const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.info_dir, entry.name });
                defer self.allocator.free(full_path);
                std.fs.deleteFileAbsolute(full_path) catch {};
            }
        }

        return deleted_count;
    }

    /// Get total size of trash
    pub fn getTrashSize(self: *TrashManager) !u64 {
        var total_size: u64 = 0;

        var dir = std.fs.openDirAbsolute(self.files_dir, .{ .iterate = true }) catch {
            return 0;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ self.files_dir, entry.name });
            defer self.allocator.free(full_path);

            if (entry.kind == .file) {
                const stat = std.fs.cwd().statFile(full_path) catch continue;
                total_size += stat.size;
            } else if (entry.kind == .directory) {
                // Calculate directory size recursively
                total_size += getDirectorySize(self.allocator, full_path) catch continue;
            }
        }

        return total_size;
    }

    /// Get number of items in trash
    pub fn getTrashCount(self: *TrashManager) !u64 {
        var count: u64 = 0;

        var dir = std.fs.openDirAbsolute(self.files_dir, .{ .iterate = true }) catch {
            return 0;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |_| {
            count += 1;
        }

        return count;
    }
};

/// URL encode a path (for Linux .trashinfo files)
fn urlEncode(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, path.len * 2);
    errdefer result.deinit(allocator);

    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~' or c == '/') {
            try result.append(allocator, c);
        } else {
            const high: u4 = @truncate(c >> 4);
            const low: u4 = @truncate(c & 0x0F);
            try result.appendSlice(allocator, &[_]u8{ '%', hexDigit(high), hexDigit(low) });
        }
    }

    return result.toOwnedSlice(allocator);
}

fn hexDigit(value: u4) u8 {
    const v: u8 = value;
    return if (v < 10) '0' + v else 'A' + v - 10;
}

/// Format timestamp as ISO 8601 datetime
fn formatDateTime(allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
    // Simple implementation - returns timestamp for now
    // A full implementation would convert to YYYY-MM-DDTHH:MM:SS
    const epoch_seconds: u64 = @intCast(timestamp);

    // Calculate date components (simplified)
    const days_since_epoch = epoch_seconds / 86400;
    const seconds_today = epoch_seconds % 86400;
    const hours = seconds_today / 3600;
    const minutes = (seconds_today % 3600) / 60;
    const seconds = seconds_today % 60;

    // Approximate year/month/day calculation
    var year: u32 = 1970;
    var remaining_days = days_since_epoch;

    while (true) {
        const days_in_year: u64 = if (isLeapYear(year)) 366 else 365;
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }

    const days_in_months = if (isLeapYear(year))
        [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u8 = 1;
    for (days_in_months) |days_in_month| {
        if (remaining_days < days_in_month) break;
        remaining_days -= days_in_month;
        month += 1;
    }

    const day: u8 = @intCast(remaining_days + 1);

    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        year,
        month,
        day,
        hours,
        minutes,
        seconds,
    });
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

/// Calculate directory size recursively
fn getDirectorySize(allocator: std.mem.Allocator, path: []const u8) !u64 {
    var total: u64 = 0;

    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch {
        return 0;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .file => {
                const stat = std.fs.cwd().statFile(full_path) catch continue;
                total += stat.size;
            },
            .directory => {
                total += try getDirectorySize(allocator, full_path);
            },
            else => {},
        }
    }

    return total;
}

// Tests
test "trash manager initialization" {
    const allocator = std.testing.allocator;
    var manager = try TrashManager.init(allocator);
    defer manager.deinit();

    try std.testing.expect(manager.trash_dir.len > 0);
}

test "url encoding" {
    const allocator = std.testing.allocator;

    const encoded = try urlEncode(allocator, "/home/user/test file.txt");
    defer allocator.free(encoded);

    try std.testing.expect(std.mem.indexOf(u8, encoded, "%20") != null);
}

test "date formatting" {
    const allocator = std.testing.allocator;

    const formatted = try formatDateTime(allocator, 1704067200); // 2024-01-01 00:00:00 UTC
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.startsWith(u8, formatted, "2024"));
}
