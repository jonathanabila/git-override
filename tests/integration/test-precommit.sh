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

# Colors, counters, pass/fail/info, and finish_suite come from test-lib.sh.
# skip() is specific to this suite (pre-commit may be unavailable).
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

    # Self-contained override content, applied to the managed target.
    echo "# MY LOCAL CLAUDE.md - pre-commit run test" > CLAUDE.local.md
    cp CLAUDE.local.md CLAUDE.md

    # Stage both the incidental file and the managed target — the grouped
    # restore only fires for staged targets.
    echo "test" >> README.md
    git add README.md CLAUDE.md

    # Run the hook. pre-commit's framework marks a hook that modifies files as
    # "Failed" by design, so the exit code is intentionally NOT asserted; the
    # restore *effect* is what we check.
    pre-commit run local-override-pre-commit --hook-stage pre-commit || true

    # The pre-commit hook restores the original tracked content into the index.
    if git show :CLAUDE.md 2>/dev/null | grep -q "Original CLAUDE.md content"; then
        pass "pre-commit hook restored original content to the index"
    else
        fail "pre-commit hook did not restore original content to the index"
        git show :CLAUDE.md 2>/dev/null || true
        return 1
    fi

    # It restores the working tree too (no commit ran, so post-commit has not
    # re-applied the override).
    if grep -q "Original CLAUDE.md content" CLAUDE.md; then
        pass "pre-commit hook restored original content in the working tree"
    else
        fail "pre-commit hook did not restore original content in the working tree"
        cat CLAUDE.md
        return 1
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

    # setup_repo re-clones a fresh seed repo per test, so the post-checkout
    # hook is not wired yet — install it here so the checkout actually fires it.
    pre-commit install \
        --hook-type pre-commit \
        --hook-type post-commit \
        --hook-type post-checkout \
        --hook-type pre-rebase 2>/dev/null || true

    # Fresh clone => clean tracked tree. Create the override file only; do NOT
    # pre-dirty the target. If the target is modified at checkout time,
    # pre-commit stashes the change, runs the hook, then rolls back the hook's
    # write on a stash conflict — which would defeat this assertion. A clean
    # branch switch (the realistic case) applies the override with no stash.
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

    # The post-checkout hook must have applied the override on branch checkout.
    if grep -q "MY LOCAL CLAUDE.md - checkout test" CLAUDE.md; then
        pass "post-checkout hook applied the override on branch checkout"
    else
        fail "post-checkout hook did not apply the override on branch checkout"
        cat CLAUDE.md 2>/dev/null || true
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

    # Self-contained override content, then apply it to the managed target.
    echo "# MY LOCAL for other-hooks test" > CLAUDE.local.md
    echo "# MY LOCAL for other-hooks test" > CLAUDE.md

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

    # The pre-commit hook restored the original tracked content into the commit,
    # even alongside the check-readme hook.
    if git show HEAD:CLAUDE.md | grep -q "Original CLAUDE.md content"; then
        pass "Committed content is the original, not the override (with other hooks)"
    else
        fail "Override content leaked into the commit (with other hooks)"
        git show HEAD:CLAUDE.md
        return 1
    fi

    # The post-commit hook re-applied the override to the working tree.
    if grep -q "MY LOCAL for other-hooks test" CLAUDE.md; then
        pass "post-commit re-applied the override to the working tree (with other hooks)"
    else
        fail "post-commit did not re-apply the override (with other hooks)"
        cat CLAUDE.md
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

test_precommit_new_target_leak_blocked() {
    info "Testing new managed target holding override content is blocked..."

    cd "$TEST_DIR"

    pre-commit install \
        --hook-type pre-commit \
        --hook-type post-commit 2>/dev/null || true

    # Add a config entry for a target that does NOT exist in HEAD.
    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
  - override: NEWFILE.local.md
    replaces:
      - NEWFILE.md
EOF
    git add .local-overrides.yaml
    git commit -q -m "Add new managed target to config"

    # Create the override and apply it so the target holds override content.
    echo "# SECRET LOCAL NEWFILE" > NEWFILE.local.md
    echo "# SECRET LOCAL NEWFILE" > NEWFILE.md

    git add NEWFILE.md

    if git commit -m "Introduce new managed target"; then
        fail "Commit of new managed target with override content was NOT blocked (leak)"
        return 1
    fi
    pass "Commit of new managed target with override content was blocked"

    # HEAD must not have gained the target at all.
    if git cat-file -e "HEAD:NEWFILE.md" 2>/dev/null; then
        fail "HEAD gained NEWFILE.md despite the block"
        return 1
    fi
    pass "HEAD did not gain the new target"

    # Working tree must still hold the override content.
    if grep -q "SECRET LOCAL NEWFILE" NEWFILE.md; then
        pass "Working tree still holds the override content"
    else
        fail "Working tree lost the override content"
        cat NEWFILE.md
        return 1
    fi
}

test_precommit_new_target_canonical_commits() {
    info "Testing new managed target with genuine canonical content commits..."

    cd "$TEST_DIR"

    pre-commit install \
        --hook-type pre-commit \
        --hook-type post-commit 2>/dev/null || true

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
  - override: NEWFILE.local.md
    replaces:
      - NEWFILE.md
EOF
    git add .local-overrides.yaml
    git commit -q -m "Add new managed target to config"

    # Override exists but the staged target holds real canonical content
    # (NOT the override), so the block must not trigger.
    echo "# SECRET LOCAL NEWFILE" > NEWFILE.local.md
    echo "# REAL CANONICAL NEWFILE" > NEWFILE.md

    git add NEWFILE.md

    if git commit -m "Introduce new managed target with canonical content"; then
        pass "Commit of new target with canonical content succeeded"
    else
        fail "Commit of new target with canonical content was wrongly blocked"
        return 1
    fi

    # HEAD must hold the canonical content, not the override.
    local committed
    committed=$(git show "HEAD:NEWFILE.md")
    if echo "$committed" | grep -q "REAL CANONICAL NEWFILE"; then
        pass "Committed content is the genuine canonical content"
    else
        fail "Committed content was not the canonical content"
        echo "Committed: $committed"
        return 1
    fi
}

# Plan 050: the pre-commit-framework install path copies only the four hook
# entry points and never configures the filter driver, leaving the armed
# attributes pointing at a driver git treats as identity. The hooks must
# self-heal: copy the filter machinery next to themselves into .git/hooks and
# configure filter.local-override.* on the first run that has config to
# enforce.
test_precommit_framework_self_heals_filter_driver() {
    info "Testing framework-style install self-heals the filter driver..."

    cd "$TEST_DIR"

    pre-commit install \
        --hook-type pre-commit \
        --hook-type post-commit \
        --hook-type post-checkout \
        --hook-type pre-rebase 2>/dev/null || true

    # The framework install path must start with the driver unconfigured —
    # that is the gap being healed.
    if [[ -z "$(git config --local filter.local-override.clean 2>/dev/null || true)" ]]; then
        pass "filter driver starts unconfigured (framework install path)"
    else
        fail "filter driver unexpectedly configured before any hook ran"
        return 1
    fi

    echo "# MY LOCAL CLAUDE.md - self-heal test" > CLAUDE.local.md

    # First branch op fires post-checkout through the framework shim; the
    # tracked tree is clean, so no framework stash interferes.
    git checkout -q -b self-heal-branch 2>/dev/null || true

    # Resolve physically (pwd -P): the hook computes its paths from git's
    # physical repo root, while $TMPDIR on macOS reaches the repo through the
    # /var -> /private/var symlink.
    local common_git_dir
    common_git_dir="$(git rev-parse --git-common-dir)"
    [[ "$common_git_dir" == /* ]] || common_git_dir="$PWD/$common_git_dir"
    common_git_dir="$(cd "$common_git_dir" && pwd -P)"

    local smudge_cmd clean_cmd required_cfg
    smudge_cmd="$(git config --local filter.local-override.smudge 2>/dev/null || echo "")"
    clean_cmd="$(git config --local filter.local-override.clean 2>/dev/null || echo "")"
    required_cfg="$(git config --local filter.local-override.required 2>/dev/null || echo "")"

    if [[ "$smudge_cmd" == "$common_git_dir/hooks/local-override-filter-smudge %f" &&
          "$clean_cmd" == "$common_git_dir/hooks/local-override-filter-clean %f" &&
          "$required_cfg" == "false" ]]; then
        pass "first hook run configured the filter driver at stable .git/hooks paths"
    else
        fail "filter driver not configured after the first hook run"
        echo "smudge:   $smudge_cmd"
        echo "clean:    $clean_cmd"
        echo "required: $required_cfg"
        return 1
    fi

    # The copied machinery must be complete (the filter scripts source the
    # lib, which sources the resolver) and executable.
    if [[ -x "$common_git_dir/hooks/local-override-filter-smudge" &&
          -x "$common_git_dir/hooks/local-override-filter-clean" &&
          -f "$common_git_dir/hooks/local-override-lib.sh" &&
          -f "$common_git_dir/hooks/local-override-resolver.sh" ]]; then
        pass "filter machinery copied next to the configured driver"
    else
        fail "filter machinery missing from $common_git_dir/hooks"
        ls -la "$common_git_dir/hooks" || true
        return 1
    fi

    # End-to-end smudge: a FILE checkout (the post-checkout hook exits early
    # for those) must serve the override via the filter driver alone.
    rm -f CLAUDE.md
    git checkout -- CLAUDE.md
    if grep -q "MY LOCAL CLAUDE.md - self-heal test" CLAUDE.md; then
        pass "smudge filter serves the override end-to-end"
    else
        fail "smudge filter did not serve the override on file checkout"
        cat CLAUDE.md 2>/dev/null || true
        return 1
    fi

    # Regression (Phase A residual-staged hazard): staging the override must
    # put the ORIGINAL in the index — the clean filter runs — so no residual
    # staged override survives for a later `git commit --no-verify` to commit.
    git add CLAUDE.md
    if git show :CLAUDE.md | grep -q "Original CLAUDE.md content"; then
        pass "clean filter keeps the override out of the index (residual-staged hazard closed)"
    else
        fail "override content reached the index despite the healed clean filter"
        git show :CLAUDE.md 2>/dev/null || true
        return 1
    fi

    # A second hook run must be a silent no-op: the heal happens once.
    local second_run_output
    second_run_output="$("$PROJECT_DIR/hooks/local-override-post-checkout" "" "" "1" 2>&1 || true)"
    if [[ "$second_run_output" != *"self-heal"* ]]; then
        pass "second hook run does not re-heal (configured driver is left alone)"
    else
        fail "self-heal fired again on an already-configured driver"
        printf '%s\n' "$second_run_output"
        return 1
    fi
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
    local test_exit
    for test_fn in \
        test_precommit_install \
        test_precommit_run_pre_commit \
        test_precommit_commit_flow \
        test_precommit_checkout_flow \
        test_precommit_with_other_hooks \
        test_precommit_skip_without_config \
        test_precommit_new_target_leak_blocked \
        test_precommit_new_target_canonical_commits \
        test_precommit_framework_self_heals_filter_driver \
        test_precommit_from_remote_repo; do
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
