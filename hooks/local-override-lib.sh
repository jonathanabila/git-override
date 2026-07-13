#!/usr/bin/env bash
#
# local-override-lib.sh
#
# Shared library for git-local-override hooks.
# This file is sourced by the hook scripts.
#

HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_LIB_DIR="$(cd "$HOOK_LIB_DIR/.." 2>/dev/null && pwd || true)"
SHARED_RESOLVER_PATH=""

if [[ -f "$HOOK_LIB_DIR/local-override-resolver.sh" ]]; then
    SHARED_RESOLVER_PATH="$HOOK_LIB_DIR/local-override-resolver.sh"
elif [[ -n "$REPO_LIB_DIR" && -f "$REPO_LIB_DIR/shared/local-override-resolver.sh" ]]; then
    SHARED_RESOLVER_PATH="$REPO_LIB_DIR/shared/local-override-resolver.sh"
else
    echo "Error: local-override-resolver.sh not found" >&2
    return 1 2>/dev/null || exit 1
fi

# shellcheck source=local-override-resolver.sh
source "$SHARED_RESOLVER_PATH"

local_override_log() {
    printf 'git-local-override: %s\n' "$*" >&2
}

# local_override_trace_log now lives once in the shared resolver (sourced
# above) as a tag-aware implementation. lib.sh no longer shadows it.

run_with_lifecycle_logging() {
    local operation_name="$1"
    shift

    local exit_code=0

    local_override_log "$operation_name started"
    "$@"
    exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        local_override_log "$operation_name finished"
        return 0
    fi

    local_override_log "$operation_name failed (exit $exit_code)"
    return "$exit_code"
}

run_with_trace_logging() {
    local operation_name="$1"
    shift

    if local_override_trace_enabled; then
        run_with_lifecycle_logging "$operation_name" "$@"
        return $?
    fi

    "$@"
}

read_managed_targets_from_attributes() {
    local repo_root="$1"
    local attributes_file=""
    local seen_targets=""
    local line=""
    local target=""

    attributes_file="$(get_attributes_file_path "$repo_root" 2>/dev/null || true)"
    [[ -n "$attributes_file" && -f "$attributes_file" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        [[ "$line" == \#* ]] && continue
        [[ "$line" == *"filter=local-override"* ]] || continue

        target="${line%% filter=local-override*}"
        [[ -n "$target" ]] || return 1

        if [[ $'\n'"$seen_targets"$'\n' == *$'\n'"$target"$'\n'* ]]; then
            continue
        fi

        printf '%s\n' "$target"
        seen_targets="$seen_targets
$target"
    done < "$attributes_file"
}

read_config_entries_from_attributes() {
    local repo_root="$1"
    local seen_entries=""
    local target=""
    local override=""
    local entry=""

    while IFS= read -r target || [[ -n "$target" ]]; do
        [[ -n "$target" ]] || continue

        override="$(get_override_for_target "$target" "$repo_root" 2>/dev/null || true)"
        [[ -n "$override" ]] || return 1

        entry="$target|$override"
        if [[ $'\n'"$seen_entries"$'\n' == *$'\n'"$entry"$'\n'* ]]; then
            continue
        fi

        printf '%s\n' "$entry"
        seen_entries="$seen_entries
$entry"
    done < <(read_managed_targets_from_attributes "$repo_root")
}

# sync_attributes_entries now lives in the shared resolver (sourced above) as
# the single canonical attributes-rewrite core. See
# shared/local-override-resolver.sh.

# Keyed to the per-worktree git dir so different checkouts of the same repo
# don't share transient commit state.
get_post_commit_state_file() {
    local repo_root="$1"
    local worktree_git_dir=""

    worktree_git_dir="$(git -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null || echo "")"
    [[ -n "$worktree_git_dir" ]] || return 1

    printf '%s\n' "$worktree_git_dir/local-override-post-commit-state"
}

clear_post_commit_state() {
    local repo_root="$1"
    local state_file=""

    state_file="$(get_post_commit_state_file "$repo_root" 2>/dev/null || true)"
    [[ -n "$state_file" ]] || return 0

    rm -f "$state_file"
}

# Writer counterpart of reapply_post_commit_state — the only place the
# reapply-state record format is produced. For every override in the
# newline-delimited <overrides> list, records one `target|override` line per
# target in <entries> (the Group expansion), deduped. Overrides are recorded
# as ABSOLUTE paths anchored at the resolution root so the reapply runs from
# the resolution root, not the (possibly fallback) checkout; the reader
# (reapply_post_commit_state) keeps a legacy relative fallback for state
# files written by older installs.
# $1 = repo root (state file location), $2 = resolution root,
# $3 = override files to record, $4 = `target|override` entries.
record_reapply_state() {
    local repo_root="$1"
    local resolution_root="$2"
    local overrides="$3"
    local entries="$4"

    local state_file=""
    state_file="$(get_post_commit_state_file "$repo_root")" || return 1

    local override_file target state_entry state_entries=""
    while IFS= read -r override_file || [[ -n "$override_file" ]]; do
        [[ -z "$override_file" ]] && continue

        while IFS= read -r target || [[ -n "$target" ]]; do
            [[ -z "$target" ]] && continue
            state_entry="$target|$resolution_root/$override_file"
            if [[ $'\n'"$state_entries"$'\n' != *$'\n'"$state_entry"$'\n'* ]]; then
                state_entries="$state_entries
$state_entry"
            fi
        done < <(targets_for_override_in_entries "$override_file" "$entries")
    done <<< "$overrides"

    printf '%s\n' "$state_entries" > "$state_file"
}

# Re-apply overrides recorded by pre-commit, if a state file is present, then
# clear it. Safe to call when no state file exists (no-op). Used by both
# post-commit (on commit success) and post-checkout (to heal an aborted commit
# that left originals in the working tree and the state file behind).
reapply_post_commit_state() {
    local repo_root="$1"
    local state_file=""
    local resolution_root=""
    local entry target override apply_status
    state_file="$(get_post_commit_state_file "$repo_root" 2>/dev/null || true)"
    [[ -n "$state_file" && -f "$state_file" ]] || return 0

    resolution_root="$(get_resolution_root "$repo_root")"

    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue

        # Parse entry: "target|override" (override is absolute — anchored at
        # the resolution root by pre-commit; legacy relative entries anchor
        # at the checkout). The resolver's write-side front door recovers the
        # resolution-root-relative form so the symlink containment check
        # anchors on the TRUE root, and logs refusals at trace level only:
        # refusing is correct but routine here (e.g. an ignored symlinked
        # override exists), and must not print on every commit.
        target="${entry%%|*}"
        override="${entry#*|}"
        [[ "$override" == /* ]] || override="$repo_root/$override"

        apply_status=0
        apply_override_to_target "$repo_root" "$resolution_root" "$target" "$override" trace \
            || apply_status=$?
        # A failed copy aborts (leaving the state file for the next heal);
        # skips and refusals fall through to the next entry.
        [[ "$apply_status" -eq 3 ]] && return 1
    done < "$state_file"

    rm -f "$state_file"
}

# Config-stamp helpers (get_config_stamp_file, compute_config_stamp,
# write_config_stamp, config_stamp_matches) now live once in the shared
# resolver (shared/local-override-resolver.sh), sourced above.

# Self-heal a missing filter driver (plan 050).
#
# The pre-commit-framework install path copies only the four hook entry points
# and never configures `filter.local-override.*`, so the managed
# `filter=local-override` lines post-checkout writes into .git/info/attributes
# reference a driver git treats as identity: checkout/merge friction, a
# permanently dirty status, and — for path-limited commits — the override left
# staged in the main index where a later `git commit --no-verify` commits it
# verbatim. When a hook runs with config to enforce but no driver configured
# anywhere, copy the filter machinery from the running hook's own directory
# (the framework's cache clone ships the full hooks/ dir next to the entry
# points) into `$common_git_dir/hooks/` — the exact layout scripts/install.sh
# and `sync-filters` produce — and point the driver config at those stable
# copies. The cache clone path itself is never written into config: it moves
# on rev bumps and `pre-commit gc/clean`.
#
# Contract:
# - No-op (a single `git config` spawn, zero writes) when any driver is
#   already configured — install.sh/template installs see no behavior change.
# - Callers gate on "this repo has git-local-override config to enforce";
#   this function does not re-check config presence.
# - Never breaks the calling hook: every failure path returns 0 and logs at
#   trace level only (GIT_LOCAL_OVERRIDE_TRACE=1).
maybe_self_heal_filter_driver() {
    local repo_root="$1"

    # Cheap gate, checked on every hook run: any effective smudge/clean/process
    # driver — local (install.sh, sync-filters, a previous heal) or global
    # (template install), including the experimental filter.process opt-in —
    # means a working or intentionally customized setup. Leave it alone.
    if git -C "$repo_root" config --get-regexp \
        '^filter\.local-override\.(smudge|clean|process)$' >/dev/null 2>&1; then
        return 0
    fi

    local common_git_dir=""
    common_git_dir="$(get_common_git_dir "$repo_root" 2>/dev/null)" || return 0
    [[ -n "$common_git_dir" ]] || return 0

    local dest_dir="$common_git_dir/hooks"

    # The filter entry points source local-override-lib.sh, which sources
    # local-override-resolver.sh: all four files must travel together into
    # $dest_dir or the copied driver cannot run. The filter scripts and lib
    # ship next to the hook entry points; the resolver's true location is
    # $SHARED_RESOLVER_PATH (a hooks-dir sibling on direct installs, ../shared
    # in a source checkout such as the pre-commit framework's cache clone).
    local required_file
    for required_file in \
        local-override-filter-smudge \
        local-override-filter-clean \
        local-override-lib.sh; do
        if [[ ! -f "$HOOK_LIB_DIR/$required_file" ]]; then
            local_override_trace_log "self-heal" \
                "filter driver unconfigured but $required_file is not next to the hooks; skipping"
            return 0
        fi
    done
    if [[ -z "$SHARED_RESOLVER_PATH" || ! -f "$SHARED_RESOLVER_PATH" ]]; then
        local_override_trace_log "self-heal" \
            "filter driver unconfigured but the shared resolver cannot be located; skipping"
        return 0
    fi

    if ! mkdir -p "$dest_dir" 2>/dev/null; then
        local_override_trace_log "self-heal" "cannot create $dest_dir; skipping"
        return 0
    fi

    # local-override-filter-process is part of the install.sh hooks layout but
    # not needed by the default smudge/clean driver; copy it when present.
    # The resolver copies from $SHARED_RESOLVER_PATH rather than $HOOK_LIB_DIR
    # (see the required-files note above).
    local heal_file heal_source
    for heal_file in \
        local-override-filter-smudge \
        local-override-filter-clean \
        local-override-filter-process \
        local-override-lib.sh \
        local-override-resolver.sh; do
        heal_source="$HOOK_LIB_DIR/$heal_file"
        [[ "$heal_file" == local-override-resolver.sh ]] && heal_source="$SHARED_RESOLVER_PATH"
        [[ -f "$heal_source" ]] || continue
        # Direct installs run the hooks from $dest_dir itself; never copy a
        # file onto itself.
        if [[ ! "$heal_source" -ef "$dest_dir/$heal_file" ]]; then
            if ! cp "$heal_source" "$dest_dir/$heal_file" 2>/dev/null; then
                local_override_trace_log "self-heal" \
                    "cannot copy $heal_file into $dest_dir; skipping"
                return 0
            fi
        fi
        chmod +x "$dest_dir/$heal_file" 2>/dev/null || true
    done

    # The resolver's configure_filter_driver is the single writer of the
    # driver config (same layout install.sh and sync-filters produce). Config
    # not yet set (partial failure above returns before this), so the gate
    # retries the heal on the next hook run if anything here fails.
    if ! configure_filter_driver "$repo_root" "$dest_dir" scripts 2>/dev/null; then
        local_override_trace_log "self-heal" "unable to write filter driver config; skipping"
        return 0
    fi

    local_override_log "configured missing filter driver (self-heal): $dest_dir"
}
