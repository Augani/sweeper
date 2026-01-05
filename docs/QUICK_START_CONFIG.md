# Configuration Quick Start

Get started with custom configurations in 5 minutes.

## 1. Export Your Current Config

```bash
desktop-cleanup --export-config my-config.json
```

This creates a base configuration file with default settings.

## 2. Edit the Configuration

Open `my-config.json` in your favorite editor:

```json
{
  "version": "1.0",
  "scan_paths": [
    "~/Downloads",
    "~/Desktop"
  ],
  "exclude_patterns": [
    ".git",
    "node_modules"
  ],
  "min_file_size": 0,
  "max_file_age_days": 30,
  "show_hidden": false,
  "use_trash": true,
  "categories": {
    "temp_files": true,
    "cache_files": true,
    "log_files": true,
    "old_downloads": true,
    "duplicates": true,
    "large_files": true,
    "dev_artifacts": false,
    "browser_data": false
  },
  "custom_rules": []
}
```

## 3. Add Custom Rules

Add rules to the `custom_rules` array:

```json
{
  "custom_rules": [
    {
      "name": "protect_pdfs",
      "description": "Never delete PDF files",
      "type": "extension",
      "pattern": ".pdf",
      "action": "exclude",
      "priority": 100,
      "enabled": true
    },
    {
      "name": "old_screenshots",
      "description": "Screenshots older than 30 days",
      "type": "name_pattern",
      "pattern": "Screenshot*.png",
      "action": "mark_safe",
      "priority": 60,
      "enabled": true
    }
  ]
}
```

## 4. Test Your Configuration

Always test with `--dry-run` first:

```bash
desktop-cleanup --config my-config.json --dry-run --scan
```

## 5. Use Your Configuration

Once tested, use it normally:

```bash
desktop-cleanup --config my-config.json --scan
```

Or with the TUI:

```bash
desktop-cleanup --config my-config.json --tui
```

## Common Configurations

### For Developers

Use the provided developer config:

```bash
desktop-cleanup --config examples/config_developer.json
```

Features:
- Protects source code files (.rs, .zig, .go, .py, etc.)
- Marks build directories as safe to delete
- Detects and manages dev artifacts
- Optimized thresholds for development work

### For Aggressive Cleanup

Use the aggressive config:

```bash
desktop-cleanup --config examples/config_aggressive.json
```

Features:
- Shorter age thresholds (7 days)
- More categories enabled
- Rules for screenshots and downloads
- Browser cache cleanup

### Basic Usage

Use the basic config:

```bash
desktop-cleanup --config examples/config_basic.json
```

Features:
- Conservative settings
- Standard categories only
- Safe defaults
- Good for first-time users

## Quick Rule Reference

### Protect Files by Extension

```json
{
  "name": "protect_source",
  "type": "extension",
  "pattern": ".rs",
  "action": "exclude",
  "priority": 100,
  "enabled": true
}
```

### Clean Old Files

```json
{
  "name": "old_temp",
  "type": "age_days",
  "pattern": "",
  "action": "mark_safe",
  "priority": 70,
  "enabled": true,
  "age_min": 30
}
```

### Target Large Files

```json
{
  "name": "large_files",
  "type": "size_range",
  "pattern": "",
  "action": "categorize",
  "priority": 60,
  "enabled": true,
  "size_min": 104857600,
  "category": "large"
}
```

### Match by Pattern

```json
{
  "name": "screenshots",
  "type": "name_pattern",
  "pattern": "Screenshot*.png",
  "action": "mark_safe",
  "priority": 60,
  "enabled": true
}
```

### Clean Directory

```json
{
  "name": "npm_cache",
  "type": "directory",
  "pattern": "/.npm/",
  "action": "mark_safe",
  "priority": 75,
  "enabled": true
}
```

## Tips

1. **Start Simple**: Begin with 1-2 rules and add more as needed
2. **Test First**: Always use `--dry-run` when testing new rules
3. **High Priority for Protection**: Use 90-100 for exclusion rules
4. **Use Examples**: Copy rules from `examples/` directory
5. **Verbose Mode**: Use `--verbose` to see rule matching
6. **Backup**: Keep a copy of working configurations

## Next Steps

- Read [CONFIGURATION.md](CONFIGURATION.md) for complete reference
- Read [RULES_GUIDE.md](RULES_GUIDE.md) for detailed rule examples
- Browse example configs in `examples/` directory
- Check [CONFIG_SYSTEM_SUMMARY.md](CONFIG_SYSTEM_SUMMARY.md) for technical details

## Troubleshooting

### Config Won't Load
- Check JSON syntax (use a JSON validator)
- Verify file path is correct
- Check file permissions

### Rules Not Matching
- Use `--verbose` to see why
- Test pattern on command line first
- Simplify pattern and add complexity gradually

### Wrong Files Matched
- Increase pattern specificity
- Add size/age constraints
- Use higher priority exclusion rules

## Need Help?

- Check the detailed guides in `docs/`
- Review example configs in `examples/`
- Run `desktop-cleanup --help`
