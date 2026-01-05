const std = @import("std");
const builtin = @import("builtin");

/// ANSI escape codes for terminal control
pub const Escape = struct {
    /// Clear screen
    pub const clear_screen = "\x1b[2J";
    /// Clear line
    pub const clear_line = "\x1b[2K";
    /// Move cursor to home position (1,1)
    pub const cursor_home = "\x1b[H";
    /// Hide cursor
    pub const cursor_hide = "\x1b[?25l";
    /// Show cursor
    pub const cursor_show = "\x1b[?25h";
    /// Reset all attributes
    pub const reset = "\x1b[0m";
    /// Bold
    pub const bold = "\x1b[1m";
    /// Dim
    pub const dim = "\x1b[2m";
    /// Italic
    pub const italic = "\x1b[3m";
    /// Underline
    pub const underline = "\x1b[4m";
    /// Blink
    pub const blink = "\x1b[5m";
    /// Reverse
    pub const reverse = "\x1b[7m";

    /// Enable alternative screen buffer
    pub const alt_screen_on = "\x1b[?1049h";
    /// Disable alternative screen buffer
    pub const alt_screen_off = "\x1b[?1049l";

    /// Enable mouse tracking
    pub const mouse_on = "\x1b[?1000h\x1b[?1002h\x1b[?1015h\x1b[?1006h";
    /// Disable mouse tracking
    pub const mouse_off = "\x1b[?1006l\x1b[?1015l\x1b[?1002l\x1b[?1000l";

    /// Move cursor to position (row, col) - 1-indexed
    pub fn moveTo(buf: []u8, row: u16, col: u16) []u8 {
        return std.fmt.bufPrint(buf, "\x1b[{d};{d}H", .{ row, col }) catch buf[0..0];
    }

    /// Set foreground color (8 colors)
    pub fn fg(buf: []u8, color: Color) []u8 {
        return std.fmt.bufPrint(buf, "\x1b[{d}m", .{30 + @intFromEnum(color)}) catch buf[0..0];
    }

    /// Set background color (8 colors)
    pub fn bg(buf: []u8, color: Color) []u8 {
        return std.fmt.bufPrint(buf, "\x1b[{d}m", .{40 + @intFromEnum(color)}) catch buf[0..0];
    }

    /// Set foreground to RGB color
    pub fn fgRgb(buf: []u8, r: u8, g: u8, b: u8) []u8 {
        return std.fmt.bufPrint(buf, "\x1b[38;2;{d};{d};{d}m", .{ r, g, b }) catch buf[0..0];
    }

    /// Set background to RGB color
    pub fn bgRgb(buf: []u8, r: u8, g: u8, b: u8) []u8 {
        return std.fmt.bufPrint(buf, "\x1b[48;2;{d};{d};{d}m", .{ r, g, b }) catch buf[0..0];
    }

    /// Set foreground to 256 color
    pub fn fg256(buf: []u8, color: u8) []u8 {
        return std.fmt.bufPrint(buf, "\x1b[38;5;{d}m", .{color}) catch buf[0..0];
    }

    /// Set background to 256 color
    pub fn bg256(buf: []u8, color: u8) []u8 {
        return std.fmt.bufPrint(buf, "\x1b[48;5;{d}m", .{color}) catch buf[0..0];
    }
};

/// Basic 8 terminal colors
pub const Color = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,

    /// Get bright version of color
    pub fn bright(self: Color) u8 {
        return @intFromEnum(self) + 8;
    }
};

/// Terminal size
pub const Size = struct {
    width: u16,
    height: u16,
};

/// Terminal state manager
pub const Terminal = struct {
    tty: std.fs.File,
    original_termios: ?std.posix.termios,
    size: Size,
    is_raw_mode: bool,
    alt_screen_active: bool,

    /// Initialize terminal
    pub fn init() !Terminal {
        // Try to open /dev/tty for direct terminal access
        const tty = if (builtin.os.tag == .windows)
            std.fs.File.stdout()
        else blk: {
            const file = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write }) catch |err| {
                std.debug.print("Failed to open /dev/tty: {}, using stdout\n", .{err});
                break :blk std.fs.File.stdout();
            };
            break :blk file;
        };

        var term = Terminal{
            .tty = tty,
            .original_termios = null,
            .size = Size{ .width = 80, .height = 24 },
            .is_raw_mode = false,
            .alt_screen_active = false,
        };

        term.size = term.getSize();
        return term;
    }

    /// Clean up terminal state
    pub fn deinit(self: *Terminal) void {
        if (self.alt_screen_active) {
            self.leaveAltScreen();
        }
        if (self.is_raw_mode) {
            self.disableRawMode();
        }
        self.showCursor();
    }

    /// Get terminal size
    pub fn getSize(self: *Terminal) Size {
        if (builtin.os.tag == .windows) {
            // Windows would use GetConsoleScreenBufferInfo
            return Size{ .width = 80, .height = 24 };
        }

        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(
            self.tty.handle,
            std.posix.T.IOCGWINSZ,
            @intFromPtr(&ws),
        );
        if (rc == 0) {
            return Size{
                .width = if (ws.col > 0) ws.col else 80,
                .height = if (ws.row > 0) ws.row else 24,
            };
        }
        return Size{ .width = 80, .height = 24 };
    }

    /// Enable raw mode for direct input handling
    pub fn enableRawMode(self: *Terminal) !void {
        if (self.is_raw_mode) return;

        if (builtin.os.tag == .windows) {
            // Windows would use SetConsoleMode
            self.is_raw_mode = true;
            return;
        }

        const fd = self.tty.handle;
        self.original_termios = std.posix.tcgetattr(fd) catch |err| {
            std.debug.print("Failed to get terminal attributes: {}\n", .{err});
            return err;
        };

        var raw = self.original_termios.?;

        // Input modes: disable break signal, CR to NL, parity checking, strip 8th bit, XON/XOFF
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        // Output modes: disable post-processing
        raw.oflag.OPOST = false;

        // Control modes: 8 bits per byte
        raw.cflag.CSIZE = .CS8;

        // Local modes: disable echo, canonical mode, signals, extended input
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        // Control characters: minimum 1 byte, no timeout
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;

        try std.posix.tcsetattr(fd, .FLUSH, raw);
        self.is_raw_mode = true;
    }

    /// Disable raw mode, restore original terminal state
    pub fn disableRawMode(self: *Terminal) void {
        if (!self.is_raw_mode) return;

        if (builtin.os.tag == .windows) {
            self.is_raw_mode = false;
            return;
        }

        if (self.original_termios) |orig| {
            std.posix.tcsetattr(self.tty.handle, .FLUSH, orig) catch {};
        }
        self.is_raw_mode = false;
    }

    /// Enter alternative screen buffer
    pub fn enterAltScreen(self: *Terminal) void {
        _ = self.tty.write(Escape.alt_screen_on) catch {};
        self.alt_screen_active = true;
    }

    /// Leave alternative screen buffer
    pub fn leaveAltScreen(self: *Terminal) void {
        _ = self.tty.write(Escape.alt_screen_off) catch {};
        self.alt_screen_active = false;
    }

    /// Hide cursor
    pub fn hideCursor(self: *Terminal) void {
        _ = self.tty.write(Escape.cursor_hide) catch {};
    }

    /// Show cursor
    pub fn showCursor(self: *Terminal) void {
        _ = self.tty.write(Escape.cursor_show) catch {};
    }

    /// Clear entire screen
    pub fn clear(self: *Terminal) void {
        _ = self.tty.write(Escape.clear_screen) catch {};
        _ = self.tty.write(Escape.cursor_home) catch {};
    }

    /// Move cursor to position (0-indexed)
    pub fn moveTo(self: *Terminal, row: u16, col: u16) void {
        var buf: [32]u8 = undefined;
        const seq = Escape.moveTo(&buf, row + 1, col + 1);
        _ = self.tty.write(seq) catch {};
    }

    /// Write string at current position
    pub fn write(self: *Terminal, str: []const u8) void {
        _ = self.tty.write(str) catch {};
    }

    /// Write formatted string
    pub fn print(self: *Terminal, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, fmt, args) catch return;
        _ = self.tty.write(str) catch {};
    }

    /// Set text style
    pub fn setStyle(self: *Terminal, style: Style) void {
        var buf: [64]u8 = undefined;
        var pos: usize = 0;

        // Reset first
        const reset_bytes = Escape.reset;
        @memcpy(buf[pos .. pos + reset_bytes.len], reset_bytes);
        pos += reset_bytes.len;

        // Apply foreground
        if (style.fg) |fg| {
            const seq = Escape.fg(buf[pos..], fg);
            pos += seq.len;
        }

        // Apply background
        if (style.bg) |bg| {
            const seq = Escape.bg(buf[pos..], bg);
            pos += seq.len;
        }

        // Apply modifiers
        if (style.bold) {
            const bold_bytes = Escape.bold;
            @memcpy(buf[pos .. pos + bold_bytes.len], bold_bytes);
            pos += bold_bytes.len;
        }
        if (style.underline) {
            const ul_bytes = Escape.underline;
            @memcpy(buf[pos .. pos + ul_bytes.len], ul_bytes);
            pos += ul_bytes.len;
        }
        if (style.reverse) {
            const rev_bytes = Escape.reverse;
            @memcpy(buf[pos .. pos + rev_bytes.len], rev_bytes);
            pos += rev_bytes.len;
        }

        _ = self.tty.write(buf[0..pos]) catch {};
    }

    /// Reset text style
    pub fn resetStyle(self: *Terminal) void {
        _ = self.tty.write(Escape.reset) catch {};
    }

    /// Flush output buffer
    pub fn flush(self: *Terminal) void {
        // std.fs.File doesn't have a separate flush for stdout
        _ = self;
    }

    /// Refresh terminal size
    pub fn refreshSize(self: *Terminal) void {
        self.size = self.getSize();
    }
};

/// Text style attributes
pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,

    pub const default = Style{};

    pub fn withFg(self: Style, color: Color) Style {
        var s = self;
        s.fg = color;
        return s;
    }

    pub fn withBg(self: Style, color: Color) Style {
        var s = self;
        s.bg = color;
        return s;
    }

    pub fn withBold(self: Style) Style {
        var s = self;
        s.bold = true;
        return s;
    }

    pub fn withUnderline(self: Style) Style {
        var s = self;
        s.underline = true;
        return s;
    }

    pub fn withReverse(self: Style) Style {
        var s = self;
        s.reverse = true;
        return s;
    }
};

// Tests
test "terminal size" {
    var term = try Terminal.init();
    defer term.deinit();

    try std.testing.expect(term.size.width > 0);
    try std.testing.expect(term.size.height > 0);
}

test "style chaining" {
    const style = Style.default
        .withFg(.cyan)
        .withBg(.black)
        .withBold();

    try std.testing.expect(style.fg == .cyan);
    try std.testing.expect(style.bg == .black);
    try std.testing.expect(style.bold);
}

test "escape sequences" {
    var buf: [32]u8 = undefined;

    const move = Escape.moveTo(&buf, 5, 10);
    try std.testing.expectEqualStrings("\x1b[5;10H", move);

    const fg_seq = Escape.fg(&buf, .red);
    try std.testing.expectEqualStrings("\x1b[31m", fg_seq);
}
