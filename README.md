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
    <a href="#-troubleshooting">Troubleshooting</a>
  </p>
</div>

<br>

> **Note**: The GitHub repository is named [`git-override`](https://github.com/jonathanabila/git-override), but the tool/CLI is called `git-local-override`.

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
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash
```

<details>
<summary>📦 Alternative: Pre-commit (Recommended for Teams)</summary>

Add to your `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/jonathanabila/git-override
    rev: v0.0.2
    hooks:
      - id: local-override-pre-commit
      - id: local-override-post-commit
      - id: local-override-post-checkout
```

Then install:

```bash
pre-commit install --hook-type pre-commit --hook-type post-commit --hook-type post-checkout
```

</details>

<details>
<summary>🌐 Global Installation (All Repos)</summary>

```bash
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash -s -- --global
```

</details>

<details>
<summary>📌 Pin to Specific Version</summary>

```bash
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/v0.0.2/scripts/install.sh | bash
```

</details>

### Set Up Your Repository

**Step 1:** Create a config file listing files that can be overridden:

```yaml
# .local-overrides.yaml
files:
  - CLAUDE.md
  - AGENTS.md
  - config/settings.json
```

**Step 2:** Create your local override:

```bash
cp CLAUDE.md CLAUDE.local.md
vim CLAUDE.local.md  # Make your changes
```

**That's it!** Your local changes are now active and protected from commits.

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

| Git Operation | Hook | What Happens |
|---------------|------|--------------|
| `git checkout` | post-checkout | Applies local overrides to working tree |
| `git pull` | post-checkout | Applies local overrides after merge |
| `git commit` | pre-commit | Restores originals, stages them |
| After commit | post-commit | Re-applies local overrides |

---

## 📝 Configuration

### Config File Format

Create `.local-overrides.yaml` in your repository root:

```yaml
# .local-overrides.yaml
files:
  - CLAUDE.md
  - AGENTS.md
  - config/settings.json
  - backend/services/*/config.yaml  # Glob patterns supported
```

<details>
<summary>Plain text format alternative</summary>

```
# .local-overrides
CLAUDE.md
AGENTS.md
config/settings.json
```

</details>

### File Naming Convention

Local override files use `.local` inserted before the extension:

| Original File | Local Override |
|---------------|----------------|
| `CLAUDE.md` | `CLAUDE.local.md` |
| `config.json` | `config.local.json` |
| `settings.yaml` | `settings.local.yaml` |
| `Makefile` | `Makefile.local` |

---

## 🛠️ CLI Commands

The optional CLI provides utility commands. Install with:

```bash
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash -s -- --cli
```

| Command | Description |
|---------|-------------|
| `git-local-override add <path>` | Create a local override file |
| `git-local-override remove [-d] <path>` | Remove override (`-d` deletes local file) |
| `git-local-override list` | List configured overrides and status |
| `git-local-override status` | Show detailed system status |
| `git-local-override apply` | Manually apply all overrides |
| `git-local-override restore` | Manually restore all originals |
| `git-local-override init-config` | Create a `.local-overrides.yaml` template |
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
    ├── pre-commit              # Restores originals before commit
    ├── post-commit             # Re-applies overrides after commit
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
<summary><strong>File not being overridden</strong></summary>

Make sure the file is listed in `.local-overrides.yaml`:

```yaml
files:
  - path/to/your/file.md
```

</details>

---

## 📦 What Gets Installed

| Location | What | Purpose |
|----------|------|---------|
| `.git/hooks/pre-commit` | Hook script | Restores originals before commit |
| `.git/hooks/post-commit` | Hook script | Re-applies overrides after commit |
| `.git/hooks/post-checkout` | Hook script | Applies overrides after checkout |
| `.git/hooks/local-override-lib.sh` | Shared library | Common functions for hooks |
| `.git/hooks/*.chained` | Backup | Your existing hooks (preserved) |
| `~/.config/git/ignore` | Gitignore patterns | Ignores `*.local.*` files globally |

With `--global`: Also installs to `~/.config/git/template/hooks/` for new repos.

With `--cli`: Installs CLI to `~/.local/bin/git-local-override`.

---

## 📋 Requirements

- **Bash** 3.2+ (macOS default) or Bash 4+
- **Git** 2.0+
- Standard Unix tools: `grep`, `cp`, `mv`, `mkdir`, `chmod`, `dirname`, `basename`
- `curl` (for remote installation only)

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
│   ├── local-override-post-checkout
│   ├── local-override-pre-commit
│   └── local-override-post-commit
├── scripts/                      # Installation scripts
│   ├── install.sh
│   └── uninstall.sh
├── tests/                        # Test suite
│   └── run-tests.sh
├── .pre-commit-hooks.yaml        # Pre-commit hook definitions
└── docs/
    └── DESIGN.md
```

</details>

<details>
<summary><strong>Running Tests</strong></summary>

```bash
make test           # Run test suite
make clean          # Clean test artifacts
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
