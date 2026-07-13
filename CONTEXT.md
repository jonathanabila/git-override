# git-local-override

Keeps local modifications to git-tracked files out of commits. Config files
declare which tracked files may be overridden; git filters and hooks swap
content transparently so git always sees the original.

## Language

### Core concepts

**Target**:
A git-tracked file whose working-tree content may be replaced by an override.
_Avoid_: managed file, overridden file

**Override**:
The user-created, gitignored `.local.*` file whose content replaces one or
more targets. Never committed.
_Avoid_: local file, override file (when "override" alone is unambiguous)

**Config**:
A `.local-overrides.yaml` file, checked into the repo and discovered
recursively, mapping each override to its targets.
_Avoid_: registry, manifest

**Group**:
All targets sharing one override. Restores are grouped: if any target in a
group is staged, every target in the group is restored.

**Apply**:
Copy override content onto a target in the working tree.

**Restore**:
Put original tracked content back into a target.

**Leak**:
Override content escaping into a commit or the index. The system's core
failure mode; the pre-commit backstops exist to refuse it.

**Reapply state**:
The record pre-commit writes of what it restored, so post-commit (or a later
checkout, after an aborted commit) can re-apply the overrides.

### Places

**Checkout root**:
The worktree where git index and working-tree operations happen.

**Resolution root**:
The checkout against which configs and overrides resolve — the main checkout
when a linked worktree falls back to it. Symlink containment checks must
anchor here.
_Avoid_: repo root (ambiguous between the two roots)

### Machinery

**Resolver**:
The single shared module owning config discovery, parsing, and safety
decisions. All distribution channels source it; shared behaviour lives here
or nowhere.
_Avoid_: library, lib

**Distribution channel**:
One of the four standalone entry paths into the system: CLI, git-invoked
hooks, installer, uninstaller. Each must run without the others present.

**Filter driver**:
The git smudge/clean (or experimental process) configuration that makes git
consider targets clean while overrides are applied.

**Front door**:
The one resolver function a read (serve override content), write (apply
override to target), or restore (put tracked HEAD content back) must pass
through; owns the symlink gates, resolution-root anchoring, and — on the
restore side — filter suppression that works in both filter modes.

**Support file**:
A shared data file an entry point must locate at runtime (resolver,
shell-init, VERSION) — found in the dev checkout or the installed location
via a single fallback ladder.

**Managed artifact**:
A file the installer owns and the uninstaller may remove — hook wrappers
carry an exact marker line identifying them as managed. The set of managed
artifacts is defined once, by the resolver's runtime manifest
(`managed_hook_types` / `managed_filter_scripts` / `managed_runtime_files`).
_Avoid_: our hooks, installed files

**Self-heal**:
A hook noticing a missing filter driver (the pre-commit-framework install
path never configures one) and configuring it in place, without breaking the
running git operation.
