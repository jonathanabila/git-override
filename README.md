<div align="center">
  <h1>🔒 git-local-override</h1>
  <p><strong>Keep your local changes invisible to git—forever clean status, zero accidental commits.</strong></p>

  <p>
    <a href="https://github.com/jonathanabila/git-override/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
    <a href="https://github.com/jonathanabila/git-override/releases"><img src="https://img.shields.io/github/v/release/jonathanabila/git-override" alt="Release"></a>
    <a href="https://github.com/jonathanabila/git-override/stargazers"><img src="https://img.shields.io/github/stars/jonathanabila/git-override" alt="Stars"></a>
    <a href="https://github.com/jonathanabila/git-override/actions/workflows/test.yml"><img src="https://github.com/jonathanabila/git-override/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
    <a href="https://github.com/jonathanabila/git-override/issues"><img src="https://img.shields.io/github/issues/jonathanabila/git-override" alt="Issues"></a>
  </p>

  <p>
    <a href="#-quick-start">Quick Start</a> •
    <a href="#%EF%B8%8F-how-it-works">How It Works</a> •
    <a href="#-configuration">Configuration</a> •
    <a href="#%EF%B8%8F-cli-commands">CLI Commands</a> •
    <a href="#-troubleshooting">Troubleshooting</a> •
    <a href="#-for-ai-assistants">For AI</a>
  </p>
</div>

<br>

> **Note**: The GitHub repository is named [`git-override`](https://github.com/jonathanabila/git-override), but the tool/CLI is called `git-local-override`.

---

## 🤖 For AI Assistants

<details>
<summary><strong>AI/LLM Agent Installation Instructions</strong></summary>

If you are an AI assistant (Claude, GPT, Gemini, etc.) and a user asks you to install git-local-override, follow these steps:

### Step 1: Install the hooks

Run the installation script in the user's repository:

```bash
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash -s -- --cli
```

This installs the git hooks to the current repository and the `git-local-override` CLI to `~/.local/bin`.

### Step 2: Create the config file

Create `.local-overrides.yaml` in the repository root, or inside a subtree you want to own independently:

```yaml
# .local-overrides.yaml
pattern: ".local"   # Required: suffix for override files
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
  # Add other files the user wants to customize locally
```

**Multi-target override** (one file replaces many):
```yaml
files:
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
      - CLAUDE.md   # Both files get the same content
```

### Step 3: Create local override files

For each file the user wants to customize, copy it using the configured pattern (e.g., `.local`):

```bash
# Example: cp CLAUDE.md CLAUDE.local.md
cp <original-file> <file>.<pattern>.<ext>
```

The naming convention inserts the pattern before the extension:
- `CLAUDE.md` → `CLAUDE.local.md` (with pattern: ".local")
- `config.json` → `config.override.json` (with pattern: ".override")
- `Makefile` → `Makefile.local`

### Step 4: Add gitignore pattern

Ensure `.local.*` files are gitignored. The installer adds this globally, but you can also add to the repo's `.gitignore`:

```
*.local.*
```

### Verification

Run `git-local-override status` (if CLI installed) or check that:
- `.git/hooks/pre-commit` exists and contains "local-override"
- `git config --local filter.local-override.smudge` returns a path (filter driver configured)

Security note:
- Review all `.local-overrides.yaml` files in the repository, not just the root one.
- Current recursive discovery includes nested configs from tracked and untracked files.
- Do not rely on symlinked managed targets or symlinked override files when repository-boundary guarantees matter.

### Key Behavior

- **On commit**: Original file content is committed (local changes are protected)
- **On checkout/pull**: Local overrides are automatically reapplied
- **On branch switch**: Filter drivers ensure seamless switching even when overridden files differ between branches
- **git status**: Always clean—local modifications are invisible to git

</details>

<details>
<summary><strong>Trace Checkout Hook Execution</strong></summary>

Branch checkouts now emit lifecycle logs to stderr when the `post-checkout` hook runs:

```text
git-local-override: post-checkout started
git-local-override: post-checkout finished
```

For deeper branch-switch debugging, set `GIT_LOCAL_OVERRIDE_TRACE=1` before checkout to log hook timing and smudge filter start/end events per file:

```bash
GIT_LOCAL_OVERRIDE_TRACE=1 git checkout dev
```

When managed targets are already synced in `.git/info/attributes` and no `.local-overrides.yaml` changed across the checkout, the common `post-checkout` fast path now avoids full recursive config discovery entirely. Trace output in that case should show the lifecycle logs without any `discover_config_files strategy=` line.

The CLI `apply` command now also prints step-by-step progress so long recursive config validation or attribute sync work is visible while it runs.

</details>

---

## ✨ What It Does

git-local-override lets you customize tracked files (like `CLAUDE.md`, `AGENTS.md`, or config files) **locally** while keeping git's view unchanged. Your modifications stay on your machine—invisible to `git status` and safe from accidental commits.

```
┌─────────────────────────────────────────────────────────┐
│                     Your Workflow                       │
├─────────────────────────────────────────────────────────┤
│                                                         │
│   CLAUDE.md          ←  What git sees (original)        │
│   CLAUDE.local.md    ←  What you edit (your version)    │
│                                                         │
│   ┌─────────────┐    ┌─────────────┐                    │
│   │  You See    │    │  Git Sees   │                    │
│   ├─────────────┤    ├─────────────┤                    │
│   │ Your local  │    │  Original   │                    │
│   │  content    │    │  content    │                    │
│   │             │    │             │                    │
│   │ Clean       │    │ No pending  │                    │
│   │ git status  │    │  changes    │                    │
│   └─────────────┘    └─────────────┘                    │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

## 🚨 The Problem

You want to customize a tracked file for your local environment:

- Add personal instructions to `CLAUDE.md` or `AGENTS.md`
- Tweak configuration files for local development
- Override settings without affecting the team

**But git makes this painful:**

- ❌ The file shows up in `git status` constantly
- ❌ Risk of accidentally committing your local changes
- ❌ `git stash` and `.gitignore` workarounds are fragile

---

## 🚀 Quick Start

### Install (One Command)

```bash
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash -s -- --cli
```

For large monorepos, install `fd` too. `git-local-override` will use it automatically for much faster `.local-overrides.yaml` discovery.

```bash
brew install fd
```

On Debian/Ubuntu, install `fd-find` and make sure the executable is available as `fd` on your `PATH`.

Re-running install in an existing repository is the supported upgrade path. It now also clears legacy `skip-worktree` bits on configured managed files, removes duplicate `*.legacy` git-local-override hooks that pre-commit migration mode can leave behind both before and after the canonical hook has been transitioned into a managed wrapper, and prints repair notices only when it repairs old state.

If install warns about an ambiguous hook state such as an unmanaged `pre-commit` plus an existing `pre-commit.chained`, the default behavior stays conservative and preserves both files. To repair that state during reinstall, run:

```bash
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash -s -- --cli --resolve-ambiguous-hooks
```

<details>
<summary>📦 Alternative: Pre-commit (Recommended for Teams)</summary>

Add to your `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/jonathanabila/git-override
    rev: v0.4.0  # Use latest version
    hooks:
      - id: local-override-pre-commit
      - id: local-override-post-commit
      - id: local-override-post-checkout
      - id: local-override-pre-rebase
```

Then install:

```bash
pre-commit install --hook-type pre-commit --hook-type post-commit --hook-type post-checkout --hook-type pre-rebase
```

</details>

<details>
<summary>🌐 Global Installation (All Repos)</summary>

```bash
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash -s -- --global --cli
```

</details>

<details>
<summary>📌 Pin to Specific Version</summary>

```bash
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/v0.4.0/scripts/install.sh | bash -s -- --cli
```

</details>

### Set Up Your Repository

**Step 1:** Create a config file:

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

**Step 2:** Create your local override:

```bash
cp CLAUDE.md CLAUDE.local.md
vim CLAUDE.local.md  # Make your changes
```

**That's it!** Your local changes are now active and protected from commits.

**Bonus: Multi-target overrides** - One file can replace multiple targets:

```yaml
files:
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
      - CLAUDE.md  # Both get same content!
```

---

## ⚙️ How It Works

The magic happens through git hooks that run automatically:

```
┌─────────────────────────────────────────────────────────────────┐
│                        Commit Workflow                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   1. You edit CLAUDE.local.md with your changes                 │
│              │                                                  │
│              ▼                                                  │
│   2. git commit ─────────────────────────────────────────────┐  │
│              │                                               │  │
│              │  ┌─────────────────────────────────────────┐  │  │
│              │  │         pre-commit hook                 │  │  │
│              │  │  • Restore original CLAUDE.md from git  │  │  │
│              │  │  • Stage the original content           │  │  │
│              │  └─────────────────────────────────────────┘  │  │
│              │                                               │  │
│              ▼                                               │  │
│   3. Commit succeeds (with original content)                 │  │
│              │                                               │  │
│              │  ┌─────────────────────────────────────────┐  │  │
│              │  │         post-commit hook                │  │  │
│              │  │  • Re-apply CLAUDE.local.md content     │  │  │
│              │  └─────────────────────────────────────────┘  │  │
│              │                                               │  │
│              ▼                                               │  │
│   4. Working tree has your local content again               │  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Hook Summary

| Git Operation | Hook / Filter | What Happens |
|---------------|---------------|--------------|
| `git checkout` | post-checkout | Applies local overrides to working tree |
| `git checkout` | filter driver (smudge) | Transparently applies local override content |
| `git pull` | post-checkout | Applies local overrides after merge |
| `git rebase` | pre-rebase | Restores originals before rebase checkout/detach |
| `git commit` | pre-commit | Restores originals, stages them |
| `git add` / staging | filter driver (clean) | Presents original content to git index |
| After commit | post-commit | Re-applies local overrides |


### Seamless Branch Switching (Filter Drivers)

git-local-override uses **smudge/clean filter drivers** (the same mechanism used by git-lfs and git-crypt) to enable seamless branch switching even when overridden files differ between branches.

Filter drivers make git consider overridden files "clean" through a roundtrip property: `clean(smudge(original)) == original`. This means:

- **Smudge** (on checkout): Outputs local override content transparently
- **Clean** (on staging): Presents original content from `HEAD` to git
- **Result**: Git operations work seamlessly—checkout, switch, pull, merge, rebase, stash all succeed

Filter drivers are configured automatically during installation in `.git/info/attributes` (local-only, not tracked in `.gitattributes`).
The filter commands use worktree-safe absolute paths so linked worktrees (`git worktree add`) work correctly.

Reinstalling with `install.sh --repo` and running `git-local-override sync-filters` both auto-heal legacy `skip-worktree` bits that may still exist from older installs. Runtime hooks also self-heal this old repo state; when they repair anything, they emit one terse notice to stderr and stay silent otherwise.

### Shell Integration

On git 2.37+, `git checkout` can fail with "Your local changes would be overwritten" when overridden files have different content between branches. The `shell-init` command provides a shell wrapper that transparently handles this:

```bash
# Add to ~/.bashrc or ~/.zshrc:
eval "$(git-local-override shell-init)"
```

The wrapper intercepts `git checkout` and `git switch` commands, restores original content before the operation, then lets the smudge filter re-apply overrides on the new branch. File checkouts (`git checkout -- <file>`) are not intercepted.

---

## 📝 Configuration

### Config File Format

Create `.local-overrides.yaml` in your repository root:

```yaml
# .local-overrides.yaml
pattern: ".local"   # Required: used by CLI to generate names
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
```

### Multi-Target Overrides

One override file can replace multiple tracked files:

```yaml
pattern: ".local"
files:
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
      - CLAUDE.md   # Both files get content from AGENTS.local.md
```

When you commit, if ANY file in a group is staged, ALL files in that group are restored to ensure consistency.

### Recursive Configs

`git-local-override` discovers `.local-overrides.yaml` recursively.

- The nearest config owns its directory subtree
- A child config fully replaces parent behavior for that subtree
- Paths inside a nested config are resolved relative to that config's directory
- A child config can inherit `pattern:` from the nearest ancestor config if it does not define its own
- Parent configs may not keep targeting files inside a child-owned subtree
- An empty child config still claims its subtree and blocks parent targets there
- A deeper config can still take ownership below an empty child config

Example:

```yaml
# .local-overrides.yaml
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
```

```yaml
# backend/.local-overrides.yaml
pattern: ".private"
files:
  - override: CLAUDE.private.md
    replaces:
      - CLAUDE.md
```

In that setup:
- root `CLAUDE.md` uses `CLAUDE.local.md`
- `backend/CLAUDE.md` uses `backend/CLAUDE.private.md`
- the root config no longer applies inside `backend/`

Additional recursive behavior:

- If `backend/.local-overrides.yaml` omits `pattern:`, it inherits the nearest ancestor pattern.
- A child config with only `pattern:` and no `files:` still blocks parent entries from targeting that subtree.
- A deeper config can still own a nested subtree below that empty child.

### Custom Patterns

Use any pattern for override file naming:

```yaml
# Use .override instead of .local
pattern: ".override"
files:
  - override: CLAUDE.override.md
    replaces:
      - CLAUDE.md
```

### File Naming Convention

Override files typically use the pattern inserted before the extension:

| Pattern | Original File | Override File |
|---------|---------------|---------------|
| `.local` | `CLAUDE.md` | `CLAUDE.local.md` |
| `.override` | `CLAUDE.md` | `CLAUDE.override.md` |
| `.custom` | `config.json` | `config.custom.json` |
| `.local` | `Makefile` | `Makefile.local` |

---

## 🛠️ CLI Commands

The CLI provides utility commands (included with the default install):

| Command | Description |
|---------|-------------|
| `git-local-override add <path>` | Create a local override file |
| `git-local-override remove [-d] <path>` | Remove override (`-d` deletes local file) |
| `git-local-override list` | List configured overrides and status |
| `git-local-override status` | Show detailed system status |
| `git-local-override apply` | Manually apply all overrides |
| `git-local-override restore` | Manually restore all originals |
| `git-local-override sync-filters` | Sync filter configuration and clear legacy managed `skip-worktree` bits |
| `git-local-override shell-init` | Output shell wrapper for transparent checkout/switch |
| `git-local-override init-config` | Create a `.local-overrides.yaml` template |
| `git-local-override --version` | Show the CLI version |
| `git-local-override help` | Show help |

---

## 🔧 Advanced Usage

<details>
<summary><strong>Escape Hatch: Commit Local Changes Intentionally</strong></summary>

Need to commit your local changes? Use git's standard bypass:

```bash
git commit --no-verify -m "Include local changes this time"
```

</details>

<details>
<summary><strong>Manual Apply/Restore</strong></summary>

```bash
# Apply all local overrides now
git-local-override apply

# Restore all originals (useful for debugging)
git-local-override restore
```

</details>

<details>
<summary><strong>Existing Hooks Preserved</strong></summary>

git-local-override chains with your existing hooks:

```bash
.git/hooks/pre-commit           # Our wrapper
.git/hooks/pre-commit.chained   # Your original hook (called after ours)
```

Managed wrappers run first and then continue into the matching `*.chained` hook only if the managed hook succeeds.

If install finds both an unmanaged canonical hook and an existing `*.chained` backup for the same managed hook, it warns and leaves both files untouched by default. Re-run install with `--resolve-ambiguous-hooks` to back up both files, move the old `*.chained` file to `*.chained.stale-<timestamp>`, promote the canonical hook to the new `*.chained`, and install the managed wrapper.

</details>

<details>
<summary><strong>Disable Filters Temporarily</strong></summary>

Set `GIT_LOCAL_OVERRIDE_DISABLE=1` to bypass filter drivers. Useful for debugging or getting the true original content:

```bash
GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- AGENTS.md
```

</details>

---

## 📁 Architecture

```
<your-repo>/
├── .local-overrides.yaml       # Config: files that can be overridden
├── CLAUDE.md                   # Tracked file (shows your local content)
├── CLAUDE.local.md             # Your local version (gitignored)
└── .git/hooks/
    ├── post-checkout           # Applies overrides after checkout
    ├── pre-rebase              # Restores originals before rebase
    ├── pre-commit              # Restores originals before commit
    ├── post-commit             # Re-applies overrides after commit
    ├── local-override-filter-smudge   # Filter: applies local content on checkout
    ├── local-override-filter-clean    # Filter: presents original content to git
    └── local-override-lib.sh   # Shared functions
```

---

## ⚡ Performance

Hooks are optimized for speed:

| Scenario | Target | Typical |
|----------|--------|---------|
| No config file | < 1ms | ~0.5ms |
| 10 overrides, post-checkout | < 50ms | ~30ms |
| 100 staged files, 10 overrides | < 100ms | ~25ms |

For large monorepos, `fd` is strongly recommended. When `fd` is available on `PATH`, `git-local-override` prefers it for config discovery and avoids slow ignored-file scans through Git.

---

## 🔍 Troubleshooting

<details>
<summary><strong>Local changes not appearing</strong></summary>

Re-apply overrides manually:

```bash
git-local-override apply
```

</details>

<details>
<summary><strong>Hooks not running</strong></summary>

Check status:

```bash
git-local-override status
```

If hooks show "not installed", reinstall them.

</details>

<details>
<summary><strong>Branch switching feels slow</strong></summary>

Watch the hook lifecycle logs during checkout:

```bash
git checkout dev
```

If you need to see whether the smudge filter is spending time on many files, enable trace mode:

```bash
GIT_LOCAL_OVERRIDE_TRACE=1 git checkout dev
```

For manual runs, `git-local-override apply` now reports validation, config resolution, active override counts, apply progress, attribute sync, and total elapsed time.

If `post-checkout` still logs `discover_config_files strategy=...`, that means it had to fall back to the slower validation path because config files changed across the checkout or local generated state needed refreshing.

</details>

<details>
<summary><strong>`git-local-override apply` is slow in a large monorepo</strong></summary>

Enable trace mode:

```bash
GIT_LOCAL_OVERRIDE_TRACE=1 git-local-override apply
```

Then look for the config discovery line:

- `discover_config_files strategy=fd` means the fast path is active
- `discover_config_files strategy=git` means the slower fallback path is active

If you see `strategy=git` in a large repo, install `fd` and rerun. `git-local-override` will pick it up automatically when the `fd` executable is available on `PATH`.

Example install:

```bash
brew install fd
```

On Debian/Ubuntu, install `fd-find` and expose it as `fd` on `PATH`.

</details>

<details>
<summary><strong>File not being overridden</strong></summary>

Make sure the file is listed in `.local-overrides.yaml`:

```yaml
files:
  - override: path/to/your/file.local.md
    replaces:
      - path/to/your/file.md
```

</details>

<details>
<summary><strong>Branch switching fails with "local changes would be overwritten"</strong></summary>

**Cause**: Filter drivers not configured properly.

**Solution**:

```bash
# Re-sync filter configuration
git-local-override sync-filters

# Or reinstall
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash -s -- --cli
```

If still failing, check filter configuration:

```bash
git config --local filter.local-override.smudge
git config --local filter.local-override.clean
cat .git/info/attributes
```

In linked worktrees, relative filter commands like `.git/hooks/...` fail because `.git` is a file in worktree directories.
Run `git-local-override sync-filters` to migrate to the worktree-safe absolute-path configuration.

If failures happen specifically during rebase and mention files like `AGENTS.md`/`CLAUDE.md` being overwritten by checkout,
ensure your install includes the `pre-rebase` hook. Re-run install or pre-commit install with `--hook-type pre-rebase`.

</details>

<details>
<summary><strong>New hooks not working after project update (curl install)</strong></summary>

If you installed using the curl method (not pre-commit) and the project adds new hooks in an update, you need to re-run the install script:

```bash
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash -s -- --cli
```

This is because the curl method installs hooks directly to `.git/hooks/` at install time. Unlike pre-commit, which manages hooks dynamically, the curl method requires manual reinstallation to pick up new hooks.

Re-running `install.sh` is the supported upgrade path and is safe:

- managed wrapper hooks are refreshed in place
- existing `*.chained` backups of your hooks are preserved
- filter config and `.git/info/attributes` managed entries are re-synced
- legacy managed `skip-worktree` bits are cleared automatically when found
- duplicate git-local-override `*.legacy` hooks left behind by pre-commit migration mode are removed before they can run a second time, including repos already transitioned to a managed hook plus `*.chained` pre-commit wrapper layout

If you prefer the CLI upgrade path, `git-local-override sync-filters` performs the same legacy `skip-worktree` cleanup for configured managed files.

Runtime hooks also repair this older repo state automatically. When a repair happens during `git checkout`, `git commit`, or `git rebase`, the hook prints a terse `git-local-override: cleared legacy skip-worktree ...` notice to stderr; if nothing needed repair, nothing is printed.

If reinstall reports a warning like `Ambiguous state for pre-commit: unmanaged hook with existing pre-commit.chained; preserving both`, it means the installer found a user-managed hook at the canonical path and also found an older chained backup. This warning is intentionally conservative.

Use repair mode only when you want the installer to reconcile that state for you:

```bash
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash -s -- --cli --resolve-ambiguous-hooks
```

Repair mode:

- creates a timestamped backup directory under the hooks directory with copies of both original files
- preserves the previous `*.chained` file as `*.chained.stale-<timestamp>` history
- promotes the unmanaged canonical hook to the new `*.chained`
- installs a fresh managed wrapper at the canonical hook path

If you want to remove curl-installed repo state, run uninstall from inside that repository:

```bash
./scripts/uninstall.sh
```

Uninstall restores `.chained` hooks only when it is safe, and preserves newer unmanaged hooks with a warning.

**Note:** If you're using pre-commit for installation, hooks are updated automatically when you run `pre-commit install` or when pre-commit auto-updates.

</details>

---

## 📦 What Gets Installed

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
| `.git/info/attributes` | Filter config | Maps files to filter driver (local only) |
| `git config filter.local-override.*` | Git config | Filter commands pointing to absolute hook script paths |
| `~/.config/git/ignore` | Gitignore patterns | Ignores `*.local.*` files globally |

With `--global`: Also installs to `~/.config/git/template/hooks/` for new repos.

With `--cli`: Installs CLI to `~/.local/bin/git-local-override` and installs `local-override-resolver.sh` to `~/.local/share/git-local-override`.

---

## 📋 Requirements

- **Bash** 3.2+ (macOS default) or Bash 4+
- **Git** 2.0+
- Standard Unix tools: `grep`, `cp`, `mv`, `mkdir`, `chmod`, `dirname`, `basename`
- `curl` (for remote installation only)

Optional but strongly recommended for large monorepos:

- `fd` on `PATH` for fast `.local-overrides.yaml` discovery

---

## 👨‍💻 Development

<details>
<summary><strong>Repository Structure</strong></summary>

```
git-local-override/
├── bin/                          # CLI tool
│   └── git-local-override
├── hooks/                        # Git hook scripts
│   ├── local-override-lib.sh     # Shared library
│   ├── local-override-resolver.sh # Installed shared resolver runtime copy
│   ├── local-override-filter-smudge   # Smudge filter (checkout)
│   ├── local-override-filter-clean    # Clean filter (staging)
│   ├── local-override-post-checkout
│   ├── local-override-pre-rebase
│   ├── local-override-pre-commit
│   └── local-override-post-commit
├── shared/
│   └── local-override-resolver.sh # Shared recursive config resolver source
├── scripts/                      # Installation and release scripts
│   ├── install.sh
│   ├── uninstall.sh
│   └── release.sh
├── tests/                        # Test suite
│   ├── run-tests.sh              # Unit tests
│   ├── run-docker.sh             # Docker test launcher
│   ├── docker/                   # Docker test infrastructure
│   └── integration/              # Integration tests
├── .pre-commit-hooks.yaml        # Pre-commit hook definitions
└── docs/
    └── DESIGN.md
```

</details>

<details>
<summary><strong>Running Tests</strong></summary>

```bash
make test-docker        # Full Docker test matrix
make test-docker-bash3  # Bash 3.2 compatibility matrix
make test               # Quick local check
make clean              # Clean test artifacts
```

</details>

<details>
<summary><strong>Code Quality</strong></summary>

```bash
# Install pre-commit hooks for development
pip install pre-commit
pre-commit install

# Run linting
make lint           # Shellcheck
make fmt            # Auto-format with shfmt
```

</details>

---

## 🤝 Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

---

## 💡 Acknowledgments

Inspired by the need to maintain local AI assistant configurations (`CLAUDE.md`, `AGENTS.md`) without polluting git history or risking accidental commits.

---

<div align="center">
  <p>
    <a href="https://github.com/jonathanabila/git-override/issues">Report Bug</a> •
    <a href="https://github.com/jonathanabila/git-override/issues">Request Feature</a>
  </p>
  <p>
    ⭐ Star this repo if you find it useful!
  </p>
</div>
