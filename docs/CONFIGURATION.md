# Configuration System

The Desktop Cleanup tool provides a flexible configuration system that allows you to customize scanning behavior, define custom rules, and set exclusion patterns.

## Configuration Files

Configuration files are stored in JSON format and can be loaded via command-line or placed in the default config directory.

### Default Config Location

- **macOS**: `~/.config/desktop-cleanup/config.json`
- **Linux**: `~/.config/desktop-cleanup/config.json`
- **Windows**: `%APPDATA%\desktop-cleanup\config.json`

### Loading a Custom Config

```bash
desktop-cleanup --config /path/to/config.json
```

## Configuration Structure

### Basic Settings

```json
{
  "version": "1.0",
  "scan_paths": ["/tmp", "~/Downloads"],
  "exclude_patterns": [".git", "node_modules"],
  "min_file_size": 0,
  "max_file_age_days": 30,
  "show_hidden": false,
  "use_trash": true
}
```

- **version**: Configuration file version (for compatibility)
- **scan_paths**: Directories to scan for files
- **exclude_patterns**: Patterns to exclude from scanning
- **min_file_size**: Minimum file size in bytes (files smaller are ignored)
- **max_file_age_days**: Maximum file age threshold in days
- **show_hidden**: Include hidden files in scan
- **use_trash**: Move files to trash instead of permanent deletion

### Category Settings

Control which file categories to detect:

```json
{
  "categories": {
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

### Analyzer Settings

Configure file analysis behavior:

```json
{
  "analyzer": {
    "large_file_threshold": 104857600,
    "unused_days_threshold": 90,
    "old_download_days": 30,
    "detect_duplicates": true,
    "max_hash_size": 1073741824
  }
}
```

- **large_file_threshold**: Size threshold for "large files" (bytes)
- **unused_days_threshold**: Days of inactivity to consider a file "unused"
- **old_download_days**: Days before a download is considered "old"
- **detect_duplicates**: Enable duplicate file detection
- **max_hash_size**: Maximum file size to hash for duplicates (bytes)

## Custom Rules

Custom rules allow you to define sophisticated file matching patterns and actions.

### Rule Structure

```json
{
  "custom_rules": [
    {
      "name": "rule_identifier",
      "description": "Human-readable description",
      "type": "extension",
      "pattern": ".tmp",
      "action": "mark_safe",
      "priority": 75,
      "enabled": true,
      "category": "temporary"
    }
  ]
}
```

### Rule Types

1. **extension**: Match by file extension
   ```json
   {
     "type": "extension",
     "pattern": ".tmp"
   }
   ```

2. **name_pattern**: Match by filename pattern (supports `*` and `?` wildcards)
   ```json
   {
     "type": "name_pattern",
     "pattern": "Screenshot*.png"
   }
   ```

3. **path_pattern**: Match by path substring
   ```json
   {
     "type": "path_pattern",
     "pattern": "/node_modules/"
   }
   ```

4. **size_range**: Match by file size
   ```json
   {
     "type": "size_range",
     "pattern": "",
     "size_min": 104857600,
     "size_max": 1073741824
   }
   ```

5. **age_days**: Match by file age
   ```json
   {
     "type": "age_days",
     "pattern": "",
     "age_min": 30,
     "age_max": 90
   }
   ```

6. **directory**: Match files in specific directories
   ```json
   {
     "type": "directory",
     "pattern": "/tmp/"
   }
   ```

### Rule Actions

- **include**: Include the file in results
- **exclude**: Exclude the file from scanning
- **mark_safe**: Mark the file as safe to delete
- **mark_unsafe**: Mark the file as unsafe to delete
- **categorize**: Assign the file to a specific category
- **adjust_confidence**: Modify the confidence score

### Rule Priority

Priority determines which rule takes precedence when multiple rules match:

- **100 (highest)**: Takes precedence over all other rules
- **75 (high)**: High priority
- **50 (normal)**: Default priority
- **25 (low)**: Low priority
- **0 (lowest)**: Lowest priority

Higher priority rules are applied first.

### Advanced Rule Examples

#### Protect Source Code

```json
{
  "name": "protect_source_code",
  "description": "Never delete source code files",
  "type": "extension",
  "pattern": ".rs",
  "action": "exclude",
  "priority": 100,
  "enabled": true
}
```

#### Clean Old Screenshots

```json
{
  "name": "old_screenshots",
  "description": "Mark old screenshots as safe to delete",
  "type": "name_pattern",
  "pattern": "Screenshot*.png",
  "action": "mark_safe",
  "priority": 60,
  "enabled": true,
  "category": "old_download"
}
```

#### Large Video Files

```json
{
  "name": "large_videos",
  "description": "Flag large video files for review",
  "type": "size_range",
  "pattern": "",
  "action": "categorize",
  "priority": 60,
  "enabled": true,
  "size_min": 524288000,
  "category": "large"
}
```

#### Clean Build Directories

```json
{
  "name": "build_artifacts",
  "description": "Mark build directories as safe to clean",
  "type": "directory",
  "pattern": "/target/",
  "action": "mark_safe",
  "priority": 75,
  "enabled": true,
  "category": "dev_artifact"
}
```

## Example Configurations

See the `examples/` directory for complete configuration examples:

- **config_basic.json**: Basic configuration for general use
- **config_developer.json**: Optimized for software developers
- **config_aggressive.json**: Aggressive cleanup settings
- **rules_custom.json**: Collection of custom rules

## Best Practices

1. **Start Conservative**: Begin with basic settings and gradually add custom rules
2. **Use Dry-Run**: Always test with `--dry-run` before actual deletion
3. **High Priority for Protection**: Use high priority (90-100) for exclusion rules
4. **Categorize Properly**: Assign meaningful categories to help organize results
5. **Document Rules**: Use clear names and descriptions for your rules
6. **Test Incrementally**: Add rules one at a time and test their effects
7. **Backup Configs**: Keep copies of working configurations
8. **Version Control**: Store configs in version control for team sharing

## Configuration Validation

The tool validates configurations on load and will report errors for:

- Invalid JSON syntax
- Unknown rule types or actions
- Missing required fields
- Invalid priority values
- Circular rule dependencies

## Exporting Configuration

Save your current configuration:

```bash
desktop-cleanup --export-config ~/my-config.json
```

## Rule Debugging

Enable verbose mode to see which rules match which files:

```bash
desktop-cleanup --verbose --config my-rules.json
```

## Performance Considerations

- **Duplicate Detection**: Disable for large scans to improve speed
- **Max Hash Size**: Reduce if scanning many large files
- **Rule Complexity**: Simple rules (extension, pattern) are faster than complex ones
- **Exclusion Patterns**: Use exclusion patterns to skip directories entirely

## Migration Guide

When upgrading configuration versions, the tool will attempt to migrate automatically. Manual migration may be required for major version changes.

Current version: **1.0**
