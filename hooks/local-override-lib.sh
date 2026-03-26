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
