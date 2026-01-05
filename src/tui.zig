//! TUI (Text User Interface) module for Desktop Cleanup
//!
//! This module provides a terminal-based user interface with:
//! - Double-buffered rendering for smooth updates
//! - Cross-platform terminal handling
//! - Widget system for common UI elements
//! - Keyboard and mouse input handling

pub const terminal = @import("tui/terminal.zig");
pub const render = @import("tui/render.zig");
pub const widgets = @import("tui/widgets.zig");
pub const input = @import("tui/input.zig");
pub const app = @import("tui/app.zig");

// Re-export commonly used types
pub const Terminal = terminal.Terminal;
pub const Style = terminal.Style;
pub const Color = terminal.Color;
pub const Escape = terminal.Escape;

pub const Renderer = render.Renderer;
pub const Buffer = render.Buffer;
pub const Rect = render.Rect;
pub const Cell = render.Cell;
pub const BorderStyle = render.BorderStyle;

pub const Key = input.Key;
pub const MouseEvent = input.MouseEvent;
pub const Event = input.Event;
pub const InputReader = input.InputReader;
pub const EventQueue = input.EventQueue;

pub const App = app.App;
pub const AppState = app.AppState;
pub const FileItem = app.FileItem;
pub const View = app.View;

// Widget types
pub const ProgressBar = widgets.ProgressBar;
pub const Text = widgets.Text;
pub const List = widgets.List;
pub const Table = widgets.Table;
pub const Panel = widgets.Panel;
pub const Tabs = widgets.Tabs;
pub const StatusBar = widgets.StatusBar;
pub const Checkbox = widgets.Checkbox;
pub const Spinner = widgets.Spinner;

/// Run the TUI application
pub fn run(allocator: @import("std").mem.Allocator) !void {
    var application = try App.init(allocator);
    defer application.deinit();

    // Add demo files for testing
    try application.addDemoFiles();

    // Switch to results view
    application.state.view = .results;

    try application.run();
}

// Tests
test "tui module imports" {
    _ = terminal;
    _ = render;
    _ = widgets;
    _ = input;
    _ = app;
}

test "re-exports work" {
    const t = Terminal;
    _ = t;
    const s = Style.default;
    _ = s;
    const c = Color.red;
    _ = c;
}
