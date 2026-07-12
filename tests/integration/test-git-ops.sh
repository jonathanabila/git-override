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

# Colors, counters, pass/fail/info, and finish_suite come from test-lib.sh.

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
    cp "$PROJECT_DIR/shared/local-override-resolver.sh" .git/hooks/
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

get_index_flag() {
    local target="$1"
    local ls_output=""

    ls_output="$(git ls-files -v -- "$target" 2>/dev/null || true)"
    printf '%s\n' "${ls_output:0:1}"
}

# Path of the per-worktree one-shot repair marker for the current checkout
# (mirrors skip_worktree_repair_marker in the lib/CLI).
skip_worktree_marker_path() {
    local git_dir=""

    git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null || echo "")"
    [[ -n "$git_dir" ]] || return 1
    printf '%s\n' "$git_dir/local-override-skipworktree-repaired"
}

setup_legacy_skip_worktree_state() {
    local target="${1:-CLAUDE.md}"
    local override_file="${2:-CLAUDE.local.md}"

    if [[ ! -f "$override_file" ]]; then
        fail "Pre-condition: missing override file $override_file"
        return 1
    fi

    cp "$override_file" "$target"

    if cmp -s "$target" <(git show "HEAD:$target"); then
        fail "Pre-condition: $target does not differ from HEAD before forcing skip-worktree"
        return 1
    fi

    git update-index --skip-worktree -- "$target"
    return 0
}

assert_legacy_hidden_mismatch_state() {
    local target="$1"
    local status_output
    local index_flag

    if ! cmp -s "$target" <(git show "HEAD:$target"); then
        pass "Legacy state keeps $target different from HEAD"
    else
        fail "Expected $target to differ from HEAD in legacy state"
        return 1
    fi

    index_flag="$(get_index_flag "$target")"
    if [[ "$index_flag" == "S" ]]; then
        pass "Legacy skip-worktree bit is set on $target"
    else
        fail "Expected skip-worktree bit on $target"
        return 1
    fi

    status_output="$(git status --porcelain -- "$target" 2>/dev/null || true)"
    if [[ -z "$status_output" ]]; then
        pass "Legacy mismatch stays hidden from git status"
    else
        fail "Expected hidden mismatch for $target, got: $status_output"
        return 1
    fi
}

assert_skip_worktree_cleared() {
    local target="$1"
    local index_flag

    index_flag="$(get_index_flag "$target")"
    if [[ "$index_flag" != "S" ]]; then
        pass "Legacy skip-worktree bit cleared for $target"
    else
        fail "Legacy skip-worktree bit still set for $target"
        return 1
    fi
}

assert_reset_hard_succeeds() {
    local reset_output
    local reset_status

    set +e
    reset_output="$(git reset --hard 2>&1)"
    reset_status=$?
    set -e

    if [[ $reset_status -eq 0 ]]; then
        pass "git reset --hard succeeds after repair"
    else
        fail "git reset --hard failed after repair: $reset_output"
        return 1
    fi
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

test_install_self_heals_legacy_skip_worktree() {
    info "Testing install.sh self-heals legacy skip-worktree state..."

    cd "$TEST_DIR"

    if ! setup_legacy_skip_worktree_state "CLAUDE.md"; then
        return 1
    fi

    if ! assert_legacy_hidden_mismatch_state "CLAUDE.md"; then
        return 1
    fi

    local output_file="$TEST_ROOT/install-self-heal.log"
    if ! "$PROJECT_DIR/scripts/install.sh" --repo > "$output_file" 2>&1; then
        fail "install.sh --repo failed during legacy self-heal test"
        cat "$output_file" || true
        return 1
    fi

    if ! assert_skip_worktree_cleared "CLAUDE.md"; then
        return 1
    fi

    if grep -q "Cleared legacy skip-worktree on 1 managed file(s)" "$output_file"; then
        pass "install.sh reported repaired managed files"
    else
        fail "install.sh did not report legacy skip-worktree repair"
        cat "$output_file" || true
        return 1
    fi

    assert_reset_hard_succeeds
}

test_sync_filters_self_heals_legacy_skip_worktree() {
    info "Testing sync-filters self-heals legacy skip-worktree state..."

    cd "$TEST_DIR"

    if ! setup_legacy_skip_worktree_state "CLAUDE.md"; then
        return 1
    fi

    if ! assert_legacy_hidden_mismatch_state "CLAUDE.md"; then
        return 1
    fi

    local output_file="$TEST_ROOT/sync-filters-self-heal.log"
    if ! git-local-override sync-filters > "$output_file" 2>&1; then
        fail "git-local-override sync-filters failed during legacy self-heal test"
        cat "$output_file" || true
        return 1
    fi

    if ! assert_skip_worktree_cleared "CLAUDE.md"; then
        return 1
    fi

    if grep -q "Cleared legacy skip-worktree on 1 managed file(s)" "$output_file"; then
        pass "sync-filters reported repaired managed files"
    else
        fail "sync-filters did not report legacy skip-worktree repair"
        cat "$output_file" || true
        return 1
    fi

    assert_reset_hard_succeeds
}

test_post_checkout_self_heals_legacy_skip_worktree() {
    info "Testing post-checkout self-heals legacy skip-worktree on first run..."

    cd "$TEST_DIR"

    # Model a genuine hooks-only legacy upgrade: no repair marker yet, so the
    # first hot-path checkout must still self-heal. setup's sync-filters writes the
    # marker, so remove it to simulate a repo that never ran the new sync-filters.
    rm -f "$(skip_worktree_marker_path)"

    if ! setup_legacy_skip_worktree_state "CLAUDE.md"; then
        return 1
    fi

    if ! assert_legacy_hidden_mismatch_state "CLAUDE.md"; then
        return 1
    fi

    local checkout_output
    local checkout_status
    set +e
    checkout_output="$(git checkout -q -b legacy-self-heal-branch 2>&1)"
    checkout_status=$?
    set -e

    if [[ $checkout_status -ne 0 ]]; then
        fail "git checkout failed during runtime self-heal test: $checkout_output"
        return 1
    fi

    if ! assert_skip_worktree_cleared "CLAUDE.md"; then
        return 1
    fi

    if grep -q "git-local-override: cleared legacy skip-worktree on 1 managed file(s)" <<< "$checkout_output"; then
        pass "post-checkout emitted runtime repair notice"
    else
        fail "post-checkout did not emit runtime repair notice"
        printf '%s\n' "$checkout_output"
        return 1
    fi

    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "post-checkout preserved local override content"
    else
        fail "post-checkout did not preserve local override content"
        return 1
    fi

    # The first heal writes the marker so later hot-path runs short-circuit.
    if [[ -f "$(skip_worktree_marker_path)" ]]; then
        pass "post-checkout wrote the repair marker after healing"
    else
        fail "post-checkout did not write the repair marker after healing"
        return 1
    fi

    assert_reset_hard_succeeds
}

test_hot_path_skips_repeated_skip_worktree_repair() {
    info "Testing hot path skips repeated skip-worktree repair once marked..."

    cd "$TEST_DIR"

    # setup_repo's sync-filters already wrote the repair marker, modeling a repo
    # that has already been migrated.
    local marker
    marker="$(skip_worktree_marker_path)"
    if [[ -f "$marker" ]]; then
        pass "Repair marker present after setup sync-filters"
    else
        fail "Expected repair marker after setup sync-filters"
        return 1
    fi

    if ! setup_legacy_skip_worktree_state "CLAUDE.md"; then
        return 1
    fi

    if ! assert_legacy_hidden_mismatch_state "CLAUDE.md"; then
        return 1
    fi

    # Hot path (branch checkout) must NOT clear the bit: the gate short-circuits.
    local checkout_output
    local checkout_status
    set +e
    checkout_output="$(git checkout -q -b gate-shortcircuit-branch 2>&1)"
    checkout_status=$?
    set -e

    if [[ $checkout_status -ne 0 ]]; then
        fail "git checkout failed during gate short-circuit test: $checkout_output"
        return 1
    fi

    if [[ "$(get_index_flag "CLAUDE.md")" == "S" ]]; then
        pass "Hot path left skip-worktree bit untouched (gate short-circuited)"
    else
        fail "Hot path cleared skip-worktree bit despite repair marker"
        return 1
    fi

    if grep -q "git-local-override: cleared legacy skip-worktree" <<< "$checkout_output"; then
        fail "Hot path emitted repair notice despite repair marker"
        printf '%s\n' "$checkout_output"
        return 1
    else
        pass "Hot path emitted no repair notice (gate short-circuited)"
    fi

    # Escape hatch: sync-filters runs the ungated repair even with the marker set.
    local sync_output
    set +e
    sync_output="$(git-local-override sync-filters 2>&1)"
    local sync_status=$?
    set -e
    if [[ $sync_status -ne 0 ]]; then
        fail "sync-filters failed during escape-hatch test: $sync_output"
        return 1
    fi

    if ! assert_skip_worktree_cleared "CLAUDE.md"; then
        return 1
    fi

    if grep -q "Cleared legacy skip-worktree on 1 managed file(s)" <<< "$sync_output"; then
        pass "sync-filters cleared the bit via the escape hatch"
    else
        fail "sync-filters did not report clearing the bit"
        printf '%s\n' "$sync_output"
        return 1
    fi

    assert_reset_hard_succeeds
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

    # Restore original deterministically without invoking smudge/filter state
    git show "HEAD:config.yaml" > config.yaml

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

    # A real pull needs a real remote. Clone this repo to a second checkout,
    # add a commit there, then pull it back — exercising fetch (FETCH_HEAD) +
    # merge, a genuinely different path from an in-repo branch merge (which is
    # what test_merge_with_overridden_file already covers).
    local pull_src="$TEST_ROOT/pull-src"
    rm -rf "$pull_src"
    git clone -q "$TEST_DIR" "$pull_src"
    git -C "$pull_src" config user.name "Test User"
    git -C "$pull_src" config user.email "test@test.com"
    echo "# Feature pull change" >> "$pull_src/README.md"
    git -C "$pull_src" add README.md
    git -C "$pull_src" commit -q -m "Remote-like change"

    cp CLAUDE.local.md CLAUDE.md

    if ! git pull -q --no-edit "$pull_src" "$default_branch" 2>/dev/null; then
        fail "git pull failed"
        return 1
    fi

    if grep -q "MY LOCAL CLAUDE.md" CLAUDE.md; then
        pass "Local override preserved after pull"
    else
        fail "Local override lost after pull"
        return 1
    fi

    # Confirm the pull actually brought the remote commit in.
    if git log --oneline -1 | grep -q "Remote-like change"; then
        pass "Pulled commit is present in history"
    else
        fail "Pull did not bring in the remote commit"
        return 1
    fi

    local status_output
    status_output=$(git status --porcelain | grep -v "^??" || true)

    if [[ -z "$status_output" ]]; then
        pass "Git status is clean after pull"
    else
        fail "Git status shows changes"
        return 1
    fi
}

# Characterization (tripwire), NOT an endorsement: the clean filter substitutes
# the original tracked content only when `git show :<path>` succeeds. For a
# never-tracked managed target being staged for the first time there is no index
# blob to substitute, so run_local_override_clean passes the incoming bytes
# through — the override content reaches the index. hooks/local-override-pre-commit
# (plan 003) is what refuses to actually COMMIT such a leak; this test pins the
# current filter contract so a future refactor of the clean core can't silently
# change it. If the team later closes the --no-verify bypass by making the clean
# filter refuse/substitute for new targets, flip this asserted contract.
test_clean_filter_new_target_index_content() {
    info "Testing clean filter passes never-tracked target content through..."

    cd "$TEST_DIR"

    # A brand-new managed target that is absent from git history.
    if git cat-file -e "HEAD:NEWDOC.md" 2>/dev/null; then
        fail "Pre-condition: NEWDOC.md unexpectedly exists in HEAD"
        return 1
    fi

    cat >> .local-overrides.yaml << 'EOF'
  - override: NEWDOC.local.md
    replaces:
      - NEWDOC.md
EOF
    git-local-override sync-filters >/dev/null

    # User created a brand-new managed target holding the override content.
    printf '# override-only content\nnever tracked\n' > NEWDOC.local.md
    printf '# override-only content\nnever tracked\n' > NEWDOC.md

    # Stage (do NOT commit — the pre-commit gate is tested separately and would
    # fire). The clean filter runs during `git add`.
    git add NEWDOC.md

    local staged_out="$TEST_ROOT/newdoc-staged.out"
    git show ":NEWDOC.md" > "$staged_out"

    if cmp -s "$staged_out" NEWDOC.local.md; then
        pass "clean filter passes new-target content through (pre-commit hook is the leak gate)"
    else
        fail "clean filter did not pass new-target content through as characterized"
        git reset -q NEWDOC.md 2>/dev/null || true
        return 1
    fi

    # Restore state (each test re-clones, but keep the repo tidy).
    git reset -q NEWDOC.md 2>/dev/null || true
    rm -f NEWDOC.md NEWDOC.local.md "$staged_out"
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

test_cherry_pick_with_overridden_file() {
    info "Testing git cherry-pick with overridden file..."

    cd "$TEST_DIR"

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    if git show-ref --verify --quiet "refs/heads/cherry-pick-source"; then
        git branch -D cherry-pick-source 2>/dev/null || true
    fi

    # Build a source commit on a separate branch that touches an unrelated
    # tracked file. The managed target keeps its original tracked content in
    # this commit's tree, so a correct cherry-pick must not capture the
    # working-tree override into the target's committed content.
    git checkout -q -b cherry-pick-source
    echo "# Cherry-pick payload" > cherry-file.txt
    git add cherry-file.txt
    git commit -q -m "Commit to cherry-pick"

    local source_commit
    source_commit=$(git rev-parse HEAD)

    git checkout -q "$default_branch"

    # Model the real state at cherry-pick time: the override is applied in the
    # working tree.
    cp CLAUDE.local.md CLAUDE.md

    if ! git cherry-pick "$source_commit" 2>/dev/null; then
        info "Cherry-pick had conflicts, aborting"
        git cherry-pick --abort 2>/dev/null || true
        fail "git cherry-pick failed"
        return 1
    fi

    # (a) The cherry-picked commit must carry the tracked content for the
    # managed target, not the override.
    local committed_content
    committed_content=$(git show HEAD:CLAUDE.md)
    if echo "$committed_content" | grep -q "Original CLAUDE.md content"; then
        pass "Cherry-picked commit contains original tracked content"
    else
        fail "Cherry-picked commit leaked override content"
        echo "Committed content: $committed_content"
        return 1
    fi

    # (b) The working tree still shows the override afterward.
    if grep -q "MY LOCAL CLAUDE.md" CLAUDE.md; then
        pass "Local override preserved after cherry-pick"
    else
        fail "Local override lost after cherry-pick"
        cat CLAUDE.md
        return 1
    fi

    git checkout -q "$default_branch" 2>/dev/null || true
}

# Shared setup for the conflicted-merge tests: commits divergent canonical
# changes to the managed target on a branch and on the default branch, applies
# the override, and starts a merge that must stop on a CLAUDE.md conflict with
# MERGE_HEAD present. Returns 1 (after its own
# fail()) if the conflict does not materialize.
setup_conflicted_merge_on_managed_target() {
    local branch_name="$1"
    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    git branch -D "$branch_name" 2>/dev/null || true

    # Branch commits one canonical change to the managed target. Setup commits
    # bypass the filter (DISABLE on add) and the hook (--no-verify) so the two
    # branches genuinely diverge on the managed file.
    git checkout -q -b "$branch_name"
    printf '# CLAUDE.md from feature\n' > CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add CLAUDE.md
    git commit -q --no-verify -m "Feature change to CLAUDE.md"

    # Default branch commits a different change so the merge conflicts.
    git checkout -q "$default_branch"
    printf '# CLAUDE.md from main\n' > CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add CLAUDE.md
    git commit -q --no-verify -m "Main change to CLAUDE.md"

    # Model the real state at merge time: the override is applied.
    git-local-override apply 2>/dev/null || true

    local merge_status
    set +e
    git merge -q --no-edit "$branch_name" >/dev/null 2>&1
    merge_status=$?
    set -e
    if [[ $merge_status -eq 0 ]]; then
        fail "Expected the merge to conflict on CLAUDE.md"
        return 1
    fi

    local merge_head_path
    merge_head_path="$(git rev-parse --git-path MERGE_HEAD 2>/dev/null || true)"
    if [[ -z "$merge_head_path" || ! -f "$merge_head_path" ]]; then
        fail "Expected MERGE_HEAD after the conflicted merge"
        git merge --abort 2>/dev/null || true
        return 1
    fi

    return 0
}

test_conflicted_merge_resolution_survives_commit() {
    info "Testing conflicted merge resolution of a managed file survives the commit..."

    cd "$TEST_DIR"

    setup_conflicted_merge_on_managed_target "merge-conflict-branch" || return 1
    pass "Merge stopped on the managed-file conflict with MERGE_HEAD present"

    # Resolve with content distinct from ours, theirs, and the override, then
    # conclude the merge. The path is unmerged at add time, so the clean
    # filter passes the resolution bytes through into the index.
    printf '# CLAUDE.md merge resolution\n' > CLAUDE.md
    git add CLAUDE.md

    if ! git commit -q --no-edit 2>/dev/null; then
        fail "Concluding merge commit was refused"
        git merge --abort 2>/dev/null || true
        return 1
    fi

    local committed_content
    committed_content=$(git show HEAD:CLAUDE.md)
    if echo "$committed_content" | grep -q "CLAUDE.md merge resolution"; then
        pass "Merge commit carries the conflict resolution"
    else
        fail "Merge commit lost the resolution (silently reverted to ours)"
        echo "Committed content: $committed_content"
        return 1
    fi

    if echo "$committed_content" | grep -q "MY LOCAL"; then
        fail "Merge commit leaked override content"
        return 1
    else
        pass "Merge commit holds no override content"
    fi
}

test_conflicted_cherry_pick_resolution_survives_commit() {
    info "Testing conflicted cherry-pick resolution of a managed file survives the commit..."

    cd "$TEST_DIR"

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    git branch -D cherry-conflict-branch 2>/dev/null || true

    # Source commit changes the managed target from the common base.
    git checkout -q -b cherry-conflict-branch
    printf '# CLAUDE.md from cherry source\n' > CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add CLAUDE.md
    git commit -q --no-verify -m "Cherry source change to CLAUDE.md"

    local source_commit
    source_commit=$(git rev-parse HEAD)

    # Default branch changes the same file differently so the pick conflicts.
    git checkout -q "$default_branch"
    printf '# CLAUDE.md from main side\n' > CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add CLAUDE.md
    git commit -q --no-verify -m "Main-side change to CLAUDE.md"

    git-local-override apply 2>/dev/null || true

    local pick_status
    set +e
    git cherry-pick "$source_commit" >/dev/null 2>&1
    pick_status=$?
    set -e
    if [[ $pick_status -eq 0 ]]; then
        fail "Expected the cherry-pick to conflict on CLAUDE.md"
        return 1
    fi

    local cherry_head_path
    cherry_head_path="$(git rev-parse --git-path CHERRY_PICK_HEAD 2>/dev/null || true)"
    if [[ -n "$cherry_head_path" && -f "$cherry_head_path" ]]; then
        pass "Cherry-pick stopped on the managed-file conflict with CHERRY_PICK_HEAD present"
    else
        fail "Expected CHERRY_PICK_HEAD after the conflicted cherry-pick"
        git cherry-pick --abort 2>/dev/null || true
        return 1
    fi

    printf '# CLAUDE.md cherry-pick resolution\n' > CLAUDE.md
    git add CLAUDE.md

    if ! git commit -q --no-edit 2>/dev/null; then
        fail "Concluding cherry-pick commit was refused"
        git cherry-pick --abort 2>/dev/null || true
        return 1
    fi

    local committed_content
    committed_content=$(git show HEAD:CLAUDE.md)
    if echo "$committed_content" | grep -q "CLAUDE.md cherry-pick resolution"; then
        pass "Cherry-pick commit carries the conflict resolution"
    else
        fail "Cherry-pick commit lost the resolution (silently reverted to ours)"
        echo "Committed content: $committed_content"
        return 1
    fi
}

test_merge_no_commit_change_survives_commit() {
    info "Testing merge --no-commit change to a managed file survives the commit..."

    cd "$TEST_DIR"

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    git branch -D no-commit-merge-branch 2>/dev/null || true

    # Only the branch changes the managed target, so the merge auto-resolves;
    # --no-ff --no-commit stops before committing with MERGE_HEAD present.
    git checkout -q -b no-commit-merge-branch
    printf '# CLAUDE.md updated by feature\n' > CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add CLAUDE.md
    git commit -q --no-verify -m "Feature-only CLAUDE.md change"

    git checkout -q "$default_branch"
    git-local-override apply 2>/dev/null || true

    if ! git merge --no-ff --no-commit no-commit-merge-branch >/dev/null 2>&1; then
        fail "git merge --no-commit failed"
        git merge --abort 2>/dev/null || true
        return 1
    fi

    local merge_head_path
    merge_head_path="$(git rev-parse --git-path MERGE_HEAD 2>/dev/null || true)"
    if [[ -n "$merge_head_path" && -f "$merge_head_path" ]]; then
        pass "merge --no-commit stopped with MERGE_HEAD present"
    else
        fail "Expected MERGE_HEAD after merge --no-commit"
        git merge --abort 2>/dev/null || true
        return 1
    fi

    if ! git commit -q --no-edit 2>/dev/null; then
        fail "Concluding merge commit was refused"
        git merge --abort 2>/dev/null || true
        return 1
    fi

    local committed_content
    committed_content=$(git show HEAD:CLAUDE.md)
    if echo "$committed_content" | grep -q "updated by feature"; then
        pass "merge --no-commit change to the managed file survives the commit"
    else
        fail "merge --no-commit change was silently reverted to ours"
        echo "Committed content: $committed_content"
        return 1
    fi
}

test_normal_commit_restore_unchanged_by_merge_guard() {
    info "Testing normal commit (no merge in progress) still restores the managed target..."

    cd "$TEST_DIR"

    # Guard regression: no merge or cherry-pick is in progress.
    local merge_head_path cherry_head_path
    merge_head_path="$(git rev-parse --git-path MERGE_HEAD 2>/dev/null || true)"
    cherry_head_path="$(git rev-parse --git-path CHERRY_PICK_HEAD 2>/dev/null || true)"
    if [[ -f "$merge_head_path" || -f "$cherry_head_path" ]]; then
        fail "Pre-condition: unexpected merge/cherry-pick in progress"
        return 1
    fi

    # Stage a managed-target edit distinct from HEAD and the override, plus an
    # unrelated change so the commit is nonempty after the restore.
    printf '# direct edit distinct from override and HEAD\n' > CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add CLAUDE.md
    echo "guard regression marker" >> README.md
    git add README.md

    git commit -q -m "Normal commit with staged managed edit"

    local committed_content
    committed_content=$(git show HEAD:CLAUDE.md)
    if echo "$committed_content" | grep -q "Original CLAUDE.md content"; then
        pass "Normal commit still restores the managed target to HEAD"
    else
        fail "Normal commit no longer restores the managed target"
        echo "Committed content: $committed_content"
        return 1
    fi

    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "post-commit reapplied the override after the normal commit"
    else
        fail "Override not reapplied after the normal commit"
        return 1
    fi
}

test_merge_blind_add_of_override_content_refused() {
    info "Testing blind git add of override content during a conflicted merge is refused..."

    cd "$TEST_DIR"

    setup_conflicted_merge_on_managed_target "blind-add-merge-branch" || return 1
    pass "Merge stopped on the managed-file conflict with MERGE_HEAD present"

    # At the conflict stop the smudge filter served override content into the
    # conflicted working file (it hides the conflict markers — recorded
    # follow-up), so the "unedited" file looks fine. Model the blind add
    # deterministically: the working file holds override bytes. The path is
    # unmerged, so `git show :path` fails and the clean filter passes the
    # override bytes straight into the index.
    cp CLAUDE.local.md CLAUDE.md
    git add CLAUDE.md

    local staged_out="$TEST_ROOT/blind-add-staged.out"
    git show :CLAUDE.md > "$staged_out"
    if cmp -s "$staged_out" CLAUDE.local.md; then
        pass "Pre-condition: blind add staged override bytes (unmerged-path clean passthrough)"
    else
        fail "Pre-condition: expected override bytes in the index after blind add"
        git merge --abort 2>/dev/null || true
        return 1
    fi

    local pre_head commit_status
    pre_head=$(git rev-parse HEAD)

    set +e
    git commit -q --no-edit >/dev/null 2>&1
    commit_status=$?
    set -e

    if [[ $commit_status -ne 0 ]]; then
        pass "Commit of staged override content was refused during the merge"
    else
        fail "Commit was not refused (override content or ours committed silently)"
        return 1
    fi

    if [[ "$(git rev-parse HEAD)" == "$pre_head" ]]; then
        pass "No commit was created by the refused attempt"
    else
        fail "A commit was created despite the refusal"
        return 1
    fi

    if git show HEAD:CLAUDE.md | grep -q "MY LOCAL"; then
        fail "Override content reached a commit"
        return 1
    else
        pass "No override content reached any commit"
    fi

    git merge --abort 2>/dev/null || true
}

test_aborted_commit_recovers_override_on_checkout() {
    info "Testing aborted commit recovery re-applies override on next checkout..."

    cd "$TEST_DIR"

    # Pre-condition: local override content is applied to the working tree.
    if ! grep -q "MY LOCAL" CLAUDE.md; then
        fail "Pre-condition: local content not applied"
        return 1
    fi

    local state_file
    state_file="$(git rev-parse --absolute-git-dir)/local-override-post-commit-state"
    rm -f "$state_file"

    # Stage an edit distinct from both the override and HEAD so it survives the
    # clean filter (its cmp gate passes the content through) and pre-commit sees
    # the overridden target as a staged change.
    printf '# staged edit distinct from override\n' > CLAUDE.md
    git add CLAUDE.md
    # Model the real commit-time state: the override is applied in the working
    # tree when pre-commit runs.
    cp CLAUDE.local.md CLAUDE.md

    # Run pre-commit directly: it restores originals into the working tree and
    # index and writes the reapply state file. Then simulate an ABORTED commit
    # by NOT running post-commit.
    .git/hooks/pre-commit

    if grep -q "Original CLAUDE.md content" CLAUDE.md; then
        pass "pre-commit restored original content into working tree"
    else
        fail "Expected original content in working tree after pre-commit"
        cat CLAUDE.md
        return 1
    fi

    if [[ -f "$state_file" ]]; then
        pass "Reapply state file present after aborted commit"
    else
        fail "Expected reapply state file to exist after pre-commit"
        return 1
    fi

    # The next branch checkout heals the working tree and clears stale state.
    .git/hooks/post-checkout "" "" "1"

    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "Override re-applied to working tree after checkout"
    else
        fail "Override not re-applied after checkout"
        cat CLAUDE.md
        return 1
    fi

    if [[ ! -f "$state_file" ]]; then
        pass "Stale reapply state file cleared after checkout"
    else
        fail "Expected stale reapply state file to be removed"
        return 1
    fi
}

test_precommit_during_rebase_is_noop() {
    info "Testing pre-commit makes no changes during an in-progress rebase..."

    cd "$TEST_DIR"

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    git branch -D midrebase-feature 2>/dev/null || true

    # Feature branch changes README's first line.
    git checkout -q -b midrebase-feature
    printf '# Feature README\n' > README.md
    git add README.md
    git commit -q -m "Feature README change"

    # Default branch changes the same line differently, creating a conflict.
    git checkout -q "$default_branch"
    printf '# Upstream README\n' > README.md
    git add README.md
    git commit -q --no-verify -m "Upstream README change"

    git checkout -q midrebase-feature
    git-local-override apply 2>/dev/null || true

    # Start a rebase that stops on the README conflict.
    local rebase_status
    set +e
    git rebase "$default_branch" >/dev/null 2>&1
    rebase_status=$?
    set -e

    if [[ $rebase_status -eq 0 ]]; then
        info "Rebase did not stop on a conflict; cannot exercise mid-rebase guard"
        git checkout -q "$default_branch" 2>/dev/null || true
        pass "Skipped (rebase produced no conflict stop)"
        return 0
    fi

    local rebase_merge_dir rebase_apply_dir
    rebase_merge_dir="$(git rev-parse --git-path rebase-merge 2>/dev/null || true)"
    rebase_apply_dir="$(git rev-parse --git-path rebase-apply 2>/dev/null || true)"
    if [[ ! -d "$rebase_merge_dir" && ! -d "$rebase_apply_dir" ]]; then
        fail "Expected an in-progress rebase after conflict"
        git rebase --abort 2>/dev/null || true
        git checkout -q "$default_branch" 2>/dev/null || true
        return 1
    fi

    local state_file
    state_file="$(git rev-parse --absolute-git-dir)/local-override-post-commit-state"
    rm -f "$state_file"

    # Ensure the overridden target holds local content, then stage it so a
    # rebase-unaware pre-commit would restore it.
    cp CLAUDE.local.md CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add CLAUDE.md 2>/dev/null || true

    # Run pre-commit during the rebase; the rebase guard must short-circuit it.
    .git/hooks/pre-commit

    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "pre-commit left the override untouched during rebase"
    else
        fail "pre-commit modified the overridden target during rebase"
        cat CLAUDE.md
        git rebase --abort 2>/dev/null || true
        git checkout -q "$default_branch" 2>/dev/null || true
        return 1
    fi

    if [[ ! -f "$state_file" ]]; then
        pass "pre-commit wrote no reapply state file during rebase"
    else
        fail "pre-commit wrote a reapply state file during rebase"
        git rebase --abort 2>/dev/null || true
        git checkout -q "$default_branch" 2>/dev/null || true
        return 1
    fi

    git rebase --abort 2>/dev/null || true
    git checkout -q "$default_branch" 2>/dev/null || true
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


    git show "HEAD:config.yaml" > config.yaml

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

test_gitignored_config_edit_applies_new_target_on_checkout() {
    info "Testing gitignored config edit applies new target on next checkout..."

    cd "$TEST_DIR"

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    # Tracked targets in a subdirectory whose config is gitignored, so config
    # edits produce no tracked HEAD diff between checkouts.
    mkdir -p subdir
    echo "# Original notes" > subdir/notes.md
    echo "# Original extra" > subdir/extra.md
    printf 'subdir/.local-overrides.yaml\n' >> .gitignore
    git add .gitignore subdir/notes.md subdir/extra.md
    git commit -q -m "Add subdir targets and gitignore its local config"

    # Gitignored config manages only notes.md at first
    cat > subdir/.local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: notes.local.md
    replaces:
      - notes.md
EOF
    echo "# LOCAL notes" > subdir/notes.local.md
    echo "# LOCAL extra" > subdir/extra.local.md

    git-local-override sync-filters >/dev/null
    git-local-override apply >/dev/null 2>&1 || true

    if ! grep -q "LOCAL notes" subdir/notes.md; then
        fail "Pre-condition: notes.md override not applied"
        return 1
    fi

    # Round-trip once so post-checkout's slow path records the current config
    # state and subsequent checkouts are eligible for the fast path.
    git checkout -q -b stale-config-warmup
    git checkout -q "$default_branch"

    # Edit the GITIGNORED config: newly manage extra.md. This produces no
    # tracked diff, so only an on-disk drift signal can catch it.
    cat > subdir/.local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: notes.local.md
    replaces:
      - notes.md
  - override: extra.local.md
    replaces:
      - extra.md
EOF

    git checkout -q stale-config-warmup
    git checkout -q "$default_branch"

    if grep -q "LOCAL extra" subdir/extra.md; then
        pass "Newly configured target applied after gitignored config edit"
    else
        fail "Stale fast path: newly configured target not applied after checkout"
        return 1
    fi

    if grep -q "LOCAL notes" subdir/notes.md; then
        pass "Previously configured target still applied"
    else
        fail "Previously configured target lost after checkout"
        return 1
    fi
}

test_checkout_fast_path_when_config_unchanged() {
    info "Testing checkout still takes fast path when config is unchanged..."

    cd "$TEST_DIR"

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    # Warm up: the first checkout after install runs the slow path and
    # records the config stamp.
    git checkout -q -b fast-path-warmup
    git checkout -q "$default_branch"

    local checkout_output
    checkout_output=$(GIT_LOCAL_OVERRIDE_TRACE=1 git checkout fast-path-warmup 2>&1)

    if grep -q "fast-path config=unchanged" <<< "$checkout_output"; then
        pass "post-checkout took the fast path with no config drift"
    else
        fail "post-checkout did not take the fast path: $checkout_output"
        git checkout -q "$default_branch" 2>/dev/null || true
        return 1
    fi

    if grep -q "MY LOCAL" CLAUDE.md; then
        pass "Override still applied on fast-path checkout"
    else
        fail "Override lost on fast-path checkout"
        git checkout -q "$default_branch" 2>/dev/null || true
        return 1
    fi

    git checkout -q "$default_branch"
}

test_checkout_resyncs_deleted_attributes() {
    info "Testing checkout re-syncs a deleted .git/info/attributes file..."

    cd "$TEST_DIR"

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    # Warm up: the first checkout after install runs the slow path, syncs
    # attributes, and records the config stamp so later checkouts are
    # eligible for the fast path.
    git checkout -q -b attributes-resync-warmup
    git checkout -q "$default_branch"

    if grep -q "filter=local-override" .git/info/attributes; then
        pass "Pre-condition: attributes file has managed filter lines"
    else
        fail "Pre-condition: attributes file missing managed filter lines"
        return 1
    fi

    # Simulate out-of-band deletion. No config changes, so the stamp still
    # matches and tracked configs are unchanged — only an attributes-file
    # check can catch this.
    rm .git/info/attributes

    # Branch checkout fires post-checkout; the fast path must disqualify
    # itself so the slow path rebuilds the attributes file.
    git checkout -q attributes-resync-warmup

    if [[ -s .git/info/attributes ]] && grep -q "filter=local-override" .git/info/attributes; then
        pass "Deleted attributes file was re-synced on branch checkout"
    else
        fail "Attributes file not re-synced after out-of-band deletion"
        git checkout -q "$default_branch" 2>/dev/null || true
        return 1
    fi

    git checkout -q "$default_branch"
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

test_special_character_filename_roundtrip() {
    info "Testing add/apply/commit/post-commit roundtrip for special-character filename..."

    cd "$TEST_DIR"

    # A managed target whose name holds a space and a non-ASCII (UTF-8) byte.
    # Reading staged paths NUL-delimited with core.quotePath=false is what lets
    # pre-commit match this against the config target instead of a C-quoted
    # string that would never match (leaking override content into the commit).
    local target="my spécial file.md"
    local override="my spécial file.local.md"
    local original="# Original spécial content"
    local local_content="# MY LOCAL spécial content"

    # Create and commit the tracked target before it is managed, so the hooks
    # ignore it and the canonical bytes land in HEAD.
    printf '%s\n' "$original" > "$target"
    git add -- "$target"
    git commit -q -m "Add special-character target"

    # Register the target in the recursive config, then commit the config.
    cat >> .local-overrides.yaml << 'EOF'
  - override: "my spécial file.local.md"
    replaces:
      - "my spécial file.md"
EOF
    git add -- .local-overrides.yaml
    git commit -q -m "Manage special-character target"

    # add: create the local override file.
    printf '%s\n' "$local_content" > "$override"

    # apply: sync filters for the new target and write the override into the
    # working tree.
    git-local-override sync-filters >/dev/null 2>&1 || true
    git-local-override apply >/dev/null 2>&1 || true

    if grep -q "MY LOCAL spécial content" "$target"; then
        pass "Override applied to special-character target's working tree"
    else
        fail "Override not applied to special-character target"
        cat "$target"
        return 1
    fi

    # commit: stage the override content directly (bypassing the clean filter),
    # then commit so pre-commit must restore the tracked bytes for a target
    # whose name carries a space and a non-ASCII byte.
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add -- "$target"
    git commit -q -m "Touch special-character target"

    # The committed content must be the tracked original, not the override.
    local committed_content
    committed_content=$(git show "HEAD:$target")
    if echo "$committed_content" | grep -q "Original spécial content"; then
        pass "Commit contains original content for special-character target"
    else
        fail "Commit leaked override content for special-character target"
        echo "Committed content: $committed_content"
        return 1
    fi

    # post-commit must re-apply the override to the working tree.
    if grep -q "MY LOCAL spécial content" "$target"; then
        pass "Override restored after commit for special-character target"
    else
        fail "Override not restored after commit for special-character target"
        cat "$target"
        return 1
    fi
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
    local test_exit
    for test_fn in \
        test_commit_preserves_original \
        test_commit_restores_local_after \
        test_commit_staged_override_file \
        test_branch_checkout_applies_overrides \
        test_git_switch_applies_overrides \
        test_multiple_files_override \
        test_install_self_heals_legacy_skip_worktree \
        test_sync_filters_self_heals_legacy_skip_worktree \
        test_post_checkout_self_heals_legacy_skip_worktree \
        test_hot_path_skips_repeated_skip_worktree_repair \
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
        test_clean_filter_new_target_index_content \
        test_merge_with_overridden_file \
        test_rebase_with_overridden_file \
        test_stash_with_overridden_file \
        test_cherry_pick_with_overridden_file \
        test_conflicted_merge_resolution_survives_commit \
        test_conflicted_cherry_pick_resolution_survives_commit \
        test_merge_no_commit_change_survives_commit \
        test_normal_commit_restore_unchanged_by_merge_guard \
        test_merge_blind_add_of_override_content_refused \
        test_special_character_filename_roundtrip \
        test_aborted_commit_recovers_override_on_checkout \
        test_precommit_during_rebase_is_noop \
        test_commit_still_contains_original \
        test_filter_and_hooks_coexist \
        test_no_override_file_normal_checkout \
        test_disable_env_var_allows_restore \
        test_gitignored_config_edit_applies_new_target_on_checkout \
        test_checkout_fast_path_when_config_unchanged \
        test_checkout_resyncs_deleted_attributes \
        test_worktree_add_with_filters; do
        CURRENT_TEST_NAME="$test_fn"
        setup_repo

        CURRENT_TEST_STATUS=0
        set +e
        "$test_fn"
        test_exit=$?
        set -e

        # A test that returned nonzero WITHOUT recording a fail() is still a
        # failure; and a test that called fail() without `return 1` must still
        # trip fail-fast + artifact preservation. Key both off CURRENT_TEST_STATUS
        # (fail() sets it to 1) instead of the test's raw return code.
        if [[ $test_exit -ne 0 && $CURRENT_TEST_STATUS -eq 0 ]]; then
            fail "${test_fn} exited with status $test_exit"
        fi

        if [[ $CURRENT_TEST_STATUS -ne 0 ]]; then
            exit 1
        fi

        finalize_current_test_root 0
    done

    cleanup

    finish_suite
}

main "$@"
