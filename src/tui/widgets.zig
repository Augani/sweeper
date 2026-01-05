const std = @import("std");
const render = @import("render.zig");
const terminal = @import("terminal.zig");

const Buffer = render.Buffer;
const Rect = render.Rect;
const Style = terminal.Style;
const Color = terminal.Color;
const BorderStyle = render.BorderStyle;

/// Progress bar widget
pub const ProgressBar = struct {
    progress: f32 = 0.0,
    label: ?[]const u8 = null,
    show_percentage: bool = true,
    filled_char: u21 = 0x2588, // █
    empty_char: u21 = 0x2591, // ░
    filled_style: Style = Style.default.withFg(.green),
    empty_style: Style = Style.default.withFg(.white),

    pub fn draw(self: ProgressBar, buf: *Buffer, rect: Rect) void {
        if (rect.width < 3 or rect.height < 1) return;

        var available_width = rect.width;

        // Draw label if present
        var label_offset: u16 = 0;
        if (self.label) |label| {
            const label_len = @min(label.len, @as(usize, rect.width / 3));
            buf.drawStringMax(rect.x, rect.y, label, @intCast(label_len), Style.default);
            label_offset = @intCast(label_len + 1);
            available_width -= label_offset;
        }

        // Calculate percentage text
        var pct_text: [5]u8 = undefined;
        var pct_len: usize = 0;
        if (self.show_percentage) {
            const pct: u8 = @intFromFloat(self.progress * 100);
            const formatted = std.fmt.bufPrint(&pct_text, "{d}%", .{pct}) catch &pct_text;
            pct_len = formatted.len;
            available_width -= @intCast(pct_len + 1);
        }

        // Draw progress bar
        const filled_width = @as(u16, @intFromFloat(@as(f32, @floatFromInt(available_width)) * self.progress));

        var x: u16 = 0;
        while (x < available_width) : (x += 1) {
            if (x < filled_width) {
                buf.setChar(rect.x + label_offset + x, rect.y, self.filled_char, self.filled_style);
            } else {
                buf.setChar(rect.x + label_offset + x, rect.y, self.empty_char, self.empty_style);
            }
        }

        // Draw percentage
        if (self.show_percentage) {
            buf.drawStringMax(rect.x + label_offset + available_width + 1, rect.y, &pct_text, @intCast(pct_len), Style.default);
        }
    }
};

/// Text widget with wrapping support
pub const Text = struct {
    content: []const u8,
    style: Style = Style.default,
    alignment: Alignment = .left,

    pub const Alignment = enum { left, center, right };

    pub fn draw(self: Text, buf: *Buffer, rect: Rect) void {
        if (rect.width == 0 or rect.height == 0) return;

        const text_len = @min(self.content.len, @as(usize, rect.width));
        var start_x = rect.x;

        switch (self.alignment) {
            .left => {},
            .center => {
                start_x = rect.x + (rect.width - @as(u16, @intCast(text_len))) / 2;
            },
            .right => {
                start_x = rect.x + rect.width - @as(u16, @intCast(text_len));
            },
        }

        buf.drawStringMax(start_x, rect.y, self.content, @intCast(text_len), self.style);
    }
};

/// List widget for displaying selectable items
pub const List = struct {
    items: []const []const u8,
    selected: usize = 0,
    scroll_offset: usize = 0,
    style: Style = Style.default,
    selected_style: Style = Style.default.withReverse(),
    show_scroll_indicator: bool = true,

    pub fn draw(self: *List, buf: *Buffer, rect: Rect) void {
        if (rect.width == 0 or rect.height == 0 or self.items.len == 0) return;

        const visible_items = @min(self.items.len - self.scroll_offset, rect.height);

        var y: u16 = 0;
        while (y < visible_items) : (y += 1) {
            const idx = self.scroll_offset + y;
            const is_selected = idx == self.selected;
            const item_style = if (is_selected) self.selected_style else self.style;

            // Clear line
            buf.drawHLine(rect.x, rect.y + y, rect.width, ' ', item_style);

            // Draw prefix
            const prefix: []const u8 = if (is_selected) "> " else "  ";
            buf.drawString(rect.x, rect.y + y, prefix, item_style);

            // Draw item text (truncated if needed)
            const max_text_len = rect.width - 2;
            if (idx < self.items.len) {
                buf.drawStringMax(rect.x + 2, rect.y + y, self.items[idx], max_text_len, item_style);
            }
        }

        // Draw scroll indicators
        if (self.show_scroll_indicator and self.items.len > rect.height) {
            if (self.scroll_offset > 0) {
                buf.setChar(rect.x + rect.width - 1, rect.y, 0x25B2, Style.default.withFg(.cyan)); // ▲
            }
            if (self.scroll_offset + rect.height < self.items.len) {
                buf.setChar(rect.x + rect.width - 1, rect.y + rect.height - 1, 0x25BC, Style.default.withFg(.cyan)); // ▼
            }
        }
    }

    pub fn selectNext(self: *List) void {
        if (self.items.len == 0) return;
        if (self.selected < self.items.len - 1) {
            self.selected += 1;
        }
    }

    pub fn selectPrev(self: *List) void {
        if (self.selected > 0) {
            self.selected -= 1;
        }
    }

    pub fn ensureVisible(self: *List, height: u16) void {
        if (self.selected < self.scroll_offset) {
            self.scroll_offset = self.selected;
        } else if (self.selected >= self.scroll_offset + height) {
            self.scroll_offset = self.selected - height + 1;
        }
    }
};

/// Table widget for displaying tabular data
pub const Table = struct {
    headers: []const []const u8,
    rows: []const []const []const u8,
    col_widths: []const u16,
    selected_row: ?usize = null,
    scroll_offset: usize = 0,
    header_style: Style = Style.default.withBold(),
    row_style: Style = Style.default,
    selected_style: Style = Style.default.withReverse(),
    show_header: bool = true,

    pub fn draw(self: Table, buf: *Buffer, rect: Rect) void {
        if (rect.width == 0 or rect.height == 0) return;

        var y: u16 = 0;

        // Draw header
        if (self.show_header and y < rect.height) {
            self.drawRow(buf, rect.x, rect.y + y, self.headers, rect.width, self.header_style);
            y += 1;

            // Draw separator
            if (y < rect.height) {
                buf.drawHLine(rect.x, rect.y + y, rect.width, 0x2500, self.header_style); // ─
                y += 1;
            }
        }

        // Draw rows
        const remaining_height = rect.height - y;
        const visible_rows = @min(self.rows.len - self.scroll_offset, remaining_height);

        var row_idx: usize = 0;
        while (row_idx < visible_rows) : (row_idx += 1) {
            const actual_idx = self.scroll_offset + row_idx;
            const is_selected = self.selected_row != null and actual_idx == self.selected_row.?;
            const style = if (is_selected) self.selected_style else self.row_style;

            if (actual_idx < self.rows.len) {
                self.drawRow(buf, rect.x, rect.y + y, self.rows[actual_idx], rect.width, style);
            }
            y += 1;
        }
    }

    fn drawRow(self: Table, buf: *Buffer, x: u16, y: u16, cells: []const []const u8, max_width: u16, style: Style) void {
        var col_x = x;

        for (cells, 0..) |cell, i| {
            if (col_x >= x + max_width) break;

            const col_width = if (i < self.col_widths.len) self.col_widths[i] else 10;
            const available = @min(col_width, x + max_width - col_x);

            buf.drawStringMax(col_x, y, cell, available, style);
            col_x += col_width + 1; // +1 for separator space
        }
    }
};

/// Panel widget with border and title
pub const Panel = struct {
    title: ?[]const u8 = null,
    border: BorderStyle = .single,
    border_style: Style = Style.default,
    title_style: Style = Style.default.withBold(),

    pub fn draw(self: Panel, buf: *Buffer, rect: Rect) void {
        if (rect.width < 2 or rect.height < 2) return;

        // Draw border
        buf.drawBox(rect, self.border_style, self.border);

        // Draw title if present
        if (self.title) |title| {
            const max_title_len = rect.width - 4;
            if (max_title_len > 0) {
                const title_len = @min(title.len, @as(usize, max_title_len));
                buf.setChar(rect.x + 1, rect.y, ' ', self.border_style);
                buf.drawStringMax(rect.x + 2, rect.y, title, @intCast(title_len), self.title_style);
                buf.setChar(rect.x + 2 + @as(u16, @intCast(title_len)), rect.y, ' ', self.border_style);
            }
        }
    }

    /// Get the inner content area
    pub fn innerRect(self: Panel, rect: Rect) Rect {
        _ = self;
        return rect.inner(1);
    }
};

/// Tabs widget for navigation
pub const Tabs = struct {
    labels: []const []const u8,
    active: usize = 0,
    style: Style = Style.default,
    active_style: Style = Style.default.withBold().withUnderline(),

    pub fn draw(self: Tabs, buf: *Buffer, rect: Rect) void {
        if (rect.width == 0 or self.labels.len == 0) return;

        var x = rect.x;

        for (self.labels, 0..) |label, i| {
            if (x >= rect.x + rect.width) break;

            const is_active = i == self.active;
            const tab_style = if (is_active) self.active_style else self.style;

            // Draw tab
            buf.setChar(x, rect.y, '[', tab_style);
            x += 1;

            const label_len = @min(label.len, @as(usize, rect.x + rect.width - x - 2));
            buf.drawStringMax(x, rect.y, label, @intCast(label_len), tab_style);
            x += @intCast(label_len);

            buf.setChar(x, rect.y, ']', tab_style);
            x += 2; // ] + space
        }
    }

    pub fn nextTab(self: *Tabs) void {
        if (self.labels.len == 0) return;
        self.active = (self.active + 1) % self.labels.len;
    }

    pub fn prevTab(self: *Tabs) void {
        if (self.labels.len == 0) return;
        if (self.active == 0) {
            self.active = self.labels.len - 1;
        } else {
            self.active -= 1;
        }
    }
};

/// Status bar widget
pub const StatusBar = struct {
    left_text: []const u8 = "",
    center_text: []const u8 = "",
    right_text: []const u8 = "",
    style: Style = Style.default.withReverse(),

    pub fn draw(self: StatusBar, buf: *Buffer, rect: Rect) void {
        if (rect.width == 0 or rect.height == 0) return;

        // Fill background
        buf.drawHLine(rect.x, rect.y, rect.width, ' ', self.style);

        // Left text
        if (self.left_text.len > 0) {
            const max_len = rect.width / 3;
            buf.drawStringMax(rect.x + 1, rect.y, self.left_text, max_len, self.style);
        }

        // Center text
        if (self.center_text.len > 0) {
            const center_len = @min(self.center_text.len, @as(usize, rect.width / 3));
            const center_x = rect.x + (rect.width - @as(u16, @intCast(center_len))) / 2;
            buf.drawStringMax(center_x, rect.y, self.center_text, @intCast(center_len), self.style);
        }

        // Right text
        if (self.right_text.len > 0) {
            const right_len = @min(self.right_text.len, @as(usize, rect.width / 3));
            const right_x = rect.x + rect.width - @as(u16, @intCast(right_len)) - 1;
            buf.drawStringMax(right_x, rect.y, self.right_text, @intCast(right_len), self.style);
        }
    }
};

/// Checkbox widget
pub const Checkbox = struct {
    label: []const u8,
    checked: bool = false,
    style: Style = Style.default,
    checked_char: u21 = 0x2713, // ✓
    unchecked_char: u21 = ' ',

    pub fn draw(self: Checkbox, buf: *Buffer, x: u16, y: u16) void {
        buf.setChar(x, y, '[', self.style);
        buf.setChar(x + 1, y, if (self.checked) self.checked_char else self.unchecked_char, self.style.withFg(.green));
        buf.setChar(x + 2, y, ']', self.style);
        buf.drawString(x + 4, y, self.label, self.style);
    }

    pub fn toggle(self: *Checkbox) void {
        self.checked = !self.checked;
    }
};

/// Spinner widget for loading indication
pub const Spinner = struct {
    frame: u8 = 0,
    style: Style = Style.default.withFg(.cyan),
    frames: []const u21 = &[_]u21{ 0x25CF, 0x25CB, 0x25CF, 0x25CB }, // ●○●○

    pub fn draw(self: Spinner, buf: *Buffer, x: u16, y: u16) void {
        const char = self.frames[self.frame % self.frames.len];
        buf.setChar(x, y, char, self.style);
    }

    pub fn tick(self: *Spinner) void {
        self.frame +%= 1;
    }
};

// Tests
test "progress bar" {
    const allocator = std.testing.allocator;
    var buf = try render.Buffer.init(allocator, 40, 1);
    defer buf.deinit();

    var progress = ProgressBar{ .progress = 0.5 };
    progress.draw(&buf, Rect{ .x = 0, .y = 0, .width = 40, .height = 1 });
}

test "list navigation" {
    const items = [_][]const u8{ "Item 1", "Item 2", "Item 3" };
    var list = List{
        .items = &items,
        .selected = 0,
    };

    list.selectNext();
    try std.testing.expect(list.selected == 1);

    list.selectPrev();
    try std.testing.expect(list.selected == 0);
}

test "tabs navigation" {
    const labels = [_][]const u8{ "Tab1", "Tab2", "Tab3" };
    var tabs = Tabs{
        .labels = &labels,
        .active = 0,
    };

    tabs.nextTab();
    try std.testing.expect(tabs.active == 1);

    tabs.prevTab();
    try std.testing.expect(tabs.active == 0);

    tabs.prevTab();
    try std.testing.expect(tabs.active == 2); // Wraps around
}

test "checkbox toggle" {
    var checkbox = Checkbox{
        .label = "Test",
        .checked = false,
    };

    checkbox.toggle();
    try std.testing.expect(checkbox.checked);

    checkbox.toggle();
    try std.testing.expect(!checkbox.checked);
}
