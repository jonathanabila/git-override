# Contributing to git-local-override

Thank you for your interest in contributing! This document provides guidelines and information for contributors.

## Code of Conduct

Be respectful, inclusive, and constructive. We're all here to build something useful together.

## Getting Started

### Prerequisites

- Bash 3.2+ (macOS) or Bash 4+ (Linux)
- Git 2.0+
- Make (for running tests and installation)

### Setting Up Development Environment

```bash
# Clone the repository
git clone https://github.com/jonathanabila/git-override.git
cd git-local-override

# Run the test suite
make test

# Install locally for testing
make install
```

## Project Structure

```
git-local-override/
├── git-local-override              # Main CLI tool (bash)
├── local-override-post-checkout    # Post-checkout hook script
├── local-override-pre-commit       # Pre-commit hook script
├── local-override-post-commit      # Post-commit hook script
├── install-local-override.sh       # Global installer
├── uninstall-local-override.sh     # Global uninstaller
├── sandbox/                        # Test environment
│   ├── run-tests.sh               # Test suite
│   └── test-wrapper.sh            # Test helper
├── README.md
├── CONTRIBUTING.md
├── CHANGELOG.md
├── LICENSE
├── Makefile
└── .gitignore
```

## Development Guidelines

### Code Style

- **Shell scripts**: Use `#!/usr/bin/env bash` shebang
- **Indentation**: 4 spaces (no tabs)
- **Line length**: Aim for < 100 characters
- **Functions**: Use `snake_case` for function names
- **Variables**: Use `snake_case` for local variables, `UPPER_CASE` for constants
- **Comments**: Explain *why*, not *what*

### Bash Compatibility

**Important**: All scripts must work with Bash 3.2 (macOS default).

Avoid:
- `declare -A` (associative arrays) - Bash 4+ only
- `${var,,}` (lowercase) - Bash 4+ only
- `|&` (pipe stderr) - Bash 4+ only
- `coproc` - Bash 4+ only

Use instead:
- Regular arrays and grep for lookups
- `tr '[:upper:]' '[:lower:]'` for case conversion
- `2>&1 |` for piping stderr

### Error Handling

```bash
# Always use strict mode
set -euo pipefail

# Use explicit error handling for expected failures
if ! some_command; then
    die "Command failed: reason"
fi

# Use || true for commands that may fail acceptably
git checkout HEAD -- "$path" 2>/dev/null || true
```

### Testing

All changes should include tests. The test suite is in `sandbox/run-tests.sh`.

```bash
# Run all tests
make test

# Run tests with verbose output
cd sandbox && bash -x ./run-tests.sh
```

#### Writing Tests

Add tests to `sandbox/run-tests.sh`:

```bash
test_your_feature() {
    info "Testing your feature..."

    cd "$TEST_REPO"

    # Setup
    # ...

    # Test
    if [[ expected_condition ]]; then
        pass "Your feature works"
    else
        fail "Your feature failed"
    fi
}
```

Don't forget to add your test to the `main()` function.

### Documentation

- Update README.md for user-facing changes
- Update CHANGELOG.md for all changes
- Add inline comments for complex logic
- Include examples in help text

## Making Changes

### Branch Naming

- `feature/description` - New features
- `fix/description` - Bug fixes
- `docs/description` - Documentation only
- `refactor/description` - Code refactoring

### Commit Messages

Follow conventional commit format:

```
type: short description

Longer description if needed.

- Bullet points for multiple changes
- Keep lines under 72 characters
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation
- `refactor`: Code refactoring
- `test`: Adding/updating tests
- `chore`: Maintenance tasks

### Pull Request Process

1. **Fork** the repository
2. **Create** a feature branch from `main`
3. **Make** your changes with tests
4. **Run** `make test` to ensure all tests pass
5. **Update** documentation as needed
6. **Submit** a pull request

#### PR Checklist

- [ ] Tests pass (`make test`)
- [ ] Code follows style guidelines
- [ ] Bash 3.2 compatible
- [ ] Documentation updated
- [ ] CHANGELOG.md updated
- [ ] Commit messages follow convention

## Testing Changes Manually

### Test Installation

```bash
# Test install
make install

# Verify
which git-local-override
git-local-override help
```

### Test in a Repository

```bash
# Create test repo
mkdir /tmp/test-repo && cd /tmp/test-repo
git init
echo "# Test" > README.md
git add . && git commit -m "Initial"

# Test the tool
git-local-override init
git-local-override allowlist add '*.md'
git-local-override add README.md
cat README.local.md  # Should exist
```

### Test Hooks

```bash
# Modify local file
echo "# Local changes" > README.local.md

# Verify hook behavior
git add README.md
git commit -m "Test"  # Should commit original, not local
cat README.md         # Should show local content again
```

## Reporting Issues

### Bug Reports

Include:
1. **Environment**: OS, Bash version (`bash --version`), Git version
2. **Steps to reproduce**: Exact commands run
3. **Expected behavior**: What should happen
4. **Actual behavior**: What actually happens
5. **Logs**: Any error messages

### Feature Requests

Include:
1. **Use case**: Why you need this feature
2. **Proposed solution**: How it might work
3. **Alternatives considered**: Other approaches

## Release Process

Maintainers only:

1. Update version in relevant files
2. Update CHANGELOG.md with release notes
3. Create git tag: `git tag -a v0.0.X -m "Release v0.0.X"`
4. Push tag: `git push origin v0.0.X`

## Questions?

Open an issue with the `question` label or start a discussion.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
