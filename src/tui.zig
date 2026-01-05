//! TUI (Text User Interface) module for Sweeper
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
/// Uses fast system commands for discovery (matching GUI implementation)
fn performRealScan(allocator: std.mem.Allocator, application: *App) !void {
    const builtin = @import("builtin");

    // Get home directory cross-platform
    const home = if (builtin.os.tag == .windows)
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch "C:\\Users\\Default"
    else
        std.process.getEnvVarOwned(allocator, "HOME") catch "/tmp";
    defer allocator.free(home);

    application.state.status_message = "Finding dev artifacts...";

    // Phase 1: Fast dev artifact discovery using system commands
    try findDevArtifacts(allocator, application, home);

    application.state.status_message = "Scanning cache directories...";

    // Phase 2: Add known cache directories
    try addKnownCacheDirs(allocator, application, home);

    application.state.status_message = "Calculating sizes...";

    // Phase 3: Calculate sizes for all discovered items
    for (application.state.files.items) |*file| {
        if (file.size == 0) {
            file.size = getDirSize(allocator, file.path);
            application.state.total_size += file.size;
        }
    }

    // Sort by size (largest first)
    std.mem.sort(FileItem, application.state.files.items, {}, struct {
        fn lessThan(_: void, a: FileItem, b: FileItem) bool {
            return a.size > b.size;
        }
    }.lessThan);

    // Update status
    application.state.scan_progress = 1.0;

    var status_buf: [128]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buf, "Found {d} cleanup candidates", .{
        application.state.files.items.len,
    }) catch "Scan complete";

    application.state.status_message = status;
    application.state.view = .results;
}

/// Find dev artifacts using fast system commands
fn findDevArtifacts(allocator: std.mem.Allocator, application: *App, home: []const u8) !void {
    const builtin = @import("builtin");

    const stdout = if (builtin.os.tag == .windows)
        findDevArtifactsWindows(allocator, home)
    else
        findDevArtifactsUnix(allocator, home);

    if (stdout) |output| {
        defer allocator.free(output);
        try parseFoundPaths(allocator, application, output);
    }
}

/// Unix/macOS: Use find command
fn findDevArtifactsUnix(allocator: std.mem.Allocator, home: []const u8) ?[]u8 {
    const find_cmd = std.fmt.allocPrint(allocator,
        \\find {s} -maxdepth 12 -type d \( \
        \\  -name 'node_modules' -o \
        \\  -name 'target' -o \
        \\  -name '.build' -o \
        \\  -name 'build' -o \
        \\  -name 'dist' -o \
        \\  -name '__pycache__' -o \
        \\  -name '.gradle' -o \
        \\  -name 'venv' -o \
        \\  -name '.venv' -o \
        \\  -name 'Pods' -o \
        \\  -name 'DerivedData' \
        \\\) -prune 2>/dev/null | head -200
    , .{home}) catch return null;
    defer allocator.free(find_cmd);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "/bin/sh", "-c", find_cmd },
        .max_output_bytes = 256 * 1024,
    }) catch return null;
    allocator.free(result.stderr);

    return result.stdout;
}

/// Windows: Use PowerShell Get-ChildItem
fn findDevArtifactsWindows(allocator: std.mem.Allocator, home: []const u8) ?[]u8 {
    const ps_cmd = std.fmt.allocPrint(allocator,
        \\Get-ChildItem -Path "{s}" -Directory -Depth 12 -ErrorAction SilentlyContinue |
        \\Where-Object {{ $_.Name -match '^(node_modules|target|\.build|build|dist|__pycache__|\.gradle|venv|\.venv|Pods|DerivedData|bin|obj)$' }} |
        \\Select-Object -First 200 -ExpandProperty FullName
    , .{home}) catch return null;
    defer allocator.free(ps_cmd);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "powershell.exe", "-NoProfile", "-Command", ps_cmd },
        .max_output_bytes = 256 * 1024,
    }) catch return null;
    allocator.free(result.stderr);

    return result.stdout;
}

/// Parse found paths from command output
fn parseFoundPaths(allocator: std.mem.Allocator, application: *App, stdout: []const u8) !void {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) continue;

        const path = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(path);

        const name = std.fs.path.basename(path);
        const category: analyzer_mod.FileCategory = if (std.mem.eql(u8, name, "node_modules") or
            std.mem.eql(u8, name, "target") or
            std.mem.eql(u8, name, ".build") or
            std.mem.eql(u8, name, "Pods") or
            std.mem.eql(u8, name, "DerivedData") or
            std.mem.eql(u8, name, "bin") or
            std.mem.eql(u8, name, "obj"))
            .dev_artifact
        else if (std.mem.eql(u8, name, "__pycache__"))
            .cache
        else
            .dev_artifact;

        try application.state.files.append(allocator, FileItem{
            .path = path,
            .name = name,
            .size = 0,
            .category = category,
            .selected = false,
            .confidence = 0.9,
        });
    }
}

/// Add known cache directories (cross-platform)
fn addKnownCacheDirs(allocator: std.mem.Allocator, application: *App, home: []const u8) !void {
    const builtin = @import("builtin");

    // Common paths for all Unix-like systems
    const common_paths = [_]struct { suffix: []const u8, category: analyzer_mod.FileCategory }{
        // Package managers
        .{ .suffix = "/.npm", .category = .cache },
        .{ .suffix = "/.yarn", .category = .cache },
        .{ .suffix = "/.pnpm-store", .category = .cache },
        .{ .suffix = "/.bun", .category = .cache },
        // Rust
        .{ .suffix = "/.cargo/registry", .category = .cache },
        .{ .suffix = "/.cargo/git", .category = .cache },
        .{ .suffix = "/.rustup/toolchains", .category = .cache },
        // Java/Kotlin/Android
        .{ .suffix = "/.gradle/caches", .category = .cache },
        .{ .suffix = "/.gradle/wrapper/dists", .category = .cache },
        .{ .suffix = "/.m2/repository", .category = .cache },
        .{ .suffix = "/.android/cache", .category = .cache },
        // Go
        .{ .suffix = "/go/pkg/mod", .category = .cache },
        .{ .suffix = "/.cache/go-build", .category = .cache },
        // Python
        .{ .suffix = "/.cache/pip", .category = .cache },
        .{ .suffix = "/.local/pipx", .category = .cache },
        // Ruby
        .{ .suffix = "/.gem", .category = .cache },
        .{ .suffix = "/.bundle/cache", .category = .cache },
        // PHP
        .{ .suffix = "/.composer/cache", .category = .cache },
        // Dart/Flutter
        .{ .suffix = "/.pub-cache", .category = .cache },
        .{ .suffix = "/.flutter", .category = .cache },
        // IDE extensions
        .{ .suffix = "/.vscode/extensions", .category = .cache },
        .{ .suffix = "/.vscode-insiders/extensions", .category = .cache },
        .{ .suffix = "/.cursor/extensions", .category = .cache },
        .{ .suffix = "/.windsurf/extensions", .category = .cache },
        .{ .suffix = "/.zed/extensions", .category = .cache },
        // Docker
        .{ .suffix = "/.docker/buildx", .category = .cache },
    };

    for (common_paths) |entry| {
        try addPathIfExists(allocator, application, home, entry.suffix, entry.category);
    }

    // Platform-specific paths
    if (builtin.os.tag == .macos) {
        const macos_paths = [_]struct { suffix: []const u8, category: analyzer_mod.FileCategory }{
            .{ .suffix = "/Library/Caches", .category = .cache },
            .{ .suffix = "/Library/Logs", .category = .log },
            .{ .suffix = "/.Trash", .category = .temporary },
            .{ .suffix = "/Library/Developer/Xcode/DerivedData", .category = .dev_artifact },
            .{ .suffix = "/Library/Developer/Xcode/Archives", .category = .dev_artifact },
            .{ .suffix = "/Library/Developer/CoreSimulator/Caches", .category = .cache },
            .{ .suffix = "/.cocoapods/repos", .category = .cache },
            .{ .suffix = "/Library/Caches/com.apple.Safari", .category = .browser_data },
            .{ .suffix = "/Library/Caches/Google/Chrome", .category = .browser_data },
            .{ .suffix = "/Library/Caches/Firefox", .category = .browser_data },
            .{ .suffix = "/Library/Caches/Homebrew", .category = .cache },
        };

        for (macos_paths) |entry| {
            try addPathIfExists(allocator, application, home, entry.suffix, entry.category);
        }
    } else if (builtin.os.tag == .linux) {
        const linux_paths = [_]struct { suffix: []const u8, category: analyzer_mod.FileCategory }{
            .{ .suffix = "/.cache", .category = .cache },
            .{ .suffix = "/.local/share/Trash", .category = .temporary },
            .{ .suffix = "/.cache/google-chrome", .category = .browser_data },
            .{ .suffix = "/.cache/chromium", .category = .browser_data },
            .{ .suffix = "/.cache/mozilla/firefox", .category = .browser_data },
            .{ .suffix = "/.cache/BraveSoftware", .category = .browser_data },
            .{ .suffix = "/snap", .category = .cache },
            .{ .suffix = "/.var/app", .category = .cache },
        };

        for (linux_paths) |entry| {
            try addPathIfExists(allocator, application, home, entry.suffix, entry.category);
        }
    } else if (builtin.os.tag == .windows) {
        try addWindowsCachePaths(allocator, application, home);
    }
}

/// Windows-specific cache paths
fn addWindowsCachePaths(allocator: std.mem.Allocator, application: *App, home: []const u8) !void {
    var env = std.process.getEnvMap(allocator) catch return;
    defer env.deinit();

    const local_app_data = env.get("LOCALAPPDATA") orelse "";
    const app_data = env.get("APPDATA") orelse "";

    // Home paths
    const home_paths = [_]struct { suffix: []const u8, category: analyzer_mod.FileCategory }{
        .{ .suffix = "\\.cargo\\registry", .category = .cache },
        .{ .suffix = "\\.gradle\\caches", .category = .cache },
        .{ .suffix = "\\.m2\\repository", .category = .cache },
        .{ .suffix = "\\.npm", .category = .cache },
        .{ .suffix = "\\.nuget\\packages", .category = .cache },
        .{ .suffix = "\\.vscode\\extensions", .category = .cache },
    };

    for (home_paths) |entry| {
        try addPathIfExists(allocator, application, home, entry.suffix, entry.category);
    }

    // LOCALAPPDATA paths
    if (local_app_data.len > 0) {
        const local_paths = [_]struct { suffix: []const u8, category: analyzer_mod.FileCategory }{
            .{ .suffix = "\\Temp", .category = .temporary },
            .{ .suffix = "\\npm-cache", .category = .cache },
            .{ .suffix = "\\pip\\Cache", .category = .cache },
            .{ .suffix = "\\Google\\Chrome\\User Data\\Default\\Cache", .category = .browser_data },
            .{ .suffix = "\\Microsoft\\Edge\\User Data\\Default\\Cache", .category = .browser_data },
        };

        for (local_paths) |entry| {
            try addPathIfExists(allocator, application, local_app_data, entry.suffix, entry.category);
        }
    }

    // APPDATA paths
    if (app_data.len > 0) {
        const roaming_paths = [_]struct { suffix: []const u8, category: analyzer_mod.FileCategory }{
            .{ .suffix = "\\Code\\Cache", .category = .cache },
            .{ .suffix = "\\npm-cache", .category = .cache },
        };

        for (roaming_paths) |entry| {
            try addPathIfExists(allocator, application, app_data, entry.suffix, entry.category);
        }
    }
}

/// Add path if it exists
fn addPathIfExists(allocator: std.mem.Allocator, application: *App, base: []const u8, suffix: []const u8, category: analyzer_mod.FileCategory) !void {
    const full_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, suffix });
    errdefer allocator.free(full_path);

    std.fs.accessAbsolute(full_path, .{}) catch {
        allocator.free(full_path);
        return;
    };

    try application.state.files.append(allocator, FileItem{
        .path = full_path,
        .name = std.fs.path.basename(full_path),
        .size = 0,
        .category = category,
        .selected = false,
        .confidence = 0.85,
    });
}

/// Get directory size using platform-specific commands
fn getDirSize(allocator: std.mem.Allocator, path: []const u8) u64 {
    const builtin = @import("builtin");

    if (builtin.os.tag == .windows) {
        return getDirSizeWindows(allocator, path);
    } else {
        return getDirSizeUnix(allocator, path);
    }
}

/// Unix/macOS: Use du command
fn getDirSizeUnix(allocator: std.mem.Allocator, path: []const u8) u64 {
    const cmd = std.fmt.allocPrint(allocator, "du -sk \"{s}\" 2>/dev/null | cut -f1", .{path}) catch return 0;
    defer allocator.free(cmd);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
        .max_output_bytes = 64,
    }) catch return 0;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const trimmed = std.mem.trim(u8, result.stdout, &[_]u8{ ' ', '\n', '\t' });
    const kb = std.fmt.parseInt(u64, trimmed, 10) catch return 0;
    return kb * 1024;
}

/// Windows: Use PowerShell
fn getDirSizeWindows(allocator: std.mem.Allocator, path: []const u8) u64 {
    const cmd = std.fmt.allocPrint(allocator,
        \\(Get-ChildItem -Path "{s}" -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    , .{path}) catch return 0;
    defer allocator.free(cmd);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "powershell.exe", "-NoProfile", "-Command", cmd },
        .max_output_bytes = 64,
    }) catch return 0;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const trimmed = std.mem.trim(u8, result.stdout, &[_]u8{ ' ', '\n', '\t', '\r' });
    return std.fmt.parseInt(u64, trimmed, 10) catch return 0;
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
