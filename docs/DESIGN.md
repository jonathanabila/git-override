# Local Override System - Hooks Solution

## Problem Statement

Users need to customize tracked files (e.g., `AGENTS.md`, `CLAUDE.md`) locally without:
1. Accidentally committing their local changes
2. Having local changes appear in `git status`/`git diff`
3. Disrupting their normal git workflow

## Solution Overview

A git hooks-based system using `post-checkout` and `pre-commit` hooks that:
- Applies local overrides to the working tree after checkout operations
- Restores original content before commits to prevent accidental commits
- Maintains a registry of override files for O(1) lookup instead of filesystem scans

## Design Principles

1. **Speed first**: Hooks must complete in <100ms for typical usage
2. **Invisible when unused**: Zero overhead if no local overrides exist
3. **Fail-safe**: If anything goes wrong, default to normal git behavior
4. **Simple mental model**: `<file>.local.<ext>` next to `<file>.<ext>` = override active
5. **Allowlist-based**: Only files matching configured patterns can be overridden

## Architecture

```
~/.config/git/
├── hooks/
│   ├── local-override-post-checkout   # Applies overrides after checkout
│   └── local-override-pre-commit      # Restores originals before commit
└── local-overrides/
    ├── allowlist                      # Global allowlist patterns
    └── <repo-hash>.list               # Registry of override paths per repo
```

Repository:
```
.git/
├── hooks/
│   ├── post-checkout             # Our hook prepended, then existing hooks
│   └── pre-commit                # Our hook prepended, then existing hooks
└── info/
    └── local-override-originals/ # Cached original content (optional optimization)
```

## Allowlist Configuration

Only files matching configured patterns can have local overrides. This prevents accidental overrides of arbitrary files.

### Global Allowlist

```
# ~/.config/git/local-overrides/allowlist
# Glob patterns for files that can be overridden (one per line)
**/AGENTS.md
**/CLAUDE.md
CLAUDE.md
```

### Per-Repository Allowlist (optional)

Repositories can extend the global allowlist:

```
# .git/info/local-override-allowlist
# Additional patterns for this repo only
config/settings.json
```

### Pattern Matching

- Uses glob syntax (same as `.gitignore`)
- `**/` matches any directory depth
- Patterns are matched against repo-relative paths
- A file must match at least one pattern to be eligible for override

### CLI Enforcement

```bash
# Succeeds - matches **/AGENTS.md
git-local-override add backend/services/foo/AGENTS.md

# Fails - no matching pattern
git-local-override add package.json
# Error: 'package.json' does not match any allowlist pattern.
# To add a pattern, edit ~/.config/git/local-overrides/allowlist

# Manage allowlist
git-local-override allowlist add '*.config.js'
git-local-override allowlist remove '*.config.js'
git-local-override allowlist list
```

## File Registry System

### Why a Registry?

Scanning the filesystem on every checkout is slow. Instead:
- Maintain a simple text file listing paths with active overrides
- Update registry only when user explicitly adds/removes overrides
- Hooks read registry in O(n) where n = number of overrides (typically <10)

### Registry Format

```
# ~/.config/git/local-overrides/<repo-hash>.list
# One path per line, relative to repo root
backend/python/services/foo/AGENTS.md
backend/python/services/bar/AGENTS.md
CLAUDE.md
config/settings.json
```

### Local File Naming Convention

For any tracked file, the local override uses `.local` inserted before the extension:

| Original File | Local Override |
|---------------|----------------|
| `AGENTS.md` | `AGENTS.local.md` |
| `CLAUDE.md` | `CLAUDE.local.md` |
| `config.json` | `config.local.json` |
| `settings.yaml` | `settings.local.yaml` |
| `Makefile` | `Makefile.local` |

### Registry Management Commands

```bash
# Add an override (creates .local file if needed, updates registry)
git-local-override add path/to/file

# Remove an override (optionally deletes .local file, updates registry)
git-local-override remove path/to/file

# List active overrides in current repo
git-local-override list

# Sync registry (scan for .local files, rebuild registry)
git-local-override sync
```

## Hook Behaviors

### post-checkout Hook

**Trigger**: After `git checkout`, `git switch`, `git clone`, `git pull` (with checkout)

**Algorithm**:
```
1. Check if registry file exists for this repo
   - If not: exit 0 (no overrides configured)

2. Read registry file (list of paths)
   - If empty: exit 0

3. For each path in registry:
   a. Compute local override path (insert .local before extension)
   b. Verify local override file still exists
      - If not: remove from registry, continue
   c. Copy local override content → original file

4. Exit 0 (never fail checkout)
```

**Performance target**: <50ms for 10 overrides

### pre-commit Hook

**Trigger**: Before `git commit`

**Algorithm**:
```
1. Check if registry file exists
   - If not: exit 0

2. Get list of staged files: git diff --cached --name-only

3. For each path in registry:
   - If path is in staged files:
     a. Restore original from git: git show HEAD:<path> > <path>
     b. Re-stage the file: git add <path>
     c. Mark for post-commit restoration

4. Exit 0
```

### post-commit Hook

**Trigger**: After `git commit` completes

**Algorithm**:
```
1. Re-apply all overrides from registry (same as post-checkout)
```

This ensures local overrides are restored immediately after commit completes.

**Performance target**: <100ms for typical commits

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| New file (not in HEAD) | Skip restoration, allow commit of new file |
| Merge conflict in overridden file | Don't interfere, let user resolve normally |
| User explicitly wants to commit changes | Use `--no-verify` escape hatch (standard git) |
| Registry lists file that no longer exists | Remove from registry, continue |
| Local override deleted but registry not updated | Remove from registry, continue |
| File has no extension (e.g., `Makefile`) | Local override is `Makefile.local` |

## Hook Chaining

When installing hooks, we must preserve existing hooks. Our hooks run **first**, then chain to existing hooks.

### Installation Strategy

```bash
# For each hook type (post-checkout, pre-commit, post-commit):

1. If .git/hooks/<hook> exists:
   a. Rename to .git/hooks/<hook>.chained
   b. Create new .git/hooks/<hook> that:
      - Runs our logic first
      - Then executes .git/hooks/<hook>.chained with same args
      - Propagates exit code from chained hook

2. If .git/hooks/<hook> does not exist:
   a. Create .git/hooks/<hook> with just our logic
```

### Hook Template

```bash
#!/bin/bash
# Local override hook - runs first, then chains to existing hook

# === Our logic ===
~/.config/git/hooks/local-override-<hook-type> "$@"

# === Chain to existing hook ===
if [[ -x ".git/hooks/<hook-type>.chained" ]]; then
    exec ".git/hooks/<hook-type>.chained" "$@"
fi
```

### Why Run First?

Running our hook first ensures:
1. Local overrides are applied before other hooks see the files
2. Pre-commit restores originals before linters/formatters run on them
3. Other hooks operate on the "real" committed content, not local overrides

## User Workflow

### Initial Setup (one-time global)

```bash
# Install global hook scripts and CLI tool
./install-local-override.sh
```

### Per-Repository Setup (one-time per repo)

```bash
# Enable hooks in this repository (creates/chains hooks)
git-local-override init
```

### Daily Usage

```bash
# Create a local override for any tracked file
git-local-override add backend/python/services/foo/AGENTS.md
# Creates AGENTS.local.md with copy of original, opens in $EDITOR

# Edit your local version anytime
vim backend/python/services/foo/AGENTS.local.md

# Work normally - git status won't show the file as modified
git status  # clean (original content preserved in git's view)

# Commits work normally - original content is committed
git commit -m "..."

# After commit, your local override is automatically restored
cat backend/python/services/foo/AGENTS.md  # shows your local content

# Remove an override when done
git-local-override remove backend/python/services/foo/AGENTS.md

# Other examples:
git-local-override add CLAUDE.md
git-local-override add config/settings.json
git-local-override list  # see all active overrides
```

## Performance Analysis

### Worst Case: post-checkout with 20 overrides

```
Read registry file:           ~1ms
Loop 20 files:
  - Check .local file exists: ~0.5ms × 20 = 10ms
  - Copy file content:        ~1ms × 20 = 20ms
Total:                        ~31ms ✓
```

### Worst Case: pre-commit with 100 staged files, 10 overrides

```
Read registry file:           ~1ms
Get staged files (git):       ~10ms
Set intersection:             ~0.1ms
Restore 2 matched files:
  - git show:                 ~5ms × 2 = 10ms
  - Write + stage:            ~2ms × 2 = 4ms
Total:                        ~25ms ✓
```

### Optimization: Skip Entirely When No Overrides

```bash
# First line of every hook:
[[ -f "$REGISTRY_FILE" ]] || exit 0
```

If no registry exists, hooks exit in <1ms.

## Security Considerations

1. **No arbitrary code execution**: Hooks only read/write specific files
2. **Path validation**: All paths validated to be within repo root
3. **No secrets in registry**: Registry only contains relative paths
4. **Gitignore pattern**: `*.local.*` added to global gitignore

## Global Gitignore

The installer adds a pattern to ignore all local override files:

```bash
# Added to ~/.config/git/ignore (or existing core.excludesfile)
*.local.*
*.local
```

This covers:
- `AGENTS.local.md`
- `CLAUDE.local.md`
- `config.local.json`
- `Makefile.local`

Note: The gitignore pattern is intentionally broad. The allowlist controls which files the system actively manages; the gitignore just ensures local files are never accidentally committed.

## Installation Deliverables

```
install-local-override.sh     # Main installer
uninstall-local-override.sh   # Clean removal

~/.local/bin/
└── git-local-override        # CLI tool (add/remove/list/sync/init/allowlist)

~/.config/git/
├── hooks/
│   ├── local-override-post-checkout
│   ├── local-override-pre-commit
│   └── local-override-post-commit
├── local-overrides/
│   ├── allowlist             # Global allowlist (default: **/AGENTS.md, **/CLAUDE.md)
│   └── <repo-hash>.list      # Per-repo registry files
└── ignore                    # Global gitignore (*.local.* pattern)
```
