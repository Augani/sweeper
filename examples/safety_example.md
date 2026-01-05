# Safety Features Example

This example demonstrates all the safety features of the Desktop Cleanup Tool.

## 1. Dry-Run Mode Example

Test what would be deleted without actually deleting anything:

```bash
# Scan Downloads folder in dry-run mode
desktop-cleanup --dry-run --scan ~/Downloads

# Sample output:
# Starting filesystem scan...
# Scanning 1 path(s):
#   - /Users/name/Downloads
#
# [DRY-RUN] Would delete: /Users/name/Downloads/old-installer.dmg (125.3 MB)
# [DRY-RUN] Would delete: /Users/name/Downloads/temp-file.txt (1.2 KB)
# [DRY-RUN] Would delete: /Users/name/Downloads/cache/ (45.8 MB)
#
# Potential space savings: 171.1 MB
```

## 2. Verbose Logging Example

Enable detailed logging for full transparency:

```bash
# Run with verbose logging
desktop-cleanup --verbose --scan ~/Downloads

# This creates detailed logs in:
# macOS: ~/Library/Caches/desktop-cleanup.log
# Linux: ~/.cache/desktop-cleanup.log
```

Example log output:
```
[1704556800] [INFO] Application started: Desktop Cleanup v0.1.0
[1704556800] [INFO] Platform: macos, Arch: aarch64
[1704556801] [INFO] Starting file system scan
[1704556801] [INFO] Scanning path: /Users/name/Downloads
[1704556802] [DEBUG] Found file: old-installer.dmg (125.3 MB)
[1704556802] [DEBUG] Category: old_download, Confidence: 95%
[1704556803] [INFO] Scan complete: 342 files found, 12 directories
[1704556804] [INFO] Starting analysis of 342 files
[1704556805] [INFO] Analysis complete: potential savings 171.1 MB
```

## 3. Interactive Confirmation Example

When not in dry-run mode, the tool will ask for confirmation:

```bash
# Run without dry-run (will prompt for confirmation)
desktop-cleanup --scan ~/Downloads
```

Sample interaction:
```
Move 15 files (171.1 MB) to trash?
Files will be moved to trash and can be restored later.
[y]es, [n]o (default: no): y

Deleting files...
[✓] old-installer.dmg (125.3 MB)
[✓] temp-file.txt (1.2 KB)
[✓] cache/ (45.8 MB)
...

Batch deletion complete: 15 succeeded, 0 failed, 171.1 MB freed
```

## 4. Configuration with Safety Rules

Create a safe configuration file (`safe-config.json`):

```json
{
  "scan_paths": [
    "/Users/name/Downloads",
    "/Users/name/Desktop/temp"
  ],
  "exclude_patterns": [
    ".git",
    ".ssh",
    "*.key",
    "*.pem",
    "*.crt",
    "credentials*",
    "important_*",
    "backup_*"
  ],
  "dry_run": false,
  "use_trash": true,
  "verbose": true,
  "show_hidden": false,
  "min_file_size": 1048576,
  "max_file_age_days": 90,
  "scan_categories": {
    "temp_files": true,
    "cache_files": true,
    "log_files": true,
    "old_downloads": true,
    "duplicates": true,
    "large_files": true,
    "dev_artifacts": false,
    "browser_data": false
  }
}
```

Use it:
```bash
desktop-cleanup --config safe-config.json --scan
```

## 5. Programmatic Usage with All Safety Features

Example Zig code:

```zig
const std = @import("std");
const logger = @import("logger.zig");
const deleter = @import("deleter.zig");
const confirm = @import("confirm.zig");

pub fn safeDeletion() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Initialize logger
    var log = logger.Logger.init(allocator, .{
        .min_level = .info,
        .log_to_file = true,
        .log_to_console = true,
        .use_color = true,
    });
    defer log.deinit();

    // Enable file logging
    const log_path = try logger.Logger.getDefaultLogPath(allocator);
    defer allocator.free(log_path);
    try log.enableFileLogging(log_path);

    log.info("Starting safe deletion operation", .{});

    // 2. Create deleter with safety options
    var del = try deleter.Deleter.init(allocator, .{
        .use_trash = true,              // Move to trash, not permanent delete
        .dry_run = false,                // Actually delete (set to true for testing)
        .skip_readonly = true,           // Skip read-only files
        .safe_only = true,               // Only delete files marked as safe
        .require_confirmation = true,    // Prompt before deletion
        .verbose_logging = true,         // Log everything
        .logger_instance = &log,         // Use our logger
        .min_confidence = 0.8,           // Only delete high-confidence files
    });
    defer del.deinit();

    // 3. Files to delete
    const files = [_][]const u8{
        "/path/to/temp1.tmp",
        "/path/to/old-file.zip",
        "/path/to/cache/",
    };

    log.info("Preparing to delete {d} items", .{files.len});

    // 4. Preview what would be deleted
    const preview = try deleter.previewDelete(
        allocator,
        analysis_results, // From analyzer
        null, // All categories
        del.options,
    );
    defer preview.deinit(allocator);

    log.info("Would delete {d} files totaling {s}", .{
        preview.file_count,
        preview.size_string,
    });

    // 5. Ask for confirmation
    const confirmed = try confirm.confirmBatchDelete(
        allocator,
        preview.file_count,
        preview.total_size,
        !del.options.use_trash,
    );

    if (!confirmed) {
        log.info("Operation cancelled by user", .{});
        return;
    }

    // 6. Perform deletion
    const results = try del.deleteFiles(&files);
    defer {
        for (results) |*result| {
            var mut_result = result.*;
            mut_result.deinit(allocator);
        }
        allocator.free(results);
    }

    // 7. Review results
    var success_count: usize = 0;
    var fail_count: usize = 0;

    for (results) |result| {
        if (result.success) {
            success_count += 1;
            log.info("Deleted: {s}", .{result.path});
        } else {
            fail_count += 1;
            const error_msg = result.error_message orelse "Unknown error";
            log.err("Failed to delete {s}: {s}", .{result.path, error_msg});
        }
    }

    // 8. Get and log final statistics
    const stats = del.getStats();
    const stats_str = try stats.format(allocator);
    defer allocator.free(stats_str);

    log.info("Operation complete", .{});
    log.info("{s}", .{stats_str});

    // 9. Provide undo information
    if (del.options.use_trash) {
        const history = del.getHistory();
        const undoable_count = history.getUndoableCount();
        log.info("Can undo {d} operations", .{undoable_count});
    }
}
```

## 6. Testing Before Production

Always test with dry-run first:

```bash
# Step 1: Test with dry-run
desktop-cleanup --dry-run --verbose --scan ~/Downloads > preview.txt

# Step 2: Review the preview
cat preview.txt

# Step 3: If satisfied, run for real
desktop-cleanup --verbose --scan ~/Downloads
```

## 7. Recovering Deleted Files

### From Trash (Manual)

**macOS:**
```bash
# View trash contents
ls -lh ~/.Trash/

# Restore a file
mv ~/.Trash/filename.txt ~/Downloads/
```

**Linux:**
```bash
# View trash contents
ls -lh ~/.local/share/Trash/files/

# Restore a file
mv ~/.local/share/Trash/files/filename.txt ~/Downloads/
```

### Using History (Programmatic)

```zig
// List recent deletions
const history = deleter.getHistory();
const entries = history.getRecentEntries(20);

for (entries) |entry| {
    if (entry.operation == .delete_to_trash and !entry.undone) {
        const formatted = try entry.format(allocator);
        defer allocator.free(formatted);
        std.debug.print("[{d}] {s}\n", .{entry.id, formatted});
    }
}

// Restore by ID
const entry_id: u64 = 5; // From the list above
if (try deleter.undoById(entry_id)) |result| {
    if (result.success) {
        std.debug.print("Restored: {s}\n", .{result.path});
    } else {
        std.debug.print("Failed to restore: {s}\n", .{
            result.error_message orelse "Unknown error"
        });
    }
}
```

## 8. Monitoring Logs

### Real-time Monitoring
```bash
# macOS
tail -f ~/Library/Caches/desktop-cleanup.log

# Linux
tail -f ~/.cache/desktop-cleanup.log
```

### Search Logs
```bash
# Find all deletions
grep "Deleted:" ~/Library/Caches/desktop-cleanup.log

# Find all errors
grep "ERROR" ~/Library/Caches/desktop-cleanup.log

# Find operations on a specific file
grep "filename.txt" ~/Library/Caches/desktop-cleanup.log
```

## 9. Best Practices Checklist

- [ ] Always run with `--dry-run` first for new scan paths
- [ ] Enable `--verbose` for important operations
- [ ] Review log files after batch deletions
- [ ] Keep trash enabled unless absolutely necessary
- [ ] Set appropriate confidence thresholds
- [ ] Add important patterns to exclusion list
- [ ] Test configuration files in dry-run mode
- [ ] Monitor disk space before and after
- [ ] Keep log files for audit purposes
- [ ] Document any permanent deletions

## 10. Emergency Recovery

If you accidentally deleted important files:

1. **Check Trash First**
   ```bash
   # macOS
   open ~/.Trash

   # Linux
   xdg-open ~/.local/share/Trash/files
   ```

2. **Check Log File**
   ```bash
   grep "Deleted:" ~/Library/Caches/desktop-cleanup.log | tail -20
   ```

3. **Use History to Undo**
   - If using the library, call `deleter.undo()`
   - Check history entries for trash paths
   - Manually move files from trash back to original location

4. **File Recovery Tools** (last resort)
   - macOS: Time Machine
   - Linux: extundelete, photorec
   - Windows: File History, Previous Versions

## Summary

The Desktop Cleanup Tool provides multiple layers of protection:

1. **Dry-Run Mode**: Test before executing
2. **Confirmation Prompts**: Explicit approval required
3. **Comprehensive Logging**: Full audit trail
4. **Trash Support**: Recoverable deletions
5. **Safety Checks**: Read-only protection, confidence thresholds
6. **Operation Cancellation**: Stop long-running operations
7. **Error Handling**: Graceful failure without data loss
8. **History Tracking**: Undo capability

Always start with dry-run, review logs, and keep trash enabled!
