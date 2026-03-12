#!/usr/bin/env bash
set -euo pipefail

test_lib_die() {
    echo "Error: $*" >&2
    return 1
}

sanitize_test_name() {
    printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_'
}

create_test_root() {
    local suite_name="${1:-test-suite}"
    local test_name="${2:-test-case}"
    local base_dir="${3:-${TMPDIR:-/tmp}}"
    local safe_suite
    local safe_test
    local test_root

    safe_suite="$(sanitize_test_name "$suite_name")"
    safe_test="$(sanitize_test_name "$test_name")"

    mkdir -p "$base_dir"
    test_root="$(mktemp -d "$base_dir/git-local-override-${safe_suite}-${safe_test}.XXXXXX")"

    mkdir -p \
        "$test_root/repo" \
        "$test_root/home/.local/bin" \
        "$test_root/xdg/git" \
        "$test_root/artifacts"

    printf '%s\n' "$test_root"
}

setup_test_env() {
    local test_root="$1"
    local project_dir="$2"
    local bin_dir="${3:-$project_dir/bin}"

    [[ -d "$test_root" ]] || test_lib_die "Test root does not exist: $test_root"
    [[ -d "$project_dir" ]] || test_lib_die "Project directory does not exist: $project_dir"

    mkdir -p \
        "$test_root/repo" \
        "$test_root/home/.local/bin" \
        "$test_root/xdg/git" \
        "$test_root/artifacts"

    export HOME="$test_root/home"
    export XDG_CONFIG_HOME="$test_root/xdg"
    export TEST_ROOT="$test_root"
    export TEST_REPO="$test_root/repo"
    export TEST_ARTIFACTS_DIR="$test_root/artifacts"

    case ":$PATH:" in
        *":$bin_dir:"*) ;;
        *) export PATH="$bin_dir:$PATH" ;;
    esac
}

cleanup_test_root() {
    local test_root="$1"

    if [[ -n "$test_root" && -d "$test_root" ]]; then
        rm -rf "$test_root"
    fi
}

preserve_test_root_on_failure() {
    local test_root="$1"
    local test_name="${2:-test-case}"
    local exit_code="${3:-0}"

    if [[ "$exit_code" -ne 0 && "${TEST_KEEP_ARTIFACTS:-0}" == "1" ]]; then
        echo "Preserved failing test root for $test_name: $test_root" >&2
        return 0
    fi

    cleanup_test_root "$test_root"
}

create_seed_repo() {
    local source_repo="$1"
    local seed_repo="$2"

    git -C "$source_repo" rev-parse --git-dir >/dev/null 2>&1 || \
        test_lib_die "Source repo is not a git repository: $source_repo"

    rm -rf "$seed_repo"
    git clone -q --bare "$source_repo" "$seed_repo"
}

clone_seed_repo() {
    local seed_repo="$1"
    local target_repo="$2"
    local user_name="${3:-Test User}"
    local user_email="${4:-test@test.com}"

    rm -rf "$target_repo"
    git clone -q "$seed_repo" "$target_repo"
    git -C "$target_repo" config user.name "$user_name"
    git -C "$target_repo" config user.email "$user_email"
}

install_test_hooks() {
    local repo_dir="$1"
    local project_dir="$2"
    local common_git_dir
    local hook_name

    git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1 || \
        test_lib_die "Repository does not exist: $repo_dir"

    common_git_dir="$(git -C "$repo_dir" rev-parse --git-common-dir)"
    if [[ "$common_git_dir" != /* ]]; then
        common_git_dir="$repo_dir/$common_git_dir"
    fi

    mkdir -p "$common_git_dir/hooks"

    cp "$project_dir/hooks/local-override-lib.sh" "$common_git_dir/hooks/"
    cp "$project_dir/hooks/local-override-filter-smudge" "$common_git_dir/hooks/"
    cp "$project_dir/hooks/local-override-filter-clean" "$common_git_dir/hooks/"

    for hook_name in post-checkout pre-commit post-commit pre-rebase; do
        cp "$project_dir/hooks/local-override-$hook_name" "$common_git_dir/hooks/$hook_name"
    done

    chmod +x "$common_git_dir/hooks"/*
}
