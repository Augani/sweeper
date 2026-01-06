const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");

/// Log level for filtering messages
pub const LogLevel = enum(u8) {
    debug = 0,
    info = 1,
    warning = 2,
    err = 3,
    critical = 4,

    pub fn getName(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warning => "WARN",
            .err => "ERROR",
            .critical => "CRITICAL",
        };
    }

    pub fn getColor(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "\x1b[36m", // Cyan
            .info => "\x1b[32m", // Green
            .warning => "\x1b[33m", // Yellow
            .err => "\x1b[31m", // Red
            .critical => "\x1b[35m", // Magenta
        };
    }
};

/// Log entry structure
pub const LogEntry = struct {
    level: LogLevel,
    timestamp: i64,
    message: []const u8,
    category: ?[]const u8,

    pub fn format(self: LogEntry, allocator: std.mem.Allocator, use_color: bool) ![]u8 {
        const time = self.timestamp;
        const level_str = self.level.getName();

        if (use_color) {
            const color = self.level.getColor();
            const reset = "\x1b[0m";
            if (self.category) |cat| {
                return try std.fmt.allocPrint(allocator, "{s}[{d}] [{s}] [{s}]{s} {s}", .{
                    color, time, level_str, cat, reset, self.message,
                });
            } else {
                return try std.fmt.allocPrint(allocator, "{s}[{d}] [{s}]{s} {s}", .{
                    color, time, level_str, reset, self.message,
                });
            }
        } else {
            if (self.category) |cat| {
                return try std.fmt.allocPrint(allocator, "[{d}] [{s}] [{s}] {s}", .{
                    time, level_str, cat, self.message,
                });
            } else {
                return try std.fmt.allocPrint(allocator, "[{d}] [{s}] {s}", .{
                    time, level_str, self.message,
                });
            }
        }
    }
};

/// Logger configuration
pub const LoggerConfig = struct {
    /// Minimum level to log
    min_level: LogLevel = .info,
    /// Log to file
    log_to_file: bool = true,
    /// Log to console
    log_to_console: bool = true,
    /// Use colored output
    use_color: bool = true,
    /// Maximum log file size before rotation (bytes)
    max_file_size: u64 = 10 * 1024 * 1024, // 10MB
    /// Number of rotated log files to keep
    max_rotations: u32 = 5,
};

/// Main logger for the application
pub const Logger = struct {
    allocator: std.mem.Allocator,
    config: LoggerConfig,
    log_file: ?std.fs.File,
    log_path: ?[]const u8,
    mutex: std.Thread.Mutex,
    buffer: std.ArrayListUnmanaged(LogEntry),
    max_buffer_size: usize,

    pub fn init(allocator: std.mem.Allocator, config: LoggerConfig) Logger {
        return Logger{
            .allocator = allocator,
            .config = config,
            .log_file = null,
            .log_path = null,
            .mutex = .{},
            .buffer = .{},
            .max_buffer_size = 1000,
        };
    }

    pub fn deinit(self: *Logger) void {
        self.flush() catch {};

        for (self.buffer.items) |*entry| {
            self.allocator.free(entry.message);
            if (entry.category) |cat| self.allocator.free(cat);
        }
        self.buffer.deinit(self.allocator);

        if (self.log_file) |f| f.close();
        if (self.log_path) |p| self.allocator.free(p);
    }

    /// Enable file logging
    pub fn enableFileLogging(self: *Logger, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Close existing file if open
        if (self.log_file) |f| f.close();

        // Open new log file
        const file = try std.fs.createFileAbsolute(path, .{ .truncate = false });

        // Seek to end
        try file.seekFromEnd(0);

        self.log_file = file;
        self.log_path = try self.allocator.dupe(u8, path);

        // Write header
        try self.writeHeader();
    }

    /// Write log header
    fn writeHeader(self: *Logger) !void {
        if (self.log_file) |file| {
            const header = try std.fmt.allocPrint(self.allocator,
                \\
                \\=== Desktop Cleanup Log Session Started ===
                \\Timestamp: {d}
                \\Platform: {s}
                \\Version: {s}
                \\============================================
                \\
            , .{
                std.time.timestamp(),
                @tagName(builtin.os.tag),
                "0.2.0",
            });
            defer self.allocator.free(header);

            try file.writeAll(header);
        }
    }

    /// Log a message
    pub fn log(
        self: *Logger,
        level: LogLevel,
        comptime fmt: []const u8,
        args: anytype,
        category: ?[]const u8,
    ) void {
        // Filter by level
        if (@intFromEnum(level) < @intFromEnum(self.config.min_level)) {
            return;
        }

        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return;

        const entry = LogEntry{
            .level = level,
            .timestamp = std.time.timestamp(),
            .message = message,
            .category = if (category) |cat| self.allocator.dupe(u8, cat) catch null else null,
        };

        self.mutex.lock();
        defer self.mutex.unlock();

        // Add to buffer
        self.buffer.append(self.allocator, entry) catch {
            // Buffer full, flush first
            self.flushUnlocked() catch {};
            self.buffer.append(self.allocator, entry) catch {
                // Failed again, just free and return
                self.allocator.free(message);
                if (entry.category) |cat| self.allocator.free(cat);
                return;
            };
        };

        // Console output if enabled
        if (self.config.log_to_console) {
            self.writeToConsole(&entry) catch {};
        }

        // Auto-flush for high priority
        if (@intFromEnum(level) >= @intFromEnum(LogLevel.err)) {
            self.flushUnlocked() catch {};
        }

        // Auto-flush if buffer is large
        if (self.buffer.items.len >= self.max_buffer_size) {
            self.flushUnlocked() catch {};
        }
    }

    /// Convenience methods for different log levels
    pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args, null);
    }

    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args, null);
    }

    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warning, fmt, args, null);
    }

    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args, null);
    }

    pub fn critical(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.critical, fmt, args, null);
    }

    /// Log with category
    pub fn logCat(
        self: *Logger,
        level: LogLevel,
        category: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        self.log(level, fmt, args, category);
    }

    /// Write entry to console
    fn writeToConsole(self: *Logger, entry: *const LogEntry) !void {
        const formatted = try entry.format(self.allocator, self.config.use_color);
        defer self.allocator.free(formatted);

        const stdout = std.fs.File.stdout();
        var buf: [8192]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{s}\n", .{formatted});
        _ = try stdout.write(msg);
    }

    /// Flush buffer to file
    pub fn flush(self: *Logger) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.flushUnlocked();
    }

    /// Flush without locking (caller must hold lock)
    fn flushUnlocked(self: *Logger) !void {
        if (!self.config.log_to_file or self.log_file == null) {
            // Still clear buffer
            for (self.buffer.items) |*entry| {
                self.allocator.free(entry.message);
                if (entry.category) |cat| self.allocator.free(cat);
            }
            self.buffer.clearRetainingCapacity();
            return;
        }

        const file = self.log_file.?;

        // Check if rotation is needed
        const stat = try file.stat();
        if (stat.size >= self.config.max_file_size) {
            try self.rotateLog();
        }

        // Write all buffered entries
        for (self.buffer.items) |*entry| {
            const formatted = try entry.format(self.allocator, false);
            defer self.allocator.free(formatted);

            try file.writeAll(formatted);
            try file.writeAll("\n");

            // Free entry
            self.allocator.free(entry.message);
            if (entry.category) |cat| self.allocator.free(cat);
        }

        self.buffer.clearRetainingCapacity();
    }

    /// Rotate log files
    fn rotateLog(self: *Logger) !void {
        if (self.log_path == null) return;

        const base_path = self.log_path.?;

        // Close current file
        if (self.log_file) |f| {
            f.close();
            self.log_file = null;
        }

        // Rotate existing files
        var i = self.config.max_rotations;
        while (i > 0) : (i -= 1) {
            const old_num = i - 1;
            const new_num = i;

            const old_path = if (old_num == 0)
                try self.allocator.dupe(u8, base_path)
            else
                try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ base_path, old_num });
            defer self.allocator.free(old_path);

            const new_path = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ base_path, new_num });
            defer self.allocator.free(new_path);

            // Try to rename (ignore errors if file doesn't exist)
            std.fs.renameAbsolute(old_path, new_path) catch {};
        }

        // Open new file
        const file = try std.fs.createFileAbsolute(base_path, .{ .truncate = true });
        self.log_file = file;
        try self.writeHeader();
    }

    /// Get default log path for the platform
    pub fn getDefaultLogPath(allocator: std.mem.Allocator) ![]u8 {
        const paths = try platform.Paths.get(allocator);
        defer {
            var mut_paths = paths;
            mut_paths.deinit(allocator);
        }

        // Use cache directory for logs
        const log_dir = paths.cache;

        // Ensure directory exists
        std.fs.makeDirAbsolute(log_dir) catch {};

        return try std.fs.path.join(allocator, &[_][]const u8{ log_dir, "desktop-cleanup.log" });
    }
};

/// Global logger instance
var global_logger: ?*Logger = null;
var global_logger_mutex: std.Thread.Mutex = .{};

/// Initialize global logger
pub fn initGlobal(allocator: std.mem.Allocator, config: LoggerConfig) !*Logger {
    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();

    if (global_logger) |logger| {
        return logger;
    }

    const logger = try allocator.create(Logger);
    logger.* = Logger.init(allocator, config);
    global_logger = logger;

    return logger;
}

/// Get global logger
pub fn getGlobal() ?*Logger {
    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();
    return global_logger;
}

/// Deinitialize global logger
pub fn deinitGlobal(allocator: std.mem.Allocator) void {
    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();

    if (global_logger) |logger| {
        logger.deinit();
        allocator.destroy(logger);
        global_logger = null;
    }
}

// Tests
test "logger initialization" {
    const allocator = std.testing.allocator;
    var logger = Logger.init(allocator, .{});
    defer logger.deinit();

    try std.testing.expect(logger.buffer.items.len == 0);
}

test "log levels" {
    try std.testing.expectEqualStrings("DEBUG", LogLevel.debug.getName());
    try std.testing.expectEqualStrings("INFO", LogLevel.info.getName());
    try std.testing.expectEqualStrings("ERROR", LogLevel.err.getName());
}

test "log entry formatting" {
    const allocator = std.testing.allocator;
    const entry = LogEntry{
        .level = .info,
        .timestamp = 1234567890,
        .message = "Test message",
        .category = null,
    };

    const formatted = try entry.format(allocator, false);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "INFO") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "Test message") != null);
}
