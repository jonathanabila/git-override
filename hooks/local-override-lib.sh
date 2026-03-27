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

get_override_for_file() {
    local repo_root="$1"
    local file_path="$2"

    get_override_for_target "$file_path" "$repo_root" || return 0
}

clear_legacy_skip_worktree() {
    local repo_root="$1"
    local repaired_count=0
    local seen_targets=""
    local entry=""
    local target=""
    local ls_output=""

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
    done < <(read_config "$repo_root")

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
