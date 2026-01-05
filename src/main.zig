const std = @import("std");
const builtin = @import("builtin");

const platform = @import("platform.zig");
const config = @import("config.zig");
const scanner = @import("scanner.zig");
const analyzer = @import("analyzer.zig");
const tui = @import("tui.zig");

pub const version = "0.1.0";
pub const app_name = "Desktop Cleanup";

/// Simple writer wrapper for stdout
const StdoutWriter = struct {
    file: std.fs.File,

    pub fn print(self: StdoutWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, fmt, args) catch |err| {
            if (err == error.NoSpaceLeft) {
                // Buffer too small, write what we can
                _ = try self.file.write(&buf);
                return;
            }
            return err;
        };
        _ = try self.file.write(formatted);
    }
};

fn getStdout() StdoutWriter {
    return StdoutWriter{ .file = std.fs.File.stdout() };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize platform-specific features
    try platform.init();
    defer platform.deinit();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Print startup banner
    const stdout = getStdout();
    try stdout.print("\n{s} v{s}\n", .{ app_name, version });
    try stdout.print("Platform: {s}\n", .{@tagName(builtin.os.tag)});
    try stdout.print("Architecture: {s}\n\n", .{@tagName(builtin.cpu.arch)});

    // Initialize configuration
    var cfg = config.Config.init(allocator);
    defer cfg.deinit();

    // Parse arguments and configure
    var scan_path: ?[]const u8 = null;
    var do_scan = false;
    var use_tui = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp(stdout);
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try stdout.print("{s} v{s}\n", .{ app_name, version });
            return;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            cfg.dry_run = true;
            try stdout.print("Dry-run mode enabled\n", .{});
        } else if (std.mem.eql(u8, arg, "--scan")) {
            do_scan = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            cfg.verbose = true;
        } else if (std.mem.eql(u8, arg, "--hidden")) {
            cfg.show_hidden = true;
        } else if (std.mem.eql(u8, arg, "--analyze")) {
            do_scan = true;
        } else if (std.mem.eql(u8, arg, "--tui") or std.mem.eql(u8, arg, "-i")) {
            use_tui = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            scan_path = arg;
            do_scan = true;
        }
    }

    // Launch TUI if requested
    if (use_tui) {
        try tui.run(allocator);
        return;
    }

    // If scan requested or path provided, run the scanner
    if (do_scan) {
        try runScan(allocator, &cfg, scan_path, stdout);
    } else {
        try stdout.print("Desktop Cleanup Tool initialized successfully.\n", .{});
        try stdout.print("Use --scan or provide a path to scan for files.\n", .{});
        try stdout.print("Use --tui or -i for interactive TUI mode.\n", .{});
        try stdout.print("Run with --help for more options.\n", .{});
    }
}

fn runScan(allocator: std.mem.Allocator, cfg: *config.Config, scan_path: ?[]const u8, writer: anytype) !void {
    // Add scan path(s)
    if (scan_path) |path| {
        try cfg.addScanPath(path);
    } else {
        // Use default paths
        try cfg.loadDefaults();
    }

    try writer.print("Starting filesystem scan...\n", .{});
    try writer.print("Scanning {d} path(s):\n", .{cfg.scan_paths.items.len});

    for (cfg.scan_paths.items) |path| {
        try writer.print("  - {s}\n", .{path});
    }
    try writer.print("\n", .{});

    // Create and run scanner
    var file_scanner = scanner.Scanner.init(allocator, cfg);
    defer file_scanner.deinit();

    try file_scanner.scanAll();

    // Get and display results
    const stats = file_scanner.getStats();
    const results = file_scanner.getResults();

    // Format and print statistics
    const stats_str = try stats.format(allocator);
    defer allocator.free(stats_str);
    try writer.print("{s}\n\n", .{stats_str});

    // Run file analysis
    try writer.print("Analyzing files for cleanup candidates...\n\n", .{});
    try runAnalysis(allocator, results, writer);
}

fn runAnalysis(allocator: std.mem.Allocator, files: []const scanner.FileInfo, writer: anytype) !void {
    // Create analyzer with default config
    var file_analyzer = analyzer.Analyzer.init(allocator, .{
        .large_file_threshold = 100 * 1024 * 1024, // 100MB
        .unused_days_threshold = 90,
        .old_download_days = 30,
        .detect_duplicates = true,
    });
    defer file_analyzer.deinit();

    // Analyze all files
    try file_analyzer.analyzeFiles(files);

    // Get statistics
    const analysis_stats = file_analyzer.getStats();
    const analysis_stats_str = try analysis_stats.format(allocator);
    defer allocator.free(analysis_stats_str);
    try writer.print("{s}\n\n", .{analysis_stats_str});

    // Show potential savings
    const savings = file_analyzer.getPotentialSavings();
    const savings_str = try platform.formatSize(allocator, savings);
    defer allocator.free(savings_str);
    try writer.print("Potential space savings: {s}\n\n", .{savings_str});

    // Show files by category
    const analysis_results = file_analyzer.getResults();
    if (analysis_results.len == 0) {
        try writer.print("No cleanup candidates found.\n", .{});
        return;
    }

    // Group and display by category
    try displayByCategory(allocator, analysis_results, writer, .temporary, "Temporary Files");
    try displayByCategory(allocator, analysis_results, writer, .cache, "Cache Files");
    try displayByCategory(allocator, analysis_results, writer, .log, "Log Files");
    try displayByCategory(allocator, analysis_results, writer, .duplicate, "Duplicate Files");
    try displayByCategory(allocator, analysis_results, writer, .large, "Large Files");
    try displayByCategory(allocator, analysis_results, writer, .unused, "Unused Files");
    try displayByCategory(allocator, analysis_results, writer, .old_download, "Old Downloads");
    try displayByCategory(allocator, analysis_results, writer, .dev_artifact, "Dev Artifacts");
}

fn displayByCategory(
    allocator: std.mem.Allocator,
    results: []const analyzer.AnalysisResult,
    writer: anytype,
    category: analyzer.FileCategory,
    title: []const u8,
) !void {
    // Count files in this category
    var count: usize = 0;
    var total_size: u64 = 0;

    for (results) |result| {
        if (result.hasCategory(category)) {
            count += 1;
            total_size += result.file.size;
        }
    }

    if (count == 0) return;

    const size_str = try platform.formatSize(allocator, total_size);
    defer allocator.free(size_str);

    try writer.print("{s} ({d} files, {s}):\n", .{ title, count, size_str });

    // Show up to 5 files per category
    var shown: usize = 0;
    for (results) |result| {
        if (result.hasCategory(category)) {
            const file_size_str = try platform.formatSize(allocator, result.file.size);
            defer allocator.free(file_size_str);

            // Show confidence as percentage
            const confidence_pct: u8 = @intFromFloat(result.confidence * 100);

            try writer.print("  [{s}] {s} ({d}%% confidence)\n", .{
                file_size_str,
                result.file.path,
                confidence_pct,
            });

            // Show duplicate info if applicable
            if (result.duplicate_of) |original| {
                try writer.print("         ^ duplicate of: {s}\n", .{original});
            }

            shown += 1;
            if (shown >= 5) {
                if (count > 5) {
                    try writer.print("  ... and {d} more\n", .{count - 5});
                }
                break;
            }
        }
    }
    try writer.print("\n", .{});
}

fn printHelp(writer: anytype) !void {
    try writer.print(
        \\Usage: desktop-cleanup [OPTIONS] [PATH]
        \\
        \\A cross-platform tool for cleaning up unused files and freeing disk space.
        \\
        \\Options:
        \\  -h, --help      Show this help message
        \\  -v, --version   Show version information
        \\  -i, --tui       Launch interactive TUI (Text User Interface)
        \\  --scan          Scan for files (runs automatically with PATH)
        \\  --analyze       Analyze files for cleanup (includes scan)
        \\  --dry-run       Show what would be deleted without actually deleting
        \\  --verbose       Enable verbose output
        \\  --hidden        Include hidden files in scan
        \\  --config FILE   Use custom configuration file
        \\
        \\TUI Controls:
        \\  Up/Down, j/k    Navigate file list
        \\  Space           Toggle file selection
        \\  a               Select all files
        \\  n               Deselect all files
        \\  d               Delete selected files
        \\  Enter           View file details
        \\  Tab             Switch category tabs
        \\  ?               Show help
        \\  q               Quit
        \\
        \\File Categories Detected:
        \\  - Temporary files (.tmp, .temp, .bak, ~)
        \\  - Cache files and directories
        \\  - Log files (.log)
        \\  - Duplicate files (same content)
        \\  - Large files (>100MB)
        \\  - Unused files (not accessed in 90+ days)
        \\  - Old downloads (30+ days)
        \\  - Development artifacts (node_modules, build, etc.)
        \\
        \\Examples:
        \\  desktop-cleanup --tui             Launch interactive TUI mode
        \\  desktop-cleanup /tmp              Scan and analyze /tmp directory
        \\  desktop-cleanup --scan            Scan and analyze default paths
        \\  desktop-cleanup ~/Downloads       Scan and analyze Downloads folder
        \\
        \\Supported Platforms:
        \\  - macOS
        \\  - Windows
        \\  - Linux
        \\
    , .{});
}

test "basic initialization" {
    // Basic test to verify compilation
    const allocator = std.testing.allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    try std.testing.expect(args.len >= 1);
}

test "scanner module import" {
    // Verify scanner module is properly imported
    const file_info = scanner.FileInfo{
        .path = "/test/path",
        .name = "test",
        .size = 1024,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
        .is_dir = false,
        .is_symlink = false,
        .is_hidden = false,
        .is_readonly = false,
        .is_executable = false,
        .extension = ".txt",
        .mode = 0o644,
        .inode = 0,
        .attributes = platform.FileAttributes{},
    };
    try std.testing.expect(file_info.size == 1024);
}

test "analyzer module import" {
    // Verify analyzer module is properly imported
    const allocator = std.testing.allocator;
    var file_analyzer = analyzer.Analyzer.init(allocator, .{});
    defer file_analyzer.deinit();

    try std.testing.expect(file_analyzer.stats.total_analyzed == 0);
    try std.testing.expect(analyzer.FileCategory.temporary.getName().len > 0);
}
