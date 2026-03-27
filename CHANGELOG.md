# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **`sync-filters` now shows progress logging**: Added `info` messages before each major step (validating config, syncing filter driver, syncing attributes, checking legacy skip-worktree) so users can see what the command is doing

### Fixed

- **`sync-filters` performance**: Cached `discover_config_files` results to eliminate repeated `git ls-files` calls (previously called O(N) times per entry via `target_is_shadowed_by_child_config`), and cached `read_config` output to avoid parsing config twice

## [0.4.1] - 2026-03-27

### Fixed

- **Config discovery now finds gitignored config files**: `discover_config_files()` now includes a second `git ls-files` pass for ignored files, so `.local-overrides.yaml` files that are untracked and gitignored (e.g. via `.git/info/exclude`) are no longer invisible to the tool

### Added

- **CLI version command**: Added `git-local-override version` and `git-local-override --version` backed by a checked-in `VERSION` file so repo and installed CLI copies report the same release number

### Changed

- **Default install command now includes `--cli`**: All documentation now recommends `bash -s -- --cli` so the CLI is installed alongside hooks by default
- **Release metadata sync**: `scripts/install.sh --cli`, `scripts/uninstall.sh`, and `scripts/release.sh` now install, remove, and update the shared `VERSION` file alongside the CLI and resolver
- **Versioning docs**: Updated contributor and agent instructions so tagged releases keep `VERSION`, changelog entries, and release tags aligned

## [0.4.0] - 2026-03-26

### Added

- **Recursive config discovery**: Added support for nested `.local-overrides.yaml` files with nearest-config-wins subtree ownership
  - Child configs fully replace parent config behavior for their subtree
  - Nested config `override:` and `replaces:` paths resolve relative to the config file's directory

### Changed

- **Release publishing flow**: Switched releases to a maintainer-run signed commit plus signed annotated tag flow, with GitHub Actions publishing from pushed `vX.Y.Z` tags instead of committing or pushing `main`
- **Release docs and workflow guardrails**: Clarified maintainer-only stable release steps, recovery commands, and release workflow wording around tag-derived versions and existing-release protection
- **Validation and filter sync**: Recursive config validation now rejects parent entries targeting child-owned subtrees, and `.git/info/attributes` sync now emits only effective recursive targets
- **Resolver architecture**: Extracted the recursive config resolver into a shared module used by hooks, the CLI, and installer/runtime packaging to reduce duplication while preserving standalone CLI installs
- **Documentation alignment**: Updated security, user, and maintainer docs for recursive config trust boundaries, shared resolver packaging, inherited nested patterns, empty-child subtree ownership, and current legacy `skip-worktree` repair behavior

## [0.3.0] - 2026-03-18

### Added

- **Shell integration command**: Added `git-local-override shell-init` for transparent `git checkout`/`git switch` support
  - Outputs a shell function wrapping git to restore originals before checkout and let smudge filter re-apply on new branch
  - Required for git 2.37+ when overridden files differ between branches
  - Works with bash 3.2 and zsh
  - Usage: `eval "$(git-local-override shell-init)"` in `.bashrc`/`.zshrc`

- **Internal `_get-active-targets` command**: Helper for shell-init wrapper to list active override targets

### Changed

- **Legacy skip-worktree self-healing**: Repo reinstall, `git-local-override sync-filters`, and runtime hooks now automatically clear stale `skip-worktree` bits on configured managed files from older installs
  - Repair stays scoped to tracked managed targets from `.local-overrides.yaml`
  - `install.sh` and `sync-filters` print a one-line info message only when repairs occur
  - Runtime hooks print a terse stderr notice only when repairs occur

- **Removed skip-worktree dependency**: Clean/smudge filters now handle `git status`/`git diff` hiding without skip-worktree
  - Removed `git update-index --skip-worktree` from all hooks (post-checkout, post-commit, pre-commit, pre-rebase)
  - Removed `git update-index --skip-worktree` from CLI `apply` and `restore` commands
  - Skip-worktree caused problems in newer git versions (sparse-checkout boundary enforcement, `git add` refusal)

### Fixed

- **Hook chaining reachability**: Managed wrapper hooks now continue into `*.chained` hooks again after successful execution
  - Replaced `exit` calls inside hook `main()` functions with `return` so wrapper-appended chain logic is reachable
  - Managed hook failures still stop the chain as before

- **Git-ops passthrough test flake**: Stabilized passthrough tests to restore tracked content with `git show` instead of `git checkout HEAD --`
  - Avoids nondeterministic filter/index stat-cache behavior when no override file is present
  - Avoids relying on `GIT_LOCAL_OVERRIDE_DISABLE=1` propagating to filter subprocesses during test setup

- **Bypass smudge filter in restore operations**: Replaced `GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD --` with approaches that reliably bypass the smudge filter across all platforms
  - `cmd_restore()`: Uses `git show HEAD:<file>` to write original content directly (no filter involvement)
  - Shell-init wrapper: Uses `git -c filter.local-override.smudge= checkout` to disable filter inline
  - Pre-rebase hook: Uses `git -c filter.local-override.smudge= checkout` to disable filter inline
  - Fixes macOS CI where env var didn't propagate to filter subprocess
  - Fixes Alpine CI where filter bypass caused unstaged-changes errors
  - Matches the pattern already used correctly in the pre-rebase hook

- **`git checkout` failure with divergent overridden files**: On git 2.37+, `git checkout <branch>` would fail when overridden files had different content between branches
  - The `shell-init` wrapper transparently restores originals before checkout
  - Smudge filter automatically re-applies overrides on the new branch

### Added

- **Installer ambiguous-hook repair mode**: Added opt-in `--resolve-ambiguous-hooks` support to `scripts/install.sh`
  - Repairs ambiguous managed-hook states where an unmanaged canonical hook and existing `*.chained` file both exist
  - Backs up both pre-repair files into a timestamped hooks backup directory
  - Preserves prior chained hooks as `*.chained.stale-<timestamp>` history before promoting the canonical hook

- **Ambiguous hook repair plan document**: Added `docs/ambiguous-hook-repair-plan.md` with the opt-in installer repair design, safety rules, test plan, and a handoff prompt for implementation

- **Safe reinstall TDD plan document**: Added `docs/safe-reinstall-tdd-plan.md` with the ownership model, red/green/refactor workflow, TODO checklist, and regression tests for making reinstall a supported upgrade path

- **Safe reinstall/uninstall regression coverage**: Expanded `tests/integration/test-install.sh` with focused upgrade/removal scenarios
  - Adds reinstall refresh checks for managed `pre-commit` and `pre-rebase` wrappers
  - Adds chained-hook preservation checks across reinstall
  - Adds stale managed artifact pruning coverage for reinstall ownership boundaries
  - Adds uninstall safety checks for restoring chained hooks only when canonical wrappers are still managed
  - Adds global uninstall coverage for removing `filter.local-override.*` and template `pre-rebase` artifacts
  - Adds linked-worktree uninstall coverage using git-resolved paths

- **Agent work order for test isolation migration**: Added `docs/test-isolation-agent-work-order.md` with execution rules, phase order, validation workflow, and failure-classification requirements for implementation agents

- **Test isolation helper library scaffold**: Added `tests/test-lib.sh` for phase 1 of the test isolation migration
  - Adds Bash 3.2-safe helpers for per-test temp roots, isolated `HOME`/`XDG_CONFIG_HOME`, seed repo cloning, hook installation, and optional failure artifact preservation

- **Test isolation migration plan**: Added `docs/test-isolation-migration-plan.md` to define the phased move toward per-test repo isolation inside Docker-backed suite runs
  - Documents the target seed-repo architecture, phased rollout order, and success criteria per suite
  - Adds explicit failure triage rules so each migrated test failure is classified as pre-existing, expected, or a true regression

- **Rebase TDD plan document**: Added `docs/rebase-regression-tdd-plan.md` to capture the regression scenario, test strategy, and implementation checklist for the override-file rebase bug

- **Pre-rebase protection hook**: Added `local-override-pre-rebase` to clear skip-worktree for configured targets before rebase
  - Prevents rebase failures like `Your local changes ... would be overwritten by checkout` on overridden files
  - Installed by `scripts/install.sh` and exposed via `.pre-commit-hooks.yaml` as `local-override-pre-rebase`

### Changed

- **Archived design doc cleanup**: Replaced `docs/DESIGN.md` legacy deep-dive content with a concise archived-history note
  - Removes obsolete implementation details and command examples that no longer apply
  - Keeps stable references while directing readers to current authoritative docs

- **Installer hook ownership model**: `scripts/install.sh` now uses an exact managed-wrapper marker (`# git-local-override-managed-hook: <hook>`) for ownership detection
  - Reinstall now refreshes managed wrappers in place instead of skipping existing hook files
  - Existing `.chained` backups are preserved across reinstall
  - Reinstall prunes stale managed helper artifacts left by older installer layouts (for example `local-override-pre-rebase`)
  - Ambiguous unmanaged states with an existing `.chained` file are preserved with warnings instead of being overwritten

- **README upgrade guidance**: Documented that rerunning `install.sh` is the safe supported upgrade path and that repo uninstall should be run from inside each affected repository
  - Clarifies reinstall behavior for managed wrappers, chained backups, and filter/attributes resync
  - Clarifies uninstall safety behavior when unmanaged hooks are present

- **Git-ops integration isolation**: Migrated `tests/integration/test-git-ops.sh` to phase 2 per-test isolation using `tests/test-lib.sh`
  - Builds one suite seed repo, clones a fresh test repo per case, and gives each case its own temp `HOME` and `XDG_CONFIG_HOME`
  - Reconfigures hooks and filters per clone with `install_test_hooks` and `git-local-override sync-filters` so coverage stays aligned with real repo setup

- **Local docs ignore rule**: Added `docs/` to `.gitignore` so local planning docs stay out of status by default

- **Pre-commit integration isolation**: Migrated `tests/integration/test-precommit.sh` to phase 3 per-test isolation using `tests/test-lib.sh`
  - Builds one suite seed repo, clones a fresh repo per case, and gives each case isolated temp home/config state for pre-commit caches and hooks
  - Keeps pre-commit hook installation and local hook-library setup realistic while removing cross-test repository state

- **Install integration isolation**: Migrated `tests/integration/test-install.sh` to phase 4 per-test isolation using `tests/test-lib.sh`
  - Gives each install/uninstall case its own isolated temp workspace plus dedicated `HOME` and `XDG_CONFIG_HOME` for global git config and CLI install checks
  - Resets global git config between isolated cases so template-dir and excludesfile assertions no longer depend on prior test state

- **Installer upgrade guidance**: Expanded `README.md` with ambiguous-hook warning and repair instructions
  - Documents the conservative default reinstall behavior when unmanaged canonical hooks and existing `*.chained` files coexist
  - Explains when to use `--resolve-ambiguous-hooks` and what files the repair flow preserves

- **Unit-style suite isolation**: Migrated `tests/run-tests.sh` to phase 5 per-test isolation using `tests/test-lib.sh`
  - Builds one suite seed repo, clones a fresh repo per test case, and reinstalls hooks for each clone so tests no longer depend on prior repo mutations
  - Moves ad hoc temp-repo cleanup into per-test roots, including the no-HEAD filter case, while keeping each assertion's original behavior intact

- **Docker suite orchestration**: Tightened phase 6 Docker test orchestration in `Makefile`
  - `make test-docker` now runs unit, install, gitops, and pre-commit suites in separate container invocations instead of one shared `all` run
  - `make test-docker-bash3` now runs each supported suite in its own container invocation to keep Docker validation aligned with per-suite isolation goals

### Fixed

- **Ambiguous hook reinstall recovery**: `scripts/install.sh` can now safely repair ambiguous hook states when explicitly requested
  - Leaves default reinstall behavior unchanged: ambiguous unmanaged states still warn and preserve both files without rewriting either one
  - Adds integration coverage for warning-only mode, repair mode for `pre-commit` and `post-checkout`, and idempotent reinstall after repair

- **Uninstall symmetry and safety**: `scripts/uninstall.sh` now reconciles managed state using exact marker ownership checks
  - Restores `<hook>.chained` only when canonical hooks are still managed wrappers
  - Preserves newer unmanaged canonical hooks and warns on ambiguous states
  - Removes repository hooks/filters using git-resolved paths (`git rev-parse --git-common-dir`, `git rev-parse --git-path info/attributes`) for linked-worktree compatibility
  - Removes global `filter.local-override.*` config during uninstall
  - Cleans global template `pre-rebase` wrapper/artifacts alongside other managed template files

- **Rebase regression coverage**: Added integration coverage for rebasing with divergent overridden files while skip-worktree is set
  - Test now simulates true upstream divergence using `GIT_LOCAL_OVERRIDE_DISABLE=1 git add` so filter-clean does not mask changes

- **Rebase with active override files**: Fixed rebase detach failures when override files remain present
  - `local-override-pre-rebase` now restores configured targets with `git checkout HEAD -- <target>` (index + working tree) instead of writing only working-tree bytes
  - Added `is_rebase_in_progress()` helper and rebase guards in post-checkout/post-commit/smudge paths to avoid reapplying overrides during rebase internals
  - `local-override-filter-clean` now prefers index (`:<path>`) content and only transforms when stdin matches active override content

- **Rebase regression tests**: Added AGENTS-focused rebase regression + workaround integration coverage
  - New test validates rebase succeeds with override file present
  - Companion test validates a disable/remove workaround path before rebase

### Fixed

- **Linked worktree filter failures**: Filter driver commands now use worktree-safe absolute hook script paths instead of relative `.git/hooks/...` paths
  - Fixes `git worktree add` failures like `local-override-filter-smudge: Not a directory` when `.git` is a file in linked worktrees
  - `git-local-override sync-filters` now repairs legacy filter config by rewriting old relative commands

### Changed

- **Installer filter configuration**:
  - `scripts/install.sh --repo` now installs hooks into the common git hooks directory and configures local filter commands with absolute paths
  - `scripts/install.sh --global` now configures global filter commands with absolute template hook paths

### Added

- **Regression coverage for worktree-safe filter paths**:
  - Added integration test for `git worktree add` with filters enabled
  - Added test coverage that install writes absolute filter command paths
  - Added test coverage that `sync-filters` migrates legacy `.git/hooks/...` filter config

## [0.2.0] - 2026-02-09

### Fixed

- **Flaky test elimination**: Fixed `test_hooks_skip_without_config` in `tests/integration/test-git-ops.sh` by using `git show "HEAD:file" > file` instead of `git checkout HEAD --` to bypass smudge filter and ensure deterministic test behavior

### Changed

- **Documentation updates**: Updated README.md and CONTRIBUTING.md to accurately reflect filter driver implementation, including filter scripts in architecture diagrams and emphasizing Docker tests as authoritative

### Added

- **skip-worktree integration**: Overridden files no longer appear as modified in `git status`
  - Uses `git update-index --skip-worktree` when applying overrides
  - Uses `git update-index --no-skip-worktree` when restoring originals
  - Applied automatically in hooks (post-checkout, pre-commit, post-commit)
  - Applied in CLI commands (`apply`, `restore`)
- **Skip-worktree documentation**: Added section to README explaining this feature
- **Filter driver scripts**: Added `local-override-filter-smudge` and `local-override-filter-clean`
  - Smudge outputs local override content when configured override files exist
  - Clean outputs original `HEAD:<path>` content when overrides are active
  - Both filters support passthrough mode and `GIT_LOCAL_OVERRIDE_DISABLE=1`
- **Filter helper commands**: Added CLI subcommands `filter-smudge` and `filter-clean`
  - Mirrors hook filter behavior for direct invocation and testing
- **sync-filters CLI command**: Added `git-local-override sync-filters` to manually sync filter configuration
  - Regenerates `.git/info/attributes` from `.local-overrides.yaml`
  - Configures git filter driver if not already set up
  - Useful for fixing out-of-sync filter state
- **GIT_LOCAL_OVERRIDE_DISABLE environment variable**: Bypass filter drivers when set to 1
  - Allows getting true original content with `GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- <file>`
  - Documented in CLI help and README

### Changed

- **Hook test setup**: Unit test bootstrap now installs filter scripts into `.git/hooks`
- **Disable-env test invocation**: Filter disable test now exports `GIT_LOCAL_OVERRIDE_DISABLE=1` to the filter process

### Fixed

- **Branch switching with divergent overridden files**: Fixed checkout/switch failures when overridden files differ between branches
  - Filter drivers now make git consider overridden files "clean" via clean(smudge(X)) == X roundtrip
  - Works across all git operations: checkout, switch, pull, merge, rebase, stash
  - Resolves "Your local changes would be overwritten by checkout" errors
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

- **0.2.0** - Skip-worktree, filter drivers, seamless branch switching
- **0.1.0** - Multi-target overrides with new config format (BREAKING)
- **0.0.7** - Custom override file naming via pattern field
- **0.0.6** - GitHub Actions release workflow
- **0.0.5** - CI badge and .gitattributes for resilience
- **0.0.4** - Community health files for public release
- **0.0.3** - Docker-based testing infrastructure and CI
- **0.0.2** - Config-driven architecture
- **0.0.1** - Initial release with full feature set

[0.4.1]: https://github.com/jonathanabila/git-override/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/jonathanabila/git-override/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/jonathanabila/git-override/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jonathanabila/git-override/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jonathanabila/git-override/compare/v0.0.7...v0.1.0
[0.0.7]: https://github.com/jonathanabila/git-override/compare/v0.0.6...v0.0.7
[0.0.6]: https://github.com/jonathanabila/git-override/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/jonathanabila/git-override/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/jonathanabila/git-override/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/jonathanabila/git-override/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/jonathanabila/git-override/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/jonathanabila/git-override/releases/tag/v0.0.1
