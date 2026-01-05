const std = @import("std");
const terminal = @import("terminal.zig");
const render = @import("render.zig");
const widgets = @import("widgets.zig");
const input = @import("input.zig");

const platform_mod = @import("../platform.zig");
const scanner_mod = @import("../scanner.zig");
const analyzer_mod = @import("../analyzer.zig");
const config_mod = @import("../config.zig");

const Terminal = terminal.Terminal;
const Renderer = render.Renderer;
const Buffer = render.Buffer;
const Rect = render.Rect;
const Style = terminal.Style;
const Color = terminal.Color;
const Key = input.Key;
const BorderStyle = render.BorderStyle;

/// File item for display in the list
pub const FileItem = struct {
    path: []const u8,
    name: []const u8,
    size: u64,
    category: analyzer_mod.FileCategory,
    selected: bool,
    confidence: f32,
};

/// Application view/screen
pub const View = enum {
    main,
    scanning,
    results,
    details,
    confirm_delete,
    help,
};

/// Application state
pub const AppState = struct {
    allocator: std.mem.Allocator,
    view: View = .main,
    files: std.ArrayListUnmanaged(FileItem),
    selected_index: usize = 0,
    scroll_offset: usize = 0,
    total_size: u64 = 0,
    selected_size: u64 = 0,
    scan_progress: f32 = 0.0,
    status_message: []const u8 = "",
    is_scanning: bool = false,
    show_help: bool = false,
    active_tab: usize = 0,
    filter_category: ?analyzer_mod.FileCategory = null,

    pub fn init(allocator: std.mem.Allocator) AppState {
        return AppState{
            .allocator = allocator,
            .files = .{},
        };
    }

    pub fn deinit(self: *AppState) void {
        self.files.deinit(self.allocator);
    }

    /// Get selected count
    pub fn getSelectedCount(self: *AppState) usize {
        var count: usize = 0;
        for (self.files.items) |file| {
            if (file.selected) count += 1;
        }
        return count;
    }

    /// Calculate selected size
    pub fn calculateSelectedSize(self: *AppState) void {
        self.selected_size = 0;
        for (self.files.items) |file| {
            if (file.selected) {
                self.selected_size += file.size;
            }
        }
    }

    /// Toggle selection of current item
    pub fn toggleCurrent(self: *AppState) void {
        if (self.selected_index < self.files.items.len) {
            self.files.items[self.selected_index].selected = !self.files.items[self.selected_index].selected;
            self.calculateSelectedSize();
        }
    }

    /// Select all items
    pub fn selectAll(self: *AppState) void {
        for (self.files.items) |*file| {
            file.selected = true;
        }
        self.calculateSelectedSize();
    }

    /// Deselect all items
    pub fn deselectAll(self: *AppState) void {
        for (self.files.items) |*file| {
            file.selected = false;
        }
        self.selected_size = 0;
    }

    /// Move selection up
    pub fn moveUp(self: *AppState) void {
        if (self.selected_index > 0) {
            self.selected_index -= 1;
        }
    }

    /// Move selection down
    pub fn moveDown(self: *AppState) void {
        if (self.selected_index < self.files.items.len -| 1) {
            self.selected_index += 1;
        }
    }

    /// Page up
    pub fn pageUp(self: *AppState, page_size: usize) void {
        if (self.selected_index >= page_size) {
            self.selected_index -= page_size;
        } else {
            self.selected_index = 0;
        }
    }

    /// Page down
    pub fn pageDown(self: *AppState, page_size: usize) void {
        const max_idx = if (self.files.items.len > 0) self.files.items.len - 1 else 0;
        if (self.selected_index + page_size < max_idx) {
            self.selected_index += page_size;
        } else {
            self.selected_index = max_idx;
        }
    }
};

/// Main TUI application
pub const App = struct {
    allocator: std.mem.Allocator,
    term: Terminal,
    renderer: Renderer,
    state: AppState,
    input_reader: input.InputReader,
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator) !App {
        var term = try Terminal.init();
        errdefer term.deinit();

        var renderer = try Renderer.init(allocator, &term);
        errdefer renderer.deinit();

        return App{
            .allocator = allocator,
            .term = term,
            .renderer = renderer,
            .state = AppState.init(allocator),
            .input_reader = input.InputReader.init(),
        };
    }

    pub fn deinit(self: *App) void {
        self.state.deinit();
        self.renderer.deinit();
        self.term.deinit();
    }

    /// Start the TUI application
    pub fn run(self: *App) !void {
        // Setup terminal
        try self.term.enableRawMode();
        self.term.enterAltScreen();
        self.term.hideCursor();
        self.term.clear();

        // Main event loop
        while (self.running) {
            // Draw
            self.draw();
            self.renderer.render();

            // Handle input
            const key = self.input_reader.readKey();
            self.handleInput(key);
        }

        // Cleanup
        self.term.showCursor();
        self.term.leaveAltScreen();
        self.term.disableRawMode();
    }

    /// Handle input events
    fn handleInput(self: *App, key: Key) void {
        // Global keys
        if (key.isCtrlC() or key.isCharKey('q')) {
            self.running = false;
            return;
        }

        if (key.isCharKey('?')) {
            self.state.show_help = !self.state.show_help;
            return;
        }

        if (self.state.show_help) {
            // Any key closes help
            if (!key.isNone()) {
                self.state.show_help = false;
            }
            return;
        }

        // View-specific input handling
        switch (self.state.view) {
            .main, .results => self.handleMainInput(key),
            .scanning => {}, // No input during scan
            .confirm_delete => self.handleConfirmInput(key),
            .details => self.handleDetailsInput(key),
            .help => {
                if (key.isEscape() or key.isEnter()) {
                    self.state.view = .results;
                }
            },
        }
    }

    /// Handle input in main/results view
    fn handleMainInput(self: *App, key: Key) void {
        switch (key) {
            .special => |s| switch (s) {
                .up => self.state.moveUp(),
                .down => self.state.moveDown(),
                .page_up => self.state.pageUp(10),
                .page_down => self.state.pageDown(10),
                .home => self.state.selected_index = 0,
                .end => {
                    if (self.state.files.items.len > 0) {
                        self.state.selected_index = self.state.files.items.len - 1;
                    }
                },
                .enter => self.state.view = .details,
                .tab => {
                    self.state.active_tab = (self.state.active_tab + 1) % 4;
                },
                else => {},
            },
            .char => |c| switch (c) {
                ' ' => self.state.toggleCurrent(),
                'a' => self.state.selectAll(),
                'n' => self.state.deselectAll(),
                'd' => {
                    if (self.state.getSelectedCount() > 0) {
                        self.state.view = .confirm_delete;
                    }
                },
                's' => self.state.view = .scanning,
                'j' => self.state.moveDown(),
                'k' => self.state.moveUp(),
                '1' => self.state.filter_category = .temporary,
                '2' => self.state.filter_category = .cache,
                '3' => self.state.filter_category = .duplicate,
                '4' => self.state.filter_category = .large,
                '0' => self.state.filter_category = null,
                else => {},
            },
            else => {},
        }
    }

    /// Handle input in confirm delete view
    fn handleConfirmInput(self: *App, key: Key) void {
        switch (key) {
            .char => |c| switch (c) {
                'y', 'Y' => {
                    // Would perform deletion here
                    self.state.status_message = "Files deleted (simulated)";
                    self.state.view = .results;
                },
                'n', 'N' => self.state.view = .results,
                else => {},
            },
            .special => |s| {
                if (s == .escape) {
                    self.state.view = .results;
                }
            },
            else => {},
        }
    }

    /// Handle input in details view
    fn handleDetailsInput(self: *App, key: Key) void {
        if (key.isEscape() or key.isEnter() or key.isCharKey('q')) {
            self.state.view = .results;
        }
    }

    /// Draw the entire UI
    fn draw(self: *App) void {
        const buf = self.renderer.buffer();
        buf.clear();

        const area = self.renderer.area();

        // Draw based on current view
        if (self.state.show_help) {
            self.drawHelp(buf, area);
        } else {
            switch (self.state.view) {
                .main, .results => self.drawMainView(buf, area),
                .scanning => self.drawScanningView(buf, area),
                .confirm_delete => self.drawConfirmView(buf, area),
                .details => self.drawDetailsView(buf, area),
                .help => self.drawHelp(buf, area),
            }
        }
    }

    /// Draw main/results view
    fn drawMainView(self: *App, buf: *Buffer, area: Rect) void {
        // Title bar
        self.drawTitleBar(buf, Rect{ .x = area.x, .y = area.y, .width = area.width, .height = 1 });

        // Tabs
        const tab_labels = [_][]const u8{ "All", "Temp", "Cache", "Large" };
        var tabs = widgets.Tabs{
            .labels = &tab_labels,
            .active = self.state.active_tab,
        };
        tabs.draw(buf, Rect{ .x = area.x + 1, .y = area.y + 1, .width = area.width - 2, .height = 1 });

        // File list panel
        const list_height = area.height - 5;
        self.drawFileList(buf, Rect{
            .x = area.x,
            .y = area.y + 2,
            .width = area.width,
            .height = list_height,
        });

        // Status bar
        self.drawStatusBar(buf, Rect{
            .x = area.x,
            .y = area.y + area.height - 2,
            .width = area.width,
            .height = 1,
        });

        // Help hint
        const help_text = "[?] Help  [Space] Select  [d] Delete  [q] Quit";
        buf.drawString(area.x + 1, area.y + area.height - 1, help_text, Style.default.withFg(.cyan));
    }

    /// Draw title bar
    fn drawTitleBar(self: *App, buf: *Buffer, area: Rect) void {
        _ = self;
        const title = " Desktop Cleanup TUI ";
        buf.drawHLine(area.x, area.y, area.width, ' ', Style.default.withBg(.blue).withFg(.white));
        buf.drawString(area.x + (area.width - @as(u16, @intCast(title.len))) / 2, area.y, title, Style.default.withBg(.blue).withFg(.white).withBold());
    }

    /// Draw file list
    fn drawFileList(self: *App, buf: *Buffer, area: Rect) void {
        // Panel border
        const panel = widgets.Panel{
            .title = "Files",
            .border = .single,
        };
        panel.draw(buf, area);

        const inner = panel.innerRect(area);
        if (inner.width == 0 or inner.height == 0) return;

        // Ensure scroll keeps selected item visible
        if (self.state.selected_index < self.state.scroll_offset) {
            self.state.scroll_offset = self.state.selected_index;
        } else if (self.state.selected_index >= self.state.scroll_offset + inner.height) {
            self.state.scroll_offset = self.state.selected_index - inner.height + 1;
        }

        // Draw header
        const header = "   Size      Category    Name";
        buf.drawString(inner.x, inner.y, header, Style.default.withBold());

        // Draw items
        const visible_height = inner.height - 1;
        var y: u16 = 0;

        while (y < visible_height) : (y += 1) {
            const idx = self.state.scroll_offset + y;
            if (idx >= self.state.files.items.len) break;

            const file = self.state.files.items[idx];
            const is_selected = idx == self.state.selected_index;

            const row_style = if (is_selected) Style.default.withReverse() else Style.default;

            // Clear line
            buf.drawHLine(inner.x, inner.y + y + 1, inner.width, ' ', row_style);

            // Selection marker
            const marker: u8 = if (file.selected) 'x' else ' ';
            buf.setChar(inner.x, inner.y + y + 1, '[', row_style);
            buf.setChar(inner.x + 1, inner.y + y + 1, marker, if (file.selected) Style.default.withFg(.green) else row_style);
            buf.setChar(inner.x + 2, inner.y + y + 1, ']', row_style);

            // Size
            var size_buf: [12]u8 = undefined;
            const size_str = formatSizeCompact(file.size, &size_buf);
            buf.drawString(inner.x + 4, inner.y + y + 1, size_str, row_style);

            // Category
            const cat_str = file.category.getName();
            const cat_style = getCategoryStyle(file.category, is_selected);
            buf.drawStringMax(inner.x + 14, inner.y + y + 1, cat_str, 10, cat_style);

            // Name (truncated)
            const name_max = inner.width - 26;
            buf.drawStringMax(inner.x + 26, inner.y + y + 1, file.name, name_max, row_style);
        }

        // Scroll indicator
        if (self.state.files.items.len > visible_height) {
            const scrollbar_height = @max(1, (visible_height * visible_height) / @as(u16, @intCast(self.state.files.items.len)));
            const scrollbar_pos = if (self.state.files.items.len > visible_height)
                @as(u16, @intCast((self.state.scroll_offset * (visible_height - scrollbar_height)) / (self.state.files.items.len - visible_height)))
            else
                0;

            var sy: u16 = 0;
            while (sy < visible_height) : (sy += 1) {
                const char: u21 = if (sy >= scrollbar_pos and sy < scrollbar_pos + scrollbar_height) 0x2588 else 0x2591;
                buf.setChar(inner.x + inner.width - 1, inner.y + sy + 1, char, Style.default.withFg(.cyan));
            }
        }
    }

    /// Draw status bar
    fn drawStatusBar(self: *App, buf: *Buffer, area: Rect) void {
        var size_buf: [16]u8 = undefined;
        const sel_count = self.state.getSelectedCount();
        const sel_size = formatSizeCompact(self.state.selected_size, &size_buf);

        var status_buf: [64]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, "{d} files | {d} selected ({s})", .{
            self.state.files.items.len,
            sel_count,
            sel_size,
        }) catch "Status";

        var bar = widgets.StatusBar{
            .left_text = status,
            .right_text = self.state.status_message,
        };
        bar.draw(buf, area);
    }

    /// Draw scanning view
    fn drawScanningView(self: *App, buf: *Buffer, area: Rect) void {
        const panel = widgets.Panel{
            .title = "Scanning",
            .border = .double,
        };
        panel.draw(buf, area);

        const inner = panel.innerRect(area);
        const center_y = inner.y + inner.height / 2;

        // Scanning message
        buf.drawString(inner.x + (inner.width - 20) / 2, center_y - 2, "Scanning filesystem...", Style.default.withBold());

        // Progress bar
        var progress = widgets.ProgressBar{
            .progress = self.state.scan_progress,
            .filled_style = Style.default.withFg(.cyan),
        };
        progress.draw(buf, Rect{
            .x = inner.x + 2,
            .y = center_y,
            .width = inner.width - 4,
            .height = 1,
        });

        // Cancel hint
        buf.drawString(inner.x + (inner.width - 22) / 2, center_y + 2, "Press Ctrl+C to cancel", Style.default.withFg(.yellow));
    }

    /// Draw confirm delete view
    fn drawConfirmView(self: *App, buf: *Buffer, area: Rect) void {
        // Draw background (main view dimmed)
        self.drawMainView(buf, area);

        // Draw dialog box
        const dialog_width: u16 = 50;
        const dialog_height: u16 = 7;
        const dialog_x = (area.width - dialog_width) / 2;
        const dialog_y = (area.height - dialog_height) / 2;

        const dialog_rect = Rect{
            .x = dialog_x,
            .y = dialog_y,
            .width = dialog_width,
            .height = dialog_height,
        };

        // Fill background
        buf.fillRect(dialog_rect, ' ', Style.default);

        // Draw border
        const panel = widgets.Panel{
            .title = "Confirm Delete",
            .border = .double,
            .border_style = Style.default.withFg(.red),
        };
        panel.draw(buf, dialog_rect);

        const inner = panel.innerRect(dialog_rect);

        // Message
        var count_buf: [32]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "Delete {d} selected files?", .{self.state.getSelectedCount()}) catch "Delete files?";
        buf.drawString(inner.x + (inner.width - @as(u16, @intCast(count_str.len))) / 2, inner.y + 1, count_str, Style.default);

        // Options
        buf.drawString(inner.x + inner.width / 4, inner.y + 3, "[Y]es", Style.default.withFg(.green));
        buf.drawString(inner.x + inner.width * 3 / 4 - 4, inner.y + 3, "[N]o", Style.default.withFg(.red));
    }

    /// Draw details view
    fn drawDetailsView(self: *App, buf: *Buffer, area: Rect) void {
        const panel = widgets.Panel{
            .title = "File Details",
            .border = .single,
        };
        panel.draw(buf, area);

        const inner = panel.innerRect(area);

        if (self.state.selected_index >= self.state.files.items.len) {
            buf.drawString(inner.x + 2, inner.y + 2, "No file selected", Style.default);
            return;
        }

        const file = self.state.files.items[self.state.selected_index];

        // File details
        buf.drawString(inner.x + 2, inner.y + 1, "Name:", Style.default.withBold());
        buf.drawStringMax(inner.x + 10, inner.y + 1, file.name, inner.width - 12, Style.default);

        buf.drawString(inner.x + 2, inner.y + 3, "Path:", Style.default.withBold());
        buf.drawStringMax(inner.x + 10, inner.y + 3, file.path, inner.width - 12, Style.default);

        var size_buf: [16]u8 = undefined;
        buf.drawString(inner.x + 2, inner.y + 5, "Size:", Style.default.withBold());
        buf.drawString(inner.x + 10, inner.y + 5, formatSizeCompact(file.size, &size_buf), Style.default);

        buf.drawString(inner.x + 2, inner.y + 7, "Category:", Style.default.withBold());
        buf.drawString(inner.x + 12, inner.y + 7, file.category.getName(), getCategoryStyle(file.category, false));

        var conf_buf: [8]u8 = undefined;
        buf.drawString(inner.x + 2, inner.y + 9, "Confidence:", Style.default.withBold());
        const conf_str = std.fmt.bufPrint(&conf_buf, "{d}%", .{@as(u8, @intFromFloat(file.confidence * 100))}) catch "??%";
        buf.drawString(inner.x + 14, inner.y + 9, conf_str, Style.default);

        // Back hint
        buf.drawString(inner.x + 2, inner.y + inner.height - 2, "Press Enter or Escape to go back", Style.default.withFg(.cyan));
    }

    /// Draw help overlay
    fn drawHelp(self: *App, buf: *Buffer, area: Rect) void {
        _ = self;

        const help_width: u16 = 60;
        const help_height: u16 = 18;
        const help_x = (area.width - help_width) / 2;
        const help_y = (area.height - help_height) / 2;

        const help_rect = Rect{
            .x = help_x,
            .y = help_y,
            .width = help_width,
            .height = help_height,
        };

        // Fill background
        buf.fillRect(help_rect, ' ', Style.default);

        // Draw border
        const panel = widgets.Panel{
            .title = "Help",
            .border = .double,
            .border_style = Style.default.withFg(.cyan),
        };
        panel.draw(buf, help_rect);

        const inner = panel.innerRect(help_rect);

        const help_lines = [_][]const u8{
            "Navigation:",
            "  Up/Down, j/k    Move selection",
            "  PgUp/PgDown     Page up/down",
            "  Home/End        Go to first/last",
            "",
            "Selection:",
            "  Space           Toggle selection",
            "  a               Select all",
            "  n               Deselect all",
            "",
            "Actions:",
            "  Enter           View details",
            "  d               Delete selected",
            "  s               Start scan",
            "  q               Quit",
        };

        var y: u16 = 0;
        for (help_lines) |line| {
            if (y >= inner.height) break;
            buf.drawString(inner.x + 2, inner.y + y, line, Style.default);
            y += 1;
        }
    }

    /// Add demo files for testing
    pub fn addDemoFiles(self: *App) !void {
        const demo_files = [_]struct {
            name: []const u8,
            path: []const u8,
            size: u64,
            category: analyzer_mod.FileCategory,
            confidence: f32,
        }{
            .{ .name = "temp_file.tmp", .path = "/tmp/temp_file.tmp", .size = 1024 * 50, .category = .temporary, .confidence = 0.95 },
            .{ .name = "cache_data.dat", .path = "~/.cache/app/cache_data.dat", .size = 1024 * 1024 * 5, .category = .cache, .confidence = 0.85 },
            .{ .name = "duplicate_photo.jpg", .path = "~/Pictures/duplicate_photo.jpg", .size = 1024 * 1024 * 3, .category = .duplicate, .confidence = 0.90 },
            .{ .name = "large_video.mp4", .path = "~/Downloads/large_video.mp4", .size = 1024 * 1024 * 500, .category = .large, .confidence = 0.70 },
            .{ .name = "old_backup.bak", .path = "~/Documents/old_backup.bak", .size = 1024 * 1024 * 100, .category = .temporary, .confidence = 0.80 },
            .{ .name = "system.log", .path = "/var/log/system.log", .size = 1024 * 1024 * 25, .category = .log, .confidence = 0.75 },
            .{ .name = "node_modules", .path = "~/projects/app/node_modules", .size = 1024 * 1024 * 200, .category = .dev_artifact, .confidence = 0.88 },
            .{ .name = "unused_doc.pdf", .path = "~/Documents/unused_doc.pdf", .size = 1024 * 1024 * 2, .category = .unused, .confidence = 0.60 },
            .{ .name = "old_download.zip", .path = "~/Downloads/old_download.zip", .size = 1024 * 1024 * 50, .category = .old_download, .confidence = 0.72 },
            .{ .name = "browser_cache", .path = "~/.chrome/cache", .size = 1024 * 1024 * 150, .category = .browser_data, .confidence = 0.82 },
        };

        for (demo_files) |f| {
            try self.state.files.append(self.allocator, FileItem{
                .name = f.name,
                .path = f.path,
                .size = f.size,
                .category = f.category,
                .selected = false,
                .confidence = f.confidence,
            });
            self.state.total_size += f.size;
        }
    }
};

// Helper functions
fn formatSizeCompact(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "K", "M", "G", "T" };
    var size: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;

    while (size >= 1024 and unit_idx < units.len - 1) {
        size /= 1024;
        unit_idx += 1;
    }

    return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ size, units[unit_idx] }) catch "???";
}

fn getCategoryStyle(category: analyzer_mod.FileCategory, is_selected: bool) Style {
    const base = if (is_selected) Style.default.withReverse() else Style.default;
    return switch (category) {
        .temporary => base.withFg(.yellow),
        .cache => base.withFg(.cyan),
        .duplicate => base.withFg(.magenta),
        .large => base.withFg(.red),
        .log => base.withFg(.blue),
        .unused => base.withFg(.white),
        .old_download => base.withFg(.yellow),
        .dev_artifact => base.withFg(.green),
        .browser_data => base.withFg(.cyan),
        .normal => base,
    };
}

// Tests
test "app state initialization" {
    const allocator = std.testing.allocator;
    var state = AppState.init(allocator);
    defer state.deinit();

    try std.testing.expect(state.files.items.len == 0);
    try std.testing.expect(state.selected_index == 0);
}

test "app state navigation" {
    const allocator = std.testing.allocator;
    var state = AppState.init(allocator);
    defer state.deinit();

    // Add some test files
    try state.files.append(allocator, FileItem{
        .name = "test1",
        .path = "/test1",
        .size = 100,
        .category = .normal,
        .selected = false,
        .confidence = 0.5,
    });
    try state.files.append(allocator, FileItem{
        .name = "test2",
        .path = "/test2",
        .size = 200,
        .category = .normal,
        .selected = false,
        .confidence = 0.5,
    });

    state.moveDown();
    try std.testing.expect(state.selected_index == 1);

    state.moveUp();
    try std.testing.expect(state.selected_index == 0);
}

test "format size compact" {
    var buf: [16]u8 = undefined;

    const kb = formatSizeCompact(1024, &buf);
    try std.testing.expect(std.mem.startsWith(u8, kb, "1.0K"));

    const mb = formatSizeCompact(1024 * 1024, &buf);
    try std.testing.expect(std.mem.startsWith(u8, mb, "1.0M"));
}
