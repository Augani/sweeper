# Custom Rules Guide

This guide explains how to create and use custom rules to tailor the Desktop Cleanup tool to your specific needs.

## What are Custom Rules?

Custom rules allow you to define sophisticated file matching patterns and specify what actions should be taken when files match those patterns. They provide fine-grained control over which files are identified for cleanup, excluded from scanning, or marked as safe/unsafe to delete.

## Basic Rule Anatomy

Every rule has these key components:

```json
{
  "name": "unique_identifier",
  "description": "Human-readable explanation",
  "type": "rule_type_here",
  "pattern": "pattern_to_match",
  "action": "what_to_do",
  "priority": 50,
  "enabled": true
}
```

## Rule Types Explained

### 1. Extension Rules

Match files by their extension:

```json
{
  "name": "temp_files",
  "description": "Temporary files with .tmp extension",
  "type": "extension",
  "pattern": ".tmp",
  "action": "mark_safe",
  "priority": 75,
  "enabled": true
}
```

**Use cases:**
- Identify specific file types (images, videos, documents)
- Protect source code files
- Target temporary or backup files

### 2. Name Pattern Rules

Match files using wildcards (* and ?):

```json
{
  "name": "screenshots",
  "description": "Screenshot files",
  "type": "name_pattern",
  "pattern": "Screenshot*.png",
  "action": "categorize",
  "priority": 60,
  "enabled": true,
  "category": "old_download"
}
```

**Wildcards:**
- `*` matches any number of characters
- `?` matches exactly one character

**Examples:**
- `Screenshot*.png` → Screenshot 2024-01-01.png
- `backup_???.txt` → backup_001.txt, backup_999.txt
- `*.log.*` → app.log.1, system.log.2

### 3. Path Pattern Rules

Match files by path substring:

```json
{
  "name": "node_modules",
  "description": "Files in node_modules directories",
  "type": "path_pattern",
  "pattern": "/node_modules/",
  "action": "mark_safe",
  "priority": 75,
  "enabled": true
}
```

**Use cases:**
- Target files in specific directories
- Match files across multiple locations
- Identify build or cache directories

### 4. Size Range Rules

Match files by size:

```json
{
  "name": "large_videos",
  "description": "Very large files over 500MB",
  "type": "size_range",
  "pattern": "",
  "action": "categorize",
  "priority": 60,
  "enabled": true,
  "size_min": 524288000,
  "category": "large"
}
```

**Size units:**
- 1 KB = 1024 bytes
- 1 MB = 1048576 bytes
- 1 GB = 1073741824 bytes

**Examples:**
- `size_min: 104857600` (100 MB minimum)
- `size_max: 1073741824` (1 GB maximum)
- Both can be used together for ranges

### 5. Age-Based Rules

Match files by how long since they were last accessed:

```json
{
  "name": "old_temp_files",
  "description": "Temporary files older than 7 days",
  "type": "age_days",
  "pattern": "",
  "action": "mark_safe",
  "priority": 70,
  "enabled": true,
  "age_min": 7
}
```

**Age parameters:**
- `age_min`: Minimum age in days
- `age_max`: Maximum age in days

### 6. Directory Rules

Match files within specific directories:

```json
{
  "name": "build_dirs",
  "description": "Files in build directories",
  "type": "directory",
  "pattern": "/build/",
  "action": "mark_safe",
  "priority": 75,
  "enabled": true,
  "category": "dev_artifact"
}
```

## Rule Actions

### include
Add matching files to results for review.

```json
{
  "action": "include"
}
```

### exclude
Completely skip matching files during scanning.

```json
{
  "action": "exclude",
  "priority": 100  // High priority to ensure it runs first
}
```

**Best for:**
- Protecting important files
- Skipping system directories
- Excluding large directories from scan

### mark_safe
Mark matching files as safe to delete.

```json
{
  "action": "mark_safe"
}
```

**Best for:**
- Temporary files
- Cache files
- Build artifacts
- Old downloads

### mark_unsafe
Mark matching files as unsafe to delete (requires user confirmation).

```json
{
  "action": "mark_unsafe",
  "priority": 90  // High priority to override other rules
}
```

**Best for:**
- Important documents
- Source code
- Configuration files
- Personal data

### categorize
Assign files to a specific category.

```json
{
  "action": "categorize",
  "category": "large"
}
```

**Available categories:**
- `temporary`
- `cache`
- `log`
- `duplicate`
- `large`
- `unused`
- `old_download`
- `dev_artifact`
- `browser_data`

### adjust_confidence
Modify the confidence score for cleanup recommendation.

```json
{
  "action": "adjust_confidence",
  "confidence_delta": 0.2  // Increase confidence by 20%
}
```

**Range:** -1.0 to 1.0
- Positive values increase confidence
- Negative values decrease confidence

## Priority System

Priority determines the order in which rules are evaluated:

- **100 (highest)**: Critical exclusions, must-protect files
- **75-90 (high)**: Important rules that should run early
- **50 (normal)**: Standard rules
- **25-40 (low)**: Lower priority categorization
- **0 (lowest)**: Fallback rules

**Best practices:**
1. Use priority 90-100 for exclusion rules
2. Use priority 70-85 for safety-critical rules
3. Use priority 50-65 for categorization
4. Use priority 25-40 for informational rules

## Practical Examples

### Protect All Source Code

```json
[
  {
    "name": "protect_rust",
    "description": "Never delete Rust source files",
    "type": "extension",
    "pattern": ".rs",
    "action": "exclude",
    "priority": 100,
    "enabled": true
  },
  {
    "name": "protect_zig",
    "description": "Never delete Zig source files",
    "type": "extension",
    "pattern": ".zig",
    "action": "exclude",
    "priority": 100,
    "enabled": true
  }
]
```

### Clean Old Screenshots

```json
{
  "name": "old_screenshots",
  "description": "Screenshots older than 30 days",
  "type": "name_pattern",
  "pattern": "Screenshot*.png",
  "action": "mark_safe",
  "priority": 60,
  "enabled": true,
  "age_min": 30,
  "category": "old_download"
}
```

### Target Large Video Files

```json
{
  "name": "large_videos",
  "description": "Video files larger than 1GB",
  "type": "size_range",
  "pattern": "",
  "action": "categorize",
  "priority": 55,
  "enabled": true,
  "size_min": 1073741824,
  "category": "large"
}
```

### Clean Development Caches

```json
[
  {
    "name": "npm_cache",
    "description": "NPM package cache",
    "type": "directory",
    "pattern": "/.npm/",
    "action": "mark_safe",
    "priority": 75,
    "enabled": true,
    "category": "cache"
  },
  {
    "name": "cargo_cache",
    "description": "Rust Cargo cache",
    "type": "directory",
    "pattern": "/.cargo/registry/",
    "action": "mark_safe",
    "priority": 75,
    "enabled": true,
    "category": "cache"
  }
]
```

### Protect Important Documents

```json
[
  {
    "name": "protect_pdfs",
    "description": "Never auto-delete PDF documents",
    "type": "extension",
    "pattern": ".pdf",
    "action": "mark_unsafe",
    "priority": 90,
    "enabled": true
  },
  {
    "name": "protect_docs",
    "description": "Never auto-delete office documents",
    "type": "extension",
    "pattern": ".docx",
    "action": "mark_unsafe",
    "priority": 90,
    "enabled": true
  }
]
```

## Testing Your Rules

1. **Start with dry-run mode:**
   ```bash
   desktop-cleanup --dry-run --config my-rules.json
   ```

2. **Use verbose mode to see matching:**
   ```bash
   desktop-cleanup --verbose --config my-rules.json
   ```

3. **Test one rule at a time:**
   - Enable only one rule initially
   - Verify it matches the expected files
   - Add more rules incrementally

4. **Check priority ordering:**
   - Ensure high-priority rules run first
   - Verify exclusions happen before categorization

## Common Patterns

### Workflow for Creating Rules

1. Identify the problem (e.g., "too many old screenshots")
2. Choose the right rule type (name_pattern for screenshots)
3. Write the pattern (Screenshot*.png)
4. Choose appropriate action (mark_safe)
5. Set priority (60 for cleanup, 90 for protection)
6. Test with dry-run
7. Refine and deploy

### Combining Multiple Rules

Rules can work together. For example:

```json
[
  {
    "name": "large_files",
    "type": "size_range",
    "size_min": 524288000,
    "action": "categorize",
    "category": "large",
    "priority": 50
  },
  {
    "name": "old_large_files",
    "type": "age_days",
    "age_min": 90,
    "action": "mark_safe",
    "priority": 65
  }
]
```

This identifies large files AND marks old ones as safe to delete.

## Troubleshooting

### Rule Not Matching

1. Check the pattern syntax
2. Verify the file actually matches the pattern
3. Test with a simple pattern first
4. Use verbose mode to see why files don't match

### Wrong Files Being Matched

1. Make pattern more specific
2. Add additional constraints (size, age)
3. Use higher priority exclusion rules
4. Test with a subset of files first

### Rules Conflicting

1. Check priority levels
2. Ensure exclusions have highest priority
3. Use more specific patterns
4. Review rule order in config file

## Best Practices

1. **Always test with --dry-run first**
2. **Use high priority (90+) for protection rules**
3. **Document your rules with clear descriptions**
4. **Start conservative, then refine**
5. **Keep rules simple and specific**
6. **Use meaningful rule names**
7. **Version control your configuration files**
8. **Review rules periodically**

## Advanced Tips

- Combine size and age rules for powerful cleanup
- Use path patterns for project-specific rules
- Create rule sets for different scenarios (work, personal, server)
- Export and share configurations with your team
- Use wildcards creatively for flexibility

## Rule Library

See `examples/rules_custom.json` for a collection of ready-to-use rules covering common scenarios.
