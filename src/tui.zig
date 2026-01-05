//! TUI (Text User Interface) module for Desktop Cleanup
//!
//! This module provides a terminal-based user interface with:
//! - Double-buffered rendering for smooth updates
//! - Cross-platform terminal handling
//! - Widget system for common UI elements
//! - Keyboard and mouse input handling

const std = @import("std");
const scanner_mod = @import("scanner.zig");
const analyzer_mod = @import("analyzer.zig");
const config_mod = @import("config.zig");
const platform_mod = @import("platform.zig");

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

/// Run the TUI application with real scanning
pub fn run(allocator: std.mem.Allocator) !void {
    var application = try App.init(allocator);
    defer application.deinit();

    // Start in scanning view
    application.state.view = .scanning;
    application.state.status_message = "Initializing scan...";

    // Perform real scan in the background
    try performRealScan(allocator, &application);

    try application.run();
}

/// Perform actual filesystem scan and populate results
fn performRealScan(allocator: std.mem.Allocator, application: *App) !void {
    const builtin = @import("builtin");

    // Create config with scan paths
    var cfg = config_mod.Config.init(allocator);
    defer cfg.deinit();

    // Add default scan paths for the platform
    try cfg.loadDefaults();

    // Get home directory cross-platform
    const home = if (builtin.os.tag == .windows)
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch "C:\\Users\\Default"
    else
        std.process.getEnvVarOwned(allocator, "HOME") catch "/tmp";
    defer allocator.free(home);

    // Platform-specific high-value targets
    if (builtin.os.tag == .macos) {
        const macos_paths = [_][]const u8{
            "/Library/Caches",
            "/Library/Logs",
            "/Library/Developer/Xcode/DerivedData",
            "/Library/Developer/CoreSimulator",
            "/.Trash",
            "/Downloads",
        };

        for (macos_paths) |suffix| {
            const full_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, suffix });
            defer allocator.free(full_path);

            if (scanner_mod.pathExists(full_path)) {
                try cfg.addScanPath(full_path);
            }
        }
    } else if (builtin.os.tag == .windows) {
        const windows_paths = [_][]const u8{
            "\\AppData\\Local\\Temp",
            "\\AppData\\Local\\Microsoft\\Windows\\INetCache",
            "\\Downloads",
        };

        for (windows_paths) |suffix| {
            const full_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, suffix });
            defer allocator.free(full_path);

            if (scanner_mod.pathExists(full_path)) {
                try cfg.addScanPath(full_path);
            }
        }
    } else {
        // Linux
        const linux_paths = [_][]const u8{
            "/.cache",
            "/.local/share/Trash",
            "/Downloads",
        };

        for (linux_paths) |suffix| {
            const full_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, suffix });
            defer allocator.free(full_path);

            if (scanner_mod.pathExists(full_path)) {
                try cfg.addScanPath(full_path);
            }
        }
    }

    // Create scanner
    var file_scanner = scanner_mod.Scanner.init(allocator, &cfg);
    defer file_scanner.deinit();

    // Enable hidden files to find more waste
    cfg.show_hidden = true;

    // Scan all paths
    application.state.status_message = "Scanning filesystem...";
    try file_scanner.scanAll();

    // Create analyzer
    var file_analyzer = analyzer_mod.Analyzer.init(allocator, .{
        .large_file_threshold = 50 * 1024 * 1024, // 50MB (lower threshold to catch more)
        .unused_days_threshold = 60, // 60 days
        .old_download_days = 14, // 2 weeks
        .detect_duplicates = false, // Disable for speed on initial scan
    });
    defer file_analyzer.deinit();

    // Analyze files
    application.state.status_message = "Analyzing files...";
    try file_analyzer.analyzeFiles(file_scanner.getResults());

    // Convert results to FileItems, filtering out normal files
    const analysis_results = file_analyzer.getResults();

    for (analysis_results) |result| {
        // Skip normal files and directories
        if (result.category == .normal or result.file.is_dir) continue;

        // Duplicate path for storage (FileItem needs owned strings)
        const path_copy = try allocator.dupe(u8, result.file.path);
        errdefer allocator.free(path_copy);

        const name = std.fs.path.basename(path_copy);

        try application.state.files.append(allocator, FileItem{
            .path = path_copy,
            .name = name,
            .size = result.file.size,
            .category = result.category,
            .selected = false,
            .confidence = result.confidence,
        });

        application.state.total_size += result.file.size;
    }

    // Sort by size (largest first)
    std.mem.sort(FileItem, application.state.files.items, {}, struct {
        fn lessThan(_: void, a: FileItem, b: FileItem) bool {
            return a.size > b.size;
        }
    }.lessThan);

    // Update status
    const stats = file_scanner.getStats();
    application.state.scan_progress = 1.0;

    var status_buf: [128]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buf, "Found {d} cleanup candidates ({d} files scanned)", .{
        application.state.files.items.len,
        stats.total_files,
    }) catch "Scan complete";

    // Store status (need to handle this carefully since it's a slice)
    application.state.status_message = status;
    application.state.view = .results;
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
