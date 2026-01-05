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

    // Load custom fonts at higher base size for crisp rendering
    const font_base = "resources/";
    const font_reg_path = font_base ++ "Inter-Regular.ttf";
    const font_semi_path = font_base ++ "Inter-SemiBold.ttf";
    const font_bold_path = font_base ++ "Inter-Bold.ttf";

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
    const icon_path = "resources/icon.png";
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
