# Agent Instructions for git-local-override

This document provides guidelines for AI agents working on the git-local-override project.

## Project Overview

git-local-override is a bash-based tool that allows users to maintain local modifications to git-tracked files without committing them. It uses git hooks to transparently manage file content based on a config file (`.local-overrides.yaml`) in the repository.

## Repository Structure

```
git-local-override/
├── bin/                          # Executable CLI tool
│   └── git-local-override        # Main command-line interface
├── hooks/                        # Git hook scripts
│   ├── local-override-lib.sh     # Shared library functions
│   ├── local-override-post-checkout
│   ├── local-override-pre-commit
│   └── local-override-post-commit
├── scripts/                      # Installation scripts
│   ├── install.sh
│   └── uninstall.sh
├── tests/                        # Test suite
│   └── run-tests.sh              # Main test runner
├── docs/                         # Additional documentation
│   └── DESIGN.md                 # Original design specification
├── .pre-commit-hooks.yaml        # Pre-commit integration definitions
├── .pre-commit-config.yaml       # Pre-commit hooks for this repo
├── Makefile                      # Build automation
├── README.md                     # User documentation
├── CONTRIBUTING.md               # Contributor guidelines
├── CHANGELOG.md                  # Version history
└── LICENSE                       # MIT license
```

## Architecture

### Config-Driven Design

The system is config-driven, not registry-based:

1. **Config file** (`.local-overrides.yaml`): Checked into repo, lists files that can be overridden
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
make test-docker-precommit # Pre-commit integration tests
```

### Running Tests Locally (Quick Check Only)

Local tests can be used for quick development iteration, but Docker tests are authoritative:

```bash
# Quick local test (for development only)
make test

# Clean test artifacts
make clean
```

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

### Test Environment

- Tests run in an isolated environment: `tests/test-repo/`
- Config is isolated: `tests/test-config/`
- Hooks are copied directly to `.git/hooks/`
- The `XDG_CONFIG_HOME` is overridden to prevent system pollution

## Key Files to Understand

### `hooks/local-override-lib.sh`

Shared library sourced by all hooks. Key functions:

- `get_repo_root()` - Get repository root directory
- `read_pattern()` - Read the `pattern:` field from config file
- `read_config()` - Parse `.local-overrides.yaml`, returns `target|override` pairs
- `get_active_overrides()` - Get files with existing override files
- `get_override_files()` - List unique override files from config
- `get_targets_for_override()` - Get all target files for a specific override
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
- Restores original content from git
- Re-stages the restored content

### `hooks/local-override-post-commit`

Called after commit. Re-applies local overrides.

### `bin/git-local-override`

Optional CLI tool. Key functions:

- `cmd_add()` - Create local override file
- `cmd_remove()` - Remove override, restore original
- `cmd_list()` - Show configured files and status
- `cmd_status()` - Show detailed system status (config, hooks, pattern)
- `cmd_apply()` - Manually apply all overrides (sets skip-worktree)
- `cmd_restore()` - Manually restore all originals (clears skip-worktree)
- `cmd_init_config()` - Create a `.local-overrides.yaml` template
- `read_config()` - Parse config file (duplicated from lib for standalone operation)

## Common Tasks

### Adding a New Command

1. Add `cmd_newcommand()` function in `bin/git-local-override`
2. Add case in `main()` switch
3. Update help text in `cmd_help()`
4. Add test in `tests/run-tests.sh`
5. Update `README.md`

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

# Manually run post-commit hook
.git/hooks/post-commit
```

### Check Config Parsing

```bash
# Add debug output to read_config():
echo "DEBUG: file=$file" >&2
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

**Version numbers are assigned automatically during release via GitHub Actions.**
