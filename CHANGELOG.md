# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **skip-worktree integration**: Overridden files no longer appear as modified in `git status`
  - Uses `git update-index --skip-worktree` when applying overrides
  - Uses `git update-index --no-skip-worktree` when restoring originals
  - Applied automatically in hooks (post-checkout, pre-commit, post-commit)
  - Applied in CLI commands (`apply`, `restore`)
- **Skip-worktree documentation**: Added section to README explaining this feature

### Fixed

- **Test compatibility with skip-worktree**: Fixed integration tests failing due to skip-worktree
  - Tests now clear skip-worktree before `git add` or `git checkout` operations
  - Affected tests: git operations and pre-commit framework integration tests
- **Documentation accuracy**: Comprehensive review and update of all documentation
  - Fixed outdated config format in `install.sh` summary (now shows `override:`/`replaces:` format)
  - Fixed `uninstall.sh` references to legacy registry/allowlist system and non-existent `uninit` command
  - Updated pre-commit version references from v0.0.2 to v0.1.0 across all docs
  - Fixed placeholder URLs (`https://.../`) with actual GitHub URLs
  - Fixed CLI help text showing non-existent v1.0.0 version
  - Fixed Makefile `install-manual` creating legacy allowlist files
  - Updated CONTRIBUTING.md project structure to reflect actual directory layout
  - Updated AGENTS.md/CLAUDE.md key functions list to include `read_pattern()`, `get_active_overrides()`, `cmd_status()`, `cmd_init_config()`
  - Fixed incomplete version history summary in CHANGELOG.md

## [0.1.0] - 2026-01-08

### Changed (BREAKING)

- **New config format**: Unified `override:` + `replaces:` format replaces all previous formats
  - **Old format (no longer supported):**
    ```yaml
    files:
      - CLAUDE.md
      - path: config.json
        override: config.local.json
    ```
  - **New format:**
    ```yaml
    files:
      - override: CLAUDE.local.md
        replaces:
          - CLAUDE.md
    ```

- **Multi-target overrides**: One override file can now replace multiple tracked files
  ```yaml
  files:
    - override: AGENTS.local.md
      replaces:
        - AGENTS.md
        - CLAUDE.md
  ```

- **Grouped pre-commit restore**: When any target in a group is staged, ALL targets are restored
  - Ensures consistency for multi-target overrides
  - Prevents partial commits of grouped files

### Removed

- Legacy plain-text `.local-overrides` config format
- Old `- path:` / `override:` per-file format
- Old simple list format (`- CLAUDE.md`)
- `get_local_path()` function from hooks (override paths are now explicit)
- Backwards compatibility fallback for missing `pattern:` field

### Added

- Conflict detection: Error if same file appears in multiple `replaces:` lists
- `get_targets_for_override()` helper function for grouped operations
- `get_override_files()` helper function to list unique override files

### Migration

Existing configs must be migrated:
```yaml
# OLD
pattern: ".local"
files:
  - CLAUDE.md
  - AGENTS.md

# NEW
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
```

## [0.0.7] - 2026-01-06

### Added

- **Troubleshooting guide for curl install users**: Documents that users who install via curl (not pre-commit) need to re-run the install script when new hooks are added to the project
- **Custom override file naming** via required `pattern:` field in config
  - Configure any pattern: `.local`, `.override`, `.custom`, etc.
  - Pattern determines override file naming: `CLAUDE.md` → `CLAUDE.{pattern}.md`
- **Per-file explicit override naming** with `path:` and `override:` syntax
  - Individual files can specify exact override filename
  - Example: `path: config.json` with `override: config.mylocal.json`
- **Config validation** with helpful error messages
  - Warns when `pattern:` field is missing from YAML config
  - Warns when using legacy plain text config format

### Changed

- Config format now requires `pattern:` field for new configurations
- `get_local_path()` function now accepts pattern as second parameter
- `read_config()` now outputs `path|override_path` format for per-file support
- `list` command now displays the configured pattern
- `status` command now shows pattern information
- `init-config` command generates config with required `pattern:` field
- Help text updated with new config format documentation

### Deprecated

- Plain text `.local-overrides` format (shows warning, use YAML instead)
- YAML config without `pattern:` field (shows error, falls back to `.local`)

## [0.0.6] - 2026-01-06

### Added

- GitHub Actions release workflow for automated versioning and releases
- Release script (`scripts/release.sh`) for changelog version assignment
- "For AI Assistants" section in README with step-by-step installation instructions for LLM agents

### Changed

- Changelog now uses `[Unreleased]` section to avoid merge conflicts in parallel PRs
- Updated CLAUDE.md with new changelog instructions

## [0.0.5] - 2026-01-05

### Added

- CI status badge in README for build visibility
- `.gitattributes` for cross-platform line ending consistency

## [0.0.4] - 2025-01-05

### Added

- **Community health files** for open-source project management:
  - `CODE_OF_CONDUCT.md` - Contributor Covenant v2.1 code of conduct
  - `.github/ISSUE_TEMPLATE/bug_report.md` - Structured bug report template
  - `.github/ISSUE_TEMPLATE/feature_request.md` - Feature request template
  - `.github/ISSUE_TEMPLATE/config.yml` - Issue template configuration
  - `.github/CODEOWNERS` - Automatic code review assignments
  - `.github/dependabot.yml` - Automated dependency updates for GitHub Actions
  - `.editorconfig` - Consistent coding styles across editors

## [0.0.3] - 2025-01-05

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

### Changed

- **Documentation overhaul** for accuracy and clarity:
  - Added obsolete warning banner to `docs/DESIGN.md` (describes v0.0.1 architecture)
  - Updated `CONTRIBUTING.md` project structure to match actual layout
  - Updated `CONTRIBUTING.md` test paths from `sandbox/` to `tests/`
  - Removed references to obsolete CLI commands (`init`, `allowlist`, `sync`) in `CONTRIBUTING.md`
  - Fixed clone instructions in `CONTRIBUTING.md` to clarify repo vs directory name
  - Added repo name vs tool name clarification in `README.md`
  - Added "What Gets Installed" section in `README.md`
  - Added version pinning guidance for curl installs in `README.md`
  - Updated requirements list in `README.md` with complete dependencies
  - Enhanced inline "why" comments in core scripts for maintainability

### Fixed

- Fixed `((count++))` arithmetic causing script exit with `set -e` when count is 0
- Fixed install.sh global template hooks not including shared library
- Simplified SCRIPT_DIR handling in hooks (lib always in same directory)

## [0.0.2] - 2025-01-05

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

## [0.0.1] - 2025-01-04

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

- **0.1.0** - Multi-target overrides with new config format (BREAKING)
- **0.0.7** - Custom override file naming via pattern field
- **0.0.6** - GitHub Actions release workflow
- **0.0.5** - CI badge and .gitattributes for resilience
- **0.0.4** - Community health files for public release
- **0.0.3** - Docker-based testing infrastructure and CI
- **0.0.2** - Config-driven architecture
- **0.0.1** - Initial release with full feature set

[0.1.0]: https://github.com/jonathanabila/git-override/compare/v0.0.7...v0.1.0
[0.0.7]: https://github.com/jonathanabila/git-override/compare/v0.0.6...v0.0.7
[0.0.6]: https://github.com/jonathanabila/git-override/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/jonathanabila/git-override/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/jonathanabila/git-override/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/jonathanabila/git-override/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/jonathanabila/git-override/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/jonathanabila/git-override/releases/tag/v0.0.1
