#!/usr/bin/env bash
#
# Integration tests for linked-worktree support:
# - resolution-root fallback (worktrees inherit the main checkout's overrides)
# - worktree-local config precedence and the fallback escape hatch
# - nested-checkout exclusion from config discovery
# - apply --all-worktrees
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/../test-lib.sh"

TEST_DIR=""
CURRENT_TEST_ROOT=""
CURRENT_TEST_NAME=""
CURRENT_TEST_STATUS=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    ((TESTS_FAILED++)) || true
}

info() {
    echo -e "${YELLOW}[TEST]${NC} $*"
    ((TESTS_RUN++)) || true
}

finalize_current_test_root() {
    local status="${1:-0}"

    if [[ -n "$CURRENT_TEST_ROOT" ]]; then
        cd "$PROJECT_DIR"
        preserve_test_root_on_failure "$CURRENT_TEST_ROOT" "$CURRENT_TEST_NAME" "$status"
        CURRENT_TEST_ROOT=""
    fi
}

cleanup_on_exit() {
    local exit_code=$?
    local final_status="${CURRENT_TEST_STATUS:-0}"

    if [[ "$final_status" -eq 0 && "$exit_code" -ne 0 ]]; then
        final_status="$exit_code"
    fi

    finalize_current_test_root "$final_status"
}

trap cleanup_on_exit EXIT

# Creates a repo with one managed file (AGENTS.md), a root config mapping
# CLAUDE.private.md -> AGENTS.md, and the filter driver + hooks installed the
# same way test-git-ops.sh does (direct copy into .git/hooks).
setup_repo() {
    CURRENT_TEST_ROOT="$(create_test_root "worktrees" "$CURRENT_TEST_NAME")"
    setup_test_env "$CURRENT_TEST_ROOT" "$PROJECT_DIR"
    TEST_DIR="$TEST_REPO"
    cd "$TEST_DIR"

    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"

    echo "# Tracked AGENTS.md" > AGENTS.md
    echo "# Tracked README" > README.md
    git add AGENTS.md README.md
    git commit -q -m "Initial commit"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".private"
files:
  - override: CLAUDE.private.md
    replaces:
      - AGENTS.md
EOF
    echo "# Private override content v1" > CLAUDE.private.md

    mkdir -p .git/hooks .git/info
    cp "$PROJECT_DIR/hooks/local-override-lib.sh" .git/hooks/
    cp "$PROJECT_DIR/shared/local-override-resolver.sh" .git/hooks/
    cp "$PROJECT_DIR/hooks/local-override-filter-smudge" .git/hooks/
    cp "$PROJECT_DIR/hooks/local-override-filter-clean" .git/hooks/
    cp "$PROJECT_DIR/hooks/local-override-post-checkout" .git/hooks/post-checkout
    chmod +x .git/hooks/local-override-filter-smudge \
        .git/hooks/local-override-filter-clean \
        .git/hooks/post-checkout

    git config filter.local-override.smudge "$TEST_DIR/.git/hooks/local-override-filter-smudge %f"
    git config filter.local-override.clean "$TEST_DIR/.git/hooks/local-override-filter-clean %f"
    git config filter.local-override.required false
    echo "AGENTS.md filter=local-override" > .git/info/attributes
}

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_worktree_helper_functions() {
    info "Testing is_linked_worktree / get_main_worktree_root / get_resolution_root..."

    cd "$TEST_DIR"
    git worktree add -q -b wt-helpers "$CURRENT_TEST_ROOT/wt-helpers" >/dev/null 2>&1

    local wt_root="$CURRENT_TEST_ROOT/wt-helpers"
    local result
    result="$(bash -c '
        set -euo pipefail
        . "$1/shared/local-override-resolver.sh"
        main_root="$2"
        wt_root="$3"

        if is_linked_worktree "$main_root"; then echo "main=linked"; else echo "main=not-linked"; fi
        if is_linked_worktree "$wt_root"; then echo "wt=linked"; else echo "wt=not-linked"; fi

        resolved="$(get_resolution_root "$wt_root")"
        if [[ -f "$resolved/.local-overrides.yaml" ]]; then
            echo "resolution=has-config"
        else
            echo "resolution=missing-config"
        fi

        main_of_wt="$(get_main_worktree_root "$wt_root")"
        if [[ -f "$main_of_wt/.local-overrides.yaml" ]]; then
            echo "main-of-wt=has-config"
        else
            echo "main-of-wt=missing-config"
        fi
    ' _ "$PROJECT_DIR" "$TEST_DIR" "$wt_root")"

    if echo "$result" | grep -qx "main=not-linked" \
        && echo "$result" | grep -qx "wt=linked" \
        && echo "$result" | grep -qx "resolution=has-config" \
        && echo "$result" | grep -qx "main-of-wt=has-config"; then
        pass "Worktree helpers resolve linked state and main root"
    else
        fail "Unexpected helper output: $result"
        return 1
    fi
}

test_nested_worktree_config_excluded() {
    info "Testing discovery ignores configs under nested linked worktrees..."

    cd "$TEST_DIR"
    # Worktree nested INSIDE the main checkout, like <repo>/.claude/worktrees/x
    git worktree add -q -b wt-nested "$TEST_DIR/nested/wt-a" >/dev/null 2>&1

    # Give the nested worktree its own config copy (simulates copy tooling)
    cat > "$TEST_DIR/nested/wt-a/.local-overrides.yaml" << 'EOF'
pattern: ".private"
files:
  - override: CLAUDE.private.md
    replaces:
      - AGENTS.md
EOF

    # Leg 1 — fd strategy (only when fd is available on this machine).
    if command -v fd >/dev/null 2>&1; then
        local discovered
        discovered="$(bash -c '
            set -euo pipefail
            . "$1/shared/local-override-resolver.sh"
            discover_config_files "$2"
        ' _ "$PROJECT_DIR" "$TEST_DIR")"

        if ! echo "$discovered" | grep -qx ".local-overrides.yaml"; then
            fail "fd strategy: main checkout config missing from discovery: $discovered"
            return 1
        fi

        if echo "$discovered" | grep -q "nested/wt-a"; then
            fail "fd strategy: nested worktree config leaked into main discovery: $discovered"
            return 1
        fi
    else
        echo "  (fd not installed; fd-strategy leg skipped)"
    fi

    # Leg 2 — git ls-files strategy (always runs, deterministic everywhere).
    # Force the git ls-files strategy: PATH without any dir containing fd,
    # plus a shim dir so git itself stays reachable.
    local git_shim="$CURRENT_TEST_ROOT/git-shim"
    mkdir -p "$git_shim"
    ln -sf "$(command -v git)" "$git_shim/git"

    local no_fd_path="" dir=""
    local saved_ifs="$IFS"
    IFS=":"
    for dir in $PATH; do
        [[ -x "$dir/fd" ]] && continue
        no_fd_path="${no_fd_path:+$no_fd_path:}$dir"
    done
    IFS="$saved_ifs"

    local discovered_git_strategy
    discovered_git_strategy="$(PATH="$git_shim:$no_fd_path" bash -c '
        set -euo pipefail
        . "$1/shared/local-override-resolver.sh"
        discover_config_files "$2"
    ' _ "$PROJECT_DIR" "$TEST_DIR")"

    if ! echo "$discovered_git_strategy" | grep -qx ".local-overrides.yaml"; then
        fail "git ls-files strategy: main checkout config missing from discovery: $discovered_git_strategy"
        return 1
    fi

    if echo "$discovered_git_strategy" | grep -q "nested/wt-a"; then
        fail "git ls-files strategy: nested worktree config leaked into main discovery: $discovered_git_strategy"
        return 1
    fi

    pass "Nested worktree configs are excluded from main-checkout discovery"
}

test_bare_main_repo_degrades_gracefully() {
    info "Testing a worktree of a bare repo degrades to the checkout root..."

    cd "$TEST_DIR"
    local bare="$CURRENT_TEST_ROOT/bare-main.git"
    git clone -q --bare "$TEST_DIR" "$bare"
    git -C "$bare" worktree add -q "$CURRENT_TEST_ROOT/bare-wt" >/dev/null 2>&1

    local result
    result="$(bash -c '
        set -euo pipefail
        . "$1/shared/local-override-resolver.sh"
        wt_root="$2"
        if get_main_worktree_root "$wt_root" >/dev/null 2>&1; then
            echo "main-root=found"
        else
            echo "main-root=none"
        fi
        resolved="$(get_resolution_root "$wt_root")"
        if [[ "$resolved" == "$wt_root" ]]; then
            echo "resolution=checkout-root"
        else
            echo "resolution=other:$resolved"
        fi
    ' _ "$PROJECT_DIR" "$CURRENT_TEST_ROOT/bare-wt")"

    if echo "$result" | grep -qx "main-root=none" \
        && echo "$result" | grep -qx "resolution=checkout-root"; then
        pass "Bare-repo main: no fallback root, resolution degrades to the checkout"
    else
        fail "Unexpected bare-repo behavior: $result"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    echo ""
    echo "========================================"
    echo "  Linked Worktree Integration Tests"
    echo "========================================"

    local test_fn
    for test_fn in \
        test_worktree_helper_functions \
        test_nested_worktree_config_excluded \
        test_bare_main_repo_degrades_gracefully; do
        CURRENT_TEST_NAME="$test_fn"
        setup_repo

        set +e
        "$test_fn"
        CURRENT_TEST_STATUS=$?
        set -e

        if [[ $CURRENT_TEST_STATUS -ne 0 ]]; then
            exit "$CURRENT_TEST_STATUS"
        fi

        finalize_current_test_root 0
    done

    echo ""
    echo "========================================"
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "  ${GREEN}All $TESTS_RUN tests passed!${NC}"
        exit 0
    else
        echo -e "  ${RED}$TESTS_FAILED/$TESTS_RUN tests failed${NC}"
        exit 1
    fi
}

main "$@"
