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
    cp "$PROJECT_DIR/hooks/local-override-pre-commit" .git/hooks/pre-commit
    cp "$PROJECT_DIR/hooks/local-override-post-commit" .git/hooks/post-commit
    cp "$PROJECT_DIR/hooks/local-override-pre-rebase" .git/hooks/pre-rebase
    chmod +x .git/hooks/local-override-filter-smudge \
        .git/hooks/local-override-filter-clean \
        .git/hooks/post-checkout \
        .git/hooks/pre-commit \
        .git/hooks/post-commit \
        .git/hooks/pre-rebase

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

test_discovery_cache_is_root_aware() {
    info "Testing discovery cache does not leak across roots..."

    cd "$TEST_DIR"
    git worktree add -q -b wt-cache "$CURRENT_TEST_ROOT/wt-cache" >/dev/null 2>&1

    # Cache the (empty) worktree discovery, then ask about the main root:
    # a root-blind cache would wrongly return the empty worktree result.
    local result
    result="$(bash -c '
        set -euo pipefail
        . "$1/shared/local-override-resolver.sh"
        cache_config_files "$2"
        main_result="$(get_cached_config_files "$3")"
        clear_config_files_cache
        if [[ -n "$main_result" ]]; then
            echo "main-root-sees-config"
        else
            echo "main-root-sees-nothing"
        fi
    ' _ "$PROJECT_DIR" "$CURRENT_TEST_ROOT/wt-cache" "$TEST_DIR")"

    if [[ "$result" == "main-root-sees-config" ]]; then
        pass "Cache miss on differing root falls through to live discovery"
    else
        fail "Cache returned wrong root's results: $result"
        return 1
    fi
}

test_worktree_fallback_smudges_override() {
    info "Testing fresh worktree inherits the main checkout's override..."

    cd "$TEST_DIR"
    git worktree add -q -b wt-fallback "$CURRENT_TEST_ROOT/wt-fallback" >/dev/null 2>&1

    if grep -q "Private override content v1" "$CURRENT_TEST_ROOT/wt-fallback/AGENTS.md"; then
        pass "Worktree AGENTS.md contains override content via fallback"
    else
        fail "Worktree AGENTS.md content: $(cat "$CURRENT_TEST_ROOT/wt-fallback/AGENTS.md")"
        return 1
    fi
}

test_worktree_local_config_wins() {
    info "Testing a worktree-local config takes precedence over fallback..."

    cd "$TEST_DIR"
    local wt="$CURRENT_TEST_ROOT/wt-local"
    git worktree add -q -b wt-local "$wt" >/dev/null 2>&1

    cat > "$wt/.local-overrides.yaml" << 'EOF'
pattern: ".private"
files:
  - override: CLAUDE.private.md
    replaces:
      - AGENTS.md
EOF
    echo "# Worktree-local override content" > "$wt/CLAUDE.private.md"

    rm "$wt/AGENTS.md"
    git -C "$wt" checkout -- AGENTS.md

    if grep -q "Worktree-local override content" "$wt/AGENTS.md"; then
        pass "Worktree-local config wins over the main root's"
    else
        fail "Worktree AGENTS.md content: $(cat "$wt/AGENTS.md")"
        return 1
    fi
}

test_fallback_escape_hatch() {
    info "Testing GIT_LOCAL_OVERRIDE_DISABLE_WORKTREE_FALLBACK=1..."

    cd "$TEST_DIR"
    local wt="$CURRENT_TEST_ROOT/wt-disabled"
    GIT_LOCAL_OVERRIDE_DISABLE_WORKTREE_FALLBACK=1 \
        git worktree add -q -b wt-disabled "$wt" >/dev/null 2>&1

    if grep -q "# Tracked AGENTS.md" "$wt/AGENTS.md"; then
        pass "Fallback disabled: worktree smudges tracked content"
    else
        fail "Worktree AGENTS.md content: $(cat "$wt/AGENTS.md")"
        return 1
    fi
}

test_clean_roundtrip_in_fallback_worktree() {
    info "Testing clean filter restores tracked content in a fallback worktree..."

    cd "$TEST_DIR"
    local wt="$CURRENT_TEST_ROOT/wt-clean"
    git worktree add -q -b wt-clean "$wt" >/dev/null 2>&1

    git -C "$wt" add AGENTS.md
    local index_content
    index_content="$(git -C "$wt" show :AGENTS.md)"

    if [[ "$index_content" == "# Tracked AGENTS.md" ]]; then
        pass "Override content did not leak into the index"
    else
        fail "Index content for AGENTS.md: $index_content"
        return 1
    fi
}

test_commit_in_stale_fallback_worktree_stays_clean() {
    info "Testing a stale fallback worktree cannot commit override content..."

    cd "$TEST_DIR"
    local wt="$CURRENT_TEST_ROOT/wt-stale"
    git worktree add -q -b wt-stale "$wt" >/dev/null 2>&1

    # Override changes at the main root AFTER the worktree materialized v1:
    # the worktree file now differs from the override, so the clean filter's
    # exact-match guard no longer protects the index.
    echo "# Private override content v2" > "$TEST_DIR/CLAUDE.private.md"

    ( cd "$wt" && git commit -aqm "routine commit" ) >/dev/null 2>&1 || true

    local committed
    committed="$(git -C "$wt" show HEAD:AGENTS.md 2>/dev/null || echo "no-commit")"
    if [[ "$committed" == "# Tracked AGENTS.md" || "$committed" == "no-commit" ]]; then
        pass "No override content reached the commit"
    else
        fail "HEAD:AGENTS.md leaked: $committed"
        return 1
    fi
}

test_post_checkout_refreshes_fallback_worktree() {
    info "Testing post-checkout refreshes a fallback worktree after override edits..."

    cd "$TEST_DIR"
    local wt="$CURRENT_TEST_ROOT/wt-refresh"
    git worktree add -q -b wt-refresh "$wt" >/dev/null 2>&1

    echo "# Private override content v3" > "$TEST_DIR/CLAUDE.private.md"

    ( cd "$wt" && git switch -qc wt-refresh-2 ) >/dev/null 2>&1

    if grep -q "Private override content v3" "$wt/AGENTS.md"; then
        pass "Branch switch re-applied the current override content"
    else
        fail "Worktree AGENTS.md after switch: $(cat "$wt/AGENTS.md")"
        return 1
    fi
}

test_apply_works_inside_fallback_worktree() {
    info "Testing 'apply' run inside a fallback worktree..."

    cd "$TEST_DIR"
    local wt="$CURRENT_TEST_ROOT/wt-apply"
    git worktree add -q -b wt-apply "$wt" >/dev/null 2>&1

    echo "# Private override content v2" > "$TEST_DIR/CLAUDE.private.md"

    if ! (cd "$wt" && "$PROJECT_DIR/bin/git-local-override" apply >/dev/null 2>&1); then
        fail "apply exited non-zero inside the worktree"
        return 1
    fi

    if grep -q "Private override content v2" "$wt/AGENTS.md"; then
        pass "apply inside worktree refreshed the target from the main root's override"
    else
        fail "Worktree AGENTS.md after apply: $(cat "$wt/AGENTS.md")"
        return 1
    fi

    # The index must still hold tracked content (clean filter round-trip)
    local index_content
    index_content="$(git -C "$wt" show :AGENTS.md)"
    if [[ "$index_content" == "# Tracked AGENTS.md" ]]; then
        pass "apply did not leak override content into the index"
    else
        fail "Index content after apply: $index_content"
        return 1
    fi
}

test_pre_rebase_repairs_skip_worktree_in_fallback_worktree() {
    info "Testing pre-rebase clears legacy skip-worktree bits in a fallback worktree..."

    cd "$TEST_DIR"
    local wt="$CURRENT_TEST_ROOT/wt-skipwt"
    git worktree add -q -b wt-skipwt "$wt" >/dev/null 2>&1

    # Plant a legacy skip-worktree bit on the managed target in the worktree
    git -C "$wt" update-index --skip-worktree AGENTS.md
    local before
    before="$(git -C "$wt" ls-files -v AGENTS.md | cut -c1)"
    if [[ "$before" != "S" ]]; then
        fail "Setup failed: expected skip-worktree bit, got: $before"
        return 1
    fi

    # Invoke the pre-rebase hook the way git would (cwd = worktree)
    ( cd "$wt" && bash "$TEST_DIR/.git/hooks/pre-rebase" ) >/dev/null 2>&1

    local after
    after="$(git -C "$wt" ls-files -v AGENTS.md | cut -c1)"
    if [[ "$after" == "H" ]]; then
        pass "pre-rebase repaired the skip-worktree bit via resolution-root entries"
    else
        fail "Expected H after hook, got: $after"
        return 1
    fi
}

test_status_caches_discovery() {
    info "Testing status runs config discovery at most once and hits the cache..."

    cd "$TEST_DIR"
    local output
    output="$(GIT_LOCAL_OVERRIDE_TRACE=1 "$PROJECT_DIR/bin/git-local-override" status 2>&1 || true)"

    local misses hits
    misses="$(printf '%s\n' "$output" | grep -c "cache=miss" || true)"
    hits="$(printf '%s\n' "$output" | grep -c "cache=hit" || true)"

    if [[ "$misses" -le 1 && "$hits" -ge 1 ]]; then
        pass "status cached discovery (misses: $misses, hits: $hits)"
    else
        fail "status discovery caching off (misses: $misses, hits: $hits)"
        return 1
    fi
}

test_status_reports_fallback_in_worktree() {
    info "Testing status in a fallback worktree reports inheritance, not init-config..."

    cd "$TEST_DIR"
    local wt="$CURRENT_TEST_ROOT/wt-status"
    git worktree add -q -b wt-status "$wt" >/dev/null 2>&1

    local output
    output="$( (cd "$wt" && "$PROJECT_DIR/bin/git-local-override" status 2>&1) || true)"

    if echo "$output" | grep -q "init-config"; then
        fail "status still recommends init-config in a fallback worktree: $output"
        return 1
    fi

    if echo "$output" | grep -qi "inherited from main worktree"; then
        pass "status reports fallback inheritance"
    else
        fail "status missing fallback indicator: $output"
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
        test_bare_main_repo_degrades_gracefully \
        test_discovery_cache_is_root_aware \
        test_worktree_fallback_smudges_override \
        test_worktree_local_config_wins \
        test_fallback_escape_hatch \
        test_clean_roundtrip_in_fallback_worktree \
        test_commit_in_stale_fallback_worktree_stays_clean \
        test_post_checkout_refreshes_fallback_worktree \
        test_apply_works_inside_fallback_worktree \
        test_pre_rebase_repairs_skip_worktree_in_fallback_worktree \
        test_status_caches_discovery \
        test_status_reports_fallback_in_worktree; do
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
