const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");

// Re-export config submodules
pub const rules = @import("config/rules.zig");
pub const loader = @import("config/loader.zig");

/// Application configuration
pub const Config = struct {
    /// Directories to scan
    scan_paths: std.ArrayListUnmanaged([]const u8),

    /// Patterns to exclude from scanning
    exclude_patterns: std.ArrayListUnmanaged([]const u8),

    /// Minimum file size to consider (in bytes)
    min_file_size: u64 = 0,

    /// Maximum file age in days (files older than this are candidates)
    max_file_age_days: u32 = 30,

    /// Enable dry-run mode (no actual deletions)
    dry_run: bool = true,

    /// Show hidden files
    show_hidden: bool = false,

    /// Verbose output
    verbose: bool = false,

    /// Move to trash instead of permanent delete
    use_trash: bool = true,

    /// Categories to scan
    scan_categories: ScanCategories = .{},

    /// Custom rule sets
    rule_sets: std.ArrayListUnmanaged(rules.RuleSet),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .scan_paths = .{},
            .exclude_patterns = .{},
            .rule_sets = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config) void {
        for (self.scan_paths.items) |path| {
            self.allocator.free(path);
        }
        self.scan_paths.deinit(self.allocator);

        for (self.exclude_patterns.items) |pattern| {
            self.allocator.free(pattern);
        }
        self.exclude_patterns.deinit(self.allocator);

        for (self.rule_sets.items) |*rule_set| {
            rule_set.deinit();
        }
        self.rule_sets.deinit(self.allocator);
    }

    pub fn addScanPath(self: *Config, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        try self.scan_paths.append(self.allocator, owned);
    }

    pub fn addExcludePattern(self: *Config, pattern: []const u8) !void {
        const owned = try self.allocator.dupe(u8, pattern);
        try self.exclude_patterns.append(self.allocator, owned);
    }

    /// Load configuration with platform-specific defaults
    pub fn loadDefaults(self: *Config) !void {
        const paths = try platform.Paths.get(self.allocator);
        var mutable_paths = paths;
        defer mutable_paths.deinit(self.allocator);

        // Add default scan paths based on platform
        try self.addScanPath(paths.cache);
        try self.addScanPath(paths.temp);

        // Default exclude patterns
        try self.addExcludePattern(".git");
        try self.addExcludePattern(".ssh");
        try self.addExcludePattern(".gnupg");
        try self.addExcludePattern("node_modules");

        // Platform-specific excludes
        switch (platform.Platform.current()) {
            .macos => {
                try self.addExcludePattern("Library/Application Support");
                try self.addExcludePattern("Library/Preferences");
            },
            .windows => {
                try self.addExcludePattern("AppData\\Roaming");
                try self.addExcludePattern("Program Files");
            },
            .linux => {
                try self.addExcludePattern(".config");
                try self.addExcludePattern(".local/share");
            },
            .unknown => {},
        }
    }

    /// Load configuration from a file
    pub fn loadFromFile(self: *Config, file_path: []const u8) !void {
        const format = loader.ConfigFormat.fromExtension(std.fs.path.extension(file_path)) orelse {
            return error.UnsupportedConfigFormat;
        };

        const loaded = switch (format) {
            .json => try loader.loadFromJson(self.allocator, file_path),
        };

        // Transfer loaded config to self
        self.deinit();
        self.* = loaded;
    }

    /// Save configuration to a file
    pub fn saveToFile(self: *const Config, file_path: []const u8) !void {
        const format = loader.ConfigFormat.fromExtension(std.fs.path.extension(file_path)) orelse {
            return error.UnsupportedConfigFormat;
        };

        switch (format) {
            .json => try loader.saveToJson(self.allocator, self, file_path),
        }
    }

    /// Add a custom rule set
    pub fn addRuleSet(self: *Config, rule_set: rules.RuleSet) !void {
        try self.rule_sets.append(self.allocator, rule_set);
    }

    /// Load rules from a file
    pub fn loadRulesFromFile(self: *Config, file_path: []const u8) !void {
        const rule_set = try loader.loadRulesFromJson(self.allocator, file_path);
        try self.addRuleSet(rule_set);
    }

    /// Get default configuration file path
    pub fn getDefaultConfigPath(allocator: std.mem.Allocator) ![]const u8 {
        return try loader.getDefaultConfigPath(allocator);
    }

    /// Check if a file should be excluded based on custom rules
    pub fn shouldExcludeByRules(self: *const Config, file: *const @import("scanner.zig").FileInfo) bool {
        for (self.rule_sets.items) |*rule_set| {
            const matching_rules = rule_set.findMatchingRules(file, self.allocator) catch continue;
            defer self.allocator.free(matching_rules);

            for (matching_rules) |rule| {
                if (rule.action == .exclude) {
                    return true;
                }
            }
        }
        return false;
    }
};

/// Categories of files to scan
pub const ScanCategories = struct {
    /// Temporary files (.tmp, .temp, etc.)
    temp_files: bool = true,

    /// Cache files
    cache_files: bool = true,

    /// Log files
    log_files: bool = true,

    /// Old downloads
    old_downloads: bool = true,

    /// Duplicate files
    duplicates: bool = true,

    /// Large files (>100MB by default)
    large_files: bool = true,

    /// Development artifacts (node_modules, target, etc.)
    dev_artifacts: bool = false,

    /// Browser data
    browser_data: bool = false,
};

/// File patterns for different categories
pub const FilePatterns = struct {
    /// Temporary file extensions
    pub const temp_extensions = [_][]const u8{
        ".tmp",
        ".temp",
        ".bak",
        ".old",
        ".swp",
        ".swo",
        "~",
        ".crash",
        ".dmp",
        ".dump",
    };

    /// Cache directory names
    pub const cache_dirs = [_][]const u8{
        "cache",
        "Cache",
        ".cache",
        "__pycache__",
        ".pytest_cache",
        ".mypy_cache",
        "Caches",
    };

    /// Log file extensions
    pub const log_extensions = [_][]const u8{
        ".log",
        ".logs",
    };

    /// Development artifact directories
    pub const dev_artifact_dirs = [_][]const u8{
        "node_modules",
        "target",
        "build",
        "dist",
        ".gradle",
        ".maven",
        "vendor",
        "__pycache__",
        ".tox",
        "venv",
        ".venv",
        "env",
        ".next",
        ".nuxt",
        ".output",
        "coverage",
        ".nyc_output",
    };

    /// Browser cache directories by browser
    pub const browser_cache_dirs = struct {
        pub const chrome = [_][]const u8{
            "Google/Chrome/Default/Cache",
            "Google/Chrome/Default/Code Cache",
        };
        pub const firefox = [_][]const u8{
            "Mozilla/Firefox/Profiles/*/cache2",
        };
        pub const safari = [_][]const u8{
            "Safari/LocalStorage",
            "Caches/com.apple.Safari",
        };
    };

    /// macOS-specific junk files
    pub const macos_junk = [_][]const u8{
        ".DS_Store",
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd",
        ".TemporaryItems",
        ".localized",
        "._",
    };

    /// macOS-specific cache/waste directories (under ~/Library/)
    pub const macos_library_waste = [_][]const u8{
        "Caches",
        "Logs",
        "Developer/Xcode/DerivedData",
        "Developer/Xcode/Archives",
        "Developer/Xcode/iOS DeviceSupport",
        "Developer/Xcode/watchOS DeviceSupport",
        "Developer/CoreSimulator/Devices",
        "Developer/CoreSimulator/Caches",
    };

    /// Developer package manager caches
    pub const dev_cache_dirs = [_][]const u8{
        ".npm",
        ".yarn",
        ".pnpm-store",
        ".cargo",
        ".rustup",
        ".gradle",
        ".m2",
        ".ivy2",
        ".sbt",
        ".coursier",
        "go/pkg",
        ".cache/pip",
        ".cache/go-build",
        ".cache/yarn",
        ".cocoapods",
        "Library/Caches/CocoaPods",
        "Library/Caches/Homebrew",
        ".pub-cache",
        ".dartServer",
        ".android",
    };
};

test "config initialization" {
    const allocator = std.testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    try cfg.addScanPath("/tmp");
    try std.testing.expect(cfg.scan_paths.items.len == 1);
}

test "scan categories defaults" {
    const categories = ScanCategories{};
    try std.testing.expect(categories.temp_files);
    try std.testing.expect(categories.cache_files);
    try std.testing.expect(!categories.dev_artifacts);
}
