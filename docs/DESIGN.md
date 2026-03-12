# Design History (Archived)

`git-local-override` originally shipped with a different architecture in v0.0.1.

This document intentionally keeps only a short historical note. The previous long-form design described:

- global allowlist files
- per-repository registry files
- legacy commands such as `allowlist`, `sync`, and `init`
- old installer names (`install-local-override.sh`, `uninstall-local-override.sh`)

Those details are obsolete and are not supported by current releases.

## Current Design (Authoritative)

Current releases (v0.2+) are config-driven and repository-local:

- Configuration: `.local-overrides.yaml`
- Installer scripts: `scripts/install.sh`, `scripts/uninstall.sh`
- CLI commands: `add`, `remove`, `list`, `status`, `apply`, `restore`, `sync-filters`, `init-config`, `help`
- Hook + filter model: per-repo hooks plus `smudge`/`clean` filter drivers

For accurate and up-to-date behavior, use:

- [README.md](../README.md)
- [CONTRIBUTING.md](../CONTRIBUTING.md)
- [AGENTS.md](../AGENTS.md)

## Why this file remains

This file is retained only so existing references to `docs/DESIGN.md` continue to resolve and to preserve a minimal pointer to the project’s early architecture.
