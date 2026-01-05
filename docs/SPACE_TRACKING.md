# Space Calculation and Reporting

This document describes the space calculation and reporting features of the Desktop Cleanup TUI tool.

## Overview

The space tracking system provides comprehensive statistics about file space usage, categorization, and potential savings. It includes real-time progress tracking and visual indicators for better user experience.

## Components

### 1. Space Statistics (`SpaceStats`)

Tracks detailed metrics for a category or group of files:

- **File counts**: Total files and deletable files
- **Size metrics**: Total bytes, deletable bytes, largest/smallest/average file sizes
- **Size distribution**: Files grouped by size brackets (tiny, small, medium, large, huge)
- **Percentage calculations**: Deletable percentage and other ratios

### 2. Category Breakdown (`CategoryBreakdown`)

Organizes space statistics by file category:

- Maintains separate stats for each file category (temporary, cache, logs, etc.)
- Provides sorted views of categories by size
- Aggregates total statistics across all categories

### 3. Space Progress (`SpaceProgress`)

Real-time progress tracking for scanning and analysis operations:

- **Progress metrics**: Files processed, bytes scanned, current file
- **Time estimation**: ETA calculation based on processing rate
- **Rate metrics**: Files per second and bytes per second throughput
- **Elapsed time tracking**: Total time since operation started

### 4. Space Tracker (`SpaceTracker`)

High-level coordinator for space analysis:

- Processes analysis results and builds comprehensive statistics
- Tracks top largest files across all categories
- Generates formatted reports
- Maintains progress information

## Usage

### Basic Usage

```zig
const space_tracker = @import("space_tracker.zig");

// Initialize tracker
var tracker = space_tracker.SpaceTracker.init(allocator);
defer tracker.deinit();

// Process analysis results
try tracker.processResults(analysis_results);

// Get potential savings
const savings = tracker.getPotentialSavings();

// Generate report
const report = try tracker.generateReport(allocator);
defer allocator.free(report);
```

### Accessing Statistics

```zig
// Get total statistics
const total_stats = tracker.breakdown.total;
std.debug.print("Total files: {d}\n", .{total_stats.file_count});
std.debug.print("Total size: {d} bytes\n", .{total_stats.total_bytes});

// Get category-specific stats
if (tracker.breakdown.getCategoryStats(.temporary)) |temp_stats| {
    std.debug.print("Temp files: {d}\n", .{temp_stats.file_count});
}

// Get sorted categories
const sorted = try tracker.breakdown.getSortedCategories(allocator);
defer allocator.free(sorted);

for (sorted) |cat_size| {
    std.debug.print("{s}: {d} bytes\n", .{
        cat_size.category.getName(),
        cat_size.size,
    });
}
```

### Progress Tracking

```zig
// Initialize progress
var progress = space_tracker.SpaceProgress.init();

// Update progress during processing
progress.update(files_done, total_files, bytes_done);

// Get metrics
const fps = progress.getFilesPerSecond();
const bps = progress.getBytesPerSecond();

// Get ETA
var eta_buf: [32]u8 = undefined;
const eta = progress.getETA(&eta_buf);
```

## TUI Integration

### Visual Widgets

The TUI includes several widgets for visualizing space usage:

#### 1. Gauge Widget
Displays a metric with a visual progress bar:

```zig
var gauge = widgets.Gauge{
    .value = selected_bytes,
    .max_value = total_bytes,
    .label = "Potential Savings",
    .bar_style = Style.default.withFg(.green),
};
gauge.draw(buf, rect);
```

#### 2. Size Chart Widget
Visualizes proportional space usage across categories:

```zig
const segments = [_]widgets.SizeChart.Segment{
    .{ .label = "Temp", .value = temp_size, .style = Style.default.withFg(.yellow) },
    .{ .label = "Cache", .value = cache_size, .style = Style.default.withFg(.cyan) },
    // ... more segments
};

var chart = widgets.SizeChart{
    .segments = &segments,
    .show_legend = true,
};
chart.draw(buf, rect);
```

#### 3. Multi-Progress Widget
Shows progress for multiple concurrent operations:

```zig
const items = [_]widgets.MultiProgress.ProgressItem{
    .{ .label = "Scanning", .progress = 0.75, .style = Style.default.withFg(.cyan) },
    .{ .label = "Analyzing", .progress = 0.45, .style = Style.default.withFg(.green) },
};

var multi = widgets.MultiProgress{
    .items = &items,
};
multi.draw(buf, rect);
```

#### 4. Sparkline Widget
Displays trend data in compact form:

```zig
const data = [_]u64{ 10, 25, 40, 35, 50, 60, 55, 70 };

var sparkline = widgets.Sparkline{
    .data = &data,
    .style = Style.default.withFg(.green),
};
sparkline.draw(buf, rect);
```

### Space Report View

Access the space report in the TUI by pressing `r`:

- **Overall statistics**: Total files, total space, potential savings
- **Visual gauge**: Percentage of space that can be freed
- **Category breakdown**: Files and space usage by category
- **Top largest files**: List of the largest files found

## Size Distribution

Files are categorized into size brackets:

| Bracket | Range | Description |
|---------|-------|-------------|
| Tiny | < 1 KB | Very small files |
| Small | 1 KB - 1 MB | Small files |
| Medium | 1 MB - 100 MB | Medium-sized files |
| Large | 100 MB - 1 GB | Large files |
| Huge | > 1 GB | Very large files |

## Statistics Tracked

### Per-Category Statistics

- File count
- Total size
- Deletable file count
- Deletable size
- Largest file size
- Smallest file size
- Average file size
- Size distribution across brackets

### Overall Statistics

- Total files analyzed
- Total bytes scanned
- Potential space savings
- Processing rate (files/sec and bytes/sec)
- Time estimates (elapsed and ETA)

## Report Format

The generated report includes:

1. **Header**: Report title
2. **Overall Statistics**:
   - Total files analyzed
   - Total space used
   - Potential savings (size and percentage)
3. **Category Breakdown**:
   - Space usage by category
   - Percentage of total space
   - File count per category
4. **Top Largest Files**:
   - Top 10 largest files
   - File path, size, and category
5. **Size Distribution**:
   - File counts across size brackets

## Performance Considerations

- **Memory efficiency**: Only tracks top 100 largest files by default (configurable)
- **Incremental updates**: Progress can be updated in real-time
- **Sorted views**: Categories and files are sorted on demand, not continuously
- **Space complexity**: O(n) for basic stats, O(k log k) for top-k largest files

## Example Output

```
=== Space Analysis Report ===

Total Files Analyzed: 1234
Total Space Used: 15.3 GB
Potential Savings: 8.2 GB (53.6%)

--- Space by Category ---
  Cache: 5.1 GB (33.3%) - 456 files
  Dev Artifact: 2.8 GB (18.3%) - 89 files
  Temporary: 0.3 GB (2.0%) - 234 files
  Log: 0.1 GB (0.7%) - 67 files

--- Top 10 Largest Files ---
 1. 2.1 GB - node_modules.tar.gz (Dev Artifact)
 2. 1.5 GB - cache.db (Cache)
 3. 890 MB - old_backup.zip (Temporary)
 ...

--- Size Distribution ---
  Tiny (<1KB):        234 files
  Small (1KB-1MB):    789 files
  Medium (1MB-100MB): 189 files
  Large (100MB-1GB):   19 files
  Huge (>1GB):          3 files
```

## Keyboard Shortcuts

In the main view:
- `r` - Open space report
- `?` - Show help (includes space report info)

In the space report view:
- `q` / `Esc` - Close and return to main view

## API Reference

### SpaceStats

```zig
pub const SpaceStats = struct {
    pub fn add(self: *SpaceStats, file_size: u64, is_deletable: bool) void
    pub fn finalize(self: *SpaceStats) void
    pub fn getDeletablePercentage(self: SpaceStats) f32
    pub fn format(self: SpaceStats, allocator: std.mem.Allocator) ![]u8
}
```

### CategoryBreakdown

```zig
pub const CategoryBreakdown = struct {
    pub fn init() CategoryBreakdown
    pub fn deinit(self: *CategoryBreakdown, allocator: std.mem.Allocator) void
    pub fn add(self: *CategoryBreakdown, allocator: std.mem.Allocator,
               category: FileCategory, file_size: u64, is_deletable: bool) !void
    pub fn finalize(self: *CategoryBreakdown) void
    pub fn getCategoryStats(self: *CategoryBreakdown, category: FileCategory) ?SpaceStats
    pub fn getSortedCategories(self: *CategoryBreakdown, allocator: std.mem.Allocator) ![]CategorySize
}
```

### SpaceProgress

```zig
pub const SpaceProgress = struct {
    pub fn init() SpaceProgress
    pub fn update(self: *SpaceProgress, files_done: u64, total_files: u64, bytes_done: u64) void
    pub fn getElapsedTime(self: SpaceProgress) []const u8
    pub fn getETA(self: SpaceProgress, buf: []u8) []const u8
    pub fn getFilesPerSecond(self: SpaceProgress) f64
    pub fn getBytesPerSecond(self: SpaceProgress) f64
}
```

### SpaceTracker

```zig
pub const SpaceTracker = struct {
    pub fn init(allocator: std.mem.Allocator) SpaceTracker
    pub fn deinit(self: *SpaceTracker) void
    pub fn processResults(self: *SpaceTracker, results: []const AnalysisResult) !void
    pub fn addFile(self: *SpaceTracker, result: AnalysisResult) !void
    pub fn getPotentialSavings(self: *SpaceTracker) u64
    pub fn getTopLargestFiles(self: *SpaceTracker, n: usize) []const FileSize
    pub fn generateReport(self: *SpaceTracker, allocator: std.mem.Allocator) ![]u8
}
```

## See Also

- [Analyzer Documentation](ANALYZER.md) - File analysis and categorization
- [TUI Documentation](TUI.md) - Terminal user interface features
- [Configuration Guide](CONFIGURATION.md) - Customizing scan behavior
