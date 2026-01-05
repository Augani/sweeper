# Safety Features

The Desktop Cleanup Tool includes multiple layers of safety features to prevent accidental data loss and provide transparency in all operations.

## 1. Dry-Run Mode

Test operations without making any changes to your filesystem.

### Usage
```bash
desktop-cleanup --dry-run --scan ~/Downloads
```

### Features
- Shows exactly what would be deleted
- Reports file sizes that would be freed
- Logs all operations to file
- Zero risk of data loss

### Example Output
```
[DRY-RUN] Would delete: /Users/name/Downloads/old-file.zip (45.2 MB)
[DRY-RUN] Would delete: /Users/name/Downloads/temp.txt (1.2 KB)

Total that would be deleted: 2 files, 45.2 MB
```

## 2. Confirmation Prompts

Interactive prompts before any destructive operation.

### Single File Deletion
When deleting a single file, you'll be prompted:
```
Move 'document.pdf' to trash? (5.2 MB)
[y]es, [n]o (default: no):
```

For permanent deletion (when `use_trash` is false):
```
⚠ WARNING ⚠
Permanently delete 'document.pdf'? (5.2 MB)
This cannot be undone!

/full/path/to/document.pdf
[y]es, [n]o (default: no):
```

### Batch Deletion
When deleting multiple files:
```
Move 45 files (123.4 MB) to trash?
Files will be moved to trash and can be restored later.
[y]es, [n]o (default: no):
```

### Disabling Confirmations
For automated scripts, disable confirmation prompts:
```zig
const options = deleter.DeleteOptions{
    .require_confirmation = false,
    .dry_run = true, // Recommended when disabling confirmations
};
```

## 3. Comprehensive Logging

All operations are logged to a persistent log file for audit and recovery purposes.

### Log File Location
- **macOS**: `~/Library/Caches/desktop-cleanup.log`
- **Linux**: `~/.cache/desktop-cleanup.log`
- **Windows**: `%LOCALAPPDATA%\Temp\desktop-cleanup.log`

### Log Levels
- **DEBUG**: Detailed diagnostic information
- **INFO**: General informational messages
- **WARNING**: Warning messages (e.g., skipped read-only files)
- **ERROR**: Error messages
- **CRITICAL**: Critical failures

### Example Log Entries
```
[1704556800] [INFO] Application started: Desktop Cleanup v0.1.0
[1704556801] [INFO] [scan] Scanning path: /Users/name/Downloads
[1704556802] [INFO] [dry-run] [DRY-RUN] Would delete: /path/to/file.tmp (1.2 MB)
[1704556803] [WARNING] [delete] Skipping read-only file: /path/to/protected.txt
[1704556804] [INFO] [delete] Deleted: /path/to/old.zip (45.2 MB)
[1704556805] [INFO] [delete] Batch deletion complete: 42 succeeded, 3 failed, 156.8 MB freed
```

### Controlling Logging

#### Verbose Logging
Enable debug-level logging:
```bash
desktop-cleanup --verbose --scan
```

#### Disable Logging
For temporary operations:
```bash
desktop-cleanup --no-log --scan
```

#### Programmatic Control
```zig
var logger = logger.Logger.init(allocator, .{
    .min_level = .debug,
    .log_to_file = true,
    .log_to_console = true,
    .use_color = true,
});

// Enable file logging
try logger.enableFileLogging("/path/to/custom.log");

// Log operations
logger.info("Starting cleanup operation", .{});
logger.warn("Skipping protected file: {s}", .{path});
logger.err("Failed to delete: {s}", .{path});
```

## 4. Trash/Recycle Bin Support

Files are moved to the system trash by default, allowing recovery.

### Platform Support
- **macOS**: `~/.Trash`
- **Linux**: `~/.local/share/Trash/files`
- **Windows**: `$RECYCLE.BIN`

### Undo Capability
All trash operations are tracked and can be undone:

```zig
var deleter = try deleter.Deleter.init(allocator, .{});

// Delete a file (moves to trash)
const result = try deleter.deleteFile("/path/to/file.txt");

// Undo the deletion
if (try deleter.undo()) |undo_result| {
    // File has been restored
}
```

### History Tracking
View deletion history:
```zig
const history = deleter.getHistory();
const entries = history.getRecentEntries(10);

for (entries) |entry| {
    const formatted = try entry.format(allocator);
    defer allocator.free(formatted);
    std.debug.print("{s}\n", .{formatted});
}
```

## 5. Safety Checks

Multiple safety checks protect against common mistakes:

### Read-Only Files
Read-only files are skipped by default:
```zig
const options = deleter.DeleteOptions{
    .skip_readonly = true, // Default
};
```

### Confidence Thresholds
Only delete files with sufficient confidence:
```zig
const options = deleter.DeleteOptions{
    .min_confidence = 0.8, // 80% confidence required
    .safe_only = true,     // Only delete files marked as safe
};
```

### Exclusion Patterns
Protect important files and directories:
```zig
try cfg.addExcludePattern(".git");
try cfg.addExcludePattern(".ssh");
try cfg.addExcludePattern("node_modules");
```

## 6. Operation Cancellation

Long-running operations can be safely cancelled:

```zig
var deleter = try deleter.Deleter.init(allocator, .{});

// Set up progress callback
deleter.setProgressCallback(progressCallback, context);

// In another thread or signal handler
deleter.cancel();

// The operation will stop gracefully
```

## 7. Error Handling

Errors are logged and reported without stopping the entire operation:

```zig
const results = try deleter.deleteFiles(paths);

for (results) |result| {
    if (!result.success) {
        const error_msg = result.error_message orelse "Unknown error";
        std.debug.print("Failed to delete {s}: {s}\n", .{
            result.path,
            error_msg,
        });
    }
}
```

## Best Practices

### 1. Always Test with Dry-Run First
```bash
# Test what would be deleted
desktop-cleanup --dry-run --scan ~/Downloads

# Review the output, then run for real
desktop-cleanup --scan ~/Downloads
```

### 2. Use Verbose Mode for Important Operations
```bash
desktop-cleanup --verbose --scan ~/Documents
```

### 3. Review Logs After Bulk Operations
```bash
# Check the log file
tail -100 ~/Library/Caches/desktop-cleanup.log
```

### 4. Enable Trash for Recovery
```zig
const options = deleter.DeleteOptions{
    .use_trash = true, // Always use trash unless absolutely necessary
};
```

### 5. Set Appropriate Confidence Thresholds
```zig
// Conservative: only very confident deletions
const conservative = deleter.DeleteOptions{
    .min_confidence = 0.9,
    .safe_only = true,
};

// Balanced: most files that are likely safe
const balanced = deleter.DeleteOptions{
    .min_confidence = 0.7,
    .safe_only = true,
};
```

## Configuration Example

Create a safe configuration file:

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
    "important_*"
  ],
  "dry_run": false,
  "use_trash": true,
  "verbose": true,
  "show_hidden": false,
  "min_file_size": 1048576,
  "max_file_age_days": 90
}
```

## Recovery Procedures

### Restore from Trash (macOS)
```bash
# View trash contents
ls ~/.Trash

# Restore a file manually
mv ~/.Trash/filename.txt ~/Downloads/
```

### Restore from Trash (Linux)
```bash
# View trash contents
ls ~/.local/share/Trash/files

# Restore a file
mv ~/.local/share/Trash/files/filename.txt ~/Downloads/
```

### Using History to Recover
```zig
// List recent operations
const history = deleter.getHistory();
const entries = history.getRecentEntries(20);

for (entries) |entry| {
    if (entry.operation == .delete_to_trash and !entry.undone) {
        std.debug.print("Can restore: {s} -> {s}\n", .{
            entry.original_path,
            entry.new_path orelse "unknown",
        });
    }
}

// Restore by ID
if (try deleter.undoById(entry_id)) |result| {
    std.debug.print("Restored: {s}\n", .{result.path});
}
```

## Command-Line Safety Features Summary

```bash
# Dry-run mode
--dry-run           # Show what would happen without doing it

# Logging control
--verbose           # Enable detailed logging
--no-log            # Disable file logging

# Interactive mode
--tui               # Launch safe interactive interface

# Configuration
--config FILE       # Use custom safety rules
```

## Safety Guarantees

1. **No Silent Deletions**: Every deletion is logged
2. **No Data Loss from Defaults**: Dry-run and trash are enabled by default in many contexts
3. **Transparent Operations**: Full audit trail in log files
4. **Recoverable by Default**: Trash instead of permanent delete
5. **User Confirmation**: Prompts for destructive operations
6. **Graceful Failure**: Errors don't cascade
7. **Cancellable**: Long operations can be stopped safely

## Support

If you accidentally delete files:
1. Check the trash/recycle bin first
2. Review the log file for the exact paths
3. Use the history feature to restore from trash
4. Contact support with your log file if needed
