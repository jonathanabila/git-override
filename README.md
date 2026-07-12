**Keep local edits to tracked files without ever committing them.**

git-local-override lets you customize tracked files — `CLAUDE.md`, `AGENTS.md`,
config files — on your machine while git's view stays unchanged. Your edits live
in a gitignored `.local` file, so the tracked file shows your content in the
working tree but stays invisible to `git status` and safe from accidental
commits. No `git stash` juggling, no fragile `.gitignore` hacks.

> The GitHub repository is named
> [`git-override`](https://github.com/jonathanabila/git-override); the tool and
> CLI are called `git-local-override`.

## Quick Start

Install the hooks plus the CLI into the current repository:

```bash
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash -s -- --cli
```

Then set up a repo in three steps:

1. Create `.local-overrides.yaml` in the repo root (or run
   `git-local-override init-config` for a template):

   ```yaml
   # .local-overrides.yaml
   pattern: ".local"   # Required: suffix used to name override files
   files:
     - override: CLAUDE.local.md
       replaces:
         - CLAUDE.md
   ```

2. Create your local override file: `cp CLAUDE.md CLAUDE.local.md`, then edit it.
3. That's it — your local content is active and protected from commits.

For large monorepos, also install [`fd`](https://github.com/sharkdp/fd)
(`brew install fd`; on Debian/Ubuntu install `fd-find` and expose it as `fd` on
`PATH`). `git-local-override` uses it automatically for much faster
`.local-overrides.yaml` discovery.

<details>
<summary>Other install options</summary>

**Pre-commit** (recommended for teams) — add to `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/jonathanabila/git-override
    rev: v0.7.0  # Use the latest version
    hooks:
      - id: local-override-pre-commit
      - id: local-override-post-commit
      - id: local-override-post-checkout
      - id: local-override-pre-rebase
```

Then run `pre-commit install --hook-type pre-commit --hook-type post-commit
--hook-type post-checkout --hook-type pre-rebase`.

**Global install** (hooks for every new repo, via the git template dir):

```bash
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash -s -- --global --cli
```

**Pin to a specific version:**

```bash
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/v0.7.0/scripts/install.sh | bash -s -- --cli
```

Re-running the install one-liner in an existing repo is the supported upgrade
path.

</details>

## How It Works

git-local-override uses **smudge/clean filter drivers** — the same mechanism as
git-lfs and git-crypt — together with four git hooks. The filters transform file
content transparently; the roundtrip property `clean(smudge(original)) ==
original` makes git consider overridden files unchanged, so checkout, switch,
pull, merge, rebase, and stash all succeed. Filters are configured during
install in `.git/info/attributes` (local-only, not tracked).

| Git Operation | Hook / Filter | What Happens |
|---------------|---------------|--------------|
| `git checkout` | post-checkout | Applies local overrides to working tree |
| `git checkout` | filter driver (smudge) | Transparently applies local override content |
| `git pull` | post-checkout | Applies local overrides after merge |
| `git rebase` | pre-rebase | Restores originals before rebase checkout/detach |
| `git commit` | pre-commit | Restores originals, stages them |
| `git add` / staging | filter driver (clean) | Presents original content to git index |
| After commit | post-commit | Re-applies local overrides |

### Linked worktrees

The filter commands use worktree-safe absolute paths, so linked worktrees
(`git worktree add`) work correctly. A worktree with no `.local-overrides.yaml`
of its own inherits the main worktree's config and overrides automatically. A
worktree-local config always wins, all-or-nothing — the two roots are never
merged. Set `GIT_LOCAL_OVERRIDE_DISABLE_WORKTREE_FALLBACK=1` to disable the
fallback. After editing an override file, refresh every checkout at once with
`git-local-override apply --all-worktrees` (or restore originals everywhere with
`git-local-override restore --all-worktrees`).

### Shell integration

On git 2.37+, `git checkout` can fail with "Your local changes would be
overwritten" when overridden files differ between branches. Add a shell wrapper
that restores originals before the operation, then lets the smudge filter
re-apply overrides on the new branch:

```bash
# Add to ~/.bashrc or ~/.zshrc:
eval "$(git-local-override shell-init)"
```

The wrapper intercepts `git checkout` and `git switch`. File checkouts
(`git checkout -- <file>`) are not intercepted.

## Configuration

Create `.local-overrides.yaml` in your repository root:

```yaml
# .local-overrides.yaml
pattern: ".local"   # Required: used to generate override names
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
```

**Multi-target overrides** — one override file can replace multiple tracked
files. When you commit, if any file in a group is staged, all files in that
group are restored so they stay consistent:

```yaml
files:
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
      - CLAUDE.md   # Both files get content from AGENTS.local.md
```

**Recursive configs** — `git-local-override` discovers `.local-overrides.yaml`
files recursively:

- The nearest config owns its directory subtree
- A child config fully replaces parent behavior for that subtree
- Paths inside a nested config are resolved relative to that config's directory
- A child config inherits `pattern:` from the nearest ancestor config if it does
  not define its own
- Parent configs may not keep targeting files inside a child-owned subtree
- An empty child config still claims its subtree and blocks parent targets there
- A deeper config can still take ownership below an empty child config

For example, a root config using `pattern: ".local"` for `CLAUDE.md` plus a
`backend/.local-overrides.yaml` using `pattern: ".private"` means root
`CLAUDE.md` uses `CLAUDE.local.md`, `backend/CLAUDE.md` uses
`backend/CLAUDE.private.md`, and the root config no longer applies inside
`backend/`.

**File naming convention** — override files insert the pattern before the
extension:

| Pattern | Original File | Override File |
|---------|---------------|---------------|
| `.local` | `CLAUDE.md` | `CLAUDE.local.md` |
| `.override` | `config.json` | `config.override.json` |
| `.local` | `Makefile` | `Makefile.local` |

**Security** — in a repository you don't fully trust, review every
`.local-overrides.yaml` before installing: discovery is recursive and includes
untracked configs, not just the root one. Symlinked targets and symlinked
override files are rejected.

## CLI Commands

The CLI ships with the default install:

| Command | Description |
|---------|-------------|
| `git-local-override add <path>` | Create a local override file |
| `git-local-override remove [-d] <path>` | Remove override (`-d` also deletes the local file) |
| `git-local-override list` | List configured overrides and status |
| `git-local-override status` | Show detailed system status |
| `git-local-override apply` | Apply all overrides (`--all-worktrees` across every linked worktree) |
| `git-local-override restore` | Restore all originals (`--all-worktrees` across every linked worktree) |
| `git-local-override sync-filters` | Sync filter config and clear legacy managed `skip-worktree` bits |
| `git-local-override validate` | Validate all `.local-overrides.yaml` files (read-only; CI-friendly) |
| `git-local-override doctor [--fix]` | Diagnose common issues (read-only); `--fix` repairs a missing filter driver |
| `git-local-override shell-init` | Output shell wrapper for transparent checkout/switch |
| `git-local-override init-config` | Create a `.local-overrides.yaml` template |
| `git-local-override version` | Show the CLI version |
| `git-local-override help` | Show help |

`git-local-override validate` runs the same checks the hooks use — duplicate
targets, subtree escapes, path traversal — against every discovered config
**without touching git state**. It exits `0` with a summary when the config is
well-formed and non-zero (printing the offending error) otherwise, so it is safe
to run in a CI pipeline (`run: git-local-override validate`).

## Flags & Environment Variables

### Installer flags

Pass these to `install.sh` (after `bash -s --`):

| Flag | What it does |
|------|--------------|
| `--repo` | Default. Install hooks and the filter driver into the current repository |
| `--global` | Install hooks to the git template dir (`~/.config/git/template/hooks/`) so new repos get them |
| `--cli` | Also install the CLI to `~/.local/bin` plus support files to `~/.local/share/git-local-override` |
| `--resolve-ambiguous-hooks` | Repair mode: reconcile an unmanaged hook plus a stale `*.chained` backup, with timestamped backups |
| `--help`, `-h` | Print usage and exit |

Both modes also add `*.local.*` to the global gitignore.

### Command flags

| Flag | Command | What it does |
|------|---------|--------------|
| `-d`, `--delete` | `remove` | Also delete the local override file, not just stop managing it |
| `--all-worktrees` | `apply`, `restore` | Run across the main checkout and every linked worktree |
| `--fix` | `doctor` | Apply the one proven repair — a missing filter driver — by delegating to `sync-filters` |
| `version`, `--version` | (top level) | Print the CLI version |

### Environment variables

| Variable | Effect |
|----------|--------|
| `GIT_LOCAL_OVERRIDE_DISABLE=1` | Bypass the smudge/clean filters and pre-commit override handling — get the true original content (debugging) |
| `GIT_LOCAL_OVERRIDE_TRACE=1` | Emit verbose timing/lifecycle trace to stderr from hooks, filters, and `apply` (includes `discover_config_files strategy=fd\|git` lines) |
| `GIT_LOCAL_OVERRIDE_DISABLE_WORKTREE_FALLBACK=1` | Disable a linked worktree inheriting the main worktree's config/overrides |

**Tip:** to commit your local content intentionally, bypass the pre-commit hook
with `git commit --no-verify`.

## Troubleshooting

Start with the diagnostic, which checks config, hooks, the filter driver,
attributes, and legacy state, then prints a pass/warn/fail report and exits
non-zero on any failure:

```bash
git-local-override doctor        # diagnose (read-only)
git-local-override doctor --fix  # apply the safe repair (missing filter driver)
```

**Overrides not appearing.** Re-apply manually with `git-local-override apply`.
Check hook installation with `git-local-override status`.

**"Local changes would be overwritten by checkout."** Re-sync the filter driver
with `git-local-override sync-filters`. In linked worktrees this also migrates
relative `.git/hooks/...` filter commands to the worktree-safe absolute-path
form. If failures happen specifically during rebase, make sure your install
includes the `pre-rebase` hook (re-run install or `pre-commit install
--hook-type pre-rebase`).

**Slow in a large monorepo.** Install `fd` and rerun. Confirm the discovery
strategy with `GIT_LOCAL_OVERRIDE_TRACE=1 git-local-override apply` and look for
the `discover_config_files strategy=` line: `strategy=fd` is the fast path,
`strategy=git` is the slower fallback.

**New hooks not working after a project update (curl install).** The curl method
writes hooks into `.git/hooks/` at install time, so re-run the install one-liner
to pick up new hooks — the supported, safe upgrade path (managed wrappers are
refreshed, `*.chained` backups preserved, filter config re-synced). If install
warns about an ambiguous hook state, re-run with `--resolve-ambiguous-hooks`. To
remove all repo state, run `./scripts/uninstall.sh` from inside the repository.

## What Gets Installed

| Location | What | Purpose |
|----------|------|---------|
| `.git/hooks/pre-commit` | Hook script | Restores originals before commit |
| `.git/hooks/pre-rebase` | Hook script | Restores originals before rebase |
| `.git/hooks/post-commit` | Hook script | Re-applies overrides after commit |
| `.git/hooks/post-checkout` | Hook script | Applies overrides after checkout |
| `.git/hooks/local-override-filter-smudge` | Filter script | Applies local content on checkout |
| `.git/hooks/local-override-filter-clean` | Filter script | Presents original content to git |
| `.git/hooks/local-override-lib.sh` | Shared library | Common functions for hooks |
| `.git/hooks/local-override-resolver.sh` | Shared resolver | Recursive config discovery and lookup |
| `.git/hooks/*.chained` | Backup | Your existing hooks (preserved) |
| `.git/info/attributes` | Filter config | Maps files to the filter driver (local only) |
| `git config filter.local-override.*` | Git config | Filter commands pointing to absolute hook paths |
| `~/.config/git/ignore` | Gitignore patterns | Ignores `*.local.*` files globally |

With `--global`: also installs to `~/.config/git/template/hooks/` for new repos.
With `--cli`: installs the CLI to `~/.local/bin/git-local-override` and its
support files — `local-override-resolver.sh`, `local-override-shell-init.sh`,
and `VERSION` — to `~/.local/share/git-local-override`.

## Requirements

- **Bash** 3.2+ (macOS default) or Bash 4+
- **Git** 2.0+
- Standard Unix tools: `grep`, `cp`, `mv`, `mkdir`, `chmod`, `dirname`, `basename`
- `curl` (for remote installation only)
- Optional but strongly recommended for large monorepos: `fd` on `PATH`

## Development

`make ci` runs the full gate (lint, resolver-sync, and the Docker test matrix);
`make test` is the quick local check. See [CONTRIBUTING.md](CONTRIBUTING.md) and
[AGENTS.md](AGENTS.md) for contributor and architecture detail.

## License

MIT — see [LICENSE](LICENSE).
