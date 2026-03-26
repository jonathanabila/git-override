#!/usr/bin/env bash
#
# Test suite for git-local-override
#
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TESTS_DIR")"
. "$TESTS_DIR/test-lib.sh"

TEST_REPO=""
SUITE_ROOT=""
SUITE_SEED_REPO=""
CURRENT_TEST_ROOT=""
CURRENT_TEST_NAME=""
CURRENT_TEST_STATUS=0
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
    CURRENT_TEST_STATUS=1
}

info() {
    echo -e "${YELLOW}[TEST]${NC} $*"
    ((TESTS_RUN++)) || true
}

#------------------------------------------------------------------------------
# Setup
#------------------------------------------------------------------------------

finalize_current_test_root() {
    local status="${1:-0}"

    if [[ -n "$CURRENT_TEST_ROOT" ]]; then
        cd "$PROJECT_DIR"
        preserve_test_root_on_failure "$CURRENT_TEST_ROOT" "$CURRENT_TEST_NAME" "$status"
        CURRENT_TEST_ROOT=""
        TEST_REPO=""
    fi
}

cleanup() {
    cd "$PROJECT_DIR"
    finalize_current_test_root "${CURRENT_TEST_STATUS:-0}"

    if [[ -n "$SUITE_ROOT" ]]; then
        cleanup_test_root "$SUITE_ROOT"
        SUITE_ROOT=""
        SUITE_SEED_REPO=""
    fi
}

setup_suite_seed() {
    echo "Setting up test environment..."

    SUITE_ROOT="$(create_test_root "run-tests" "suite-seed")"
    TEST_REPO="$SUITE_ROOT/repo"
    SUITE_SEED_REPO="$SUITE_ROOT/artifacts/seed.git"

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

    create_seed_repo "$TEST_REPO" "$SUITE_SEED_REPO"

    cd "$PROJECT_DIR"

    echo -e "${GREEN}[OK]${NC} Test environment setup complete"
}

setup_test_case() {
    CURRENT_TEST_ROOT="$(create_test_root "run-tests" "$CURRENT_TEST_NAME")"
    CURRENT_TEST_STATUS=0
    setup_test_env "$CURRENT_TEST_ROOT" "$PROJECT_DIR"

    clone_seed_repo "$SUITE_SEED_REPO" "$TEST_REPO"
    install_test_hooks "$TEST_REPO" "$PROJECT_DIR"
    cd "$TEST_REPO"
}

create_config() {
    # Create a .local-overrides.yaml config file with new format
    cat > .local-overrides.yaml << 'EOF'
# Test configuration
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
  - override: backend/services/foo/AGENTS.local.md
    replaces:
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
        # Check it has the new format
        if grep -q "override:" .local-overrides.yaml && grep -q "replaces:" .local-overrides.yaml; then
            pass "init-config creates config with new format"
        else
            fail "init-config created config with wrong format"
        fi
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

    # Add creates the local file but tells user to update config
    git-local-override add CLAUDE.md 2>/dev/null || true

    if [[ -f "CLAUDE.local.md" ]]; then
        pass "Local file created: CLAUDE.local.md"
    else
        fail "Local file not created"
    fi
}

test_override_is_applied() {
    info "Testing override is applied..."

    cd "$TEST_REPO"
    create_config

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
    info "Testing git status hides file with clean filter..."

    cd "$TEST_REPO"
    create_config

    echo "# STATUS LOCAL CONTENT" > CLAUDE.local.md

    # Set up filter driver so clean filter hides changes
    git-local-override sync-filters >/dev/null
    git-local-override apply >/dev/null

    # Git should NOT see the file as modified (clean filter returns original)
    local status
    status=$(git status --porcelain)

    if [[ "$status" != *"CLAUDE.md"* ]]; then
        pass "Git status hides file (clean filter active)"
    else
        fail "Git status still shows file (clean filter not working)"
    fi
}

test_restore_originals() {
    info "Testing restore command..."

    cd "$TEST_REPO"

    create_config
    echo "# LOCAL CONTENT TO RESTORE" > CLAUDE.local.md
    git-local-override apply >/dev/null

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
    git-local-override apply >/dev/null

    local output
    output=$(git-local-override list)

    if [[ "$output" == *"CLAUDE.local.md"* && "$output" == *"[active]"* ]]; then
        pass "List shows active overrides"
    else
        echo "Output was: $output"
        fail "List output incorrect"
    fi
}

test_remove_override() {
    info "Testing remove override..."

    cd "$TEST_REPO"

    create_config
    echo "# LOCAL REMOVE CONTENT" > CLAUDE.local.md

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

    create_config
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

    git-local-override add backend/services/foo/AGENTS.md 2>/dev/null || true

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
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add CLAUDE.md

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

test_file_not_in_config_error() {
    info "Testing guidance for file not in config..."

    cd "$TEST_REPO"
    create_config

    # Try to add a file not in config - should show guidance
    local output
    output=$(git-local-override add config.json 2>&1) || true

    if [[ "$output" == *"To enable"* && "$output" == *"override:"* ]]; then
        pass "Guidance shown for file not in config"
    else
        fail "No guidance for file not in config"
    fi

    # Clean up
    rm -f config.local.json
}

test_hooks_check_for_config() {
    info "Testing hooks exit early without config..."

    cd "$TEST_REPO"

    # Remove config
    rm -f .local-overrides.yaml .local-overrides

    # Create a local file that would be applied if config existed
    echo "# SHOULD NOT BE APPLIED" > CLAUDE.local.md

    # Restore original content (bypass smudge filter)
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- CLAUDE.md

    # Run post-checkout - should exit early without config
    .git/hooks/post-checkout "" "" "1"

    # Original should remain unchanged
    if grep -q "Original CLAUDE.md content" CLAUDE.md; then
        pass "Hooks exit early without config"
    else
        fail "Hooks modified files without config"
    fi

    # Clean up and restore config for other tests
    rm -f CLAUDE.local.md
    create_config
}

test_custom_pattern() {
    info "Testing custom pattern naming..."
    cd "$TEST_REPO"

    # Create config with custom pattern
    cat > .local-overrides.yaml << 'EOF'
pattern: ".override"
files:
  - override: CLAUDE.override.md
    replaces:
      - CLAUDE.md
EOF

    # Create override file with custom pattern
    echo "# CUSTOM OVERRIDE PATTERN CONTENT" > CLAUDE.override.md

    # Run post-checkout hook
    .git/hooks/post-checkout "" "" "1"

    if grep -q "CUSTOM OVERRIDE PATTERN CONTENT" CLAUDE.md; then
        pass "Custom pattern works"
    else
        fail "Custom pattern did not work"
    fi

    # Restore for other tests
    rm -f CLAUDE.override.md
    git checkout HEAD -- CLAUDE.md 2>/dev/null || true
    create_config
}

test_multi_target_override() {
    info "Testing multi-target override (1:many)..."
    cd "$TEST_REPO"

    # Create config with one override replacing multiple files
    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: COMBINED.local.md
    replaces:
      - CLAUDE.md
      - AGENTS.md
EOF

    # Create single override file
    echo "# COMBINED CONTENT FOR BOTH FILES" > COMBINED.local.md

    # Run post-checkout hook
    .git/hooks/post-checkout "" "" "1"

    # Check both files were updated
    if grep -q "COMBINED CONTENT" CLAUDE.md && grep -q "COMBINED CONTENT" AGENTS.md; then
        pass "Multi-target override applied to all targets"
    else
        fail "Multi-target override did not apply to all targets"
    fi

    # Restore for other tests
    rm -f COMBINED.local.md
    git checkout HEAD -- CLAUDE.md AGENTS.md 2>/dev/null || true
    create_config
}

test_multi_target_pre_commit_restores_all() {
    info "Testing pre-commit restores ALL targets when one is staged..."
    cd "$TEST_REPO"

    # Create config with multi-target override
    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: COMBINED.local.md
    replaces:
      - CLAUDE.md
      - AGENTS.md
EOF

    # Create and apply override
    echo "# COMBINED LOCAL CONTENT" > COMBINED.local.md
    .git/hooks/post-checkout "" "" "1"

    # Verify both have local content
    if ! grep -q "COMBINED LOCAL CONTENT" CLAUDE.md || ! grep -q "COMBINED LOCAL CONTENT" AGENTS.md; then
        fail "Setup failed - override not applied to both targets"
        return
    fi

    # Stage ONLY CLAUDE.md (bypass clean filter to force staging)
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add CLAUDE.md

    # Run pre-commit hook - should restore BOTH files
    .git/hooks/pre-commit

    # Check both files have original content restored
    if grep -q "Original CLAUDE.md content" CLAUDE.md && grep -q "Original AGENTS.md in root" AGENTS.md; then
        pass "Pre-commit restored all targets in group when one was staged"
    else
        fail "Pre-commit did not restore all targets in group"
    fi

    # Restore
    rm -f COMBINED.local.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- CLAUDE.md AGENTS.md 2>/dev/null || true
    create_config
}

test_missing_pattern_error() {
    info "Testing error for missing pattern..."
    cd "$TEST_REPO"

    # Create config without pattern
    cat > .local-overrides.yaml << 'EOF'
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    echo "# MISSING PATTERN TEST" > CLAUDE.local.md

    # Run hook and capture stderr
    local output
    local exit_code=0
    output=$(.git/hooks/post-checkout "" "" "1" 2>&1) || exit_code=$?

    if [[ "$output" == *"pattern"* ]] && [[ $exit_code -ne 0 ]]; then
        pass "Error shown for missing pattern"
    else
        fail "No error for missing pattern (exit code: $exit_code)"
    fi

    rm -f CLAUDE.local.md
    git checkout HEAD -- CLAUDE.md 2>/dev/null || true
    create_config
}

test_duplicate_target_error() {
    info "Testing error for duplicate target file..."
    cd "$TEST_REPO"

    # Create config with same file in multiple replaces lists
    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: FIRST.local.md
    replaces:
      - CLAUDE.md
  - override: SECOND.local.md
    replaces:
      - CLAUDE.md
EOF

    echo "# FIRST" > FIRST.local.md
    echo "# SECOND" > SECOND.local.md

    # Run hook - should error
    local output
    local exit_code=0
    output=$(.git/hooks/post-checkout "" "" "1" 2>&1) || exit_code=$?

    if [[ "$output" == *"Duplicate"* ]] && [[ $exit_code -ne 0 ]]; then
        pass "Error shown for duplicate target file"
    else
        fail "No error for duplicate target (exit code: $exit_code, output: $output)"
    fi

    rm -f FIRST.local.md SECOND.local.md
    git checkout HEAD -- CLAUDE.md 2>/dev/null || true
    create_config
}

test_init_config_has_pattern() {
    info "Testing init-config creates config with pattern..."
    cd "$TEST_REPO"

    rm -f .local-overrides.yaml

    git-local-override init-config

    if grep -q "^pattern:" .local-overrides.yaml; then
        pass "init-config creates config with pattern field"
    else
        fail "init-config missing pattern field"
    fi

    # Restore
    create_config
}

test_list_shows_pattern() {
    info "Testing list command shows pattern..."
    cd "$TEST_REPO"
    create_config

    local output
    output=$(git-local-override list)

    if [[ "$output" == *"Configured overrides:"* ]]; then
        pass "List command shows configured overrides"
    else
        fail "List command does not show configured overrides"
    fi
}

test_recursive_child_config_overrides_parent_subtree() {
    info "Testing child config overrides parent subtree..."

    cd "$TEST_REPO"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    mkdir -p backend
    cat > backend/.local-overrides.yaml << 'EOF'
pattern: ".private"
files:
  - override: CLAUDE.private.md
    replaces:
      - CLAUDE.md
EOF

    echo "# ROOT LOCAL" > CLAUDE.local.md
    echo "# BACKEND PRIVATE" > backend/CLAUDE.private.md
    echo "# Original backend CLAUDE" > backend/CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add backend/CLAUDE.md .local-overrides.yaml backend/.local-overrides.yaml

    git-local-override apply >/dev/null

    if grep -q "ROOT LOCAL" CLAUDE.md && grep -q "BACKEND PRIVATE" backend/CLAUDE.md; then
        pass "Nearest child config owns its subtree"
    else
        fail "Recursive child config did not override parent subtree correctly"
    fi
}

test_recursive_parent_targeting_child_subtree_errors() {
    info "Testing parent config cannot target child-owned subtree..."

    cd "$TEST_REPO"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: backend/CLAUDE.local.md
    replaces:
      - backend/CLAUDE.md
EOF

    mkdir -p backend
    cat > backend/.local-overrides.yaml << 'EOF'
pattern: ".private"
files:
  - override: CLAUDE.private.md
    replaces:
      - CLAUDE.md
EOF

    local output
    local exit_code=0
    output=$(git-local-override list 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 && "$output" == *"belongs to a child subtree config"* ]]; then
        pass "Shadowed parent targets are rejected"
    else
        fail "Expected validation error for parent target in child subtree (exit: $exit_code, output: $output)"
    fi
}

test_recursive_add_uses_nearest_config_pattern() {
    info "Testing add uses nearest config pattern..."

    cd "$TEST_REPO"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    mkdir -p backend/services/foo
    cat > backend/.local-overrides.yaml << 'EOF'
pattern: ".private"
files:
  - override: AGENTS.private.md
    replaces:
      - AGENTS.md
EOF

    echo "# Backend nested target" > backend/services/foo/CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add backend/services/foo/CLAUDE.md backend/.local-overrides.yaml .local-overrides.yaml

    git-local-override add backend/services/foo/CLAUDE.md >/dev/null 2>&1 || true

    if [[ -f "backend/services/foo/CLAUDE.private.md" ]]; then
        pass "Add uses nearest config pattern for nested target"
    else
        fail "Add did not use nearest config pattern"
    fi
}

test_recursive_child_inherits_parent_pattern() {
    info "Testing child config inherits parent pattern..."

    cd "$TEST_REPO"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    mkdir -p backend
    cat > backend/.local-overrides.yaml << 'EOF'
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    echo "# BACKEND INHERITED LOCAL" > backend/CLAUDE.local.md
    echo "# Original backend CLAUDE" > backend/CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add backend/CLAUDE.md .local-overrides.yaml backend/.local-overrides.yaml

    git-local-override apply >/dev/null

    if grep -q "BACKEND INHERITED LOCAL" backend/CLAUDE.md; then
        pass "Child config inherits parent pattern"
    else
        fail "Child config did not inherit parent pattern behavior"
    fi
}

test_recursive_grandchild_overrides_inherited_pattern() {
    info "Testing grandchild overrides inherited pattern..."

    cd "$TEST_REPO"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    mkdir -p backend/services/foo
    cat > backend/.local-overrides.yaml << 'EOF'
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    cat > backend/services/.local-overrides.yaml << 'EOF'
pattern: ".private"
files:
  - override: CLAUDE.private.md
    replaces:
      - foo/CLAUDE.md
EOF

    echo "# BACKEND INHERITED LOCAL" > backend/CLAUDE.local.md
    echo "# SERVICES PRIVATE" > backend/services/CLAUDE.private.md
    echo "# Original foo CLAUDE" > backend/services/foo/CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add backend/services/foo/CLAUDE.md .local-overrides.yaml backend/.local-overrides.yaml backend/services/.local-overrides.yaml

    git-local-override apply >/dev/null

    if grep -q "SERVICES PRIVATE" backend/services/foo/CLAUDE.md; then
        pass "Grandchild explicit pattern overrides inherited pattern"
    else
        fail "Grandchild explicit pattern did not override inherited behavior"
    fi
}

test_recursive_add_uses_inherited_pattern() {
    info "Testing add uses inherited parent pattern..."

    cd "$TEST_REPO"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    mkdir -p backend/services/foo
    cat > backend/.local-overrides.yaml << 'EOF'
files:
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
EOF

    echo "# Backend nested target" > backend/services/foo/CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add backend/services/foo/CLAUDE.md backend/.local-overrides.yaml .local-overrides.yaml

    git-local-override add backend/services/foo/CLAUDE.md >/dev/null 2>&1 || true

    if [[ -f "backend/services/foo/CLAUDE.local.md" ]]; then
        pass "Add uses inherited parent pattern"
    else
        fail "Add did not use inherited parent pattern"
    fi
}

test_recursive_override_path_escape_errors() {
    info "Testing override path cannot escape child subtree..."

    cd "$TEST_REPO"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    mkdir -p backend
    cat > backend/.local-overrides.yaml << 'EOF'
pattern: ".private"
files:
  - override: ../CLAUDE.private.md
    replaces:
      - CLAUDE.md
EOF

    local output
    local exit_code=0
    output=$(git-local-override list 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 && "$output" == *"escapes its subtree"* ]]; then
        pass "Override path escape is rejected"
    else
        fail "Expected override path escape validation error (exit: $exit_code, output: $output)"
    fi
}

test_recursive_target_path_escape_errors() {
    info "Testing target path cannot escape child subtree..."

    cd "$TEST_REPO"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    mkdir -p backend
    cat > backend/.local-overrides.yaml << 'EOF'
pattern: ".private"
files:
  - override: CLAUDE.private.md
    replaces:
      - ../CLAUDE.md
EOF

    local output
    local exit_code=0
    output=$(git-local-override list 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 && "$output" == *"escapes its subtree"* ]]; then
        pass "Target path escape is rejected"
    else
        fail "Expected target path escape validation error (exit: $exit_code, output: $output)"
    fi
}

test_recursive_escape_is_rejected_by_hook_validation() {
    info "Testing hook validation rejects nested path escapes..."

    cd "$TEST_REPO"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    mkdir -p backend
    cat > backend/.local-overrides.yaml << 'EOF'
pattern: ".private"
files:
  - override: CLAUDE.private.md
    replaces:
      - ../CLAUDE.md
EOF

    echo "# INVALID" > backend/CLAUDE.private.md

    local output
    local exit_code=0
    output=$(.git/hooks/post-checkout "" "" "1" 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 && "$output" == *"escapes its subtree"* ]]; then
        pass "Hook validation rejects escaped nested paths"
    else
        fail "Expected hook validation error for escaped nested path (exit: $exit_code, output: $output)"
    fi
}

test_list_shows_grouped_targets() {
    info "Testing list command shows grouped targets..."
    cd "$TEST_REPO"

    # Create multi-target config
    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: COMBINED.local.md
    replaces:
      - CLAUDE.md
      - AGENTS.md
EOF

    echo "# COMBINED" > COMBINED.local.md

    local output
    output=$(git-local-override list)

    if [[ "$output" == *"COMBINED.local.md"* && "$output" == *"CLAUDE.md"* && "$output" == *"AGENTS.md"* ]]; then
        pass "List shows grouped targets"
    else
        echo "Output was: $output"
        fail "List does not show grouped targets"
    fi

    rm -f COMBINED.local.md
    create_config
}

#------------------------------------------------------------------------------
# Filter Tests (smudge/clean)
#------------------------------------------------------------------------------

test_filter_smudge_applies_override() {
    info "Testing smudge filter applies override when override exists..."
    cd "$TEST_REPO"
    create_config

    # Create filter scripts (they don't exist yet, so this should fail)
    local smudge_script=".git/hooks/local-override-filter-smudge"
    local clean_script=".git/hooks/local-override-filter-clean"

    if [[ ! -f "$smudge_script" ]]; then
        fail "Smudge filter script not found (expected - not implemented yet)"
        return
    fi

    # Create local override
    echo "# LOCAL SMUDGE CONTENT" > CLAUDE.local.md

    # Test smudge: should output local content when override exists
    local output
    output=$(echo "# Original CLAUDE.md content" | "$smudge_script" CLAUDE.md)

    if [[ "$output" == *"LOCAL SMUDGE CONTENT"* ]]; then
        pass "Smudge filter applies override"
    else
        fail "Smudge filter did not apply override"
    fi
}

test_filter_smudge_passthrough() {
    info "Testing smudge filter passes through when no override exists..."
    cd "$TEST_REPO"
    create_config

    local smudge_script=".git/hooks/local-override-filter-smudge"

    if [[ ! -f "$smudge_script" ]]; then
        fail "Smudge filter script not found (expected - not implemented yet)"
        return
    fi

    # Remove local override
    rm -f CLAUDE.local.md

    # Test smudge: should pass through stdin when no override
    local input="# Original content from git"
    local output
    output=$(echo "$input" | "$smudge_script" CLAUDE.md)

    if [[ "$output" == "$input" ]]; then
        pass "Smudge filter passes through without override"
    else
        fail "Smudge filter did not pass through (got: $output)"
    fi
}

test_filter_clean_returns_original() {
    info "Testing clean filter returns original content from git..."
    cd "$TEST_REPO"
    create_config

    local clean_script=".git/hooks/local-override-filter-clean"

    if [[ ! -f "$clean_script" ]]; then
        fail "Clean filter script not found (expected - not implemented yet)"
        return
    fi

    # Create local override
    echo "# LOCAL CLEAN CONTENT" > CLAUDE.local.md

    # Test clean: should output original from git, not local content
    local output
    output=$(echo "# LOCAL CLEAN CONTENT" | "$clean_script" CLAUDE.md)

    if [[ "$output" == *"Original CLAUDE.md content"* ]]; then
        pass "Clean filter returns original content"
    else
        fail "Clean filter did not return original (got: $output)"
    fi
}

test_filter_clean_passthrough() {
    info "Testing clean filter passes through when no override exists..."
    cd "$TEST_REPO"
    create_config

    local clean_script=".git/hooks/local-override-filter-clean"

    if [[ ! -f "$clean_script" ]]; then
        fail "Clean filter script not found (expected - not implemented yet)"
        return
    fi

    # Remove local override
    rm -f CLAUDE.local.md

    # Test clean: should pass through stdin when no override
    local input="# Content from working tree"
    local output
    output=$(echo "$input" | "$clean_script" CLAUDE.md)

    if [[ "$output" == "$input" ]]; then
        pass "Clean filter passes through without override"
    else
        fail "Clean filter did not pass through (got: $output)"
    fi
}

test_filter_roundtrip() {
    info "Testing filter roundtrip: clean(smudge(blob)) == blob..."
    cd "$TEST_REPO"
    create_config

    local smudge_script=".git/hooks/local-override-filter-smudge"
    local clean_script=".git/hooks/local-override-filter-clean"

    if [[ ! -f "$smudge_script" || ! -f "$clean_script" ]]; then
        fail "Filter scripts not found (expected - not implemented yet)"
        return
    fi

    # Create local override
    echo "# LOCAL ROUNDTRIP CONTENT" > CLAUDE.local.md

    # Original content from git
    local original="# Original CLAUDE.md content"

    # Roundtrip: original -> smudge -> clean -> should equal original
    local smudged
    smudged=$(echo "$original" | "$smudge_script" CLAUDE.md)

    local cleaned
    cleaned=$(echo "$smudged" | "$clean_script" CLAUDE.md)

    if [[ "$cleaned" == "$original" ]]; then
        pass "Filter roundtrip preserves original content"
    else
        fail "Filter roundtrip failed (original: '$original', cleaned: '$cleaned')"
    fi
}

test_filter_disable_env_var() {
    info "Testing filters passthrough when GIT_LOCAL_OVERRIDE_DISABLE=1..."
    cd "$TEST_REPO"
    create_config

    local smudge_script=".git/hooks/local-override-filter-smudge"
    local clean_script=".git/hooks/local-override-filter-clean"

    if [[ ! -f "$smudge_script" || ! -f "$clean_script" ]]; then
        fail "Filter scripts not found (expected - not implemented yet)"
        return
    fi

    # Create local override
    echo "# LOCAL DISABLED CONTENT" > CLAUDE.local.md

    # Test with disable flag
    local input="# Input content"
    local smudge_output
    local clean_output

    smudge_output=$(echo "$input" | GIT_LOCAL_OVERRIDE_DISABLE=1 "$smudge_script" CLAUDE.md)
    clean_output=$(echo "$input" | GIT_LOCAL_OVERRIDE_DISABLE=1 "$clean_script" CLAUDE.md)

    if [[ "$smudge_output" == "$input" && "$clean_output" == "$input" ]]; then
        pass "Filters passthrough when disabled"
    else
        fail "Filters did not passthrough when disabled"
    fi
}

test_filter_no_head_passthrough() {
    info "Testing clean filter passes through when HEAD doesn't exist..."
    cd "$TEST_REPO"

    # Create a fresh repo with no commits
    local temp_repo="$CURRENT_TEST_ROOT/no-head-repo"
    mkdir -p "$temp_repo"
    cd "$temp_repo"

    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"

    install_test_hooks "$temp_repo" "$PROJECT_DIR"

    local clean_script=".git/hooks/local-override-filter-clean"

    if [[ ! -f "$clean_script" ]]; then
        fail "Clean filter script not found (expected - not implemented yet)"
        cd "$TEST_REPO"
        return
    fi

    # Create config
    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    # Test clean without HEAD
    local input="# Content before first commit"
    local output
    output=$(echo "$input" | "$clean_script" CLAUDE.md)

    if [[ "$output" == "$input" ]]; then
        pass "Clean filter passes through when HEAD doesn't exist"
    else
        fail "Clean filter did not passthrough without HEAD (got: $output)"
    fi

    cd "$TEST_REPO"
}

test_filter_non_configured_file_passthrough() {
    info "Testing filters passthrough for non-configured files..."
    cd "$TEST_REPO"
    create_config

    local smudge_script=".git/hooks/local-override-filter-smudge"
    local clean_script=".git/hooks/local-override-filter-clean"

    if [[ ! -f "$smudge_script" || ! -f "$clean_script" ]]; then
        fail "Filter scripts not found (expected - not implemented yet)"
        return
    fi

    # Test with a file not in config
    local input="# Content for non-configured file"
    local smudge_output
    local clean_output

    smudge_output=$(echo "$input" | "$smudge_script" config.json)
    clean_output=$(echo "$input" | "$clean_script" config.json)

    if [[ "$smudge_output" == "$input" && "$clean_output" == "$input" ]]; then
        pass "Filters passthrough for non-configured files"
    else
        fail "Filters did not passthrough for non-configured file"
    fi
}

test_sync_filters_migrates_legacy_hook_paths() {
    info "Testing sync-filters migrates legacy .git/hooks filter paths..."
    cd "$TEST_REPO"
    create_config

    git config --local filter.local-override.smudge ".git/hooks/local-override-filter-smudge %f"
    git config --local filter.local-override.clean ".git/hooks/local-override-filter-clean %f"

    git-local-override sync-filters >/dev/null

    local smudge_cmd
    local clean_cmd
    smudge_cmd=$(git config --local filter.local-override.smudge 2>/dev/null || echo "")
    clean_cmd=$(git config --local filter.local-override.clean 2>/dev/null || echo "")

    if [[ "$smudge_cmd" == .git/hooks/* || "$clean_cmd" == .git/hooks/* ]]; then
        fail "sync-filters did not migrate legacy relative paths"
        return
    fi

    if [[ "$smudge_cmd" == /* && "$clean_cmd" == /* ]]; then
        pass "sync-filters migrated to absolute worktree-safe filter paths"
    else
        fail "sync-filters did not set absolute filter paths"
    fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    local test_fn
    local test_exit

    echo ""
    echo "========================================"
    echo "  git-local-override Test Suite"
    echo "========================================"
    echo ""

    trap cleanup EXIT

    setup_suite_seed

    echo ""
    echo "Running tests..."
    echo ""

    for test_fn in \
        test_cli_help \
        test_init_config \
        test_list_no_config \
        test_add_override \
        test_override_is_applied \
        test_git_status_after_override \
        test_restore_originals \
        test_list_overrides \
        test_remove_override \
        test_remove_with_delete \
        test_nested_override \
        test_post_checkout_hook \
        test_pre_commit_hook \
        test_post_commit_hook \
        test_status_command \
        test_no_override_when_no_local_file \
        test_file_not_in_config_error \
        test_hooks_check_for_config \
        test_custom_pattern \
        test_recursive_child_config_overrides_parent_subtree \
        test_recursive_parent_targeting_child_subtree_errors \
        test_recursive_add_uses_nearest_config_pattern \
        test_recursive_child_inherits_parent_pattern \
        test_recursive_grandchild_overrides_inherited_pattern \
        test_recursive_add_uses_inherited_pattern \
        test_recursive_override_path_escape_errors \
        test_recursive_target_path_escape_errors \
        test_recursive_escape_is_rejected_by_hook_validation \
        test_missing_pattern_error \
        test_init_config_has_pattern \
        test_list_shows_pattern \
        test_multi_target_override \
        test_multi_target_pre_commit_restores_all \
        test_duplicate_target_error \
        test_list_shows_grouped_targets \
        test_filter_smudge_applies_override \
        test_filter_smudge_passthrough \
        test_filter_clean_returns_original \
        test_filter_clean_passthrough \
        test_filter_roundtrip \
        test_filter_disable_env_var \
        test_filter_no_head_passthrough \
        test_filter_non_configured_file_passthrough \
        test_sync_filters_migrates_legacy_hook_paths; do
        CURRENT_TEST_NAME="$test_fn"
        setup_test_case

        set +e
        "$test_fn"
        test_exit=$?
        set -e

        if [[ $test_exit -ne 0 && $CURRENT_TEST_STATUS -eq 0 ]]; then
            fail "${test_fn} exited with status $test_exit"
        fi

        finalize_current_test_root "$CURRENT_TEST_STATUS"
    done

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
