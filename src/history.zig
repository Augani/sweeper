const std = @import("std");
const trash = @import("trash.zig");
const platform = @import("platform.zig");

/// Operation types for history tracking
pub const OperationType = enum {
    delete_to_trash,
    permanent_delete,
    restore,
    move,
    rename,

    pub fn getName(self: OperationType) []const u8 {
        return switch (self) {
            .delete_to_trash => "Move to Trash",
            .permanent_delete => "Permanent Delete",
            .restore => "Restore",
            .move => "Move",
            .rename => "Rename",
        };
    }

    pub fn canUndo(self: OperationType) bool {
        return switch (self) {
            .delete_to_trash => true,
            .restore => true,
            .move => true,
            .rename => true,
            .permanent_delete => false,
        };
    }
};

/// A single history entry representing one file operation
pub const HistoryEntry = struct {
    /// Unique ID for this entry
    id: u64,
    /// Type of operation performed
    operation: OperationType,
    /// Original path of the file
    original_path: []const u8,
    /// New path (trash path for delete, destination for move)
    new_path: ?[]const u8,
    /// Size of the file
    file_size: u64,
    /// When the operation was performed
    timestamp: i64,
    /// Whether this operation has been undone
    undone: bool,
    /// Additional metadata (JSON or simple key=value)
    metadata: ?[]const u8,

    pub fn deinit(self: *HistoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.original_path);
        if (self.new_path) |p| allocator.free(p);
        if (self.metadata) |m| allocator.free(m);
    }

    pub fn format(self: HistoryEntry, allocator: std.mem.Allocator) ![]u8 {
        const op_name = self.operation.getName();
        const size_str = try platform.formatSize(allocator, self.file_size);
        defer allocator.free(size_str);

        const basename = std.fs.path.basename(self.original_path);

        return try std.fmt.allocPrint(allocator, "[{s}] {s} ({s})", .{
            op_name,
            basename,
            size_str,
        });
    }
};

/// History manager for tracking operations and enabling undo
pub const HistoryManager = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(HistoryEntry),
    max_entries: usize,
    next_id: u64,
    /// Path to persist history
    history_file: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) HistoryManager {
        return HistoryManager{
            .allocator = allocator,
            .entries = .{},
            .max_entries = 1000,
            .next_id = 1,
            .history_file = null,
        };
    }

    pub fn deinit(self: *HistoryManager) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
        if (self.history_file) |f| self.allocator.free(f);
    }

    /// Set up history persistence
    pub fn enablePersistence(self: *HistoryManager, path: []const u8) !void {
        self.history_file = try self.allocator.dupe(u8, path);
        // Try to load existing history
        self.loadHistory() catch {};
    }

    /// Record a new operation
    pub fn record(
        self: *HistoryManager,
        operation: OperationType,
        original_path: []const u8,
        new_path: ?[]const u8,
        file_size: u64,
    ) !u64 {
        // Enforce max entries limit
        if (self.entries.items.len >= self.max_entries) {
            // Remove oldest entry
            var oldest = self.entries.orderedRemove(0);
            oldest.deinit(self.allocator);
        }

        const entry = HistoryEntry{
            .id = self.next_id,
            .operation = operation,
            .original_path = try self.allocator.dupe(u8, original_path),
            .new_path = if (new_path) |p| try self.allocator.dupe(u8, p) else null,
            .file_size = file_size,
            .timestamp = std.time.timestamp(),
            .undone = false,
            .metadata = null,
        };

        try self.entries.append(self.allocator, entry);
        self.next_id += 1;

        // Persist if enabled
        if (self.history_file != null) {
            self.saveHistory() catch {};
        }

        return entry.id;
    }

    /// Get the most recent undoable operation
    pub fn getLastUndoable(self: *HistoryManager) ?*HistoryEntry {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = &self.entries.items[i];
            if (!entry.undone and entry.operation.canUndo()) {
                return entry;
            }
        }
        return null;
    }

    /// Get entry by ID
    pub fn getEntry(self: *HistoryManager, id: u64) ?*HistoryEntry {
        for (self.entries.items) |*entry| {
            if (entry.id == id) {
                return entry;
            }
        }
        return null;
    }

    /// Mark an entry as undone
    pub fn markUndone(self: *HistoryManager, id: u64) bool {
        if (self.getEntry(id)) |entry| {
            entry.undone = true;

            // Persist if enabled
            if (self.history_file != null) {
                self.saveHistory() catch {};
            }

            return true;
        }
        return false;
    }

    /// Get all entries (most recent first)
    pub fn getEntries(self: *HistoryManager) []const HistoryEntry {
        return self.entries.items;
    }

    /// Get recent entries (up to count, most recent first)
    pub fn getRecentEntries(self: *HistoryManager, count: usize) []const HistoryEntry {
        const len = self.entries.items.len;
        if (len <= count) {
            return self.entries.items;
        }
        return self.entries.items[len - count ..];
    }

    /// Clear all history
    pub fn clear(self: *HistoryManager) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.clearRetainingCapacity();

        // Persist if enabled
        if (self.history_file != null) {
            self.saveHistory() catch {};
        }
    }

    /// Clear entries older than the given timestamp
    pub fn clearOlderThan(self: *HistoryManager, timestamp: i64) usize {
        var removed: usize = 0;
        var i: usize = 0;

        while (i < self.entries.items.len) {
            if (self.entries.items[i].timestamp < timestamp) {
                var entry = self.entries.orderedRemove(i);
                entry.deinit(self.allocator);
                removed += 1;
            } else {
                i += 1;
            }
        }

        // Persist if enabled
        if (self.history_file != null and removed > 0) {
            self.saveHistory() catch {};
        }

        return removed;
    }

    /// Get total size of files that can be recovered
    pub fn getRecoverableSize(self: *HistoryManager) u64 {
        var total: u64 = 0;
        for (self.entries.items) |entry| {
            if (!entry.undone and entry.operation == .delete_to_trash) {
                total += entry.file_size;
            }
        }
        return total;
    }

    /// Count of undoable operations
    pub fn getUndoableCount(self: *HistoryManager) usize {
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (!entry.undone and entry.operation.canUndo()) {
                count += 1;
            }
        }
        return count;
    }

    /// Save history to file
    fn saveHistory(self: *HistoryManager) !void {
        const path = self.history_file orelse return;

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();

        // Write version header
        try file.writeAll("# Desktop Cleanup History v1\n");

        // Write each entry
        for (self.entries.items) |entry| {
            var buf: [512]u8 = undefined;
            const line = try std.fmt.bufPrint(&buf, "{d}|{d}|{s}|{s}|{d}|{d}|{d}\n", .{
                entry.id,
                @intFromEnum(entry.operation),
                entry.original_path,
                entry.new_path orelse "",
                entry.file_size,
                entry.timestamp,
                @as(u8, if (entry.undone) 1 else 0),
            });
            try file.writeAll(line);
        }
    }

    /// Load history from file
    fn loadHistory(self: *HistoryManager) !void {
        const path = self.history_file orelse return;

        const file = std.fs.openFileAbsolute(path, .{}) catch return;
        defer file.close();

        var reader = file.reader();
        var buf: [8192]u8 = undefined;

        // Skip header line
        _ = try reader.readUntilDelimiterOrEof(&buf, '\n');

        while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            const entry = self.parseLine(line) catch continue;
            try self.entries.append(self.allocator, entry);

            // Update next_id
            if (entry.id >= self.next_id) {
                self.next_id = entry.id + 1;
            }
        }
    }

    /// Parse a history line
    fn parseLine(self: *HistoryManager, line: []const u8) !HistoryEntry {
        var iter = std.mem.splitScalar(u8, line, '|');

        const id_str = iter.next() orelse return error.InvalidFormat;
        const op_str = iter.next() orelse return error.InvalidFormat;
        const original = iter.next() orelse return error.InvalidFormat;
        const new_path_str = iter.next() orelse return error.InvalidFormat;
        const size_str = iter.next() orelse return error.InvalidFormat;
        const time_str = iter.next() orelse return error.InvalidFormat;
        const undone_str = iter.next() orelse return error.InvalidFormat;

        return HistoryEntry{
            .id = try std.fmt.parseInt(u64, id_str, 10),
            .operation = @enumFromInt(try std.fmt.parseInt(u8, op_str, 10)),
            .original_path = try self.allocator.dupe(u8, original),
            .new_path = if (new_path_str.len > 0) try self.allocator.dupe(u8, new_path_str) else null,
            .file_size = try std.fmt.parseInt(u64, size_str, 10),
            .timestamp = try std.fmt.parseInt(i64, time_str, 10),
            .undone = undone_str[0] == '1',
            .metadata = null,
        };
    }
};

/// Batch operation tracking
pub const BatchOperation = struct {
    id: u64,
    entries: std.ArrayListUnmanaged(u64),
    started_at: i64,
    completed_at: ?i64,
    description: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: u64, description: []const u8) !BatchOperation {
        return BatchOperation{
            .id = id,
            .entries = .{},
            .started_at = std.time.timestamp(),
            .completed_at = null,
            .description = try allocator.dupe(u8, description),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BatchOperation) void {
        self.entries.deinit(self.allocator);
        self.allocator.free(self.description);
    }

    pub fn addEntry(self: *BatchOperation, entry_id: u64) !void {
        try self.entries.append(self.allocator, entry_id);
    }

    pub fn complete(self: *BatchOperation) void {
        self.completed_at = std.time.timestamp();
    }

    pub fn getEntryCount(self: BatchOperation) usize {
        return self.entries.items.len;
    }
};

// Tests
test "history manager initialization" {
    const allocator = std.testing.allocator;
    var manager = HistoryManager.init(allocator);
    defer manager.deinit();

    try std.testing.expect(manager.entries.items.len == 0);
}

test "record operation" {
    const allocator = std.testing.allocator;
    var manager = HistoryManager.init(allocator);
    defer manager.deinit();

    const id = try manager.record(.delete_to_trash, "/home/user/test.txt", "/trash/test.txt", 1024);
    try std.testing.expect(id == 1);
    try std.testing.expect(manager.entries.items.len == 1);
}

test "get last undoable" {
    const allocator = std.testing.allocator;
    var manager = HistoryManager.init(allocator);
    defer manager.deinit();

    _ = try manager.record(.delete_to_trash, "/home/user/test.txt", "/trash/test.txt", 1024);
    _ = try manager.record(.permanent_delete, "/home/user/test2.txt", null, 2048);

    const last = manager.getLastUndoable();
    try std.testing.expect(last != null);
    try std.testing.expect(last.?.operation == .delete_to_trash);
}

test "mark undone" {
    const allocator = std.testing.allocator;
    var manager = HistoryManager.init(allocator);
    defer manager.deinit();

    const id = try manager.record(.delete_to_trash, "/home/user/test.txt", "/trash/test.txt", 1024);
    try std.testing.expect(manager.markUndone(id));

    const entry = manager.getEntry(id);
    try std.testing.expect(entry.?.undone);
}

test "operation type properties" {
    try std.testing.expect(OperationType.delete_to_trash.canUndo());
    try std.testing.expect(!OperationType.permanent_delete.canUndo());
    try std.testing.expectEqualStrings("Move to Trash", OperationType.delete_to_trash.getName());
}

test "recoverable size calculation" {
    const allocator = std.testing.allocator;
    var manager = HistoryManager.init(allocator);
    defer manager.deinit();

    _ = try manager.record(.delete_to_trash, "/test1.txt", "/trash/test1.txt", 1000);
    _ = try manager.record(.delete_to_trash, "/test2.txt", "/trash/test2.txt", 2000);
    _ = try manager.record(.permanent_delete, "/test3.txt", null, 3000);

    const recoverable = manager.getRecoverableSize();
    try std.testing.expect(recoverable == 3000);
}
