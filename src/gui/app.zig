//! Main GUI Application
//!
//! Dashboard Design Implementation

const std = @import("std");
const rl = @import("raylib");

const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const scanner = @import("../scanner.zig");
const analyzer = @import("../analyzer.zig");
const config = @import("../config.zig");
const deleter = @import("../deleter.zig");
const platform = @import("../platform.zig");

/// File item for display
pub const FileItem = struct {
    path: []const u8,
    name: []const u8,
    size: u64,
    category: analyzer.FileCategory,
    selected: bool,
    confidence: f32,
    mtime: i128, // Last modification time (nanoseconds)
    days_old: u32, // Days since last modification

    /// Check if this item is considered stale (default 90 days)
    pub fn isStale(self: FileItem, threshold_days: u32) bool {
        return self.days_old >= threshold_days;
    }
};

/// Tab filter enum
pub const Tab = enum(usize) {
    all = 0,
    largest = 1,
    cache = 2,
    dev = 3,
    temp = 4,

    pub fn name(self: Tab) [:0]const u8 {
        return switch (self) {
            .all => "All Files",
            .largest => "Largest",
            .cache => "Cache",
            .dev => "Dev Artifacts",
            .temp => "Temporary",
        };
    }

    pub fn icon(self: Tab) [:0]const u8 {
        return switch (self) {
            .all => "A", // Placeholder icons
            .largest => "L",
            .cache => "C",
            .dev => "D",
            .temp => "T",
        };
    }
};

/// View state
pub const View = enum {
    idle,
    scanning,
    analyzing,
    results,
    deleting,
};

/// Scan phase for incremental scanning
pub const ScanPhase = enum {
    not_started,
    waiting_for_discovery, // Background thread running find command
    processing_results, // Processing discovered paths
    calculating_sizes, // Calculating sizes incrementally
    done,
};

/// Dialog state
pub const Dialog = enum {
    none,
    confirm_delete,
};

/// Main GUI Application
pub const GuiApp = struct {
    allocator: std.mem.Allocator,

    // State
    files: std.ArrayListUnmanaged(FileItem),
    selected_index: usize,
    scroll_offset: usize,
    active_tab: Tab,
    view: View,
    dialog: Dialog,
    should_quit: bool,

    // Statistics
    total_size: u64,
    selected_count: usize,
    selected_size: u64,
    scan_progress: f32,
    status_message: []const u8,
    status_buf: [128]u8, // Buffer for formatted status messages

    // Chart stats
    category_sizes: [10]u64,

    // Deletion
    file_deleter: ?*deleter.Deleter,
    delete_progress: f32,

    // Cached filtered list
    filtered_indices: std.ArrayListUnmanaged(usize),

    // Incremental scan state
    scan_phase: ScanPhase,
    scan_paths_to_process: std.ArrayListUnmanaged([]const u8),
    scan_current_path_idx: usize,
    scan_pending_dirs: std.ArrayListUnmanaged([]const u8),
    scan_file_results: std.ArrayListUnmanaged(scanner.FileInfo),
    scan_files_processed: usize,

    // Background scan thread
    scan_thread: ?std.Thread,
    scan_thread_done: bool,
    scan_thread_result: ?[]u8,
    scan_home_path: ?[]u8,

    pub fn init(allocator: std.mem.Allocator) !GuiApp {
        return GuiApp{
            .allocator = allocator,
            .files = .{},
            .selected_index = 0,
            .scroll_offset = 0,
            .active_tab = .all,
            .view = .idle,
            .dialog = .none,
            .should_quit = false,
            .total_size = 0,
            .selected_count = 0,
            .selected_size = 0,
            .scan_progress = 0,
            .status_message = "Ready to scan",
            .status_buf = [_]u8{0} ** 128,
            .category_sizes = [_]u64{0} ** 10,
            .file_deleter = null,
            .delete_progress = 0,
            .filtered_indices = .{},
            .scan_phase = .not_started,
            .scan_paths_to_process = .{},
            .scan_current_path_idx = 0,
            .scan_pending_dirs = .{},
            .scan_file_results = .{},
            .scan_files_processed = 0,
            .scan_thread = null,
            .scan_thread_done = false,
            .scan_thread_result = null,
            .scan_home_path = null,
        };
    }

    /// Free a FileItem's allocated memory
    fn freeFileItem(self: *GuiApp, file: FileItem) void {
        // Check if name is separately allocated (not a slice of path)
        // If name pointer is outside the path memory range, it needs to be freed
        const path_start = @intFromPtr(file.path.ptr);
        const path_end = path_start + file.path.len;
        const name_ptr = @intFromPtr(file.name.ptr);
        if (name_ptr < path_start or name_ptr >= path_end) {
            self.allocator.free(file.name);
        }
        self.allocator.free(file.path);
    }

    pub fn deinit(self: *GuiApp) void {
        // Wait for scan thread if running
        if (self.scan_thread) |thread| {
            thread.join();
        }

        for (self.files.items) |file| {
            self.freeFileItem(file);
        }
        self.files.deinit(self.allocator);
        self.filtered_indices.deinit(self.allocator);

        // Clean up scan state
        for (self.scan_paths_to_process.items) |path| {
            self.allocator.free(path);
        }
        self.scan_paths_to_process.deinit(self.allocator);

        for (self.scan_pending_dirs.items) |path| {
            self.allocator.free(path);
        }
        self.scan_pending_dirs.deinit(self.allocator);

        for (self.scan_file_results.items) |*file| {
            self.allocator.free(file.path);
        }
        self.scan_file_results.deinit(self.allocator);

        if (self.scan_thread_result) |r| {
            self.allocator.free(r);
        }
        if (self.scan_home_path) |h| {
            self.allocator.free(h);
        }

        if (self.file_deleter) |d| {
            d.deinit();
            self.allocator.destroy(d);
        }
    }

    /// Start filesystem scan using fast system commands
    pub fn startScan(self: *GuiApp) void {
        const builtin = @import("builtin");

        // Wait for any existing scan thread
        if (self.scan_thread) |thread| {
            thread.join();
            self.scan_thread = null;
        }

        // Clear previous results
        for (self.files.items) |file| {
            self.freeFileItem(file);
        }
        self.files.clearRetainingCapacity();
        self.filtered_indices.clearRetainingCapacity();
        self.total_size = 0;
        self.selected_size = 0;
        self.selected_count = 0;
        self.category_sizes = [_]u64{0} ** 10;
        self.scan_files_processed = 0;

        // Clean up previous thread result
        if (self.scan_thread_result) |r| {
            self.allocator.free(r);
            self.scan_thread_result = null;
        }
        if (self.scan_home_path) |h| {
            self.allocator.free(h);
        }

        // Get home directory
        self.scan_home_path = if (builtin.os.tag == .windows)
            std.process.getEnvVarOwned(self.allocator, "USERPROFILE") catch
                std.process.getEnvVarOwned(self.allocator, "HOMEDRIVE") catch null
        else
            std.process.getEnvVarOwned(self.allocator, "HOME") catch null;

        self.view = .scanning;
        self.scan_phase = .waiting_for_discovery;
        self.scan_progress = 0.05;
        self.scan_thread_done = false;

        // Spawn background thread for find command
        self.scan_thread = std.Thread.spawn(.{}, scanThreadFn, .{self}) catch null;
    }

    /// Background thread function for scanning
    fn scanThreadFn(self: *GuiApp) void {
        const builtin = @import("builtin");
        const home = self.scan_home_path orelse return;

        // Run the find command (this is blocking but in a separate thread)
        const result = if (builtin.os.tag == .windows)
            self.findDevArtifactsWindows(home)
        else
            self.findDevArtifactsUnix(home);

        self.scan_thread_result = result;
        self.scan_thread_done = true;
    }

    /// Process scan incrementally (called from update)
    fn processScanPhase(self: *GuiApp) void {
        switch (self.scan_phase) {
            .not_started => {},

            .waiting_for_discovery => {
                // Poll: Is background thread done?
                if (self.scan_thread_done) {
                    // Join the thread
                    if (self.scan_thread) |thread| {
                        thread.join();
                        self.scan_thread = null;
                    }

                    // Process results from find command
                    if (self.scan_thread_result) |stdout| {
                        self.parseFoundPaths(stdout);
                        self.allocator.free(stdout);
                        self.scan_thread_result = null;
                    }

                    // Add known cache directories (fast, no blocking)
                    if (self.scan_home_path) |home| {
                        self.addKnownCacheDirs(home);
                    }

                    self.scan_phase = .calculating_sizes;
                    self.scan_files_processed = 0;
                    self.scan_progress = 0.2;
                } else {
                    // Still waiting - animate progress
                    self.scan_progress = 0.05 + 0.1 * @as(f32, @floatCast(@mod(@as(f64, @floatCast(rl.getTime())), 1.0)));
                }
            },

            .processing_results => {
                // This phase is now combined with waiting_for_discovery
                self.scan_phase = .calculating_sizes;
            },

            .calculating_sizes => {
                // Calculate sizes incrementally (5 per frame for responsiveness)
                const batch_size: usize = 5;
                var processed: usize = 0;

                while (self.scan_files_processed < self.files.items.len and processed < batch_size) {
                    const file = &self.files.items[self.scan_files_processed];
                    file.size = self.getDirSize(file.path);
                    self.total_size += file.size;
                    self.category_sizes[@intFromEnum(file.category)] += file.size;

                    self.scan_files_processed += 1;
                    processed += 1;
                }

                // Update progress
                if (self.files.items.len > 0) {
                    self.scan_progress = 0.2 + 0.75 * (@as(f32, @floatFromInt(self.scan_files_processed)) / @as(f32, @floatFromInt(self.files.items.len)));
                }

                // Check if done
                if (self.scan_files_processed >= self.files.items.len) {
                    self.scan_phase = .done;
                }
            },

            .done => {
                // Sort by size descending
                std.mem.sort(FileItem, self.files.items, {}, struct {
                    fn f(_: void, a: FileItem, b: FileItem) bool {
                        return a.size > b.size;
                    }
                }.f);

                self.scan_progress = 1.0;
                self.view = .results;
                self.updateFilteredList();
            },
        }
    }

    /// Find dev artifacts using system find command (fast!)
    fn findDevArtifacts(self: *GuiApp, home: []const u8) void {
        const builtin = @import("builtin");

        // Platform-specific command to find dev artifacts
        const result = if (builtin.os.tag == .windows)
            self.findDevArtifactsWindows(home)
        else
            self.findDevArtifactsUnix(home);

        if (result) |stdout| {
            defer self.allocator.free(stdout);
            self.parseFoundPaths(stdout);
        }
    }

    /// Unix/macOS: Use find command
    fn findDevArtifactsUnix(self: *GuiApp, home: []const u8) ?[]u8 {
        const find_cmd = std.fmt.allocPrint(self.allocator,
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
        defer self.allocator.free(find_cmd);

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "/bin/sh", "-c", find_cmd },
            .max_output_bytes = 256 * 1024,
        }) catch return null;
        self.allocator.free(result.stderr);

        return result.stdout;
    }

    /// Windows: Use PowerShell Get-ChildItem
    fn findDevArtifactsWindows(self: *GuiApp, home: []const u8) ?[]u8 {
        // PowerShell command to find dev artifact directories
        // Using -Depth instead of -Recurse for performance
        const ps_cmd = std.fmt.allocPrint(self.allocator,
            \\Get-ChildItem -Path "{s}" -Directory -Depth 12 -ErrorAction SilentlyContinue |
            \\Where-Object {{ $_.Name -match '^(node_modules|target|\.build|build|dist|__pycache__|\.gradle|venv|\.venv|Pods|DerivedData|bin|obj)$' }} |
            \\Select-Object -First 200 -ExpandProperty FullName
        , .{home}) catch return null;
        defer self.allocator.free(ps_cmd);

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "powershell.exe", "-NoProfile", "-Command", ps_cmd },
            .max_output_bytes = 256 * 1024,
        }) catch return null;
        self.allocator.free(result.stderr);

        return result.stdout;
    }

    /// Parse found paths from command output
    fn parseFoundPaths(self: *GuiApp, stdout: []const u8) void {
        const now_ns = std.time.nanoTimestamp();

        var lines = std.mem.splitScalar(u8, stdout, '\n');
        while (lines.next()) |line| {
            // Trim carriage return for Windows
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len == 0) continue;

            const path = self.allocator.dupe(u8, trimmed) catch continue;
            const name = std.fs.path.basename(path);
            const category: analyzer.FileCategory = if (std.mem.eql(u8, name, "node_modules") or
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

            // Get modification time and calculate age
            var mtime: i128 = 0;
            var days_old: u32 = 0;

            if (std.fs.openDirAbsolute(path, .{})) |dir| {
                var d = dir;
                defer d.close();
                if (d.stat()) |stat| {
                    mtime = stat.mtime;
                    // Calculate days since last modification
                    const age_ns = now_ns - mtime;
                    if (age_ns > 0) {
                        const ns_per_day: i128 = 24 * 60 * 60 * 1_000_000_000;
                        days_old = @intCast(@divTrunc(age_ns, ns_per_day));
                    }
                } else |_| {}
            } else |_| {}

            // Set confidence based on category and age
            const confidence: f32 = if (category == .cache or category == .temporary)
                0.95
            else if (days_old > 90)
                0.90 // Stale dev artifacts are safer to delete
            else if (days_old > 30)
                0.80
            else
                0.70; // Active projects, lower confidence

            self.files.append(self.allocator, FileItem{
                .path = path,
                .name = name,
                .size = 0,
                .category = category,
                .selected = false,
                .confidence = confidence,
                .mtime = mtime,
                .days_old = days_old,
            }) catch {
                self.allocator.free(path);
                continue;
            };
        }
    }

    /// Add known cache directories without recursing into them
    /// Cross-platform support for macOS, Linux, and Windows
    fn addKnownCacheDirs(self: *GuiApp, home: []const u8) void {
        const builtin = @import("builtin");

        // Common paths (work on all Unix-like systems)
        const common_paths = [_]struct { suffix: []const u8, category: analyzer.FileCategory }{
            // Package manager caches (cross-platform)
            .{ .suffix = "/.npm", .category = .cache },
            .{ .suffix = "/.npm/_cacache", .category = .cache },
            .{ .suffix = "/.yarn", .category = .cache },
            .{ .suffix = "/.yarn/cache", .category = .cache },
            .{ .suffix = "/.pnpm-store", .category = .cache },
            .{ .suffix = "/.bun/install/cache", .category = .cache },
            // Rust
            .{ .suffix = "/.cargo/registry", .category = .cache },
            .{ .suffix = "/.cargo/git", .category = .cache },
            .{ .suffix = "/.rustup/toolchains", .category = .cache },
            // Java/Kotlin/Android
            .{ .suffix = "/.gradle/caches", .category = .cache },
            .{ .suffix = "/.gradle/wrapper/dists", .category = .cache },
            .{ .suffix = "/.gradle/daemon", .category = .cache },
            .{ .suffix = "/.m2/repository", .category = .cache },
            .{ .suffix = "/.android/cache", .category = .cache },
            .{ .suffix = "/.android/build-cache", .category = .cache },
            // Go
            .{ .suffix = "/go/pkg/mod", .category = .cache },
            .{ .suffix = "/.cache/go-build", .category = .cache },
            // Python
            .{ .suffix = "/.cache/pip", .category = .cache },
            .{ .suffix = "/.cache/pypoetry", .category = .cache },
            .{ .suffix = "/.local/pipx", .category = .cache },
            // Ruby
            .{ .suffix = "/.gem", .category = .cache },
            .{ .suffix = "/.bundle/cache", .category = .cache },
            // PHP
            .{ .suffix = "/.composer/cache", .category = .cache },
            // Dart/Flutter
            .{ .suffix = "/.pub-cache", .category = .cache },
            .{ .suffix = "/.flutter", .category = .cache },
            // IDE extensions (cross-platform)
            .{ .suffix = "/.vscode/extensions", .category = .cache },
            .{ .suffix = "/.vscode-insiders/extensions", .category = .cache },
            .{ .suffix = "/.cursor/extensions", .category = .cache },
            .{ .suffix = "/.windsurf/extensions", .category = .cache },
            .{ .suffix = "/.zed/extensions", .category = .cache },
            // JetBrains IDEs
            .{ .suffix = "/.cache/JetBrains", .category = .cache },
            // Electron apps
            .{ .suffix = "/.config/Slack/Cache", .category = .cache },
            .{ .suffix = "/.config/discord/Cache", .category = .cache },
            // Docker
            .{ .suffix = "/.docker/buildx", .category = .cache },
        };

        // macOS-specific paths
        // Note: We only scan specific subfolders, NOT parent folders like ~/Library/Caches
        // because the parent contains system caches that can't be deleted
        const macos_paths = [_]struct { suffix: []const u8, category: analyzer.FileCategory }{
            // Trash
            .{ .suffix = "/.Trash", .category = .temporary },
            // Xcode & iOS Development
            .{ .suffix = "/Library/Developer/Xcode/DerivedData", .category = .dev_artifact },
            .{ .suffix = "/Library/Developer/Xcode/Archives", .category = .dev_artifact },
            .{ .suffix = "/Library/Developer/CoreSimulator/Caches", .category = .cache },
            .{ .suffix = "/Library/Developer/CoreSimulator/Devices", .category = .cache },
            .{ .suffix = "/.cocoapods/repos", .category = .cache },
            .{ .suffix = "/Library/Caches/CocoaPods", .category = .cache },
            // VS Code on macOS
            .{ .suffix = "/Library/Application Support/Code/CachedExtensionVSIXs", .category = .cache },
            .{ .suffix = "/Library/Application Support/Code/Cache", .category = .cache },
            .{ .suffix = "/Library/Application Support/Code/CachedData", .category = .cache },
            // Browsers (specific app caches, not system caches)
            .{ .suffix = "/Library/Caches/Google/Chrome", .category = .browser_data },
            .{ .suffix = "/Library/Caches/com.apple.Safari", .category = .browser_data },
            .{ .suffix = "/Library/Caches/Firefox", .category = .browser_data },
            .{ .suffix = "/Library/Caches/org.mozilla.firefox", .category = .browser_data },
            // JetBrains IDEs
            .{ .suffix = "/Library/Caches/JetBrains", .category = .cache },
            // Package managers
            .{ .suffix = "/Library/Caches/Homebrew", .category = .cache },
            .{ .suffix = "/Library/Caches/pip", .category = .cache },
            .{ .suffix = "/Library/Caches/yarn", .category = .cache },
            // npm/node
            .{ .suffix = "/.npm", .category = .cache },
            .{ .suffix = "/.node-gyp", .category = .cache },
        };

        // Linux-specific paths
        const linux_paths = [_]struct { suffix: []const u8, category: analyzer.FileCategory }{
            // XDG cache
            .{ .suffix = "/.cache", .category = .cache },
            .{ .suffix = "/.local/share/Trash", .category = .temporary },
            // Browsers
            .{ .suffix = "/.cache/google-chrome", .category = .browser_data },
            .{ .suffix = "/.cache/chromium", .category = .browser_data },
            .{ .suffix = "/.cache/mozilla/firefox", .category = .browser_data },
            .{ .suffix = "/.cache/BraveSoftware", .category = .browser_data },
            // Snap/Flatpak
            .{ .suffix = "/.cache/snapd", .category = .cache },
            .{ .suffix = "/.var/app", .category = .cache },
        };

        // Add common paths
        for (common_paths) |entry| {
            self.addPathIfExists(home, entry.suffix, entry.category);
        }

        // Add platform-specific paths
        if (builtin.os.tag == .macos) {
            for (macos_paths) |entry| {
                self.addPathIfExists(home, entry.suffix, entry.category);
            }
        } else if (builtin.os.tag == .linux) {
            for (linux_paths) |entry| {
                self.addPathIfExists(home, entry.suffix, entry.category);
            }
        } else if (builtin.os.tag == .windows) {
            self.addWindowsCachePaths(home);
        }
    }

    /// Windows-specific cache paths using environment variables
    fn addWindowsCachePaths(self: *GuiApp, home: []const u8) void {
        var env = std.process.getEnvMap(self.allocator) catch return;
        defer env.deinit();

        // Get Windows environment variables
        const local_app_data = env.get("LOCALAPPDATA") orelse "";
        const app_data = env.get("APPDATA") orelse "";
        const temp = env.get("TEMP") orelse env.get("TMP") orelse "";

        // Windows paths relative to USERPROFILE (home)
        const home_paths = [_]struct { suffix: []const u8, category: analyzer.FileCategory }{
            // Package managers in home
            .{ .suffix = "\\.cargo\\registry", .category = .cache },
            .{ .suffix = "\\.cargo\\git", .category = .cache },
            .{ .suffix = "\\.rustup\\toolchains", .category = .cache },
            .{ .suffix = "\\.gradle\\caches", .category = .cache },
            .{ .suffix = "\\.gradle\\wrapper\\dists", .category = .cache },
            .{ .suffix = "\\.m2\\repository", .category = .cache },
            .{ .suffix = "\\.nuget\\packages", .category = .cache },
            .{ .suffix = "\\.npm", .category = .cache },
            .{ .suffix = "\\.yarn", .category = .cache },
            .{ .suffix = "\\.pnpm-store", .category = .cache },
            // Go
            .{ .suffix = "\\go\\pkg\\mod", .category = .cache },
            // Python
            .{ .suffix = "\\.cache\\pip", .category = .cache },
            .{ .suffix = "\\.local\\pipx", .category = .cache },
            // Ruby
            .{ .suffix = "\\.gem", .category = .cache },
            .{ .suffix = "\\.bundle\\cache", .category = .cache },
            // PHP
            .{ .suffix = "\\.composer\\cache", .category = .cache },
            // Dart/Flutter
            .{ .suffix = "\\.pub-cache", .category = .cache },
            .{ .suffix = "\\.flutter", .category = .cache },
            // IDE extensions
            .{ .suffix = "\\.vscode\\extensions", .category = .cache },
            .{ .suffix = "\\.vscode-insiders\\extensions", .category = .cache },
            .{ .suffix = "\\.cursor\\extensions", .category = .cache },
            // Android
            .{ .suffix = "\\.android\\cache", .category = .cache },
            .{ .suffix = "\\.android\\build-cache", .category = .cache },
            // Docker
            .{ .suffix = "\\.docker\\buildx", .category = .cache },
        };

        for (home_paths) |entry| {
            self.addPathIfExists(home, entry.suffix, entry.category);
        }

        // Paths relative to LOCALAPPDATA
        if (local_app_data.len > 0) {
            const local_paths = [_]struct { suffix: []const u8, category: analyzer.FileCategory }{
                // System temp/cache
                .{ .suffix = "\\Temp", .category = .temporary },
                .{ .suffix = "\\Microsoft\\Windows\\Explorer", .category = .cache }, // Thumbnail cache
                .{ .suffix = "\\Microsoft\\Windows\\INetCache", .category = .cache }, // IE/Edge cache
                .{ .suffix = "\\Microsoft\\Windows\\Temporary Internet Files", .category = .cache },
                // Package managers
                .{ .suffix = "\\npm-cache", .category = .cache },
                .{ .suffix = "\\Yarn", .category = .cache },
                .{ .suffix = "\\pnpm", .category = .cache },
                .{ .suffix = "\\pip\\Cache", .category = .cache },
                .{ .suffix = "\\NuGet\\v3-cache", .category = .cache },
                .{ .suffix = "\\Go\\pkg\\mod", .category = .cache },
                // Browsers
                .{ .suffix = "\\Google\\Chrome\\User Data\\Default\\Cache", .category = .browser_data },
                .{ .suffix = "\\Google\\Chrome\\User Data\\Default\\Code Cache", .category = .browser_data },
                .{ .suffix = "\\Google\\Chrome\\User Data\\Default\\GPUCache", .category = .browser_data },
                .{ .suffix = "\\Microsoft\\Edge\\User Data\\Default\\Cache", .category = .browser_data },
                .{ .suffix = "\\Mozilla\\Firefox\\Profiles", .category = .browser_data },
                .{ .suffix = "\\BraveSoftware\\Brave-Browser\\User Data\\Default\\Cache", .category = .browser_data },
                // IDEs
                .{ .suffix = "\\JetBrains", .category = .cache },
                .{ .suffix = "\\Microsoft\\VisualStudio\\Packages", .category = .cache },
                // Electron apps
                .{ .suffix = "\\Slack\\Cache", .category = .cache },
                .{ .suffix = "\\Discord\\Cache", .category = .cache },
                .{ .suffix = "\\Microsoft Teams\\Cache", .category = .cache },
            };

            for (local_paths) |entry| {
                self.addPathIfExists(local_app_data, entry.suffix, entry.category);
            }
        }

        // Paths relative to APPDATA (Roaming)
        if (app_data.len > 0) {
            const roaming_paths = [_]struct { suffix: []const u8, category: analyzer.FileCategory }{
                // VS Code
                .{ .suffix = "\\Code\\CachedExtensionVSIXs", .category = .cache },
                .{ .suffix = "\\Code\\Cache", .category = .cache },
                .{ .suffix = "\\Code\\CachedData", .category = .cache },
                .{ .suffix = "\\Code\\logs", .category = .log },
                // npm/Node
                .{ .suffix = "\\npm-cache", .category = .cache },
                // Electron apps
                .{ .suffix = "\\Slack\\Cache", .category = .cache },
                .{ .suffix = "\\Slack\\logs", .category = .log },
                .{ .suffix = "\\discord\\Cache", .category = .cache },
            };

            for (roaming_paths) |entry| {
                self.addPathIfExists(app_data, entry.suffix, entry.category);
            }
        }

        // Add TEMP directory directly
        if (temp.len > 0) {
            self.addAbsolutePath(temp, .temporary);
        }
    }

    /// Add an absolute path (no base + suffix concatenation)
    fn addAbsolutePath(self: *GuiApp, path: []const u8, category: analyzer.FileCategory) void {
        const owned_path = self.allocator.dupe(u8, path) catch return;

        std.fs.accessAbsolute(owned_path, .{}) catch {
            self.allocator.free(owned_path);
            return;
        };

        // Get modification time and calculate age
        const now_ns = std.time.nanoTimestamp();
        var mtime: i128 = 0;
        var days_old: u32 = 0;

        if (std.fs.openDirAbsolute(owned_path, .{})) |dir| {
            var d = dir;
            defer d.close();
            if (d.stat()) |stat| {
                mtime = stat.mtime;
                const age_ns = now_ns - mtime;
                if (age_ns > 0) {
                    const ns_per_day: i128 = 24 * 60 * 60 * 1_000_000_000;
                    days_old = @intCast(@divTrunc(age_ns, ns_per_day));
                }
            } else |_| {}
        } else |_| {}

        const confidence: f32 = if (category == .temporary) 0.98 else 0.85;

        self.files.append(self.allocator, FileItem{
            .path = owned_path,
            .name = std.fs.path.basename(owned_path),
            .size = 0,
            .category = category,
            .selected = false,
            .confidence = confidence,
            .mtime = mtime,
            .days_old = days_old,
        }) catch {
            self.allocator.free(owned_path);
        };
    }

    /// Expand CoreSimulator/Devices to show individual simulator devices
    fn expandSimulatorDevices(self: *GuiApp, devices_path: []const u8, category: analyzer.FileCategory) void {
        var dir = std.fs.openDirAbsolute(devices_path, .{ .iterate = true }) catch return;
        defer dir.close();

        const now_ns = std.time.nanoTimestamp();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            // Skip hidden files and non-UUID directories
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            // UUID format check (simple validation)
            if (entry.name.len != 36) continue;

            // Build full path to device directory
            const device_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ devices_path, entry.name }) catch continue;

            // Try to read device.plist to get friendly name
            const plist_path = std.fmt.allocPrint(self.allocator, "{s}/device.plist", .{device_path}) catch {
                self.allocator.free(device_path);
                continue;
            };
            defer self.allocator.free(plist_path);

            // Parse device.plist for name and runtime
            const display_name = self.parseSimulatorPlist(plist_path) orelse blk: {
                // Fallback to UUID if plist parsing fails
                break :blk std.fmt.allocPrint(self.allocator, "Simulator ({s})", .{entry.name[0..8]}) catch {
                    self.allocator.free(device_path);
                    continue;
                };
            };

            // Get modification time
            var mtime: i128 = 0;
            var days_old: u32 = 0;
            if (std.fs.openDirAbsolute(device_path, .{})) |d| {
                var opened_dir = d;
                defer opened_dir.close();
                if (opened_dir.stat()) |stat| {
                    mtime = stat.mtime;
                    const age_ns = now_ns - mtime;
                    if (age_ns > 0) {
                        const ns_per_day: i128 = 24 * 60 * 60 * 1_000_000_000;
                        days_old = @intCast(@divTrunc(age_ns, ns_per_day));
                    }
                } else |_| {}
            } else |_| {}

            self.files.append(self.allocator, FileItem{
                .path = device_path,
                .name = display_name,
                .size = 0,
                .category = category,
                .selected = false,
                .confidence = 0.85, // Lower confidence - user should decide
                .mtime = mtime,
                .days_old = days_old,
            }) catch {
                self.allocator.free(device_path);
                self.allocator.free(display_name);
            };
        }
    }

    /// Parse simulator device.plist to extract name and runtime
    fn parseSimulatorPlist(self: *GuiApp, plist_path: []const u8) ?[]const u8 {
        const file = std.fs.openFileAbsolute(plist_path, .{}) catch return null;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 8192) catch return null;
        defer self.allocator.free(content);

        // Simple XML parsing for name and runtime
        var name: ?[]const u8 = null;
        var runtime: ?[]const u8 = null;

        // Find <key>name</key><string>...</string>
        if (std.mem.indexOf(u8, content, "<key>name</key>")) |name_key_pos| {
            const after_key = content[name_key_pos..];
            if (std.mem.indexOf(u8, after_key, "<string>")) |str_start| {
                const value_start = name_key_pos + str_start + 8;
                if (std.mem.indexOf(u8, content[value_start..], "</string>")) |str_end| {
                    name = content[value_start .. value_start + str_end];
                }
            }
        }

        // Find <key>runtime</key><string>...</string>
        if (std.mem.indexOf(u8, content, "<key>runtime</key>")) |runtime_key_pos| {
            const after_key = content[runtime_key_pos..];
            if (std.mem.indexOf(u8, after_key, "<string>")) |str_start| {
                const value_start = runtime_key_pos + str_start + 8;
                if (std.mem.indexOf(u8, content[value_start..], "</string>")) |str_end| {
                    const full_runtime = content[value_start .. value_start + str_end];
                    // Extract iOS version from "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
                    if (std.mem.indexOf(u8, full_runtime, "SimRuntime.")) |prefix_end| {
                        runtime = full_runtime[prefix_end + 11 ..];
                    }
                }
            }
        }

        // Build display name
        if (name) |n| {
            if (runtime) |r| {
                // Convert "iOS-26-0" to "iOS 26.0"
                var runtime_buf: [64]u8 = undefined;
                var runtime_formatted: []const u8 = r;

                // Replace dashes with dots/spaces for readability
                var i: usize = 0;
                var j: usize = 0;
                var first_dash = true;
                while (i < r.len and j < runtime_buf.len - 1) : (i += 1) {
                    if (r[i] == '-') {
                        if (first_dash) {
                            runtime_buf[j] = ' ';
                            first_dash = false;
                        } else {
                            runtime_buf[j] = '.';
                        }
                    } else {
                        runtime_buf[j] = r[i];
                    }
                    j += 1;
                }
                runtime_formatted = runtime_buf[0..j];

                return std.fmt.allocPrint(self.allocator, "{s} ({s})", .{ n, runtime_formatted }) catch null;
            } else {
                return self.allocator.dupe(u8, n) catch null;
            }
        }

        return null;
    }

    fn addPathIfExists(self: *GuiApp, home: []const u8, suffix: []const u8, category: analyzer.FileCategory) void {
        const full_path = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home, suffix }) catch return;

        std.fs.accessAbsolute(full_path, .{}) catch {
            self.allocator.free(full_path);
            return;
        };

        // Special handling for CoreSimulator/Devices - expand to show individual simulators
        if (std.mem.endsWith(u8, suffix, "/Library/Developer/CoreSimulator/Devices")) {
            self.expandSimulatorDevices(full_path, category);
            self.allocator.free(full_path);
            return;
        }

        // Get modification time and calculate age
        const now_ns = std.time.nanoTimestamp();
        var mtime: i128 = 0;
        var days_old: u32 = 0;

        if (std.fs.openDirAbsolute(full_path, .{})) |dir| {
            var d = dir;
            defer d.close();
            if (d.stat()) |stat| {
                mtime = stat.mtime;
                const age_ns = now_ns - mtime;
                if (age_ns > 0) {
                    const ns_per_day: i128 = 24 * 60 * 60 * 1_000_000_000;
                    days_old = @intCast(@divTrunc(age_ns, ns_per_day));
                }
            } else |_| {}
        } else |_| {}

        // Higher confidence for caches/temp
        const confidence: f32 = if (category == .cache or category == .temporary)
            0.95
        else if (category == .log)
            0.90
        else
            0.85;

        self.files.append(self.allocator, FileItem{
            .path = full_path,
            .name = std.fs.path.basename(full_path),
            .size = 0,
            .category = category,
            .selected = false,
            .confidence = confidence,
            .mtime = mtime,
            .days_old = days_old,
        }) catch {
            self.allocator.free(full_path);
        };
    }

    /// Calculate sizes for all items using du command (fast!)
    fn calculateAllSizes(self: *GuiApp) void {
        for (self.files.items) |*file| {
            file.size = self.getDirSize(file.path);
            self.total_size += file.size;
            self.category_sizes[@intFromEnum(file.category)] += file.size;
        }
    }

    /// Get directory size using platform-specific commands
    fn getDirSize(self: *GuiApp, path: []const u8) u64 {
        const builtin = @import("builtin");

        if (builtin.os.tag == .windows) {
            return self.getDirSizeWindows(path);
        } else {
            return self.getDirSizeUnix(path);
        }
    }

    /// Unix/macOS: Use du command
    fn getDirSizeUnix(self: *GuiApp, path: []const u8) u64 {
        const cmd = std.fmt.allocPrint(self.allocator, "du -sk \"{s}\" 2>/dev/null | cut -f1", .{path}) catch return 0;
        defer self.allocator.free(cmd);

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
            .max_output_bytes = 64,
        }) catch return 0;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        const trimmed = std.mem.trim(u8, result.stdout, &[_]u8{ ' ', '\n', '\t' });
        const kb = std.fmt.parseInt(u64, trimmed, 10) catch return 0;
        return kb * 1024; // Convert KB to bytes
    }

    /// Windows: Use PowerShell to get directory size
    fn getDirSizeWindows(self: *GuiApp, path: []const u8) u64 {
        const cmd = std.fmt.allocPrint(self.allocator,
            \\(Get-ChildItem -Path "{s}" -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        , .{path}) catch return 0;
        defer self.allocator.free(cmd);

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "powershell.exe", "-NoProfile", "-Command", cmd },
            .max_output_bytes = 64,
        }) catch return 0;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        const trimmed = std.mem.trim(u8, result.stdout, &[_]u8{ ' ', '\n', '\t', '\r' });
        // PowerShell returns bytes directly
        return std.fmt.parseInt(u64, trimmed, 10) catch return 0;
    }

    fn updateFilteredList(self: *GuiApp) void {
        self.filtered_indices.clearRetainingCapacity();
        for (self.files.items, 0..) |file, i| {
             const keep = switch(self.active_tab) {
                 .all => true,
                 .largest => file.size >= 50 * 1024 * 1024,
                 .cache => file.category == .cache,
                 .dev => file.category == .dev_artifact,
                 .temp => file.category == .temporary,
             };
             if (keep) {
                 self.filtered_indices.append(self.allocator, i) catch continue;
             }
        }
        self.scroll_offset = 0;
    }

    fn updateSelectionStats(self: *GuiApp) void {
        self.selected_count = 0;
        self.selected_size = 0;
        for (self.files.items) |file| {
            if (file.selected) {
                self.selected_count += 1;
                self.selected_size += file.size;
            }
        }
    }

    fn areAllFilteredSelected(self: *GuiApp) bool {
        if (self.filtered_indices.items.len == 0) return false;
        for (self.filtered_indices.items) |idx| {
            if (!self.files.items[idx].selected) return false;
        }
        return true;
    }

    fn toggleSelectAll(self: *GuiApp) void {
        const all_selected = self.areAllFilteredSelected();
        for (self.filtered_indices.items) |idx| {
            self.files.items[idx].selected = !all_selected;
        }
        self.updateSelectionStats();
    }

    pub fn handleInput(self: *GuiApp) void {
        // Q - Quit
        if (rl.isKeyPressed(.q)) self.should_quit = true;

        // Esc - Cancel dialog or clear selection
        if (rl.isKeyPressed(.escape)) {
            if (self.dialog != .none) {
                self.dialog = .none;
            } else if (self.selected_count > 0) {
                // Deselect all
                for (self.files.items) |*file| {
                    file.selected = false;
                }
                self.updateSelectionStats();
            }
        }

        // R - Rescan
        if (rl.isKeyPressed(.r) and self.view != .scanning and self.dialog == .none) {
            self.startScan();
        }

        // A - Select/Deselect All (in current filter)
        if (rl.isKeyPressed(.a) and self.view == .results and self.dialog == .none) {
            self.toggleSelectAll();
        }

        // D - Delete selected
        if (rl.isKeyPressed(.d) and self.selected_count > 0 and self.dialog == .none) {
            self.dialog = .confirm_delete;
        }

        // Enter - Confirm delete in dialog
        if (rl.isKeyPressed(.enter) and self.dialog == .confirm_delete) {
            self.performDeletion();
            self.dialog = .none;
        }

        // Z - Undo last deletion (Ctrl+Z would be nice but we'll use just Z)
        if (rl.isKeyPressed(.z) and self.view == .results and self.dialog == .none) {
            self.performUndo();
        }

        // Scroll with mouse wheel
        const wheel = rl.getMouseWheelMove();
        if (wheel != 0 and self.filtered_indices.items.len > 0) {
            const speed: i32 = 3;
            const new_off = @as(i32, @intCast(self.scroll_offset)) - @as(i32, @intFromFloat(wheel * @as(f32, @floatFromInt(speed))));
            const max_rows: usize = @intCast(@divTrunc(rl.getScreenHeight() - theme.dimensions.header_height, theme.dimensions.row_height)); // approx
            const max_scroll = if (self.filtered_indices.items.len > max_rows) self.filtered_indices.items.len - max_rows else 0;
            self.scroll_offset = @intCast(@max(0, @min(new_off, @as(i32, @intCast(max_scroll)))));
        }
    }

    /// Perform deletion of selected items
    fn performDeletion(self: *GuiApp) void {
        // Initialize deleter if not already
        if (self.file_deleter == null) {
            const d = self.allocator.create(deleter.Deleter) catch return;
            d.* = deleter.Deleter.init(self.allocator, .{
                .use_trash = true,
                .dry_run = false,
                .require_confirmation = false, // We already confirmed in GUI
                .verbose_logging = false,
            }) catch {
                self.allocator.destroy(d);
                return;
            };
            self.file_deleter = d;
        }

        // Collect paths of selected items
        var paths_to_delete: std.ArrayListUnmanaged([]const u8) = .{};
        defer paths_to_delete.deinit(self.allocator);

        for (self.files.items) |file| {
            if (file.selected) {
                paths_to_delete.append(self.allocator, file.path) catch continue;
            }
        }

        if (paths_to_delete.items.len == 0) return;

        // Perform deletion
        self.view = .deleting;
        self.delete_progress = 0;

        const results = self.file_deleter.?.deleteFiles(paths_to_delete.items) catch {
            self.view = .results;
            self.status_message = "Deletion failed";
            return;
        };
        defer {
            // Free each result's allocated strings, then free the array
            for (results) |*result| {
                var r = result.*;
                r.deinit(self.allocator);
            }
            self.allocator.free(results);
        }

        // Calculate freed space and count successes/failures
        var freed: u64 = 0;
        var success_count: usize = 0;
        var fail_count: usize = 0;
        for (results) |result| {
            if (result.success) {
                freed += result.bytes_freed;
                success_count += 1;
            } else {
                fail_count += 1;
            }
        }

        // Remove successfully deleted items from the list, deselect failed items
        var i: usize = 0;
        while (i < self.files.items.len) {
            const file = &self.files.items[i];
            if (file.selected) {
                // Check if this file was successfully deleted
                var was_deleted = false;
                for (results) |result| {
                    if (std.mem.eql(u8, result.path, file.path)) {
                        was_deleted = result.success;
                        break;
                    }
                }

                if (was_deleted) {
                    self.freeFileItem(file.*);
                    _ = self.files.orderedRemove(i);
                    continue;
                } else {
                    // Deselect failed items so user can try again or skip them
                    file.selected = false;
                }
            }
            i += 1;
        }

        // Update stats
        self.total_size -= freed;
        self.selected_count = 0;
        self.selected_size = 0;
        self.updateFilteredList();
        self.view = .results;

        // Show appropriate status message
        if (fail_count == 0) {
            self.status_message = "Deletion complete";
        } else if (success_count == 0) {
            self.status_message = "Deletion failed - permission denied";
        } else {
            // Some succeeded, some failed - format a message
            const msg = std.fmt.bufPrint(&self.status_buf, "{d} deleted, {d} failed (permission denied)", .{ success_count, fail_count }) catch "Partial deletion";
            self.status_message = msg;
        }
    }

    /// Undo last deletion
    fn performUndo(self: *GuiApp) void {
        if (self.file_deleter == null) return;

        const result = self.file_deleter.?.undo() catch return;
        if (result) |undo_result| {
            defer {
                var r = undo_result;
                r.deinit(self.allocator);
            }

            if (undo_result.success) {
                // Re-scan to pick up restored file
                self.status_message = "Undo successful - file restored";
            } else {
                self.status_message = "Undo failed";
            }
        }
    }

    /// Delete a single item by index
    fn deleteSingleItem(self: *GuiApp, idx: usize) void {
        if (idx >= self.files.items.len) return;

        // Initialize deleter if needed
        if (self.file_deleter == null) {
            const d = self.allocator.create(deleter.Deleter) catch return;
            d.* = deleter.Deleter.init(self.allocator, .{
                .use_trash = true,
                .dry_run = false,
                .require_confirmation = false,
                .verbose_logging = false,
            }) catch {
                self.allocator.destroy(d);
                return;
            };
            self.file_deleter = d;
        }

        const file = &self.files.items[idx];
        var result = self.file_deleter.?.deleteFile(file.path) catch return;
        defer result.deinit(self.allocator);

        if (result.success) {
            // Update stats
            self.total_size -= result.bytes_freed;
            self.category_sizes[@intFromEnum(file.category)] -= @min(result.bytes_freed, self.category_sizes[@intFromEnum(file.category)]);

            // Remove from list
            self.freeFileItem(file.*);
            _ = self.files.orderedRemove(idx);
            self.updateFilteredList();
            self.status_message = "Item deleted";
        }
    }

    pub fn update(self: *GuiApp) void {
        if (self.view == .scanning) {
            self.processScanPhase();
        }
    }

    // --- RENDER ---

    pub fn render(self: *GuiApp) void {
        const sw = rl.getScreenWidth();
        const sh = rl.getScreenHeight();
        
        // Background
        rl.clearBackground(theme.colors.background);
        
        // 1. Sidebar
        self.renderSidebar(sw, sh);
        
        // 2. Main Content Area
        const main_x = theme.dimensions.sidebar_width;
        const main_w = sw - main_x;
        
        // Header
        self.renderHeader(main_x, main_w);
        
        // Content
        const content_y = theme.dimensions.header_height;
        const content_h = sh - content_y;
        
        if (self.view == .scanning) {
            self.renderScanning(main_x, content_y, main_w, content_h);
        } else if (self.view == .results or self.view == .idle) {
            self.renderDashboard(main_x, content_y, main_w, content_h);
        }
        
        // Dialogs
        if (self.dialog == .confirm_delete) {
            // Format message with count and size
            var msg_buf: [128]u8 = undefined;
            var size_buf: [32]u8 = undefined;
            const size_str = widgets.formatSizeBuffer(self.selected_size, &size_buf);

            const msg = std.fmt.bufPrint(&msg_buf, "Delete {d} items ({s})? This will move them to trash.", .{ self.selected_count, size_str }) catch "Delete selected items?";

            var msg_z: [128:0]u8 = undefined;
            @memcpy(msg_z[0..msg.len], msg);
            msg_z[msg.len] = 0;

            const result = widgets.drawConfirmDialog("Confirm Delete", &msg_z, sw, sh);
            if (result) |confirmed| {
                if (confirmed) {
                    self.performDeletion();
                }
                self.dialog = .none;
            }
        }
    }

    fn renderSidebar(self: *GuiApp, sw: i32, sh: i32) void {
        _ = sw;
        const w = theme.dimensions.sidebar_width;
        rl.drawRectangle(0, 0, w, sh, theme.colors.sidebar_bg);
        
        // Navigation
        const start_y = 100;
        const tabs = [_]Tab{ .all, .largest, .cache, .dev, .temp };
        
        for (tabs, 0..) |tab, i| {
             const y = start_y + @as(i32, @intCast(i)) * 60; // 60px height per item
             if (widgets.drawSidebarItem(tab.name(), tab.icon(), 0, y, w, 50, self.active_tab == tab)) {
                 self.active_tab = tab;
                 self.updateFilteredList();
             }
        }
        
        // Storage Card at bottom
        const card_h = 110;
        const card_y = sh - card_h - 20;
        const card_margin = 15;

        // Card background (Darker than sidebar)
        const rec = rl.Rectangle{
            .x = @floatFromInt(card_margin),
            .y = @floatFromInt(card_y),
            .width = @floatFromInt(w - card_margin*2),
            .height = @floatFromInt(card_h)
        };
        rl.drawRectangleRounded(rec, 0.1, 6, theme.colors.background); // Darker padding

        const card_text_y = card_y + 15;

        // "Reclaimable" label - show total before selection, selected after
        const label_text: [:0]const u8 = if (self.selected_size > 0) "Selected to Clear" else "Reclaimable";
        widgets.drawLabel(label_text, card_margin + 15, card_text_y, theme.fonts.body, theme.colors.text_secondary);

        // Show total reclaimable (or selected if items selected)
        var size_buf: [32]u8 = undefined;
        const display_size = if (self.selected_size > 0) self.selected_size else self.total_size;
        const size_str = widgets.formatSizeBuffer(display_size, &size_buf);
        var size_z: [32:0]u8 = undefined;
        @memcpy(size_z[0..size_str.len], size_str);
        size_z[size_str.len] = 0;

        // Large bold text for size - green if selected, white otherwise
        const size_color = if (self.selected_size > 0) theme.colors.success else theme.colors.text_primary;
        widgets.drawTitle(&size_z, card_margin + 15, card_text_y + 30, 32.0, size_color);

        // Progress bar showing selected / total
        const progress: f32 = if (self.total_size > 0)
            @as(f32, @floatFromInt(self.selected_size)) / @as(f32, @floatFromInt(self.total_size))
        else 0.0;

        widgets.drawProgressBar(progress, card_margin + 15, card_y + 80, w - card_margin*2 - 30, 8);
    }

    fn renderHeader(self: *GuiApp, x: i32, w: i32) void {
         const h = theme.dimensions.header_height;
         // rl.drawRectangle(x, 0, w, h, theme.colors.background); // Already bg

         const title = "System Scan";
         widgets.drawTitle(title, x + 30, @divTrunc(h - @as(i32, @intFromFloat(theme.fonts.title)), 2), theme.fonts.title, theme.colors.text_primary);

         // Status message (shown next to title)
         if (self.status_message.len > 0 and !std.mem.eql(u8, self.status_message, "Ready to scan")) {
             var status_buf: [128:0]u8 = undefined;
             const len = @min(self.status_message.len, 127);
             @memcpy(status_buf[0..len], self.status_message[0..len]);
             status_buf[len] = 0;

             // Show status with appropriate color
             const status_color = if (std.mem.indexOf(u8, self.status_message, "complete") != null or
                                      std.mem.indexOf(u8, self.status_message, "deleted") != null or
                                      std.mem.indexOf(u8, self.status_message, "successful") != null)
                 theme.colors.success
             else if (std.mem.indexOf(u8, self.status_message, "failed") != null)
                 theme.colors.danger
             else
                 theme.colors.text_secondary;

             const title_w = @as(i32, @intFromFloat(widgets.measureTextEx(title, theme.fonts.title)));
             widgets.drawLabel(&status_buf, x + 30 + title_w + 20, @divTrunc(h - @as(i32, @intFromFloat(theme.fonts.body)), 2) + 4, theme.fonts.body, status_color);
         }

         // Rescan Button (Primary Red)
         const btn_w = 120;
         const btn_h = 36;
         const btn_x = x + w - btn_w - 30;
         const btn_y = @divTrunc(h - btn_h, 2);

         if (widgets.drawButton("Rescan", btn_x, btn_y, btn_w, btn_h, theme.ButtonStyle.primary)) {
             self.startScan();
         }
    }

    fn renderScanning(self: *GuiApp, x: i32, y: i32, w: i32, h: i32) void {
         const cx = x + @divTrunc(w, 2);
         const cy = y + @divTrunc(h, 2);
         widgets.drawSpinner(cx, cy - 20, 30);
         widgets.drawProgressBar(self.scan_progress, cx - 150, cy + 30, 300, 10);
         const msg = "Scanning...";
         const mw = @as(i32, @intFromFloat(widgets.measureTextEx(msg, theme.fonts.body)));
         widgets.drawLabel(msg, cx - @divTrunc(mw, 2), cy + 50, theme.fonts.body, theme.colors.text_secondary);
    }

    fn renderDashboard(self: *GuiApp, x: i32, y: i32, w: i32, h: i32) void {
        const gap = 20;
        const pad = 20;
        
        // Dimensions
        const chart_w = 300;
        const chart_h = h - pad;
        const chart_x = x + pad;
        const chart_y = y; // Already padded from top
        
        // File List Card (remaining width)
        const list_x = chart_x + chart_w + gap;
        const list_w = w - pad * 2 - (chart_w + gap);
        const list_h = chart_h;
        
        // 1. Chart Card
        widgets.drawCard(chart_x, chart_y, chart_w, chart_h);
        widgets.drawLabel("Space Breakdown", chart_x + 20, chart_y + 20, theme.fonts.body, theme.colors.text_secondary);
        
        // Donut
        const radius: f32 = 80;
        const donut_cx = chart_x + @divTrunc(chart_w, 2);
        const donut_cy = chart_y + @divTrunc(chart_h, 2) - 40;
        
        // Build segments from actual category data
        var segments: [5]widgets.ChartSegment = undefined;
        segments[0] = .{ .value = @floatFromInt(self.category_sizes[@intFromEnum(analyzer.FileCategory.dev_artifact)]), .color = theme.colors.chart_1, .label = "Dev Artifacts" };
        segments[1] = .{ .value = @floatFromInt(self.category_sizes[@intFromEnum(analyzer.FileCategory.cache)]), .color = theme.colors.chart_2, .label = "Caches" };
        segments[2] = .{ .value = @floatFromInt(self.category_sizes[@intFromEnum(analyzer.FileCategory.temporary)]), .color = theme.colors.chart_3, .label = "Temp Files" };
        segments[3] = .{ .value = @floatFromInt(self.category_sizes[@intFromEnum(analyzer.FileCategory.log)]), .color = theme.colors.chart_4, .label = "Logs" };
        segments[4] = .{ .value = @floatFromInt(self.category_sizes[@intFromEnum(analyzer.FileCategory.browser_data)]), .color = theme.colors.chart_5, .label = "Browser Data" };

        // Thicker donut
        widgets.drawDonutChart(donut_cx, donut_cy, radius, 35, &segments);

        // Legend - only show categories with data
        var legend_y = chart_y + chart_h - 180;

        for (segments) |seg| {
            // Skip empty categories
            if (seg.value < 1.0) continue;

            rl.drawCircle(chart_x + 30, legend_y + 6, 4, seg.color);
            widgets.drawLabel(seg.label, chart_x + 45, legend_y, theme.fonts.small, theme.colors.text_secondary);

            // Show size instead of percentage for clarity
            var sz_buf: [32]u8 = undefined;
            const sz_str = widgets.formatSizeBuffer(@intFromFloat(seg.value), &sz_buf);
            var sz_z: [32:0]u8 = undefined;
            @memcpy(sz_z[0..sz_str.len], sz_str);
            sz_z[sz_str.len] = 0;

            widgets.drawStrong(&sz_z, chart_x + chart_w - 80, legend_y, theme.fonts.small, theme.colors.text_primary);
            legend_y += 28;
        }
        
        // 2. File List Card
        widgets.drawCard(list_x, chart_y, list_w, list_h);

        // Header row with selection buttons
        const header_y = chart_y + 15;
        const btn_h: i32 = 28;

        // Select All / Deselect All button
        const select_btn_w: i32 = 100;
        const all_selected = self.areAllFilteredSelected();
        const select_label: [:0]const u8 = if (all_selected) "Deselect All" else "Select All";
        if (widgets.drawButton(select_label, list_x + 20, header_y, select_btn_w, btn_h, theme.ButtonStyle.secondary)) {
            self.toggleSelectAll();
        }

        // Delete Selected button (only if items selected)
        if (self.selected_count > 0) {
            var del_label_buf: [32:0]u8 = undefined;
            const del_label_result = std.fmt.bufPrint(&del_label_buf, "Delete ({d})", .{self.selected_count}) catch "Delete";
            del_label_buf[del_label_result.len] = 0;
            const del_btn_w: i32 = 100;
            if (widgets.drawButton(del_label_buf[0..del_label_result.len :0], list_x + 20 + select_btn_w + 10, header_y, del_btn_w, btn_h, theme.ButtonStyle.danger)) {
                self.dialog = .confirm_delete;
            }
        }

        // Column headers
        const cols_y = header_y + btn_h + 15;
        widgets.drawLabel("FILE PATH", list_x + 80, cols_y, theme.fonts.small, theme.colors.text_muted);
        widgets.drawLabel("SIZE", list_x + list_w - 120, cols_y, theme.fonts.small, theme.colors.text_muted);

        rl.drawLineEx(
            .{ .x = @floatFromInt(list_x + 10), .y = @floatFromInt(cols_y + 25) },
            .{ .x = @floatFromInt(list_x + list_w - 10), .y = @floatFromInt(cols_y + 25) },
            1.0, theme.colors.border
        );

        // List area
        const list_area_y = cols_y + 35;
        const list_area_h = list_h - 110;
        
        // Render rows
        const row_h = 80; // High rows
        var curr_y = list_area_y;
        var i: usize = self.scroll_offset;
        
        // Clip content
        rl.beginScissorMode(list_x, list_area_y, list_w, list_area_h);
        
        while (i < self.filtered_indices.items.len and curr_y < list_area_y + list_area_h) : (i += 1) {
            const idx = self.filtered_indices.items[i];
            const file = &self.files.items[idx];

            // Row background highlight if selected
            if (file.selected) {
                const row_rec = rl.Rectangle{
                    .x = @floatFromInt(list_x + 10),
                    .y = @floatFromInt(curr_y),
                    .width = @floatFromInt(list_w - 20),
                    .height = @floatFromInt(row_h - 5),
                };
                var sel_color = theme.colors.success;
                sel_color.a = 25;
                rl.drawRectangleRounded(row_rec, 0.1, 4, sel_color);
            }

            // Checkbox for selection
            if (widgets.drawCheckbox(file.selected, list_x + 20, curr_y + 28)) {
                file.selected = !file.selected;
                self.updateSelectionStats();
            }

            // Icon Background (Hexagon)
            const icon_bg_x = list_x + 65;
            const icon_bg_y = curr_y + 38;
            rl.drawPoly(.{ .x = @floatFromInt(icon_bg_x), .y = @floatFromInt(icon_bg_y) }, 6, 18.0, 30.0, theme.colors.surface);

            // Code Icon </>
            widgets.drawLabel("</>", list_x + 53, curr_y + 30, theme.fonts.small, theme.colors.text_muted);

            // Path / Name - "project-alpha/node_modules" style
            const parent = std.fs.path.dirname(file.path) orelse "";
            const parent_base = std.fs.path.basename(parent);

            var name_buf: [256]u8 = undefined;
            const name_display = std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ parent_base, file.name }) catch file.name;
            var name_z: [256:0]u8 = undefined;
            const len = @min(name_display.len, 255);
            @memcpy(name_z[0..len], name_display[0..len]);
            name_z[len] = 0;

            widgets.drawStrong(&name_z, list_x + 100, curr_y + 15, theme.fonts.heading, theme.colors.text_primary);

            // Subtitle: "Unused for X days" or stale indicator
            var sub_buf: [128]u8 = undefined;
            const is_stale = file.isStale(90);
            const sub = if (is_stale)
                std.fmt.bufPrint(&sub_buf, "Stale - {d} days old", .{file.days_old}) catch ""
            else if (file.days_old > 0)
                std.fmt.bufPrint(&sub_buf, "Unused for {d} days", .{file.days_old}) catch ""
            else
                std.fmt.bufPrint(&sub_buf, "Modified recently", .{}) catch "";
            var sub_z: [128:0]u8 = undefined;
            @memcpy(sub_z[0..sub.len], sub);
            sub_z[sub.len] = 0;

            const sub_color = if (is_stale) theme.colors.warning else theme.colors.text_muted;
            widgets.drawLabel(&sub_z, list_x + 100, curr_y + 42, theme.fonts.small, sub_color);

            // Size (right side)
            var sz_buf: [32]u8 = undefined;
            const sz_s = widgets.formatSizeBuffer(file.size, &sz_buf);
            var sz_z: [32:0]u8 = undefined;
            @memcpy(sz_z[0..sz_s.len], sz_s);
            sz_z[sz_s.len] = 0;

            const sz_w = widgets.measureTextStrong(&sz_z, theme.fonts.heading);
            widgets.drawStrong(&sz_z, list_x + list_w - 110 - @as(i32, @intFromFloat(sz_w)), curr_y + 28, theme.fonts.heading, theme.colors.text_primary);

            // Trash Button
            if (widgets.drawIconButton("trash", list_x + list_w - 60, curr_y + 22, 36, theme.colors.text_muted)) {
                self.deleteSingleItem(idx);
            }

            curr_y += row_h;
        }
        rl.endScissorMode();
    }
};
