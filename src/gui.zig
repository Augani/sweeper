//! GUI module for Desktop Cleanup
//!
//! Native GUI using raylib for users who prefer graphical interface.

const std = @import("std");
const rl = @import("raylib");

const scanner = @import("scanner.zig");
const analyzer = @import("analyzer.zig");
const config = @import("config.zig");
const deleter = @import("deleter.zig");
const platform = @import("platform.zig");

pub const theme = @import("gui/theme.zig");
pub const widgets = @import("gui/widgets.zig");
pub const app = @import("gui/app.zig");

pub const App = app.GuiApp;

pub fn run(allocator: std.mem.Allocator) !void {
    // Set config flags before window creation
    rl.setConfigFlags(.{
        .window_resizable = true,
        .window_highdpi = true,
        .msaa_4x_hint = true,
    });

    // Initialize raylib
    rl.initWindow(1280, 850, "Sweeper");
    defer rl.closeWindow();

    // Get the directory of the executable to find resources
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_dir_buf) catch "";
    const exe_dir = std.fs.path.dirname(exe_path) orelse "";

    // Build resource paths relative to executable (null-terminated for raylib)
    var font_reg_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var font_semi_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var font_bold_buf: [std.fs.max_path_bytes:0]u8 = undefined;

    const font_reg_path: [:0]const u8 = if (exe_dir.len > 0)
        std.fmt.bufPrintZ(&font_reg_buf, "{s}/resources/Inter-Regular.ttf", .{exe_dir}) catch "resources/Inter-Regular.ttf"
    else
        "resources/Inter-Regular.ttf";

    const font_semi_path: [:0]const u8 = if (exe_dir.len > 0)
        std.fmt.bufPrintZ(&font_semi_buf, "{s}/resources/Inter-SemiBold.ttf", .{exe_dir}) catch "resources/Inter-SemiBold.ttf"
    else
        "resources/Inter-SemiBold.ttf";

    const font_bold_path: [:0]const u8 = if (exe_dir.len > 0)
        std.fmt.bufPrintZ(&font_bold_buf, "{s}/resources/Inter-Bold.ttf", .{exe_dir}) catch "resources/Inter-Bold.ttf"
    else
        "resources/Inter-Bold.ttf";

    // Load fonts at 48px base size for better quality when scaling down
    const font_size: i32 = 48;
    const default_font = rl.getFontDefault() catch unreachable;
    theme.font_regular = rl.loadFontEx(font_reg_path, font_size, null) catch default_font;
    theme.font_semibold = rl.loadFontEx(font_semi_path, font_size, null) catch default_font;
    theme.font_bold = rl.loadFontEx(font_bold_path, font_size, null) catch default_font;

    // Check if custom fonts loaded
    theme.fonts_initialized = (theme.font_regular.glyphCount > 0);
    if (theme.fonts_initialized) {
        std.debug.print("Loaded Inter fonts at {d}px\n", .{font_size});
        // Set bilinear filtering for smooth text at any size
        rl.setTextureFilter(theme.font_regular.texture, .bilinear);
        rl.setTextureFilter(theme.font_semibold.texture, .bilinear);
        rl.setTextureFilter(theme.font_bold.texture, .bilinear);
    } else {
        std.debug.print("Using default font\n", .{});
    }

    defer if (theme.fonts_initialized) {
        rl.unloadFont(theme.font_regular);
        rl.unloadFont(theme.font_semibold);
        rl.unloadFont(theme.font_bold);
    };

    // Load and set window icon
    var icon_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const icon_path: [:0]const u8 = if (exe_dir.len > 0)
        std.fmt.bufPrintZ(&icon_buf, "{s}/resources/icon.png", .{exe_dir}) catch "resources/icon.png"
    else
        "resources/icon.png";

    if (rl.loadImage(icon_path)) |icon| {
        icon.useAsWindowIcon();
        rl.unloadImage(icon);
    } else |_| {
        // Icon not found, continue without it
    }

    // Center window on screen and bring to front
    const monitor_w = rl.getMonitorWidth(0);
    const monitor_h = rl.getMonitorHeight(0);
    const win_x = @divTrunc(monitor_w - 1280, 2);
    const win_y = @divTrunc(monitor_h - 850, 2);
    rl.setWindowPosition(win_x, win_y);

    // Focus the window (important for macOS)
    rl.setWindowFocused();

    rl.setTargetFPS(60);

    // Initialize application (starts in idle state)
    var application = try App.init(allocator);
    defer application.deinit();

    // Main loop
    while (!rl.windowShouldClose() and !application.should_quit) {
        // Handle input
        application.handleInput();

        // Update state
        application.update();

        // Render
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(theme.colors.background);
        application.render();
    }
}
