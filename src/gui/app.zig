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
    collecting_paths,
    scanning_files,
    analyzing,
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
        };
    }

    pub fn deinit(self: *GuiApp) void {
        for (self.files.items) |file| {
            self.allocator.free(file.path);
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

        if (self.file_deleter) |d| {
            d.deinit();
            self.allocator.destroy(d);
        }
    }

    /// Start filesystem scan using fast system commands
    pub fn startScan(self: *GuiApp) void {
        // Clear previous
        for (self.files.items) |file| {
            self.allocator.free(file.path);
        }
        self.files.clearRetainingCapacity();
        self.filtered_indices.clearRetainingCapacity();
        self.total_size = 0;
        self.selected_size = 0;
        self.selected_count = 0;
        self.category_sizes = [_]u64{0} ** 10;
        self.scan_files_processed = 0;

        self.view = .scanning;
        self.scan_phase = .collecting_paths;
        self.scan_progress = 0.0;
    }

    /// Process scan incrementally (called from update)
    fn processScanPhase(self: *GuiApp) void {
        const builtin = @import("builtin");

        // Get home directory (cross-platform)
        const home = if (builtin.os.tag == .windows)
            std.process.getEnvVarOwned(self.allocator, "USERPROFILE") catch
                std.process.getEnvVarOwned(self.allocator, "HOMEDRIVE") catch "C:\\"
        else
            std.process.getEnvVarOwned(self.allocator, "HOME") catch "/tmp";
        defer self.allocator.free(home);

        switch (self.scan_phase) {
            .not_started => {},
            .collecting_paths => {
                // Phase 1: Find dev artifacts
                self.scan_progress = 0.1;
                self.findDevArtifacts(home);
                self.scan_phase = .scanning_files;
            },
            .scanning_files => {
                // Phase 2: Add known cache dirs
                self.scan_progress = 0.3;
                self.addKnownCacheDirs(home);
                self.scan_phase = .analyzing;
                self.scan_files_processed = 0;
            },
            .analyzing => {
                // Phase 3: Calculate sizes incrementally (3 per frame)
                const batch_size: usize = 3;
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
                    self.scan_progress = 0.3 + 0.6 * (@as(f32, @floatFromInt(self.scan_files_processed)) / @as(f32, @floatFromInt(self.files.items.len)));
                }

                // Check if done
                if (self.scan_files_processed >= self.files.items.len) {
                    self.scan_phase = .done;
                }
            },
            .done => {
                // Phase 4: Finish up
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
        const macos_paths = [_]struct { suffix: []const u8, category: analyzer.FileCategory }{
            // System
            .{ .suffix = "/Library/Caches", .category = .cache },
            .{ .suffix = "/Library/Logs", .category = .log },
            .{ .suffix = "/.Trash", .category = .temporary },
            // Xcode & iOS
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
            // Browsers
            .{ .suffix = "/Library/Caches/Google/Chrome", .category = .browser_data },
            .{ .suffix = "/Library/Caches/com.apple.Safari", .category = .browser_data },
            .{ .suffix = "/Library/Caches/Firefox", .category = .browser_data },
            // JetBrains on macOS
            .{ .suffix = "/Library/Caches/JetBrains", .category = .cache },
            // Homebrew
            .{ .suffix = "/Library/Caches/Homebrew", .category = .cache },
            // Pip on macOS
            .{ .suffix = "/Library/Caches/pip", .category = .cache },
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

    fn addPathIfExists(self: *GuiApp, home: []const u8, suffix: []const u8, category: analyzer.FileCategory) void {
        const full_path = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home, suffix }) catch return;

        std.fs.accessAbsolute(full_path, .{}) catch {
            self.allocator.free(full_path);
            return;
        };

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
        defer self.allocator.free(results);

        // Calculate freed space and count successes
        var freed: u64 = 0;
        var success_count: usize = 0;
        for (results) |result| {
            if (result.success) {
                freed += result.bytes_freed;
                success_count += 1;
            }
        }

        // Remove successfully deleted items from the list
        var i: usize = 0;
        while (i < self.files.items.len) {
            const file = &self.files.items[i];
            if (file.selected) {
                // Check if this file was successfully deleted
                var was_deleted = false;
                for (results) |result| {
                    if (result.success and std.mem.eql(u8, result.path, file.path)) {
                        was_deleted = true;
                        break;
                    }
                }

                if (was_deleted) {
                    self.allocator.free(file.path);
                    _ = self.files.orderedRemove(i);
                    continue;
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
        self.status_message = "Deletion complete";
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
            self.allocator.free(file.path);
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
        const card_h = 100;
        const card_y = sh - card_h - 20;
        const card_margin = 15;

        widgets.drawCard(card_margin, card_y, w - card_margin*2, card_h);

        const card_text_y = card_y + 15;

        // Show "To be cleared" with actual selected size
        if (self.selected_size > 0) {
            widgets.drawLabel("To Be Cleared", card_margin + 15, card_text_y, theme.fonts.small, theme.colors.text_muted);

            // Format selected size
            var size_buf: [32]u8 = undefined;
            const size_str = widgets.formatSizeBuffer(self.selected_size, &size_buf);
            var size_z: [32:0]u8 = undefined;
            @memcpy(size_z[0..size_str.len], size_str);
            size_z[size_str.len] = 0;

            widgets.drawLabel(&size_z, card_margin + 15, card_text_y + 25, theme.fonts.title, theme.colors.success);

            // Progress bar showing selected / total
            const progress: f32 = if (self.total_size > 0)
                @as(f32, @floatFromInt(self.selected_size)) / @as(f32, @floatFromInt(self.total_size))
            else 0.0;
            widgets.drawProgressBar(progress, card_margin + 15, card_y + 70, w - card_margin*2 - 30, 8);
        } else if (self.view == .results and self.files.items.len > 0) {
            // Scan complete but nothing selected
            widgets.drawLabel("Select items to clear", card_margin + 15, card_text_y, theme.fonts.small, theme.colors.text_muted);
            widgets.drawLabel("0 B", card_margin + 15, card_text_y + 25, theme.fonts.title, theme.colors.text_secondary);
            widgets.drawProgressBar(0, card_margin + 15, card_y + 70, w - card_margin*2 - 30, 8);
        } else {
            // No scan yet or scanning
            widgets.drawLabel("Storage to Clear", card_margin + 15, card_text_y, theme.fonts.small, theme.colors.text_muted);
            widgets.drawLabel("--", card_margin + 15, card_text_y + 25, theme.fonts.title, theme.colors.text_muted);
            widgets.drawProgressBar(0, card_margin + 15, card_y + 70, w - card_margin*2 - 30, 8);
        }
    }

    fn renderHeader(self: *GuiApp, x: i32, w: i32) void {
         const h = theme.dimensions.header_height;
         // rl.drawRectangle(x, 0, w, h, theme.colors.background); // Already bg
         
         const title = "System Scan";
         widgets.drawTitle(title, x + 30, @divTrunc(h - @as(i32, @intFromFloat(theme.fonts.title)), 2), theme.fonts.title, theme.colors.text_primary);
         
         // Rescan Button
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
        const chart_w = 340;
        // Chart Card is full height minus padding? Or just sufficient height?
        // Making it full height to match screenshot vertical split feeling
        const chart_h = h - pad * 2;
        const chart_x = x + pad;
        const chart_y = y + pad;
        
        // File List Card (remaining width)
        const list_x = chart_x + chart_w + gap;
        const list_w = w - pad * 2 - (chart_w + gap);
        const list_h = chart_h;
        
        // 1. Chart Card
        widgets.drawCard(chart_x, chart_y, chart_w, chart_h);
        widgets.drawStrong("Space Breakdown", chart_x + 20, chart_y + 20, theme.fonts.heading, theme.colors.text_secondary);
        
        // Donut
        const radius: f32 = 90;
        const donut_cx = chart_x + @divTrunc(chart_w, 2);
        const donut_cy = chart_y + @divTrunc(chart_h, 2) - 40;
        
        // Build segments
        var segments: [5]widgets.ChartSegment = undefined;
        // Simplified breakdown for visual
        segments[0] = .{ .value = @floatFromInt(self.category_sizes[@intFromEnum(analyzer.FileCategory.dev_artifact)]), .color = theme.colors.chart_1, .label = "Dev" };
        segments[1] = .{ .value = @floatFromInt(self.category_sizes[@intFromEnum(analyzer.FileCategory.cache)]), .color = theme.colors.chart_2, .label = "Cache" };
        segments[2] = .{ .value = @floatFromInt(self.category_sizes[@intFromEnum(analyzer.FileCategory.temporary)]), .color = theme.colors.chart_3, .label = "Temp" };
        segments[3] = .{ .value = @floatFromInt(self.category_sizes[@intFromEnum(analyzer.FileCategory.large)]), .color = theme.colors.chart_4, .label = "Large" };
        segments[4] = .{ .value = 0, .color = theme.colors.chart_5, .label = "Other" }; // Remainder?
        
        widgets.drawDonutChart(donut_cx, donut_cy, radius, 30, &segments);
        
        // Legend at bottom
        var legend_y = donut_cy + @as(i32, @intFromFloat(radius)) + 40;
        for (segments) |seg| {
            if (seg.value > 0) {
                 rl.drawCircle(chart_x + 30, legend_y + 6, 4, seg.color);
                 widgets.drawLabel(seg.label, chart_x + 45, legend_y, theme.fonts.body, theme.colors.text_secondary);
                 // PCT
                 const total = @max(1.0, @as(f32, @floatFromInt(self.total_size)));
                 var pct_buf: [16]u8 = undefined;
                 const pct = std.fmt.bufPrint(&pct_buf, "{d:.0}%", .{ (seg.value / total) * 100.0 }) catch "0%";
                 var pct_z: [16:0]u8 = undefined; @memcpy(pct_z[0..pct.len], pct); pct_z[pct.len] = 0;
                 
                 widgets.drawStrong(&pct_z, chart_x + chart_w - 60, legend_y, theme.fonts.body, theme.colors.text_primary);
                 legend_y += 30;
            }
        }
        
        // 2. File List Card
        widgets.drawCard(list_x, chart_y, list_w, list_h);

        // Header row with buttons
        const header_y = chart_y + 15;
        const btn_h: i32 = 28;

        // Select All / Deselect All button
        const select_btn_w: i32 = 90;
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

        // Column labels
        widgets.drawLabel("FILE PATH", list_x + 20 + 50, header_y + btn_h + 10, theme.fonts.small, theme.colors.text_muted);
        widgets.drawLabel("SIZE", list_x + list_w - 120, header_y + btn_h + 10, theme.fonts.small, theme.colors.text_muted);

        // List area
        const list_area_y = header_y + btn_h + 35;
        const list_area_h = list_h - 80;
        
        // Render rows
        const row_h = 70; // High rows with icon
        var curr_y = list_area_y;
        var i: usize = self.scroll_offset;
        
        // Clip content
        rl.beginScissorMode(list_x, list_area_y, list_w, list_area_h);
        
        while (i < self.filtered_indices.items.len and curr_y < list_area_y + list_area_h) : (i += 1) {
            const idx = self.filtered_indices.items[i];
            const file = &self.files.items[idx];

            // Row background highlight if selected or stale
            const is_stale = file.isStale(90);
            if (file.selected or is_stale) {
                const row_rec = rl.Rectangle{
                    .x = @floatFromInt(list_x + 10),
                    .y = @floatFromInt(curr_y),
                    .width = @floatFromInt(list_w - 20),
                    .height = @floatFromInt(row_h - 5),
                };
                var bg_color = if (file.selected) theme.colors.success else theme.colors.warning;
                bg_color.a = if (file.selected) 20 else 10;
                rl.drawRectangleRounded(row_rec, 0.1, 4, bg_color);
            }

            // Checkbox for selection
            if (widgets.drawCheckbox(file.selected, list_x + 20, curr_y + 25)) {
                file.selected = !file.selected;
                self.updateSelectionStats();
            }

            // Name
            var name_buf: [256:0]u8 = undefined;
            const name_len = @min(file.name.len, 255);
            @memcpy(name_buf[0..name_len], file.name[0..name_len]);
            name_buf[name_len] = 0;
            widgets.drawLabel(&name_buf, list_x + 55, curr_y + 10, theme.fonts.body, theme.colors.text_primary);

            // Confidence badge (right after name)
            const conf_pct = @as(u32, @intFromFloat(file.confidence * 100));
            var conf_buf: [8:0]u8 = undefined;
            const conf_str = std.fmt.bufPrint(&conf_buf, "{d}%", .{conf_pct}) catch "??%";
            conf_buf[conf_str.len] = 0;

            // Confidence badge color based on value
            const conf_color = if (file.confidence >= 0.90)
                theme.colors.success
            else if (file.confidence >= 0.70)
                theme.colors.warning
            else
                theme.colors.danger;

            // Draw small confidence badge
            const name_width = @as(i32, @intFromFloat(widgets.measureTextEx(&name_buf, theme.fonts.body)));
            widgets.drawBadge(conf_buf[0..conf_str.len :0], list_x + 60 + name_width, curr_y + 10, conf_color);

            // Subtitle: path + stale indicator
            const path_trunc = if (file.path.len > 35) file.path[file.path.len - 35 ..] else file.path;
            var sub_buf: [128]u8 = undefined;
            const sub = if (is_stale)
                std.fmt.bufPrint(&sub_buf, "...{s}  [{d} days old]", .{ path_trunc, file.days_old }) catch ""
            else if (file.days_old > 0)
                std.fmt.bufPrint(&sub_buf, "...{s}  [{d}d]", .{ path_trunc, file.days_old }) catch ""
            else
                std.fmt.bufPrint(&sub_buf, "...{s}", .{path_trunc}) catch "";
            var sub_z: [128:0]u8 = undefined;
            @memcpy(sub_z[0..sub.len], sub);
            sub_z[sub.len] = 0;

            const sub_color = if (is_stale) theme.colors.warning else theme.colors.text_muted;
            widgets.drawLabel(&sub_z, list_x + 55, curr_y + 32, theme.fonts.small, sub_color);

            // Category badge
            const cat_label: [:0]const u8 = switch (file.category) {
                .dev_artifact => "Dev",
                .cache => "Cache",
                .temporary => "Temp",
                .log => "Log",
                .large => "Large",
                .browser_data => "Browser",
                else => "Other",
            };
            const cat_color = switch (file.category) {
                .dev_artifact => theme.colors.chart_1,
                .cache => theme.colors.chart_2,
                .temporary => theme.colors.chart_3,
                .log => theme.colors.chart_4,
                .browser_data => theme.colors.chart_5,
                else => theme.colors.text_muted,
            };
            widgets.drawBadge(cat_label, list_x + 55, curr_y + 50, cat_color);

            // Size (right side)
            var sz_buf: [32]u8 = undefined;
            const sz_s = widgets.formatSizeBuffer(file.size, &sz_buf);
            var sz_z: [32:0]u8 = undefined;
            @memcpy(sz_z[0..sz_s.len], sz_s);
            sz_z[sz_s.len] = 0;
            const sz_w = widgets.measureTextEx(&sz_z, theme.fonts.body);
            widgets.drawLabel(&sz_z, list_x + list_w - 100 - @as(i32, @intFromFloat(sz_w)), curr_y + 25, theme.fonts.body, theme.colors.text_primary);

            // Delete Action (single item) - store idx for deletion
            if (widgets.drawIconButton("X", list_x + list_w - 55, curr_y + 20, 30, theme.colors.danger)) {
                self.deleteSingleItem(idx);
            }

            curr_y += row_h;
        }
        rl.endScissorMode();
    }
};
