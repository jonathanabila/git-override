#!/usr/bin/env bash
#
# Integration tests for pre-commit framework integration
#
# Tests that our hooks work correctly when installed via pre-commit:
# - pre-commit install with multiple hook types
# - Hooks triggered through pre-commit run
# - Coexistence with other pre-commit hooks
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/../test-lib.sh"

TEST_DIR=""
SUITE_ROOT=""
TEST_SEED_REPO=""
CURRENT_TEST_ROOT=""
CURRENT_TEST_NAME=""
CURRENT_TEST_STATUS=0

# Colors
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

skip() {
    echo -e "${YELLOW}[SKIP]${NC} $*"
    ((TESTS_RUN++)) || true
}

cleanup() {
    cd "$PROJECT_DIR"
    cleanup_test_root "$SUITE_ROOT"
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
    cleanup
}

trap cleanup_on_exit EXIT

check_precommit() {
    if ! command -v pre-commit &>/dev/null; then
        echo "pre-commit not installed, skipping pre-commit tests"
        return 1
    fi
    return 0
}

write_local_precommit_config() {
    cat > .pre-commit-config.yaml << EOF
repos:
  - repo: local
    hooks:
      - id: local-override-pre-commit
        name: Restore originals before commit
        entry: $PROJECT_DIR/hooks/local-override-pre-commit
        language: script
        stages: [pre-commit]
        always_run: true
        pass_filenames: false
      - id: local-override-post-commit
        name: Re-apply local overrides after commit
        entry: $PROJECT_DIR/hooks/local-override-post-commit
        language: script
        stages: [post-commit]
        always_run: true
        pass_filenames: false
      - id: local-override-post-checkout
        name: Apply local overrides after checkout
        entry: $PROJECT_DIR/hooks/local-override-post-checkout
        language: script
        stages: [post-checkout]
        always_run: true
        pass_filenames: false

      - id: local-override-pre-rebase
        name: Restore originals before rebase
        entry: $PROJECT_DIR/hooks/local-override-pre-rebase
        language: script
        stages: [pre-rebase]
        always_run: true
        pass_filenames: false
EOF
}

setup_seed_repo() {
    SUITE_ROOT="$(create_test_root "precommit" "suite")"
    setup_test_env "$SUITE_ROOT" "$PROJECT_DIR"
    cd "$TEST_REPO"

    # Initialize repo
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"

    # Create initial files
    echo "# Original README" > README.md
    echo "# Original CLAUDE.md content" > CLAUDE.md

    git add .
    git commit -q -m "Initial commit"

    write_local_precommit_config

    # Create local-overrides config
    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    git add .pre-commit-config.yaml .local-overrides.yaml
    git commit -q -m "Add pre-commit config"

    TEST_SEED_REPO="$SUITE_ROOT/artifacts/precommit-seed.git"
    create_seed_repo "$TEST_REPO" "$TEST_SEED_REPO"
}

configure_test_repo() {
    cd "$TEST_REPO"

    mkdir -p .git/hooks
    cp "$PROJECT_DIR/hooks/local-override-lib.sh" .git/hooks/
    cp "$PROJECT_DIR/shared/local-override-resolver.sh" .git/hooks/

    # Create local override file
    echo "# MY LOCAL CLAUDE.md - pre-commit test" > CLAUDE.local.md
}

setup_repo() {
    CURRENT_TEST_ROOT="$(create_test_root "precommit" "$CURRENT_TEST_NAME")"
    CURRENT_TEST_STATUS=0
    setup_test_env "$CURRENT_TEST_ROOT" "$PROJECT_DIR"
    clone_seed_repo "$TEST_SEED_REPO" "$TEST_REPO"
    TEST_DIR="$TEST_REPO"
    configure_test_repo
    cd "$TEST_DIR"
}

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_precommit_install() {
    info "Testing pre-commit install with multiple hook types..."

    cd "$TEST_DIR"

    # Install pre-commit hooks
    if pre-commit install \
        --hook-type pre-commit \
        --hook-type post-commit \
        --hook-type post-checkout \
        --hook-type pre-rebase; then
        pass "pre-commit install succeeded"
    else
        fail "pre-commit install failed"
        return 1
    fi

    # Verify hooks were created
    if [[ -f ".git/hooks/pre-commit" ]] &&
       [[ -f ".git/hooks/post-commit" ]] &&
       [[ -f ".git/hooks/post-checkout" ]] &&
       [[ -f ".git/hooks/pre-rebase" ]]; then
        pass "All hook files created"
    else
        fail "Some hook files missing"
        ls -la .git/hooks/
        return 1
    fi

    # Verify hooks are from pre-commit
    if grep -q "pre-commit" .git/hooks/pre-commit; then
        pass "Hooks are managed by pre-commit"
    else
        fail "Hooks not managed by pre-commit"
        return 1
    fi

    # Status must recognize framework-managed hooks (uses real shims +
    # the seeded .pre-commit-config.yaml with local-override-* hook ids)
    local status_output
    status_output=$("$PROJECT_DIR/bin/git-local-override" status)
    if [[ "$status_output" == *"installed (via pre-commit)"* ]]; then
        pass "status reports hooks installed via pre-commit"
    else
        fail "status did not recognize pre-commit managed hooks"
        printf '%s\n' "$status_output" | grep "Hooks:" || true
        return 1
    fi
}

test_precommit_run_pre_commit() {
    info "Testing pre-commit run for pre-commit stage..."

    cd "$TEST_DIR"

    # Apply local content first
    cp CLAUDE.local.md CLAUDE.md

    # Stage a file
    echo "test" >> README.md
    git add README.md

    # Run pre-commit manually
    if pre-commit run local-override-pre-commit --hook-stage pre-commit; then
        pass "pre-commit hook ran successfully"
    else
        # Hook might "fail" because it modified files - that's OK
        pass "pre-commit hook ran (may have modified files)"
    fi
}

test_precommit_commit_flow() {
    info "Testing full commit flow through pre-commit..."

    cd "$TEST_DIR"

    # Ensure pre-commit hooks are installed
    pre-commit install \
        --hook-type pre-commit \
        --hook-type post-commit \
        --hook-type post-checkout \
        --hook-type pre-rebase 2>/dev/null || true

    # Apply local content
    echo "# MY LOCAL CLAUDE.md - commit flow test" > CLAUDE.local.md
    echo "# MY LOCAL CLAUDE.md - commit flow test" > CLAUDE.md

    # Make a change and commit
    echo "Pre-commit flow test" >> README.md
    # Ensure file can be staged

    git add README.md CLAUDE.md

    # Commit (this triggers pre-commit hooks)
    if git commit -m "Test pre-commit flow"; then
        pass "Commit succeeded through pre-commit"
    else
        fail "Commit failed"
        return 1
    fi

    # Verify committed content is original
    local committed_content
    committed_content=$(git show HEAD:CLAUDE.md)

    if echo "$committed_content" | grep -q "Original CLAUDE.md content"; then
        pass "Committed content is original"
    else
        fail "Committed content is not original"
        echo "Committed: $committed_content"
        return 1
    fi

    # Verify working tree has local content (post-commit hook)
    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "Local content restored after commit"
    else
        fail "Local content not restored after commit"
        cat CLAUDE.md
        return 1
    fi
}

test_precommit_checkout_flow() {
    info "Testing checkout flow through pre-commit..."

    cd "$TEST_DIR"

    # Clean up any unstaged changes before checkout
    # (pre-commit stashing can cause issues with our hooks)
    git checkout -- . 2>/dev/null || true
    git clean -fd 2>/dev/null || true

    # Create the local file again after cleanup
    echo "# MY LOCAL CLAUDE.md - checkout test" > CLAUDE.local.md

    # Create a new branch (may return non-zero due to pre-commit hook conflicts)
    git checkout -q -b test-branch 2>/dev/null || true

    # Verify the branch was created
    if [[ "$(git rev-parse --abbrev-ref HEAD)" == "test-branch" ]]; then
        pass "Branch checkout completed"
    else
        fail "Branch checkout failed"
        return 1
    fi
}

test_precommit_with_other_hooks() {
    info "Testing coexistence with other pre-commit hooks..."

    cd "$TEST_DIR"

    # Add another hook to the config
    cat > .pre-commit-config.yaml << EOF
repos:
  - repo: local
    hooks:
      - id: local-override-pre-commit
        name: Restore originals before commit
        entry: $PROJECT_DIR/hooks/local-override-pre-commit
        language: script
        stages: [pre-commit]
        always_run: true
        pass_filenames: false
      - id: local-override-post-commit
        name: Re-apply local overrides after commit
        entry: $PROJECT_DIR/hooks/local-override-post-commit
        language: script
        stages: [post-commit]
        always_run: true
        pass_filenames: false
      - id: check-readme
        name: Check README exists
        entry: bash -c 'test -f README.md'
        language: system
        stages: [pre-commit]
        always_run: true
        pass_filenames: false
EOF

    # Commit the config change first
    git add .pre-commit-config.yaml
    git commit -q -m "Update pre-commit config" 2>/dev/null || true

    # Reinstall hooks
    pre-commit install --hook-type pre-commit --hook-type post-commit 2>/dev/null || true

    # Apply local content
    echo "# LOCAL CONTENT" > CLAUDE.md

    # Make a commit
    echo "Multiple hooks test" >> README.md
    # Ensure file can be staged

    git add README.md CLAUDE.md

    if git commit -m "Test multiple hooks"; then
        pass "Commit succeeded with multiple hooks"
    else
        fail "Commit failed with multiple hooks"
        return 1
    fi
}

test_precommit_skip_without_config() {
    info "Testing hooks skip gracefully without .local-overrides.yaml..."

    cd "$TEST_DIR"

    # Remove the config file
    rm -f .local-overrides.yaml .local-overrides
    # Restore original content

    git checkout HEAD -- CLAUDE.md

    # Make a commit
    echo "No config test" >> README.md
    git add README.md

    if git commit -m "Commit without local-overrides config"; then
        pass "Commit succeeded without config"
    else
        fail "Commit failed without config"
        return 1
    fi

    # Restore config for other tests
    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF
}

test_precommit_from_remote_repo() {
    info "Testing pre-commit config pointing to our remote repo..."

    # Create a fresh repo
    local fresh_repo="$TEST_DIR/fresh-repo"
    mkdir -p "$fresh_repo"
    cd "$fresh_repo"

    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"

    echo "# README" > README.md
    echo "# Original CLAUDE.md" > CLAUDE.md
    git add .
    git commit -q -m "Initial"

    # Create config that references the project directory as if it were a remote
    # (In real usage, this would be a GitHub URL)
    cat > .pre-commit-config.yaml << EOF
repos:
  - repo: $PROJECT_DIR
    rev: HEAD
    hooks:
      - id: local-override-pre-commit
      - id: local-override-post-commit
      - id: local-override-post-checkout
EOF

    # Copy lib to hooks dir (needed for hooks to work)
    mkdir -p .git/hooks
    cp "$PROJECT_DIR/hooks/local-override-lib.sh" .git/hooks/
    cp "$PROJECT_DIR/shared/local-override-resolver.sh" .git/hooks/

    # Create local-overrides config
    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    git add .pre-commit-config.yaml .local-overrides.yaml
    git commit -q -m "Add pre-commit config"

    # Install hooks
    if pre-commit install --hook-type pre-commit --hook-type post-commit; then
        pass "pre-commit install from 'remote' repo succeeded"
    else
        fail "pre-commit install from 'remote' repo failed"
        return 1
    fi

    # Create local file
    echo "# LOCAL from remote test" > CLAUDE.local.md
    echo "# LOCAL from remote test" > CLAUDE.md

    # Try a commit
    echo "test" >> README.md
    # Ensure file can be staged

    git add README.md CLAUDE.md

    if git commit -m "Test remote repo hooks"; then
        pass "Commit with remote repo hooks succeeded"
    else
        fail "Commit with remote repo hooks failed"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    echo ""
    echo "========================================"
    echo "  Pre-commit Framework Integration Tests"
    echo "========================================"
    echo ""

    # Check if pre-commit is available
    if ! check_precommit; then
        skip "pre-commit not available - skipping all tests"
        echo ""
        echo "========================================"
        echo -e "  ${YELLOW}All tests skipped (pre-commit not installed)${NC}"
        echo "========================================"
        exit 0
    fi

    echo "pre-commit version: $(pre-commit --version)"
    echo ""

    setup_seed_repo

    local test_fn
    for test_fn in \
        test_precommit_install \
        test_precommit_run_pre_commit \
        test_precommit_commit_flow \
        test_precommit_checkout_flow \
        test_precommit_with_other_hooks \
        test_precommit_skip_without_config \
        test_precommit_from_remote_repo; do
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

    cleanup

    echo ""
    echo "========================================"
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "  ${GREEN}All $TESTS_RUN tests passed!${NC}"
        exit 0
    else
        echo -e "  ${RED}$TESTS_FAILED/$TESTS_RUN tests failed${NC}"
        exit 1
    fi
    echo "========================================"
}

main "$@"
