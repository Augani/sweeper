const std = @import("std");
const testing = std.testing;

const logger = @import("../src/logger.zig");
const confirm = @import("../src/confirm.zig");
const deleter = @import("../src/deleter.zig");

test "logger initialization and basic logging" {
    var log = logger.Logger.init(testing.allocator, .{
        .min_level = .debug,
        .log_to_file = false, // Don't write to file in tests
        .log_to_console = false,
    });
    defer log.deinit();

    // Log some messages
    log.debug("Debug message", .{});
    log.info("Info message", .{});
    log.warn("Warning message", .{});
    log.err("Error message", .{});

    // Should have 4 buffered entries
    try testing.expect(log.buffer.items.len == 4);
}

test "logger filtering by level" {
    var log = logger.Logger.init(testing.allocator, .{
        .min_level = .warning, // Only warnings and above
        .log_to_file = false,
        .log_to_console = false,
    });
    defer log.deinit();

    log.debug("Debug message", .{}); // Filtered out
    log.info("Info message", .{}); // Filtered out
    log.warn("Warning message", .{}); // Included
    log.err("Error message", .{}); // Included

    // Should have 2 buffered entries (warning and error only)
    try testing.expect(log.buffer.items.len == 2);
}

test "log entry formatting" {
    const entry = logger.LogEntry{
        .level = .info,
        .timestamp = 1704556800,
        .message = "Test message",
        .category = "test",
    };

    const formatted = try entry.format(testing.allocator, false);
    defer testing.allocator.free(formatted);

    try testing.expect(std.mem.indexOf(u8, formatted, "INFO") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "test") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Test message") != null);
}

test "confirm result enum" {
    try testing.expect(confirm.ConfirmResult.yes != confirm.ConfirmResult.no);
    try testing.expect(confirm.ConfirmResult.yes_to_all != confirm.ConfirmResult.no_to_all);
}

test "batch confirmation state" {
    var batch = confirm.BatchConfirmation{};

    try testing.expect(!batch.yes_to_all);
    try testing.expect(!batch.no_to_all);
    try testing.expect(!batch.cancelled);

    batch.yes_to_all = true;
    try testing.expect(batch.yes_to_all);

    batch.reset();
    try testing.expect(!batch.yes_to_all);
    try testing.expect(!batch.no_to_all);
    try testing.expect(!batch.cancelled);
}

test "delete options defaults include safety features" {
    const options = deleter.DeleteOptions{};

    // Safety defaults
    try testing.expect(options.use_trash); // Use trash by default
    try testing.expect(!options.dry_run); // But not in dry-run by default
    try testing.expect(options.skip_readonly); // Skip read-only files
    try testing.expect(options.safe_only); // Only safe files
    try testing.expect(options.require_confirmation); // Require confirmation
}

test "dry-run mode prevents actual deletion" {
    const tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a test file
    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll("test content");
    file.close();

    // Get absolute path
    const test_path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(test_path);

    // Create deleter in dry-run mode
    var del = try deleter.Deleter.init(testing.allocator, .{
        .dry_run = true,
        .require_confirmation = false, // Disable for automated test
    });
    defer del.deinit();

    // Try to delete
    var result = try del.deleteFile(test_path);
    defer result.deinit(testing.allocator);

    // Should succeed (in dry-run)
    try testing.expect(result.success);

    // But file should still exist
    const file_exists = blk: {
        tmp_dir.dir.access("test.txt", .{}) catch break :blk false;
        break :blk true;
    };
    try testing.expect(file_exists);

    // Error message should indicate dry-run
    try testing.expect(std.mem.eql(u8, result.error_message.?, "[dry-run]"));
}

test "delete stats tracking" {
    var stats = deleter.DeleteStats{
        .total_processed = 10,
        .successful = 8,
        .failed = 2,
        .bytes_freed = 1024 * 1024,
        .moved_to_trash = 6,
        .permanently_deleted = 2,
    };

    const formatted = try stats.format(testing.allocator);
    defer testing.allocator.free(formatted);

    try testing.expect(std.mem.indexOf(u8, formatted, "Total processed: 10") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Successful: 8") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Failed: 2") != null);
}

test "logger categories" {
    var log = logger.Logger.init(testing.allocator, .{
        .log_to_file = false,
        .log_to_console = false,
    });
    defer log.deinit();

    log.logCat(.info, "scan", "Scanning directory", .{});
    log.logCat(.warning, "delete", "Skipping file", .{});

    try testing.expect(log.buffer.items.len == 2);
    try testing.expect(log.buffer.items[0].category != null);
    try testing.expectEqualStrings("scan", log.buffer.items[0].category.?);
    try testing.expectEqualStrings("delete", log.buffer.items[1].category.?);
}
