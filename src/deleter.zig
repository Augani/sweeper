const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");
const trash = @import("trash.zig");
const history = @import("history.zig");
const scanner = @import("scanner.zig");
const analyzer = @import("analyzer.zig");
const logger = @import("logger.zig");
const confirm = @import("confirm.zig");

/// Result of a deletion operation
pub const DeleteResult = struct {
    /// Whether the operation succeeded
    success: bool,
    /// Path of the deleted file
    path: []const u8,
    /// Where the file was moved (if moved to trash)
    trash_path: ?[]const u8,
    /// Error message if failed
    error_message: ?[]const u8,
    /// Size of the deleted file
    bytes_freed: u64,
    /// History entry ID for undo
    history_id: ?u64,

    pub fn deinit(self: *DeleteResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.trash_path) |p| allocator.free(p);
        if (self.error_message) |m| allocator.free(m);
    }
};

/// Statistics from batch deletion
pub const DeleteStats = struct {
    /// Total files processed
    total_processed: u64 = 0,
    /// Successfully deleted files
    successful: u64 = 0,
    /// Failed deletions
    failed: u64 = 0,
    /// Total bytes freed
    bytes_freed: u64 = 0,
    /// Files moved to trash
    moved_to_trash: u64 = 0,
    /// Files permanently deleted
    permanently_deleted: u64 = 0,

    pub fn format(self: DeleteStats, allocator: std.mem.Allocator) ![]u8 {
        const freed_str = try platform.formatSize(allocator, self.bytes_freed);
        defer allocator.free(freed_str);

        return try std.fmt.allocPrint(allocator,
            \\Deletion Results:
            \\  Total processed: {d}
            \\  Successful: {d}
            \\  Failed: {d}
            \\  Bytes freed: {s}
            \\  Moved to trash: {d}
            \\  Permanently deleted: {d}
        , .{
            self.total_processed,
            self.successful,
            self.failed,
            freed_str,
            self.moved_to_trash,
            self.permanently_deleted,
        });
    }
};

/// Options for deletion operations
pub const DeleteOptions = struct {
    /// Use trash instead of permanent delete
    use_trash: bool = true,
    /// Dry run mode (don't actually delete)
    dry_run: bool = false,
    /// Skip read-only files
    skip_readonly: bool = true,
    /// Skip files that are open/in use
    skip_in_use: bool = true,
    /// Force deletion even if errors occur
    force: bool = false,
    /// Delete directories recursively
    recursive: bool = true,
    /// Minimum confidence score to delete (for analyzer results)
    min_confidence: f32 = 0.0,
    /// Only delete files marked as safe
    safe_only: bool = true,
    /// Require confirmation before deletion
    require_confirmation: bool = true,
    /// Enable verbose logging
    verbose_logging: bool = true,
    /// Logger instance (optional)
    logger_instance: ?*logger.Logger = null,
};

/// Callback type for deletion progress
pub const DeleteProgressCallback = *const fn (progress: *const DeleteProgress, context: ?*anyopaque) void;

/// Progress information during deletion
pub const DeleteProgress = struct {
    /// Current file being processed
    current_path: []const u8,
    /// Files processed so far
    files_processed: u64,
    /// Total files to process
    total_files: u64,
    /// Bytes freed so far
    bytes_freed: u64,
    /// Whether operation is complete
    is_complete: bool,

    pub fn percentComplete(self: DeleteProgress) f32 {
        if (self.total_files == 0) return 100.0;
        return @as(f32, @floatFromInt(self.files_processed)) / @as(f32, @floatFromInt(self.total_files)) * 100.0;
    }
};

/// Safe file deleter with trash support and undo capability
pub const Deleter = struct {
    allocator: std.mem.Allocator,
    trash_manager: trash.TrashManager,
    history_manager: history.HistoryManager,
    options: DeleteOptions,
    stats: DeleteStats,
    progress_callback: ?DeleteProgressCallback,
    progress_context: ?*anyopaque,
    should_stop: bool,

    pub fn init(allocator: std.mem.Allocator, options: DeleteOptions) !Deleter {
        return Deleter{
            .allocator = allocator,
            .trash_manager = try trash.TrashManager.init(allocator),
            .history_manager = history.HistoryManager.init(allocator),
            .options = options,
            .stats = .{},
            .progress_callback = null,
            .progress_context = null,
            .should_stop = false,
        };
    }

    pub fn deinit(self: *Deleter) void {
        self.trash_manager.deinit();
        self.history_manager.deinit();
    }

    /// Set progress callback
    pub fn setProgressCallback(self: *Deleter, callback: DeleteProgressCallback, context: ?*anyopaque) void {
        self.progress_callback = callback;
        self.progress_context = context;
    }

    /// Cancel ongoing operation
    pub fn cancel(self: *Deleter) void {
        self.should_stop = true;
    }

    /// Reset cancellation flag
    pub fn reset(self: *Deleter) void {
        self.should_stop = false;
    }

    /// Delete a single file
    pub fn deleteFile(self: *Deleter, path: []const u8) !DeleteResult {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        // Get file info for size first
        const stat = std.fs.cwd().statFile(path) catch |err| {
            if (self.options.logger_instance) |log| {
                log.logCat(.err, "delete", "Failed to stat file {s}: {}", .{ path, err });
            }
            const err_msg = try self.allocator.dupe(u8, @errorName(err));
            return DeleteResult{
                .success = false,
                .path = owned_path,
                .trash_path = null,
                .error_message = err_msg,
                .bytes_freed = 0,
                .history_id = null,
            };
        };

        const file_size = stat.size;

        // Dry run check
        if (self.options.dry_run) {
            if (self.options.logger_instance) |log| {
                const size_str = try platform.formatSize(self.allocator, file_size);
                defer self.allocator.free(size_str);
                log.logCat(.info, "dry-run", "[DRY-RUN] Would delete: {s} ({s})", .{ path, size_str });
            }
            return DeleteResult{
                .success = true,
                .path = owned_path,
                .trash_path = null,
                .error_message = try self.allocator.dupe(u8, "[dry-run]"),
                .bytes_freed = file_size,
                .history_id = null,
            };
        }

        // Confirmation check
        if (self.options.require_confirmation) {
            const confirmed = confirm.confirmDelete(
                self.allocator,
                path,
                file_size,
                !self.options.use_trash,
            ) catch false;

            if (!confirmed) {
                if (self.options.logger_instance) |log| {
                    log.logCat(.info, "delete", "Deletion cancelled by user: {s}", .{path});
                }
                return DeleteResult{
                    .success = false,
                    .path = owned_path,
                    .trash_path = null,
                    .error_message = try self.allocator.dupe(u8, "Cancelled by user"),
                    .bytes_freed = 0,
                    .history_id = null,
                };
            }
        }

        // Check if read-only and skip if configured
        if (self.options.skip_readonly) {
            const attrs = platform.FileAttributes.fromStat(stat, std.fs.path.basename(path));
            if (attrs.is_readonly) {
                if (self.options.logger_instance) |log| {
                    log.logCat(.warning, "delete", "Skipping read-only file: {s}", .{path});
                }
                return DeleteResult{
                    .success = false,
                    .path = owned_path,
                    .trash_path = null,
                    .error_message = try self.allocator.dupe(u8, "File is read-only"),
                    .bytes_freed = 0,
                    .history_id = null,
                };
            }
        }

        // Determine deletion method
        if (self.options.use_trash) {
            return self.moveToTrash(owned_path, file_size);
        } else {
            return self.permanentDelete(owned_path, file_size);
        }
    }

    /// Move file to trash
    fn moveToTrash(self: *Deleter, path: []const u8, file_size: u64) !DeleteResult {
        var trash_result = try self.trash_manager.trash(path);
        defer {
            if (!trash_result.success) {
                if (trash_result.trash_path) |p| self.allocator.free(p);
                if (trash_result.error_message) |m| self.allocator.free(m);
            }
        }

        if (!trash_result.success) {
            return DeleteResult{
                .success = false,
                .path = path,
                .trash_path = null,
                .error_message = if (trash_result.error_message) |m|
                    try self.allocator.dupe(u8, m)
                else
                    null,
                .bytes_freed = 0,
                .history_id = null,
            };
        }

        // Record in history
        const history_id = try self.history_manager.record(
            .delete_to_trash,
            path,
            trash_result.trash_path,
            file_size,
        );

        // Update stats
        self.stats.successful += 1;
        self.stats.bytes_freed += file_size;
        self.stats.moved_to_trash += 1;

        // Transfer ownership of trash_path
        const result_trash_path = trash_result.trash_path;
        trash_result.trash_path = null;

        return DeleteResult{
            .success = true,
            .path = path,
            .trash_path = result_trash_path,
            .error_message = null,
            .bytes_freed = file_size,
            .history_id = history_id,
        };
    }

    /// Permanently delete file
    fn permanentDelete(self: *Deleter, path: []const u8, file_size: u64) !DeleteResult {
        // Get file info to check if directory
        const stat = std.fs.cwd().statFile(path) catch |err| {
            return DeleteResult{
                .success = false,
                .path = path,
                .trash_path = null,
                .error_message = try self.allocator.dupe(u8, @errorName(err)),
                .bytes_freed = 0,
                .history_id = null,
            };
        };

        // Delete based on type
        if (stat.kind == .directory) {
            if (self.options.recursive) {
                std.fs.deleteTreeAbsolute(path) catch |err| {
                    return DeleteResult{
                        .success = false,
                        .path = path,
                        .trash_path = null,
                        .error_message = try self.allocator.dupe(u8, @errorName(err)),
                        .bytes_freed = 0,
                        .history_id = null,
                    };
                };
            } else {
                return DeleteResult{
                    .success = false,
                    .path = path,
                    .trash_path = null,
                    .error_message = try self.allocator.dupe(u8, "Directory deletion requires recursive option"),
                    .bytes_freed = 0,
                    .history_id = null,
                };
            }
        } else {
            std.fs.deleteFileAbsolute(path) catch |err| {
                return DeleteResult{
                    .success = false,
                    .path = path,
                    .trash_path = null,
                    .error_message = try self.allocator.dupe(u8, @errorName(err)),
                    .bytes_freed = 0,
                    .history_id = null,
                };
            };
        }

        // Record in history (can't undo permanent delete, but track it)
        const history_id = try self.history_manager.record(
            .permanent_delete,
            path,
            null,
            file_size,
        );

        // Update stats
        self.stats.successful += 1;
        self.stats.bytes_freed += file_size;
        self.stats.permanently_deleted += 1;

        return DeleteResult{
            .success = true,
            .path = path,
            .trash_path = null,
            .error_message = null,
            .bytes_freed = file_size,
            .history_id = history_id,
        };
    }

    /// Delete multiple files
    pub fn deleteFiles(self: *Deleter, paths: []const []const u8) ![]DeleteResult {
        var results = try self.allocator.alloc(DeleteResult, paths.len);
        errdefer self.allocator.free(results);

        // Calculate total size for batch confirmation
        var total_size: u64 = 0;
        for (paths) |path| {
            const stat = std.fs.cwd().statFile(path) catch continue;
            total_size += stat.size;
        }

        // Batch confirmation if required and not in dry-run
        if (self.options.require_confirmation and !self.options.dry_run and paths.len > 1) {
            const confirmed = confirm.confirmBatchDelete(
                self.allocator,
                paths.len,
                total_size,
                !self.options.use_trash,
            ) catch false;

            if (!confirmed) {
                if (self.options.logger_instance) |log| {
                    log.logCat(.info, "delete", "Batch deletion cancelled by user ({d} files)", .{paths.len});
                }
                // Mark all as cancelled
                for (paths, 0..) |path, i| {
                    results[i] = DeleteResult{
                        .success = false,
                        .path = try self.allocator.dupe(u8, path),
                        .trash_path = null,
                        .error_message = try self.allocator.dupe(u8, "Cancelled by user"),
                        .bytes_freed = 0,
                        .history_id = null,
                    };
                }
                return results;
            }
        }

        if (self.options.logger_instance) |log| {
            const size_str = try platform.formatSize(self.allocator, total_size);
            defer self.allocator.free(size_str);
            log.logCat(.info, "delete", "Starting batch deletion: {d} files ({s})", .{ paths.len, size_str });
        }

        self.stats.total_processed = 0;
        self.should_stop = false;

        for (paths, 0..) |path, i| {
            if (self.should_stop) {
                // Mark remaining as cancelled
                for (i..paths.len) |j| {
                    results[j] = DeleteResult{
                        .success = false,
                        .path = try self.allocator.dupe(u8, paths[j]),
                        .trash_path = null,
                        .error_message = try self.allocator.dupe(u8, "Cancelled"),
                        .bytes_freed = 0,
                        .history_id = null,
                    };
                }
                break;
            }

            // Skip confirmation for individual files in batch mode
            const saved_confirmation = self.options.require_confirmation;
            if (paths.len > 1) {
                self.options.require_confirmation = false;
            }

            results[i] = try self.deleteFile(path);
            self.stats.total_processed += 1;

            // Restore confirmation setting
            self.options.require_confirmation = saved_confirmation;

            // Log result
            if (self.options.verbose_logging and self.options.logger_instance != null) {
                const log = self.options.logger_instance.?;
                if (results[i].success) {
                    const size_str = try platform.formatSize(self.allocator, results[i].bytes_freed);
                    defer self.allocator.free(size_str);
                    log.logCat(.info, "delete", "Deleted: {s} ({s})", .{ path, size_str });
                } else {
                    const err_msg = results[i].error_message orelse "Unknown error";
                    log.logCat(.err, "delete", "Failed to delete {s}: {s}", .{ path, err_msg });
                }
            }

            // Send progress update
            self.sendProgress(path, i + 1, paths.len, false);
        }

        // Send final progress
        self.sendProgress("", paths.len, paths.len, true);

        // Log final statistics
        if (self.options.logger_instance) |log| {
            const freed_str = try platform.formatSize(self.allocator, self.stats.bytes_freed);
            defer self.allocator.free(freed_str);
            log.logCat(.info, "delete", "Batch deletion complete: {d} succeeded, {d} failed, {s} freed", .{
                self.stats.successful,
                self.stats.failed,
                freed_str,
            });
        }

        return results;
    }

    /// Delete analyzer results based on category
    pub fn deleteAnalyzerResults(
        self: *Deleter,
        results: []const analyzer.AnalysisResult,
        category: ?analyzer.FileCategory,
    ) ![]DeleteResult {
        // Count matching files
        var count: usize = 0;
        for (results) |result| {
            if (self.shouldDelete(result, category)) {
                count += 1;
            }
        }

        if (count == 0) {
            return try self.allocator.alloc(DeleteResult, 0);
        }

        var delete_results = try self.allocator.alloc(DeleteResult, count);
        errdefer self.allocator.free(delete_results);

        var idx: usize = 0;
        self.stats.total_processed = 0;
        self.should_stop = false;

        for (results) |result| {
            if (self.should_stop) break;

            if (self.shouldDelete(result, category)) {
                delete_results[idx] = try self.deleteFile(result.file.path);
                self.stats.total_processed += 1;
                idx += 1;

                // Send progress update
                self.sendProgress(result.file.path, idx, count, false);
            }
        }

        // Resize if we stopped early
        if (idx < count) {
            delete_results = self.allocator.realloc(delete_results, idx) catch delete_results;
        }

        // Send final progress
        self.sendProgress("", idx, count, true);

        return delete_results;
    }

    /// Check if an analyzer result should be deleted
    fn shouldDelete(self: *Deleter, result: analyzer.AnalysisResult, category: ?analyzer.FileCategory) bool {
        // Check category match
        if (category) |cat| {
            if (!result.hasCategory(cat)) {
                return false;
            }
        }

        // Check confidence threshold
        if (result.confidence < self.options.min_confidence) {
            return false;
        }

        // Check safe_only option
        if (self.options.safe_only and !result.safe_to_delete) {
            return false;
        }

        return true;
    }

    /// Send progress update
    fn sendProgress(self: *Deleter, path: []const u8, processed: usize, total: usize, complete: bool) void {
        if (self.progress_callback) |cb| {
            const progress = DeleteProgress{
                .current_path = path,
                .files_processed = processed,
                .total_files = total,
                .bytes_freed = self.stats.bytes_freed,
                .is_complete = complete,
            };
            cb(&progress, self.progress_context);
        }
    }

    /// Undo the last operation
    pub fn undo(self: *Deleter) !?DeleteResult {
        const entry = self.history_manager.getLastUndoable() orelse return null;

        // Can only undo trash operations
        if (entry.operation != .delete_to_trash) {
            return null;
        }

        const trash_path = entry.new_path orelse return null;
        const original_path = entry.original_path;

        // Attempt restore
        const success = try self.trash_manager.restore(trash_path, original_path);

        if (success) {
            // Mark as undone in history
            _ = self.history_manager.markUndone(entry.id);

            return DeleteResult{
                .success = true,
                .path = try self.allocator.dupe(u8, original_path),
                .trash_path = try self.allocator.dupe(u8, trash_path),
                .error_message = null,
                .bytes_freed = 0,
                .history_id = entry.id,
            };
        } else {
            return DeleteResult{
                .success = false,
                .path = try self.allocator.dupe(u8, original_path),
                .trash_path = null,
                .error_message = try self.allocator.dupe(u8, "Failed to restore file"),
                .bytes_freed = 0,
                .history_id = entry.id,
            };
        }
    }

    /// Undo a specific operation by ID
    pub fn undoById(self: *Deleter, id: u64) !?DeleteResult {
        const entry = self.history_manager.getEntry(id) orelse return null;

        if (entry.undone or entry.operation != .delete_to_trash) {
            return null;
        }

        const trash_path = entry.new_path orelse return null;
        const original_path = entry.original_path;

        const success = try self.trash_manager.restore(trash_path, original_path);

        if (success) {
            _ = self.history_manager.markUndone(entry.id);

            return DeleteResult{
                .success = true,
                .path = try self.allocator.dupe(u8, original_path),
                .trash_path = try self.allocator.dupe(u8, trash_path),
                .error_message = null,
                .bytes_freed = 0,
                .history_id = id,
            };
        } else {
            return DeleteResult{
                .success = false,
                .path = try self.allocator.dupe(u8, original_path),
                .trash_path = null,
                .error_message = try self.allocator.dupe(u8, "Failed to restore file"),
                .bytes_freed = 0,
                .history_id = id,
            };
        }
    }

    /// Get deletion statistics
    pub fn getStats(self: *Deleter) DeleteStats {
        return self.stats;
    }

    /// Reset statistics
    pub fn resetStats(self: *Deleter) void {
        self.stats = .{};
    }

    /// Get history manager for access to history
    pub fn getHistory(self: *Deleter) *history.HistoryManager {
        return &self.history_manager;
    }

    /// Get trash manager for direct trash operations
    pub fn getTrash(self: *Deleter) *trash.TrashManager {
        return &self.trash_manager;
    }

    /// Empty trash
    pub fn emptyTrash(self: *Deleter) !u64 {
        return try self.trash_manager.emptyTrash();
    }

    /// Get trash size
    pub fn getTrashSize(self: *Deleter) !u64 {
        return try self.trash_manager.getTrashSize();
    }
};

/// Preview what would be deleted without actually deleting
pub fn previewDelete(
    allocator: std.mem.Allocator,
    results: []const analyzer.AnalysisResult,
    category: ?analyzer.FileCategory,
    options: DeleteOptions,
) !PreviewResult {
    var total_size: u64 = 0;
    var count: u64 = 0;

    for (results) |result| {
        // Check category
        if (category) |cat| {
            if (!result.hasCategory(cat)) continue;
        }

        // Check confidence
        if (result.confidence < options.min_confidence) continue;

        // Check safe_only
        if (options.safe_only and !result.safe_to_delete) continue;

        total_size += result.file.size;
        count += 1;
    }

    return PreviewResult{
        .file_count = count,
        .total_size = total_size,
        .size_string = try platform.formatSize(allocator, total_size),
    };
}

/// Result of preview operation
pub const PreviewResult = struct {
    file_count: u64,
    total_size: u64,
    size_string: []u8,

    pub fn deinit(self: *PreviewResult, allocator: std.mem.Allocator) void {
        allocator.free(self.size_string);
    }
};

// Tests
test "deleter initialization" {
    const allocator = std.testing.allocator;
    var deleter = try Deleter.init(allocator, .{});
    defer deleter.deinit();

    try std.testing.expect(deleter.stats.total_processed == 0);
}

test "delete options defaults" {
    const options = DeleteOptions{};
    try std.testing.expect(options.use_trash);
    try std.testing.expect(!options.dry_run);
    try std.testing.expect(options.skip_readonly);
}

test "delete stats format" {
    const allocator = std.testing.allocator;
    var stats = DeleteStats{
        .total_processed = 10,
        .successful = 8,
        .failed = 2,
        .bytes_freed = 1024 * 1024,
        .moved_to_trash = 6,
        .permanently_deleted = 2,
    };

    const formatted = try stats.format(allocator);
    defer allocator.free(formatted);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "Total processed: 10") != null);
}

test "delete progress percent" {
    const progress = DeleteProgress{
        .current_path = "/test",
        .files_processed = 50,
        .total_files = 100,
        .bytes_freed = 0,
        .is_complete = false,
    };

    try std.testing.expectApproxEqAbs(@as(f32, 50.0), progress.percentComplete(), 0.1);
}
