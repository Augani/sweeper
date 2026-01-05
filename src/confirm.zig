const std = @import("std");
const platform = @import("platform.zig");

/// Confirmation prompt result
pub const ConfirmResult = enum {
    yes,
    no,
    cancel,
    yes_to_all,
    no_to_all,
};

/// Confirmation options
pub const ConfirmOptions = struct {
    /// Default choice (used when Enter is pressed without input)
    default: ConfirmResult = .no,
    /// Allow "yes to all" option
    allow_yes_to_all: bool = false,
    /// Allow "no to all" option
    allow_no_to_all: bool = false,
    /// Allow cancel option
    allow_cancel: bool = true,
    /// Show warning style (red/bold text)
    show_warning: bool = false,
    /// Additional details to show
    details: ?[]const u8 = null,
};

/// Prompt user for confirmation
pub fn confirm(
    allocator: std.mem.Allocator,
    message: []const u8,
    options: ConfirmOptions,
) !ConfirmResult {
    const stdin = std.fs.File.stdin();
    const stdout_file = std.fs.File.stdout();

    // Helper to write to stdout
    var buf: [4096]u8 = undefined;
    const writeStdout = struct {
        fn write(file: std.fs.File, msg: []const u8) !void {
            _ = try file.write(msg);
        }
    }.write;

    // Show warning if requested
    if (options.show_warning) {
        try writeStdout(stdout_file, "\x1b[31m"); // Red color
        try writeStdout(stdout_file, "⚠ WARNING ⚠\n");
        try writeStdout(stdout_file, "\x1b[0m"); // Reset color
    }

    // Show message
    const msg = try std.fmt.bufPrint(&buf, "{s}\n", .{message});
    try writeStdout(stdout_file, msg);

    // Show details if provided
    if (options.details) |details| {
        const detail_msg = try std.fmt.bufPrint(&buf, "\n{s}\n", .{details});
        try writeStdout(stdout_file, detail_msg);
    }

    // Build and print prompt
    try writeStdout(stdout_file, "\n");
    try writeStdout(stdout_file, "[y]es, [n]o");

    if (options.allow_yes_to_all) {
        try writeStdout(stdout_file, ", yes to [a]ll");
    }
    if (options.allow_no_to_all) {
        try writeStdout(stdout_file, ", no to a[l]l");
    }
    if (options.allow_cancel) {
        try writeStdout(stdout_file, ", [c]ancel");
    }

    // Show default
    const default_str = switch (options.default) {
        .yes => "yes",
        .no => "no",
        .cancel => "cancel",
        .yes_to_all => "yes to all",
        .no_to_all => "no to all",
    };
    const prompt = try std.fmt.bufPrint(&buf, " (default: {s}): ", .{default_str});
    try writeStdout(stdout_file, prompt);

    // Read input
    var input_buf: [256]u8 = undefined;
    const bytes_read = try stdin.read(&input_buf);
    if (bytes_read == 0) return options.default;
    const input = input_buf[0..bytes_read];

    // Trim whitespace
    const trimmed = std.mem.trim(u8, input, " \t\r\n");

    // Empty input = default
    if (trimmed.len == 0) {
        return options.default;
    }

    // Parse response
    const lower = try std.ascii.allocLowerString(allocator, trimmed);
    defer allocator.free(lower);

    if (std.mem.eql(u8, lower, "y") or std.mem.eql(u8, lower, "yes")) {
        return .yes;
    } else if (std.mem.eql(u8, lower, "n") or std.mem.eql(u8, lower, "no")) {
        return .no;
    } else if (options.allow_yes_to_all and (std.mem.eql(u8, lower, "a") or std.mem.eql(u8, lower, "all"))) {
        return .yes_to_all;
    } else if (options.allow_no_to_all and std.mem.eql(u8, lower, "l")) {
        return .no_to_all;
    } else if (options.allow_cancel and (std.mem.eql(u8, lower, "c") or std.mem.eql(u8, lower, "cancel"))) {
        return .cancel;
    }

    // Invalid input, return default
    const invalid_msg = try std.fmt.bufPrint(&buf, "Invalid input, using default: {s}\n", .{default_str});
    try writeStdout(stdout_file, invalid_msg);
    return options.default;
}

/// Simple yes/no confirmation
pub fn confirmYesNo(message: []const u8, default_yes: bool) !bool {
    const result = try confirm(
        std.heap.page_allocator,
        message,
        .{
            .default = if (default_yes) .yes else .no,
            .allow_yes_to_all = false,
            .allow_no_to_all = false,
            .allow_cancel = false,
        },
    );
    return result == .yes;
}

/// Confirmation for dangerous operations
pub fn confirmDangerous(
    allocator: std.mem.Allocator,
    message: []const u8,
    details: ?[]const u8,
) !bool {
    const result = try confirm(
        allocator,
        message,
        .{
            .default = .no,
            .show_warning = true,
            .details = details,
            .allow_yes_to_all = false,
            .allow_no_to_all = false,
            .allow_cancel = true,
        },
    );
    return result == .yes;
}

/// Batch confirmation context
pub const BatchConfirmation = struct {
    yes_to_all: bool = false,
    no_to_all: bool = false,
    cancelled: bool = false,

    /// Ask for confirmation in a batch operation
    pub fn ask(
        self: *BatchConfirmation,
        allocator: std.mem.Allocator,
        message: []const u8,
        options: ConfirmOptions,
    ) !ConfirmResult {
        // Check if already decided
        if (self.cancelled) return .cancel;
        if (self.yes_to_all) return .yes;
        if (self.no_to_all) return .no;

        // Ask user
        const result = try confirm(allocator, message, options);

        // Update state
        switch (result) {
            .yes_to_all => self.yes_to_all = true,
            .no_to_all => self.no_to_all = true,
            .cancel => self.cancelled = true,
            else => {},
        }

        return result;
    }

    /// Reset the confirmation state
    pub fn reset(self: *BatchConfirmation) void {
        self.yes_to_all = false;
        self.no_to_all = false;
        self.cancelled = false;
    }
};

/// Confirmation for file deletion
pub fn confirmDelete(
    allocator: std.mem.Allocator,
    path: []const u8,
    size: u64,
    permanent: bool,
) !bool {
    const size_str = try platform.formatSize(allocator, size);
    defer allocator.free(size_str);

    const basename = std.fs.path.basename(path);

    const message = if (permanent)
        try std.fmt.allocPrint(allocator,
            "Permanently delete '{s}'? ({s})\nThis cannot be undone!",
            .{ basename, size_str })
    else
        try std.fmt.allocPrint(allocator,
            "Move '{s}' to trash? ({s})",
            .{ basename, size_str });
    defer allocator.free(message);

    if (permanent) {
        return try confirmDangerous(allocator, message, path);
    } else {
        return try confirmYesNo(message, false);
    }
}

/// Confirmation for batch deletion
pub fn confirmBatchDelete(
    allocator: std.mem.Allocator,
    count: usize,
    total_size: u64,
    permanent: bool,
) !bool {
    const size_str = try platform.formatSize(allocator, total_size);
    defer allocator.free(size_str);

    const message = if (permanent)
        try std.fmt.allocPrint(allocator,
            "Permanently delete {d} files ({s})?\nThis cannot be undone!",
            .{ count, size_str })
    else
        try std.fmt.allocPrint(allocator,
            "Move {d} files ({s}) to trash?",
            .{ count, size_str });
    defer allocator.free(message);

    const details = if (permanent)
        "All files will be permanently deleted. This operation cannot be undone."
    else
        "Files will be moved to trash and can be restored later.";

    if (permanent) {
        return try confirmDangerous(allocator, message, details);
    } else {
        return try confirmYesNo(message, false);
    }
}

// Tests
test "confirm result enum" {
    const yes: ConfirmResult = .yes;
    const no: ConfirmResult = .no;
    try std.testing.expect(yes != no);
}

test "batch confirmation state" {
    var batch = BatchConfirmation{};

    try std.testing.expect(!batch.yes_to_all);
    try std.testing.expect(!batch.no_to_all);
    try std.testing.expect(!batch.cancelled);

    batch.yes_to_all = true;
    try std.testing.expect(batch.yes_to_all);

    batch.reset();
    try std.testing.expect(!batch.yes_to_all);
}

test "confirm options defaults" {
    const options = ConfirmOptions{};
    try std.testing.expect(options.default == .no);
    try std.testing.expect(!options.allow_yes_to_all);
    try std.testing.expect(options.allow_cancel);
}
