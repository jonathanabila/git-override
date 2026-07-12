# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **`apply` now writes the config stamp after its full discovery walk, matching `sync-filters`**: `apply` and `sync-filters` are both documented as ways to register a newly created gitignored config, but only `sync-filters` recorded the resolved config set in the config stamp. A gitignored config registered via `apply` landed in `.git/info/attributes` yet stayed absent from the stamp — invisible to hot discovery (not tracked, not stamped) and invisible to the stamp comparison — so a later edit to that config adding/removing a target was silently missed by the post-checkout fast path until a full walk was forced. `apply_to_checkout` now writes the stamp after syncing attributes (its discovery cache is full-mode, so the stamp captures the complete set), leaving the same state `sync-filters` does; `apply --all-worktrees` stamps each worktree via the per-checkout loop (unit 117→118)
- **Post-checkout now re-syncs a deleted or truncated `.git/info/attributes` file**: if the attributes file was removed or emptied out-of-band while the config stamp still matched and tracked configs were unchanged, every subsequent branch checkout took the fast path, "succeeded" with an empty entry set, and never rebuilt the managed `filter=local-override` block — silently disabling the filter driver so overrides stopped applying and originals could leak into commits. The fast path now disqualifies itself when the attributes file is missing or empty, forcing the slow path to re-sync attributes and rewrite the config stamp (git-ops 38→39)

### Security

- **Config target paths can no longer inject attribute macros or glob patterns into `.git/info/attributes`**: managed target paths from `.local-overrides.yaml` (attacker-controlled in the malicious-repo threat model) were written verbatim into `.git/info/attributes`, a valid macro-definition location — so a crafted target could redefine a git attribute macro or wire the filter to every path via a wildcard, silently changing attribute semantics in the victim's checkout (no content leak: the filters re-check an exact config match before substituting). `validate_config` now rejects any target containing a glob/attribute metacharacter (`*` `?` `[` `]`), and the attribute-line writer quotes targets containing whitespace, double quotes, or backslashes in git's double-quoted gitattributes form — which also closes the plan-010 gap where a space-containing target produced an unquoted line git rejected, leaving the filter driver unwired for that file (unit 118→121)

- **Closed a repo-containment bypass in the override read gate**: a symlinked parent directory inside an override path could bypass the repo-containment check in the smudge/clean filters and the post-commit reapply, because those call sites anchored the check on the override's own parent directory instead of the true resolution root. All override-read sites now go through a single safe resolver front door (`resolve_safe_override_for_file`) that anchors containment on the resolution root — the same convention the CLI already used — so an override path traversing a repo-shipped symlinked directory is refused regardless of the `local-override.followSymlinkedOverrides` opt-in (the opt-in covers only the override file itself, never path components). The post-checkout apply loop was also aligned onto the opt-in-aware override gate, so a legitimate user-created untracked symlinked override is now applied there too, matching the filters (unit 113→117)

## [0.9.0] - 2026-07-12

### Added

- **Opt-in support for symlinked override files** (`git config --local local-override.followSymlinkedOverrides true`): override files that are symlinks created by the user — e.g. pointing at a canonical copy kept in a separate dotfiles repo — are now followed by `add`, `apply`, the smudge/clean filters, and the post-commit reapply. The opt-in is deliberately impossible to ship in repo content: it lives only in git config, and a symlink that is *tracked* by git is refused even when the opt-in is set, so a hostile repo can neither enable following nor plant a link (the plan-001 read-leak and write-escape guards are otherwise unchanged — symlinked *targets* are always refused). Dangling symlinks are treated as a missing override. `list`/`status` mark symlinked overrides and show their real (followed vs ignored) state, and `doctor` gained a check that prints the exact opt-in command when a symlinked override is being ignored (unit 102→113)

## [0.8.0] - 2026-07-12

### Added

- **CLI error-path and clean-filter characterization tests**: two unit tests pin the previously untested `die "Not in a git repository"` guard (running `status`/`list`/`apply` from outside any git worktree) and the `die "Unknown command"` dispatch fallback; one git-ops characterization test locks the clean filter's current contract for a never-tracked managed target — staging a brand-new target that holds override content passes those bytes through to the index (there is no index/HEAD blob to substitute), so `hooks/local-override-pre-commit` remains the leak gate. The characterization test is a tripwire for a future clean-core refactor, not an endorsement of the passthrough (unit 91→93, git-ops 37→38 native)
- **filter.process now under CI**: the byte-exact roundtrip verifier (`tests/bench-filter-process.sh --verify-only`, the six plan-009 hazardous cases — binary/NUL, CRLF, empty blob, empty override, no trailing newline, multiple trailing newlines) runs through the real `filter.process` handshake as a Docker suite (`filterprocess` verb; `make test-docker-filter-process`, and added to `make test-docker`), plus a new opt-in install-wiring integration test (`test_install_filter_process_mode`) that asserts `GIT_LOCAL_OVERRIDE_FILTER_PROCESS=1` install sets `filter.local-override.process` (and unsets per-file smudge), then drives smudge (checkout serves override) and clean (staging yields original tracked bytes) end to end and confirms `doctor` reports healthy. Previously the 251-line protocol implementation and its install wiring were executed by nothing in CI (install suite 32→33)
- **`make check-docs-sync` gate** (`tests/check-docs-sync.sh`, wired into `make ci` next to `check-resolver-sync` and into the CI `lint` job): fails the build when a hardcoded documentation version pin (pre-commit `rev:` snippets, pinned `/vX.Y.Z/scripts/install.sh` URLs) does not match `VERSION`, or when a public CLI command in the dispatch `case` is missing from the `help` text or the README CLI Commands table

### Changed

- **Read-only CLI commands now use stamp-gated hot discovery instead of a full two-pass walk per invocation.** `list`, `status`, `validate`, `doctor`, and the internal `_get_active_targets` share a new `cache_config_files_readonly` helper that reuses plan-043's hook hot path: one non-ignored-tree walk plus a free re-check of the gitignored configs recorded in the config stamp, falling back to a full walk only on a config-stamp mismatch or when no stamp exists yet (fresh clone before any `sync-filters`/post-checkout slow path). This drops the ignored-tree pass (measured ~190ms → ~110ms at 360k files warm; the gap grows with ignored-tree size), so read-only commands now cost about what a hook checkout does. The carve-out is identical to the hooks': a **brand-new gitignored config** is invisible to the fast path until a full-discovery command registers it; edits/removals of already-registered configs are caught by the cksum-based stamp. Read-only commands never write the stamp — `sync-filters` and the post-checkout slow path stay the only writing authorities — so a stale-but-present stamp can only cost a fallback walk, never hide a config from a mutating command. Mutating commands (`add`, `remove`, `apply`, `restore`, `sync-filters`) keep full discovery unchanged. A new resolver predicate `config_files_cached_for` lets a delegating read-only command (`status` calls `list`) reuse the already-stamp-validated cache instead of thrashing the discovery mode key back to hot
- **Config discovery no longer walks gitignored trees or `.git/`, so hook cost scales with the non-ignored tree only.** `discover_config_files` gained two modes: hook checkouts run `hot` (one `git ls-files --cached --others --exclude-standard` walk over the non-ignored tree, plus a free re-check of the gitignored configs already recorded in the config stamp), and full-discovery commands (`apply`, `sync-filters`, `pre-rebase`) run `full` (the same pass 1 plus a `git ls-files --others --ignored --directory` pass that finds directly-ignored configs but no longer descends into wholly-ignored directories). The discovery cache is keyed on the mode so a hot result is never served to a full caller. `get_nested_worktree_dirs` also skips the per-discovery `git worktree list` spawn in repos with no linked worktrees. Behavior note: a **newly created** gitignored config is no longer auto-registered by the next checkout — run `git-local-override sync-filters` (or any full-discovery command) once to register it; **edits and deletions of already-registered gitignored configs are still auto-detected** via the plan-008 config stamp. On a synthetic 590k-file monorepo (500k ignored, 62k `.git` objects), per hook-checkout discovery dropped from ~679ms (fd) to roughly the cost of one non-ignored walk (~106ms), and the gap grows with ignored-tree size
- **Filter invocations establish git context with a single combined `git rev-parse`** (was 5 subprocess spawns per smudged file, 3 per cleaned file). `load_git_context` runs one `git rev-parse --show-toplevel --git-dir --git-common-dir --git-path rebase-merge --git-path rebase-apply` and memoizes the result keyed by repo root; the smudge/clean cores and their `is_linked_worktree`/`is_rebase_in_progress` consumers read the memo when the root matches, falling back to per-call spawns for multi-root callers (e.g. `apply --all-worktrees`). `is_rebase_in_progress` now checks the free `GIT_REFLOG_ACTION` env var before spawning any git. Measured on macOS (`tests/bench-filter-process.sh --sizes "1 10" --repeats 3`): per-file smudge dropped from 153ms→81ms at N=1 and from ~145.7ms/file→98.0ms/file at N=10 (~33–47% faster). A new git-shim unit test asserts the smudge core spawns exactly one `rev-parse`
- **Small internal dedup batch**: `cmd_apply`/`cmd_restore` now share one `--all-worktrees` fan-out loop (`run_in_each_worktree`) instead of two byte-similar ~40-line copies; `local_override_trace_log` has a single tag-aware implementation in the resolver (the divergent lib.sh shadow is gone, so trace format no longer depends on the entry point); and the three remaining fork-per-entry `grep -qxF` accumulator sites in the pre-commit hot path use the fork-free in-shell membership test (completing plan 012's leftover). No user-visible behavior change (fan-out messages byte-identical; only the CLI-sourced clean core's debug trace lines gain the `[clean]` tag they already had via the hook)
- **`install.sh` reuses the resolver's skip-worktree repair and a single content getter**: `repair_legacy_skip_worktree` now delegates to the shared resolver's `clear_legacy_skip_worktree` (it already sourced the resolver in its subshell) instead of re-implementing the detect+repair loop with the pre-plan-012 fork-per-entry dedup, and it now writes the plan-013 one-shot repair marker so the first post-checkout after install doesn't repeat the repair. The six near-identical `get_*_content` getters collapse into one parameterized `get_project_file_content <rel-path>` (same local-checkout-else-`curl` fallback)
- **`status` and `doctor` now share their check helpers**: hook-installed detection (`detect_hooks_installed`), filter-driver mode (`get_filter_driver_mode`), the managed-attribute-line count (`count_managed_attribute_lines`), and the effective-target count (`count_effective_targets`) each have one implementation consumed by both commands (and `sync-filters`/`validate` where applicable), so the two commands' checks can no longer drift as they had
- **Single canonical attributes-rewrite implementation**: the logic that rewrites `.git/info/attributes` (preserve foreign lines, drop the managed `filter=local-override` block, regenerate it from config) now lives once in the shared resolver as `sync_attributes_entries`. The three former copies — the post-checkout hook path (`hooks/local-override-lib.sh`), the CLI (`apply`/`sync-filters`), and the installer (`scripts/install.sh`) — are now thin callers that delegate to it, so the managed-block format can no longer drift between writers (the installer copy had drifted back to the pre-fork-free dedup idiom). `scripts/uninstall.sh`'s removal-only variant is intentionally kept separate (it must run standalone when the resolver is already gone)
- **`scripts/release.sh` now bumps the documentation version pins** (`README.md`, `SECURITY.md`, `.pre-commit-hooks.yaml`, `bin/git-local-override`) from the previous release to the new one, so the pinned install/pre-commit snippets no longer have to be re-bumped by hand each release
- Rewrote README: smaller and more direct, removed the hero header, added a "Flags & Environment Variables" section documenting installer flags, command flags, and environment variables.
- **AGENTS.md agent instructions refreshed** to match the current repo: the structure tree now lists `shared/local-override-shell-init.sh`, the shared test harness (`tests/test-lib.sh`), `tests/coverage.sh`, `tests/bench-filter-process.sh`, the linked-worktree suite (`tests/integration/test-worktrees.sh`), `Formula/`, `VERSION`, `plans/`, and the `CLAUDE.md -> AGENTS.md` symlink; the Testing section documents `make ci` as the single CI-parity command plus `make test-docker-worktree` and the opt-in `make coverage`; the CLI function list adds `cmd_validate`/`cmd_doctor`/`cmd_shell_init`/`cmd_version` and the `--all-worktrees` flags; and the file now states the shared-harness rule and the resolver mirror rule (`make check-resolver-sync`)

### Removed

- **The `fd`-based discovery strategy** (and its install recommendation across README/CONTRIBUTING/requirements). `fd --hidden --no-ignore` descended into `.git/` (every loose object) and every gitignored tree, which dominated hook cost on large monorepos; discovery is now a pure `git ls-files` implementation with the `hot`/`full` modes above. The trace field `discover_config_files strategy=fd|git` is now `strategy=hot|full`. `fd` is no longer a dependency, optional or otherwise

### Fixed

- **`scripts/release.sh` no longer strips the executable bit off `bin/git-local-override`**: the doc-pin bump wrote each file via `sed > tmp && mv tmp file`, and `mv` of a fresh temp file reset the mode to the umask default — dropping the `+x` bit on the CLI, so every hook and test that execs it failed with `Permission denied` right after a release prep. The bump now copies the rewritten content back into the original inode (`cat tmp > file`), preserving the file's existing mode
- **`validate` no longer runs config discovery twice per invocation.** `cmd_validate` called `has_any_config` *before* `cache_config_files`, so the check missed the in-process cache and paid a throwaway full discovery walk, then `cache_config_files` walked a second time — visible as two `strategy=full` trace lines where every other command logs one. Reordered to cache first (matching `cmd_sync_filters`), so `has_any_config` hits the cache. Pure reordering, no output change; saves one full discovery walk per `validate`, which matters most in CI where the repo is often cold (3–5× the warm cost)
- **Configs inside `.git/` or inside a wholly-gitignored directory are no longer discovered or honored.** The old `fd --no-ignore` strategy (and the old unconditional ignored pass) could discover and act on a `.local-overrides.yaml` planted inside `.git/` or inside a vendored/gitignored tree (e.g. an npm package shipping a config plus override files), letting third-party content overwrite arbitrary repo files at checkout. Discovery now skips both. Configs whose own path is gitignored but whose parent directory is walked (the documented gitignored-config use case) remain fully supported
- **Test-infra hygiene**: the four integration runner loops no longer overwrite `CURRENT_TEST_STATUS` with the test function's raw return code — they key fail-fast and artifact preservation off `CURRENT_TEST_STATUS` (which `fail()` sets to 1) like the unit runner, so a future test that calls `fail` without `return 1` still stops the suite and preserves its test root under `TEST_KEEP_ARTIFACTS=1` instead of silently continuing and deleting it (latent today: all ~327 `fail` sites currently `return 1`). `tests/run-docker.sh` now passes `-e CI=true` so the dev launcher reproduces the Makefile gate's assertions (the worktree fd-strategy legs hard-fail instead of soft-skipping). The Docker test image pins `pre-commit==4.6.*` (was unpinned `pip3 install pre-commit`, rebuilt every CI run) so an upstream release can't break CI on an unrelated PR
- **Five integration tests that could not fail now assert the behaviors they are named after**: `test_precommit_run_pre_commit` (was both `if` arms `pass`) now asserts the pre-commit hook restored the original content to both the index and the working tree; `test_new_repo_gets_hooks_after_global_install` (was else-branch `pass` with a "may be expected" note) now hard-fails if `git init` didn't copy the template hooks (a core-git behavior, not version-dependent); `test_precommit_checkout_flow` (asserted only branch creation) now asserts the post-checkout hook applied the override on a clean branch switch — and drops the self-defeating `git checkout -- .` preamble that pre-dirtied the target and tripped pre-commit's post-checkout stash/rollback; `test_precommit_with_other_hooks` (asserted only commit exit 0) now asserts the committed content is the original and the post-commit hook re-applied the override, alongside a third `check-readme` hook; and `test_pull_with_overridden_file` (ran `git merge`, byte-similar to the merge test) now performs a real `git pull` from a second cloned repository (fetch + merge) and confirms the pulled commit landed
- **bash 3.2 CI lane now runs genuine bash 3.2.57**: the `make test-docker-bash3` lane was based on `alpine:3.19`, whose bash is 5.2.x, so the project's hardest rule ("all scripts must work on bash 3.2") was enforced by no CI lane. The lane now uses Docker Hub's `bash:3.2` image (real from-source bash 3.2.57 at `/usr/local/bin/bash`), and `tests/docker/entrypoint.sh` asserts the interpreter major version via `EXPECT_BASH_MAJOR` so the lane hard-fails if the image ever regresses to a newer bash. The native macOS CI job now pins `#!/usr/bin/env bash` to `/bin/bash` (macOS's 3.2.57) for all steps via `$GITHUB_PATH` and asserts `BASH_VERSINFO[0] -eq 3`, instead of only echoing an informational `bash --version`. The bash3 Makefile target label is relabeled from "macOS compatibility" to "bash-version compatibility" (the lane is a bash-version + musl-portability check with busybox userland, not a BSD-userland check)
- **`status` now recognizes the experimental `filter.process` driver**: a repo installed in the opt-in `GIT_LOCAL_OVERRIDE_FILTER_PROCESS=1` mode (plan 019) previously showed `Filter: not installed` in `status` even though `doctor` passed. `status` now reports `Filter: installed (filter.process, experimental)` and follows the same attributes-count path as the smudge/clean driver
- **`uninstall.sh` now removes every installed artifact**: it deletes `local-override-shell-init.sh` from the CLI data dir (so the data dir is then empty and gets `rmdir`'d as intended) and `local-override-filter-process` from hook directories (previously it survived in `.git/hooks/` and the global template dir, where every future `git clone` copied the stale script into new repos). The installed-file manifest was duplicated between `install.sh` and `uninstall.sh` with no shared list, so two recently added files drifted out of the uninstaller
- **User-facing doc gaps**: the README CLI Commands table now lists `doctor` (previously only in help/dispatch/troubleshooting prose); the "What Gets Installed" `--cli` line now names all support files written to the CLI data dir (`local-override-shell-init.sh` and `VERSION` alongside `local-override-resolver.sh`); the CONTRIBUTING project tree now lists `shared/` (both modules), the shared test harness and the linked-worktree suite, `Formula/`, and `VERSION`, and its PR checklist leads with `make ci`; and `docs/DESIGN.md`'s command list adds `validate`, `doctor`, `shell-init`, and `version`

## [0.7.0] - 2026-07-11

### Security

- **Symlinked target/override write escape**: refuse symlinked managed targets and override files (and paths resolving outside the repo root) during checkout/commit/apply/restore and in the smudge/clean filters, so a malicious repository cannot use a committed symlink target to write outside the checkout

### Added

- **`git-local-override doctor`** runs read-only health checks (config present/valid, hooks installed, filter driver configured, attributes in sync, legacy skip-worktree bits) and prints a pass/warn/fail report, exiting non-zero when any check fails — one command that absorbs the manual troubleshooting recipes. The filter-driver check treats `(smudge + clean)` **or** the experimental `filter.process` mode as healthy. `doctor --fix` applies the single proven repair — a missing filter driver — by delegating to the existing `sync-filters` path (which also re-syncs attributes and clears legacy skip-worktree bits); every other issue stays reported-only. More `--fix` repairs are planned as follow-ups (see `plans/021-doctor-design.md`)
- **`git-local-override validate`** checks all discovered `.local-overrides.yaml` files (duplicate targets, subtree escapes, traversal, etc.) and exits non-zero on any problem — usable in CI without a git operation
- **Experimental opt-in long-running `filter.process` prototype** (spike, plan 019): a new `hooks/local-override-filter-process` speaks git's long-running filter protocol so one process serves an entire checkout instead of git spawning a fresh bash per managed file. **Opt-in only** — wired to `filter.local-override.process` when `GIT_LOCAL_OVERRIDE_FILTER_PROCESS=1` is set at install time; the default remains the per-file `%f` smudge/clean scripts and is byte-for-byte unchanged. It reuses the shared resolver smudge/clean cores, so content is byte-identical to the `%f` path (all plan-009 binary/NUL/CRLF/empty/no-newline roundtrip cases pass through the real protocol on Bash 3.2 and 5.x). Benchmarking (`tests/bench-filter-process.sh`) shows the pure-bash pkt-line framing overhead offsets the bash-startup savings: it is slower for typical repos (N ≤ 10) and wins only marginally (~4–9%) for large monorepos (N ≥ 50) on Linux, so it stays experimental and is **not** the default. See `plans/019-filter-process-design.md` for the full go/no-go analysis
- **`make coverage` diagnostic**: runs the unit suite (`tests/run-tests.sh`) under `kcov` inside the Docker test image and writes an HTML report to the gitignored `coverage/` directory to surface untested branches (opt-in; not a CI gate). The report covers the directly-invoked CLI (`bin/git-local-override`) and its sourced resolver (`shared/local-override-resolver.sh`); the `hooks/` scripts are not attributed because the suite runs hook *copies* installed into each test repo's `.git/hooks/`, whose paths fall outside kcov's include set
- **Linked worktree support**: worktrees without their own `.local-overrides.yaml` now resolve configs and override files against the main worktree (worktree-local config wins; disable with `GIT_LOCAL_OVERRIDE_DISABLE_WORKTREE_FALLBACK=1`)
- **`apply --all-worktrees`**: refresh materialized overrides in the main checkout and every linked worktree in one command
- **`restore --all-worktrees`**: restores original tracked content in the main checkout and every linked worktree in one command, mirroring `apply --all-worktrees`
- **Filter roundtrip content coverage**: roundtrip tests now cover binary (NUL bytes), CRLF, empty, no-trailing-newline, and multiple-trailing-newline content on both the tracked blob and override sides, via file-based `cmp` comparison (command substitution strips trailing newlines and cannot carry NUL bytes, so the previous string-based test could not catch these corruptions)
- **Cherry-pick and special-character filename test coverage**: added integration tests for `git cherry-pick` with an overridden file (asserting the cherry-picked commit carries the tracked content while the working tree keeps the override) and for the full add/apply/commit/post-commit roundtrip of a managed target whose name contains a space and a non-ASCII byte

### Fixed

- **Stale documentation version examples**: documentation version examples (README, CLI `help`, `.pre-commit-hooks.yaml`, `SECURITY.md`) now reference the current release instead of the stale `v0.3.0`/`v0.4.0` pins, and are bumped to `v0.7.0` with this release, so copied install/pre-commit snippets fetch the current build
- **Stale overrides after editing a gitignored/untracked config**: editing a gitignored/untracked `.local-overrides.yaml` between checkouts no longer leaves stale overrides applied: `post-checkout`'s fast path now falls back to full discovery when the on-disk config set drifts from what the recorded attributes were built from (a per-worktree content stamp of the discovered configs, recorded after each full resolution)
- **Special-character managed target names leaking override content**: managed targets whose names contain tabs, quotes, backslashes, or non-ASCII bytes are now correctly matched and restored before commit (`pre-commit` reads staged files NUL-delimited with `core.quotePath=false`), and worktree enumeration is NUL-delimited (`worktree list --porcelain -z` on git >= 2.36, with a newline-terminated fallback on older gits) so worktree paths containing newlines parse correctly
- **Malformed config entry silently truncating the effective override map**: a `.local-overrides.yaml` whose `override:`/`replaces:` path is invalid or escapes its subtree is now rejected by validation with a clear error, instead of silently dropping that entry and every entry after it in the same config file
- **Config-derived paths interpreted as git options**: config-derived target paths are now passed to `git add`/`git ls-files` after a `--` separator, so a target whose name starts with `-` cannot be interpreted as a git option
- **Glob-unsafe repo prefix strip**: `git-local-override add`/`remove` now strip the repo prefix with a quoted pattern, so absolute paths under a checkout whose directory name contains glob characters (`[`, `]`, `*`, `?`) normalize correctly
- **Cache temp file leak on failed commands**: the config-discovery cache temp file is now removed on all exit paths (including `die`), fixing a slow temp-file leak on failed commands
- **New managed target committing override content**: refuse to commit a brand-new managed target that holds local override content and has no tracked canonical version, instead of silently committing the local content into history. Introducing a new managed target now requires staging genuine canonical content (or removing it from `.local-overrides.yaml`) first
- **Overrides vanishing on aborted / mid-rebase commits**: overrides no longer silently vanish from the working tree when a commit is aborted after the pre-commit restore, or when committing during a rebase. `pre-commit` now bails during a rebase, and a leftover reapply state file is re-applied on the next checkout
- **Nested-worktree config pollution**: config files inside linked worktrees checked out under the main worktree's directory are no longer treated as the main checkout's subtree configs
- **`status`/`list` performance**: config discovery is now cached per invocation (previously re-scanned per target; multi-minute hangs in large monorepos with many worktrees)
- **Discovery cache correctness**: the cache is keyed by resolution root, so one invocation querying two roots (worktree + main) cannot return the wrong root's results
- **Legacy CLI clean filter clobbering staged edits**: `git-local-override filter-clean` substituted HEAD content unconditionally; it now matches the hook filter (exact-match `cmp` gate, index blob), so legitimately staged edits to managed files survive
- **Discovery walk descending into nested worktrees**: the fd discovery strategy now prunes linked-worktree directories during traversal instead of only discarding their results afterwards; `status` in a monorepo with 42 nested checkouts drops from ~2m24s to ~10s
- **Rebase-internal checkouts triggering discovery**: `post-checkout` now bails on an in-progress rebase before resolving the resolution root, so per-commit rebase checkouts in fallback worktrees no longer run config discovery
- **Dead variable in pre-commit hook**: removed an unused `matched_config` local (shellcheck SC2034) that would fail the now-gating lint

### Changed

- **`shell-init` snippet extracted into its own support module**: the shell integration wrapper previously embedded in `bin/git-local-override` as a heredoc now lives in `shared/local-override-shell-init.sh`; `git-local-override shell-init` locates it with the same dev-or-installed fallback used for the shared resolver (`$SCRIPT_DIR/../shared/…` in a checkout, else `${XDG_DATA_HOME:-$HOME/.local/share}/git-local-override/…` when installed) and emits it verbatim. The installer copies the module into the CLI support data directory alongside the resolver. Output is byte-identical to before; this is the proof-of-concept extraction validating the god-file split approach (see `plans/017-god-file-split-design.md`)
- **Test assertion harness consolidated in `tests/test-lib.sh`**: the `pass`/`fail`/`info` helpers, the `RED`/`GREEN`/`YELLOW`/`NC` colors, and the `TESTS_RUN`/`TESTS_PASSED`/`TESTS_FAILED` counters now live once in `tests/test-lib.sh` with a single `finish_suite` exit helper, replacing five drifted per-file copies. Every suite is green iff `TESTS_FAILED == 0`; the unit suite (`tests/run-tests.sh`), whose `pass()` is called once per test, additionally opts into the stricter `TESTS_PASSED == TESTS_RUN` invariant via `STRICT_PASS_COUNT=1` (so a test that starts but never reaches a `pass()` still fails the build). Printed totals are unchanged
- **Shared helpers consolidated in the resolver**: the path/timing/count/trace helpers (`get_repo_root`, `get_common_git_dir`, `get_attributes_file_path`, the millisecond timers, the trace-enabled check, the list-count helper) and the `clear_legacy_skip_worktree` family now live once in the shared resolver instead of being duplicated (and drifting) across the CLI and hook lib; the two `get_common_git_dir` copies had already diverged (`die` vs return-non-zero) and are reconciled on the return-non-zero contract with the CLI dying at its call sites. Also removed the dead `get_active_overrides` helper (zero callers)
- **Legacy `skip-worktree` repair now runs once per checkout** (guarded by a per-worktree marker) plus on install/`sync-filters`, instead of on every `post-checkout` and `pre-commit` — removing 2 `git` subprocesses per managed target from the commit/checkout hot paths. `sync-filters` remains the escape hatch: it always runs the ungated repair and (re)writes the marker, so a stray `skip-worktree` bit that appears mid-session is cleared by running `git-local-override sync-filters`
- **Unified smudge/clean filter implementation**: the `git-local-override filter-smudge`/`filter-clean` subcommands and the git-invoked filter hooks now share one implementation in the resolver (`run_local_override_smudge`/`run_local_override_clean`), eliminating drift (the CLI subcommands previously lacked the clean filter's trace logging). The smudge core keeps its intentional rebase-passthrough guard while the clean core intentionally has none (commit 75d4df6); a new test asserts the CLI subcommand output is byte-identical to the hook script output
- **Config/discovery hot-path performance**: dedup on the config, discovery, and attributes-reader hot paths now uses fork-free in-shell membership tests instead of a `grep` subprocess per entry (removing the O(N²) fork-per-entry cost), and the clean filter reads index content with a single `git show` instead of two
- **Legacy CLI filter subcommands** (`filter-smudge` / `filter-clean`) now match the hook filters exactly, including worktree fallback and rebase passthrough. Edge: a user who hand-edits a managed target beyond the applied override and stages it now commits those edits (previously silently reverted to HEAD)
- **CI hardening**: CI pins the shellcheck action to a released version (2.0.0, by commit SHA), runs with a read-only `GITHUB_TOKEN`, lints `shared/` and `tests/`, and fails if the `shared/` and `hooks/` resolver copies drift. `make lint` now gates (severity `warning`, matching CI) instead of always succeeding
- **New `make ci` target** runs the full CI-equivalent suite (lint, resolver sync, both Docker test suites) in one command; `CONTRIBUTING.md` now points at it as the single parity command

## [0.6.0] - 2026-06-10

### Fixed

- **`status` hook detection in worktrees**: `git-local-override status` resolved hooks via a hardcoded `.git/hooks` path, so it always reported `Hooks: not installed` from linked worktrees; it now resolves the hooks directory with `git rev-parse --git-path hooks`, which also honors `core.hooksPath`
- **`status` hook detection for pre-commit installs**: hooks installed via the pre-commit framework produce generic shims without the `local-override` marker, so `status` reported them as not installed; framework shims backed by `local-override-*` hook ids in `.pre-commit-config.yaml` are now reported as `installed (via pre-commit)`

## [0.5.0] - 2026-04-17

### Added

- **Checkout lifecycle logging**: `post-checkout` now emits `git-local-override: ... started` and `... finished` stderr logs so slow branch switches are visible while they happen
- **Optional trace mode**: `GIT_LOCAL_OVERRIDE_TRACE=1` now adds start/end stderr logs for smudge filter executions during checkout debugging
- **`apply` progress logging**: `git-local-override apply` now reports validation, config resolution, active override counts, attribute sync, and total elapsed time so long recursive runs are no longer silent
- **Path-rich apply output**: `git-local-override apply` now prints repo-relative target and override paths such as `./AGENTS.md <- ./CLAUDE.private.md` so repeated filenames are easier to distinguish
- **Deep `apply` trace logging**: `GIT_LOCAL_OVERRIDE_TRACE=1 git-local-override apply` now logs repo/config discovery timing, per-target `cp` vs `git add` timing, resolver summaries, `sync_attributes` breakdown, and clean-filter phase timings to help isolate long-running apply calls

### Changed

- **`sync-filters` now shows progress logging**: Added `info` messages before each major step (validating config, syncing filter driver, syncing attributes, checking legacy skip-worktree) so users can see what the command is doing
- **`apply` config reuse**: `git-local-override apply` now resolves effective config entries once and reuses them for the apply loop and attribute sync instead of reparsing recursive config multiple times
- **Config discovery strategy**: Full config discovery now prefers `fd` for exact filename lookup when available, and `apply` caches config discovery before checking for config presence so startup avoids an extra whole-repo scan
- **Large-monorepo performance docs**: README and contributor docs now recommend installing `fd` on `PATH` to speed config discovery and explain how to verify the active strategy with trace output
- **Commit hook hot path**: `pre-commit` now resolves only staged-file-relevant configs without triggering full-repo config discovery, and restages restored originals with filters disabled; `post-commit` now reapplies only exact target/override pairs recorded by `pre-commit` instead of rescanning and validating the whole repo on every commit

### Fixed

- **Docker pre-commit worktree failures**: Docker test images now exclude host `.git` metadata and rebuild the copied project as a standalone git repo, so `repo: $PROJECT_DIR` pre-commit integration tests work from git worktrees as well as normal clones
- **pre-commit migration duplicate hook runs**: Reinstall now removes duplicate `*.legacy` git-local-override hooks that pre-commit left behind in migration mode both before and after the canonical hook has already been transitioned into a managed wrapper, avoiding a second managed hook execution during stages like `post-checkout`
- **Common-case post-checkout latency in large repos**: `post-checkout` now skips full recursive config discovery when `.local-overrides.yaml` files did not change across the checkout and managed targets are already recorded in `.git/info/attributes`, falling back to the slower validation path only when config state changed or local generated state is missing
- **Checkout hook latency in large repos**: `post-checkout` and `pre-rebase` now cache recursive config discovery for the duration of a hook run, avoiding repeated full-repo `.local-overrides.yaml` scans during validation and config reads
- **`sync-filters` performance**: Cached `discover_config_files` results to eliminate repeated `git ls-files` calls (previously called O(N) times per entry via `target_is_shadowed_by_child_config`), and cached `read_config` output to avoid parsing config twice
- **All commands slow in large repos**: `discover_config_files` listed every file in the repo via unfiltered `git ls-files`, then filtered in bash. Now passes `-- .local-overrides.yaml */.local-overrides.yaml` path filter to git directly. Also added config file caching to `apply` and `restore` commands
- **Monorepo filter latency**: Clean and smudge filters now resolve single-file overrides from the nearest ancestor config instead of triggering full recursive config discovery, avoiding repeated whole-repo scans during `git add`

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

[0.9.0]: https://github.com/jonathanabila/git-override/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/jonathanabila/git-override/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/jonathanabila/git-override/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/jonathanabila/git-override/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/jonathanabila/git-override/compare/v0.4.1...v0.5.0
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
