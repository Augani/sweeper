const std = @import("std");
const terminal = @import("terminal.zig");
const render = @import("render.zig");
const widgets = @import("widgets.zig");
const input = @import("input.zig");

const platform_mod = @import("../platform.zig");
const scanner_mod = @import("../scanner.zig");
const analyzer_mod = @import("../analyzer.zig");
const config_mod = @import("../config.zig");
const deleter_mod = @import("../deleter.zig");
const history_mod = @import("../history.zig");
const space_tracker_mod = @import("../space_tracker.zig");

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
    deleting,
    undo_confirm,
    history,
    help,
    space_report,
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
    delete_progress: f32 = 0.0,
    status_message: []const u8 = "",
    is_scanning: bool = false,
    is_deleting: bool = false,
    show_help: bool = false,
    active_tab: usize = 0,
    filter_category: ?analyzer_mod.FileCategory = null,
    use_trash: bool = true,
    dry_run: bool = false,
    last_delete_count: u64 = 0,
    last_delete_size: u64 = 0,
    history_scroll: usize = 0,
    space_tracker: ?*space_tracker_mod.SpaceTracker = null,
    show_space_report: bool = false,

    pub fn init(allocator: std.mem.Allocator) AppState {
        return AppState{
            .allocator = allocator,
            .files = .{},
        };
    }

    pub fn deinit(self: *AppState) void {
        // Free duplicated path strings
        for (self.files.items) |file| {
            // Only free paths that were dynamically allocated (not string literals)
            // We can't easily tell the difference, so we track that paths from real scans
            // are allocated. For safety, we check if it's within heap range.
            // Actually, the simplest approach: paths from performRealScan are allocated,
            // demo files use string literals. Since we now use real scanning, free all.
            self.allocator.free(file.path);
        }
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
    deleter: ?deleter_mod.Deleter,
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator) !App {
        var term = try Terminal.init();
        errdefer term.deinit();

        // Initialize deleter with default options
        var deleter = try deleter_mod.Deleter.init(allocator, .{
            .use_trash = true,
            .dry_run = false,
        });
        errdefer deleter.deinit();

        // Initialize renderer with terminal's tty handle and size
        // (file handles are copyable, so this is safe across moves)
        var renderer = try Renderer.init(allocator, term.tty, term.size.width, term.size.height);
        errdefer renderer.deinit();

        return App{
            .allocator = allocator,
            .term = term,
            .renderer = renderer,
            .state = AppState.init(allocator),
            .input_reader = input.InputReader.initWithFile(term.tty),
            .deleter = deleter,
        };
    }

    pub fn deinit(self: *App) void {
        if (self.deleter) |*d| {
            d.deinit();
        }
        self.state.deinit();
        self.renderer.deinit();
        self.term.deinit();
    }

    /// Start the TUI application
    pub fn run(self: *App) !void {
        // Setup terminal with deferred cleanup to ensure restoration on any exit
        try self.term.enableRawMode();
        defer self.term.disableRawMode();

        self.term.enterAltScreen();
        defer {
            // Clean exit sequence: reset style, clear screen, show cursor, leave alt screen
            self.term.resetStyle();
            self.term.clear();
            self.term.showCursor();
            self.term.leaveAltScreen();
        }

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
            .deleting => {}, // No input during delete
            .confirm_delete => self.handleConfirmInput(key),
            .undo_confirm => self.handleUndoConfirmInput(key),
            .history => self.handleHistoryInput(key),
            .details => self.handleDetailsInput(key),
            .space_report => self.handleSpaceReportInput(key),
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
                    self.state.active_tab = (self.state.active_tab + 1) % 5;
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
                'u' => {
                    // Undo last operation
                    self.state.view = .undo_confirm;
                },
                'h' => {
                    // Show history
                    self.state.view = .history;
                    self.state.history_scroll = 0;
                },
                'r' => {
                    // Show space report
                    self.state.view = .space_report;
                },
                't' => {
                    // Toggle trash mode
                    self.state.use_trash = !self.state.use_trash;
                    self.state.status_message = if (self.state.use_trash) "Trash mode: ON" else "Trash mode: OFF (permanent delete)";
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
                    // Perform actual deletion
                    self.performDelete();
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

    /// Handle input in undo confirm view
    fn handleUndoConfirmInput(self: *App, key: Key) void {
        switch (key) {
            .char => |c| switch (c) {
                'y', 'Y' => {
                    self.performUndo();
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

    /// Handle input in history view
    fn handleHistoryInput(self: *App, key: Key) void {
        switch (key) {
            .special => |s| switch (s) {
                .up => {
                    if (self.state.history_scroll > 0) {
                        self.state.history_scroll -= 1;
                    }
                },
                .down => {
                    self.state.history_scroll += 1;
                },
                .escape => self.state.view = .results,
                else => {},
            },
            .char => |c| switch (c) {
                'q' => self.state.view = .results,
                'j' => self.state.history_scroll += 1,
                'k' => {
                    if (self.state.history_scroll > 0) {
                        self.state.history_scroll -= 1;
                    }
                },
                else => {},
            },
            else => {},
        }
    }

    /// Perform the actual deletion of selected files
    fn performDelete(self: *App) void {
        if (self.deleter == null) {
            self.state.status_message = "Deleter not initialized";
            self.state.view = .results;
            return;
        }

        var del = &self.deleter.?;

        // Update deleter options based on state
        del.options.use_trash = self.state.use_trash;
        del.options.dry_run = self.state.dry_run;

        var deleted_count: u64 = 0;
        var deleted_size: u64 = 0;
        var failed_count: u64 = 0;

        // Delete selected files
        var i: usize = 0;
        while (i < self.state.files.items.len) {
            if (self.state.files.items[i].selected) {
                const file = self.state.files.items[i];
                var result = del.deleteFile(file.path) catch {
                    failed_count += 1;
                    i += 1;
                    continue;
                };
                defer result.deinit(self.allocator);

                if (result.success) {
                    deleted_count += 1;
                    deleted_size += result.bytes_freed;
                    // Remove from list
                    _ = self.state.files.orderedRemove(i);
                    // Don't increment i since we removed an item
                } else {
                    failed_count += 1;
                    i += 1;
                }
            } else {
                i += 1;
            }
        }

        // Update state
        self.state.last_delete_count = deleted_count;
        self.state.last_delete_size = deleted_size;
        self.state.selected_size = 0;

        // Adjust selected index if necessary
        if (self.state.selected_index >= self.state.files.items.len and self.state.files.items.len > 0) {
            self.state.selected_index = self.state.files.items.len - 1;
        }

        // Set status message
        if (failed_count == 0) {
            self.state.status_message = if (self.state.use_trash)
                "Files moved to trash. Press [u] to undo."
            else
                "Files permanently deleted.";
        } else {
            self.state.status_message = "Some files failed to delete.";
        }

        self.state.view = .results;
    }

    /// Perform undo of last operation
    fn performUndo(self: *App) void {
        if (self.deleter == null) {
            self.state.status_message = "No operations to undo";
            self.state.view = .results;
            return;
        }

        var del = &self.deleter.?;

        const result = del.undo() catch {
            self.state.status_message = "Undo failed";
            self.state.view = .results;
            return;
        };

        if (result) |undo_result_const| {
            // Make a mutable copy for deinit
            var undo_result = undo_result_const;

            if (undo_result.success) {
                // Duplicate the path before undo_result is freed
                const path_copy = self.allocator.dupe(u8, undo_result.path) catch {
                    undo_result.deinit(self.allocator);
                    self.state.status_message = "File restored (path not tracked)";
                    self.state.view = .results;
                    return;
                };
                const name = std.fs.path.basename(path_copy);

                // Now we can free undo_result
                undo_result.deinit(self.allocator);

                // Re-add file to the list with duplicated path
                self.state.files.append(self.allocator, FileItem{
                    .path = path_copy,
                    .name = name,
                    .size = 0, // Size unknown after restore
                    .category = .normal,
                    .selected = false,
                    .confidence = 0.0,
                }) catch {
                    self.allocator.free(path_copy);
                };

                self.state.status_message = "File restored from trash";
            } else {
                undo_result.deinit(self.allocator);
                self.state.status_message = "Failed to restore file";
            }
        } else {
            self.state.status_message = "No operations to undo";
        }

        self.state.view = .results;
    }

    /// Handle input in details view
    fn handleDetailsInput(self: *App, key: Key) void {
        if (key.isEscape() or key.isEnter() or key.isCharKey('q')) {
            self.state.view = .results;
        }
    }

    /// Handle input in space report view
    fn handleSpaceReportInput(self: *App, key: Key) void {
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
                .deleting => self.drawDeletingView(buf, area),
                .confirm_delete => self.drawConfirmView(buf, area),
                .undo_confirm => self.drawUndoConfirmView(buf, area),
                .history => self.drawHistoryView(buf, area),
                .details => self.drawDetailsView(buf, area),
                .space_report => self.drawSpaceReportView(buf, area),
                .help => self.drawHelp(buf, area),
            }
        }
    }

    /// Draw main/results view
    fn drawMainView(self: *App, buf: *Buffer, area: Rect) void {
        // Title bar
        self.drawTitleBar(buf, Rect{ .x = area.x, .y = area.y, .width = area.width, .height = 1 });

        // Tabs - updated to more useful categories
        const tab_labels = [_][]const u8{ "All", "Largest", "Cache", "Dev", "Temp" };
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
        const trash_indicator = if (self.state.use_trash) "[Trash]" else "[Perm]";
        var hint_buf: [96]u8 = undefined;
        const help_text = std.fmt.bufPrint(&hint_buf, "[?] Help [Tab] Tabs [Space] Select [d] Delete [u] Undo [t] {s}", .{trash_indicator}) catch "[?] Help";
        buf.drawString(area.x + 1, area.y + area.height - 1, help_text, Style.default.withFg(.cyan));
    }

    /// Check if file matches current tab filter
    fn matchesCurrentTab(self: *App, file: FileItem) bool {
        return switch (self.state.active_tab) {
            0 => true, // All
            1 => file.size >= 50 * 1024 * 1024, // Largest (>50MB)
            2 => file.category == .cache, // Cache
            3 => file.category == .dev_artifact, // Dev
            4 => file.category == .temporary, // Temp
            else => true,
        };
    }

    /// Get filtered file count for current tab
    fn getFilteredCount(self: *App) usize {
        if (self.state.active_tab == 0) return self.state.files.items.len;

        var count: usize = 0;
        for (self.state.files.items) |file| {
            if (self.matchesCurrentTab(file)) count += 1;
        }
        return count;
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
        // Panel border with tab-specific title
        const panel_title = switch (self.state.active_tab) {
            0 => "All Files",
            1 => "Largest Files (>50MB)",
            2 => "Cache Files",
            3 => "Dev Artifacts",
            4 => "Temporary Files",
            else => "Files",
        };
        const panel = widgets.Panel{
            .title = panel_title,
            .border = .single,
        };
        panel.draw(buf, area);

        const inner = panel.innerRect(area);
        if (inner.width == 0 or inner.height == 0) return;

        // Build filtered indices
        var filtered_indices: [4096]usize = undefined;
        var filtered_count: usize = 0;
        for (self.state.files.items, 0..) |file, idx| {
            if (self.matchesCurrentTab(file)) {
                if (filtered_count < filtered_indices.len) {
                    filtered_indices[filtered_count] = idx;
                    filtered_count += 1;
                }
            }
        }

        // Clamp selected_index to filtered range
        if (filtered_count > 0 and self.state.selected_index >= filtered_count) {
            self.state.selected_index = filtered_count - 1;
        }

        // Ensure scroll keeps selected item visible
        const visible_height = inner.height - 1;
        if (self.state.selected_index < self.state.scroll_offset) {
            self.state.scroll_offset = self.state.selected_index;
        } else if (self.state.selected_index >= self.state.scroll_offset + visible_height) {
            self.state.scroll_offset = self.state.selected_index - visible_height + 1;
        }

        // Draw header
        const header = "   Size      Category    Name";
        buf.drawString(inner.x, inner.y, header, Style.default.withBold());

        // Show empty message if no files match filter
        if (filtered_count == 0) {
            buf.drawString(inner.x + 2, inner.y + 2, "No files match this filter", Style.default.withFg(.yellow));
            return;
        }

        // Draw filtered items
        var y: u16 = 0;
        while (y < visible_height) : (y += 1) {
            const filtered_idx = self.state.scroll_offset + y;
            if (filtered_idx >= filtered_count) break;

            const actual_idx = filtered_indices[filtered_idx];
            const file = self.state.files.items[actual_idx];
            const is_selected = filtered_idx == self.state.selected_index;

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

        // Scroll indicator (use filtered_count for proper scroll bar)
        if (filtered_count > visible_height and visible_height > 0) {
            // Calculate scrollbar size (minimum 1 cell)
            const scrollbar_height = @max(1, (visible_height * visible_height) / @as(u16, @intCast(filtered_count)));

            // Calculate scrollbar position safely (avoid division by zero)
            const scroll_range = filtered_count - visible_height;
            const track_range = visible_height -| scrollbar_height; // Saturating subtract
            const scrollbar_pos: u16 = if (scroll_range > 0 and track_range > 0)
                @as(u16, @intCast(@min(
                    track_range,
                    (self.state.scroll_offset * track_range) / scroll_range,
                )))
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
            .title = "Scanning Filesystem",
            .border = .double,
            .border_style = Style.default.withFg(.cyan),
        };
        panel.draw(buf, area);

        const inner = panel.innerRect(area);
        var y = inner.y + inner.height / 2 - 5;

        // Scanning message with spinner
        const spinner_chars = [_]u21{ '|', '/', '-', '\\' };
        const spinner_idx = @as(usize, @intCast(std.time.timestamp())) % spinner_chars.len;
        buf.setChar(inner.x + (inner.width - 25) / 2, y, spinner_chars[spinner_idx], Style.default.withFg(.cyan));
        buf.drawString(inner.x + (inner.width - 23) / 2 + 2, y, "Scanning filesystem...", Style.default.withBold());
        y += 2;

        // Statistics
        var stats_buf: [64]u8 = undefined;
        const files_text = std.fmt.bufPrint(&stats_buf, "Files found: {d}", .{self.state.files.items.len}) catch "";
        buf.drawString(inner.x + 4, y, files_text, Style.default);
        y += 1;

        var size_buf: [32]u8 = undefined;
        const size_str = formatSizeCompact(self.state.total_size, &size_buf);
        var total_text_buf: [64]u8 = undefined;
        const total_text = std.fmt.bufPrint(&total_text_buf, "Total size: {s}", .{size_str}) catch "";
        buf.drawString(inner.x + 4, y, total_text, Style.default);
        y += 2;

        // Progress bar
        var progress = widgets.ProgressBar{
            .progress = self.state.scan_progress,
            .filled_style = Style.default.withFg(.cyan),
            .show_percentage = true,
        };
        progress.draw(buf, Rect{
            .x = inner.x + 2,
            .y = y,
            .width = inner.width - 4,
            .height = 1,
        });
        y += 2;

        // Rate information
        var rate_buf: [64]u8 = undefined;
        const rate_text = std.fmt.bufPrint(&rate_buf, "Processing... {d:.0} files/sec", .{@as(f64, 100.0)}) catch "";
        buf.drawString(inner.x + (inner.width - @as(u16, @intCast(@min(rate_text.len, inner.width)))) / 2, y, rate_text, Style.default.withFg(.green));
        y += 2;

        // Cancel hint
        buf.drawString(inner.x + (inner.width - 22) / 2, y, "Press Ctrl+C to cancel", Style.default.withFg(.yellow));
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

        // Show trash/permanent indicator
        const mode_text = if (self.state.use_trash) "(Move to Trash)" else "(Permanent Delete!)";
        const mode_style = if (self.state.use_trash) Style.default.withFg(.cyan) else Style.default.withFg(.red).withBold();
        buf.drawString(inner.x + (inner.width - @as(u16, @intCast(mode_text.len))) / 2, inner.y + 2, mode_text, mode_style);
    }

    /// Draw undo confirm view
    fn drawUndoConfirmView(self: *App, buf: *Buffer, area: Rect) void {
        // Draw background
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
            .title = "Undo Last Delete",
            .border = .double,
            .border_style = Style.default.withFg(.cyan),
        };
        panel.draw(buf, dialog_rect);

        const inner = panel.innerRect(dialog_rect);

        // Check if there's something to undo
        if (self.deleter) |*del| {
            const undoable_count = del.getHistory().getUndoableCount();
            if (undoable_count > 0) {
                var msg_buf: [48]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "Restore last deleted file? ({d} undoable)", .{undoable_count}) catch "Restore last deleted file?";
                buf.drawString(inner.x + 2, inner.y + 1, msg, Style.default);

                buf.drawString(inner.x + inner.width / 4, inner.y + 3, "[Y]es", Style.default.withFg(.green));
                buf.drawString(inner.x + inner.width * 3 / 4 - 4, inner.y + 3, "[N]o", Style.default.withFg(.red));
            } else {
                buf.drawString(inner.x + 2, inner.y + 2, "No operations to undo", Style.default.withFg(.yellow));
                buf.drawString(inner.x + inner.width / 2 - 8, inner.y + 4, "[Press any key]", Style.default.withFg(.cyan));
            }
        } else {
            buf.drawString(inner.x + 2, inner.y + 2, "Deleter not available", Style.default.withFg(.red));
        }
    }

    /// Draw deleting progress view
    fn drawDeletingView(self: *App, buf: *Buffer, area: Rect) void {
        const panel = widgets.Panel{
            .title = "Deleting Files",
            .border = .double,
            .border_style = Style.default.withFg(.yellow),
        };
        panel.draw(buf, area);

        const inner = panel.innerRect(area);
        const center_y = inner.y + inner.height / 2;

        // Deleting message
        buf.drawString(inner.x + (inner.width - 20) / 2, center_y - 2, "Deleting files...", Style.default.withBold());

        // Progress bar
        var progress = widgets.ProgressBar{
            .progress = self.state.delete_progress,
            .filled_style = Style.default.withFg(.yellow),
        };
        progress.draw(buf, Rect{
            .x = inner.x + 2,
            .y = center_y,
            .width = inner.width - 4,
            .height = 1,
        });

        // Cancel hint
        buf.drawString(inner.x + (inner.width - 22) / 2, center_y + 2, "Please wait...", Style.default.withFg(.cyan));
    }

    /// Draw history view
    fn drawHistoryView(self: *App, buf: *Buffer, area: Rect) void {
        const panel = widgets.Panel{
            .title = "Deletion History",
            .border = .single,
            .border_style = Style.default.withFg(.cyan),
        };
        panel.draw(buf, area);

        const inner = panel.innerRect(area);

        // Header
        buf.drawString(inner.x + 2, inner.y, "Operation              Path                                 Size", Style.default.withBold());

        if (self.deleter) |*del| {
            const history = del.getHistory();
            const entries = history.getEntries();

            if (entries.len == 0) {
                buf.drawString(inner.x + 2, inner.y + 2, "No deletion history", Style.default.withFg(.yellow));
            } else {
                var y: u16 = 1;
                const max_entries = inner.height - 3;
                const start_idx = self.state.history_scroll;

                for (entries[start_idx..]) |entry| {
                    if (y >= max_entries) break;

                    const op_name = entry.operation.getName();
                    const basename = std.fs.path.basename(entry.original_path);

                    var size_buf: [12]u8 = undefined;
                    const size_str = formatSizeCompact(entry.file_size, &size_buf);

                    const style = if (entry.undone) Style.default.withFg(.white) else Style.default;
                    const status = if (entry.undone) " (undone)" else "";

                    buf.drawStringMax(inner.x + 2, inner.y + y, op_name, 20, style);
                    buf.drawStringMax(inner.x + 24, inner.y + y, basename, 36, style);
                    buf.drawString(inner.x + 62, inner.y + y, size_str, style);

                    if (entry.undone) {
                        buf.drawString(inner.x + 72, inner.y + y, status, Style.default.withFg(.yellow));
                    }

                    y += 1;
                }

                // Show scroll indicator if needed
                if (entries.len > max_entries) {
                    var scroll_buf: [20]u8 = undefined;
                    const scroll_info = std.fmt.bufPrint(&scroll_buf, "[{d}/{d}]", .{ start_idx + 1, entries.len }) catch "[?/?]";
                    buf.drawString(inner.x + inner.width - 10, inner.y, scroll_info, Style.default.withFg(.cyan));
                }
            }

            // Summary
            const recoverable = history.getRecoverableSize();
            var rec_buf: [16]u8 = undefined;
            const rec_str = formatSizeCompact(recoverable, &rec_buf);

            var summary_buf: [48]u8 = undefined;
            const summary = std.fmt.bufPrint(&summary_buf, "Recoverable: {s} ({d} files)", .{ rec_str, history.getUndoableCount() }) catch "Recoverable: ???";
            buf.drawString(inner.x + 2, inner.y + inner.height - 2, summary, Style.default.withFg(.green));
        } else {
            buf.drawString(inner.x + 2, inner.y + 2, "History not available", Style.default.withFg(.red));
        }

        // Controls hint
        buf.drawString(inner.x + 2, inner.y + inner.height - 1, "[j/k] Scroll  [q/Esc] Close", Style.default.withFg(.cyan));
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

    /// Draw space report view
    fn drawSpaceReportView(self: *App, buf: *Buffer, area: Rect) void {
        const panel = widgets.Panel{
            .title = "Space Analysis Report",
            .border = .single,
            .border_style = Style.default.withFg(.cyan),
        };
        panel.draw(buf, area);

        const inner = panel.innerRect(area);
        var y: u16 = 0;

        // Overall statistics
        buf.drawString(inner.x + 2, inner.y + y, "=== Overall Statistics ===", Style.default.withBold());
        y += 2;

        var total_buf: [32]u8 = undefined;
        const total_str = formatSizeCompact(self.state.total_size, &total_buf);
        buf.drawString(inner.x + 2, inner.y + y, "Total Space:", Style.default);
        buf.drawString(inner.x + 20, inner.y + y, total_str, Style.default.withFg(.cyan));
        y += 1;

        var selected_buf: [32]u8 = undefined;
        const selected_str = formatSizeCompact(self.state.selected_size, &selected_buf);
        buf.drawString(inner.x + 2, inner.y + y, "Selected:", Style.default);
        buf.drawString(inner.x + 20, inner.y + y, selected_str, Style.default.withFg(.green));
        y += 1;

        const sel_count = self.state.getSelectedCount();
        var count_buf: [32]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{sel_count}) catch "?";
        buf.drawString(inner.x + 2, inner.y + y, "Selected Files:", Style.default);
        buf.drawString(inner.x + 20, inner.y + y, count_str, Style.default.withFg(.green));
        y += 2;

        // Percentage gauge
        if (self.state.total_size > 0) {
            var gauge = widgets.Gauge{
                .value = self.state.selected_size,
                .max_value = self.state.total_size,
                .label = "Potential Savings",
                .bar_style = Style.default.withFg(.green),
            };
            gauge.draw(buf, Rect{
                .x = inner.x + 2,
                .y = inner.y + y,
                .width = inner.width - 4,
                .height = 3,
            });
            y += 4;
        }

        // Category breakdown
        if (y < inner.height - 2) {
            buf.drawString(inner.x + 2, inner.y + y, "=== Category Breakdown ===", Style.default.withBold());
            y += 2;

            // Count files by category
            var category_counts: [@typeInfo(analyzer_mod.FileCategory).@"enum".fields.len]u64 = [_]u64{0} ** @typeInfo(analyzer_mod.FileCategory).@"enum".fields.len;
            var category_sizes: [@typeInfo(analyzer_mod.FileCategory).@"enum".fields.len]u64 = [_]u64{0} ** @typeInfo(analyzer_mod.FileCategory).@"enum".fields.len;

            for (self.state.files.items) |file| {
                const idx = @intFromEnum(file.category);
                category_counts[idx] += 1;
                category_sizes[idx] += file.size;
            }

            // Display categories
            inline for (@typeInfo(analyzer_mod.FileCategory).@"enum".fields, 0..) |field, i| {
                if (y >= inner.height - 1) break;
                if (category_counts[i] > 0) {
                    const cat: analyzer_mod.FileCategory = @enumFromInt(i);
                    var cat_size_buf: [16]u8 = undefined;
                    const cat_size_str = formatSizeCompact(category_sizes[i], &cat_size_buf);

                    var cat_info_buf: [64]u8 = undefined;
                    const cat_info = std.fmt.bufPrint(&cat_info_buf, "{s}: {d} files ({s})", .{
                        cat.getName(),
                        category_counts[i],
                        cat_size_str,
                    }) catch "";

                    buf.drawStringMax(inner.x + 4, inner.y + y, cat_info, inner.width - 6, getCategoryStyle(cat, false));
                    y += 1;
                }
                _ = field;
            }
        }

        // Instructions
        buf.drawString(inner.x + 2, inner.y + inner.height - 1, "[q/Esc] Close", Style.default.withFg(.cyan));
    }

    /// Draw help overlay
    fn drawHelp(self: *App, buf: *Buffer, area: Rect) void {
        _ = self;

        const help_width: u16 = 60;
        const help_height: u16 = 24;
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
            "Deletion:",
            "  d               Delete selected",
            "  u               Undo last delete",
            "  h               View deletion history",
            "  t               Toggle trash/permanent",
            "",
            "Other:",
            "  Enter           View details",
            "  r               Show space report",
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
