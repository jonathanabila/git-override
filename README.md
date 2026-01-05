# git-local-override

**Maintain local modifications to tracked files without committing them.**

git-local-override lets you customize tracked files (like `CLAUDE.md`, `AGENTS.md`, or config files) locally while keeping git's view of those files unchanged. Your local modifications stay on your machine, invisible to git status and safe from accidental commits.

## The Problem

You want to customize a tracked file for your local environment:
- Add personal instructions to `CLAUDE.md` or `AGENTS.md`
- Tweak configuration files for local development
- Override settings without affecting the team

But git makes this painful:
- The file shows up in `git status` constantly
- Risk of accidentally committing your local changes
- `git stash` and `.gitignore` workarounds are fragile

## The Solution

git-local-override uses git hooks to transparently manage local file overrides:

```
CLAUDE.md          <- What git sees (original content)
CLAUDE.local.md    <- What you edit (your local version)
```

| You see | Git sees |
|---------|----------|
| Your local content | Original tracked content |
| Clean `git status` | No modifications |
| Safe commits | Original content committed |

## Quick Start

### For Repository Maintainers

Add a `.local-overrides.yaml` to your repository listing files that users can override:

```yaml
# .local-overrides.yaml
files:
  - CLAUDE.md
  - AGENTS.md
  - config/settings.json
```

Commit this file to your repository.

### For Users

#### Option 1: Pre-commit (Recommended for Teams)

Add to your `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/jonathanabila/git-override
    rev: v1.0.0
    hooks:
      - id: local-override-pre-commit
      - id: local-override-post-commit
      - id: local-override-post-checkout
```

Then install the hooks:

```bash
pre-commit install --hook-type pre-commit --hook-type post-commit --hook-type post-checkout
```

#### Option 2: Standalone (Quick Setup)

```bash
# Install hooks to current repository
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash

# Or install globally (affects all new repos)
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash -s -- --global
```

### Create Your Overrides

```bash
# Create a local version of the file you want to customize
cp CLAUDE.md CLAUDE.local.md

# Edit your local version
vim CLAUDE.local.md
```

That's it! Your local changes are now active and protected from commits.

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                        Your Workflow                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   1. Edit CLAUDE.local.md                                       │
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

### Hook Actions

| Git Operation | Hook | What Happens |
|---------------|------|--------------|
| `git checkout` | post-checkout | Applies local overrides to working tree |
| `git pull` | post-checkout | Applies local overrides after merge |
| `git commit` | pre-commit | Restores originals, stages them |
| After commit | post-commit | Re-applies local overrides |

## Configuration

### Config File Format

Create `.local-overrides.yaml` in your repository root:

```yaml
# .local-overrides.yaml
files:
  - CLAUDE.md
  - AGENTS.md
  - config/settings.json
  - backend/services/*/config.yaml
```

Or use plain text format `.local-overrides`:

```
# .local-overrides
CLAUDE.md
AGENTS.md
config/settings.json
```

### File Naming Convention

Local override files use `.local` inserted before the extension:

| Original File | Local Override |
|---------------|----------------|
| `CLAUDE.md` | `CLAUDE.local.md` |
| `AGENTS.md` | `AGENTS.local.md` |
| `config.json` | `config.local.json` |
| `settings.yaml` | `settings.local.yaml` |
| `Makefile` | `Makefile.local` |

## CLI Tool (Optional)

The CLI provides utility commands for managing overrides. Install it with:

```bash
curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash -s -- --cli
```

### Commands

```bash
git-local-override add <path>           # Create a local override file
git-local-override remove [-d] <path>   # Remove override (-d deletes local file)
git-local-override list                 # List configured overrides and status
git-local-override status               # Show detailed system status
git-local-override apply                # Manually apply all overrides
git-local-override restore              # Manually restore all originals
git-local-override init-config          # Create a .local-overrides.yaml template
git-local-override help                 # Show help
```

## Advanced Usage

### Escape Hatch

Need to commit your local changes intentionally? Use git's standard bypass:

```bash
git commit --no-verify -m "Include local changes this time"
```

### Manually Apply/Restore

```bash
# Apply all local overrides now
git-local-override apply

# Restore all originals now (useful for debugging)
git-local-override restore
```

### Existing Hooks

git-local-override preserves your existing hooks by chaining them:

```bash
.git/hooks/pre-commit           # Our wrapper
.git/hooks/pre-commit.chained   # Your original hook (called after ours)
```

## Architecture

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

## Performance

Hooks are optimized for speed:

| Scenario | Target | Typical |
|----------|--------|---------|
| No config file | < 1ms | ~0.5ms |
| 10 overrides, post-checkout | < 50ms | ~30ms |
| 100 staged files, 10 overrides | < 100ms | ~25ms |

## Troubleshooting

### Local changes not appearing

Re-apply overrides manually:

```bash
git-local-override apply
```

### Hooks not running

Check status:

```bash
git-local-override status
```

If hooks show "not installed", reinstall them.

### File not being overridden

Make sure the file is listed in `.local-overrides.yaml`:

```yaml
files:
  - path/to/your/file.md
```

## Global Gitignore

The install script adds patterns to your global gitignore so `.local.*` files never show in git status:

```
# ~/.config/git/ignore
*.local.*
*.local
```

## Requirements

- Bash 3.2+ (macOS default) or Bash 4+
- Git 2.0+
- Standard Unix tools: `grep`, `cp`

## Development

### Repository Structure

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

### Running Tests

```bash
make test           # Run test suite
make clean          # Clean test artifacts
```

### Code Quality

```bash
# Install pre-commit hooks for development
pip install pre-commit
pre-commit install

# Run linting
make lint           # Shellcheck
make fmt            # Auto-format with shfmt
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

Inspired by the need to maintain local AI assistant configurations (`CLAUDE.md`, `AGENTS.md`) without polluting git history or risking accidental commits.
