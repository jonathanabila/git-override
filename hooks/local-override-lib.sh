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

local_override_trace_enabled() {
    [[ "${GIT_LOCAL_OVERRIDE_TRACE:-0}" == "1" ]]
}

local_override_now_milliseconds() {
    if command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes=time -e 'printf("%.0f\n", time() * 1000)'
        return 0
    fi

    printf '%s000\n' "$(date +%s)"
}

local_override_elapsed_milliseconds() {
    local start_ms="$1"
    local end_ms

    end_ms="$(local_override_now_milliseconds)"
    printf '%s\n' "$((end_ms - start_ms))"
}

local_override_trace_log() {
    if local_override_trace_enabled; then
        printf 'Trace[%s]: %s\n' "${1:-hook}" "${2:-}" >&2
    fi
}

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

# Returns the ABSOLUTE path of the override file for a managed target, or
# nothing. Resolves against the checkout's resolution root, so linked
# worktrees without their own config inherit the main worktree's overrides.
get_override_for_file() {
    local repo_root="$1"
    local file_path="$2"
    local resolution_root=""
    local override=""

    resolution_root="$(get_resolution_root "$repo_root")"
    override="$(get_override_for_target "$file_path" "$resolution_root" 2>/dev/null || true)"
    [[ -n "$override" ]] || return 0

    printf '%s/%s\n' "$resolution_root" "$override"
}

get_common_git_dir() {
    local repo_root="$1"
    local common_git_dir=""

    common_git_dir="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null || echo "")"
    [[ -n "$common_git_dir" ]] || return 1

    if [[ "$common_git_dir" != /* ]]; then
        common_git_dir="$repo_root/$common_git_dir"
    fi

    printf '%s\n' "$common_git_dir"
}

get_attributes_file_path() {
    local repo_root="$1"
    local attributes_path=""

    attributes_path="$(git -C "$repo_root" rev-parse --git-path info/attributes 2>/dev/null || echo "")"
    [[ -n "$attributes_path" ]] || return 1

    if [[ "$attributes_path" != /* ]]; then
        attributes_path="$repo_root/$attributes_path"
    fi

    printf '%s\n' "$attributes_path"
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

        if printf '%s\n' "$seen_targets" | grep -qxF "$target"; then
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
        if printf '%s\n' "$seen_entries" | grep -qxF "$entry"; then
            continue
        fi

        printf '%s\n' "$entry"
        seen_entries="$seen_entries
$entry"
    done < <(read_managed_targets_from_attributes "$repo_root")
}

sync_attributes_entries() {
    local repo_root="$1"
    local config_entries="${2:-}"
    local attributes_file=""
    local temp_file=""
    local line=""
    local seen_targets=""
    local entry=""
    local target=""
    local has_targets=false

    attributes_file="$(get_attributes_file_path "$repo_root")" || return 1
    temp_file="$(mktemp)"

    mkdir -p "$(dirname "$attributes_file")"

    if [[ -f "$attributes_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == *"filter=local-override"* ]]; then
                continue
            fi
            if [[ "$line" == *"Auto-generated by git-local-override"* ]]; then
                continue
            fi
            printf '%s\n' "$line" >> "$temp_file"
        done < "$attributes_file"
    fi

    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -n "$entry" ]] || continue

        target="${entry%%|*}"
        [[ -n "$target" ]] || continue

        if printf '%s\n' "$seen_targets" | grep -qxF "$target"; then
            continue
        fi

        seen_targets="$seen_targets
$target"
        has_targets=true
    done <<< "$config_entries"

    if [[ "$has_targets" == true ]]; then
        if [[ -s "$temp_file" ]]; then
            printf '\n' >> "$temp_file"
        fi

        printf '%s\n' '# Auto-generated by git-local-override — do not edit manually' >> "$temp_file"

        while IFS= read -r target || [[ -n "$target" ]]; do
            [[ -n "$target" ]] || continue
            printf '%s filter=local-override\n' "$target" >> "$temp_file"
        done <<< "$seen_targets"
    fi

    mv "$temp_file" "$attributes_file"
}

get_post_commit_state_file() {
    local repo_root="$1"
    local common_git_dir=""

    common_git_dir="$(get_common_git_dir "$repo_root")" || return 1
    printf '%s\n' "$common_git_dir/local-override-post-commit-state"
}

clear_post_commit_state() {
    local repo_root="$1"
    local state_file=""

    state_file="$(get_post_commit_state_file "$repo_root" 2>/dev/null || true)"
    [[ -n "$state_file" ]] || return 0

    rm -f "$state_file"
}

clear_legacy_skip_worktree() {
    local repo_root="$1"
    local config_entries="${2:-}"
    local repaired_count=0
    local seen_targets=""
    local entry=""
    local target=""
    local ls_output=""

    if [[ -z "$config_entries" ]]; then
        config_entries="$(read_config "$repo_root")"
    fi

    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue

        target="${entry%%|*}"
        [[ -n "$target" ]] || continue

        if echo "$seen_targets" | grep -qxF "$target"; then
            continue
        fi
        seen_targets="$seen_targets
$target"

        if ! git -C "$repo_root" ls-files --error-unmatch -- "$target" >/dev/null 2>&1; then
            continue
        fi

        ls_output="$(git -C "$repo_root" ls-files -v -- "$target" 2>/dev/null || true)"
        if [[ "${ls_output:0:1}" != "S" ]]; then
            continue
        fi

        git -C "$repo_root" update-index --no-skip-worktree -- "$target"
        ((repaired_count++)) || true
    done <<< "$config_entries"

    printf '%s\n' "$repaired_count"
}

get_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

is_rebase_in_progress() {
    local repo_root="$1"
    local rebase_merge_path=""
    local rebase_apply_path=""

    rebase_merge_path="$(git -C "$repo_root" rev-parse --git-path rebase-merge 2>/dev/null || true)"
    rebase_apply_path="$(git -C "$repo_root" rev-parse --git-path rebase-apply 2>/dev/null || true)"

    if [[ "${GIT_REFLOG_ACTION:-}" == rebase* ]]; then
        return 0
    fi

    if [[ -n "$rebase_merge_path" && -d "$rebase_merge_path" ]]; then
        return 0
    fi

    if [[ -n "$rebase_apply_path" && -d "$rebase_apply_path" ]]; then
        return 0
    fi

    return 1
}
