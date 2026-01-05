//! GUI Widgets for Desktop Cleanup
//!
//! Reusable UI components built with raylib

const std = @import("std");
const rl = @import("raylib");
const theme = @import("theme.zig");
const analyzer = @import("../analyzer.zig");

/// Check if mouse is within a rectangle
pub fn isMouseOver(x: i32, y: i32, w: i32, h: i32) bool {
    const mx = rl.getMouseX();
    const my = rl.getMouseY();
    return mx >= x and mx < x + w and my >= y and my < y + h;
}

/// Helper to draw text with a specific font
fn drawTextWithFont(font: rl.Font, text: [:0]const u8, x: i32, y: i32, fontSize: f32, color: rl.Color) void {
    const position = rl.Vector2{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    if (theme.fonts_initialized) {
        rl.drawTextEx(font, text, position, fontSize, 1.0, color);
    } else {
        rl.drawText(text, x, y, @intFromFloat(fontSize), color);
    }
}

/// Helper to measure text with a specific font
fn measureTextWithFont(font: rl.Font, text: [:0]const u8, fontSize: f32) f32 {
    if (theme.fonts_initialized) {
        const size = rl.measureTextEx(font, text, fontSize, 1.0);
        return size.x;
    } else {
        return @floatFromInt(rl.measureText(text, @intFromFloat(fontSize)));
    }
}

/// Draw text with Regular weight
pub fn drawLabel(text: [:0]const u8, x: i32, y: i32, fontSize: f32, color: rl.Color) void {
    drawTextWithFont(theme.font_regular, text, x, y, fontSize, color);
}

/// Draw text with SemiBold weight
pub fn drawStrong(text: [:0]const u8, x: i32, y: i32, fontSize: f32, color: rl.Color) void {
    drawTextWithFont(theme.font_semibold, text, x, y, fontSize, color);
}

/// Draw text with Bold weight
pub fn drawTitle(text: [:0]const u8, x: i32, y: i32, fontSize: f32, color: rl.Color) void {
    drawTextWithFont(theme.font_bold, text, x, y, fontSize, color);
}

/// Measure text (Regular)
pub fn measureTextEx(text: [:0]const u8, fontSize: f32) f32 {
    return measureTextWithFont(theme.font_regular, text, fontSize);
}

/// Measure text (SemiBold)
pub fn measureTextStrong(text: [:0]const u8, fontSize: f32) f32 {
    return measureTextWithFont(theme.font_semibold, text, fontSize);
}

/// Measure text (Bold)
pub fn measureTextTitle(text: [:0]const u8, fontSize: f32) f32 {
    return measureTextWithFont(theme.font_bold, text, fontSize);
}

/// Draw a rounded card background
pub fn drawCard(x: i32, y: i32, w: i32, h: i32) void {
    const rec = rl.Rectangle{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = @floatFromInt(w),
        .height = @floatFromInt(h)
    };
    rl.drawRectangleRounded(rec, theme.dimensions.border_radius / @as(f32, @floatFromInt(@min(w, h))), 10, theme.colors.card_bg);
}

/// Draw a donut chart
pub const ChartSegment = struct {
    value: f32,
    color: rl.Color,
    label: [:0]const u8,
};

pub fn drawDonutChart(x: i32, y: i32, radius: f32, thickness: f32, segments: []const ChartSegment) void {
    const center = rl.Vector2{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
    var start_angle: f32 = 0.0;
    
    // Calculate total for normalization
    var total: f32 = 0.0;
    for (segments) |seg| {
        total += seg.value;
    }

    if (total <= 0.001) {
         // Draw empty ring
        rl.drawRing(center, radius - thickness, radius, 0, 360, 36, theme.colors.surface_hover);
        return;
    }

    // Draw segments
    for (segments) |seg| {
        const sweep = (seg.value / total) * 360.0;
        if (sweep > 0) {
            rl.drawRing(center, radius - thickness, radius, start_angle, start_angle + sweep - 2.0, 36, seg.color);
            start_angle += sweep;
        }
    }
}

/// Draw Sidebar Item with custom icon
pub fn drawSidebarItem(label: [:0]const u8, icon_type: [:0]const u8, x: i32, y: i32, w: i32, h: i32, active: bool) bool {
    const hovered = isMouseOver(x, y, w, h);
    const clicked = hovered and rl.isMouseButtonReleased(.left);

    // Background (if active or hovered)
    if (active or hovered) {
        const color = if (active) theme.colors.surface_active else theme.colors.surface_hover;
        const rec = rl.Rectangle{
             .x = @floatFromInt(x + theme.spacing.sm),
             .y = @floatFromInt(y),
             .width = @floatFromInt(w - theme.spacing.md),
             .height = @floatFromInt(h)
        };
        rl.drawRectangleRounded(rec, 0.5, 6, color);
    }

    // Draw icon based on type
    const icon_color = if (active) theme.colors.accent else theme.colors.text_muted;
    const icon_x = x + theme.spacing.lg + 8;
    const icon_y = y + @divTrunc(h, 2);
    drawSidebarIcon(icon_type, icon_x, icon_y, icon_color);

    // Label
    const text_color = if (active) theme.colors.text_primary else theme.colors.text_secondary;
    const label_y = y + @divTrunc(h - @as(i32, @intFromFloat(theme.fonts.body)), 2);

    if (active) {
        drawStrong(label, x + theme.spacing.xl + 24, label_y, theme.fonts.body, text_color);
    } else {
        drawLabel(label, x + theme.spacing.xl + 24, label_y, theme.fonts.body, text_color);
    }

    return clicked;
}

/// Draw sidebar icon shapes
fn drawSidebarIcon(icon_type: [:0]const u8, cx: i32, cy: i32, color: rl.Color) void {
    const s: i32 = 8; // Icon half-size

    if (std.mem.eql(u8, icon_type, "A")) {
        // All Files: 2x2 grid
        rl.drawRectangle(cx - s, cy - s, s - 2, s - 2, color);
        rl.drawRectangle(cx + 2, cy - s, s - 2, s - 2, color);
        rl.drawRectangle(cx - s, cy + 2, s - 2, s - 2, color);
        rl.drawRectangle(cx + 2, cy + 2, s - 2, s - 2, color);
    } else if (std.mem.eql(u8, icon_type, "L")) {
        // Largest: Bar chart
        rl.drawRectangle(cx - s, cy + 2, 4, s - 2, color);
        rl.drawRectangle(cx - 3, cy - 4, 4, s + 4, color);
        rl.drawRectangle(cx + 4, cy - s, 4, s * 2, color);
    } else if (std.mem.eql(u8, icon_type, "C")) {
        // Cache: Database cylinder
        const fx: f32 = @floatFromInt(cx);
        rl.drawEllipse(cx, cy - s + 3, @as(f32, @floatFromInt(s)), 4, color);
        rl.drawRectangle(cx - s, cy - s + 3, s * 2, s + 4, color);
        rl.drawEllipse(cx, cy + 7, @as(f32, @floatFromInt(s)), 4, color);
        // Horizontal lines
        rl.drawLine(@intFromFloat(fx - 7), cy - 2, @intFromFloat(fx + 7), cy - 2, color);
        rl.drawLine(@intFromFloat(fx - 7), cy + 3, @intFromFloat(fx + 7), cy + 3, color);
    } else if (std.mem.eql(u8, icon_type, "D")) {
        // Dev: Code brackets < >
        const fx: f32 = @floatFromInt(cx);
        const fy: f32 = @floatFromInt(cy);
        const sf: f32 = @floatFromInt(s);
        // Left bracket <
        rl.drawLineEx(.{ .x = fx - 3, .y = fy - sf }, .{ .x = fx - sf, .y = fy }, 2, color);
        rl.drawLineEx(.{ .x = fx - sf, .y = fy }, .{ .x = fx - 3, .y = fy + sf }, 2, color);
        // Right bracket >
        rl.drawLineEx(.{ .x = fx + 3, .y = fy - sf }, .{ .x = fx + sf, .y = fy }, 2, color);
        rl.drawLineEx(.{ .x = fx + sf, .y = fy }, .{ .x = fx + 3, .y = fy + sf }, 2, color);
    } else if (std.mem.eql(u8, icon_type, "T")) {
        // Temp: Clock/timer
        rl.drawCircleLines(cx, cy, @as(f32, @floatFromInt(s)), color);
        const fx: f32 = @floatFromInt(cx);
        const fy: f32 = @floatFromInt(cy);
        // Clock hands
        rl.drawLineEx(.{ .x = fx, .y = fy }, .{ .x = fx, .y = fy - 5 }, 2, color);
        rl.drawLineEx(.{ .x = fx, .y = fy }, .{ .x = fx + 4, .y = fy + 2 }, 2, color);
    }
}

/// Draw a button and return true if clicked
pub fn drawButton(text: [:0]const u8, x: i32, y: i32, w: i32, h: i32, style: theme.ButtonStyle) bool {
    const hovered = isMouseOver(x, y, w, h);
    const pressed = hovered and rl.isMouseButtonDown(.left);
    const clicked = hovered and rl.isMouseButtonReleased(.left);

    // Background
    const bg_color = if (pressed) style.bg_active else if (hovered) style.bg_hover else style.bg;
    
    const rec = rl.Rectangle{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = @floatFromInt(w),
        .height = @floatFromInt(h)
    };
    
    rl.drawRectangleRounded(rec, theme.dimensions.button_radius / @as(f32, @floatFromInt(@min(w, h))), 8, bg_color);

    // Text (centered) - Buttons usually use SemiBold
    const text_measured = measureTextStrong(text, theme.fonts.body);
    const text_x = x + @divTrunc(w - @as(i32, @intFromFloat(text_measured)), 2);
    const text_y = y + @divTrunc(h - @as(i32, @intFromFloat(theme.fonts.body)), 2);
    
    drawStrong(text, text_x, text_y, theme.fonts.body, style.text);

    return clicked;
}

/// Draw icon-only button (circular/square)
pub fn drawIconButton(icon: [:0]const u8, x: i32, y: i32, size: i32, color: rl.Color) bool {
    const hovered = isMouseOver(x, y, size, size);
    const clicked = hovered and rl.isMouseButtonReleased(.left);
    
    const rec = rl.Rectangle{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = @floatFromInt(size),
        .height = @floatFromInt(size)
    };
    
    if (hovered) {
        rl.drawRectangleRounded(rec, 0.5, 6, theme.colors.surface_hover);
    }
    
    // Icon usually fits best with Regular or similar, Heading size
    const text_w = measureTextEx(icon, theme.fonts.heading);
    const text_x = x + @divTrunc(size - @as(i32, @intFromFloat(text_w)), 2);
    const text_y = y + @divTrunc(size - @as(i32, @intFromFloat(theme.fonts.heading)), 2);
    
    drawLabel(icon, text_x, text_y, theme.fonts.heading, color);
    
    return clicked;
}

/// Draw a checkbox and return true if clicked
pub fn drawCheckbox(checked: bool, x: i32, y: i32) bool {
    const size: i32 = 22;
    const hovered = isMouseOver(x, y, size, size);
    const clicked = hovered and rl.isMouseButtonReleased(.left);

    const rec = rl.Rectangle{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = @floatFromInt(size),
        .height = @floatFromInt(size),
    };

    // Box background
    const bg_color = if (checked) theme.colors.success else theme.colors.surface_hover;
    rl.drawRectangleRounded(rec, 0.3, 4, bg_color);

    // Border
    const border_color = if (hovered) theme.colors.accent else if (checked) theme.colors.success else theme.colors.border;
    rl.drawRectangleRoundedLines(rec, 0.3, 4, border_color);

    // Checkmark
    if (checked) {
        const cx = @as(f32, @floatFromInt(x));
        const cy = @as(f32, @floatFromInt(y));
        const s = @as(f32, @floatFromInt(size));
        // Draw checkmark lines
        rl.drawLineEx(
            .{ .x = cx + s * 0.2, .y = cy + s * 0.5 },
            .{ .x = cx + s * 0.4, .y = cy + s * 0.7 },
            2.5,
            theme.colors.text_primary,
        );
        rl.drawLineEx(
            .{ .x = cx + s * 0.4, .y = cy + s * 0.7 },
            .{ .x = cx + s * 0.8, .y = cy + s * 0.3 },
            2.5,
            theme.colors.text_primary,
        );
    }

    return clicked;
}

/// Draw a progress bar
pub fn drawProgressBar(progress: f32, x: i32, y: i32, w: i32, h: i32) void {
    const rec_bg = rl.Rectangle{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = @floatFromInt(w),
        .height = @floatFromInt(h)
    };

    // Background
    rl.drawRectangleRounded(rec_bg, 1.0, 8, theme.colors.surface_active);

    // Progress fill
    const fill_width = @as(f32, @floatFromInt(w)) * std.math.clamp(progress, 0.0, 1.0);
    if (fill_width > 0) {
        const rec_fill = rl.Rectangle{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .width = fill_width,
            .height = @floatFromInt(h)
        };
        rl.drawRectangleRounded(rec_fill, 1.0, 8, theme.colors.success); 
    }
}

/// Draw a scrollbar and return the new scroll offset if dragged
pub fn drawScrollbar(
    total_items: usize,
    visible_items: usize,
    scroll_offset: usize,
    x: i32,
    y: i32,
    h: i32,
    w: i32
) ?usize {
    if (total_items <= visible_items) return null;

    var result: ?usize = null;

    // Calculate thumb size and position
    const visible_ratio = @as(f32, @floatFromInt(visible_items)) / @as(f32, @floatFromInt(total_items));
    const thumb_height = @max(30, @as(i32, @intFromFloat(@as(f32, @floatFromInt(h)) * visible_ratio)));
    const max_scroll = total_items - visible_items;
    const scroll_ratio = @as(f32, @floatFromInt(scroll_offset)) / @as(f32, @floatFromInt(max_scroll));
    const track_space = h - thumb_height;
    const thumb_y = y + @as(i32, @intFromFloat(@as(f32, @floatFromInt(track_space)) * scroll_ratio));

    // Thumb
    const hovered = isMouseOver(x, thumb_y, w, thumb_height);
    const thumb_color = if (hovered) theme.colors.scrollbar_thumb_hover else theme.colors.scrollbar_thumb;
    
    const rec_thumb = rl.Rectangle{
        .x = @floatFromInt(x),
        .y = @floatFromInt(thumb_y),
        .width = @floatFromInt(w),
        .height = @floatFromInt(thumb_height)
    };
    
    rl.drawRectangleRounded(rec_thumb, 1.0, 4, thumb_color);

    // Handle click on track
    if (isMouseOver(x, y, w, h) and rl.isMouseButtonPressed(.left)) {
        const click_y = rl.getMouseY();
        const click_ratio = @as(f32, @floatFromInt(click_y - y)) / @as(f32, @floatFromInt(h));
        const new_scroll = @as(usize, @intFromFloat(click_ratio * @as(f32, @floatFromInt(max_scroll))));
        result = @min(new_scroll, max_scroll);
    }

    return result;
}

/// Helper to format and print size
pub fn formatSizeBuffer(size: u64, buf: *[32]u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var s: f64 = @floatFromInt(size);
    var unit_idx: usize = 0;

    while (s >= 1024 and unit_idx < units.len - 1) {
        s /= 1024;
        unit_idx += 1;
    }

    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d} B", .{size}) catch "0 B";
    } else {
        return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ s, units[unit_idx] }) catch "0 B";
    }
}

/// Draw a spinner animation
pub fn drawSpinner(x: i32, y: i32, radius: f32) void {
    const time = @as(f32, @floatCast(rl.getTime()));
    const segments: i32 = 8;
    const arc_length: f32 = std.math.pi / 3.0;

    const start_angle = time * 4.0;
    const center_x: f32 = @floatFromInt(x);
    const center_y: f32 = @floatFromInt(y);

    var i: i32 = 0;
    while (i < segments) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const angle = start_angle + fi * arc_length / @as(f32, @floatFromInt(segments));
        const alpha: u8 = @intFromFloat(255.0 * (1.0 - fi / @as(f32, @floatFromInt(segments))));

        const px = center_x + @cos(angle) * radius;
        const py = center_y + @sin(angle) * radius;

        var color = theme.colors.accent;
        color.a = alpha;
        rl.drawCircle(@intFromFloat(px), @intFromFloat(py), 3.0, color);
    }
}

/// Draw a small badge/pill with text
pub fn drawBadge(text: [:0]const u8, x: i32, y: i32, color: rl.Color) void {
    const font_size = theme.fonts.small;
    const text_w = measureTextEx(text, font_size);
    const padding_x: i32 = 6;
    const padding_y: i32 = 2;
    const badge_w: i32 = @as(i32, @intFromFloat(text_w)) + padding_x * 2;
    const badge_h: i32 = @as(i32, @intFromFloat(font_size)) + padding_y * 2;

    // Background with transparency
    var bg_color = color;
    bg_color.a = 40;

    const rec = rl.Rectangle{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = @floatFromInt(badge_w),
        .height = @floatFromInt(badge_h),
    };
    rl.drawRectangleRounded(rec, 0.5, 4, bg_color);

    // Text
    drawLabel(text, x + padding_x, y + padding_y, font_size, color);
}

/// Draw confirmation dialog
pub fn drawConfirmDialog(title: [:0]const u8, message: [:0]const u8, screen_w: i32, screen_h: i32) ?bool {
    const dialog_w: i32 = 420;
    const dialog_h: i32 = 200;
    const dialog_x = @divTrunc(screen_w - dialog_w, 2);
    const dialog_y = @divTrunc(screen_h - dialog_h, 2);

    // Backdrop
    rl.drawRectangle(0, 0, screen_w, screen_h, rl.Color.init(0, 0, 0, 180));

    // Card background
    drawCard(dialog_x, dialog_y, dialog_w, dialog_h);

    // Title using Title font
    const title_w = measureTextTitle(title, theme.fonts.heading);
    const title_x = dialog_x + @divTrunc(dialog_w - @as(i32, @intFromFloat(title_w)), 2);
    drawTitle(title, title_x, dialog_y + theme.spacing.xl, theme.fonts.heading, theme.colors.text_primary);

    // Message
    const msg_w = measureTextEx(message, theme.fonts.body);
    const msg_x = dialog_x + @divTrunc(dialog_w - @as(i32, @intFromFloat(msg_w)), 2);
    drawLabel(message, msg_x, dialog_y + 80, theme.fonts.body, theme.colors.text_secondary);

    // Buttons
    const btn_w: i32 = 120;
    const btn_h: i32 = theme.dimensions.button_height;
    const btn_y = dialog_y + dialog_h - btn_h - theme.spacing.xl;
    const btn_spacing: i32 = 20;
    const total_btn_w = btn_w * 2 + btn_spacing;
    const btn_start_x = dialog_x + @divTrunc(dialog_w - total_btn_w, 2);

    if (drawButton("Cancel", btn_start_x, btn_y, btn_w, btn_h, theme.ButtonStyle.secondary)) {
        return false;
    }

    if (drawButton("Confirm", btn_start_x + btn_w + btn_spacing, btn_y, btn_w, btn_h, theme.ButtonStyle.danger)) {
        return true;
    }

    return null;
}
