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
# Note: Repo is named 'git-override' but the tool is 'git-local-override'
git clone https://github.com/jonathanabila/git-override.git
cd git-override

# Run the test suite (local)
make test

# Run tests in Docker (recommended)
make test-docker

# Install hooks to the current repository (for testing)
./scripts/install.sh --repo

# Or install CLI tool globally (optional)
./scripts/install.sh --cli
```

## Project Structure

```
git-local-override/
├── bin/                          # CLI tool
│   └── git-local-override        # Main command-line interface
├── hooks/                        # Git hook scripts
│   ├── local-override-lib.sh     # Shared library functions
│   ├── local-override-post-checkout
│   ├── local-override-pre-commit
│   ├── local-override-post-commit
│   ├── local-override-filter-smudge   # Smudge filter (checkout)
│   └── local-override-filter-clean    # Clean filter (staging)
├── scripts/                      # Installation and release scripts
│   ├── install.sh
│   ├── uninstall.sh
│   └── release.sh                # Changelog version assignment
├── tests/                        # Test suite
│   ├── run-tests.sh              # Main test runner (unit tests)
│   ├── run-docker.sh             # Docker test launcher
│   ├── docker/                   # Docker test infrastructure
│   │   ├── Dockerfile            # Ubuntu test image
│   │   ├── Dockerfile.bash3      # Bash 3.2 compatibility image
│   │   └── entrypoint.sh
│   └── integration/              # Integration tests
│       ├── test-install.sh       # Install/uninstall tests
│       ├── test-git-ops.sh       # Git operations tests
│       └── test-precommit.sh     # Pre-commit framework tests
├── .github/                      # GitHub configuration
│   ├── workflows/                # CI and release workflows
│   ├── ISSUE_TEMPLATE/           # Issue templates
│   └── PULL_REQUEST_TEMPLATE.md
├── docs/                         # Additional documentation
│   └── DESIGN.md                 # Historical design (v0.0.1)
├── .pre-commit-hooks.yaml        # Pre-commit integration definitions
├── .pre-commit-config.yaml       # Pre-commit hooks for this repo
├── Makefile                      # Build automation
├── README.md                     # User documentation
├── CONTRIBUTING.md               # Contributor guidelines (this file)
├── CHANGELOG.md                  # Version history
├── AGENTS.md                     # AI agent instructions (same as CLAUDE.md)
├── CLAUDE.md                     # AI agent instructions
└── LICENSE                       # MIT license
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

All changes should include tests. The test suite is in `tests/run-tests.sh`.

**IMPORTANT: Tests must be run inside Docker to ensure isolation and consistency.**

```bash
# Run all tests in Docker (recommended and authoritative)
make test-docker

# Run tests with bash 3.2 for macOS compatibility
make test-docker-bash3

# Quick local test (for development iteration only)
make test

# Run tests with verbose output
bash -x tests/run-tests.sh
```

#### Writing Tests

Add tests to `tests/run-tests.sh`:

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

- [ ] Tests pass (`make test-docker` - authoritative)
- [ ] Tests pass (`make test` - local verification)
- [ ] Code follows style guidelines
- [ ] Bash 3.2 compatible
- [ ] Documentation updated
- [ ] CHANGELOG.md updated
- [ ] Commit messages follow convention

## Testing Changes Manually

### Test Installation

```bash
# Install hooks to current repo
./scripts/install.sh --repo

# Or install CLI tool globally
./scripts/install.sh --cli

# Verify CLI (if installed)
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

# Install hooks (from cloned repo)
/path/to/git-local-override/scripts/install.sh --repo

# Create config file
git-local-override init-config
# Edit .local-overrides.yaml to add README.md

# Create local override
git-local-override add README.md
cat README.local.md  # Should exist
```

### Test Hooks

```bash
# Modify local file
echo "# Local changes" > README.local.md

# Apply override to see local content
git-local-override apply

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

Releases are automated via GitHub Actions:

1. Ensure all changes are in the `[Unreleased]` section of CHANGELOG.md
2. Go to **Actions** → **Release** workflow → **Run workflow**
3. Enter the version number (e.g., `0.2.1`)
4. The workflow will:
   - Run `scripts/release.sh` to update CHANGELOG.md
   - Commit, tag, and push
   - Create a GitHub Release with release notes

For manual releases (if needed): `./scripts/release.sh <version>`

## Questions?

Open an issue with the `question` label or start a discussion.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
