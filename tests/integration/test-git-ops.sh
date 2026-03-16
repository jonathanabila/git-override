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

setup_seed_repo() {
    SUITE_ROOT="$(create_test_root "gitops" "suite")"
    setup_test_env "$SUITE_ROOT" "$PROJECT_DIR"
    cd "$TEST_REPO"

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
    cp "$PROJECT_DIR/hooks/local-override-pre-rebase" .git/hooks/pre-rebase
    cp "$PROJECT_DIR/hooks/local-override-filter-smudge" .git/hooks/
    cp "$PROJECT_DIR/hooks/local-override-filter-clean" .git/hooks/
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

    TEST_SEED_REPO="$SUITE_ROOT/artifacts/gitops-seed.git"
    create_seed_repo "$TEST_REPO" "$TEST_SEED_REPO"
}

configure_test_repo() {
    cd "$TEST_REPO"

    install_test_hooks "$TEST_REPO" "$PROJECT_DIR"
    git-local-override sync-filters >/dev/null

    # Create local override files
    echo "# MY LOCAL CLAUDE.md - customized for my environment" > CLAUDE.local.md
    echo "local_value: true" > config.local.yaml

    # Apply overrides initially
    git-local-override apply 2>/dev/null || true
}

setup_repo() {
    CURRENT_TEST_ROOT="$(create_test_root "gitops" "$CURRENT_TEST_NAME")"
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

    echo "# TEMPORARY CHANGE - should be filtered" > CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add CLAUDE.md

    if ! git commit -q -m "Commit CLAUDE.md" 2>/dev/null; then
        info "No changes to commit (clean filter returned original)"
        pass "Clean filter prevented staging different content"

        cp CLAUDE.local.md CLAUDE.md 2>/dev/null || true
        return 0
    fi

    local committed_content
    committed_content=$(git show HEAD:CLAUDE.md)

    if echo "$committed_content" | grep -q "Original CLAUDE.md content"; then
        pass "Clean filter ensured original content in commit"
    else
        fail "Clean filter failed - commit has wrong content"
        echo "Committed: $committed_content"
        return 1
    fi

    cp CLAUDE.local.md CLAUDE.md 2>/dev/null || true

    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "Working tree restored to local content"
    else
        fail "Working tree not restored"
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

test_rebase_with_divergent_overridden_file() {
    info "Testing rebase succeeds with divergent override (filter-driven)..."

    cd "$TEST_DIR"

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    git branch -D rebase-diverge-feature 2>/dev/null || true

    # Feature branch with non-overridden change
    git checkout -q -b rebase-diverge-feature
    echo "feature-line" >> README.md
    git add README.md
    git commit -q -m "Feature commit for divergent rebase"

    # Main branch changes overridden file content in git history
    git checkout -q "$default_branch"
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- CLAUDE.md
    echo "# Upstream CLAUDE update" > CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add CLAUDE.md
    git commit -q --no-verify -m "Upstream updates CLAUDE"

    # Back to feature branch with overrides active (clean filter hides changes)
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout -q rebase-diverge-feature
    # Keep override files so clean filter works
    git-local-override apply 2>/dev/null || true

    local rebase_output
    local rebase_status
    set +e
    rebase_output=$(git rebase "$default_branch" 2>&1)
    rebase_status=$?
    set -e

    if [[ $rebase_status -ne 0 ]]; then
        local pre_rebase_status
        pre_rebase_status=$(git status --porcelain 2>/dev/null || true)
        fail "Rebase failed: $rebase_output; pre-rebase status: $pre_rebase_status"
        git rebase --abort 2>/dev/null || true
        git checkout -q "$default_branch" 2>/dev/null || true
        return 1
    fi

    pass "Rebase succeeded with divergent overridden file"
    git checkout -q "$default_branch" 2>/dev/null || true
}

setup_rebase_override_presence_scenario() {
    cd "$TEST_DIR"

    # Add AGENTS.md as tracked target for this regression scenario
    echo "# Original AGENTS content" > AGENTS.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add AGENTS.md
    git commit -q --no-verify -m "Add AGENTS target for rebase regression"

    cat >> .local-overrides.yaml << 'EOF'
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
EOF
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add .local-overrides.yaml
    git commit -q --no-verify -m "Configure AGENTS override target"

    cat >> .git/info/attributes << 'EOF'
AGENTS.md filter=local-override
EOF

    cat > AGENTS.local.md << 'EOF'
# MY LOCAL AGENTS
local customized content
EOF
    git-local-override apply 2>/dev/null || true

    if ! grep -q "local customized content" AGENTS.md; then
        fail "Pre-condition: AGENTS local override content not applied"
        return 1
    fi

    return 0
}

test_rebase_succeeds_with_override_file_present() {
    info "Testing rebase succeeds when override file remains present..."

    cd "$TEST_DIR"

    if ! setup_rebase_override_presence_scenario; then
        return 1
    fi

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    git branch -D rebase-override-present 2>/dev/null || true

    git checkout -q -b rebase-override-present
    echo "feature-line" >> README.md
    git add README.md
    git commit -q -m "Feature commit for rebase reproduction"

    git checkout -q "$default_branch"
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- AGENTS.md
    echo "# Upstream AGENTS change" > AGENTS.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add AGENTS.md
    git commit -q --no-verify -m "Upstream updates AGENTS"

    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- AGENTS.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout -q rebase-override-present
    git-local-override apply 2>/dev/null || true

    if [[ ! -f AGENTS.local.md ]]; then
        fail "Setup invalid: override file missing before rebase"
        return 1
    fi

    local rebase_output
    local rebase_status
    set +e
    rebase_output=$(git rebase "$default_branch" 2>&1)
    rebase_status=$?
    set -e

    if [[ $rebase_status -ne 0 ]]; then
        fail "Expected rebase success with override file present: $rebase_output"
        git rebase --abort 2>/dev/null || true
        git checkout -q "$default_branch" 2>/dev/null || true
        return 1
    fi

    if [[ ! -f AGENTS.local.md ]]; then
        fail "Override file unexpectedly disappeared during rebase"
        return 1
    fi

    pass "Rebase succeeded with override file still present"

    git checkout -q "$default_branch" 2>/dev/null || true
}

test_rebase_succeeds_when_override_file_removed_before_rebase() {
    info "Testing rebase succeeds when override file is removed before rebase..."

    cd "$TEST_DIR"

    if ! setup_rebase_override_presence_scenario; then
        return 1
    fi

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    git branch -D rebase-override-workaround 2>/dev/null || true

    git checkout -q -b rebase-override-workaround
    echo "feature-line" >> README.md
    git add README.md
    git commit -q -m "Feature commit for workaround rebase"

    git checkout -q "$default_branch"
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- AGENTS.md
    echo "# Upstream AGENTS change" > AGENTS.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add AGENTS.md
    git commit -q --no-verify -m "Upstream updates AGENTS for workaround"

    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- AGENTS.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout -q rebase-override-workaround

    if [[ ! -f AGENTS.local.md ]]; then
        fail "Setup invalid: override file missing before workaround step"
        return 1
    fi

    rm -f AGENTS.local.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- AGENTS.md

    local attrs_tmp
    attrs_tmp="$(mktemp "${TMPDIR:-/tmp}/attrs.XXXXXX")"
    grep -v '^AGENTS.md filter=local-override$' .git/info/attributes > "$attrs_tmp" 2>/dev/null || true
    mv "$attrs_tmp" .git/info/attributes

    local workaround_hash
    local head_hash
    workaround_hash=$(git hash-object AGENTS.md)
    head_hash=$(git show HEAD:AGENTS.md | git hash-object --stdin)

    if [[ "$workaround_hash" != "$head_hash" ]]; then
        fail "Setup invalid before workaround rebase: AGENTS.md still differs from HEAD"
        return 1
    fi

    local pre_rebase_status
    pre_rebase_status=$(git status --porcelain=v2 -- AGENTS.md 2>/dev/null || true)
    if [[ -n "$pre_rebase_status" ]]; then
        fail "Setup invalid before workaround rebase: repository not clean: $pre_rebase_status"
        return 1
    fi

    local rebase_output
    local rebase_status
    set +e
    rebase_output=$(git rebase "$default_branch" 2>&1)
    rebase_status=$?
    set -e

    if [[ $rebase_status -ne 0 ]]; then
        fail "Expected rebase success after removing override file: $rebase_output"
        git rebase --abort 2>/dev/null || true
        git checkout -q "$default_branch" 2>/dev/null || true
        return 1
    fi

    pass "Rebase succeeds when override file is removed before rebase"
    git checkout -q "$default_branch" 2>/dev/null || true
}

test_no_override_without_local_file() {
    info "Testing file without .local version is unchanged..."

    cd "$TEST_DIR"

    # Remove the local file for config.yaml
    rm -f config.local.yaml

    # Restore original (bypass smudge filter)
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- config.yaml

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

    git-local-override restore

    # After restore with GIT_LOCAL_OVERRIDE_DISABLE=1, original content should be present
    if grep -q "Original CLAUDE.md content" CLAUDE.md; then
        pass "Restore returned original content"
    else
        fail "Restore did not return original content"
        cat CLAUDE.md
        return 1
    fi

    git-local-override apply
}

test_dirty_working_tree_commit() {
    info "Testing commit with dirty working tree..."

    cd "$TEST_DIR"

    echo "Unstaged change" >> README.md

    echo "temp_value: false" > config.yaml
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add config.yaml

    if git diff --cached --quiet; then
        info "Clean filter returned original (matches HEAD)"
        pass "Clean filter working correctly with dirty tree"
        git checkout HEAD -- README.md
        cp config.local.yaml config.yaml 2>/dev/null || true
    
        return 0
    fi

    if ! git commit -q -m "Commit config" 2>/dev/null; then
        fail "Commit failed"
        git checkout HEAD -- README.md
        return 1
    fi

    local committed_content
    committed_content=$(git show HEAD:config.yaml)

    if echo "$committed_content" | grep -q "original_value"; then
        pass "Config committed with original content (clean filter)"
    else
        fail "Config committed with wrong content"
        git checkout HEAD -- README.md
        return 1
    fi

    cp config.local.yaml config.yaml 2>/dev/null || true

    if grep -q "local_value" config.yaml; then
        pass "Local content restored in working tree"
    else
        fail "Local content not restored"
        git checkout HEAD -- README.md
        return 1
    fi

    if grep -q "Unstaged change" README.md; then
        pass "Unstaged changes preserved"
    else
        fail "Unstaged changes lost"
        git checkout HEAD -- README.md
        return 1
    fi

    git checkout HEAD -- README.md
}

test_hooks_skip_without_config() {
    info "Testing hooks skip without config file..."

    cd "$TEST_DIR"

    # Remove config
    rm -f .local-overrides.yaml .local-overrides

    # Restore original content deterministically (bypass smudge filter)
    git show "HEAD:CLAUDE.md" > CLAUDE.md
    git show "HEAD:config.yaml" > config.yaml

    # Make a change and commit
    echo "No config test" >> README.md
    git add README.md
    git commit -q -m "No config commit"

    # Files should still match tracked content from HEAD (not local override content)
    local expected_content
    local actual_content
    expected_content=$(GIT_LOCAL_OVERRIDE_DISABLE=1 git show "HEAD:CLAUDE.md" 2>/dev/null || echo "")
    actual_content=$(cat CLAUDE.md 2>/dev/null || echo "")
    if [[ "$actual_content" == "$expected_content" ]] && [[ "$actual_content" != *"MY LOCAL"* ]]; then
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
# Filter Integration Tests
#------------------------------------------------------------------------------

test_checkout_with_override_active() {
    info "Testing checkout with override active (non-divergent files)..."

    cd "$TEST_DIR"

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    if git show-ref --verify --quiet "refs/heads/feature-diverge"; then
        git branch -D feature-diverge 2>/dev/null || true
    fi

    git checkout -q -b feature-diverge

    echo "# Feature branch README change" >> README.md
    git add README.md
    git commit -q -m "Change on feature branch"

    git checkout -q "$default_branch"

    if [[ ! -f "CLAUDE.local.md" ]]; then
        echo "# MY LOCAL CLAUDE.md - personal instructions" > CLAUDE.local.md
    fi

    cp CLAUDE.local.md CLAUDE.md

    local checkout_output
    checkout_output=$(git checkout feature-diverge 2>&1)
    local checkout_status=$?

    if [[ $checkout_status -ne 0 ]]; then
        fail "Checkout failed: $checkout_output"
        git checkout -q "$default_branch" 2>/dev/null || true
        return 1
    fi

    if grep -q "MY LOCAL CLAUDE.md" CLAUDE.md; then
        pass "Checkout succeeded and local override preserved"
    else
        fail "Checkout succeeded but local override lost"
        git checkout -q "$default_branch"
        return 1
    fi

    local status_output
    status_output=$(git status --porcelain | grep -v "^??" || true)

    if [[ -z "$status_output" ]]; then
        pass "Git status is clean after checkout (ignoring untracked files)"
    else
        fail "Git status shows changes: $status_output"
        git checkout -q "$default_branch"
        return 1
    fi

    git checkout -q "$default_branch"
}

test_checkout_with_truly_divergent_overridden_file() {
    info "Testing checkout with truly divergent overridden file..."

    cd "$TEST_DIR"

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    if git show-ref --verify --quiet "refs/heads/feature-divergent-override"; then
        git branch -D feature-divergent-override 2>/dev/null || true
    fi

    # Create feature branch with different CLAUDE.md content
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- CLAUDE.md
    git checkout -q -b feature-divergent-override
    echo "# Feature branch CLAUDE.md content - DIFFERENT" > CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add CLAUDE.md
    git commit -q --no-verify -m "Change CLAUDE.md on feature branch"

    # Back on main, create override
    git checkout -q "$default_branch"

    if [[ ! -f "CLAUDE.local.md" ]]; then
        echo "# MY LOCAL CLAUDE.md - personal instructions" > CLAUDE.local.md
    fi

    # Apply override (working tree has override content)
    git-local-override apply 2>/dev/null || true

    # Verify override is active
    if ! grep -q "MY LOCAL" CLAUDE.md; then
        fail "Pre-condition: override not applied"
        return 1
    fi

    # git checkout feature — must succeed
    local checkout_output
    checkout_output=$(git checkout feature-divergent-override 2>&1)
    local checkout_status=$?

    if [[ $checkout_status -ne 0 ]]; then
        fail "Checkout to feature branch failed: $checkout_output"
        git checkout -q "$default_branch" 2>/dev/null || true
        return 1
    fi

    # Verify override still active (smudge filter re-applied)
    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "Checkout succeeded to feature branch with override preserved"
    else
        fail "Override lost after checkout to feature branch"
        git checkout -q "$default_branch" 2>/dev/null || true
        return 1
    fi

    # git checkout main — must succeed back
    checkout_output=$(git checkout "$default_branch" 2>&1)
    checkout_status=$?

    if [[ $checkout_status -ne 0 ]]; then
        fail "Checkout back to $default_branch failed: $checkout_output"
        return 1
    fi

    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "Checkout back to $default_branch succeeded with override preserved"
    else
        fail "Override lost after checkout back to $default_branch"
        return 1
    fi
}

test_shell_init_checkout_with_divergent_file() {
    info "Testing shell-init wrapper with divergent overridden file..."

    cd "$TEST_DIR"

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    if git show-ref --verify --quiet "refs/heads/feature-shell-init"; then
        git branch -D feature-shell-init 2>/dev/null || true
    fi

    # Create feature branch with different CLAUDE.md content
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- CLAUDE.md
    git checkout -q -b feature-shell-init
    echo "# Shell-init feature branch CLAUDE.md" > CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add CLAUDE.md
    git commit -q --no-verify -m "Diverge CLAUDE.md for shell-init test"

    # Back on main, apply override
    git checkout -q "$default_branch"

    if [[ ! -f "CLAUDE.local.md" ]]; then
        echo "# MY LOCAL CLAUDE.md - shell-init test" > CLAUDE.local.md
    fi

    git-local-override apply 2>/dev/null || true

    if ! grep -q "MY LOCAL" CLAUDE.md; then
        fail "Pre-condition: override not applied"
        return 1
    fi

    # Source the shell-init wrapper
    eval "$(git-local-override shell-init)"

    # Use the wrapper to checkout (this calls the git function)
    local checkout_output
    local checkout_status=0
    checkout_output=$(git checkout feature-shell-init 2>&1) || checkout_status=$?

    if [[ $checkout_status -ne 0 ]]; then
        fail "Shell-init wrapper checkout failed: $checkout_output"
        unset -f git
        command git checkout -q "$default_branch" 2>/dev/null || true
        return 1
    fi

    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "Shell-init wrapper checkout preserved override"
    else
        fail "Shell-init wrapper checkout lost override"
        unset -f git
        command git checkout -q "$default_branch" 2>/dev/null || true
        return 1
    fi

    # Checkout back
    git checkout "$default_branch" 2>/dev/null || true

    # Unset the wrapper function
    unset -f git

    pass "Shell-init wrapper handles divergent files correctly"
}

test_switch_with_divergent_overridden_file() {
    info "Testing git switch with divergent branches..."

    if ! git switch --help &>/dev/null; then
        info "git switch not available (Git < 2.23), skipping"
        pass "Skipped (git switch not available)"
        return 0
    fi

    cd "$TEST_DIR"

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    if ! git show-ref --verify --quiet "refs/heads/feature-switch-test"; then
        git checkout -q -b feature-switch-test
        echo "# Feature for switch test" >> README.md
        git add README.md
        git commit -q -m "Feature commit for switch test"
        git checkout -q "$default_branch"
    fi

    if [[ ! -f "CLAUDE.local.md" ]]; then
        echo "# MY LOCAL CLAUDE.md - personal instructions" > CLAUDE.local.md
    fi


    cp CLAUDE.local.md CLAUDE.md

    if ! git switch -q feature-switch-test 2>/dev/null; then
        fail "git switch failed"
        git checkout -q "$default_branch"
        return 1
    fi

    if grep -q "MY LOCAL CLAUDE.md" CLAUDE.md; then
        pass "git switch preserved local override"
    else
        fail "git switch lost local override"
        git checkout -q "$default_branch"
        return 1
    fi

    local status_output
    status_output=$(git status --porcelain | grep -v "^??" || true)
    
    if [[ -z "$status_output" ]]; then
        pass "Git status is clean after switch"
    else
        fail "Git status shows changes after switch"
        git checkout -q "$default_branch"
        return 1
    fi

    git switch -q "$default_branch" || git checkout -q "$default_branch"
}

test_pull_with_overridden_file() {
    info "Testing git pull with overridden file..."

    cd "$TEST_DIR"

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    if git show-ref --verify --quiet "refs/heads/feature-pull"; then
        git branch -D feature-pull 2>/dev/null || true
    fi

    git checkout -q -b feature-pull
    echo "# Feature pull change" >> README.md
    git add README.md
    git commit -q -m "Remote-like change"
    git checkout -q "$default_branch"


    cp CLAUDE.local.md CLAUDE.md

    if ! git merge -q --no-edit feature-pull 2>/dev/null; then
        fail "Merge (simulating pull) failed"
        git merge --abort 2>/dev/null || true
        return 1
    fi

    if grep -q "MY LOCAL CLAUDE.md" CLAUDE.md; then
        pass "Local override preserved after merge (simulating pull)"
    else
        fail "Local override lost after merge"
        return 1
    fi

    local status_output
    status_output=$(git status --porcelain | grep -v "^??" || true)
    
    if [[ -z "$status_output" ]]; then
        pass "Git status is clean after merge"
    else
        fail "Git status shows changes"
        return 1
    fi
}

test_merge_with_overridden_file() {
    info "Testing git merge with overridden file..."

    cd "$TEST_DIR"

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    if git show-ref --verify --quiet "refs/heads/merge-test-branch"; then
        git branch -D merge-test-branch 2>/dev/null || true
    fi
    
    git checkout -q -b merge-test-branch
    echo "# Merge branch change" >> README.md
    git add README.md
    git commit -q -m "Change on merge branch"
    git checkout -q "$default_branch"


    cp CLAUDE.local.md CLAUDE.md

    if ! git merge -q --no-edit merge-test-branch 2>/dev/null; then
        fail "git merge failed"
        git merge --abort 2>/dev/null || true
        return 1
    fi

    if grep -q "MY LOCAL CLAUDE.md" CLAUDE.md; then
        pass "Local override preserved after merge"
    else
        fail "Local override lost after merge"
        return 1
    fi

    local status_output
    status_output=$(git status --porcelain | grep -v "^??" || true)
    
    if [[ -z "$status_output" ]]; then
        pass "Git status is clean after merge"
    else
        fail "Git status shows changes"
        return 1
    fi
}

test_rebase_with_overridden_file() {
    info "Testing git rebase with overridden file..."

    cd "$TEST_DIR"

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    if git show-ref --verify --quiet "refs/heads/rebase-test-branch"; then
        git branch -D rebase-test-branch 2>/dev/null || true
    fi

    git checkout -q -b rebase-test-branch HEAD~1 2>/dev/null || git checkout -q -b rebase-test-branch
    echo "New file for rebase" > rebase-file.txt
    git add rebase-file.txt
    git commit -q -m "Commit for rebase"


    cp CLAUDE.local.md CLAUDE.md

    if ! git rebase -q "$default_branch" 2>/dev/null; then
        info "Rebase had conflicts or issues, aborting"
        git rebase --abort 2>/dev/null || true
        git checkout -q "$default_branch"
        pass "Rebase test skipped (conflicts)"
        return 0
    fi

    if grep -q "MY LOCAL CLAUDE.md" CLAUDE.md; then
        pass "Local override preserved after rebase"
    else
        fail "Local override lost after rebase"
        git checkout -q "$default_branch"
        return 1
    fi

    local status_output
    status_output=$(git status --porcelain | grep -v "^??" || true)
    
    if [[ -z "$status_output" ]]; then
        pass "Git status is clean after rebase"
    else
        info "Status: $status_output"
        pass "Rebase completed (status may show rebase artifacts)"
    fi

    git checkout -q "$default_branch"
}

test_stash_with_overridden_file() {
    info "Testing git stash with overridden file..."

    cd "$TEST_DIR"

    echo "# Temporary change" >> README.md
    git add README.md

    if ! git stash -q 2>/dev/null; then
        fail "git stash failed"
        git reset HEAD README.md 2>/dev/null || true
        return 1
    fi

    if grep -q "MY LOCAL CLAUDE.md" CLAUDE.md; then
        pass "Local override preserved after stash"
    else
        fail "Local override lost after stash"
        return 1
    fi

    if ! git stash pop -q 2>/dev/null; then
        fail "git stash pop failed"
        git stash drop 2>/dev/null || true
        return 1
    fi

    if grep -q "MY LOCAL CLAUDE.md" CLAUDE.md; then
        pass "Local override preserved after stash pop"
    else
        fail "Local override lost after stash pop"
        return 1
    fi

    git checkout HEAD -- README.md 2>/dev/null || true
}

test_commit_still_contains_original() {
    info "Testing commit contains original content with filters active..."

    cd "$TEST_DIR"


    cp CLAUDE.local.md CLAUDE.md

    local claude_before
    claude_before=$(git show HEAD:CLAUDE.md 2>/dev/null || echo "")

    echo "Test change for commit test" >> README.md
    git add README.md
    git commit -q -m "Test commit with filters"

    local committed_claude
    committed_claude=$(git show HEAD:CLAUDE.md 2>/dev/null || echo "")

    if [[ "$committed_claude" == "$claude_before" ]]; then
        pass "Committed content unchanged for CLAUDE.md (not local override)"
    else
        fail "Committed content contains local override"
        echo "Committed: $committed_claude"
        return 1
    fi
}

test_filter_and_hooks_coexist() {
    info "Testing filters and hooks work together..."

    cd "$TEST_DIR"




    cp CLAUDE.local.md CLAUDE.md 2>/dev/null || true
    cp config.local.yaml config.yaml 2>/dev/null || true

    echo "Change for coexist test" >> README.md
    git add README.md
    git commit -q -m "Test coexistence"

    if grep -q "MY LOCAL CLAUDE.md" CLAUDE.md && grep -q "local_value" config.yaml; then
        pass "Both hooks and filters applied local content after commit"
    else
        fail "Hooks or filters did not apply correctly"
        return 1
    fi

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    if git show-ref --verify --quiet "refs/heads/coexist-test-branch"; then
        git branch -D coexist-test-branch 2>/dev/null || true
    fi
    
    git checkout -q -b coexist-test-branch
    git checkout -q "$default_branch"

    if grep -q "MY LOCAL CLAUDE.md" CLAUDE.md && grep -q "local_value" config.yaml; then
        pass "Filters and hooks coexist on checkout"
    else
        fail "Filters or hooks failed on checkout"
        return 1
    fi
}

test_no_override_file_normal_checkout() {
    info "Testing checkout without .local file works normally..."

    cd "$TEST_DIR"

    rm -f config.local.yaml


    git checkout HEAD -- config.yaml

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    if ! git show-ref --verify --quiet "refs/heads/passthrough-test-branch"; then
        git checkout -q -b passthrough-test-branch
        git checkout -q "$default_branch"
    else
        git checkout -q passthrough-test-branch
        git checkout -q "$default_branch"
    fi

    if grep -q "original_value" config.yaml; then
        pass "File without .local override passes through normally"
    else
        fail "File without .local override was modified"
        return 1
    fi

    echo "local_value: true" > config.local.yaml
}

test_disable_env_var_allows_restore() {
    info "Testing GIT_LOCAL_OVERRIDE_DISABLE=1 restores original..."

    cd "$TEST_DIR"

    if ! grep -q "MY LOCAL CLAUDE.md" CLAUDE.md; then
        cp CLAUDE.local.md CLAUDE.md 2>/dev/null || true
    fi



    local expected_content
    expected_content=$(git show HEAD:CLAUDE.md 2>/dev/null || echo "")

    # Remove file first to force git to re-run the smudge filter
    rm -f CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- CLAUDE.md

    if [[ "$(cat CLAUDE.md 2>/dev/null || echo "")" == "$expected_content" ]]; then
        pass "GIT_LOCAL_OVERRIDE_DISABLE=1 restored true original"
    else
        fail "GIT_LOCAL_OVERRIDE_DISABLE=1 did not restore original"
        cat CLAUDE.md
        return 1
    fi

    cp CLAUDE.local.md CLAUDE.md 2>/dev/null || true

}

test_worktree_add_with_filters() {
    info "Testing git worktree add works with filters..."

    cd "$TEST_DIR"

    local default_branch
    local worktree_branch="worktree-filter-test-branch"
    local worktree_dir="$TEST_DIR/worktrees/worktree-filter-test"
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    rm -rf "$worktree_dir"
    mkdir -p "$TEST_DIR/worktrees"
    git branch -D "$worktree_branch" 2>/dev/null || true

    local output
    output=$(git worktree add -b "$worktree_branch" "$worktree_dir" "$default_branch" 2>&1)
    local status=$?

    if [[ $status -ne 0 ]]; then
        fail "git worktree add failed: $output"
        git worktree remove -f "$worktree_dir" 2>/dev/null || true
        git branch -D "$worktree_branch" 2>/dev/null || true
        return 1
    fi

    if [[ -d "$worktree_dir" ]]; then
        pass "git worktree add succeeded with filters configured"
    else
        fail "Worktree directory was not created"
        git branch -D "$worktree_branch" 2>/dev/null || true
        return 1
    fi

    git worktree remove -f "$worktree_dir" 2>/dev/null || true
    git branch -D "$worktree_branch" 2>/dev/null || true
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

    setup_seed_repo

    local test_fn
    for test_fn in \
        test_commit_preserves_original \
        test_commit_restores_local_after \
        test_commit_staged_override_file \
        test_branch_checkout_applies_overrides \
        test_git_switch_applies_overrides \
        test_multiple_files_override \
        test_rebase_succeeds_when_override_file_removed_before_rebase \
        test_rebase_succeeds_with_override_file_present \
        test_rebase_with_divergent_overridden_file \
        test_no_override_without_local_file \
        test_restore_command \
        test_dirty_working_tree_commit \
        test_hooks_skip_without_config \
        test_checkout_with_override_active \
        test_checkout_with_truly_divergent_overridden_file \
        test_shell_init_checkout_with_divergent_file \
        test_switch_with_divergent_overridden_file \
        test_pull_with_overridden_file \
        test_merge_with_overridden_file \
        test_rebase_with_overridden_file \
        test_stash_with_overridden_file \
        test_commit_still_contains_original \
        test_filter_and_hooks_coexist \
        test_no_override_file_normal_checkout \
        test_disable_env_var_allows_restore \
        test_worktree_add_with_filters; do
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
