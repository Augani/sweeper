//! Background Scanner Module
//!
//! Provides non-blocking filesystem scanning using a background thread.
//! Results are streamed to the main thread via a thread-safe queue.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform.zig");
const analyzer = @import("../analyzer.zig");

/// Scan result for a discovered item
pub const ScanResult = struct {
    path: []const u8,
    name: []const u8,
    category: analyzer.FileCategory,
    size: u64, // SIZE_PENDING = max u64 means not yet calculated
    stale_days: u32, // 0 = not stale or not applicable
    is_stale: bool,

    pub const SIZE_PENDING: u64 = std.math.maxInt(u64);
};

/// Scan status enum (u8 for atomic compatibility)
pub const ScanStatus = enum(u8) {
    idle = 0,
    discovering = 1, // Phase 1: Finding directories
    calculating = 2, // Phase 2: Calculating sizes
    done = 3,
    scan_error = 4,
};

/// Thread-safe result queue
pub const ResultQueue = struct {
    mutex: std.Thread.Mutex,
    items: std.ArrayListUnmanaged(ScanResult),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ResultQueue {
        return .{
            .mutex = .{},
            .items = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ResultQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |item| {
            self.allocator.free(item.path);
        }
        self.items.deinit(self.allocator);
    }

    pub fn push(self: *ResultQueue, item: ScanResult) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.items.append(self.allocator, item) catch {};
    }

    pub fn drain(self: *ResultQueue, out: *std.ArrayListUnmanaged(ScanResult), out_allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        out.appendSlice(out_allocator, self.items.items) catch {};
        self.items.clearRetainingCapacity();
    }

    pub fn count(self: *ResultQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.items.items.len;
    }
};

/// Background scanner that runs discovery in a separate thread
pub const BackgroundScanner = struct {
    allocator: std.mem.Allocator,
    results: ResultQueue,
    status: std.atomic.Value(ScanStatus),
    progress: std.atomic.Value(u32), // 0-100
    items_found: std.atomic.Value(u32),
    should_stop: std.atomic.Value(bool),
    scan_thread: ?std.Thread,
    stale_threshold_days: u32,

    pub fn init(allocator: std.mem.Allocator) BackgroundScanner {
        return .{
            .allocator = allocator,
            .results = ResultQueue.init(allocator),
            .status = std.atomic.Value(ScanStatus).init(.idle),
            .progress = std.atomic.Value(u32).init(0),
            .items_found = std.atomic.Value(u32).init(0),
            .should_stop = std.atomic.Value(bool).init(false),
            .scan_thread = null,
            .stale_threshold_days = 90, // Default 90 days
        };
    }

    pub fn deinit(self: *BackgroundScanner) void {
        self.stop();
        self.results.deinit();
    }

    /// Start scanning in background thread
    pub fn startScan(self: *BackgroundScanner) void {
        // Stop any existing scan
        self.stop();

        // Reset state
        self.status.store(.discovering, .monotonic);
        self.progress.store(0, .monotonic);
        self.items_found.store(0, .monotonic);
        self.should_stop.store(false, .monotonic);

        // Spawn scan thread
        self.scan_thread = std.Thread.spawn(.{}, scanThread, .{self}) catch {
            self.status.store(.scan_error, .monotonic);
            return;
        };
    }

    /// Stop the scan
    pub fn stop(self: *BackgroundScanner) void {
        self.should_stop.store(true, .monotonic);
        if (self.scan_thread) |thread| {
            thread.join();
            self.scan_thread = null;
        }
    }

    /// Get current status
    pub fn getStatus(self: *BackgroundScanner) ScanStatus {
        return self.status.load(.monotonic);
    }

    /// Get progress (0-100)
    pub fn getProgress(self: *BackgroundScanner) u32 {
        return self.progress.load(.monotonic);
    }

    /// Get number of items found so far
    pub fn getItemsFound(self: *BackgroundScanner) u32 {
        return self.items_found.load(.monotonic);
    }

    /// Poll for new results (non-blocking)
    pub fn pollResults(self: *BackgroundScanner, out: *std.ArrayListUnmanaged(ScanResult), out_allocator: std.mem.Allocator) void {
        self.results.drain(out, out_allocator);
    }

    /// The main scan thread function
    fn scanThread(self: *BackgroundScanner) void {
        // Phase 1: Discovery using system find command
        self.runDiscovery();

        if (self.should_stop.load(.monotonic)) {
            self.status.store(.idle, .monotonic);
            return;
        }

        self.status.store(.done, .monotonic);
        self.progress.store(100, .monotonic);
    }

    /// Run discovery phase using platform-specific commands
    fn runDiscovery(self: *BackgroundScanner) void {
        const current_platform = platform.Platform.current();

        // Get home directory
        const home = switch (current_platform) {
            .windows => std.posix.getenv("USERPROFILE") orelse "C:\\Users",
            else => std.posix.getenv("HOME") orelse "/tmp",
        };

        // First add known system paths
        self.addKnownSystemPaths(home);
        self.progress.store(20, .monotonic);

        if (self.should_stop.load(.monotonic)) return;

        // Scan Downloads for old files (using stale threshold)
        self.scanOldDownloads(home);
        self.progress.store(30, .monotonic);

        if (self.should_stop.load(.monotonic)) return;

        // Then run find command for dev artifacts
        switch (current_platform) {
            .windows => self.runWindowsDiscovery(home),
            else => self.runUnixDiscovery(home),
        }

        self.progress.store(80, .monotonic);
    }

    /// Scan Downloads folder for old files (older than stale_threshold_days)
    fn scanOldDownloads(self: *BackgroundScanner, home: []const u8) void {
        const current_platform = platform.Platform.current();

        const downloads_path = switch (current_platform) {
            .windows => blk: {
                const path = std.fmt.allocPrint(self.allocator, "{s}\\Downloads", .{home}) catch return;
                break :blk path;
            },
            else => blk: {
                const path = std.fmt.allocPrint(self.allocator, "{s}/Downloads", .{home}) catch return;
                break :blk path;
            },
        };
        defer self.allocator.free(downloads_path);

        // Open downloads directory
        var dir = std.fs.openDirAbsolute(downloads_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (self.should_stop.load(.monotonic)) return;

            // Build full path
            const full_path = std.fs.path.join(self.allocator, &[_][]const u8{ downloads_path, entry.name }) catch continue;

            // Check file/dir age
            const stat = std.fs.cwd().statFile(full_path) catch {
                self.allocator.free(full_path);
                continue;
            };

            // Calculate age in days
            const now = std.time.nanoTimestamp();
            const mtime_ns: i128 = stat.mtime;
            const age_ns = now - mtime_ns;
            const age_days: u32 = @intCast(@max(0, @divTrunc(age_ns, std.time.ns_per_day)));

            // Only include if older than threshold
            if (age_days >= self.stale_threshold_days) {
                self.results.push(.{
                    .path = full_path,
                    .name = entry.name,
                    .category = .old_download,
                    .size = ScanResult.SIZE_PENDING,
                    .stale_days = age_days,
                    .is_stale = true,
                });
                _ = self.items_found.fetchAdd(1, .monotonic);
            } else {
                self.allocator.free(full_path);
            }
        }
    }

    /// Add known system paths (caches, logs, etc.)
    fn addKnownSystemPaths(self: *BackgroundScanner, home: []const u8) void {
        const current_platform = platform.Platform.current();

        // Common paths for all platforms
        const common_paths = [_]struct { suffix: []const u8, cat: analyzer.FileCategory }{
            .{ .suffix = "/.npm", .cat = .cache },
            .{ .suffix = "/.yarn", .cat = .cache },
            .{ .suffix = "/.pnpm-store", .cat = .cache },
            .{ .suffix = "/.cargo/registry", .cat = .cache },
            .{ .suffix = "/.rustup", .cat = .dev_artifact },
            .{ .suffix = "/.gradle/caches", .cat = .cache },
            .{ .suffix = "/.m2/repository", .cat = .cache },
            .{ .suffix = "/.pub-cache", .cat = .cache },
            .{ .suffix = "/.gem", .cat = .cache },
            .{ .suffix = "/.cocoapods", .cat = .cache },
            .{ .suffix = "/.cache", .cat = .cache },
            .{ .suffix = "/.docker", .cat = .dev_artifact },
            .{ .suffix = "/.nvm", .cat = .dev_artifact },
            .{ .suffix = "/go/pkg", .cat = .cache },
        };

        for (common_paths) |item| {
            if (self.should_stop.load(.monotonic)) return;
            self.addPathIfExists(home, item.suffix, item.cat);
        }

        // Platform-specific paths
        switch (current_platform) {
            .macos => {
                // Safe-to-delete items
                const macos_paths = [_]struct { suffix: []const u8, cat: analyzer.FileCategory }{
                    .{ .suffix = "/Library/Caches", .cat = .cache },
                    .{ .suffix = "/Library/Logs", .cat = .log },
                    .{ .suffix = "/.Trash", .cat = .temporary },
                    .{ .suffix = "/Library/Developer/Xcode/DerivedData", .cat = .dev_artifact },
                    .{ .suffix = "/Library/Developer/Xcode/Archives", .cat = .dev_artifact },
                    .{ .suffix = "/Library/Developer/Xcode/iOS DeviceSupport", .cat = .dev_artifact },
                    .{ .suffix = "/Library/Developer/CoreSimulator", .cat = .dev_artifact },
                    .{ .suffix = "/Library/Application Support/Code/Cache", .cat = .cache },
                    .{ .suffix = "/Library/Application Support/Code/CachedData", .cat = .cache },
                    .{ .suffix = "/Library/Caches/Homebrew", .cat = .cache },
                    .{ .suffix = "/Library/Caches/JetBrains", .cat = .cache },
                };
                for (macos_paths) |item| {
                    if (self.should_stop.load(.monotonic)) return;
                    self.addPathIfExists(home, item.suffix, item.cat);
                }
            },
            .linux => {
                // Only truly safe-to-delete items
                const linux_paths = [_]struct { suffix: []const u8, cat: analyzer.FileCategory }{
                    .{ .suffix = "/.local/share/Trash", .cat = .temporary },
                    // Downloads excluded - user files need manual review
                    .{ .suffix = "/.config/Code/Cache", .cat = .cache },
                    .{ .suffix = "/.config/Code/CachedData", .cat = .cache },
                    .{ .suffix = "/.cache/JetBrains", .cat = .cache },
                };
                for (linux_paths) |item| {
                    if (self.should_stop.load(.monotonic)) return;
                    self.addPathIfExists(home, item.suffix, item.cat);
                }
            },
            .windows => {
                // Windows paths use backslashes
                const localappdata = std.posix.getenv("LOCALAPPDATA") orelse "";
                if (localappdata.len > 0) {
                    self.addPathIfExists(localappdata, "\\Temp", .temporary);
                    self.addPathIfExists(localappdata, "\\npm-cache", .cache);
                    self.addPathIfExists(localappdata, "\\yarn\\Cache", .cache);
                }
            },
            .unknown => {},
        }
    }

    fn addPathIfExists(self: *BackgroundScanner, home: []const u8, suffix: []const u8, category: analyzer.FileCategory) void {
        const full_path = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home, suffix }) catch return;

        if (pathExists(full_path)) {
            self.addResult(full_path, category);
        } else {
            self.allocator.free(full_path);
        }
    }

    fn addPathIfExistsAbs(self: *BackgroundScanner, path: []const u8, category: analyzer.FileCategory) void {
        const path_copy = self.allocator.dupe(u8, path) catch return;

        if (pathExists(path_copy)) {
            self.addResult(path_copy, category);
        } else {
            self.allocator.free(path_copy);
        }
    }

    fn addResult(self: *BackgroundScanner, path: []const u8, category: analyzer.FileCategory) void {
        const name = std.fs.path.basename(path);

        // Check staleness for dev artifacts
        var stale_days: u32 = 0;
        var is_stale = false;

        if (category == .dev_artifact) {
            const stale_info = checkStaleness(self.allocator, path, self.stale_threshold_days);
            stale_days = stale_info.days;
            is_stale = stale_info.is_stale;
        }

        self.results.push(.{
            .path = path,
            .name = name,
            .category = category,
            .size = ScanResult.SIZE_PENDING,
            .stale_days = stale_days,
            .is_stale = is_stale,
        });

        _ = self.items_found.fetchAdd(1, .monotonic);
    }

    /// Run Unix (macOS/Linux) discovery using find command
    fn runUnixDiscovery(self: *BackgroundScanner, home: []const u8) void {
        // Build find command for dev artifacts
        const find_cmd = std.fmt.allocPrint(
            self.allocator,
            "find \"{s}\" -maxdepth 12 -type d \\( " ++
                "-name 'node_modules' -o " ++
                "-name 'target' -o " ++
                "-name '.build' -o " ++
                "-name 'DerivedData' -o " ++
                "-name 'Pods' -o " ++
                "-name 'build' -o " ++
                "-name 'dist' -o " ++
                "-name '__pycache__' -o " ++
                "-name '.gradle' -o " ++
                "-name 'venv' -o " ++
                "-name '.venv' -o " ++
                "-name '.next' -o " ++
                "-name '.nuxt' -o " ++
                "-name 'vendor' -o " ++
                "-name 'obj' " ++
                "\\) -prune 2>/dev/null",
            .{home},
        ) catch return;
        defer self.allocator.free(find_cmd);

        // Execute find command
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "/bin/sh", "-c", find_cmd },
            .max_output_bytes = 50 * 1024 * 1024, // 50MB max output
        }) catch return;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        // Parse output
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            if (self.should_stop.load(.monotonic)) return;
            if (line.len == 0) continue;

            const path_copy = self.allocator.dupe(u8, line) catch continue;
            const name = std.fs.path.basename(path_copy);

            // Determine category
            const category = categorizeByName(name);

            // Check staleness
            var stale_days: u32 = 0;
            var is_stale = false;
            if (category == .dev_artifact) {
                const stale_info = checkStaleness(self.allocator, path_copy, self.stale_threshold_days);
                stale_days = stale_info.days;
                is_stale = stale_info.is_stale;
            }

            self.results.push(.{
                .path = path_copy,
                .name = name,
                .category = category,
                .size = ScanResult.SIZE_PENDING,
                .stale_days = stale_days,
                .is_stale = is_stale,
            });

            _ = self.items_found.fetchAdd(1, .monotonic);
        }
    }

    /// Run Windows discovery using PowerShell
    fn runWindowsDiscovery(self: *BackgroundScanner, home: []const u8) void {
        // Build PowerShell command
        const ps_cmd = std.fmt.allocPrint(
            self.allocator,
            "powershell -NoProfile -Command \"Get-ChildItem -Path '{s}' -Recurse -Directory -Depth 12 -ErrorAction SilentlyContinue | " ++
                "Where-Object {{ $_.Name -match '^(node_modules|target|\\.build|build|dist|__pycache__|\\.gradle|venv|\\.venv|\\.next|\\.nuxt|vendor|obj|Pods)$' }} | " ++
                "Select-Object -ExpandProperty FullName\"",
            .{home},
        ) catch return;
        defer self.allocator.free(ps_cmd);

        // Execute PowerShell command
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "cmd", "/c", ps_cmd },
            .max_output_bytes = 50 * 1024 * 1024,
        }) catch return;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        // Parse output (Windows uses CRLF)
        var lines = std.mem.splitSequence(u8, result.stdout, "\r\n");
        while (lines.next()) |line| {
            if (self.should_stop.load(.monotonic)) return;
            if (line.len == 0) continue;

            const path_copy = self.allocator.dupe(u8, line) catch continue;
            const name = std.fs.path.basename(path_copy);
            const category = categorizeByName(name);

            var stale_days: u32 = 0;
            var is_stale = false;
            if (category == .dev_artifact) {
                const stale_info = checkStaleness(self.allocator, path_copy, self.stale_threshold_days);
                stale_days = stale_info.days;
                is_stale = stale_info.is_stale;
            }

            self.results.push(.{
                .path = path_copy,
                .name = name,
                .category = category,
                .size = ScanResult.SIZE_PENDING,
                .stale_days = stale_days,
                .is_stale = is_stale,
            });

            _ = self.items_found.fetchAdd(1, .monotonic);
        }
    }
};

/// Categorize directory by name
fn categorizeByName(name: []const u8) analyzer.FileCategory {
    if (std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, "target") or
        std.mem.eql(u8, name, ".build") or
        std.mem.eql(u8, name, "DerivedData") or
        std.mem.eql(u8, name, "Pods") or
        std.mem.eql(u8, name, ".gradle") or
        std.mem.eql(u8, name, "venv") or
        std.mem.eql(u8, name, ".venv") or
        std.mem.eql(u8, name, ".next") or
        std.mem.eql(u8, name, ".nuxt") or
        std.mem.eql(u8, name, "vendor") or
        std.mem.eql(u8, name, "obj"))
    {
        return .dev_artifact;
    }

    if (std.mem.eql(u8, name, "build") or std.mem.eql(u8, name, "dist")) {
        return .dev_artifact;
    }

    if (std.mem.eql(u8, name, "__pycache__")) {
        return .cache;
    }

    return .dev_artifact;
}

/// Stale info result
pub const StaleInfo = struct {
    is_stale: bool,
    days: u32,
};

/// Check if a project is stale by looking at parent directory modification times
fn checkStaleness(allocator: std.mem.Allocator, path: []const u8, threshold_days: u32) StaleInfo {
    const parent = std.fs.path.dirname(path) orelse return .{ .is_stale = false, .days = 0 };

    // Check for package.json, Cargo.toml, build.gradle, etc.
    const config_files = [_][]const u8{
        "package.json",
        "Cargo.toml",
        "build.gradle",
        "pom.xml",
        "Podfile",
        "Package.swift",
        "pyproject.toml",
        "setup.py",
        "go.mod",
    };

    var newest_mtime: i128 = 0;

    for (config_files) |config_file| {
        const config_path = std.fs.path.join(allocator, &[_][]const u8{ parent, config_file }) catch continue;
        defer allocator.free(config_path);

        if (std.fs.cwd().statFile(config_path)) |stat| {
            if (stat.mtime > newest_mtime) {
                newest_mtime = stat.mtime;
            }
        } else |_| {
            continue;
        }
    }

    if (newest_mtime == 0) {
        // No config file found, check parent directory itself
        if (std.fs.cwd().statFile(parent)) |stat| {
            newest_mtime = stat.mtime;
        } else |_| {
            return .{ .is_stale = false, .days = 0 };
        }
    }

    // Calculate age in days
    const now = std.time.nanoTimestamp();
    const mtime_ns: i128 = newest_mtime;
    const age_ns = now - mtime_ns;
    const age_days: u32 = @intCast(@max(0, @divTrunc(age_ns, std.time.ns_per_day)));

    return .{
        .is_stale = age_days >= threshold_days,
        .days = age_days,
    };
}

/// Check if a path exists
fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Calculate directory size using system du command (fast)
pub fn calculateDirSize(allocator: std.mem.Allocator, path: []const u8) u64 {
    const current_platform = platform.Platform.current();

    switch (current_platform) {
        .windows => return calculateDirSizeWindows(allocator, path),
        else => return calculateDirSizeUnix(allocator, path),
    }
}

fn calculateDirSizeUnix(allocator: std.mem.Allocator, path: []const u8) u64 {
    // Use du -sk for speed (returns size in KB)
    const cmd = std.fmt.allocPrint(
        allocator,
        "du -sk \"{s}\" 2>/dev/null | cut -f1",
        .{path},
    ) catch return 0;
    defer allocator.free(cmd);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
        .max_output_bytes = 1024,
    }) catch return 0;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Parse the size (in KB)
    const trimmed = std.mem.trim(u8, result.stdout, &[_]u8{ ' ', '\t', '\n', '\r' });
    const size_kb = std.fmt.parseInt(u64, trimmed, 10) catch return 0;

    return size_kb * 1024; // Convert to bytes
}

fn calculateDirSizeWindows(allocator: std.mem.Allocator, path: []const u8) u64 {
    // Use PowerShell to calculate size
    const cmd = std.fmt.allocPrint(
        allocator,
        "powershell -NoProfile -Command \"(Get-ChildItem -Path '{s}' -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum\"",
        .{path},
    ) catch return 0;
    defer allocator.free(cmd);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "cmd", "/c", cmd },
        .max_output_bytes = 1024,
    }) catch return 0;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const trimmed = std.mem.trim(u8, result.stdout, &[_]u8{ ' ', '\t', '\n', '\r' });
    return std.fmt.parseInt(u64, trimmed, 10) catch 0;
}
