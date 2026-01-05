const std = @import("std");
const terminal = @import("terminal.zig");

const Terminal = terminal.Terminal;
const Style = terminal.Style;
const Color = terminal.Color;

/// A cell in the render buffer
pub const Cell = struct {
    char: u21 = ' ',
    style: Style = Style.default,

    pub fn eql(self: Cell, other: Cell) bool {
        return self.char == other.char and
            self.style.fg == other.style.fg and
            self.style.bg == other.style.bg and
            self.style.bold == other.style.bold and
            self.style.underline == other.style.underline and
            self.style.reverse == other.style.reverse;
    }
};

/// Rectangle structure for positioning
pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn contains(self: Rect, x: u16, y: u16) bool {
        return x >= self.x and x < self.x + self.width and
            y >= self.y and y < self.y + self.height;
    }

    pub fn inner(self: Rect, margin: u16) Rect {
        if (self.width <= margin * 2 or self.height <= margin * 2) {
            return Rect{ .x = self.x, .y = self.y, .width = 0, .height = 0 };
        }
        return Rect{
            .x = self.x + margin,
            .y = self.y + margin,
            .width = self.width - margin * 2,
            .height = self.height - margin * 2,
        };
    }

    pub fn intersection(self: Rect, other: Rect) ?Rect {
        const x1 = @max(self.x, other.x);
        const y1 = @max(self.y, other.y);
        const x2 = @min(self.x + self.width, other.x + other.width);
        const y2 = @min(self.y + self.height, other.y + other.height);

        if (x2 <= x1 or y2 <= y1) return null;
        return Rect{
            .x = x1,
            .y = y1,
            .width = x2 - x1,
            .height = y2 - y1,
        };
    }
};

/// Double-buffered render context
pub const Buffer = struct {
    allocator: std.mem.Allocator,
    cells: []Cell,
    width: u16,
    height: u16,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Buffer {
        const size = @as(usize, width) * @as(usize, height);
        const cells = try allocator.alloc(Cell, size);
        @memset(cells, Cell{});

        return Buffer{
            .allocator = allocator,
            .cells = cells,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.cells);
    }

    /// Clear buffer with default cell
    pub fn clear(self: *Buffer) void {
        @memset(self.cells, Cell{});
    }

    /// Clear buffer with specific character and style
    pub fn fill(self: *Buffer, char: u21, style: Style) void {
        const cell = Cell{ .char = char, .style = style };
        @memset(self.cells, cell);
    }

    /// Get cell at position
    pub fn get(self: *Buffer, x: u16, y: u16) ?*Cell {
        if (x >= self.width or y >= self.height) return null;
        const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        return &self.cells[idx];
    }

    /// Set cell at position
    pub fn set(self: *Buffer, x: u16, y: u16, cell: Cell) void {
        if (x >= self.width or y >= self.height) return;
        const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        self.cells[idx] = cell;
    }

    /// Set character at position with style
    pub fn setChar(self: *Buffer, x: u16, y: u16, char: u21, style: Style) void {
        self.set(x, y, Cell{ .char = char, .style = style });
    }

    /// Draw a string at position (clips to bounds)
    pub fn drawString(self: *Buffer, x: u16, y: u16, str: []const u8, style: Style) void {
        var col = x;
        for (str) |c| {
            if (col >= self.width) break;
            self.setChar(col, y, c, style);
            col += 1;
        }
    }

    /// Draw a string with max length
    pub fn drawStringMax(self: *Buffer, x: u16, y: u16, str: []const u8, max_len: u16, style: Style) void {
        var col = x;
        var count: u16 = 0;
        for (str) |c| {
            if (col >= self.width or count >= max_len) break;
            self.setChar(col, y, c, style);
            col += 1;
            count += 1;
        }
    }

    /// Draw horizontal line
    pub fn drawHLine(self: *Buffer, x: u16, y: u16, len: u16, char: u21, style: Style) void {
        var i: u16 = 0;
        while (i < len) : (i += 1) {
            self.setChar(x + i, y, char, style);
        }
    }

    /// Draw vertical line
    pub fn drawVLine(self: *Buffer, x: u16, y: u16, len: u16, char: u21, style: Style) void {
        var i: u16 = 0;
        while (i < len) : (i += 1) {
            self.setChar(x, y + i, char, style);
        }
    }

    /// Draw box with borders
    pub fn drawBox(self: *Buffer, rect: Rect, style: Style, border: BorderStyle) void {
        if (rect.width < 2 or rect.height < 2) return;

        const chars = border.chars();

        // Corners
        self.setChar(rect.x, rect.y, chars.top_left, style);
        self.setChar(rect.x + rect.width - 1, rect.y, chars.top_right, style);
        self.setChar(rect.x, rect.y + rect.height - 1, chars.bottom_left, style);
        self.setChar(rect.x + rect.width - 1, rect.y + rect.height - 1, chars.bottom_right, style);

        // Horizontal lines
        self.drawHLine(rect.x + 1, rect.y, rect.width - 2, chars.horizontal, style);
        self.drawHLine(rect.x + 1, rect.y + rect.height - 1, rect.width - 2, chars.horizontal, style);

        // Vertical lines
        self.drawVLine(rect.x, rect.y + 1, rect.height - 2, chars.vertical, style);
        self.drawVLine(rect.x + rect.width - 1, rect.y + 1, rect.height - 2, chars.vertical, style);
    }

    /// Fill rectangle with character
    pub fn fillRect(self: *Buffer, rect: Rect, char: u21, style: Style) void {
        var y: u16 = 0;
        while (y < rect.height) : (y += 1) {
            var x: u16 = 0;
            while (x < rect.width) : (x += 1) {
                self.setChar(rect.x + x, rect.y + y, char, style);
            }
        }
    }

    /// Resize buffer (clears content)
    pub fn resize(self: *Buffer, width: u16, height: u16) !void {
        if (width == self.width and height == self.height) return;

        self.allocator.free(self.cells);
        const size = @as(usize, width) * @as(usize, height);
        self.cells = try self.allocator.alloc(Cell, size);
        @memset(self.cells, Cell{});
        self.width = width;
        self.height = height;
    }
};

/// Border drawing characters
pub const BorderChars = struct {
    top_left: u21,
    top_right: u21,
    bottom_left: u21,
    bottom_right: u21,
    horizontal: u21,
    vertical: u21,
};

/// Border style presets
pub const BorderStyle = enum {
    none,
    single,
    double,
    rounded,
    thick,
    ascii,

    pub fn chars(self: BorderStyle) BorderChars {
        return switch (self) {
            .none => BorderChars{
                .top_left = ' ',
                .top_right = ' ',
                .bottom_left = ' ',
                .bottom_right = ' ',
                .horizontal = ' ',
                .vertical = ' ',
            },
            .single => BorderChars{
                .top_left = 0x250C, // ┌
                .top_right = 0x2510, // ┐
                .bottom_left = 0x2514, // └
                .bottom_right = 0x2518, // ┘
                .horizontal = 0x2500, // ─
                .vertical = 0x2502, // │
            },
            .double => BorderChars{
                .top_left = 0x2554, // ╔
                .top_right = 0x2557, // ╗
                .bottom_left = 0x255A, // ╚
                .bottom_right = 0x255D, // ╝
                .horizontal = 0x2550, // ═
                .vertical = 0x2551, // ║
            },
            .rounded => BorderChars{
                .top_left = 0x256D, // ╭
                .top_right = 0x256E, // ╮
                .bottom_left = 0x2570, // ╰
                .bottom_right = 0x256F, // ╯
                .horizontal = 0x2500, // ─
                .vertical = 0x2502, // │
            },
            .thick => BorderChars{
                .top_left = 0x250F, // ┏
                .top_right = 0x2513, // ┓
                .bottom_left = 0x2517, // ┗
                .bottom_right = 0x251B, // ┛
                .horizontal = 0x2501, // ━
                .vertical = 0x2503, // ┃
            },
            .ascii => BorderChars{
                .top_left = '+',
                .top_right = '+',
                .bottom_left = '+',
                .bottom_right = '+',
                .horizontal = '-',
                .vertical = '|',
            },
        };
    }
};

/// Renderer that handles double-buffering and efficient updates
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    term: *Terminal,
    front: Buffer,
    back: Buffer,

    pub fn init(allocator: std.mem.Allocator, term: *Terminal) !Renderer {
        const w = term.size.width;
        const h = term.size.height;

        return Renderer{
            .allocator = allocator,
            .term = term,
            .front = try Buffer.init(allocator, w, h),
            .back = try Buffer.init(allocator, w, h),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.front.deinit();
        self.back.deinit();
    }

    /// Get the back buffer for drawing
    pub fn buffer(self: *Renderer) *Buffer {
        return &self.back;
    }

    /// Get full screen rectangle
    pub fn area(self: *Renderer) Rect {
        return Rect{
            .x = 0,
            .y = 0,
            .width = self.back.width,
            .height = self.back.height,
        };
    }

    /// Clear back buffer
    pub fn clear(self: *Renderer) void {
        self.back.clear();
    }

    /// Render changes to terminal (differential update)
    pub fn render(self: *Renderer) void {
        var output_buf: [16384]u8 = undefined;
        var pos: usize = 0;

        var last_style: ?Style = null;
        var y: u16 = 0;

        while (y < self.back.height) : (y += 1) {
            var x: u16 = 0;
            while (x < self.back.width) : (x += 1) {
                const idx = @as(usize, y) * @as(usize, self.back.width) + @as(usize, x);
                const back_cell = self.back.cells[idx];
                const front_cell = self.front.cells[idx];

                // Skip if unchanged
                if (back_cell.eql(front_cell)) continue;

                // Move cursor
                const move_seq = terminal.Escape.moveTo(output_buf[pos..], y + 1, x + 1);
                pos += move_seq.len;

                // Update style if changed
                if (last_style == null or !styleEql(last_style.?, back_cell.style)) {
                    pos += writeStyle(output_buf[pos..], back_cell.style);
                    last_style = back_cell.style;
                }

                // Write character (UTF-8 encode)
                pos += writeUtf8(output_buf[pos..], back_cell.char);

                // Flush if buffer getting full
                if (pos > output_buf.len - 256) {
                    self.term.write(output_buf[0..pos]);
                    pos = 0;
                }
            }
        }

        // Reset style and flush
        if (pos + terminal.Escape.reset.len < output_buf.len) {
            @memcpy(output_buf[pos .. pos + terminal.Escape.reset.len], terminal.Escape.reset);
            pos += terminal.Escape.reset.len;
        }

        if (pos > 0) {
            self.term.write(output_buf[0..pos]);
        }

        // Swap buffers
        std.mem.swap(Buffer, &self.front, &self.back);
    }

    /// Force full redraw (useful after resize)
    pub fn forceRedraw(self: *Renderer) void {
        // Clear front buffer to force full redraw
        @memset(self.front.cells, Cell{ .char = 0, .style = Style.default });
        self.render();
    }

    /// Handle resize
    pub fn handleResize(self: *Renderer) !void {
        self.term.refreshSize();
        const w = self.term.size.width;
        const h = self.term.size.height;

        try self.front.resize(w, h);
        try self.back.resize(w, h);

        self.term.clear();
    }
};

// Helper functions
fn styleEql(a: Style, b: Style) bool {
    return a.fg == b.fg and a.bg == b.bg and
        a.bold == b.bold and a.underline == b.underline and
        a.reverse == b.reverse;
}

fn writeStyle(buf: []u8, style: Style) usize {
    var pos: usize = 0;

    // Write reset
    const reset = terminal.Escape.reset;
    @memcpy(buf[pos .. pos + reset.len], reset);
    pos += reset.len;

    // Write foreground
    if (style.fg) |fg| {
        const seq = terminal.Escape.fg(buf[pos..], fg);
        pos += seq.len;
    }

    // Write background
    if (style.bg) |bg| {
        const seq = terminal.Escape.bg(buf[pos..], bg);
        pos += seq.len;
    }

    // Write modifiers
    if (style.bold) {
        const bold = terminal.Escape.bold;
        @memcpy(buf[pos .. pos + bold.len], bold);
        pos += bold.len;
    }
    if (style.underline) {
        const ul = terminal.Escape.underline;
        @memcpy(buf[pos .. pos + ul.len], ul);
        pos += ul.len;
    }
    if (style.reverse) {
        const rev = terminal.Escape.reverse;
        @memcpy(buf[pos .. pos + rev.len], rev);
        pos += rev.len;
    }

    return pos;
}

fn writeUtf8(buf: []u8, codepoint: u21) usize {
    if (codepoint < 0x80) {
        buf[0] = @intCast(codepoint);
        return 1;
    } else if (codepoint < 0x800) {
        buf[0] = @intCast(0xC0 | (codepoint >> 6));
        buf[1] = @intCast(0x80 | (codepoint & 0x3F));
        return 2;
    } else if (codepoint < 0x10000) {
        buf[0] = @intCast(0xE0 | (codepoint >> 12));
        buf[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (codepoint & 0x3F));
        return 3;
    } else {
        buf[0] = @intCast(0xF0 | (codepoint >> 18));
        buf[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3F));
        buf[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        buf[3] = @intCast(0x80 | (codepoint & 0x3F));
        return 4;
    }
}

// Tests
test "buffer operations" {
    const allocator = std.testing.allocator;

    var buf = try Buffer.init(allocator, 10, 5);
    defer buf.deinit();

    buf.setChar(0, 0, 'A', Style.default);
    const cell = buf.get(0, 0).?;
    try std.testing.expect(cell.char == 'A');

    buf.drawString(0, 1, "Hello", Style.default);
    try std.testing.expect(buf.get(0, 1).?.char == 'H');
    try std.testing.expect(buf.get(4, 1).?.char == 'o');
}

test "rect operations" {
    const rect = Rect{ .x = 5, .y = 5, .width = 10, .height = 10 };

    try std.testing.expect(rect.contains(5, 5));
    try std.testing.expect(rect.contains(14, 14));
    try std.testing.expect(!rect.contains(15, 15));

    const inner = rect.inner(1);
    try std.testing.expect(inner.x == 6);
    try std.testing.expect(inner.y == 6);
    try std.testing.expect(inner.width == 8);
    try std.testing.expect(inner.height == 8);
}

test "utf8 encoding" {
    var buf: [4]u8 = undefined;

    // ASCII
    try std.testing.expect(writeUtf8(&buf, 'A') == 1);
    try std.testing.expect(buf[0] == 'A');

    // 2-byte
    try std.testing.expect(writeUtf8(&buf, 0x00E9) == 2); // é
}
