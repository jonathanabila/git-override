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

# The assertion harness (colors, counters, pass/fail/info, finish_suite)
# lives in test-lib.sh. This suite calls pass() once per test, so it opts
# into the stricter TESTS_PASSED == TESTS_RUN invariant.
# shellcheck disable=SC2034  # read by finish_suite in test-lib.sh
STRICT_PASS_COUNT=1

count_trace_matches() {
    local output="$1"
    local needle="$2"

    printf '%s\n' "$output" | grep -c "$needle" 2>/dev/null || true
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

test_cli_version() {
    info "Testing CLI version command..."

    local expected_version
    local output

    expected_version="$(tr -d '\r' < "$PROJECT_DIR/VERSION")"
    output="$(git-local-override version)"

    if [[ "$output" == "$expected_version" ]]; then
        pass "CLI version command works"
    else
        fail "CLI version command returned '$output'"
    fi
}

test_cli_version_flag() {
    info "Testing CLI --version flag..."

    local expected_version
    local output

    expected_version="$(tr -d '\r' < "$PROJECT_DIR/VERSION")"
    output="$(git-local-override --version)"

    if [[ "$output" == "$expected_version" ]]; then
        pass "CLI --version flag works"
    else
        fail "CLI --version flag returned '$output'"
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

test_apply_shows_progress_output() {
    info "Testing apply shows progress output..."

    cd "$TEST_REPO"
    create_config

    echo "# APPLY PROGRESS CLAUDE" > CLAUDE.local.md
    echo "# APPLY PROGRESS AGENTS" > AGENTS.local.md

    local output
    output=$(git-local-override apply 2>&1)

    if [[ "$output" == *"Applying overrides..."* ]] &&
       [[ "$output" == *"Validating config..."* ]] &&
       [[ "$output" == *"Resolving effective override map..."* ]] &&
       [[ "$output" == *"Configured targets: 3; active overrides: 2"* ]] &&
       [[ "$output" == *"Applying active overrides..."* ]] &&
       [[ "$output" == *"Applied 1/2: ./CLAUDE.md <- ./CLAUDE.local.md"* ]] &&
       [[ "$output" == *"Applied 2/2: ./AGENTS.md <- ./AGENTS.local.md"* ]] &&
       [[ "$output" == *"Syncing attributes..."* ]] &&
       [[ "$output" == *"Applied 2 override(s) in "* ]]; then
        pass "Apply command shows progress output"
    else
        fail "Apply command did not show expected progress output (output: $output)"
    fi
}

test_apply_shows_nested_paths() {
    info "Testing apply shows nested relative paths..."

    cd "$TEST_REPO"
    create_config

    echo "# APPLY PROGRESS NESTED" > backend/services/foo/AGENTS.local.md

    local output
    output=$(git-local-override apply 2>&1)

    if [[ "$output" == *"Applied 1/1: backend/services/foo/AGENTS.md <- backend/services/foo/AGENTS.local.md"* ]]; then
        pass "Apply command shows nested relative paths"
    else
        fail "Apply command did not show nested relative paths (output: $output)"
    fi
}

test_apply_reports_no_active_overrides() {
    info "Testing apply explains when no override files are active..."

    cd "$TEST_REPO"
    create_config

    local output
    output=$(git-local-override apply 2>&1)

    if [[ "$output" == *"Configured targets: 3; active overrides: 0"* ]] &&
       [[ "$output" == *"No active override files found; syncing attributes only"* ]] &&
       [[ "$output" == *"Applied 0 override(s) in "* ]]; then
        pass "Apply command explains zero active overrides"
    else
        fail "Apply command did not explain zero active overrides (output: $output)"
    fi
}

test_apply_with_ignored_config_file() {
    info "Testing apply finds ignored config files..."
    cd "$TEST_REPO"
    create_config

    echo ".local-overrides.yaml" >> .git/info/exclude
    echo "# IGNORED CONFIG CONTENT" > CLAUDE.local.md

    git-local-override apply >/dev/null

    if grep -q "IGNORED CONFIG CONTENT" CLAUDE.md; then
        pass "Apply discovered ignored config file"
    else
        fail "Apply did not discover ignored config file"
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

test_post_checkout_hook_logs_lifecycle() {
    info "Testing post-checkout hook emits lifecycle logs..."

    cd "$TEST_REPO"
    create_config

    echo "# POST CHECKOUT LOG TEST" > CLAUDE.local.md

    local output
    output=$(.git/hooks/post-checkout "" "" "1" 2>&1)

    if [[ "$output" == *"git-local-override: post-checkout started"* ]] &&
       [[ "$output" == *"git-local-override: post-checkout finished"* ]]; then
        pass "Post-checkout hook emits start and finish logs"
    else
        fail "Post-checkout hook did not emit lifecycle logs (output: $output)"
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

test_pre_commit_hook_restores_special_char_target() {
    info "Testing pre-commit restores a special-character target name..."

    cd "$TEST_REPO"

    # A space plus a non-ASCII byte: with core.quotePath=true (the default),
    # `git diff --cached --name-only` C-quotes this name, so a plain-text
    # match against the config target never fires and the override content
    # would be committed silently.
    local special_target="spécial target.md"
    local special_override="spécial target.local.md"

    echo "# Original special content" > "$special_target"
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add -- "$special_target"
    GIT_LOCAL_OVERRIDE_DISABLE=1 git commit -q -m "Add special-name target"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: spécial target.local.md
    replaces:
      - spécial target.md
EOF

    echo "# LOCAL special content" > "$special_override"
    echo "# LOCAL special content" > "$special_target"
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add -- "$special_target"

    .git/hooks/pre-commit

    local staged_content
    staged_content="$(GIT_LOCAL_OVERRIDE_DISABLE=1 git show ":$special_target")"
    if [[ "$staged_content" == "# Original special content" ]]; then
        pass "Pre-commit restored the special-character target before commit"
    else
        fail "Special-character target still stages override content: $staged_content"
    fi
}

test_post_commit_hook() {
    info "Testing post-commit hook..."

    cd "$TEST_REPO"
    create_config

    # Ensure local file has test content
    echo "# LOCAL CONTENT FOR POST COMMIT TEST" > CLAUDE.local.md

    local common_git_dir
    common_git_dir="$(git rev-parse --git-common-dir)"
    if [[ "$common_git_dir" != /* ]]; then
        common_git_dir="$TEST_REPO/$common_git_dir"
    fi
    printf 'CLAUDE.md|CLAUDE.local.md\n' > "$common_git_dir/local-override-post-commit-state"

    # Run post-commit to apply override
    .git/hooks/post-commit

    # Check override was applied
    if grep -q "LOCAL CONTENT FOR POST COMMIT TEST" CLAUDE.md; then
        pass "Post-commit hook applied override"
    else
        fail "Post-commit hook did not apply override"
    fi
}

test_post_commit_hook_exits_without_state() {
    info "Testing post-commit exits early without state..."

    cd "$TEST_REPO"
    create_config

    echo "# LOCAL CONTENT SHOULD NOT APPLY" > CLAUDE.local.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- CLAUDE.md

    .git/hooks/post-commit

    if grep -q "Original CLAUDE.md content" CLAUDE.md; then
        pass "Post-commit leaves files alone without pre-commit state"
    else
        fail "Post-commit unexpectedly applied override without state"
    fi
}

test_pre_commit_trace_avoids_global_config_discovery() {
    info "Testing pre-commit trace avoids global config discovery..."

    cd "$TEST_REPO"
    create_config

    echo "# TRACE CACHE TEST" > CLAUDE.local.md
    .git/hooks/post-checkout "" "" "1"
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add CLAUDE.md

    local output
    output=$(GIT_LOCAL_OVERRIDE_TRACE=1 .git/hooks/pre-commit 2>&1)

    if [[ "$output" != *"discover_config_files strategy="* ]] &&
       [[ "$output" != *"discover_config_files cache="* ]]; then
        pass "Pre-commit avoids global config discovery"
    else
        fail "Pre-commit still triggered global config discovery (output: $output)"
    fi
}

test_post_checkout_trace_falls_back_when_attributes_missing() {
    info "Testing post-checkout trace falls back when attributes are missing..."

    cd "$TEST_REPO"
    create_config

    echo "# TRACE CACHE TEST" > CLAUDE.local.md

    local output
    local discover_count
    output=$(GIT_LOCAL_OVERRIDE_TRACE=1 .git/hooks/post-checkout "" "" "1" 2>&1)
    discover_count="$(count_trace_matches "$output" 'discover_config_files strategy=')"

    if [[ "$discover_count" -eq 1 ]] && [[ "$output" == *"discover_config_files cache=hit"* ]]; then
        pass "Post-checkout falls back to one discovery pass without attributes"
    else
        fail "Expected one config discovery pass and later cache hits when attributes are missing (output: $output)"
    fi
}

test_sync_attributes_entries_preserves_foreign_lines() {
    info "Testing sync_attributes_entries preserves foreign lines and regenerates the managed block..."

    cd "$TEST_REPO"

    local attributes_file
    attributes_file="$(git rev-parse --git-path info/attributes)"
    if [[ "$attributes_file" != /* ]]; then
        attributes_file="$TEST_REPO/$attributes_file"
    fi
    mkdir -p "$(dirname "$attributes_file")"

    # Seed with a foreign line plus a stale managed block from a previous run.
    cat > "$attributes_file" <<'EOF'
*.bin binary

# Auto-generated by git-local-override — do not edit manually
STALE.md filter=local-override
EOF

    # Call the canonical core directly (source the resolver in a subshell).
    (
        # shellcheck disable=SC1090
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        sync_attributes_entries "$TEST_REPO" "CLAUDE.md|CLAUDE.local.md"
    )

    local foreign_count header_count managed_count stale_count
    foreign_count="$(grep -c '^\*\.bin binary$' "$attributes_file" || true)"
    header_count="$(grep -c 'Auto-generated by git-local-override' "$attributes_file" || true)"
    managed_count="$(grep -c '^CLAUDE\.md filter=local-override$' "$attributes_file" || true)"
    stale_count="$(grep -c '^STALE\.md filter=local-override$' "$attributes_file" || true)"

    if [[ "$foreign_count" -eq 1 ]] &&
       [[ "$header_count" -eq 1 ]] &&
       [[ "$managed_count" -eq 1 ]] &&
       [[ "$stale_count" -eq 0 ]]; then
        pass "sync_attributes_entries preserves foreign lines and rewrites one managed block"
    else
        fail "Unexpected attributes content (foreign=$foreign_count header=$header_count managed=$managed_count stale=$stale_count): $(cat "$attributes_file")"
    fi
}

test_sync_attributes_quotes_space_target() {
    info "Testing attribute sync quotes a space-containing target and git wires the filter..."

    cd "$TEST_REPO"

    echo "# Original spaced content" > "my file.md"
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add -- "my file.md"
    GIT_LOCAL_OVERRIDE_DISABLE=1 git commit -q -m "Add space-name target"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: my file.local.md
    replaces:
      - my file.md
EOF

    echo "# LOCAL spaced content" > "my file.local.md"

    local sync_exit=0
    git-local-override sync-filters >/dev/null 2>&1 || sync_exit=$?

    local attributes_file
    attributes_file="$(git rev-parse --git-path info/attributes)"
    if [[ "$attributes_file" != /* ]]; then
        attributes_file="$TEST_REPO/$attributes_file"
    fi

    local attr_output
    attr_output="$(git check-attr filter -- "my file.md")"

    if [[ $sync_exit -eq 0 ]] &&
       grep -qF '"my file.md" filter=local-override' "$attributes_file" &&
       [[ "$attr_output" == *"filter: local-override"* ]]; then
        pass "Space-containing target is quoted and git wires the filter"
    else
        fail "Space target not quoted or filter not wired (sync exit: $sync_exit, check-attr: $attr_output, attributes: $(cat "$attributes_file" 2>/dev/null))"
    fi
}

test_post_checkout_trace_single_discovery_when_config_unchanged() {
    info "Testing post-checkout fast path runs one discovery pass and skips validation..."

    cd "$TEST_REPO"
    create_config
    git add .local-overrides.yaml
    git commit -q -m "Add override config"

    git-local-override sync-filters >/dev/null 2>&1

    echo "# FAST PATH TEST" > CLAUDE.local.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- CLAUDE.md

    echo '{"key": "updated"}' > config.json
    git add config.json
    git commit -q -m "Change non-config file"

    local previous_head
    local new_head
    local output
    local discover_count
    previous_head="$(git rev-parse HEAD~1)"
    new_head="$(git rev-parse HEAD)"

    # Warm up: the first post-checkout run takes the slow path and records
    # the config stamp; subsequent runs are eligible for the fast path.
    .git/hooks/post-checkout "$previous_head" "$new_head" "1" >/dev/null 2>&1

    output=$(GIT_LOCAL_OVERRIDE_TRACE=1 .git/hooks/post-checkout "$previous_head" "$new_head" "1" 2>&1)
    discover_count="$(count_trace_matches "$output" 'discover_config_files strategy=')"

    # The fast path pays exactly one discovery pass (the config drift stamp)
    # but must skip full validation and config resolution.
    if [[ "$discover_count" -eq 1 ]] &&
       [[ "$output" == *"fast-path config=unchanged"* ]] &&
       [[ "$output" != *"validate_config"* ]] &&
       grep -q "FAST PATH TEST" CLAUDE.md; then
        pass "Post-checkout fast path uses one discovery pass and skips validation"
    else
        fail "Expected fast path with a single discovery pass when config is unchanged (output: $output)"
    fi
}

test_post_checkout_falls_back_and_refreshes_attributes_when_config_changes() {
    info "Testing post-checkout falls back and refreshes attributes when config changes..."

    cd "$TEST_REPO"
    create_config
    git add .local-overrides.yaml
    git commit -q -m "Add override config"

    git-local-override sync-filters >/dev/null 2>&1

    local attributes_file
    attributes_file="$(git rev-parse --git-path info/attributes)"
    if [[ "$attributes_file" != /* ]]; then
        attributes_file="$TEST_REPO/$attributes_file"
    fi

    if grep -q '^config.json filter=local-override$' "$attributes_file"; then
        fail "Precondition failed: config.json already managed before config change"
        return 1
    fi

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
  - override: config.local.json
    replaces:
      - config.json
EOF

    git add .local-overrides.yaml
    git commit -q -m "Change override config"

    printf '{"key": "local override"}\n' > config.local.json
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- config.json

    local previous_head
    local new_head
    local output
    local discover_count
    previous_head="$(git rev-parse HEAD~1)"
    new_head="$(git rev-parse HEAD)"
    output=$(GIT_LOCAL_OVERRIDE_TRACE=1 .git/hooks/post-checkout "$previous_head" "$new_head" "1" 2>&1)
    discover_count="$(count_trace_matches "$output" 'discover_config_files strategy=')"

    if [[ "$discover_count" -eq 1 ]] &&
       [[ "$output" == *"discover_config_files cache=hit"* ]] &&
       grep -q '^config.json filter=local-override$' "$attributes_file" &&
       grep -q 'local override' config.json; then
        pass "Post-checkout falls back and refreshes attributes when config changes"
    else
        fail "Expected fallback discovery, attribute refresh, and override apply when config changes (output: $output)"
    fi
}

test_pre_rebase_trace_reuses_config_discovery_cache() {
    info "Testing pre-rebase trace reuses config discovery cache..."

    cd "$TEST_REPO"
    create_config

    echo "# TRACE CACHE TEST" > CLAUDE.local.md

    local output
    local discover_count
    output=$(GIT_LOCAL_OVERRIDE_TRACE=1 .git/hooks/pre-rebase 2>&1)
    discover_count="$(count_trace_matches "$output" 'discover_config_files strategy=')"

    if [[ "$discover_count" -eq 1 ]] && [[ "$output" == *"discover_config_files cache=hit"* ]]; then
        pass "Pre-rebase performs config discovery once per hook run"
    else
        fail "Expected one config discovery pass and later cache hits during pre-rebase (output: $output)"
    fi
}

test_discovery_full_finds_directly_ignored_config() {
    info "Testing full discovery finds a directly-ignored config in a walked dir..."

    cd "$TEST_REPO"

    mkdir -p tools
    cat > tools/.local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: notes.local.md
    replaces:
      - notes.md
EOF
    # Ignore the config file itself; its parent dir (tools/) is still walked.
    echo "tools/.local-overrides.yaml" >> .git/info/exclude

    local output
    output="$(
        # shellcheck disable=SC1090
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        discover_config_files "$PWD"
    )"

    if printf '%s\n' "$output" | grep -qxF "tools/.local-overrides.yaml"; then
        pass "Full discovery finds a directly-ignored config in a walked directory"
    else
        fail "Directly-ignored config not discovered (output: $output)"
    fi
}

test_discovery_skips_config_inside_ignored_dir() {
    info "Testing full discovery skips a config inside a wholly-ignored directory..."

    cd "$TEST_REPO"

    mkdir -p vendor/dep
    cat > vendor/dep/.local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: x.local.md
    replaces:
      - x.md
EOF
    # Ignore the whole vendor/ tree: git collapses it under --directory, so the
    # config inside is never discovered (carve-out 1).
    echo "vendor/" >> .git/info/exclude

    local output
    output="$(
        # shellcheck disable=SC1090
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        discover_config_files "$PWD"
    )"

    if printf '%s\n' "$output" | grep -qF "vendor/dep/.local-overrides.yaml"; then
        fail "Config inside a wholly-ignored directory was discovered (output: $output)"
    else
        pass "Config inside a wholly-ignored directory is not discovered"
    fi
}

test_discovery_hot_mode_unions_stamped_paths() {
    info "Testing hot discovery unions stamped paths but skips the ignored tree..."

    cd "$TEST_REPO"

    # Root config is untracked-but-not-ignored, so pass 1 always finds it.
    create_config
    mkdir -p tools
    cat > tools/.local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: notes.local.md
    replaces:
      - notes.md
EOF
    echo "tools/.local-overrides.yaml" >> .git/info/exclude

    local hot_plain hot_extra hot_missing
    hot_plain="$(
        # shellcheck disable=SC1090
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        discover_config_files "$PWD" hot
    )"
    hot_extra="$(
        # shellcheck disable=SC1090
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        discover_config_files "$PWD" hot "tools/.local-overrides.yaml"
    )"
    hot_missing="$(
        # shellcheck disable=SC1090
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        discover_config_files "$PWD" hot "gone/.local-overrides.yaml"
    )"

    local extra_count missing_count
    extra_count="$(printf '%s\n' "$hot_extra" | grep -cxF "tools/.local-overrides.yaml" || true)"
    missing_count="$(printf '%s\n' "$hot_missing" | grep -cxF "gone/.local-overrides.yaml" || true)"

    if ! printf '%s\n' "$hot_plain" | grep -qxF "tools/.local-overrides.yaml" &&
       [[ "$extra_count" -eq 1 ]] &&
       [[ "$missing_count" -eq 0 ]]; then
        pass "Hot discovery skips the ignored tree, unions existing stamped paths once, drops missing ones"
    else
        fail "Hot mode union incorrect (plain=[$hot_plain] extra_count=$extra_count missing_count=$missing_count)"
    fi
}

test_discovery_never_reads_git_dir_configs() {
    info "Testing discovery never reads configs inside .git/..."

    cd "$TEST_REPO"

    mkdir -p .git/sub
    cat > .git/sub/.local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: x.local.md
    replaces:
      - x.md
EOF

    local output
    output="$(
        # shellcheck disable=SC1090
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        discover_config_files "$PWD"
    )"

    if printf '%s\n' "$output" | grep -qF ".git/sub/.local-overrides.yaml"; then
        fail "Config inside .git/ was discovered (output: $output)"
    else
        pass "Configs inside .git/ are never discovered (carve-out 3 tripwire)"
    fi
}

test_new_gitignored_config_registered_by_sync_filters() {
    info "Testing a new gitignored config is registered only after sync-filters..."

    cd "$TEST_REPO"

    # Tracked root config + its override; sync-filters records the stamp.
    create_config
    git add .local-overrides.yaml
    git commit -q -m "Add tracked root config"
    echo "# ROOT LOCAL" > CLAUDE.local.md

    git-local-override sync-filters >/dev/null 2>&1

    local head
    head="$(git rev-parse HEAD)"
    # Warm the attributes/stamp via one hook run.
    .git/hooks/post-checkout "$head" "$head" "1" >/dev/null 2>&1

    # A brand-new gitignored config in a walked subdir, managing a tracked
    # target. No tracked config diff can see it.
    mkdir -p sub
    echo "# original notes" > sub/notes.md
    git add sub/notes.md
    git commit -q -m "Add tracked subdir target"
    cat > sub/.local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: notes.local.md
    replaces:
      - notes.md
EOF
    echo "sub/.local-overrides.yaml" >> .gitignore
    echo "# SUB LOCAL notes" > sub/notes.local.md

    head="$(git rev-parse HEAD)"

    # Before sync-filters: hooks trust the stamp, so the new gitignored config
    # is invisible and the new target is left untouched.
    .git/hooks/post-checkout "$head" "$head" "1" >/dev/null 2>&1
    local before_applied=false
    if grep -q "SUB LOCAL notes" sub/notes.md; then
        before_applied=true
    fi

    # sync-filters runs full discovery, registering the new config + stamp.
    git-local-override sync-filters >/dev/null 2>&1
    .git/hooks/post-checkout "$head" "$head" "1" >/dev/null 2>&1
    local after_applied=false
    if grep -q "SUB LOCAL notes" sub/notes.md; then
        after_applied=true
    fi

    if [[ "$before_applied" == false && "$after_applied" == true ]]; then
        pass "New gitignored config unregistered until sync-filters, then applied on checkout"
    else
        fail "Expected new target unmanaged before sync-filters and managed after (before=$before_applied after=$after_applied)"
    fi
}

test_readonly_cli_hot_discovery_on_matching_stamp() {
    info "Testing a read-only CLI command uses hot discovery when the config stamp matches..."

    cd "$TEST_REPO"
    create_config
    git add .local-overrides.yaml
    git commit -q -m "Add override config"
    echo "# ROOT LOCAL" > CLAUDE.local.md

    # sync-filters runs full discovery and records the config stamp the
    # read-only fast path trusts.
    git-local-override sync-filters >/dev/null 2>&1

    local output
    local discover_count
    output=$(GIT_LOCAL_OVERRIDE_TRACE=1 git-local-override validate 2>&1)
    discover_count="$(count_trace_matches "$output" 'discover_config_files strategy=')"

    # A matching stamp means the hot cache is trusted: exactly one hot pass,
    # no ignored-tree walk.
    if [[ "$discover_count" -eq 1 ]] &&
       [[ "$output" == *"strategy=hot"* ]] &&
       [[ "$output" != *"strategy=full"* ]]; then
        pass "Read-only validate performs a single hot discovery pass on a matching stamp"
    else
        fail "Expected exactly one hot discovery pass and no full walk (count=$discover_count, output: $output)"
    fi
}

test_readonly_cli_falls_back_to_full_on_stamp_mismatch() {
    info "Testing a read-only CLI command falls back to full discovery on stamp drift and sees a new gitignored config..."

    cd "$TEST_REPO"
    create_config
    git add .local-overrides.yaml
    git commit -q -m "Add override config"
    echo "# ROOT LOCAL" > CLAUDE.local.md

    # Stamp records the config set as of this full discovery: {root config}.
    git-local-override sync-filters >/dev/null 2>&1

    # A brand-new gitignored config in a walked subdir, managing a tracked
    # target. Full discovery finds it; hot discovery (stamped paths only) can't.
    mkdir -p sub
    echo "# original notes" > sub/notes.md
    git add sub/notes.md
    git commit -q -m "Add tracked subdir target"
    cat > sub/.local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: notes.local.md
    replaces:
      - notes.md
EOF
    echo "sub/.local-overrides.yaml" >> .gitignore
    echo "# SUB LOCAL notes" > sub/notes.local.md

    # Edit the tracked root config so its checksum no longer matches the stamp,
    # forcing the fast path to fall back to a full walk. The entries are
    # unchanged, so the only effect is the cksum-based stamp mismatch.
    printf '\n# stamp-busting comment\n' >> .local-overrides.yaml

    local output
    output=$(GIT_LOCAL_OVERRIDE_TRACE=1 git-local-override list 2>&1)

    if [[ "$output" == *"strategy=full"* ]] &&
       [[ "$output" == *"sub/notes.md"* ]]; then
        pass "Read-only list falls back to full discovery on stamp drift and finds the new gitignored config"
    else
        fail "Expected full-discovery fallback and visibility of the new gitignored config (output: $output)"
    fi
}

test_readonly_cli_falls_back_to_full_on_stamp_deletion() {
    info "Testing a read-only CLI command falls back to full discovery when a stamped config is deleted..."

    cd "$TEST_REPO"
    create_config
    git add .local-overrides.yaml
    git commit -q -m "Add override config"
    echo "# ROOT LOCAL" > CLAUDE.local.md

    # A gitignored config managing a tracked target, registered via the
    # sync-filters full walk so the stamp records it.
    mkdir -p sub
    echo "# original notes" > sub/notes.md
    git add sub/notes.md
    git commit -q -m "Add tracked subdir target"
    cat > sub/.local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: notes.local.md
    replaces:
      - notes.md
EOF
    echo "sub/.local-overrides.yaml" >> .gitignore
    echo "# SUB LOCAL notes" > sub/notes.local.md
    git-local-override sync-filters >/dev/null 2>&1

    # Deletion is a distinct drift branch from the cksum-edit case: a stamped
    # path is now missing entirely from the hot set.
    rm sub/.local-overrides.yaml

    local output
    output=$(GIT_LOCAL_OVERRIDE_TRACE=1 git-local-override list 2>&1)

    if [[ "$output" == *"strategy=full"* ]] &&
       [[ "$output" != *"sub/notes.md"* ]]; then
        pass "Read-only list falls back to full discovery on stamped-config deletion and drops its targets"
    else
        fail "Expected full-discovery fallback without the deleted config's target (output: $output)"
    fi
}

test_readonly_cli_full_discovery_without_stamp() {
    info "Testing a read-only CLI command uses full discovery without a stamp and never writes one..."

    cd "$TEST_REPO"
    create_config
    git add .local-overrides.yaml
    git commit -q -m "Add override config"
    echo "# ROOT LOCAL" > CLAUDE.local.md

    # No sync-filters/post-checkout slow path has run, so there is no stamp.
    local stamp_file
    stamp_file="$(git rev-parse --absolute-git-dir)/local-override-config-stamp"
    rm -f "$stamp_file"

    local output
    output=$(GIT_LOCAL_OVERRIDE_TRACE=1 git-local-override validate 2>&1)

    # A missing stamp fails the match, so the read-only command must fall back
    # to a full walk — and must not write the stamp (that stays sync-filters'
    # and the post-checkout slow path's job).
    if [[ "$output" == *"strategy=full"* ]] && [[ ! -f "$stamp_file" ]]; then
        pass "Read-only validate falls back to full discovery without a stamp and writes no stamp"
    else
        local stamp_state="absent"
        [[ -f "$stamp_file" ]] && stamp_state="present"
        fail "Expected full discovery without a stamp and no stamp written (stamp=$stamp_state, output: $output)"
    fi
}

test_discover_config_files_hot_then_full() {
    info "Testing the resolver hot-then-full discovery kernel directly..."

    cd "$TEST_REPO"
    create_config
    git add .local-overrides.yaml
    git commit -q -m "Add override config"

    # sync-filters runs full discovery and writes the stamp the kernel trusts.
    git-local-override sync-filters >/dev/null 2>&1

    # Runs the kernel in a fresh subshell against the sourced resolver, then
    # prints the cache it left populated. Trace + cache listing share stdout.
    run_kernel() (
        # shellcheck disable=SC1091
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        export GIT_LOCAL_OVERRIDE_TRACE=1
        discover_config_files_hot_then_full "$TEST_REPO" "$TEST_REPO" 2>&1
        GIT_LOCAL_OVERRIDE_TRACE="" get_cached_config_files "$TEST_REPO" 2>/dev/null
        clear_config_files_cache
    )

    local failures=""
    local output=""

    # (a) Matching stamp: one hot pass, no full fallback.
    output="$(run_kernel)"
    if [[ "$output" != *"strategy=hot"* ]] || [[ "$output" == *"strategy=full"* ]]; then
        failures="$failures matching-stamp-not-hot-only"
    fi

    # (b) Stamp drift: a new gitignored config the hot walk cannot see, plus a
    # stamp-busting edit to the tracked root config, must trigger the full
    # fallback and leave the full result cached.
    mkdir -p sub
    echo "# original notes" > sub/notes.md
    git add sub/notes.md
    git commit -q -m "Add tracked subdir target"
    cat > sub/.local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: notes.local.md
    replaces:
      - notes.md
EOF
    echo "sub/.local-overrides.yaml" >> .gitignore
    printf '\n# stamp-busting comment\n' >> .local-overrides.yaml

    output="$(run_kernel)"
    if [[ "$output" != *"strategy=full"* ]]; then
        failures="$failures drift-no-full-fallback"
    fi
    if [[ "$output" != *"sub/.local-overrides.yaml"* ]]; then
        failures="$failures drift-cache-missing-new-config"
    fi

    if [[ -z "$failures" ]]; then
        pass "Kernel serves hot on a matching stamp and falls back to a full cache on drift"
    else
        fail "Kernel behavior mismatches:$failures (last output: $output)"
    fi
}

test_apply_writes_config_stamp() {
    info "Testing apply writes the config stamp so the hot path can trust it..."

    cd "$TEST_REPO"
    create_config
    git add .local-overrides.yaml
    git commit -q -m "Add override config"
    echo "# ROOT LOCAL" > CLAUDE.local.md

    # Start without a stamp so only apply itself can have written it.
    local stamp_file
    stamp_file="$(git rev-parse --absolute-git-dir)/local-override-config-stamp"
    rm -f "$stamp_file"

    git-local-override apply >/dev/null 2>&1

    # apply's full discovery must register the resolved config set in the
    # stamp — exactly the state sync-filters leaves — so the stamp must exist,
    # be non-empty, and match the current on-disk config set.
    local stamp_matches=false
    if (
        # shellcheck disable=SC1090
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        config_stamp_matches "$PWD" "$PWD"
    ); then
        stamp_matches=true
    fi

    if [[ -s "$stamp_file" ]] && [[ "$stamp_matches" == true ]]; then
        pass "apply writes a config stamp matching the on-disk config set"
    else
        local stamp_state="missing-or-empty"
        [[ -s "$stamp_file" ]] && stamp_state="present"
        fail "Expected apply to write a matching config stamp (stamp=$stamp_state, matches=$stamp_matches)"
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

test_status_recognizes_filter_process_mode() {
    info "Testing status recognizes the experimental filter.process driver..."

    cd "$TEST_REPO"
    create_config

    # Configure only the experimental process driver (unset smudge/clean).
    git config --local --unset-all filter.local-override.smudge 2>/dev/null || true
    git config --local --unset-all filter.local-override.clean 2>/dev/null || true
    git config --local filter.local-override.process "x"

    local output
    local filter_line
    output=$(git-local-override status)
    # Strip ANSI color codes and isolate the Filter: line.
    filter_line=$(printf '%s\n' "$output" | sed $'s/\033\[[0-9;]*m//g' | grep '^Filter:' || true)

    if [[ "$filter_line" == *"installed (filter.process"* \
        && "$filter_line" != *"not installed"* ]]; then
        pass "Status recognizes filter.process mode"
    else
        fail "Status did not recognize filter.process mode (Filter line: '$filter_line')"
    fi
}

test_status_in_worktree() {
    info "Testing status command from inside a linked worktree..."

    cd "$TEST_REPO"
    create_config
    git add .local-overrides.yaml
    git commit -q -m "Add local-overrides config"

    local worktree_dir="$TEST_ROOT/status-worktree"
    git worktree add -q "$worktree_dir" -b status-worktree-branch

    local output
    output=$(cd "$worktree_dir" && git-local-override status)

    local hooks_line
    hooks_line=$(printf '%s\n' "$output" | grep "Hooks:" || true)

    git worktree remove --force "$worktree_dir"
    git branch -q -D status-worktree-branch

    if [[ "$hooks_line" == *"not installed"* ]]; then
        fail "Status reported hooks not installed from linked worktree"
    elif [[ "$hooks_line" == *"installed"* ]]; then
        pass "Status detects hooks from linked worktree"
    else
        fail "Status output has no Hooks line: $hooks_line"
    fi
}

test_status_detects_precommit_framework_hooks() {
    info "Testing status detection of pre-commit framework hooks..."

    cd "$TEST_REPO"
    create_config

    # Replace the direct hooks with pre-commit framework shims
    local hook_type
    for hook_type in post-checkout pre-commit post-commit; do
        cat > ".git/hooks/$hook_type" << 'EOF'
#!/usr/bin/env bash
# File generated by pre-commit: https://pre-commit.com
# ID: 138fd403232d2ddd5efb44317e38bf03
exec pre-commit run --hook-stage "$(basename "$0")"
EOF
        chmod +x ".git/hooks/$hook_type"
    done

    cat > .pre-commit-config.yaml << 'EOF'
repos:
  - repo: https://github.com/jonathanabila/git-override
    rev: v0.5.0
    hooks:
      - id: local-override-pre-commit
      - id: local-override-post-commit
      - id: local-override-post-checkout
EOF

    local output
    output=$(git-local-override status)

    if [[ "$output" == *"installed (via pre-commit)"* ]]; then
        pass "Status reports hooks installed via pre-commit"
    else
        fail "Status did not detect pre-commit framework hooks"
    fi
}

test_status_shim_without_local_override_ids() {
    info "Testing status rejects pre-commit shims without local-override hooks..."

    cd "$TEST_REPO"
    create_config

    local hook_type
    for hook_type in post-checkout pre-commit post-commit; do
        cat > ".git/hooks/$hook_type" << 'EOF'
#!/usr/bin/env bash
# File generated by pre-commit: https://pre-commit.com
exec pre-commit run --hook-stage "$(basename "$0")"
EOF
        chmod +x ".git/hooks/$hook_type"
    done

    # Config exists but lists no local-override hook ids
    cat > .pre-commit-config.yaml << 'EOF'
repos:
  - repo: https://github.com/psf/black
    rev: 24.1.0
    hooks:
      - id: black
EOF

    local output
    output=$(git-local-override status)
    local hooks_line
    hooks_line=$(printf '%s\n' "$output" | grep "Hooks:" || true)

    if [[ "$hooks_line" == *"not installed"* ]]; then
        pass "Status reports not installed for unrelated pre-commit shims"
    else
        fail "Status wrongly accepted shims without local-override hook ids: $hooks_line"
    fi
}

test_status_empty_attributes_no_arithmetic_error() {
    info "Testing status with filter configured but no filtered entries yet..."

    cd "$TEST_REPO"
    create_config

    # Reproduce the pre-sync-filters state: filter driver configured, but the
    # attributes file has no filter=local-override lines. grep -c then prints
    # "0" AND exits non-zero; a naive `|| echo 0` would make the count a
    # two-line value and break the numeric comparison in status.
    git config --local filter.local-override.smudge "smudge %f"
    git config --local filter.local-override.clean "clean %f"

    local attributes_file
    attributes_file="$(git rev-parse --git-path info/attributes)"
    mkdir -p "$(dirname "$attributes_file")"
    : > "$attributes_file"

    local output
    output=$(git-local-override status 2>&1)

    # A corrupted filter_count makes bash print "... arithmetic syntax error
    # in expression ...". Match that specific signature — not the loose word
    # "arithmetic", which also appears in this test's own temp-dir path.
    if [[ "$output" == *"syntax error"* ]]; then
        fail "Status emitted an arithmetic error on empty attributes: $output"
    elif [[ "$output" == *"Filtered:"* && "$output" == *"0 files"* ]]; then
        pass "Status reports zero filtered files without arithmetic errors"
    else
        fail "Status did not report the expected empty-filter state: $output"
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

test_validate_valid_config_passes() {
    info "Testing validate accepts a well-formed config..."
    cd "$TEST_REPO"

    create_config

    local output
    local exit_code=0
    output=$(git-local-override validate 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 && "$output" == *"Config valid"* ]]; then
        pass "validate exits 0 with summary on valid config"
    else
        fail "validate failed on valid config (exit: $exit_code, output: $output)"
    fi
}

test_validate_duplicate_target_fails() {
    info "Testing validate rejects duplicate targets..."
    cd "$TEST_REPO"

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

    local output
    local exit_code=0
    output=$(git-local-override validate 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 && "$output" == *"Duplicate"* ]]; then
        pass "validate rejects duplicate target"
    else
        fail "validate did not reject duplicate target (exit: $exit_code, output: $output)"
    fi

    rm -f FIRST.local.md SECOND.local.md
    create_config
}

test_validate_subtree_escape_rejected() {
    info "Testing validate rejects subtree escapes..."
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
    output=$(git-local-override validate 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 && "$output" == *"escapes its subtree"* ]]; then
        pass "validate rejects subtree escape"
    else
        fail "validate did not reject subtree escape (exit: $exit_code, output: $output)"
    fi

    rm -f backend/.local-overrides.yaml
    create_config
}

test_validate_rejects_attr_macro_target() {
    info "Testing validate rejects an attribute-macro target..."
    cd "$TEST_REPO"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: MACRO.local.md
    replaces:
      - "[attr]binary"
EOF

    local output
    local exit_code=0
    output=$(git-local-override validate 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 && "$output" == *"glob/attribute metacharacter"* ]]; then
        pass "validate rejects attribute-macro target"
    else
        fail "validate did not reject attribute-macro target (exit: $exit_code, output: $output)"
    fi

    create_config
}

test_validate_rejects_wildcard_target() {
    info "Testing validate rejects a wildcard target..."
    cd "$TEST_REPO"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: WILD.local.md
    replaces:
      - "*"
EOF

    local output
    local exit_code=0
    output=$(git-local-override validate 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 && "$output" == *"glob/attribute metacharacter"* ]]; then
        pass "validate rejects wildcard target"
    else
        fail "validate did not reject wildcard target (exit: $exit_code, output: $output)"
    fi

    create_config
}

test_validate_no_config_dies() {
    info "Testing validate dies without a config..."
    cd "$TEST_REPO"

    rm -f .local-overrides.yaml .local-overrides

    local output
    local exit_code=0
    output=$(git-local-override validate 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 && "$output" == *"No .local-overrides.yaml"* ]]; then
        pass "validate dies with no-config message"
    else
        fail "validate did not die on missing config (exit: $exit_code, output: $output)"
    fi

    create_config
}

test_unknown_command_dies() {
    info "Testing unknown command dies..."
    cd "$TEST_REPO"

    local output
    local exit_code=0
    output=$(git-local-override definitely-not-a-command 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 && "$output" == *"Unknown command"* ]]; then
        pass "unknown command dies with message"
    else
        fail "unknown command did not die (exit: $exit_code, output: $output)"
    fi
}

test_outside_repo_dies() {
    info "Testing commands die outside a git repository..."

    local scratch
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/glo-norepo.XXXXXX")"
    cd "$scratch"

    # Guard against a vacuous pass: if the scratch dir is somehow inside a
    # repository, the "not in a repo" assertion would be meaningless.
    if git rev-parse --git-dir >/dev/null 2>&1; then
        cd "$TEST_REPO"
        rm -rf "$scratch"
        fail "scratch dir is unexpectedly inside a git repo: $scratch"
        return
    fi

    local ok=1
    local bad=""
    local cmd output exit_code
    for cmd in status list apply; do
        exit_code=0
        output=$(git-local-override "$cmd" 2>&1) || exit_code=$?
        if [[ $exit_code -eq 0 || "$output" != *"Not in a git repository"* ]]; then
            ok=0
            bad="$bad $cmd(exit=$exit_code)"
        fi
    done

    cd "$TEST_REPO"
    rm -rf "$scratch"

    if [[ $ok -eq 1 ]]; then
        pass "status/list/apply die outside a git repository"
    else
        fail "commands did not die outside a repo:$bad"
    fi
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

test_invalid_path_entry_fails_whole_config() {
    info "Testing invalid path entry fails validation instead of truncating..."

    cd "$TEST_REPO"

    # The middle target escapes the repo root, which fails path normalization
    # inside the parser. Previously the parser aborted mid-stream and the bad
    # entry plus every entry after it were silently dropped, while the first
    # entry was still accepted with no diagnostic at all.
    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: FIRST.local.md
    replaces:
      - FIRST.md
  - override: EVIL.local.md
    replaces:
      - ../outside-repo.md
  - override: THIRD.local.md
    replaces:
      - THIRD.md
EOF

    local output
    local exit_code=0
    output=$(git-local-override list 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 && "$output" == *".local-overrides.yaml"* \
        && "$output" != *"FIRST.md"* ]]; then
        pass "Invalid path entry rejects the whole config with an error"
    else
        fail "Expected validation failure naming the config without accepting valid entries (exit: $exit_code, output: $output)"
    fi
}

test_valid_multi_entry_config_parses_fully() {
    info "Testing valid multi-entry config lists every entry..."

    cd "$TEST_REPO"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: FIRST.local.md
    replaces:
      - FIRST.md
  - override: SECOND.local.md
    replaces:
      - SECOND.md
EOF

    local output
    local exit_code=0
    output=$(git-local-override list 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 && "$output" == *"FIRST.md"* && "$output" == *"SECOND.md"* ]]; then
        pass "Valid multi-entry config lists all entries"
    else
        fail "Expected both entries listed (exit: $exit_code, output: $output)"
    fi
}

test_symlink_target_refused_on_apply() {
    info "Testing symlinked target is refused (write escape)..."

    cd "$TEST_REPO"

    # An outside-repo file the attacker wants to overwrite. It lives in the
    # test's temp area but OUTSIDE the repo root, so a failed guard is an
    # observable out-of-repo write (never point this at a real $HOME file).
    local outside_file="$CURRENT_TEST_ROOT/outside-secret.txt"
    echo "OUTSIDE SECRET" > "$outside_file"

    # Config declares a target that, on disk, is a symlink pointing outside.
    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: evil.local.md
    replaces:
      - evil-target.md
EOF

    echo "PWNED" > evil.local.md
    ln -s "$outside_file" evil-target.md

    local output
    local exit_code=0
    output=$(.git/hooks/post-checkout "" "" "1" 2>&1) || exit_code=$?

    local after
    after="$(cat "$outside_file")"

    rm -f evil-target.md evil.local.md

    if [[ "$after" == "OUTSIDE SECRET" && "$output" == *"refusing symlinked path"* ]]; then
        pass "Symlinked target refused; outside file not overwritten"
    else
        fail "Symlink target write escape not prevented (outside now: '$after', output: '$output')"
    fi
}

test_symlink_override_refused_on_smudge() {
    info "Testing symlinked override is refused (read leak)..."

    cd "$TEST_REPO"
    create_config

    local smudge_script=".git/hooks/local-override-filter-smudge"

    if [[ ! -f "$smudge_script" ]]; then
        fail "Smudge filter script not found"
        return
    fi

    # An outside-repo secret the attacker wants to exfiltrate into a tracked file.
    local outside_file="$CURRENT_TEST_ROOT/outside-key.txt"
    echo "OUTSIDE SSH KEY" > "$outside_file"

    # The override file is a symlink to the outside secret.
    rm -f CLAUDE.local.md
    ln -s "$outside_file" CLAUDE.local.md

    local original="# Original CLAUDE.md content"
    local output
    output=$(echo "$original" | "$smudge_script" CLAUDE.md)

    rm -f CLAUDE.local.md

    if [[ "$output" == "$original" && "$output" != *"OUTSIDE SSH KEY"* ]]; then
        pass "Symlinked override refused; outside content not leaked"
    else
        fail "Symlinked override leaked outside content (output: '$output')"
    fi
}

test_symlink_guard_allows_regular_files() {
    info "Testing non-symlink target/override still applies..."

    cd "$TEST_REPO"
    create_config

    echo "# LOCAL OK CONTENT" > CLAUDE.local.md

    local output
    local exit_code=0
    output=$(.git/hooks/post-checkout "" "" "1" 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 ]] \
       && grep -q "LOCAL OK CONTENT" CLAUDE.md \
       && [[ "$output" != *"refusing symlinked path"* ]]; then
        pass "Regular (non-symlink) override applies normally"
    else
        fail "Regular override did not apply (exit: $exit_code, output: '$output')"
    fi
}

# Direct decision-table test for the resolver's override read-side predicate
# (spec: docs/superpowers/specs/2026-07-12-symlinked-override-optin-design.md).
# Each check sources the resolver in a subshell so the per-process memo in
# local_override_follow_symlinks_enabled never sees two config states.
test_override_symlink_helper_decision_table() {
    info "Testing override_path_is_symlink_safe decision table..."

    cd "$TEST_REPO"
    create_config

    local outside_file="$CURRENT_TEST_ROOT/outside-canonical.md"
    echo "# EXTERNAL CANONICAL" > "$outside_file"

    # Runs the predicate in a fresh subshell; exit status is the verdict.
    check_override_safe() (
        # shellcheck disable=SC1091
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        override_path_is_symlink_safe "$TEST_REPO" "$1" "$TEST_REPO"
    )

    local failures=""

    # Row 1: regular file -> current containment behavior (safe).
    echo "# regular" > CLAUDE.local.md
    check_override_safe "CLAUDE.local.md" || failures="$failures regular-file-refused"

    # Row 2: symlink, opt-in off -> refused.
    rm -f CLAUDE.local.md
    ln -s "$outside_file" CLAUDE.local.md
    check_override_safe "CLAUDE.local.md" && failures="$failures no-optin-followed"

    # Row 4: symlink, opt-in on, untracked, resolves -> followed.
    git config local-override.followSymlinkedOverrides true
    check_override_safe "CLAUDE.local.md" || failures="$failures optin-refused"

    # Row 3: symlink, opt-in on, TRACKED -> refused.
    git add -f CLAUDE.local.md
    check_override_safe "CLAUDE.local.md" && failures="$failures tracked-followed"
    git rm -q --cached CLAUDE.local.md

    # Row 5: symlink, opt-in on, untracked, dangling -> refused (missing).
    rm -f CLAUDE.local.md
    ln -s "$CURRENT_TEST_ROOT/does-not-exist.md" CLAUDE.local.md
    check_override_safe "CLAUDE.local.md" && failures="$failures dangling-followed"

    rm -f CLAUDE.local.md
    git config --unset local-override.followSymlinkedOverrides || true

    if [[ -z "$failures" ]]; then
        pass "override_path_is_symlink_safe matches the decision table"
    else
        fail "Decision table violations:$failures"
    fi
}

# Direct test for the shared display classifier used by `list` and `doctor`.
# Each check sources the resolver in a subshell so the per-process memo in
# local_override_follow_symlinks_enabled never sees two config states.
test_classify_symlinked_override() {
    info "Testing classify_symlinked_override state tokens..."

    cd "$TEST_REPO"
    create_config

    local outside_file="$CURRENT_TEST_ROOT/classifier-canonical.md"
    echo "# EXTERNAL CANONICAL" > "$outside_file"

    # Runs the classifier in a fresh subshell; prints the state token.
    classify() (
        # shellcheck disable=SC1091
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        classify_symlinked_override "$TEST_REPO" "$1"
    )

    local failures=""
    local token=""

    # State 1: opt-in off -> ignored-optout.
    rm -f CLAUDE.local.md
    ln -s "$outside_file" CLAUDE.local.md
    token="$(classify "CLAUDE.local.md")"
    [[ "$token" == "ignored-optout" ]] || failures="$failures optout=$token"

    # State 2: opt-in on, untracked, resolves -> followed.
    git config local-override.followSymlinkedOverrides true
    token="$(classify "CLAUDE.local.md")"
    [[ "$token" == "followed" ]] || failures="$failures followed=$token"

    # State 3: opt-in on, TRACKED -> tracked-refused.
    git add -f CLAUDE.local.md
    token="$(classify "CLAUDE.local.md")"
    [[ "$token" == "tracked-refused" ]] || failures="$failures tracked=$token"
    git rm -q --cached CLAUDE.local.md

    # State 4: opt-in on, untracked, dangling -> dangling.
    rm -f CLAUDE.local.md
    ln -s "$CURRENT_TEST_ROOT/does-not-exist.md" CLAUDE.local.md
    token="$(classify "CLAUDE.local.md")"
    [[ "$token" == "dangling" ]] || failures="$failures dangling=$token"

    rm -f CLAUDE.local.md
    git config --unset local-override.followSymlinkedOverrides || true

    if [[ -z "$failures" ]]; then
        pass "classify_symlinked_override returns all four state tokens"
    else
        fail "Classifier token mismatches:$failures"
    fi
}

test_symlink_override_refused_without_optin_cli() {
    info "Testing CLI apply skips symlinked override without opt-in..."

    cd "$TEST_REPO"
    create_config

    local outside_file="$CURRENT_TEST_ROOT/external-canonical.md"
    echo "# EXTERNAL CANONICAL" > "$outside_file"

    rm -f CLAUDE.local.md
    ln -s "$outside_file" CLAUDE.local.md

    local output
    local exit_code=0
    output=$(git-local-override apply 2>&1) || exit_code=$?

    local attributes_file
    attributes_file="$(git rev-parse --git-path info/attributes)"

    # Refused symlinked override is a benign skip: apply exits 0, the target
    # keeps its original content, and attributes are still synced.
    if [[ $exit_code -eq 0 ]] \
       && [[ "$output" == *"refusing symlinked override"* ]] \
       && grep -q "Original CLAUDE.md content" CLAUDE.md \
       && grep -q "filter=local-override" "$attributes_file"; then
        pass "Symlinked override skipped by apply without opt-in"
    else
        fail "Expected apply to warn-skip (exit: $exit_code, output: '$output')"
    fi
}

test_symlink_override_followed_with_optin() {
    info "Testing CLI apply follows symlinked override with opt-in..."

    cd "$TEST_REPO"
    create_config
    git config local-override.followSymlinkedOverrides true

    local outside_file="$CURRENT_TEST_ROOT/external-canonical.md"
    echo "# EXTERNAL CANONICAL" > "$outside_file"

    rm -f CLAUDE.local.md
    ln -s "$outside_file" CLAUDE.local.md

    local output
    local exit_code=0
    output=$(git-local-override apply 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 ]] \
       && grep -q "EXTERNAL CANONICAL" CLAUDE.md \
       && [[ -L CLAUDE.local.md ]]; then
        pass "Symlinked override applied; link preserved"
    else
        fail "Apply did not follow opt-in symlink (exit: $exit_code, output: '$output')"
    fi
}

test_tracked_symlink_override_refused_with_optin() {
    info "Testing tracked symlinked override refused even with opt-in..."

    cd "$TEST_REPO"
    create_config
    git config local-override.followSymlinkedOverrides true

    local outside_file="$CURRENT_TEST_ROOT/external-secret.md"
    echo "OUTSIDE SECRET" > "$outside_file"

    rm -f CLAUDE.local.md
    ln -s "$outside_file" CLAUDE.local.md
    # Simulate a hostile repo shipping the symlink: track it.
    git add -f CLAUDE.local.md

    local output
    local exit_code=0
    output=$(git-local-override apply 2>&1) || exit_code=$?

    local attributes_file
    attributes_file="$(git rev-parse --git-path info/attributes)"

    # Refused (tracked) symlinked override is a benign skip: apply exits 0,
    # the target keeps its original content, and attributes are still synced.
    if [[ $exit_code -eq 0 ]] \
       && [[ "$output" == *"refusing symlinked override"* ]] \
       && grep -q "Original CLAUDE.md content" CLAUDE.md \
       && grep -q "filter=local-override" "$attributes_file"; then
        pass "Tracked symlinked override refused despite opt-in"
    else
        fail "Tracked symlink not refused (exit: $exit_code, output: '$output')"
    fi
}

test_dangling_symlink_override_treated_missing() {
    info "Testing dangling symlinked override treated as missing..."

    cd "$TEST_REPO"
    create_config
    git config local-override.followSymlinkedOverrides true

    rm -f CLAUDE.local.md
    ln -s "$CURRENT_TEST_ROOT/does-not-exist.md" CLAUDE.local.md

    local output
    local exit_code=0
    output=$(git-local-override apply 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 ]] \
       && grep -q "Original CLAUDE.md content" CLAUDE.md; then
        pass "Dangling symlinked override skipped as missing"
    else
        fail "Dangling symlink mishandled (exit: $exit_code, output: '$output')"
    fi
}

test_symlink_target_still_refused_with_optin() {
    info "Testing symlinked TARGET still refused with opt-in set..."

    cd "$TEST_REPO"

    local outside_file="$CURRENT_TEST_ROOT/outside-write-target.txt"
    echo "OUTSIDE SECRET" > "$outside_file"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: evil.local.md
    replaces:
      - evil-target.md
EOF

    git config local-override.followSymlinkedOverrides true
    echo "PWNED" > evil.local.md
    ln -s "$outside_file" evil-target.md

    local output
    local exit_code=0
    output=$(git-local-override apply 2>&1) || exit_code=$?

    local after
    after="$(cat "$outside_file")"
    rm -f evil-target.md evil.local.md

    # The refusal is now a benign skip (exit 0), but the write guard must
    # still hold: the outside file is never overwritten.
    if [[ $exit_code -eq 0 ]] \
       && [[ "$output" == *"refusing symlinked path"* ]] \
       && [[ "$after" == "OUTSIDE SECRET" ]]; then
        pass "Symlinked target still refused; opt-in is read-side only"
    else
        fail "Target write escape with opt-in (outside now: '$after', output: '$output')"
    fi
}

# Regression for the pre-skip behavior: apply used to die on the first refused
# symlinked override, aborting before later entries applied and before
# attributes were synced (an order-dependent partial state). Now the refused
# entry is skipped, the rest apply, and attributes are synced.
test_apply_skips_refused_symlink_and_applies_rest() {
    info "Testing apply skips refused symlink and applies the rest..."

    cd "$TEST_REPO"
    create_config

    local outside_file="$CURRENT_TEST_ROOT/external-canonical.md"
    echo "# EXTERNAL CANONICAL" > "$outside_file"

    # First config entry: symlinked override, opt-in off -> refused.
    rm -f CLAUDE.local.md
    ln -s "$outside_file" CLAUDE.local.md
    # Second config entry: regular override -> must still apply.
    echo "# LOCAL AGENTS CONTENT" > AGENTS.local.md

    local output
    local exit_code=0
    output=$(git-local-override apply 2>&1) || exit_code=$?

    local attributes_file
    attributes_file="$(git rev-parse --git-path info/attributes)"

    if [[ $exit_code -eq 0 ]] \
       && [[ "$output" == *"refusing symlinked override"* ]] \
       && grep -q "Original CLAUDE.md content" CLAUDE.md \
       && grep -q "LOCAL AGENTS CONTENT" AGENTS.md \
       && grep -q "^CLAUDE.md filter=local-override" "$attributes_file" \
       && grep -q "^AGENTS.md filter=local-override" "$attributes_file"; then
        pass "Apply skipped the refused symlink and applied the remaining override"
    else
        fail "Apply partial-skip wrong (exit: $exit_code, output: '$output', CLAUDE: '$(cat CLAUDE.md)', AGENTS: '$(cat AGENTS.md)')"
    fi
}

test_add_preserves_existing_symlink_override_with_optin() {
    info "Testing add keeps an existing symlinked override with opt-in..."

    cd "$TEST_REPO"
    create_config
    git config local-override.followSymlinkedOverrides true

    local outside_file="$CURRENT_TEST_ROOT/external-canonical.md"
    echo "# EXTERNAL CANONICAL" > "$outside_file"

    rm -f CLAUDE.local.md
    ln -s "$outside_file" CLAUDE.local.md

    local output
    local exit_code=0
    output=$(git-local-override add CLAUDE.md 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 ]] \
       && [[ "$output" == *"already exists"* ]] \
       && [[ -L CLAUDE.local.md ]] \
       && grep -q "EXTERNAL CANONICAL" CLAUDE.md; then
        pass "add preserved the symlink and applied its content"
    else
        fail "add mishandled symlinked override (exit: $exit_code, output: '$output')"
    fi
}

test_symlink_override_filter_roundtrip_with_optin() {
    info "Testing smudge/clean roundtrip through symlinked override with opt-in..."

    cd "$TEST_REPO"
    create_config
    git config local-override.followSymlinkedOverrides true

    local outside_file="$CURRENT_TEST_ROOT/external-canonical.md"
    echo "# EXTERNAL CANONICAL" > "$outside_file"

    rm -f CLAUDE.local.md
    ln -s "$outside_file" CLAUDE.local.md

    local smudge_script=".git/hooks/local-override-filter-smudge"
    local clean_script=".git/hooks/local-override-filter-clean"

    local original="$CURRENT_TEST_ROOT/artifacts/original.txt"
    local smudged="$CURRENT_TEST_ROOT/artifacts/smudged.txt"
    local cleaned="$CURRENT_TEST_ROOT/artifacts/cleaned.txt"
    mkdir -p "$CURRENT_TEST_ROOT/artifacts"

    git show HEAD:CLAUDE.md > "$original"
    "$smudge_script" CLAUDE.md < "$original" > "$smudged"
    "$clean_script" CLAUDE.md < "$smudged" > "$cleaned"

    if cmp -s "$smudged" "$outside_file" && cmp -s "$cleaned" "$original"; then
        pass "clean(smudge(original)) == original through symlinked override"
    else
        fail "Roundtrip broke (smudged: '$(cat "$smudged")', cleaned: '$(cat "$cleaned")')"
    fi
}

test_symlink_override_post_commit_reapply_with_optin() {
    info "Testing pre-commit restore + post-commit reapply through symlink..."

    cd "$TEST_REPO"
    create_config
    git config local-override.followSymlinkedOverrides true

    local outside_file="$CURRENT_TEST_ROOT/external-canonical.md"
    echo "# EXTERNAL CANONICAL" > "$outside_file"

    rm -f CLAUDE.local.md
    ln -s "$outside_file" CLAUDE.local.md

    git-local-override apply > /dev/null 2>&1

    # Stage the overridden target, then drive the commit-time hook pair the
    # way git would.
    git add CLAUDE.md
    .git/hooks/pre-commit > /dev/null 2>&1

    local restored=""
    if grep -q "Original CLAUDE.md content" CLAUDE.md; then
        restored="yes"
    fi

    .git/hooks/post-commit > /dev/null 2>&1

    if [[ "$restored" == "yes" ]] && grep -q "EXTERNAL CANONICAL" CLAUDE.md; then
        pass "Original restored at commit, symlinked override reapplied after"
    else
        fail "Commit flow broke (restored: '$restored', now: '$(cat CLAUDE.md)')"
    fi
}

# SEC-01 regression: an override path traversing a repo-shipped SYMLINKED
# PARENT dir (x -> outside) must be refused by the smudge core regardless of
# the symlink opt-in — the final component is a regular file, so the opt-in
# (which covers only the override file itself) never applies.
test_smudge_refuses_parent_symlinked_override() {
    info "Testing smudge refuses override behind a symlinked parent dir..."

    cd "$TEST_REPO"

    # Outside-repo directory holding the sentinel the attacker wants leaked.
    local outside_dir="$CURRENT_TEST_ROOT/outside-dir"
    mkdir -p "$outside_dir"
    echo "OUTSIDE PARENT SECRET" > "$outside_dir/secret"

    # Repo-shipped symlinked parent dir: the override path traverses it.
    ln -s "$outside_dir" x
    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: x/secret
    replaces:
      - CLAUDE.md
EOF

    local smudge_script=".git/hooks/local-override-filter-smudge"
    local artifacts="$CURRENT_TEST_ROOT/artifacts"
    mkdir -p "$artifacts"
    local original="$artifacts/original.txt"
    local smudged_off="$artifacts/smudged-optin-off.txt"
    local smudged_on="$artifacts/smudged-optin-on.txt"

    git show HEAD:CLAUDE.md > "$original"

    # Expected: passthrough (the tracked blob), with opt-in BOTH off and on.
    "$smudge_script" CLAUDE.md < "$original" > "$smudged_off"
    git config local-override.followSymlinkedOverrides true
    "$smudge_script" CLAUDE.md < "$original" > "$smudged_on"

    rm -f x

    if cmp -s "$smudged_off" "$original" && cmp -s "$smudged_on" "$original"; then
        pass "Parent-symlinked override refused by smudge with opt-in off and on"
    else
        fail "Smudge leaked content behind a symlinked parent dir (off: '$(cat "$smudged_off")', on: '$(cat "$smudged_on")')"
    fi
}

# Clean-side counterpart of the SEC-01 regression: working-tree stdin equal to
# the outside content must NOT be recognized as the override (which would
# substitute index content) — it must pass through unchanged.
test_clean_refuses_parent_symlinked_override() {
    info "Testing clean refuses override behind a symlinked parent dir..."

    cd "$TEST_REPO"

    local outside_dir="$CURRENT_TEST_ROOT/outside-dir"
    mkdir -p "$outside_dir"
    echo "OUTSIDE PARENT SECRET" > "$outside_dir/secret"

    ln -s "$outside_dir" x
    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: x/secret
    replaces:
      - CLAUDE.md
EOF

    local clean_script=".git/hooks/local-override-filter-clean"
    local artifacts="$CURRENT_TEST_ROOT/artifacts"
    mkdir -p "$artifacts"
    local sentinel_in="$artifacts/sentinel-in.txt"
    local cleaned_off="$artifacts/cleaned-optin-off.txt"
    local cleaned_on="$artifacts/cleaned-optin-on.txt"

    cp "$outside_dir/secret" "$sentinel_in"

    # Expected: output == sentinel input unchanged, opt-in BOTH off and on.
    "$clean_script" CLAUDE.md < "$sentinel_in" > "$cleaned_off"
    git config local-override.followSymlinkedOverrides true
    "$clean_script" CLAUDE.md < "$sentinel_in" > "$cleaned_on"

    rm -f x

    if cmp -s "$cleaned_off" "$sentinel_in" && cmp -s "$cleaned_on" "$sentinel_in"; then
        pass "Parent-symlinked override refused by clean with opt-in off and on"
    else
        fail "Clean substituted index content behind a symlinked parent dir"
    fi
}

# Reapply-side SEC-01 regression: a state entry whose absolute override path
# traverses a symlinked parent dir must be refused, leaving the target intact.
test_post_commit_reapply_refuses_parent_symlinked_override() {
    info "Testing reapply refuses override behind a symlinked parent dir..."

    cd "$TEST_REPO"

    local outside_dir="$CURRENT_TEST_ROOT/outside-dir"
    mkdir -p "$outside_dir"
    echo "OUTSIDE PARENT SECRET" > "$outside_dir/secret"
    ln -s "$outside_dir" x

    local artifacts="$CURRENT_TEST_ROOT/artifacts"
    mkdir -p "$artifacts"
    local target_before="$artifacts/target-before.txt"
    cp CLAUDE.md "$target_before"

    # Seed the reapply state file the way pre-commit would (absolute override
    # anchored at the resolution root), traversing the symlinked parent dir.
    local resolution_root state_file
    resolution_root="$(
        # shellcheck disable=SC1091
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        get_resolution_root "$TEST_REPO"
    )"
    state_file="$(git rev-parse --absolute-git-dir)/local-override-post-commit-state"

    # Quiet by default: the refusal must not print on a normal commit.
    printf 'CLAUDE.md|%s/x/secret\n' "$resolution_root" > "$state_file"
    local output_quiet
    output_quiet=$(.git/hooks/post-commit 2>&1) || true

    # Under trace, the refusal is still observable (and still refused).
    printf 'CLAUDE.md|%s/x/secret\n' "$resolution_root" > "$state_file"
    local output_trace
    output_trace=$(GIT_LOCAL_OVERRIDE_TRACE=1 .git/hooks/post-commit 2>&1) || true

    rm -f x

    if cmp -s CLAUDE.md "$target_before" \
       && [[ "$output_quiet" != *"refusing symlinked"* ]] \
       && [[ "$output_trace" == *"refusing symlinked override"* ]]; then
        pass "Reapply refused the parent-symlinked override; target untouched"
    else
        fail "Reapply refusal wrong (quiet: '$output_quiet', trace: '$output_trace', now: '$(cat CLAUDE.md)')"
    fi
}

# GATE-01 positive: the post-checkout cp-apply loop now uses the opt-in-aware
# override gate, so an untracked user-created symlinked override is applied
# with the opt-in ON (matching the filters) and still refused with it OFF.
test_post_checkout_applies_optin_symlinked_override() {
    info "Testing post-checkout applies opt-in symlinked override..."

    cd "$TEST_REPO"
    create_config

    local outside_file="$CURRENT_TEST_ROOT/external-canonical.md"
    echo "# EXTERNAL CANONICAL" > "$outside_file"

    rm -f CLAUDE.local.md
    ln -s "$outside_file" CLAUDE.local.md

    local artifacts="$CURRENT_TEST_ROOT/artifacts"
    mkdir -p "$artifacts"
    local original="$artifacts/claude-original.txt"
    cp CLAUDE.md "$original"

    # Opt-in OFF: the symlinked override must NOT be applied. (The write-side
    # front door distinguishes override refusals from target refusals.)
    local output_off
    output_off=$(.git/hooks/post-checkout "" "" "1" 2>&1) || true
    local off_ok=""
    if cmp -s CLAUDE.md "$original" \
       && [[ "$output_off" == *"refusing symlinked override"* ]]; then
        off_ok="yes"
    fi

    # Opt-in ON: post-checkout follows the untracked symlinked override.
    git config local-override.followSymlinkedOverrides true
    .git/hooks/post-checkout "" "" "1" > /dev/null 2>&1 || true

    if [[ "$off_ok" == "yes" ]] && cmp -s CLAUDE.md "$outside_file"; then
        pass "Post-checkout honors the symlink opt-in (refused off, applied on)"
    else
        fail "Post-checkout opt-in handling wrong (off_ok: '$off_ok', now: '$(cat CLAUDE.md)')"
    fi
}

test_list_marks_symlinked_override() {
    info "Testing list marks symlinked overrides..."

    cd "$TEST_REPO"
    create_config

    local outside_file="$CURRENT_TEST_ROOT/external-canonical.md"
    echo "# EXTERNAL CANONICAL" > "$outside_file"

    rm -f CLAUDE.local.md
    ln -s "$outside_file" CLAUDE.local.md

    local without_optin
    without_optin=$(git-local-override list 2>&1)

    git config local-override.followSymlinkedOverrides true
    local with_optin
    with_optin=$(git-local-override list 2>&1)

    if [[ "$without_optin" == *"[symlink ignored]"* ]] \
       && [[ "$without_optin" == *"(symlink)"* ]] \
       && [[ "$with_optin" == *"[active]"* ]] \
       && [[ "$with_optin" == *"(symlink)"* ]]; then
        pass "list shows symlink marker and ignored/active state"
    else
        fail "list output wrong (no opt-in: '$without_optin'; opt-in: '$with_optin')"
    fi
}

test_doctor_warns_symlinked_override_without_optin() {
    info "Testing doctor surfaces the symlink opt-in hint..."

    cd "$TEST_REPO"
    create_config

    local outside_file="$CURRENT_TEST_ROOT/external-canonical.md"
    echo "# EXTERNAL CANONICAL" > "$outside_file"

    rm -f CLAUDE.local.md
    ln -s "$outside_file" CLAUDE.local.md

    # Make the repo otherwise healthy so warns are the only signal.
    git-local-override sync-filters > /dev/null 2>&1

    local output
    local exit_code=0
    output=$(git-local-override doctor 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 ]] \
       && [[ "$output" == *"followSymlinkedOverrides"* ]] \
       && [[ "$output" == *"ignored"* ]]; then
        pass "doctor warns with the exact opt-in command"
    else
        fail "doctor missing symlink hint (exit: $exit_code, output: '$output')"
    fi
}

test_recursive_three_level_nearest_config_wins() {
    info "Testing three-level nearest config ownership..."

    cd "$TEST_REPO"

    mkdir -p backend/services/foo

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    cat > backend/.local-overrides.yaml << 'EOF'
pattern: ".private"
files:
  - override: CLAUDE.private.md
    replaces:
      - CLAUDE.md
EOF

    cat > backend/services/.local-overrides.yaml << 'EOF'
pattern: ".deep"
files:
  - override: CLAUDE.deep.md
    replaces:
      - foo/CLAUDE.md
EOF

    echo "# ROOT LOCAL" > CLAUDE.local.md
    echo "# BACKEND PRIVATE" > backend/CLAUDE.private.md
    echo "# SERVICES DEEP" > backend/services/CLAUDE.deep.md
    echo "# Original backend CLAUDE" > backend/CLAUDE.md
    echo "# Original foo CLAUDE" > backend/services/foo/CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add \
        backend/CLAUDE.md \
        backend/services/foo/CLAUDE.md \
        .local-overrides.yaml \
        backend/.local-overrides.yaml \
        backend/services/.local-overrides.yaml

    git-local-override apply >/dev/null

    if grep -q "ROOT LOCAL" CLAUDE.md && \
       grep -q "BACKEND PRIVATE" backend/CLAUDE.md && \
       grep -q "SERVICES DEEP" backend/services/foo/CLAUDE.md; then
        pass "Nearest config wins across three levels"
    else
        fail "Three-level ownership did not apply expected overrides"
    fi
}

test_recursive_three_level_add_uses_nearest_pattern() {
    info "Testing add uses nearest pattern across three levels..."

    cd "$TEST_REPO"

    mkdir -p backend/services/foo

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    cat > backend/.local-overrides.yaml << 'EOF'
pattern: ".private"
files:
  - override: CLAUDE.private.md
    replaces:
      - CLAUDE.md
EOF

    cat > backend/services/.local-overrides.yaml << 'EOF'
pattern: ".deep"
files:
  - override: AGENTS.deep.md
    replaces:
      - foo/AGENTS.md
EOF

    echo "# Deep nested target" > backend/services/foo/CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add \
        backend/services/foo/CLAUDE.md \
        .local-overrides.yaml \
        backend/.local-overrides.yaml \
        backend/services/.local-overrides.yaml

    git-local-override add backend/services/foo/CLAUDE.md >/dev/null 2>&1 || true

    if [[ -f "backend/services/foo/CLAUDE.deep.md" ]]; then
        pass "Add uses nearest pattern across three levels"
    else
        fail "Add did not use nearest pattern across three levels"
    fi
}

test_recursive_empty_child_blocks_parent_targets() {
    info "Testing empty child config blocks parent subtree targets..."

    cd "$TEST_REPO"

    mkdir -p backend

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
  - override: backend/CLAUDE.local.md
    replaces:
      - backend/CLAUDE.md
EOF

    cat > backend/.local-overrides.yaml << 'EOF'
pattern: ".private"
EOF

    local output
    local exit_code=0
    output=$(git-local-override list 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 && "$output" == *"belongs to a child subtree config"* ]]; then
        pass "Empty child config blocks parent subtree targets"
    else
        fail "Expected empty child config to block parent subtree targets (exit: $exit_code, output: $output)"
    fi
}

test_recursive_empty_child_still_allows_deeper_config() {
    info "Testing empty child config still allows deeper ownership..."

    cd "$TEST_REPO"

    mkdir -p backend/services/foo

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    cat > backend/.local-overrides.yaml << 'EOF'
pattern: ".private"
EOF

    cat > backend/services/.local-overrides.yaml << 'EOF'
pattern: ".deep"
files:
  - override: CLAUDE.deep.md
    replaces:
      - foo/CLAUDE.md
EOF

    echo "# ROOT LOCAL" > CLAUDE.local.md
    echo "# SERVICES DEEP" > backend/services/CLAUDE.deep.md
    echo "# Original foo CLAUDE" > backend/services/foo/CLAUDE.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add \
        backend/services/foo/CLAUDE.md \
        .local-overrides.yaml \
        backend/.local-overrides.yaml \
        backend/services/.local-overrides.yaml

    git-local-override apply >/dev/null

    if grep -q "ROOT LOCAL" CLAUDE.md && grep -q "SERVICES DEEP" backend/services/foo/CLAUDE.md; then
        pass "Empty child config still allows deeper config ownership"
    else
        fail "Deeper config did not apply beneath empty child config"
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

test_filter_smudge_single_git_spawn() {
    info "Testing smudge filter establishes git context with a single rev-parse spawn..."
    cd "$TEST_REPO"
    create_config

    local smudge_script=".git/hooks/local-override-filter-smudge"
    if [[ ! -f "$smudge_script" ]]; then
        fail "Smudge filter script not found"
        return
    fi

    echo "# LOCAL SMUDGE CONTENT" > CLAUDE.local.md

    # Resolve the real git BEFORE putting the shim on PATH so the shim can exec it.
    local real_git
    real_git="$(command -v git)"

    local shim_dir="$CURRENT_TEST_ROOT/git-shim"
    local git_log="$CURRENT_TEST_ROOT/git-calls.log"
    mkdir -p "$shim_dir"
    : > "$git_log"

    cat > "$shim_dir/git" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$git_log"
exec "$real_git" "\$@"
EOF
    chmod +x "$shim_dir/git"

    # Run with cwd = repo top, matching git's filter cwd.
    printf 'blob\n' | PATH="$shim_dir:$PATH" "$smudge_script" CLAUDE.md > /dev/null

    local rev_parse_count
    rev_parse_count="$(grep -c 'rev-parse' "$git_log" 2>/dev/null || true)"

    if [[ "$rev_parse_count" == "1" ]]; then
        pass "Smudge filter spawns exactly one git rev-parse"
    else
        fail "Expected exactly 1 rev-parse spawn, got $rev_parse_count (log: $(tr '\n' '|' < "$git_log"))"
    fi
}

test_filter_smudge_trace_env_var() {
    info "Testing smudge filter trace logging when GIT_LOCAL_OVERRIDE_TRACE=1..."
    cd "$TEST_REPO"
    create_config

    local smudge_script=".git/hooks/local-override-filter-smudge"

    if [[ ! -f "$smudge_script" ]]; then
        fail "Smudge filter script not found"
        return
    fi

    echo "# LOCAL TRACE CONTENT" > CLAUDE.local.md

    local stdout_file="$CURRENT_TEST_ROOT/smudge-trace.stdout"
    local stderr_file="$CURRENT_TEST_ROOT/smudge-trace.stderr"
    printf '# Original content from git\n' | GIT_LOCAL_OVERRIDE_TRACE=1 "$smudge_script" CLAUDE.md > "$stdout_file" 2> "$stderr_file"

    if grep -q "LOCAL TRACE CONTENT" "$stdout_file" &&
       grep -q "git-local-override: filter-smudge CLAUDE.md started" "$stderr_file" &&
       grep -q "git-local-override: filter-smudge CLAUDE.md finished" "$stderr_file"; then
        pass "Smudge filter trace logs go to stderr"
    else
        fail "Smudge filter trace logging missing or redirected incorrectly"
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

run_filter_roundtrip_file_case() {
    # Drive the real substitution path through files, compared with cmp.
    # Never capture filter output via $(...): command substitution strips
    # trailing newlines and cannot carry NUL bytes, which is exactly the
    # blind spot these cases close.
    #
    # $1 = label, $2 = committed target path, $3 = override file path,
    # $4 = file holding the exact tracked blob bytes
    local label="$1"
    local target="$2"
    local override="$3"
    local original="$4"

    local smudge_script=".git/hooks/local-override-filter-smudge"
    local clean_script=".git/hooks/local-override-filter-clean"
    local smudged="$TEST_ARTIFACTS_DIR/roundtrip-smudged"
    local cleaned="$TEST_ARTIFACTS_DIR/roundtrip-cleaned"

    info "Testing file-based filter roundtrip: $label..."

    # Setup sanity: the committed blob must hold the exact original bytes,
    # otherwise the roundtrip comparison below would be meaningless.
    if ! git show ":$target" | cmp -s - "$original"; then
        fail "Setup: committed blob for $label does not match original bytes"
        return
    fi

    "$smudge_script" "$target" < "$original" > "$smudged"
    "$clean_script" "$target" < "$smudged" > "$cleaned"

    # Confirm smudge substituted (not passthrough) so clean exercises its
    # real cmp-gated substitution path rather than trivially passing through.
    if ! cmp -s "$smudged" "$override"; then
        fail "Smudge did not emit override bytes for $label ($(cmp "$smudged" "$override" 2>&1 || true))"
        rm -f "$smudged" "$cleaned"
        return
    fi

    if cmp -s "$cleaned" "$original"; then
        pass "Roundtrip preserves $label byte-for-byte"
    else
        fail "Roundtrip corrupted $label ($(cmp "$cleaned" "$original" 2>&1 || true))"
    fi

    rm -f "$smudged" "$cleaned"
}

test_filter_roundtrip_content_variants() {
    cd "$TEST_REPO"

    local smudge_script=".git/hooks/local-override-filter-smudge"
    local clean_script=".git/hooks/local-override-filter-clean"

    if [[ ! -f "$smudge_script" || ! -f "$clean_script" ]]; then
        info "Testing file-based filter roundtrip content variants..."
        fail "Filter scripts not found"
        return
    fi

    # Keep committed bytes exactly as written (CRLF case must not be
    # normalized on add).
    git config core.autocrlf false

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: rt-binary.local.bin
    replaces:
      - rt-binary.bin
  - override: rt-crlf.local.txt
    replaces:
      - rt-crlf.txt
  - override: rt-empty-blob.local.txt
    replaces:
      - rt-empty-blob.txt
  - override: rt-empty-override.local.txt
    replaces:
      - rt-empty-override.txt
  - override: rt-no-newline.local.txt
    replaces:
      - rt-no-newline.txt
  - override: rt-multi-newline.local.txt
    replaces:
      - rt-multi-newline.txt
EOF

    # Exact tracked-blob bytes for each case, kept outside the repo so the
    # roundtrip result can be cmp-compared against untouched reference files.
    local originals_dir="$TEST_ARTIFACTS_DIR/roundtrip-originals"
    mkdir -p "$originals_dir"

    printf 'a\0b\0c' > "$originals_dir/binary"
    printf 'line1\r\nline2\r\n' > "$originals_dir/crlf"
    : > "$originals_dir/empty-blob"
    printf 'tracked content\n' > "$originals_dir/empty-override"
    printf 'no trailing newline' > "$originals_dir/no-newline"
    printf 'x\n\n\n' > "$originals_dir/multi-newline"

    cp "$originals_dir/binary" rt-binary.bin
    cp "$originals_dir/crlf" rt-crlf.txt
    cp "$originals_dir/empty-blob" rt-empty-blob.txt
    cp "$originals_dir/empty-override" rt-empty-override.txt
    cp "$originals_dir/no-newline" rt-no-newline.txt
    cp "$originals_dir/multi-newline" rt-multi-newline.txt

    # Commit the targets before creating any override files so the hooks
    # see no active overrides and the canonical bytes land in the index.
    git add .local-overrides.yaml \
        rt-binary.bin rt-crlf.txt rt-empty-blob.txt \
        rt-empty-override.txt rt-no-newline.txt rt-multi-newline.txt
    git commit -q -m "Add roundtrip content variant targets"

    # Overrides carry the hazardous byte patterns too: a binary/CRLF/empty/
    # newline-less override is a distinct hazard from a tracked blob with
    # the same shape, and both sides must survive the roundtrip.
    printf 'x\0y\0local' > rt-binary.local.bin
    printf 'local1\r\nlocal2\r\n' > rt-crlf.local.txt
    printf 'local override content\n' > rt-empty-blob.local.txt
    : > rt-empty-override.local.txt
    printf 'local no trailing newline' > rt-no-newline.local.txt
    printf 'y\n\n\n\n' > rt-multi-newline.local.txt

    run_filter_roundtrip_file_case "binary content with NUL bytes" \
        rt-binary.bin rt-binary.local.bin "$originals_dir/binary"
    run_filter_roundtrip_file_case "CRLF line endings" \
        rt-crlf.txt rt-crlf.local.txt "$originals_dir/crlf"
    run_filter_roundtrip_file_case "empty tracked blob" \
        rt-empty-blob.txt rt-empty-blob.local.txt "$originals_dir/empty-blob"
    run_filter_roundtrip_file_case "empty override file" \
        rt-empty-override.txt rt-empty-override.local.txt "$originals_dir/empty-override"
    run_filter_roundtrip_file_case "content without trailing newline" \
        rt-no-newline.txt rt-no-newline.local.txt "$originals_dir/no-newline"
    run_filter_roundtrip_file_case "multiple trailing newlines" \
        rt-multi-newline.txt rt-multi-newline.local.txt "$originals_dir/multi-newline"
}

test_filter_cli_matches_hook() {
    # Anti-drift guard: the CLI subcommands (git-local-override filter-smudge/
    # filter-clean) and the git-invoked hook scripts share one implementation
    # in the resolver, so they MUST produce byte-identical stdout for the same
    # input. Compare with file-based cmp (never $(...), which strips trailing
    # newlines / NUL and would hide a real byte-level divergence).
    info "Testing CLI filter subcommands match hook scripts byte-for-byte..."
    cd "$TEST_REPO"

    local smudge_script=".git/hooks/local-override-filter-smudge"
    local clean_script=".git/hooks/local-override-filter-clean"

    if [[ ! -f "$smudge_script" || ! -f "$clean_script" ]]; then
        fail "Filter scripts not found"
        return
    fi

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: cli-hook.local.md
    replaces:
      - cli-hook.md
EOF

    printf '# tracked cli-hook content\nsecond line\n' > cli-hook.md
    git add .local-overrides.yaml cli-hook.md
    git commit -q -m "Add cli-hook parity target"

    printf '# LOCAL cli-hook override\nno trailing newline' > cli-hook.local.md

    local input_override="$TEST_ARTIFACTS_DIR/cli-hook-input-override"
    local input_other="$TEST_ARTIFACTS_DIR/cli-hook-input-other"
    cp cli-hook.local.md "$input_override"
    printf 'unrelated working-tree bytes\0with NUL' > "$input_other"

    local cli_out="$TEST_ARTIFACTS_DIR/cli-hook-cli.out"
    local hook_out="$TEST_ARTIFACTS_DIR/cli-hook-hook.out"
    local mismatch=0

    # Smudge: override active (substitutes) and no-override case (passthrough).
    git-local-override filter-smudge cli-hook.md < cli-hook.md > "$cli_out"
    "$smudge_script" cli-hook.md < cli-hook.md > "$hook_out"
    if ! cmp -s "$cli_out" "$hook_out"; then
        fail "smudge (override active) diverged ($(cmp "$cli_out" "$hook_out" 2>&1 || true))"
        mismatch=1
    fi

    git-local-override filter-smudge unmanaged.md < cli-hook.md > "$cli_out"
    "$smudge_script" unmanaged.md < cli-hook.md > "$hook_out"
    if ! cmp -s "$cli_out" "$hook_out"; then
        fail "smudge (passthrough) diverged ($(cmp "$cli_out" "$hook_out" 2>&1 || true))"
        mismatch=1
    fi

    # Clean: input equals override (substitutes index) and non-matching input
    # (passthrough).
    git-local-override filter-clean cli-hook.md < "$input_override" > "$cli_out"
    "$clean_script" cli-hook.md < "$input_override" > "$hook_out"
    if ! cmp -s "$cli_out" "$hook_out"; then
        fail "clean (substitute) diverged ($(cmp "$cli_out" "$hook_out" 2>&1 || true))"
        mismatch=1
    fi

    git-local-override filter-clean cli-hook.md < "$input_other" > "$cli_out"
    "$clean_script" cli-hook.md < "$input_other" > "$hook_out"
    if ! cmp -s "$cli_out" "$hook_out"; then
        fail "clean (passthrough) diverged ($(cmp "$cli_out" "$hook_out" 2>&1 || true))"
        mismatch=1
    fi

    if [[ "$mismatch" -eq 0 ]]; then
        pass "CLI filter subcommands match hook scripts byte-for-byte"
    fi

    rm -f "$input_override" "$input_other" "$cli_out" "$hook_out" cli-hook.local.md
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

test_doctor_reports_healthy() {
    info "Testing doctor reports a healthy repo (all pass, exit 0)..."
    cd "$TEST_REPO"
    create_config

    # Hooks are installed by the harness; sync filters to make the repo healthy.
    git-local-override sync-filters >/dev/null

    local output
    local exit_code=0
    output=$(git-local-override doctor 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 \
        && "$output" == *"[PASS] Filter driver"* \
        && "$output" == *"0 failed"* ]]; then
        pass "doctor reports healthy repo with exit 0"
    else
        fail "doctor did not report healthy (exit: $exit_code, output: $output)"
    fi
}

test_doctor_detects_missing_filter() {
    info "Testing doctor detects a missing filter driver (exit non-zero)..."
    cd "$TEST_REPO"
    create_config
    git-local-override sync-filters >/dev/null

    # Break the repo: remove the filter driver configuration.
    git config --local --unset-all filter.local-override.smudge 2>/dev/null || true
    git config --local --unset-all filter.local-override.clean 2>/dev/null || true

    local output
    local exit_code=0
    output=$(git-local-override doctor 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 \
        && "$output" == *"[FAIL] Filter driver"* \
        && "$output" == *"1 failed"* ]]; then
        pass "doctor detects missing filter driver and exits non-zero"
    else
        fail "doctor did not detect missing filter (exit: $exit_code, output: $output)"
    fi
}

test_doctor_fix_repairs_filter() {
    info "Testing doctor --fix repairs the filter driver via sync-filters..."
    cd "$TEST_REPO"
    create_config
    git-local-override sync-filters >/dev/null

    # Break the repo, then repair with --fix.
    git config --local --unset-all filter.local-override.smudge 2>/dev/null || true
    git config --local --unset-all filter.local-override.clean 2>/dev/null || true

    git-local-override doctor --fix >/dev/null 2>&1

    # A second doctor run should now report healthy.
    local output
    local exit_code=0
    output=$(git-local-override doctor 2>&1) || exit_code=$?

    local smudge_cmd
    smudge_cmd=$(git config --local filter.local-override.smudge 2>/dev/null || echo "")

    if [[ $exit_code -eq 0 \
        && -n "$smudge_cmd" \
        && "$output" == *"[PASS] Filter driver"* ]]; then
        pass "doctor --fix repairs filter driver and re-check is healthy"
    else
        fail "doctor --fix did not repair filter (exit: $exit_code, smudge: $smudge_cmd, output: $output)"
    fi
}

test_doctor_fix_resyncs_drifted_attributes() {
    info "Testing doctor --fix resyncs drifted attributes..."
    cd "$TEST_REPO"
    create_config
    git-local-override sync-filters >/dev/null

    # Drift: driver stays configured, but the managed attribute lines vanish.
    local attributes_file
    attributes_file="$(git rev-parse --git-path info/attributes)"
    : > "$attributes_file"

    local output
    local exit_code=0
    output=$(git-local-override doctor --fix 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 \
        && "$output" == *"out of sync"*"repairing via sync-filters"* \
        && "$(grep -c "filter=local-override" "$attributes_file")" -eq 3 ]]; then
        pass "doctor --fix resynced attributes with exit 0"
    else
        fail "doctor --fix did not resync attributes (exit: $exit_code, lines: $(grep -c "filter=local-override" "$attributes_file" || true), output: $output)"
    fi
}

test_doctor_fix_clears_legacy_skip_worktree() {
    info "Testing doctor --fix clears legacy skip-worktree bits..."
    cd "$TEST_REPO"
    create_config
    git-local-override sync-filters >/dev/null

    # Plant a legacy skip-worktree bit on a tracked managed target.
    git update-index --skip-worktree CLAUDE.md

    local output
    local exit_code=0
    output=$(git-local-override doctor --fix 2>&1) || exit_code=$?

    local ls_state
    ls_state="$(git ls-files -v -- CLAUDE.md)"

    if [[ $exit_code -eq 0 \
        && "$output" == *"legacy bit(s) present"*"repairing via sync-filters"* \
        && "${ls_state:0:1}" != "S" ]]; then
        pass "doctor --fix cleared the legacy skip-worktree bit with exit 0"
    else
        fail "doctor --fix did not clear skip-worktree (exit: $exit_code, ls-files: $ls_state, output: $output)"
    fi
}

test_doctor_readonly_leaves_drift_unrepaired() {
    info "Testing plain doctor warns but does not repair attribute/skip-worktree drift..."
    cd "$TEST_REPO"
    create_config
    git-local-override sync-filters >/dev/null

    # Both fixable states at once: drifted attributes + a legacy bit.
    local attributes_file
    attributes_file="$(git rev-parse --git-path info/attributes)"
    : > "$attributes_file"
    git update-index --skip-worktree CLAUDE.md

    local output
    local exit_code=0
    output=$(git-local-override doctor 2>&1) || exit_code=$?

    local ls_state
    ls_state="$(git ls-files -v -- CLAUDE.md)"

    # Warns only (exit 0 = no FAIL), hints printed, and nothing mutated:
    # attributes stay empty and the skip-worktree bit stays set.
    if [[ $exit_code -eq 0 \
        && "$output" == *"[WARN] Attributes"* \
        && "$output" == *"[WARN] Skip-worktree"* \
        && "$output" == *"Run 'git-local-override sync-filters'"* \
        && ! -s "$attributes_file" \
        && "${ls_state:0:1}" == "S" ]]; then
        git update-index --no-skip-worktree CLAUDE.md
        pass "plain doctor warned for both states and repaired nothing"
    else
        git update-index --no-skip-worktree CLAUDE.md 2>/dev/null || true
        fail "plain doctor changed state or missed a warn (exit: $exit_code, ls-files: $ls_state, output: $output)"
    fi
}

test_dash_prefixed_target_not_option() {
    info "Testing dash-prefixed target is passed as a pathspec, not an option..."
    cd "$TEST_REPO"

    # Commit a target whose first path component begins with '-'
    mkdir -p -- '-weird'
    echo "# Original weird content" > './-weird/name.md'
    git add -- '-weird/name.md'
    git commit -q -m "Add dash-prefixed target"

    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: "-weird/name.local.md"
    replaces:
      - "-weird/name.md"
EOF

    echo "# LOCAL weird content" > './-weird/name.local.md'

    git-local-override sync-filters >/dev/null

    local output
    local exit_code=0
    output=$(git-local-override apply 2>&1) || exit_code=$?

    # The clean filter runs via 'git add -- <target>'; without the '--' the
    # add silently fails and git status keeps showing the target as modified.
    local status
    status=$(git status --porcelain -- '-weird/name.md')

    if [[ $exit_code -eq 0 && -z "$status" ]] && grep -q "LOCAL" './-weird/name.md'; then
        pass "Dash-prefixed target applied and re-staged as clean via git add --"
    else
        fail "Dash-prefixed target mishandled (exit: $exit_code, status: $status, output: $output)"
    fi
}

test_glob_char_repo_path_normalizes() {
    info "Testing absolute path normalization with glob chars in repo path..."

    # Create a standalone repo whose directory name contains glob chars
    local glob_repo="$TEST_ROOT/repo[1]"
    mkdir -p -- "$glob_repo"
    git -C "$glob_repo" init -q
    git -C "$glob_repo" config user.email "test@test.com"
    git -C "$glob_repo" config user.name "Test User"

    echo "# Original glob repo content" > "$glob_repo/CLAUDE.md"
    git -C "$glob_repo" add CLAUDE.md
    git -C "$glob_repo" commit -q -m "Initial commit"

    cat > "$glob_repo/.local-overrides.yaml" << 'EOF'
pattern: ".local"
files:
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    # Pass an absolute path (derived from the physical repo root so it matches
    # what get_repo_root returns); the repo-root prefix strip must treat the
    # repo path literally even though it contains [ and ].
    local glob_root
    glob_root="$(git -C "$glob_repo" rev-parse --show-toplevel)"

    local output
    local exit_code=0
    output=$(cd "$glob_repo" && git-local-override add "$glob_root/CLAUDE.md" 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 && -f "$glob_repo/CLAUDE.local.md" ]]; then
        pass "Absolute path normalized under glob-char repo path"
    else
        fail "add failed under glob-char repo path (exit: $exit_code, output: $output)"
    fi

    cd "$TEST_REPO"
}

test_die_does_not_leak_cache_temp_file() {
    info "Testing cache temp file is removed when a command dies..."
    cd "$TEST_REPO"

    # Invalid config: duplicate target makes validate_config fail after the
    # discovery cache temp file has been created.
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

    local leak_tmpdir="$TEST_ROOT/leak-tmp"
    mkdir -p "$leak_tmpdir"

    local exit_code=0
    TMPDIR="$leak_tmpdir" git-local-override list >/dev/null 2>&1 || exit_code=$?

    local leftover
    leftover=$(ls -A "$leak_tmpdir" 2>/dev/null | wc -l | tr -d ' ')

    if [[ $exit_code -ne 0 && "$leftover" == "0" ]]; then
        pass "No cache temp file leaked after failed command"
    else
        fail "Expected failure without leak (exit: $exit_code, leftover: $(ls -A "$leak_tmpdir" 2>/dev/null | tr '\n' ' '))"
    fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

# locate_support_file: the resolver-anchored fallback ladder must serve every
# layout — source checkout (shared/ sibling + checkout-root files), installed
# hooks dir (CLI data dir fallback) — and fail cleanly when a file is nowhere.
test_locate_support_file_ladder() {
    info "Testing locate_support_file fallback ladder..."

    local scratch="$CURRENT_TEST_ROOT/locate-support"
    mkdir -p "$scratch/devtree/shared" "$scratch/fakegit/hooks" \
        "$scratch/xdg/git-local-override"
    # The resolver canonicalizes its own directory (cd && pwd); canonicalize
    # the scratch root too so the expected paths compare byte-for-byte.
    scratch="$(cd "$scratch" && pwd)"

    cp "$PROJECT_DIR/shared/local-override-resolver.sh" "$scratch/devtree/shared/"
    cp "$PROJECT_DIR/shared/local-override-resolver.sh" "$scratch/fakegit/hooks/"
    echo "9.9.9-dev" > "$scratch/devtree/VERSION"
    echo "# dev shell init" > "$scratch/devtree/shared/local-override-shell-init.sh"
    echo "8.8.8-installed" > "$scratch/xdg/git-local-override/VERSION"

    # Source-checkout layout: VERSION resolves to the checkout root (ladder
    # step 2), shell-init to the shared/ sibling (step 1) — even when an
    # installed data-dir copy also exists, the checkout wins.
    local dev_version dev_shell_init
    dev_version="$(
        # shellcheck disable=SC1091
        source "$scratch/devtree/shared/local-override-resolver.sh"
        XDG_DATA_HOME="$scratch/xdg" locate_support_file VERSION
    )"
    dev_shell_init="$(
        # shellcheck disable=SC1091
        source "$scratch/devtree/shared/local-override-resolver.sh"
        locate_support_file local-override-shell-init.sh
    )"

    # Installed-hooks layout: nothing next to the resolver, so VERSION falls
    # through to the CLI data dir (step 3); a missing file returns 1.
    local hooks_version missing_status=0
    hooks_version="$(
        # shellcheck disable=SC1091
        source "$scratch/fakegit/hooks/local-override-resolver.sh"
        XDG_DATA_HOME="$scratch/xdg" locate_support_file VERSION
    )"
    (
        # shellcheck disable=SC1091
        source "$scratch/fakegit/hooks/local-override-resolver.sh"
        XDG_DATA_HOME="$scratch/xdg" locate_support_file no-such-file
    ) > /dev/null 2>&1 || missing_status=$?

    if [[ "$dev_version" == "$scratch/devtree/VERSION" \
       && "$dev_shell_init" == "$scratch/devtree/shared/local-override-shell-init.sh" \
       && "$hooks_version" == "$scratch/xdg/git-local-override/VERSION" \
       && "$missing_status" -ne 0 ]]; then
        pass "locate_support_file resolves each layout and fails cleanly"
    else
        fail "locate_support_file ladder wrong (dev VERSION: '$dev_version', dev shell-init: '$dev_shell_init', hooks VERSION: '$hooks_version', missing status: $missing_status)"
    fi
}

# apply_override_to_target is the write-side front door: one function owns
# the existence checks, both symlink gates, the resolution-root anchoring for
# absolute override paths, the copy, and the refusal logging. Pin its status
# contract: 0 applied, 1 skipped, 2 refused, plus loud-vs-trace verbosity.
test_apply_override_front_door_statuses() {
    info "Testing apply_override_to_target status contract..."

    cd "$TEST_REPO"
    create_config

    local root
    root="$(git rev-parse --show-toplevel)"

    echo "# FRONT DOOR CONTENT" > CLAUDE.local.md

    # 0: active override applies.
    local applied_status=0
    (
        # shellcheck disable=SC1091
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        apply_override_to_target "$root" "$root" CLAUDE.md CLAUDE.local.md loud
    ) || applied_status=$?

    # 1: missing override file is the normal inactive skip.
    local skipped_status=0
    (
        # shellcheck disable=SC1091
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        apply_override_to_target "$root" "$root" CLAUDE.md no-such.local.md loud
    ) || skipped_status=$?

    # 2 (loud): an absolute override outside the resolution root refuses on
    # anchoring, with one stderr line.
    local refused_status=0 refused_output=""
    refused_output="$(
        # shellcheck disable=SC1091
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        apply_override_to_target "$root" "$root" CLAUDE.md "$CURRENT_TEST_ROOT/outside.local.md" loud 2>&1
    )" || refused_status=$?

    # 2 (trace): the same refusal stays silent without GIT_LOCAL_OVERRIDE_TRACE.
    local quiet_status=0 quiet_output=""
    quiet_output="$(
        # shellcheck disable=SC1091
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        apply_override_to_target "$root" "$root" CLAUDE.md "$CURRENT_TEST_ROOT/outside.local.md" trace 2>&1
    )" || quiet_status=$?

    if [[ "$applied_status" -eq 0 ]] && grep -q "FRONT DOOR CONTENT" CLAUDE.md \
       && [[ "$skipped_status" -eq 1 ]] \
       && [[ "$refused_status" -eq 2 && "$refused_output" == *"refusing symlinked override"* ]] \
       && [[ "$quiet_status" -eq 2 && -z "$quiet_output" ]]; then
        pass "Front door statuses and verbosity behave as specified"
    else
        fail "Front door contract wrong (applied: $applied_status, skipped: $skipped_status, refused: $refused_status '$refused_output', quiet: $quiet_status '$quiet_output')"
    fi

    # Restore the tracked target for any later assertions.
    git checkout -q HEAD -- CLAUDE.md 2>/dev/null || true
}

# configure_filter_driver owns mode exclusivity: writing one mode must unset
# the other, so filter.local-override.* never claims both drivers at once.
test_configure_filter_driver_mode_exclusivity() {
    info "Testing configure_filter_driver mode exclusivity..."

    cd "$TEST_REPO"

    local checkout_root drv_dir
    checkout_root="$(git rev-parse --show-toplevel)"
    drv_dir="$(git rev-parse --git-common-dir)"
    [[ "$drv_dir" == /* ]] || drv_dir="$checkout_root/$drv_dir"
    drv_dir="$drv_dir/hooks"

    (
        # shellcheck disable=SC1091
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        configure_filter_driver "$checkout_root" "$drv_dir" process
    )
    local p_process p_smudge
    p_process="$(git config --local filter.local-override.process 2>/dev/null || echo "")"
    p_smudge="$(git config --local filter.local-override.smudge 2>/dev/null || echo "")"

    (
        # shellcheck disable=SC1091
        source "$PROJECT_DIR/shared/local-override-resolver.sh"
        configure_filter_driver "$checkout_root" "$drv_dir" scripts
    )
    local s_process s_smudge s_clean s_required
    s_process="$(git config --local filter.local-override.process 2>/dev/null || echo "")"
    s_smudge="$(git config --local filter.local-override.smudge 2>/dev/null || echo "")"
    s_clean="$(git config --local filter.local-override.clean 2>/dev/null || echo "")"
    s_required="$(git config --local filter.local-override.required 2>/dev/null || echo "")"

    if [[ "$p_process" == "$drv_dir/local-override-filter-process" && -z "$p_smudge" \
       && -z "$s_process" \
       && "$s_smudge" == "$drv_dir/local-override-filter-smudge %f" \
       && "$s_clean" == "$drv_dir/local-override-filter-clean %f" \
       && "$s_required" == "false" ]]; then
        pass "configure_filter_driver keeps the two modes mutually exclusive"
    else
        fail "Mode exclusivity wrong (process round: process='$p_process' smudge='$p_smudge'; scripts round: process='$s_process' smudge='$s_smudge' clean='$s_clean' required='$s_required')"
    fi
}

# sync-filters must preserve an existing local filter.process opt-in instead
# of writing scripts-mode config over it (which used to leave BOTH modes in
# the config, with process silently winning).
test_sync_filters_preserves_process_optin() {
    info "Testing sync-filters preserves the filter.process opt-in..."

    cd "$TEST_REPO"
    create_config

    local checkout_root drv_dir
    checkout_root="$(git rev-parse --show-toplevel)"
    drv_dir="$(git rev-parse --git-common-dir)"
    [[ "$drv_dir" == /* ]] || drv_dir="$checkout_root/$drv_dir"
    drv_dir="$drv_dir/hooks"

    git config --local filter.local-override.process "$drv_dir/local-override-filter-process"
    git config --local --unset-all filter.local-override.smudge 2>/dev/null || true
    git config --local --unset-all filter.local-override.clean 2>/dev/null || true

    local output
    output="$(git-local-override sync-filters 2>&1)" || {
        fail "sync-filters failed with a process opt-in configured: $output"
        return
    }

    local process smudge
    process="$(git config --local filter.local-override.process 2>/dev/null || echo "")"
    smudge="$(git config --local filter.local-override.smudge 2>/dev/null || echo "")"

    if [[ "$process" == "$drv_dir/local-override-filter-process" && -z "$smudge" \
       && "$output" == *"filter.process opt-in"* ]]; then
        pass "sync-filters preserved the process opt-in without adding scripts config"
    else
        fail "Process opt-in not preserved (process: '$process', smudge: '$smudge', output: $output)"
    fi
}

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
        test_cli_version \
        test_cli_version_flag \
        test_locate_support_file_ladder \
        test_apply_override_front_door_statuses \
        test_configure_filter_driver_mode_exclusivity \
        test_sync_filters_preserves_process_optin \
        test_init_config \
        test_list_no_config \
        test_add_override \
        test_override_is_applied \
        test_apply_shows_progress_output \
        test_apply_shows_nested_paths \
        test_apply_reports_no_active_overrides \
        test_apply_with_ignored_config_file \
        test_git_status_after_override \
        test_restore_originals \
        test_list_overrides \
        test_remove_override \
        test_remove_with_delete \
        test_nested_override \
        test_post_checkout_hook \
        test_post_checkout_hook_logs_lifecycle \
        test_pre_commit_hook \
        test_pre_commit_hook_restores_special_char_target \
        test_post_commit_hook \
        test_post_commit_hook_exits_without_state \
        test_pre_commit_trace_avoids_global_config_discovery \
        test_sync_attributes_entries_preserves_foreign_lines \
        test_sync_attributes_quotes_space_target \
        test_post_checkout_trace_falls_back_when_attributes_missing \
        test_post_checkout_trace_single_discovery_when_config_unchanged \
        test_post_checkout_falls_back_and_refreshes_attributes_when_config_changes \
        test_pre_rebase_trace_reuses_config_discovery_cache \
        test_discovery_full_finds_directly_ignored_config \
        test_discovery_skips_config_inside_ignored_dir \
        test_discovery_hot_mode_unions_stamped_paths \
        test_discovery_never_reads_git_dir_configs \
        test_new_gitignored_config_registered_by_sync_filters \
        test_readonly_cli_hot_discovery_on_matching_stamp \
        test_readonly_cli_falls_back_to_full_on_stamp_mismatch \
        test_readonly_cli_falls_back_to_full_on_stamp_deletion \
        test_readonly_cli_full_discovery_without_stamp \
        test_discover_config_files_hot_then_full \
        test_apply_writes_config_stamp \
        test_status_command \
        test_status_recognizes_filter_process_mode \
        test_status_in_worktree \
        test_status_detects_precommit_framework_hooks \
        test_status_shim_without_local_override_ids \
        test_status_empty_attributes_no_arithmetic_error \
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
        test_invalid_path_entry_fails_whole_config \
        test_valid_multi_entry_config_parses_fully \
        test_symlink_target_refused_on_apply \
        test_symlink_override_refused_on_smudge \
        test_symlink_guard_allows_regular_files \
        test_override_symlink_helper_decision_table \
        test_classify_symlinked_override \
        test_symlink_override_refused_without_optin_cli \
        test_symlink_override_followed_with_optin \
        test_tracked_symlink_override_refused_with_optin \
        test_dangling_symlink_override_treated_missing \
        test_symlink_target_still_refused_with_optin \
        test_apply_skips_refused_symlink_and_applies_rest \
        test_add_preserves_existing_symlink_override_with_optin \
        test_symlink_override_filter_roundtrip_with_optin \
        test_symlink_override_post_commit_reapply_with_optin \
        test_smudge_refuses_parent_symlinked_override \
        test_clean_refuses_parent_symlinked_override \
        test_post_commit_reapply_refuses_parent_symlinked_override \
        test_post_checkout_applies_optin_symlinked_override \
        test_list_marks_symlinked_override \
        test_doctor_warns_symlinked_override_without_optin \
        test_recursive_three_level_nearest_config_wins \
        test_recursive_three_level_add_uses_nearest_pattern \
        test_recursive_empty_child_blocks_parent_targets \
        test_recursive_empty_child_still_allows_deeper_config \
        test_missing_pattern_error \
        test_init_config_has_pattern \
        test_list_shows_pattern \
        test_multi_target_override \
        test_multi_target_pre_commit_restores_all \
        test_duplicate_target_error \
        test_validate_valid_config_passes \
        test_validate_duplicate_target_fails \
        test_validate_subtree_escape_rejected \
        test_validate_rejects_attr_macro_target \
        test_validate_rejects_wildcard_target \
        test_validate_no_config_dies \
        test_unknown_command_dies \
        test_outside_repo_dies \
        test_list_shows_grouped_targets \
        test_filter_smudge_applies_override \
        test_filter_smudge_passthrough \
        test_filter_smudge_single_git_spawn \
        test_filter_smudge_trace_env_var \
        test_filter_clean_returns_original \
        test_filter_clean_passthrough \
        test_filter_roundtrip \
        test_filter_roundtrip_content_variants \
        test_filter_cli_matches_hook \
        test_filter_disable_env_var \
        test_filter_no_head_passthrough \
        test_filter_non_configured_file_passthrough \
        test_sync_filters_migrates_legacy_hook_paths \
        test_doctor_reports_healthy \
        test_doctor_detects_missing_filter \
        test_doctor_fix_repairs_filter \
        test_doctor_fix_resyncs_drifted_attributes \
        test_doctor_fix_clears_legacy_skip_worktree \
        test_doctor_readonly_leaves_drift_unrepaired \
        test_dash_prefixed_target_not_option \
        test_glob_char_repo_path_normalizes \
        test_die_does_not_leak_cache_temp_file; do
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

    finish_suite
}

main "$@"
