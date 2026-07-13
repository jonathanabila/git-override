# Agent Instructions for git-local-override

This document provides guidelines for AI agents working on the git-local-override project.

## Project Overview

git-local-override is a bash-based tool that allows users to maintain local modifications to git-tracked files without committing them. It uses git hooks to transparently manage file content based on recursive config files (`.local-overrides.yaml`) in the repository.

## Repository Structure

```
git-local-override/
├── bin/                          # Executable CLI tool
│   └── git-local-override        # Main command-line interface
├── hooks/                        # Git hook scripts
│   ├── local-override-lib.sh     # Shared library functions
│   ├── local-override-filter-smudge   # Smudge filter (checkout)
│   ├── local-override-filter-clean    # Clean filter (staging)
│   ├── local-override-post-checkout
│   ├── local-override-pre-rebase
│   ├── local-override-pre-commit
│   └── local-override-post-commit
├── shared/                       # Shared shell modules
│   ├── local-override-resolver.sh # Canonical recursive config resolver
│   └── local-override-shell-init.sh # Shell wrapper source (printed by shell-init)
├── scripts/                      # Installation and release scripts
│   ├── install.sh
│   ├── uninstall.sh
│   └── release.sh                # Changelog release prep helper
├── tests/                        # Test suite
│   ├── run-tests.sh              # Main test runner (unit suite)
│   ├── run-docker.sh             # Docker test launcher
│   ├── test-lib.sh               # Shared assertion harness (info/pass/fail, counters)
│   ├── coverage.sh               # kcov entrypoint (opt-in coverage run)
│   ├── bench-filter-process.sh   # filter.process benchmark + roundtrip harness
│   ├── docker/                   # Docker test infrastructure
│   │   ├── Dockerfile            # Ubuntu test image
│   │   ├── Dockerfile.bash3      # Bash 3.2 compatibility image
│   │   └── entrypoint.sh
│   └── integration/              # Integration tests
│       ├── test-install.sh       # Install/uninstall tests
│       ├── test-git-ops.sh       # Git operations tests
│       ├── test-precommit.sh     # Pre-commit framework tests
│       └── test-worktrees.sh     # Linked-worktree tests
├── .github/                      # GitHub configuration
│   ├── workflows/
│   │   ├── test.yml              # CI test workflow
│   │   └── release.yml           # Tag-triggered GitHub release publish
│   ├── ISSUE_TEMPLATE/           # Issue templates
│   ├── PULL_REQUEST_TEMPLATE.md
│   ├── CODEOWNERS
│   └── dependabot.yml
├── docs/                         # Additional documentation (DESIGN.md, rebase-regression-tdd-plan.md)
├── plans/                        # Implementation plans + index (plans/README.md)
├── Formula/                      # Draft Homebrew formula (unpublished)
│   └── git-local-override.rb
├── AGENTS.md                     # Canonical agent instructions (this file)
├── CLAUDE.md                     # Symlink -> AGENTS.md
├── VERSION                       # Release version file (synced by scripts/release.sh)
├── .pre-commit-hooks.yaml        # Pre-commit integration definitions
├── .pre-commit-config.yaml       # Pre-commit hooks for this repo
├── .editorconfig                 # Editor configuration
├── .gitattributes                # Line ending configuration
├── Makefile                      # Build automation
├── README.md                     # User documentation
├── CONTRIBUTING.md               # Contributor guidelines
├── CHANGELOG.md                  # Version history
├── SECURITY.md                   # Security policy
├── CODE_OF_CONDUCT.md            # Contributor code of conduct
└── LICENSE                       # MIT license
```

`coverage/` (kcov HTML output) is a gitignored build artifact, not a source
directory.

## Architecture

### Config-Driven Design

The system is config-driven, not registry-based:

1. **Config files** (`.local-overrides.yaml`): Checked into repo, discovered recursively, list files that can be overridden
2. **Local files** (`.local.*`): User creates these locally, gitignored
3. **Hooks**: Read config, apply/restore local files automatically

### No Global State

- No global registry files
- No global allowlist
- Each repo is self-contained with its own config
- Hooks are installed per-repo (via pre-commit or install script)

### Two Installation Methods

1. **Pre-commit**: Users add to `.pre-commit-config.yaml` and run `pre-commit install`
2. **Curl**: `curl ... | bash` downloads hooks directly to `.git/hooks/`

### Filter Drivers (Smudge/Clean)

git-local-override uses **smudge/clean filter drivers** (same mechanism as git-lfs and git-crypt) to make git consider overridden files "clean" during checkout/switch/merge operations:

- **Smudge**: Runs on checkout, outputs local override content to working tree
- **Clean**: Runs on staging, outputs original content from `HEAD` to git index
- **Roundtrip**: `clean(smudge(original)) == original` makes git consider files unchanged
- **Configuration**: Via `.git/info/attributes` (local, not tracked) and `git config filter.local-override.*`
- **Bypass**: Set `GIT_LOCAL_OVERRIDE_DISABLE=1` to temporarily disable filters
- **Coexistence**: Filters and hooks work together — filters handle content transformation, while hooks/CLI handle restore/reapply flows and clear legacy `skip-worktree` bits from older installs when found

## Code Guidelines

### Bash Compatibility

**Critical**: All scripts must work with Bash 3.2 (macOS default).

**Avoid these Bash 4+ features:**

```bash
# DON'T use associative arrays
declare -A myarray  # Bash 4+ only

# DON'T use lowercase/uppercase operators
${var,,}  # Bash 4+ only
${var^^}  # Bash 4+ only

# DON'T use |& for stderr piping
command |& other  # Bash 4+ only
```

**Use these alternatives:**

```bash
# Use grep for lookups instead of associative arrays
if echo "$list" | grep -qxF "$item"; then

# Use tr for case conversion
echo "$var" | tr '[:upper:]' '[:lower:]'

# Use 2>&1 | for stderr
command 2>&1 | other
```

### Script Headers

All scripts should start with:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

### Variable Naming

- Local variables: `snake_case`
- Constants: `UPPER_CASE`
- Loop variables: declare as local to prevent scope leaks

```bash
# Good - loop variable is local
local line
while IFS= read -r line; do
    process "$line"
done

# Bad - loop variable leaks to outer scope
while IFS= read -r line; do  # 'line' may overwrite caller's variable
    process "$line"
done
```

### Error Handling

```bash
# Use die() for fatal errors
die() {
    echo "Error: $*" >&2
    exit 1
}

# Use || true for acceptable failures
git checkout HEAD -- "$path" 2>/dev/null || true

# Check command success explicitly
if ! some_command; then
    die "Command failed"
fi
```

### Arithmetic with set -e

When using `((counter++))` with `set -e`, the exit code is 1 if the value before increment was 0. Use `|| true`:

```bash
((count++)) || true
```

## Testing

**IMPORTANT: Tests must be run inside Docker to ensure isolation and consistency.**

### Running Tests (Docker - Required)

```bash
# Run all tests in Docker (recommended)
make test-docker

# Run tests with bash 3.2 for macOS compatibility
make test-docker-bash3

# Run specific test suites
make test-docker-unit     # Unit tests only
make test-docker-install  # Install/uninstall tests
make test-docker-gitops   # Git operations tests
make test-docker-worktree # Linked-worktree tests
make test-docker-precommit # Pre-commit integration tests

# Match CI matrix before committing (required)
make test-docker          # All Docker suites (Linux CI equivalent)
make test-docker-bash3    # Bash compatibility suite (Bash 3.2 CI equivalent)

# If developing on macOS, also run native suites to mirror macOS CI job
make test
tests/integration/test-install.sh && tests/integration/test-git-ops.sh && tests/integration/test-precommit.sh
```

The single command that mirrors the full CI matrix is `make ci`, which runs
`lint check-docs-sync test-docker test-docker-bash3` (see the `ci` target in
the `Makefile`). Run it before committing; the individual targets above are
for selective runs.

```bash
# Full CI-equivalent suite (requires Docker) — run this before committing
make ci

# Opt-in coverage diagnostic (kcov; writes gitignored coverage/index.html; NOT a CI gate)
make coverage
```

### Running Tests Locally (Quick Check Only)

Local tests can be used for quick development iteration, but Docker tests are authoritative:

```bash
# Quick local test (for development only)
make test

# Clean test artifacts
make clean
```

### Pre-commit CI parity requirement

Before creating any commit, run the full local CI-equivalent suite and ensure all pass:

- `make ci` — the authoritative single command
  (`lint check-docs-sync test-docker test-docker-bash3`)
- On macOS: `make test` plus all integration scripts in `tests/integration/`

### Writing Tests

Add tests to `tests/run-tests.sh`:

```bash
test_my_feature() {
    info "Testing my feature..."
    cd "$TEST_REPO"

    # Ensure config exists
    create_config

    # Test
    git-local-override add somefile.md

    if [[ -f "somefile.local.md" ]]; then
        pass "Feature works correctly"
    else
        fail "Feature did not work"
    fi
}

# Don't forget to add to main():
main() {
    # ...existing tests...
    test_my_feature
}
```

The assertion harness — `info`/`pass`/`fail`, the terminal color vars, the
`TESTS_RUN`/`TESTS_PASSED`/`TESTS_FAILED` counters, and the `finish_suite`
summary/exit helper — lives once in `tests/test-lib.sh`. Suites source it and
must NOT redefine these. `tests/run-tests.sh` (the unit suite) calls `pass`
exactly once per test, so it sets `STRICT_PASS_COUNT=1` to additionally require
`TESTS_PASSED == TESTS_RUN` (a test that starts but never reaches a `pass()`
fails the build); the integration suites call `pass` once per assertion and
leave that flag off.

### Test Environment

- Tests run in an isolated environment: `tests/test-repo/`
- Config is isolated: `tests/test-config/`
- Hooks are copied directly to `.git/hooks/`
- The `XDG_CONFIG_HOME` is overridden to prevent system pollution

## Key Files to Understand

**Single-resolver rule**: `shared/local-override-resolver.sh` is the one and
only copy of the recursive config resolver. Do NOT create a copy under
`hooks/` — installers place the runtime copy into `.git/hooks/` (or the
template dir) at install time, and source-tree hooks fall back to
`../shared/` via `local-override-lib.sh`. `make lint` (part of `make ci`)
fails if a `hooks/local-override-resolver.sh` reappears.

### `hooks/local-override-lib.sh`

Shared library sourced by all hooks. Key functions:

- `get_repo_root()` - Get repository root directory
- `read_pattern()` - Read the `pattern:` field from config file
- `read_config()` - Parse recursive `.local-overrides.yaml` files, returns effective `target|override` pairs
- `get_active_overrides()` - Get files with existing override files
- `get_override_files()` - List unique override files from config
- `get_targets_for_override()` - Get all target files for a specific override
- `resolve_safe_override_for_file()` - Read-side front door (in the shared resolver): given the checkout repo root and a target path, prints the absolute override path only when a readable, symlink-safe override exists; anchors the containment check on the true resolution root
- `locate_support_file()` - Canonical dev-vs-installed fallback ladder for support files (VERSION, shell-init); lives in the shared resolver, anchored on the resolver's own location
- `configure_filter_driver()` - Single writer of the `filter.local-override.*` config (in the shared resolver): explicit scope (repo root or `global`), script dir, and mode (`scripts`|`process`); owns mode exclusivity and reads no env switches
- `apply_override_to_target()` - Write-side front door (in the shared resolver): owns both symlink gates, resolution-root anchoring for absolute override paths, the copy, and refusal logging (`loud`|`trace`); returns 0 applied / 1 skipped / 2 refused / 3 copy-failed
- `restore_target_to_head()` - Restore-side front door (in the shared resolver): owns the HEAD-existence guard, the target symlink gate, mode-proof filter suppression (`GIT_LOCAL_OVERRIDE_DISABLE=1`, which covers both scripts and process modes), and the unconditional worktree write (blob redirect, never `git checkout`, which no-ops on stat-clean applied overrides); modes `worktree` (working tree only) | `full` (working tree + index); returns 0 restored / 1 skipped (not in HEAD) / 2 refused / 3 failed
- `override_path_is_symlink_safe()` - Read-side symlink gate for override files (in the shared resolver): delegates to `path_is_symlink_safe` for regular paths; follows a symlinked override only when the user set `git config --local local-override.followSymlinkedOverrides true` AND the symlink is untracked AND it resolves to a regular file. Targets (write side) never use it.
- `validate_config()` - Validate config format and check for duplicate targets

### `hooks/local-override-post-checkout`

Called by git after branch checkouts (not file checkouts). Key behavior:

- Only runs on branch checkouts (3rd arg = 1)
- Reads config and applies any existing `.local` files
- Fast exit if no config file

### `hooks/local-override-pre-commit`

Called before commit. Key behavior:

- Checks if staged files have local overrides
- **Grouped restore**: If ANY target in a group is staged, ALL targets in that group are restored
- The decisions live in the shared resolver as directly testable functions — `precommit_plan_restores` (grouped-restore plan), `staged_blob_matches_override` (byte-exact leak predicate), `precommit_find_merge_leak` (merge/cherry-pick backstop) — the hook keeps only git mutations and messages
- Restores original content from git
- Re-stages the restored content
- **Merge/cherry-pick guard**: during an in-progress merge or cherry-pick (MERGE_HEAD / CHERRY_PICK_HEAD present — `is_merge_or_cherry_pick_in_progress` in the shared resolver), the HEAD-restore is skipped so genuine conflict resolutions and `merge --no-commit` changes survive into the commit; instead, a byte-exact backstop refuses the commit if a staged managed target's blob is identical to its override file (the blind-`git add`-of-override-content case: unmerged paths make the clean filter pass bytes through). No reapply state is written on this path (nothing was restored)

### `hooks/local-override-pre-rebase`

Called before `git rebase`. Key behavior:

- Clears legacy skip-worktree bits on configured target files when present
- Restores original tracked content for configured targets before rebase starts
- Prevents rebase checkout/detach failures like "local changes would be overwritten by checkout"
- Fast exit if no config file

### `hooks/local-override-post-commit`

Called after commit. Re-applies local overrides.

### `hooks/local-override-filter-smudge`

Standalone smudge filter script called by git during checkout. Key behavior:

- Receives original blob content on stdin, filename as $1 (%f)
- Outputs .local override content if exists, else passthrough
- Respects GIT_LOCAL_OVERRIDE_DISABLE=1

### `hooks/local-override-filter-clean`

Standalone clean filter script called by git during staging. Key behavior:

- Receives working tree content on stdin, filename as $1 (%f)
- Outputs original content from git HEAD if override exists, else passthrough
- Falls back to passthrough when HEAD doesn't exist
- Respects GIT_LOCAL_OVERRIDE_DISABLE=1

### `bin/git-local-override`

Optional CLI tool. Key functions:

- `cmd_add()` - Create local override file
- `cmd_remove()` - Remove override, restore original
- `cmd_list()` - Show configured files and status
- `cmd_status()` - Show detailed system status (config, hooks, pattern, filter status)
- `cmd_apply()` - Manually apply all overrides using the shared recursive resolver (`--all-worktrees` applies across every linked worktree)
- `cmd_restore()` - Manually restore all originals (`--all-worktrees` restores across every linked worktree)
- `cmd_sync_filters()` - Sync filter configuration with the effective recursive config and clear legacy managed `skip-worktree` bits
- `cmd_validate()` - Read-only config validation (CI-friendly); reuses the resolver's `validate_config`
- `cmd_doctor()` - Read-only diagnostics; `--fix` repairs a missing filter driver by delegating to `cmd_sync_filters`; also classifies symlinked overrides (followed / ignored / tracked-refused / dangling) against the `local-override.followSymlinkedOverrides` opt-in
- `cmd_shell_init()` - Print the shell wrapper (content lives in `shared/local-override-shell-init.sh`, installed to the CLI data dir)
- `cmd_version()` - Print the version, read from the `VERSION` file (repo checkout or installed support dir)
- `cmd_filter_smudge()` - Internal: smudge filter for git filter driver
- `cmd_filter_clean()` - Internal: clean filter for git filter driver
- `cmd_init_config()` - Create a `.local-overrides.yaml` template
- The CLI loads `shared/local-override-resolver.sh` from the repo checkout during development or its installed support directory at runtime

## Common Tasks

### Adding a New Command

1. Add `cmd_newcommand()` function in `bin/git-local-override`
2. Add case in `main()` switch
3. Update help text in `cmd_help()`
4. Add test in `tests/run-tests.sh`
5. Update `README.md` (the CLI Commands table — `make check-docs-sync` enforces coverage)
6. Update this file (`AGENTS.md`) — the "Key Files … `bin/git-local-override`" list

### Modifying Hook Behavior

1. Edit the appropriate hook in `hooks/`
2. If modifying shared code, update `local-override-lib.sh`
3. Test with `make test`
4. Verify bash 3.2 compatibility
5. Update documentation if behavior changes

## Debugging Tips

### Enable Trace Mode

```bash
# In any script, add at the top:
set -x  # Print commands as they execute

# Or run with bash -x:
bash -x bin/git-local-override add file.md
```

### Test Hook Execution

```bash
# Manually run post-checkout hook (branch checkout mode)
.git/hooks/post-checkout "" "" "1"

# Manually run pre-commit hook
.git/hooks/pre-commit

# Manually run pre-rebase hook
.git/hooks/pre-rebase

# Manually run post-commit hook
.git/hooks/post-commit
```

### Check Config Parsing

```bash
# Add debug output to read_config():
echo "DEBUG: file=$file" >&2
```

### Disable Filter Drivers

```bash
# Temporarily bypass filter drivers
GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- AGENTS.md

# Check filter configuration
git config --local filter.local-override.smudge
git config --local filter.local-override.clean
cat .git/info/attributes
```

## Performance Considerations

- Hooks must complete in < 100ms for typical usage
- Use early exits: `[[ -f "$config" ]] || exit 0`
- Avoid subshells in loops when possible
- Config parsing is O(n) where n = number of lines

## Security Notes

- Never execute user-provided paths without validation
- Config file is checked into repo - maintainer controls it
- Local files (`.local.*`) are user-controlled but gitignored
- Paths must be within repository root

## Changelog Maintenance

**Important**: Every time you make changes to this project, update `CHANGELOG.md`:

1. Add your changes under the `[Unreleased]` section at the top
2. Use categories: `Added`, `Changed`, `Fixed`, `Removed`, `Deprecated`, `Security`
3. Follow [Keep a Changelog](https://keepachangelog.com/) format
4. Be specific about what changed and why

Example:

```markdown
## [Unreleased]

### Added
- New `foo` command for doing X

### Fixed
- Bug where Y happened when Z
```

**Releases are prepared locally from `[Unreleased]`, then published by GitHub Actions when maintainers push a signed annotated `vX.Y.Z` tag from `origin/main`.**

When preparing a new tagged release, keep the checked-in `VERSION` file in sync with the release tag. The release prep flow should update both `CHANGELOG.md` and `VERSION` together before the signed release commit and annotated `vX.Y.Z` tag are created.
