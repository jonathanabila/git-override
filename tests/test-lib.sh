#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Unified assertion harness (shared by every suite)
# ---------------------------------------------------------------------------
# Counting model:
#   info() starts a test      -> TESTS_RUN++
#   pass() records a success  -> TESTS_PASSED++
#   fail() records a failure  -> TESTS_FAILED++ and CURRENT_TEST_STATUS=1
#
# finish_suite() prints the summary and exits non-zero if any test failed.
#
# The unit suite (tests/run-tests.sh) calls pass() exactly once per test and
# additionally enforces the stricter invariant TESTS_PASSED == TESTS_RUN, so a
# test that starts (info) but never reaches a pass() is caught. It opts in via
# STRICT_PASS_COUNT=1. The integration suites call pass() once per assertion
# (many per test), so that invariant does not apply to them and stays off by
# default; they are green iff TESTS_FAILED == 0, matching prior behavior.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
# CURRENT_TEST_STATUS is read by each suite's per-test runner loop.
# shellcheck disable=SC2034
CURRENT_TEST_STATUS=0

pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
    ((TESTS_PASSED++)) || true
}

fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    ((TESTS_FAILED++)) || true
    # shellcheck disable=SC2034  # consumed by each suite's runner loop
    CURRENT_TEST_STATUS=1
}

info() {
    echo -e "${YELLOW}[TEST]${NC} $*"
    ((TESTS_RUN++)) || true
}

# Print the final summary and exit non-zero if the suite failed.
# Set STRICT_PASS_COUNT=1 to additionally require TESTS_PASSED == TESTS_RUN
# (used by the unit suite, whose pass() is per-test rather than per-assertion).
finish_suite() {
    local ok=1

    if [[ $TESTS_FAILED -ne 0 ]]; then
        ok=0
    fi
    if [[ "${STRICT_PASS_COUNT:-0}" == "1" && $TESTS_PASSED -ne $TESTS_RUN ]]; then
        ok=0
    fi

    echo ""
    echo "========================================"
    if [[ $ok -eq 1 ]]; then
        echo -e "  ${GREEN}All $TESTS_RUN tests passed!${NC}"
    elif [[ "${STRICT_PASS_COUNT:-0}" == "1" ]]; then
        echo -e "  ${RED}$TESTS_PASSED/$TESTS_RUN tests passed${NC}"
    else
        echo -e "  ${RED}$TESTS_FAILED/$TESTS_RUN tests failed${NC}"
    fi
    echo "========================================"
    echo ""

    [[ $ok -eq 1 ]] || exit 1
}

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
    cp "$project_dir/shared/local-override-resolver.sh" "$common_git_dir/hooks/"
    cp "$project_dir/hooks/local-override-filter-smudge" "$common_git_dir/hooks/"
    cp "$project_dir/hooks/local-override-filter-clean" "$common_git_dir/hooks/"

    for hook_name in post-checkout pre-commit post-commit pre-rebase; do
        cp "$project_dir/hooks/local-override-$hook_name" "$common_git_dir/hooks/$hook_name"
    done

    chmod +x "$common_git_dir/hooks"/*
}
