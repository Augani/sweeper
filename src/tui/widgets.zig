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

/// Gauge widget for displaying a metric with visual bar
pub const Gauge = struct {
    value: u64 = 0,
    max_value: u64 = 100,
    label: []const u8 = "",
    unit: []const u8 = "",
    show_value: bool = true,
    show_percentage: bool = true,
    style: Style = Style.default,
    bar_style: Style = Style.default.withFg(.cyan),
    height: u16 = 1,

    pub fn draw(self: Gauge, buf: *Buffer, rect: Rect) void {
        if (rect.height < 1) return;

        var y_offset: u16 = 0;

        // Draw label if present
        if (self.label.len > 0) {
            buf.drawStringMax(rect.x, rect.y, self.label, rect.width, self.style.withBold());
            y_offset += 1;
            if (y_offset >= rect.height) return;
        }

        // Calculate percentage
        const percentage = if (self.max_value > 0)
            @as(f32, @floatFromInt(self.value)) / @as(f32, @floatFromInt(self.max_value))
        else
            0.0;

        const clamped_pct = @min(1.0, @max(0.0, percentage));

        // Draw progress bar
        const bar_width = rect.width -| 2;
        if (bar_width > 0) {
            const filled = @as(u16, @intFromFloat(@as(f32, @floatFromInt(bar_width)) * clamped_pct));

            buf.setChar(rect.x, rect.y + y_offset, '[', self.style);
            var x: u16 = 0;
            while (x < bar_width) : (x += 1) {
                const char: u21 = if (x < filled) 0x2588 else 0x2591; // █ or ░
                buf.setChar(rect.x + 1 + x, rect.y + y_offset, char, self.bar_style);
            }
            buf.setChar(rect.x + 1 + bar_width, rect.y + y_offset, ']', self.style);
            y_offset += 1;
        }

        // Draw value and percentage
        if ((self.show_value or self.show_percentage) and y_offset < rect.height) {
            var info_buf: [64]u8 = undefined;
            var info_text: []const u8 = "";

            if (self.show_value and self.show_percentage) {
                info_text = std.fmt.bufPrint(&info_buf, "{d} {s} ({d:.1}%)", .{
                    self.value,
                    self.unit,
                    clamped_pct * 100.0,
                }) catch "";
            } else if (self.show_value) {
                info_text = std.fmt.bufPrint(&info_buf, "{d} {s}", .{ self.value, self.unit }) catch "";
            } else if (self.show_percentage) {
                info_text = std.fmt.bufPrint(&info_buf, "{d:.1}%", .{clamped_pct * 100.0}) catch "";
            }

            if (info_text.len > 0) {
                const x_pos = rect.x + (rect.width - @as(u16, @intCast(@min(info_text.len, rect.width)))) / 2;
                buf.drawStringMax(x_pos, rect.y + y_offset, info_text, rect.width, self.style);
            }
        }
    }
};

/// Sparkline widget for showing trends in compact form
pub const Sparkline = struct {
    data: []const u64,
    max_value: ?u64 = null,
    style: Style = Style.default.withFg(.green),
    chars: []const u21 = &[_]u21{ 0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588 }, // ▁▂▃▄▅▆▇█

    pub fn draw(self: Sparkline, buf: *Buffer, rect: Rect) void {
        if (rect.width == 0 or self.data.len == 0) return;

        // Determine max value
        var max: u64 = self.max_value orelse blk: {
            var m: u64 = 0;
            for (self.data) |v| {
                if (v > m) m = v;
            }
            break :blk m;
        };

        if (max == 0) max = 1;

        // Draw sparkline
        const samples_to_show = @min(self.data.len, rect.width);
        const start_idx = if (self.data.len > rect.width) self.data.len - rect.width else 0;

        var x: u16 = 0;
        for (self.data[start_idx..][0..samples_to_show]) |value| {
            const ratio = @as(f32, @floatFromInt(value)) / @as(f32, @floatFromInt(max));
            const char_idx = @as(usize, @intFromFloat(ratio * @as(f32, @floatFromInt(self.chars.len - 1))));
            const char = self.chars[@min(char_idx, self.chars.len - 1)];

            buf.setChar(rect.x + x, rect.y, char, self.style);
            x += 1;
        }
    }
};

/// Multi-progress widget for showing multiple concurrent operations
pub const MultiProgress = struct {
    items: []const ProgressItem,
    show_labels: bool = true,
    compact: bool = false,

    pub const ProgressItem = struct {
        label: []const u8,
        progress: f32,
        style: Style = Style.default.withFg(.cyan),
    };

    pub fn draw(self: MultiProgress, buf: *Buffer, rect: Rect) void {
        if (rect.height == 0 or self.items.len == 0) return;

        const row_height: u16 = if (self.compact) 1 else 2;
        var y: u16 = 0;

        for (self.items) |item| {
            if (y >= rect.height) break;

            const item_rect = Rect{
                .x = rect.x,
                .y = rect.y + y,
                .width = rect.width,
                .height = @min(row_height, rect.height - y),
            };

            var progress_bar = ProgressBar{
                .progress = item.progress,
                .label = if (self.show_labels) item.label else null,
                .filled_style = item.style,
            };

            progress_bar.draw(buf, item_rect);
            y += row_height;
        }
    }
};

/// Size chart widget for visualizing space usage
pub const SizeChart = struct {
    segments: []const Segment,
    total: u64 = 0,
    show_legend: bool = true,
    height: u16 = 3,

    pub const Segment = struct {
        label: []const u8,
        value: u64,
        style: Style,
    };

    pub fn draw(self: SizeChart, buf: *Buffer, rect: Rect) void {
        if (rect.width < 10 or rect.height < 2 or self.segments.len == 0) return;

        var total = self.total;
        if (total == 0) {
            for (self.segments) |seg| {
                total += seg.value;
            }
        }

        if (total == 0) return;

        var y: u16 = 0;

        // Draw the bar chart
        const bar_width = rect.width;
        var x_offset: u16 = 0;

        for (self.segments) |seg| {
            const seg_width = @as(u16, @intFromFloat(@as(f32, @floatFromInt(seg.value)) / @as(f32, @floatFromInt(total)) * @as(f32, @floatFromInt(bar_width))));

            if (seg_width > 0 and x_offset < bar_width) {
                const actual_width = @min(seg_width, bar_width - x_offset);
                var sx: u16 = 0;
                while (sx < actual_width) : (sx += 1) {
                    buf.setChar(rect.x + x_offset + sx, rect.y + y, 0x2588, seg.style); // █
                }
                x_offset += actual_width;
            }
        }
        y += 1;

        // Draw legend if enabled
        if (self.show_legend and y < rect.height) {
            y += 1; // Spacing

            for (self.segments) |seg| {
                if (y >= rect.height) break;

                const pct = @as(f32, @floatFromInt(seg.value)) / @as(f32, @floatFromInt(total)) * 100.0;
                var legend_buf: [64]u8 = undefined;
                const legend = std.fmt.bufPrint(&legend_buf, "{s}: {d:.1}%", .{ seg.label, pct }) catch "";

                buf.setChar(rect.x, rect.y + y, 0x25A0, seg.style); // ■
                buf.drawStringMax(rect.x + 2, rect.y + y, legend, rect.width - 2, Style.default);
                y += 1;
            }
        }
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
