const std = @import("std");
const scanner = @import("../scanner.zig");

/// Rule type for file matching
pub const RuleType = enum {
    /// Match by file extension
    extension,
    /// Match by file name pattern (glob-like)
    name_pattern,
    /// Match by path pattern
    path_pattern,
    /// Match by file size range
    size_range,
    /// Match by file age (days)
    age_days,
    /// Match by MIME type (if detectable)
    mime_type,
    /// Match files in specific directory
    directory,
    /// Composite rule (AND/OR combination)
    composite,

    pub fn getName(self: RuleType) []const u8 {
        return switch (self) {
            .extension => "Extension",
            .name_pattern => "Name Pattern",
            .path_pattern => "Path Pattern",
            .size_range => "Size Range",
            .age_days => "File Age",
            .mime_type => "MIME Type",
            .directory => "Directory",
            .composite => "Composite",
        };
    }
};

/// Action to take when a rule matches
pub const RuleAction = enum {
    /// Include the file in results
    include,
    /// Exclude the file from results
    exclude,
    /// Mark as safe to delete
    mark_safe,
    /// Mark as unsafe to delete
    mark_unsafe,
    /// Set specific category
    categorize,
    /// Adjust confidence score
    adjust_confidence,

    pub fn getName(self: RuleAction) []const u8 {
        return switch (self) {
            .include => "Include",
            .exclude => "Exclude",
            .mark_safe => "Mark Safe",
            .mark_unsafe => "Mark Unsafe",
            .categorize => "Categorize",
            .adjust_confidence => "Adjust Confidence",
        };
    }
};

/// Operator for composite rules
pub const CompositeOperator = enum {
    and_op,
    or_op,
    not_op,

    pub fn getName(self: CompositeOperator) []const u8 {
        return switch (self) {
            .and_op => "AND",
            .or_op => "OR",
            .not_op => "NOT",
        };
    }
};

/// Rule priority level
pub const RulePriority = enum(u8) {
    lowest = 0,
    low = 25,
    normal = 50,
    high = 75,
    highest = 100,

    pub fn fromInt(value: u8) RulePriority {
        return if (value >= 100)
            .highest
        else if (value >= 75)
            .high
        else if (value >= 50)
            .normal
        else if (value >= 25)
            .low
        else
            .lowest;
    }

    pub fn toInt(self: RulePriority) u8 {
        return @intFromEnum(self);
    }
};

/// Size range for size-based rules
pub const SizeRange = struct {
    min: ?u64 = null,
    max: ?u64 = null,

    pub fn matches(self: SizeRange, size: u64) bool {
        if (self.min) |min| {
            if (size < min) return false;
        }
        if (self.max) |max| {
            if (size > max) return false;
        }
        return true;
    }
};

/// Custom file matching rule
pub const Rule = struct {
    /// Rule name/identifier
    name: []const u8,
    /// Rule description
    description: []const u8,
    /// Rule type
    rule_type: RuleType,
    /// Pattern or value (type-specific)
    pattern: []const u8,
    /// Action to take when matched
    action: RuleAction,
    /// Priority for rule application
    priority: RulePriority,
    /// Whether rule is enabled
    enabled: bool,
    /// Optional category to assign
    category: ?[]const u8,
    /// Optional confidence adjustment (-1.0 to 1.0)
    confidence_delta: ?f32,
    /// For size range rules
    size_range: ?SizeRange,
    /// For age-based rules
    min_age_days: ?u32,
    max_age_days: ?u32,
    /// For composite rules
    operator: ?CompositeOperator,
    sub_rules: ?[]Rule,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, rule_type: RuleType) !Rule {
        return Rule{
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, ""),
            .rule_type = rule_type,
            .pattern = try allocator.dupe(u8, ""),
            .action = .include,
            .priority = .normal,
            .enabled = true,
            .category = null,
            .confidence_delta = null,
            .size_range = null,
            .min_age_days = null,
            .max_age_days = null,
            .operator = null,
            .sub_rules = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Rule) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.allocator.free(self.pattern);
        if (self.category) |cat| {
            self.allocator.free(cat);
        }
        if (self.sub_rules) |rules| {
            for (rules) |*rule| {
                rule.deinit();
            }
            self.allocator.free(rules);
        }
    }

    /// Check if this rule matches a file
    pub fn matches(self: *const Rule, file: *const scanner.FileInfo) bool {
        if (!self.enabled) return false;

        return switch (self.rule_type) {
            .extension => self.matchesExtension(file),
            .name_pattern => self.matchesNamePattern(file),
            .path_pattern => self.matchesPathPattern(file),
            .size_range => self.matchesSizeRange(file),
            .age_days => self.matchesAgeDays(file),
            .directory => self.matchesDirectory(file),
            .composite => self.matchesComposite(file),
            .mime_type => false, // TODO: Implement MIME type detection
        };
    }

    fn matchesExtension(self: *const Rule, file: *const scanner.FileInfo) bool {
        if (file.extension) |ext| {
            return std.ascii.eqlIgnoreCase(ext, self.pattern);
        }
        return false;
    }

    fn matchesNamePattern(self: *const Rule, file: *const scanner.FileInfo) bool {
        const name = std.fs.path.basename(file.path);
        return matchesGlobPattern(self.pattern, name);
    }

    fn matchesPathPattern(self: *const Rule, file: *const scanner.FileInfo) bool {
        return std.mem.indexOf(u8, file.path, self.pattern) != null;
    }

    fn matchesSizeRange(self: *const Rule, file: *const scanner.FileInfo) bool {
        if (self.size_range) |range| {
            return range.matches(file.size);
        }
        return false;
    }

    fn matchesAgeDays(self: *const Rule, file: *const scanner.FileInfo) bool {
        const age = file.getAgeDays();
        if (self.min_age_days) |min| {
            if (age < min) return false;
        }
        if (self.max_age_days) |max| {
            if (age > max) return false;
        }
        return true;
    }

    fn matchesDirectory(self: *const Rule, file: *const scanner.FileInfo) bool {
        return std.mem.indexOf(u8, file.path, self.pattern) != null;
    }

    fn matchesComposite(self: *const Rule, file: *const scanner.FileInfo) bool {
        const sub_rules = self.sub_rules orelse return false;
        const op = self.operator orelse return false;

        return switch (op) {
            .and_op => blk: {
                for (sub_rules) |*rule| {
                    if (!rule.matches(file)) break :blk false;
                }
                break :blk true;
            },
            .or_op => blk: {
                for (sub_rules) |*rule| {
                    if (rule.matches(file)) break :blk true;
                }
                break :blk false;
            },
            .not_op => blk: {
                if (sub_rules.len > 0) {
                    break :blk !sub_rules[0].matches(file);
                }
                break :blk false;
            },
        };
    }

    /// Clone this rule
    pub fn clone(self: *const Rule) !Rule {
        var new_rule = try Rule.init(self.allocator, self.name, self.rule_type);
        new_rule.allocator.free(new_rule.description);
        new_rule.allocator.free(new_rule.pattern);

        new_rule.description = try self.allocator.dupe(u8, self.description);
        new_rule.pattern = try self.allocator.dupe(u8, self.pattern);
        new_rule.action = self.action;
        new_rule.priority = self.priority;
        new_rule.enabled = self.enabled;

        if (self.category) |cat| {
            new_rule.category = try self.allocator.dupe(u8, cat);
        }

        new_rule.confidence_delta = self.confidence_delta;
        new_rule.size_range = self.size_range;
        new_rule.min_age_days = self.min_age_days;
        new_rule.max_age_days = self.max_age_days;
        new_rule.operator = self.operator;

        if (self.sub_rules) |rules| {
            const new_sub_rules = try self.allocator.alloc(Rule, rules.len);
            for (rules, 0..) |*rule, i| {
                new_sub_rules[i] = try rule.clone();
            }
            new_rule.sub_rules = new_sub_rules;
        }

        return new_rule;
    }
};

/// Simple glob pattern matching (supports * and ?)
fn matchesGlobPattern(pattern: []const u8, text: []const u8) bool {
    var p_idx: usize = 0;
    var t_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (t_idx < text.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == text[t_idx] or pattern[p_idx] == '?')) {
            p_idx += 1;
            t_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            star_idx = p_idx;
            match_idx = t_idx;
            p_idx += 1;
        } else if (star_idx) |star| {
            p_idx = star + 1;
            match_idx += 1;
            t_idx = match_idx;
        } else {
            return false;
        }
    }

    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

/// Rule set for organizing multiple rules
pub const RuleSet = struct {
    name: []const u8,
    description: []const u8,
    rules: std.ArrayListUnmanaged(Rule),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !RuleSet {
        return RuleSet{
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, ""),
            .rules = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RuleSet) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        for (self.rules.items) |*rule| {
            rule.deinit();
        }
        self.rules.deinit(self.allocator);
    }

    pub fn addRule(self: *RuleSet, rule: Rule) !void {
        try self.rules.append(self.allocator, rule);
    }

    /// Find all matching rules for a file, sorted by priority
    pub fn findMatchingRules(self: *const RuleSet, file: *const scanner.FileInfo, allocator: std.mem.Allocator) ![]const *const Rule {
        var matches = std.ArrayList(*const Rule){};
        defer matches.deinit(allocator);

        for (self.rules.items) |*rule| {
            if (rule.matches(file)) {
                try matches.append(allocator, rule);
            }
        }

        // Sort by priority (highest first)
        const sorted = try allocator.alloc(*const Rule, matches.items.len);
        @memcpy(sorted, matches.items);

        std.mem.sort(*const Rule, sorted, {}, struct {
            fn lessThan(_: void, a: *const Rule, b: *const Rule) bool {
                return a.priority.toInt() > b.priority.toInt();
            }
        }.lessThan);

        return sorted;
    }
};

// Tests
test "rule matching - extension" {
    const allocator = std.testing.allocator;
    const platform = @import("../platform.zig");

    var rule = try Rule.init(allocator, "tmp_files", .extension);
    defer rule.deinit();

    rule.allocator.free(rule.pattern);
    rule.pattern = try allocator.dupe(u8, ".tmp");

    const file = scanner.FileInfo{
        .path = "/test/file.tmp",
        .name = "file.tmp",
        .size = 100,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
        .is_dir = false,
        .is_symlink = false,
        .is_hidden = false,
        .is_readonly = false,
        .is_executable = false,
        .extension = ".tmp",
        .mode = 0o644,
        .inode = 1,
        .attributes = platform.FileAttributes{},
    };

    try std.testing.expect(rule.matches(&file));
}

test "rule matching - size range" {
    const allocator = std.testing.allocator;
    const platform = @import("../platform.zig");

    var rule = try Rule.init(allocator, "large_files", .size_range);
    defer rule.deinit();

    rule.size_range = SizeRange{
        .min = 100 * 1024 * 1024, // 100MB
        .max = null,
    };

    const large_file = scanner.FileInfo{
        .path = "/test/large.bin",
        .name = "large.bin",
        .size = 200 * 1024 * 1024,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
        .is_dir = false,
        .is_symlink = false,
        .is_hidden = false,
        .is_readonly = false,
        .is_executable = false,
        .extension = ".bin",
        .mode = 0o644,
        .inode = 1,
        .attributes = platform.FileAttributes{},
    };

    try std.testing.expect(rule.matches(&large_file));
}

test "glob pattern matching" {
    try std.testing.expect(matchesGlobPattern("*.txt", "file.txt"));
    try std.testing.expect(matchesGlobPattern("test_*.log", "test_123.log"));
    try std.testing.expect(matchesGlobPattern("file?.txt", "file1.txt"));
    try std.testing.expect(!matchesGlobPattern("*.txt", "file.log"));
    try std.testing.expect(matchesGlobPattern("*", "anything"));
}

test "rule priority" {
    try std.testing.expect(RulePriority.highest.toInt() == 100);
    try std.testing.expect(RulePriority.normal.toInt() == 50);
    try std.testing.expect(RulePriority.fromInt(80) == .high);
}
