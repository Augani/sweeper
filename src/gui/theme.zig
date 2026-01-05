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
    pub const background = rl.Color.init(16, 16, 18, 255);      // #101012 - Main BG
    pub const sidebar_bg = rl.Color.init(23, 23, 26, 255);      // #17171A - Sidebar BG
    pub const card_bg = rl.Color.init(23, 23, 26, 255);         // #17171A - Card BG (Same as sidebar)
    
    // Interactive colors
    pub const surface = rl.Color.init(32, 32, 36, 255);         // Surface for inputs/secondary
    pub const surface_hover = rl.Color.init(45, 45, 50, 255);   // Lighter surface
    pub const surface_active = rl.Color.init(220, 38, 38, 30);  // Red tint active
    
    // Text colors
    pub const text_primary = rl.Color.init(240, 240, 245, 255);   // #F0F0F5
    pub const text_secondary = rl.Color.init(161, 161, 166, 255); // #A1A1A6 (Grey text)
    pub const text_muted = rl.Color.init(110, 110, 115, 255);     // Darker grey
    
    // Accent colors
    pub const accent = rl.Color.init(220, 38, 38, 255);           // #DC2626 (Red scan/action)
    pub const accent_secondary = rl.Color.init(239, 68, 68, 255); // Lighter red
    pub const accent_hover = rl.Color.init(185, 28, 28, 255);     // Darker red hover
    
    // Chart / Category colors
    pub const chart_1 = rl.Color.init(220, 38, 38, 255); // Red (Primary/Dev)
    pub const chart_2 = rl.Color.init(252, 165, 165, 255); // Light Red (Cache)
    pub const chart_3 = rl.Color.init(75, 85, 99, 255);  // Grey (Temp/Other)
    pub const chart_4 = rl.Color.init(31, 41, 55, 255);  // Dark Grey
    pub const chart_5 = rl.Color.init(248, 113, 113, 255); // Another Red
    pub const chart_6 = rl.Color.init(153, 27, 27, 255); // Dark Red
    
    // Status colors
    pub const success = rl.Color.init(34, 197, 94, 255); // Green
    pub const warning = rl.Color.init(234, 179, 8, 255); // Yellow
    pub const danger = rl.Color.init(220, 38, 38, 255); // Red
    
    // Border colors
    pub const border = rl.Color.init(45, 45, 50, 255);
    pub const border_focus = rl.Color.init(220, 38, 38, 255);
    
    // Selection
    pub const selected = rl.Color.init(220, 38, 38, 20); // Low opacity red
    pub const selected_text = rl.Color.init(255, 255, 255, 255);
    
    // Scrollbar
    pub const scrollbar_bg = rl.Color.init(0, 0, 0, 0);
    pub const scrollbar_thumb = rl.Color.init(63, 63, 70, 255);
    pub const scrollbar_thumb_hover = rl.Color.init(82, 82, 91, 255);
    
    // Mappings for older code compat (aliases)
    pub const temporary = chart_3; 
    pub const cache = chart_2;
    pub const dev_artifact = chart_1;
    pub const large = chart_1;
    pub const log = chart_3;
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
