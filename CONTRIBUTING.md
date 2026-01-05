# Contributing to Sweeper

Thank you for your interest in contributing to Sweeper! This document provides guidelines and information for contributors.

## Getting Started

### Prerequisites

- [Zig 0.15+](https://ziglang.org/download/)
- Git

### Setup

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/augani/sweeper.git
   cd sweeper
   ```
3. Build the project:
   ```bash
   zig build
   ```
4. Run tests:
   ```bash
   zig build test
   ```

## Development Workflow

### Branch Naming

- `feature/description` - New features
- `fix/description` - Bug fixes
- `docs/description` - Documentation updates
- `refactor/description` - Code refactoring

### Code Style

- Follow Zig's official style guide
- Use meaningful variable and function names
- Keep functions focused and small
- Add comments for complex logic

### Commit Messages

Use clear, descriptive commit messages:

```
type: short description

Longer description if needed. Explain what and why,
not how (the code shows how).
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

## Pull Request Process

1. Create a feature branch from `main`
2. Make your changes
3. Test thoroughly on your platform
4. Update documentation if needed
5. Submit a PR with a clear description

### PR Checklist

- [ ] Code compiles without warnings
- [ ] Tests pass
- [ ] Documentation updated (if applicable)
- [ ] Commit messages follow conventions
- [ ] PR description explains the changes

## Testing

### Running Tests

```bash
# Run all tests
zig build test

# Run specific test file
zig test src/scanner.zig
```

### Testing on Multiple Platforms

If possible, test on:
- macOS (ARM and Intel)
- Linux
- Windows

Cross-compilation:
```bash
zig build -Dtarget=x86_64-windows-gnu
zig build -Dtarget=x86_64-linux-gnu
```

## Areas for Contribution

### Good First Issues

- Documentation improvements
- Additional cache path detection
- UI polish and accessibility
- Test coverage

### Larger Projects

- Plugin system for custom cleanup rules
- Integration with system trash
- Scheduled cleanup automation
- Cloud storage cleanup support

## Reporting Bugs

When reporting bugs, include:

1. Operating system and version
2. Zig version (`zig version`)
3. Steps to reproduce
4. Expected vs actual behavior
5. Error messages or logs

## Feature Requests

Feature requests are welcome! Please:

1. Check existing issues first
2. Describe the use case
3. Explain why it would benefit users

## Code of Conduct

- Be respectful and inclusive
- Focus on constructive feedback
- Help others learn and grow

## Questions?

- Open an issue for questions
- Join discussions in existing issues

Thank you for contributing to Sweeper!
