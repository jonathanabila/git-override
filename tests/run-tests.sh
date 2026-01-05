#!/usr/bin/env bash
#
# Test suite for git-local-override
#
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TESTS_DIR")"
TEST_REPO="$TESTS_DIR/test-repo"
export XDG_CONFIG_HOME="$TESTS_DIR/test-config"
export PATH="$PROJECT_DIR/bin:$PATH"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0

pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
    ((TESTS_PASSED++)) || true
}

fail() {
    echo -e "${RED}[FAIL]${NC} $*"
    # Don't exit immediately, continue running tests
}

info() {
    echo -e "${YELLOW}[TEST]${NC} $*"
    ((TESTS_RUN++)) || true
}

#------------------------------------------------------------------------------
# Setup
#------------------------------------------------------------------------------

setup() {
    echo "Setting up test environment..."

    # Clean and recreate test repo
    rm -rf "$TEST_REPO"
    mkdir -p "$TEST_REPO"
    cd "$TEST_REPO"

    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"

    # Create initial files
    mkdir -p backend/services/foo
    echo "# Original CLAUDE.md content" > CLAUDE.md
    echo "# Original AGENTS.md in root" > AGENTS.md
    echo "# Original AGENTS.md in backend" > backend/services/foo/AGENTS.md
    echo '{"key": "original"}' > config.json

    git add .
    git commit -q -m "Initial commit"

    # Reset XDG config (for global gitignore)
    rm -rf "$XDG_CONFIG_HOME"
    mkdir -p "$XDG_CONFIG_HOME/git"

    # Install hooks using the install script approach (copy hooks directly)
    mkdir -p .git/hooks
    cp "$PROJECT_DIR/hooks/local-override-lib.sh" .git/hooks/
    cp "$PROJECT_DIR/hooks/local-override-post-checkout" .git/hooks/post-checkout
    cp "$PROJECT_DIR/hooks/local-override-pre-commit" .git/hooks/pre-commit
    cp "$PROJECT_DIR/hooks/local-override-post-commit" .git/hooks/post-commit
    chmod +x .git/hooks/*

    echo -e "${GREEN}[OK]${NC} Test environment setup complete"
}

create_config() {
    # Create a .local-overrides.yaml config file
    cat > .local-overrides.yaml << 'EOF'
# Test configuration
files:
  - CLAUDE.md
  - AGENTS.md
  - backend/services/foo/AGENTS.md
EOF
}

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_cli_help() {
    info "Testing CLI help command..."

    local output
    output=$(git-local-override help)

    if [[ "$output" == *"git-local-override"* && "$output" == *"COMMANDS"* ]]; then
        pass "CLI help command works"
    else
        fail "CLI help command failed"
    fi
}

test_init_config() {
    info "Testing init-config command..."

    cd "$TEST_REPO"
    rm -f .local-overrides.yaml

    git-local-override init-config

    if [[ -f ".local-overrides.yaml" ]]; then
        pass "init-config creates config file"
    else
        fail "init-config did not create config file"
    fi
}

test_list_no_config() {
    info "Testing list without config..."

    cd "$TEST_REPO"
    rm -f .local-overrides.yaml .local-overrides

    local output
    output=$(git-local-override list)

    if [[ "$output" == *"No .local-overrides.yaml found"* ]]; then
        pass "List handles missing config gracefully"
    else
        fail "List did not handle missing config"
    fi
}

test_add_override() {
    info "Testing add override..."

    cd "$TEST_REPO"
    create_config

    git-local-override add CLAUDE.md

    if [[ -f "CLAUDE.local.md" ]]; then
        pass "Local file created: CLAUDE.local.md"
    else
        fail "Local file not created"
    fi
}

test_override_is_applied() {
    info "Testing override is applied..."

    cd "$TEST_REPO"

    # Modify the local file
    echo "# My LOCAL CLAUDE.md content" > CLAUDE.local.md

    # Run apply to apply the override
    git-local-override apply

    # Check that the original file now has local content
    if grep -q "LOCAL" CLAUDE.md; then
        pass "Override applied to tracked file"
    else
        fail "Override not applied"
    fi
}

test_git_status_after_override() {
    info "Testing git status shows modified file..."

    cd "$TEST_REPO"

    # Git should see the file as modified (since we applied local content)
    local status
    status=$(git status --porcelain)

    if [[ "$status" == *"CLAUDE.md"* ]]; then
        pass "Git sees file as modified (expected before pre-commit hook)"
    else
        fail "Git status unexpected"
    fi
}

test_restore_originals() {
    info "Testing restore command..."

    cd "$TEST_REPO"

    git-local-override restore

    # Check that original content is restored
    if grep -q "Original" CLAUDE.md && ! grep -q "LOCAL" CLAUDE.md; then
        pass "Original content restored"
    else
        fail "Original content not restored"
    fi
}

test_list_overrides() {
    info "Testing list command..."

    cd "$TEST_REPO"
    create_config

    # Re-apply override so we have an active one
    echo "# LOCAL" > CLAUDE.local.md

    local output
    output=$(git-local-override list)

    if [[ "$output" == *"CLAUDE.md"* && "$output" == *"[active]"* ]]; then
        pass "List shows active overrides"
    else
        echo "Output was: $output"
        fail "List output incorrect"
    fi
}

test_remove_override() {
    info "Testing remove override..."

    cd "$TEST_REPO"

    # Remove the CLAUDE.md override (but keep the local file)
    git-local-override remove CLAUDE.md

    # Check local file still exists and original restored
    if [[ -f "CLAUDE.local.md" ]] && grep -q "Original" CLAUDE.md; then
        pass "Local file preserved and original restored"
    else
        fail "Remove failed - local file or original content issue"
    fi
}

test_remove_with_delete() {
    info "Testing remove with --delete..."

    cd "$TEST_REPO"

    # Ensure local file exists
    echo "# LOCAL" > CLAUDE.local.md

    # Remove with delete flag
    git-local-override remove --delete CLAUDE.md

    # Check local file was deleted
    if [[ ! -f "CLAUDE.local.md" ]]; then
        pass "Local file deleted with --delete flag"
    else
        fail "Local file was not deleted"
    fi
}

test_nested_override() {
    info "Testing override for nested file..."

    cd "$TEST_REPO"
    create_config

    git-local-override add backend/services/foo/AGENTS.md

    if [[ -f "backend/services/foo/AGENTS.local.md" ]]; then
        pass "Nested local file created"
    else
        fail "Nested local file not created"
    fi
}

test_post_checkout_hook() {
    info "Testing post-checkout hook..."

    cd "$TEST_REPO"
    create_config

    # Create local file
    echo "# POST CHECKOUT TEST CONTENT" > CLAUDE.local.md

    # Manually run the post-checkout hook
    .git/hooks/post-checkout "" "" "1"

    # Check content was applied
    if grep -q "POST CHECKOUT TEST" CLAUDE.md; then
        pass "Post-checkout hook applied override"
    else
        fail "Post-checkout hook did not apply override"
    fi
}

test_pre_commit_hook() {
    info "Testing pre-commit hook behavior..."

    cd "$TEST_REPO"
    create_config

    # Set up an override
    echo "# LOCAL CONTENT FOR COMMIT TEST" > CLAUDE.local.md
    git-local-override apply

    # Stage the file
    git add CLAUDE.md

    # Run the pre-commit hook
    .git/hooks/pre-commit

    # Check that original content was restored
    if grep -q "Original" CLAUDE.md; then
        pass "Pre-commit hook restored original content"
    else
        fail "Pre-commit hook did not restore original"
    fi
}

test_post_commit_hook() {
    info "Testing post-commit hook..."

    cd "$TEST_REPO"
    create_config

    # Ensure local file has test content
    echo "# LOCAL CONTENT FOR POST COMMIT TEST" > CLAUDE.local.md

    # Run post-commit to apply override
    .git/hooks/post-commit

    # Check override was applied
    if grep -q "LOCAL CONTENT FOR POST COMMIT TEST" CLAUDE.md; then
        pass "Post-commit hook applied override"
    else
        fail "Post-commit hook did not apply override"
    fi
}

test_status_command() {
    info "Testing status command..."

    cd "$TEST_REPO"
    create_config

    local output
    output=$(git-local-override status)

    if [[ "$output" == *"Repository:"* && "$output" == *"Hooks:"* && "$output" == *"installed"* ]]; then
        pass "Status command works"
    else
        fail "Status command failed"
    fi
}

test_plain_text_config() {
    info "Testing plain text config format..."

    cd "$TEST_REPO"

    # Remove YAML config, create plain text
    rm -f .local-overrides.yaml
    cat > .local-overrides << 'EOF'
# Plain text config
CLAUDE.md
AGENTS.md
EOF

    # Create local file
    echo "# PLAIN TEXT CONFIG TEST" > CLAUDE.local.md

    # Apply should work
    git-local-override apply

    if grep -q "PLAIN TEXT CONFIG TEST" CLAUDE.md; then
        pass "Plain text config format works"
    else
        fail "Plain text config format failed"
    fi

    # Clean up
    rm .local-overrides
    create_config
}

test_no_override_when_no_local_file() {
    info "Testing no override when local file missing..."

    cd "$TEST_REPO"
    create_config

    # Remove any local file
    rm -f AGENTS.local.md

    # Restore original
    git checkout HEAD -- AGENTS.md

    # Run post-checkout
    .git/hooks/post-checkout "" "" "1"

    # Original content should remain
    if grep -q "Original AGENTS.md in root" AGENTS.md; then
        pass "No override when local file missing"
    else
        fail "Unexpected modification when local file missing"
    fi
}

test_file_not_in_config_warning() {
    info "Testing warning for file not in config..."

    cd "$TEST_REPO"
    create_config

    # Try to add a file not in config
    local output
    output=$(git-local-override add config.json 2>&1) || true

    if [[ "$output" == *"not in .local-overrides.yaml"* ]]; then
        pass "Warning shown for file not in config"
    else
        fail "No warning for file not in config"
    fi
}

test_hooks_check_for_config() {
    info "Testing hooks exit early without config..."

    cd "$TEST_REPO"

    # Remove config
    rm -f .local-overrides.yaml .local-overrides

    # Create a local file that would be applied if config existed
    echo "# SHOULD NOT BE APPLIED" > CLAUDE.local.md

    # Restore original
    git checkout HEAD -- CLAUDE.md

    # Run post-checkout - should exit early without config
    .git/hooks/post-checkout "" "" "1"

    # Original should remain unchanged
    if grep -q "Original CLAUDE.md content" CLAUDE.md; then
        pass "Hooks exit early without config"
    else
        fail "Hooks modified files without config"
    fi

    # Restore config for other tests
    create_config
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    echo ""
    echo "========================================"
    echo "  git-local-override Test Suite"
    echo "========================================"
    echo ""

    setup

    echo ""
    echo "Running tests..."
    echo ""

    test_cli_help
    test_init_config
    test_list_no_config
    test_add_override
    test_override_is_applied
    test_git_status_after_override
    test_restore_originals
    test_list_overrides
    test_remove_override
    test_remove_with_delete
    test_nested_override
    test_post_checkout_hook
    test_pre_commit_hook
    test_post_commit_hook
    test_status_command
    test_plain_text_config
    test_no_override_when_no_local_file
    test_file_not_in_config_warning
    test_hooks_check_for_config

    echo ""
    echo "========================================"
    if [[ $TESTS_PASSED -eq $TESTS_RUN ]]; then
        echo -e "  ${GREEN}All $TESTS_RUN tests passed!${NC}"
    else
        echo -e "  ${RED}$TESTS_PASSED/$TESTS_RUN tests passed${NC}"
    fi
    echo "========================================"
    echo ""

    if [[ $TESTS_PASSED -ne $TESTS_RUN ]]; then
        exit 1
    fi
}

main "$@"
