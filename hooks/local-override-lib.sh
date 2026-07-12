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

# Re-apply overrides recorded by pre-commit, if a state file is present, then
# clear it. Safe to call when no state file exists (no-op). Used by both
# post-commit (on commit success) and post-checkout (to heal an aborted commit
# that left originals in the working tree and the state file behind).
reapply_post_commit_state() {
    local repo_root="$1"
    local state_file=""
    local entry target override
    state_file="$(get_post_commit_state_file "$repo_root" 2>/dev/null || true)"
    [[ -n "$state_file" && -f "$state_file" ]] || return 0

    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue

        # Parse entry: "target|override" (override may be absolute — anchored
        # at the resolution root by pre-commit)
        target="${entry%%|*}"
        override="${entry#*|}"
        [[ "$override" == /* ]] || override="$repo_root/$override"

        if [[ -f "$override" && -f "$repo_root/$target" ]]; then
            # $override is absolute (anchored at the resolution root by
            # pre-commit). Recover the resolution root + relative override so the
            # symlink containment check anchors on the TRUE root, never the
            # override's own (possibly symlinked) parent dir.
            local reapply_resolution_root reapply_override_rel
            reapply_resolution_root="$(get_resolution_root "$repo_root")"
            reapply_override_rel="${override#"$reapply_resolution_root"/}"
            if ! path_is_symlink_safe "$repo_root" "$target" \
               || [[ "$reapply_override_rel" == "$override" ]] \
               || ! override_path_is_symlink_safe "$reapply_resolution_root" "$reapply_override_rel" "$repo_root"; then
                # Refusing is correct but routine (e.g. an ignored symlinked
                # override exists); log at trace level so every commit does
                # not print a scary stderr line.
                local_override_trace_log "reapply" "refusing symlinked override for $target"
                continue
            fi
            cp "$override" "$repo_root/$target"
        fi
    done < "$state_file"

    rm -f "$state_file"
}

# Config-stamp helpers (get_config_stamp_file, compute_config_stamp,
# write_config_stamp, config_stamp_matches) now live once in the shared
# resolver (shared/local-override-resolver.sh), sourced above.
