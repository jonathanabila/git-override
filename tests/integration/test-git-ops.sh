#!/usr/bin/env bash
#
# Integration tests for real git operations
#
# Tests that hooks work correctly when triggered by actual git commands:
# - git commit
# - git checkout (branch switching)
# - git switch
# - git stash
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$SCRIPT_DIR/test-gitops"

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

cleanup() {
    rm -rf "$TEST_DIR"
}

setup_repo() {
    cleanup
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"

    # Initialize repo
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"

    # Create initial files
    echo "# Original README" > README.md
    echo "# Original CLAUDE.md content" > CLAUDE.md
    echo "original_value: true" > config.yaml

    git add .
    git commit -q -m "Initial commit"

    # Install hooks directly (simulating install.sh --repo)
    mkdir -p .git/hooks
    cp "$PROJECT_DIR/hooks/local-override-lib.sh" .git/hooks/
    cp "$PROJECT_DIR/hooks/local-override-post-checkout" .git/hooks/post-checkout
    cp "$PROJECT_DIR/hooks/local-override-pre-commit" .git/hooks/pre-commit
    cp "$PROJECT_DIR/hooks/local-override-post-commit" .git/hooks/post-commit
    chmod +x .git/hooks/*

    # Create config file
    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
  - override: config.local.yaml
    replaces:
      - config.yaml
EOF

    git add .local-overrides.yaml
    git commit -q -m "Add local-overrides config"

    # Create local override files
    echo "# MY LOCAL CLAUDE.md - customized for my environment" > CLAUDE.local.md
    echo "local_value: true" > config.local.yaml

    # Apply overrides initially
    export PATH="$PROJECT_DIR/bin:$PATH"
    git-local-override apply 2>/dev/null || true
}

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_commit_preserves_original() {
    info "Testing git commit preserves original content..."

    cd "$TEST_DIR"

    # Verify local content is in working tree
    if ! grep -q "MY LOCAL" CLAUDE.md; then
        fail "Pre-condition: local content not applied"
        return 1
    fi

    # Make a change to README (unrelated file)
    echo "# Updated README" > README.md
    git add README.md

    # Commit - pre-commit hook should restore original
    git commit -q -m "Update README"

    # Check what was actually committed for CLAUDE.md
    local committed_content
    committed_content=$(git show HEAD:CLAUDE.md)

    if echo "$committed_content" | grep -q "Original CLAUDE.md content"; then
        pass "Commit contains original content"
    else
        fail "Commit contains local content (should be original)"
        echo "Committed content: $committed_content"
        return 1
    fi
}

test_commit_restores_local_after() {
    info "Testing local content restored after commit..."

    cd "$TEST_DIR"

    # Make a change
    echo "Another change" >> README.md
    git add README.md
    git commit -q -m "Another update"

    # Check working tree has local content after commit
    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "Local content restored after commit"
    else
        fail "Local content not restored after commit"
        cat CLAUDE.md
        return 1
    fi
}

test_commit_staged_override_file() {
    info "Testing commit with staged override file..."

    cd "$TEST_DIR"

    # Clear skip-worktree before staging (git add doesn't work with skip-worktree)
    git update-index --no-skip-worktree CLAUDE.md

    # Stage the override file itself
    git add CLAUDE.md

    # Commit - should commit original, not local
    git commit -q -m "Commit CLAUDE.md"

    # Verify committed content is original
    local committed_content
    committed_content=$(git show HEAD:CLAUDE.md)

    if echo "$committed_content" | grep -q "Original CLAUDE.md content"; then
        pass "Staged override file committed with original content"
    else
        fail "Staged override file has wrong content"
        echo "Committed: $committed_content"
        return 1
    fi

    # Verify working tree still has local content
    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "Working tree still has local content"
    else
        fail "Working tree lost local content"
        return 1
    fi
}

test_branch_checkout_applies_overrides() {
    info "Testing branch checkout applies overrides..."

    cd "$TEST_DIR"

    # Get the default branch name
    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    # Create a new branch
    git checkout -q -b feature-branch

    # After checkout, local content should be applied
    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "Override applied after branch creation"
    else
        fail "Override not applied after branch creation"
        return 1
    fi

    # Make a commit on this branch
    echo "Feature work" >> README.md
    git add README.md
    git commit -q -m "Feature commit"

    # Switch back to default branch
    git checkout -q "$default_branch"

    # Local content should still be there
    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "Override applied after switching to $default_branch"
    else
        fail "Override not applied after switching to $default_branch"
        return 1
    fi
}

test_git_switch_applies_overrides() {
    info "Testing git switch applies overrides..."

    cd "$TEST_DIR"

    # Check if git switch is available (Git 2.23+)
    if ! git switch --help &>/dev/null; then
        info "git switch not available (Git < 2.23), skipping"
        pass "Skipped (git switch not available)"
        return 0
    fi

    # Get the default branch name
    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    # Create branch using switch
    git switch -q -c another-feature

    # Override should be applied
    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "Override applied after git switch -c"
    else
        fail "Override not applied after git switch -c"
        return 1
    fi

    # Switch back to default branch
    git switch -q "$default_branch"

    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "Override applied after git switch $default_branch"
    else
        fail "Override not applied after git switch $default_branch"
        return 1
    fi
}

test_multiple_files_override() {
    info "Testing multiple files are overridden..."

    cd "$TEST_DIR"

    # Check both files have local content
    if grep -q "MY LOCAL" CLAUDE.md && grep -q "local_value" config.yaml; then
        pass "Multiple files have local content"
    else
        fail "Not all files have local content"
        return 1
    fi

    # Commit something
    echo "test" >> README.md
    git add README.md
    git commit -q -m "Test commit"

    # Both should still have local content
    if grep -q "MY LOCAL" CLAUDE.md && grep -q "local_value" config.yaml; then
        pass "Multiple files preserved after commit"
    else
        fail "Some files lost local content after commit"
        return 1
    fi
}

test_no_override_without_local_file() {
    info "Testing file without .local version is unchanged..."

    cd "$TEST_DIR"

    # Remove the local file for config.yaml
    rm -f config.local.yaml

    # Clear skip-worktree before restore (git checkout doesn't work with skip-worktree)
    git update-index --no-skip-worktree config.yaml

    # Restore original
    git checkout HEAD -- config.yaml

    # Apply overrides
    git-local-override apply

    # config.yaml should have original content (no local file exists)
    if grep -q "original_value" config.yaml; then
        pass "File without local version has original content"
    else
        fail "File without local version was modified"
        return 1
    fi

    # CLAUDE.md should still have local content
    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "Other files still have local content"
    else
        fail "Other files lost local content"
        return 1
    fi

    # Restore for other tests
    echo "local_value: true" > config.local.yaml
}

test_restore_command() {
    info "Testing restore command..."

    cd "$TEST_DIR"

    # Run restore
    git-local-override restore

    # All files should have original content
    if grep -q "Original CLAUDE.md content" CLAUDE.md; then
        pass "CLAUDE.md restored to original"
    else
        fail "CLAUDE.md not restored"
        return 1
    fi

    if grep -q "original_value" config.yaml; then
        pass "config.yaml restored to original"
    else
        fail "config.yaml not restored"
        return 1
    fi

    # Re-apply for other tests
    git-local-override apply
}

test_dirty_working_tree_commit() {
    info "Testing commit with dirty working tree..."

    cd "$TEST_DIR"

    # Make unstaged changes to README
    echo "Unstaged change" >> README.md

    # Clear skip-worktree before staging (git add doesn't work with skip-worktree)
    git update-index --no-skip-worktree config.yaml

    # Stage config.yaml (which has local content applied)
    git add config.yaml

    # Commit
    git commit -q -m "Commit config"

    # Check committed content is original
    local committed_content
    committed_content=$(git show HEAD:config.yaml)

    if echo "$committed_content" | grep -q "original_value"; then
        pass "Config committed with original content"
    else
        fail "Config committed with local content"
        return 1
    fi

    # Working tree should have local content restored
    if grep -q "local_value" config.yaml; then
        pass "Local content restored in working tree"
    else
        fail "Local content not restored"
        return 1
    fi

    # Unstaged README change should still be there
    if grep -q "Unstaged change" README.md; then
        pass "Unstaged changes preserved"
    else
        fail "Unstaged changes lost"
        return 1
    fi

    # Clean up
    git checkout HEAD -- README.md
}

test_hooks_skip_without_config() {
    info "Testing hooks skip without config file..."

    cd "$TEST_DIR"

    # Remove config
    rm -f .local-overrides.yaml .local-overrides

    # Clear skip-worktree before checkout (git checkout doesn't work with skip-worktree)
    git update-index --no-skip-worktree CLAUDE.md 2>/dev/null || true
    git update-index --no-skip-worktree config.yaml 2>/dev/null || true

    # Restore original content
    git checkout HEAD -- CLAUDE.md config.yaml

    # Make a change and commit
    echo "No config test" >> README.md
    git add README.md
    git commit -q -m "No config commit"

    # Files should still have original content (not local)
    if grep -q "Original CLAUDE.md content" CLAUDE.md; then
        pass "Hooks gracefully handle missing config"
    else
        fail "Hooks modified files without config"
        return 1
    fi

    # Restore config
    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
  - override: config.local.yaml
    replaces:
      - config.yaml
EOF
    git-local-override apply 2>/dev/null || true
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    echo ""
    echo "========================================"
    echo "  Git Operations Integration Tests"
    echo "========================================"
    echo ""

    # Add project bin to PATH
    export PATH="$PROJECT_DIR/bin:$PATH"

    setup_repo

    test_commit_preserves_original
    test_commit_restores_local_after
    test_commit_staged_override_file
    test_branch_checkout_applies_overrides
    test_git_switch_applies_overrides
    test_multiple_files_override
    test_no_override_without_local_file
    test_restore_command
    test_dirty_working_tree_commit
    test_hooks_skip_without_config

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
