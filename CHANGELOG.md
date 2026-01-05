# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Docker-based testing infrastructure** for isolated, reproducible tests:
  - `make test-docker` - Run all tests in Docker container
  - `make test-docker-bash3` - Run tests on Alpine for compatibility testing
  - Dockerfile for Ubuntu 22.04 with git, bash, pre-commit
  - Dockerfile for Alpine (lightweight compatibility testing)

- **Integration test suites**:
  - Install/uninstall tests - Verify install.sh and uninstall.sh work correctly
  - Git operations tests - Test real git commit, checkout, branch operations
  - Pre-commit framework tests - Verify hooks work through pre-commit

- **GitHub Actions CI workflow** (`.github/workflows/test.yml`):
  - Docker-based tests on Ubuntu
  - Native macOS tests (with real bash 3.2)
  - Shellcheck linting

### Fixed

- Fixed `((count++))` arithmetic causing script exit with `set -e` when count is 0
- Fixed install.sh global template hooks not including shared library
- Simplified SCRIPT_DIR handling in hooks (lib always in same directory)

## [2.0.0] - 2025-01-05

### Changed

- **Config-driven architecture**: Replaced registry/allowlist system with `.local-overrides.yaml` config file
  - Repository maintainers now define override-able files in a checked-in config
  - No more global allowlist or per-repo registry files
  - Simpler mental model: config file + local files = overrides

- **Pre-commit integration**: Added `.pre-commit-hooks.yaml` for native pre-commit support
  - Users can add hooks via `.pre-commit-config.yaml` instead of manual installation
  - Supports `pre-commit`, `post-commit`, and `post-checkout` stages

- **Simplified installation**:
  - Option 1: Pre-commit (add to yaml, run `pre-commit install`)
  - Option 2: Curl one-liner for standalone installation
  - No more global CLI installation required

- **Self-contained hooks**: Hooks now include shared library (`local-override-lib.sh`)
  - No dependency on globally installed scripts
  - Each repo is fully self-contained

### Added

- `hooks/local-override-lib.sh` - Shared library for hook scripts
- `.pre-commit-hooks.yaml` - Pre-commit hook definitions
- `init-config` CLI command - Create `.local-overrides.yaml` template
- Support for plain text config format (`.local-overrides`)

### Removed

- Global registry system (`~/.config/git/local-overrides/<hash>.list`)
- Global allowlist (`~/.config/git/local-overrides/allowlist`)
- `init` command (replaced by install script)
- `sync` command (no longer needed without registry)
- `allowlist` subcommands (no longer needed)

### Fixed

- Post-checkout hook now only runs on branch checkouts (not file checkouts)
  - Allows `git checkout HEAD -- file` to work for restoring originals
  - Fixes conflict between `restore` command and hook behavior

## [1.0.0] - 2025-01-04

### Added

- **Core CLI tool** (`git-local-override`) with commands:
  - `add <path>` - Add a local override for a tracked file
  - `remove [-d] <path>` - Remove an override (optionally delete local file)
  - `list` - List all active overrides in current repository
  - `status` - Show detailed system status
  - `sync` - Rebuild registry from existing `.local` files
  - `apply` - Manually apply all overrides
  - `restore` - Manually restore all originals
  - `init` - Install hooks in current repository
  - `allowlist add|remove|list` - Manage allowed file patterns

- **Git hooks** for transparent operation:
  - `post-checkout` - Applies overrides after checkout/pull
  - `pre-commit` - Restores originals before commit
  - `post-commit` - Re-applies overrides after commit

- **Allowlist system** for security:
  - Global allowlist at `~/.config/git/local-overrides/allowlist`
  - Per-repository allowlist support
  - Glob pattern matching (`**`, `*`, `?`)
  - Default patterns for `CLAUDE.md` and `AGENTS.md`

- **Registry system** for performance:
  - Per-repository registry files
  - O(n) lookup where n = number of overrides
  - Automatic cleanup of stale entries

- **Hook chaining** to preserve existing hooks:
  - Existing hooks renamed to `<hook>.chained`
  - Our hooks run first, then chain to existing

- **Installation scripts**:
  - `install-local-override.sh` - Global installer
  - `uninstall-local-override.sh` - Clean removal

- **Comprehensive test suite** with 18 tests covering:
  - CLI commands
  - Hook behavior
  - Allowlist enforcement
  - Registry management
  - Edge cases

### Technical Details

- Bash 3.2+ compatible (works on macOS default bash)
- No external dependencies beyond standard Unix tools
- Performance optimized (< 50ms for typical operations)
- Automatic global gitignore for `*.local.*` patterns

### File Naming Convention

| Original | Local Override |
|----------|----------------|
| `file.md` | `file.local.md` |
| `file.json` | `file.local.json` |
| `Makefile` | `Makefile.local` |

---

## Version History

- **1.0.0** - Initial release with full feature set

[Unreleased]: https://github.com/jonathanabila/git-override/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/jonathanabila/git-override/releases/tag/v1.0.0
