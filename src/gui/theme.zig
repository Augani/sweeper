//! Theme definitions for the GUI
//!
//! Dark Violet / Dashboard Theme

const rl = @import("raylib");

/// Global font handles
pub var font_regular: rl.Font = undefined;
pub var font_semibold: rl.Font = undefined;
pub var font_bold: rl.Font = undefined;
pub var fonts_initialized: bool = false;

/// Color palette for the application
pub const colors = struct {
    // Layout colors
    pub const background = rl.Color.init(17, 17, 27, 255);      // Main BG (Darker)
    pub const sidebar_bg = rl.Color.init(30, 30, 46, 255);      // Sidebar BG
    pub const card_bg = rl.Color.init(49, 50, 68, 255);         // Card/Element BG
    
    // Interactive colors
    pub const surface = rl.Color.init(49, 50, 68, 255);         // Same as card_bg
    pub const surface_hover = rl.Color.init(69, 71, 90, 255);   // Lighter surface
    pub const surface_active = rl.Color.init(88, 91, 112, 255); // Even lighter

    // Text colors
    pub const text_primary = rl.Color.init(205, 214, 244, 255);   // White-ish
    pub const text_secondary = rl.Color.init(166, 173, 200, 255); // Grey-ish
    pub const text_muted = rl.Color.init(108, 112, 134, 255);     // Darker grey

    // Accent colors
    pub const accent = rl.Color.init(137, 180, 250, 255);         // Blue/Violet accent
    pub const accent_secondary = rl.Color.init(203, 166, 247, 255); // Pink/Purple secondary
    pub const accent_hover = rl.Color.init(180, 190, 254, 255);

    // Chart / Category colors
    pub const chart_1 = rl.Color.init(137, 180, 250, 255); // Blue
    pub const chart_2 = rl.Color.init(203, 166, 247, 255); // Purple
    pub const chart_3 = rl.Color.init(243, 139, 168, 255); // Red/Pink
    pub const chart_4 = rl.Color.init(166, 227, 161, 255); // Green
    pub const chart_5 = rl.Color.init(249, 226, 175, 255); // Yellow
    pub const chart_6 = rl.Color.init(148, 226, 213, 255); // Teal

    // Status colors
    pub const success = rl.Color.init(166, 227, 161, 255);
    pub const warning = rl.Color.init(249, 226, 175, 255);
    pub const danger = rl.Color.init(243, 139, 168, 255);

    // Border colors
    pub const border = rl.Color.init(69, 71, 90, 255);
    pub const border_focus = rl.Color.init(137, 180, 250, 255);

    // Selection
    pub const selected = rl.Color.init(137, 180, 250, 30);
    pub const selected_text = rl.Color.init(255, 255, 255, 255);

    // Scrollbar
    pub const scrollbar_bg = rl.Color.init(0, 0, 0, 0);
    pub const scrollbar_thumb = rl.Color.init(88, 91, 112, 255);
    pub const scrollbar_thumb_hover = rl.Color.init(108, 112, 134, 255);
    
    // Mappings for older code compat (aliases)
    pub const temporary = chart_5; 
    pub const cache = chart_1;
    pub const dev_artifact = chart_2;
    pub const large = chart_3;
    pub const log = chart_4;
    pub const duplicate = chart_3;
    pub const unused = text_muted;
    pub const old_download = chart_2;
    pub const normal = text_secondary;
};

/// Font sizes
pub const fonts = struct {
    pub const title: f32 = 24.0;
    pub const heading: f32 = 18.0;
    pub const body: f32 = 14.0;
    pub const small: f32 = 12.0;
    pub const mono: f32 = 13.0;
};

/// Spacing values
pub const spacing = struct {
    pub const xs: i32 = 4;
    pub const sm: i32 = 8;
    pub const md: i32 = 16;  // More spacious default
    pub const lg: i32 = 24;
    pub const xl: i32 = 32;
    pub const xxl: i32 = 48;
};

/// Component dimensions
pub const dimensions = struct {
    pub const sidebar_width: i32 = 260; // Fixed sidebar
    pub const header_height: i32 = 80;
    pub const row_height: i32 = 60;     // Taller rows
    pub const button_height: i32 = 40;
    pub const checkbox_size: i32 = 20;
    pub const scrollbar_width: i32 = 8;
    pub const border_radius: f32 = 12.0; // Rounder
    pub const button_radius: f32 = 8.0;
    pub const card_padding: i32 = 20;
};

/// Button style configuration
pub const ButtonStyle = struct {
    bg: rl.Color,
    bg_hover: rl.Color,
    bg_active: rl.Color,
    text: rl.Color,
    border: rl.Color,

    pub const primary = ButtonStyle{
        .bg = colors.accent,
        .bg_hover = colors.accent_hover,
        .bg_active = colors.accent_secondary,
        .text = rl.Color.init(24, 24, 37, 255), // Dark text on light accent
        .border = colors.accent,
    };

    pub const secondary = ButtonStyle{
        .bg = colors.surface,
        .bg_hover = colors.surface_hover,
        .bg_active = colors.surface_active,
        .text = colors.text_primary,
        .border = colors.border,
    };

    pub const danger = ButtonStyle{
        .bg = colors.surface, // Subtle danger button
        .bg_hover = colors.danger,
        .bg_active = colors.danger,
        .text = colors.danger, // Red text initially
        .border = colors.border,
    };
    // Special danger style for hover state handling in widget? 
    // For now we'll stick to this simple struct.
};

/// Get color for file category
pub fn categoryColor(category: @import("../analyzer.zig").FileCategory) rl.Color {
    return switch (category) {
        .temporary => colors.temporary,
        .cache => colors.cache,
        .dev_artifact => colors.dev_artifact,
        .large => colors.large,
        .log => colors.log,
        .duplicate => colors.duplicate,
        .unused => colors.unused,
        .old_download => colors.old_download,
        .browser_data => colors.cache,
        .normal => colors.normal,
    };
}
