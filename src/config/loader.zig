const std = @import("std");
const config = @import("../config.zig");
const rules = @import("rules.zig");

/// Configuration file format
pub const ConfigFormat = enum {
    json,
    // Could add TOML support in the future
    // toml,

    pub fn fromExtension(ext: []const u8) ?ConfigFormat {
        if (std.ascii.eqlIgnoreCase(ext, ".json")) return .json;
        return null;
    }

    pub fn getExtension(self: ConfigFormat) []const u8 {
        return switch (self) {
            .json => ".json",
        };
    }
};

/// Configuration file structure
pub const ConfigFile = struct {
    /// Config version for compatibility
    version: []const u8 = "1.0",
    /// Scan paths
    scan_paths: [][]const u8 = &.{},
    /// Exclusion patterns
    exclude_patterns: [][]const u8 = &.{},
    /// Minimum file size (bytes)
    min_file_size: u64 = 0,
    /// Maximum file age (days)
    max_file_age_days: u32 = 30,
    /// Show hidden files
    show_hidden: bool = false,
    /// Use trash instead of delete
    use_trash: bool = true,
    /// Category settings
    categories: CategorySettings = .{},
    /// Custom rules
    custom_rules: []RuleConfig = &.{},
    /// Analyzer settings
    analyzer: AnalyzerSettings = .{},

    pub const CategorySettings = struct {
        temp_files: bool = true,
        cache_files: bool = true,
        log_files: bool = true,
        old_downloads: bool = true,
        duplicates: bool = true,
        large_files: bool = true,
        dev_artifacts: bool = false,
        browser_data: bool = false,
    };

    pub const AnalyzerSettings = struct {
        large_file_threshold: u64 = 100 * 1024 * 1024,
        unused_days_threshold: u32 = 90,
        old_download_days: u32 = 30,
        detect_duplicates: bool = true,
        max_hash_size: u64 = 1024 * 1024 * 1024,
    };

    pub const RuleConfig = struct {
        name: []const u8,
        description: []const u8 = "",
        type: []const u8,
        pattern: []const u8 = "",
        action: []const u8 = "include",
        priority: u8 = 50,
        enabled: bool = true,
        category: ?[]const u8 = null,
        confidence_delta: ?f32 = null,
        size_min: ?u64 = null,
        size_max: ?u64 = null,
        age_min: ?u32 = null,
        age_max: ?u32 = null,
    };
};

/// Load configuration from a JSON file
pub fn loadFromJson(allocator: std.mem.Allocator, file_path: []const u8) !config.Config {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);
    const json_data = buffer[0..bytes_read];

    const parsed = try std.json.parseFromSlice(ConfigFile, allocator, json_data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return try configFromParsed(allocator, parsed.value);
}

/// Convert parsed config to runtime Config
fn configFromParsed(allocator: std.mem.Allocator, cfg_file: ConfigFile) !config.Config {
    var cfg = config.Config.init(allocator);
    errdefer cfg.deinit();

    // Copy scan paths
    for (cfg_file.scan_paths) |path| {
        try cfg.addScanPath(path);
    }

    // Copy exclude patterns
    for (cfg_file.exclude_patterns) |pattern| {
        try cfg.addExcludePattern(pattern);
    }

    // Set other fields
    cfg.min_file_size = cfg_file.min_file_size;
    cfg.max_file_age_days = cfg_file.max_file_age_days;
    cfg.show_hidden = cfg_file.show_hidden;
    cfg.use_trash = cfg_file.use_trash;

    // Set category settings
    cfg.scan_categories = .{
        .temp_files = cfg_file.categories.temp_files,
        .cache_files = cfg_file.categories.cache_files,
        .log_files = cfg_file.categories.log_files,
        .old_downloads = cfg_file.categories.old_downloads,
        .duplicates = cfg_file.categories.duplicates,
        .large_files = cfg_file.categories.large_files,
        .dev_artifacts = cfg_file.categories.dev_artifacts,
        .browser_data = cfg_file.categories.browser_data,
    };

    return cfg;
}

/// Save configuration to a JSON file
pub fn saveToJson(allocator: std.mem.Allocator, cfg: *const config.Config, file_path: []const u8) !void {
    // Build JSON string in memory first
    var json_content = std.ArrayListUnmanaged(u8){};
    defer json_content.deinit(allocator);

    const json_writer = json_content.writer(allocator);

    // Write JSON manually for compatibility
    try json_writer.writeAll("{\n");
    try json_writer.writeAll("  \"version\": \"1.0\",\n");

    // Scan paths
    try json_writer.writeAll("  \"scan_paths\": [\n");
    for (cfg.scan_paths.items, 0..) |path, i| {
        try json_writer.print("    \"{s}\"", .{path});
        if (i < cfg.scan_paths.items.len - 1) {
            try json_writer.writeAll(",\n");
        } else {
            try json_writer.writeAll("\n");
        }
    }
    try json_writer.writeAll("  ],\n");

    // Exclude patterns
    try json_writer.writeAll("  \"exclude_patterns\": [\n");
    for (cfg.exclude_patterns.items, 0..) |pattern, i| {
        try json_writer.print("    \"{s}\"", .{pattern});
        if (i < cfg.exclude_patterns.items.len - 1) {
            try json_writer.writeAll(",\n");
        } else {
            try json_writer.writeAll("\n");
        }
    }
    try json_writer.writeAll("  ],\n");

    // Other settings
    try json_writer.print("  \"min_file_size\": {d},\n", .{cfg.min_file_size});
    try json_writer.print("  \"max_file_age_days\": {d},\n", .{cfg.max_file_age_days});
    try json_writer.print("  \"show_hidden\": {s},\n", .{if (cfg.show_hidden) "true" else "false"});
    try json_writer.print("  \"use_trash\": {s},\n", .{if (cfg.use_trash) "true" else "false"});

    // Categories
    try json_writer.writeAll("  \"categories\": {\n");
    try json_writer.print("    \"temp_files\": {s},\n", .{if (cfg.scan_categories.temp_files) "true" else "false"});
    try json_writer.print("    \"cache_files\": {s},\n", .{if (cfg.scan_categories.cache_files) "true" else "false"});
    try json_writer.print("    \"log_files\": {s},\n", .{if (cfg.scan_categories.log_files) "true" else "false"});
    try json_writer.print("    \"old_downloads\": {s},\n", .{if (cfg.scan_categories.old_downloads) "true" else "false"});
    try json_writer.print("    \"duplicates\": {s},\n", .{if (cfg.scan_categories.duplicates) "true" else "false"});
    try json_writer.print("    \"large_files\": {s},\n", .{if (cfg.scan_categories.large_files) "true" else "false"});
    try json_writer.print("    \"dev_artifacts\": {s},\n", .{if (cfg.scan_categories.dev_artifacts) "true" else "false"});
    try json_writer.print("    \"browser_data\": {s}\n", .{if (cfg.scan_categories.browser_data) "true" else "false"});
    try json_writer.writeAll("  },\n");

    // Empty custom rules for now
    try json_writer.writeAll("  \"custom_rules\": []\n");
    try json_writer.writeAll("}\n");

    // Write to file
    try std.fs.cwd().writeFile(.{
        .sub_path = file_path,
        .data = json_content.items,
    });
}

/// Convert runtime Config to ConfigFile for serialization
fn configToParsed(allocator: std.mem.Allocator, cfg: *const config.Config) !ConfigFile {
    const scan_paths = try allocator.alloc([]const u8, cfg.scan_paths.items.len);
    for (cfg.scan_paths.items, 0..) |path, i| {
        scan_paths[i] = path;
    }

    const exclude_patterns = try allocator.alloc([]const u8, cfg.exclude_patterns.items.len);
    for (cfg.exclude_patterns.items, 0..) |pattern, i| {
        exclude_patterns[i] = pattern;
    }

    return ConfigFile{
        .version = "1.0",
        .scan_paths = scan_paths,
        .exclude_patterns = exclude_patterns,
        .min_file_size = cfg.min_file_size,
        .max_file_age_days = cfg.max_file_age_days,
        .show_hidden = cfg.show_hidden,
        .use_trash = cfg.use_trash,
        .categories = .{
            .temp_files = cfg.scan_categories.temp_files,
            .cache_files = cfg.scan_categories.cache_files,
            .log_files = cfg.scan_categories.log_files,
            .old_downloads = cfg.scan_categories.old_downloads,
            .duplicates = cfg.scan_categories.duplicates,
            .large_files = cfg.scan_categories.large_files,
            .dev_artifacts = cfg.scan_categories.dev_artifacts,
            .browser_data = cfg.scan_categories.browser_data,
        },
        .custom_rules = &.{},
        .analyzer = .{},
    };
}

fn freeConfigFile(allocator: std.mem.Allocator, cfg_file: ConfigFile) void {
    allocator.free(cfg_file.scan_paths);
    allocator.free(cfg_file.exclude_patterns);
}

/// Load rules from JSON configuration
pub fn loadRulesFromJson(allocator: std.mem.Allocator, file_path: []const u8) !rules.RuleSet {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);
    const json_data = buffer[0..bytes_read];

    const parsed = try std.json.parseFromSlice(ConfigFile, allocator, json_data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var rule_set = try rules.RuleSet.init(allocator, "custom");
    errdefer rule_set.deinit();

    for (parsed.value.custom_rules) |rule_cfg| {
        const rule = try parseRule(allocator, rule_cfg);
        try rule_set.addRule(rule);
    }

    return rule_set;
}

/// Parse a single rule from config
fn parseRule(allocator: std.mem.Allocator, rule_cfg: ConfigFile.RuleConfig) !rules.Rule {
    const rule_type = try parseRuleType(rule_cfg.type);
    var rule = try rules.Rule.init(allocator, rule_cfg.name, rule_type);
    errdefer rule.deinit();

    // Update description
    allocator.free(rule.description);
    rule.description = try allocator.dupe(u8, rule_cfg.description);

    // Update pattern
    allocator.free(rule.pattern);
    rule.pattern = try allocator.dupe(u8, rule_cfg.pattern);

    // Set action
    rule.action = try parseRuleAction(rule_cfg.action);

    // Set priority
    rule.priority = rules.RulePriority.fromInt(rule_cfg.priority);

    // Set enabled state
    rule.enabled = rule_cfg.enabled;

    // Set optional fields
    if (rule_cfg.category) |cat| {
        rule.category = try allocator.dupe(u8, cat);
    }
    rule.confidence_delta = rule_cfg.confidence_delta;

    // Set size range if applicable
    if (rule_cfg.size_min != null or rule_cfg.size_max != null) {
        rule.size_range = rules.SizeRange{
            .min = rule_cfg.size_min,
            .max = rule_cfg.size_max,
        };
    }

    // Set age range if applicable
    rule.min_age_days = rule_cfg.age_min;
    rule.max_age_days = rule_cfg.age_max;

    return rule;
}

fn parseRuleType(type_str: []const u8) !rules.RuleType {
    if (std.mem.eql(u8, type_str, "extension")) return .extension;
    if (std.mem.eql(u8, type_str, "name_pattern")) return .name_pattern;
    if (std.mem.eql(u8, type_str, "path_pattern")) return .path_pattern;
    if (std.mem.eql(u8, type_str, "size_range")) return .size_range;
    if (std.mem.eql(u8, type_str, "age_days")) return .age_days;
    if (std.mem.eql(u8, type_str, "mime_type")) return .mime_type;
    if (std.mem.eql(u8, type_str, "directory")) return .directory;
    if (std.mem.eql(u8, type_str, "composite")) return .composite;
    return error.InvalidRuleType;
}

fn parseRuleAction(action_str: []const u8) !rules.RuleAction {
    if (std.mem.eql(u8, action_str, "include")) return .include;
    if (std.mem.eql(u8, action_str, "exclude")) return .exclude;
    if (std.mem.eql(u8, action_str, "mark_safe")) return .mark_safe;
    if (std.mem.eql(u8, action_str, "mark_unsafe")) return .mark_unsafe;
    if (std.mem.eql(u8, action_str, "categorize")) return .categorize;
    if (std.mem.eql(u8, action_str, "adjust_confidence")) return .adjust_confidence;
    return error.InvalidRuleAction;
}

/// Get default configuration file path
pub fn getDefaultConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const platform = @import("../platform.zig");
    const paths = try platform.Paths.get(allocator);
    var mutable_paths = paths;
    defer mutable_paths.deinit(allocator);

    return try std.fs.path.join(allocator, &[_][]const u8{
        paths.config,
        "desktop-cleanup",
        "config.json",
    });
}

/// Ensure config directory exists
pub fn ensureConfigDir(allocator: std.mem.Allocator) ![]const u8 {
    const platform = @import("../platform.zig");
    const paths = try platform.Paths.get(allocator);
    var mutable_paths = paths;
    defer mutable_paths.deinit(allocator);

    const config_dir = try std.fs.path.join(allocator, &[_][]const u8{
        paths.config,
        "desktop-cleanup",
    });

    // Create directory if it doesn't exist
    std.fs.cwd().makePath(config_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    return config_dir;
}

// Tests
test "config format detection" {
    try std.testing.expect(ConfigFormat.fromExtension(".json") == .json);
    try std.testing.expect(ConfigFormat.fromExtension(".txt") == null);
}

test "rule type parsing" {
    try std.testing.expect(try parseRuleType("extension") == .extension);
    try std.testing.expect(try parseRuleType("size_range") == .size_range);
    try std.testing.expectError(error.InvalidRuleType, parseRuleType("invalid"));
}

test "rule action parsing" {
    try std.testing.expect(try parseRuleAction("include") == .include);
    try std.testing.expect(try parseRuleAction("exclude") == .exclude);
    try std.testing.expectError(error.InvalidRuleAction, parseRuleAction("invalid"));
}
