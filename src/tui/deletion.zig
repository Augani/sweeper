const std = @import("std");
const deleter_mod = @import("../deleter.zig");
const history_mod = @import("../history.zig");

/// Helper functions for TUI deletion operations

/// Delete selected files from a file list
pub fn deleteSelectedFiles(
    allocator: std.mem.Allocator,
    deleter: *deleter_mod.Deleter,
    files: anytype, // Should be []FileItem or similar with .path and .selected fields
) !deleter_mod.DeleteStats {
    // Count selected files
    var selected_count: usize = 0;
    for (files) |file| {
        if (file.selected) selected_count += 1;
    }

    if (selected_count == 0) {
        return deleter.getStats();
    }

    // Build list of paths to delete
    var paths = try allocator.alloc([]const u8, selected_count);
    defer allocator.free(paths);

    var idx: usize = 0;
    for (files) |file| {
        if (file.selected) {
            paths[idx] = file.path;
            idx += 1;
        }
    }

    // Perform deletion
    const results = try deleter.deleteFiles(paths);
    defer {
        for (results) |*result| {
            var mut_result = result.*;
            mut_result.deinit(allocator);
        }
        allocator.free(results);
    }

    return deleter.getStats();
}

/// Remove deleted files from the file list
pub fn removeDeletedFiles(files: anytype) void {
    var write_idx: usize = 0;
    var read_idx: usize = 0;

    while (read_idx < files.items.len) : (read_idx += 1) {
        if (!files.items[read_idx].selected) {
            if (write_idx != read_idx) {
                files.items[write_idx] = files.items[read_idx];
            }
            write_idx += 1;
        }
    }

    files.shrinkRetainingCapacity(write_idx);
}

/// Format deletion stats for display
pub fn formatStats(allocator: std.mem.Allocator, stats: deleter_mod.DeleteStats) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        "Deleted {d}/{d} files, freed {s}",
        .{
            stats.successful,
            stats.total_processed,
            try formatSize(allocator, stats.bytes_freed),
        },
    );
}

/// Format file size in human-readable format
fn formatSize(allocator: std.mem.Allocator, bytes: u64) ![]u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var size: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;

    while (size >= 1024 and unit_idx < units.len - 1) {
        size /= 1024;
        unit_idx += 1;
    }

    return try std.fmt.allocPrint(allocator, "{d:.1} {s}", .{ size, units[unit_idx] });
}

/// Get recent history entries for display
pub fn getRecentHistory(
    allocator: std.mem.Allocator,
    deleter: *deleter_mod.Deleter,
    count: usize,
) ![]history_mod.HistoryEntry {
    const history = deleter.getHistory();
    const entries = history.getRecentEntries(count);

    // Return a slice (no need to allocate new memory)
    return entries;
}

/// Format history entry for display
pub fn formatHistoryEntry(
    allocator: std.mem.Allocator,
    entry: history_mod.HistoryEntry,
) ![]u8 {
    const basename = std.fs.path.basename(entry.original_path);
    const op_name = entry.operation.getName();
    const size_str = try formatSize(allocator, entry.file_size);
    defer allocator.free(size_str);

    const status = if (entry.undone) "[RESTORED]" else "";

    return try std.fmt.allocPrint(allocator, "{s} {s} {s} ({s})", .{
        status,
        op_name,
        basename,
        size_str,
    });
}
