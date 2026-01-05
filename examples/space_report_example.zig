const std = @import("std");
const scanner = @import("../src/scanner.zig");
const analyzer = @import("../src/analyzer.zig");
const config = @import("../src/config.zig");
const platform = @import("../src/platform.zig");
const space_tracker = @import("../src/space_tracker.zig");

/// Example demonstrating space calculation and reporting functionality
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Space Tracking Example ===\n\n", .{});

    // Create configuration
    var cfg = config.Config.init(allocator);
    defer cfg.deinit();

    // Set up scan paths (use current directory for this example)
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    try cfg.scan_paths.append(allocator, try allocator.dupe(u8, cwd_path));

    // Initialize scanner
    var file_scanner = scanner.Scanner.init(allocator, &cfg);
    defer file_scanner.deinit();

    // Perform scan
    std.debug.print("Scanning directory: {s}\n", .{cwd_path});
    try file_scanner.scanAll();

    const scan_stats = file_scanner.getStats();
    std.debug.print("Found {d} files ({d} directories)\n\n", .{
        scan_stats.total_files,
        scan_stats.total_dirs,
    });

    // Initialize analyzer
    var file_analyzer = analyzer.Analyzer.init(allocator, .{
        .categories = .{
            .temp_files = true,
            .cache_files = true,
            .log_files = true,
            .large_files = true,
            .old_downloads = true,
            .dev_artifacts = true,
        },
    });
    defer file_analyzer.deinit();

    // Analyze files
    std.debug.print("Analyzing files...\n", .{});
    try file_analyzer.analyzeFiles(file_scanner.getResults());

    const analysis_stats = file_analyzer.getStats();
    std.debug.print("Analyzed {d} files\n\n", .{analysis_stats.total_analyzed});

    // Initialize space tracker
    var tracker = space_tracker.SpaceTracker.init(allocator);
    defer tracker.deinit();

    // Process results and build statistics
    std.debug.print("Building space statistics...\n", .{});
    try tracker.processResults(file_analyzer.getResults());

    // Generate and display report
    std.debug.print("\n", .{});
    const report = try tracker.generateReport(allocator);
    defer allocator.free(report);

    std.debug.print("{s}\n", .{report});

    // Display progress information
    std.debug.print("\n=== Processing Statistics ===\n", .{});
    std.debug.print("Files processed: {d}\n", .{tracker.progress.files_processed});
    std.debug.print("Bytes scanned: {d}\n", .{tracker.progress.bytes_scanned});
    std.debug.print("Processing rate: {d:.2} files/sec\n", .{tracker.progress.getFilesPerSecond()});

    const bytes_per_sec = tracker.progress.getBytesPerSecond();
    const bytes_per_sec_str = try platform.formatSize(allocator, @intFromFloat(bytes_per_sec));
    defer allocator.free(bytes_per_sec_str);
    std.debug.print("Throughput: {s}/sec\n", .{bytes_per_sec_str});

    // Show breakdown by category
    std.debug.print("\n=== Category Details ===\n", .{});
    const sorted_categories = try tracker.breakdown.getSortedCategories(allocator);
    defer allocator.free(sorted_categories);

    for (sorted_categories, 0..) |cat_size, i| {
        const size_str = try platform.formatSize(allocator, cat_size.size);
        defer allocator.free(size_str);

        const pct = if (tracker.breakdown.total.total_bytes > 0)
            @as(f32, @floatFromInt(cat_size.size)) / @as(f32, @floatFromInt(tracker.breakdown.total.total_bytes)) * 100.0
        else
            0.0;

        std.debug.print("{d}. {s}: {s} ({d:.1}%)\n", .{
            i + 1,
            cat_size.category.getName(),
            size_str,
            pct,
        });

        std.debug.print("   Files: {d} | Deletable: {d} ({s})\n", .{
            cat_size.stats.file_count,
            cat_size.stats.deletable_count,
            if (cat_size.stats.deletable_count > 0) "safe" else "review",
        });
    }

    // Show size distribution
    std.debug.print("\n=== File Size Distribution ===\n", .{});
    const dist = tracker.breakdown.total.size_distribution;
    std.debug.print("Tiny (<1KB):        {d:6} files\n", .{dist.tiny});
    std.debug.print("Small (1KB-1MB):    {d:6} files\n", .{dist.small});
    std.debug.print("Medium (1MB-100MB): {d:6} files\n", .{dist.medium});
    std.debug.print("Large (100MB-1GB):  {d:6} files\n", .{dist.large});
    std.debug.print("Huge (>1GB):        {d:6} files\n", .{dist.huge});

    std.debug.print("\n✅ Space tracking demonstration complete!\n", .{});
}
