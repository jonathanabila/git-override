# Contributing to git-local-override

Thank you for your interest in contributing! This document provides guidelines and information for contributors.

## Code of Conduct

Be respectful, inclusive, and constructive. We're all here to build something useful together.

## Getting Started

### Prerequisites

- Bash 3.2+ (macOS) or Bash 4+ (Linux)
- Git 2.0+
- Make (for running tests and installation)
- `fd` on `PATH` is strongly recommended when profiling config discovery in large monorepos

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

When debugging performance in large repositories, use trace mode and note whether config discovery is using `fd` or the Git fallback:

```bash
GIT_LOCAL_OVERRIDE_TRACE=1 git-local-override apply
```

Look for `discover_config_files strategy=fd` versus `discover_config_files strategy=git`. Large-repo timings can differ substantially depending on whether `fd` is installed.

```bash
# Run the full CI-equivalent suite: lint, resolver sync, and both Docker
# test suites (recommended before committing; requires Docker)
make ci

# Run all tests in Docker (recommended and authoritative)
make test-docker

# Run tests with bash 3.2 for macOS compatibility
make test-docker-bash3

# Quick local test (for development iteration only)
make test

# Run tests with verbose output
bash -x tests/run-tests.sh

# Run the unit suite under kcov to surface untested branches
# (opt-in diagnostic; writes coverage/index.html; NOT a CI gate)
make coverage
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

The assertion harness — `info`/`pass`/`fail`, the terminal colors, the
`TESTS_RUN`/`TESTS_PASSED`/`TESTS_FAILED` counters, and the `finish_suite`
summary/exit helper — lives once in `tests/test-lib.sh`. Any suite that sources
`test-lib.sh` gets it for free; don't redefine these per file. Each suite's
`main()` ends with `finish_suite`, which prints the summary and exits non-zero if
any test failed. `info` starts a test, `fail` marks a failure, and every suite is
green iff no test failed. In `tests/run-tests.sh`, `pass` is called exactly once
per test, so it sets `STRICT_PASS_COUNT=1` to additionally require
`TESTS_PASSED == TESTS_RUN` (a test that starts but never reaches a `pass()` fails
the build); the integration suites call `pass` once per assertion and leave that
flag off.

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

Releases are cut locally by maintainers and published by GitHub Actions from a pushed signed annotated tag. GitHub Actions never commits to or pushes `main`, and only stable `X.Y.Z` versions are supported.

### Preflight Checklist

Before cutting a release, make sure:

1. Your working tree is clean
2. `main` is checked out and up to date with `origin/main`
3. The full local CI-equivalent suite is passing
4. `CHANGELOG.md` has complete notes under `[Unreleased]`
5. Commit signing and tag signing are configured locally

Recommended verification commands:

```bash
git status --short
git checkout main
git pull --ff-only origin main
make ci
```

`make ci` is the single CI-parity command: it runs shellcheck (`lint`), the
resolver-copy sync guard (`check-resolver-sync`), and both Docker test suites.
Docker is required.

If developing on macOS, also mirror the native macOS CI job:

```bash
make test
tests/integration/test-install.sh
tests/integration/test-git-ops.sh
tests/integration/test-precommit.sh
```

### Maintainer Release Flow

Only maintainers should cut releases. If you want GitHub to enforce that policy, add tag protection for `v*` tags.

1. Prepare the changelog for the new stable version:

   ```bash
   ./scripts/release.sh X.Y.Z
   ```

   This moves the current `[Unreleased]` notes into `## [X.Y.Z] - YYYY-MM-DD`, updates the compare links in `CHANGELOG.md`, and syncs the root `VERSION` file to the same release.

2. Review the changelog update and create a signed release commit:

   ```bash
   git diff -- CHANGELOG.md VERSION
   git add CHANGELOG.md VERSION
   git commit -S -m "chore(release): vX.Y.Z"
   ```

3. Create a signed annotated tag for that commit:

   ```bash
   git tag -s "vX.Y.Z" -m "vX.Y.Z"
   ```

4. Push `main`, then push the tag:

   ```bash
   git push origin main
   git push origin "vX.Y.Z"
   ```

5. The `Release` workflow runs on the pushed `vX.Y.Z` tag and will:
    - Validate that the tag is stable semver and annotated
    - Verify the tagged commit is reachable from `origin/main`
    - Read the matching `## [X.Y.Z]` section from `CHANGELOG.md`
    - Fail if a GitHub release for that tag already exists
    - Publish the GitHub release for that tag

Exact maintainer command sequence:

```bash
git checkout main
git pull --ff-only origin main
./scripts/release.sh X.Y.Z
git add CHANGELOG.md VERSION
git commit -S -m "chore(release): vX.Y.Z"
git tag -s "vX.Y.Z" -m "vX.Y.Z"
git push origin main
git push origin "vX.Y.Z"
```

### Recovery

- If the publish job fails for a good tag, fix the workflow issue and rerun the failed workflow when possible; no new commit or tag is needed unless the tag itself is wrong
- If `CHANGELOG.md` or the tag version is wrong, delete the local and remote tag, fix the release commit or changelog on `main`, recreate the signed annotated tag, and push it again:

  ```bash
  git tag -d "vX.Y.Z"
  git push origin :refs/tags/vX.Y.Z
  ```

- If the version already exists as a tag or GitHub release, do not reuse it; prepare the next correct version instead
- If you accidentally tagged the wrong commit, delete the bad tag, return to `origin/main`, rebuild the release commit if needed, and recreate the signed annotated tag on the correct commit

## Questions?

Open an issue with the `question` label or start a discussion.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
