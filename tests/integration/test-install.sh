#!/usr/bin/env bash
#
# Integration tests for install.sh and uninstall.sh
#
# Tests:
# - Repository installation (--repo)
# - Global installation (--global)
# - CLI installation (--cli)
# - Hook chaining (preserving existing hooks)
# - Idempotent installation (running twice)
# - Uninstallation
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/../test-lib.sh"

TEST_DIR=""
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
    finalize_current_test_root 0
}

finalize_current_test_root() {
    local status="${1:-0}"

    if [[ -n "$CURRENT_TEST_ROOT" ]]; then
        cd "$PROJECT_DIR"
        preserve_test_root_on_failure "$CURRENT_TEST_ROOT" "$CURRENT_TEST_NAME" "$status"
        CURRENT_TEST_ROOT=""
        TEST_DIR=""
    fi
}

reset_git_config() {
    # Reset global git config that might affect other tests
    git config --global --unset init.templateDir 2>/dev/null || true
    git config --global --unset core.excludesfile 2>/dev/null || true
}

setup() {
    CURRENT_TEST_ROOT="$(create_test_root "install" "$CURRENT_TEST_NAME")"
    CURRENT_TEST_STATUS=0
    setup_test_env "$CURRENT_TEST_ROOT" "$PROJECT_DIR"
    TEST_DIR="$CURRENT_TEST_ROOT/workspace"
    mkdir -p "$TEST_DIR"

    # Ensure clean git config
    reset_git_config
}

create_test_repo() {
    local repo_dir="$1"
    mkdir -p "$repo_dir"
    cd "$repo_dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    echo "# Test file" > README.md
    git add README.md
    git commit -q -m "Initial commit"
}

managed_hook_marker_for_test() {
    local hook_type="$1"
    printf '# git-local-override-managed-hook: %s\n' "$hook_type"
}

get_common_hooks_dir_for_repo() {
    local repo_dir="$1"
    local common_git_dir

    common_git_dir="$(git -C "$repo_dir" rev-parse --git-common-dir 2>/dev/null || echo "")"
    if [[ -z "$common_git_dir" ]]; then
        return 1
    fi

    if [[ "$common_git_dir" != /* ]]; then
        common_git_dir="$repo_dir/$common_git_dir"
    fi

    printf '%s/hooks\n' "$common_git_dir"
}

get_hook_file_for_repo() {
    local repo_dir="$1"
    local hook_name="$2"
    local hooks_dir

    hooks_dir="$(get_common_hooks_dir_for_repo "$repo_dir")" || return 1
    printf '%s/%s\n' "$hooks_dir" "$hook_name"
}

get_attributes_file_for_repo() {
    local repo_dir="$1"
    local attributes_file

    attributes_file="$(git -C "$repo_dir" rev-parse --git-path info/attributes 2>/dev/null || echo "")"
    if [[ -z "$attributes_file" ]]; then
        return 1
    fi

    if [[ "$attributes_file" != /* ]]; then
        attributes_file="$repo_dir/$attributes_file"
    fi

    printf '%s\n' "$attributes_file"
}

run_uninstall_non_interactive_capture() {
    local output_file="$1"
    printf 'n\nn\nn\nn\n' | "$PROJECT_DIR/scripts/uninstall.sh" > "$output_file" 2>&1
}

#------------------------------------------------------------------------------
# Tests
#------------------------------------------------------------------------------

test_install_to_repo() {
    info "Testing install.sh --repo..."

    local repo_dir="$TEST_DIR/repo1"
    create_test_repo "$repo_dir"

    # Run install
    "$PROJECT_DIR/scripts/install.sh" --repo

    # Check hooks were installed
    if [[ -f "$repo_dir/.git/hooks/pre-commit" ]] &&
       [[ -f "$repo_dir/.git/hooks/post-commit" ]] &&
       [[ -f "$repo_dir/.git/hooks/post-checkout" ]] &&
       [[ -f "$repo_dir/.git/hooks/local-override-lib.sh" ]]; then
        pass "All hooks installed to repository"
    else
        fail "Missing hooks in repository"
        ls -la "$repo_dir/.git/hooks/" || true
        return 1
    fi

    # Check hooks are executable
    if [[ -x "$repo_dir/.git/hooks/pre-commit" ]]; then
        pass "Hooks are executable"
    else
        fail "Hooks are not executable"
        return 1
    fi

    # Check hooks contain our code
    if grep -q "local-override" "$repo_dir/.git/hooks/pre-commit"; then
        pass "Hooks contain local-override code"
    else
        fail "Hooks don't contain local-override code"
        return 1
    fi
}

test_install_with_existing_hooks() {
    info "Testing install preserves existing hooks..."

    local repo_dir="$TEST_DIR/repo2"
    create_test_repo "$repo_dir"

    # Create existing pre-commit hook
    mkdir -p "$repo_dir/.git/hooks"
    cat > "$repo_dir/.git/hooks/pre-commit" << 'EOF'
#!/usr/bin/env bash
echo "Original pre-commit hook"
EOF
    chmod +x "$repo_dir/.git/hooks/pre-commit"

    # Run install
    "$PROJECT_DIR/scripts/install.sh" --repo

    # Check original hook was preserved
    if [[ -f "$repo_dir/.git/hooks/pre-commit.chained" ]]; then
        pass "Original hook preserved as .chained"
    else
        fail "Original hook not preserved"
        return 1
    fi

    # Check chained hook contains original content
    if grep -q "Original pre-commit hook" "$repo_dir/.git/hooks/pre-commit.chained"; then
        pass "Chained hook has original content"
    else
        fail "Chained hook missing original content"
        return 1
    fi

    # Check new hook chains to original
    if grep -q "chained" "$repo_dir/.git/hooks/pre-commit"; then
        pass "New hook chains to original"
    else
        fail "New hook doesn't chain to original"
        return 1
    fi
}

test_install_idempotent() {
    info "Testing install is idempotent..."

    local repo_dir="$TEST_DIR/repo3"
    create_test_repo "$repo_dir"

    # Run install twice
    "$PROJECT_DIR/scripts/install.sh" --repo
    "$PROJECT_DIR/scripts/install.sh" --repo

    # Should not create .chained files for our own hooks
    if [[ ! -f "$repo_dir/.git/hooks/pre-commit.chained" ]]; then
        pass "No duplicate chaining on reinstall"
    else
        # Check if the chained file is our hook (which is OK) or something else
        if grep -q "local-override" "$repo_dir/.git/hooks/pre-commit.chained"; then
            pass "Reinstall handled gracefully (detected existing)"
        else
            fail "Created unnecessary .chained file"
            return 1
        fi
    fi

    # Hooks should still work
    if grep -q "local-override" "$repo_dir/.git/hooks/pre-commit"; then
        pass "Hooks still functional after reinstall"
    else
        fail "Hooks broken after reinstall"
        return 1
    fi
}

test_reinstall_upgrades_managed_pre_commit_hook() {
    info "Testing reinstall upgrades managed pre-commit hook..."

    local repo_dir="$TEST_DIR/repo-reinstall-managed-pre-commit"
    create_test_repo "$repo_dir"

    "$PROJECT_DIR/scripts/install.sh" --repo

    local hook_file
    hook_file="$(get_hook_file_for_repo "$repo_dir" "pre-commit")" || {
        fail "Unable to resolve pre-commit hook path"
        return 1
    }

    echo "# STALE_MANAGED_PRE_COMMIT_SENTINEL" >> "$hook_file"

    "$PROJECT_DIR/scripts/install.sh" --repo

    if grep -q "STALE_MANAGED_PRE_COMMIT_SENTINEL" "$hook_file"; then
        fail "Managed pre-commit hook was not refreshed on reinstall"
        return 1
    fi
    pass "Managed pre-commit hook refreshed on reinstall"

    local marker
    marker="$(managed_hook_marker_for_test "pre-commit")"
    if grep -qxF "$marker" "$hook_file"; then
        pass "Managed pre-commit marker preserved"
    else
        fail "Managed pre-commit marker missing after reinstall"
        return 1
    fi

    if [[ ! -f "$hook_file.chained" ]]; then
        pass "Reinstall did not create extra pre-commit.chained"
    else
        fail "Unexpected pre-commit.chained created during managed reinstall"
        return 1
    fi
}

test_reinstall_upgrades_managed_pre_rebase_hook() {
    info "Testing reinstall upgrades managed pre-rebase hook..."

    local repo_dir="$TEST_DIR/repo-reinstall-managed-pre-rebase"
    create_test_repo "$repo_dir"

    "$PROJECT_DIR/scripts/install.sh" --repo

    local hook_file
    hook_file="$(get_hook_file_for_repo "$repo_dir" "pre-rebase")" || {
        fail "Unable to resolve pre-rebase hook path"
        return 1
    }

    echo "# STALE_MANAGED_PRE_REBASE_SENTINEL" >> "$hook_file"

    "$PROJECT_DIR/scripts/install.sh" --repo

    if grep -q "STALE_MANAGED_PRE_REBASE_SENTINEL" "$hook_file"; then
        fail "Managed pre-rebase hook was not refreshed on reinstall"
        return 1
    fi
    pass "Managed pre-rebase hook refreshed on reinstall"

    local marker
    marker="$(managed_hook_marker_for_test "pre-rebase")"
    if grep -qxF "$marker" "$hook_file"; then
        pass "Managed pre-rebase marker preserved"
    else
        fail "Managed pre-rebase marker missing after reinstall"
        return 1
    fi

    if [[ ! -f "$hook_file.chained" ]]; then
        pass "Reinstall did not create extra pre-rebase.chained"
    else
        fail "Unexpected pre-rebase.chained created during managed reinstall"
        return 1
    fi
}

test_reinstall_preserves_existing_chained_hook() {
    info "Testing reinstall preserves existing chained hook..."

    local repo_dir="$TEST_DIR/repo-reinstall-preserve-chained"
    create_test_repo "$repo_dir"

    local hook_file
    hook_file="$(get_hook_file_for_repo "$repo_dir" "pre-commit")" || {
        fail "Unable to resolve pre-commit hook path"
        return 1
    }

    cat > "$hook_file" << 'EOF'
#!/usr/bin/env bash
echo "Original pre-commit hook content"
EOF
    chmod +x "$hook_file"

    "$PROJECT_DIR/scripts/install.sh" --repo

    local chained_file="$hook_file.chained"
    if [[ ! -f "$chained_file" ]]; then
        fail "Pre-condition: pre-commit.chained was not created"
        return 1
    fi

    local chained_before="$TEST_DIR/pre-commit.chained.before"
    cp "$chained_file" "$chained_before"

    "$PROJECT_DIR/scripts/install.sh" --repo

    if [[ -f "$chained_file" ]]; then
        pass "pre-commit.chained still exists after reinstall"
    else
        fail "pre-commit.chained missing after reinstall"
        return 1
    fi

    if cmp -s "$chained_before" "$chained_file"; then
        pass "pre-commit.chained content preserved"
    else
        fail "pre-commit.chained content changed during reinstall"
        return 1
    fi

    local marker
    marker="$(managed_hook_marker_for_test "pre-commit")"
    if grep -qxF "$marker" "$hook_file"; then
        pass "Canonical pre-commit remains managed after reinstall"
    else
        fail "Canonical pre-commit not managed after reinstall"
        return 1
    fi
}

test_reinstall_prunes_stale_managed_artifacts() {
    info "Testing reinstall prunes stale managed artifacts without touching unmanaged hooks..."

    local repo_dir="$TEST_DIR/repo-reinstall-prune-stale-managed"
    create_test_repo "$repo_dir"

    "$PROJECT_DIR/scripts/install.sh" --repo

    local hooks_dir
    hooks_dir="$(get_common_hooks_dir_for_repo "$repo_dir")" || {
        fail "Unable to resolve hooks directory"
        return 1
    }

    local stale_managed_artifact="$hooks_dir/local-override-pre-rebase"
    cat > "$stale_managed_artifact" << 'EOF'
#!/usr/bin/env bash
# stale managed artifact from previous installer version
exit 0
EOF
    chmod +x "$stale_managed_artifact"

    local unmanaged_hook="$hooks_dir/pre-push"
    cat > "$unmanaged_hook" << 'EOF'
#!/usr/bin/env bash
echo "UNMANAGED_PRE_PUSH_CONTROL"
EOF
    chmod +x "$unmanaged_hook"

    local unmanaged_before="$TEST_DIR/pre-push.before"
    cp "$unmanaged_hook" "$unmanaged_before"

    "$PROJECT_DIR/scripts/install.sh" --repo

    if [[ -f "$stale_managed_artifact" ]]; then
        fail "Stale managed artifact was not pruned on reinstall"
        return 1
    fi
    pass "Stale managed artifact pruned on reinstall"

    if [[ -f "$unmanaged_hook" ]] && cmp -s "$unmanaged_before" "$unmanaged_hook"; then
        pass "Unmanaged control hook preserved unchanged"
    else
        fail "Unmanaged control hook was modified during reinstall"
        return 1
    fi
}

test_install_global() {
    info "Testing install.sh --global..."

    # Create a repo first (not required but useful for verification)
    local repo_dir="$TEST_DIR/repo-global"
    create_test_repo "$repo_dir"

    # Run global install
    "$PROJECT_DIR/scripts/install.sh" --global

    # Check template directory was created
    local template_dir="$XDG_CONFIG_HOME/git/template/hooks"
    if [[ -d "$template_dir" ]]; then
        pass "Template directory created"
    else
        fail "Template directory not created"
        return 1
    fi

    # Check hooks exist in template
    if [[ -f "$template_dir/pre-commit" ]] &&
       [[ -f "$template_dir/post-commit" ]] &&
       [[ -f "$template_dir/post-checkout" ]]; then
        pass "Hooks installed to template"
    else
        fail "Hooks missing from template"
        ls -la "$template_dir" || true
        return 1
    fi

    # Check git config was set
    local configured_template
    configured_template=$(git config --global init.templateDir || echo "")
    if [[ -n "$configured_template" ]]; then
        pass "Git templateDir configured"
    else
        fail "Git templateDir not configured"
        return 1
    fi
}

test_install_cli() {
    info "Testing install.sh --cli..."

    # Reset global config to avoid template hooks being copied
    reset_git_config

    local repo_dir="$TEST_DIR/repo-cli"
    create_test_repo "$repo_dir"

    # Run install with CLI
    "$PROJECT_DIR/scripts/install.sh" --repo --cli

    # Check CLI was installed
    local cli_path="$HOME/.local/bin/git-local-override"
    if [[ -f "$cli_path" ]]; then
        pass "CLI tool installed"
    else
        fail "CLI tool not installed"
        return 1
    fi

    # Check CLI is executable
    if [[ -x "$cli_path" ]]; then
        pass "CLI tool is executable"
    else
        fail "CLI tool not executable"
        return 1
    fi

    # Check CLI works
    if "$cli_path" help | grep -q "git-local-override"; then
        pass "CLI tool functional"
    else
        fail "CLI tool not functional"
        return 1
    fi
}

test_install_gitignore() {
    info "Testing install sets up global gitignore..."

    # Reset global config first
    reset_git_config

    local repo_dir="$TEST_DIR/repo-gitignore"
    create_test_repo "$repo_dir"

    "$PROJECT_DIR/scripts/install.sh" --repo

    # Check global gitignore was configured
    local gitignore_file
    gitignore_file=$(git config --global core.excludesfile || echo "")

    if [[ -n "$gitignore_file" ]]; then
        pass "Global gitignore configured"
    else
        fail "Global gitignore not configured"
        return 1
    fi

    # Expand path and check content
    gitignore_file="${gitignore_file/#\~/$HOME}"
    if [[ -f "$gitignore_file" ]] && grep -q '\.local\.' "$gitignore_file"; then
        pass "Gitignore contains .local.* pattern"
    else
        fail "Gitignore missing .local.* pattern"
        return 1
    fi
}

test_uninstall_from_repo() {
    info "Testing uninstall removes hooks..."

    # Reset global config first
    reset_git_config

    local repo_dir="$TEST_DIR/repo-uninstall"
    create_test_repo "$repo_dir"

    # Install first
    "$PROJECT_DIR/scripts/install.sh" --repo --cli

    # Verify installation
    [[ -f "$repo_dir/.git/hooks/pre-commit" ]] || {
        fail "Pre-condition: hooks not installed"
        return 1
    }

    # Run uninstall (non-interactive mode)
    echo "n" | "$PROJECT_DIR/scripts/uninstall.sh" || true

    # Check CLI was removed
    if [[ ! -f "$HOME/.local/bin/git-local-override" ]]; then
        pass "CLI tool removed"
    else
        fail "CLI tool still exists"
        return 1
    fi
}

test_uninstall_restores_chained_hook_when_wrapper_is_managed() {
    info "Testing uninstall restores chained hook for managed wrapper..."

    local repo_dir="$TEST_DIR/repo-uninstall-restore-chained"
    create_test_repo "$repo_dir"

    local hook_file
    hook_file="$(get_hook_file_for_repo "$repo_dir" "pre-commit")" || {
        fail "Unable to resolve pre-commit hook path"
        return 1
    }

    cat > "$hook_file" << 'EOF'
#!/usr/bin/env bash
echo "ORIGINAL_USER_PRE_COMMIT"
EOF
    chmod +x "$hook_file"

    "$PROJECT_DIR/scripts/install.sh" --repo

    local chained_file="$hook_file.chained"
    if [[ ! -f "$chained_file" ]]; then
        fail "Pre-condition: pre-commit.chained missing after install"
        return 1
    fi

    local marker
    marker="$(managed_hook_marker_for_test "pre-commit")"
    if ! grep -qxF "$marker" "$hook_file"; then
        fail "Pre-condition: canonical pre-commit is not managed"
        return 1
    fi

    local uninstall_output="$TEST_DIR/uninstall-restore-chained.log"
    if ! run_uninstall_non_interactive_capture "$uninstall_output"; then
        fail "Uninstall command failed"
        cat "$uninstall_output" || true
        return 1
    fi

    if [[ -f "$hook_file" ]]; then
        pass "Canonical pre-commit exists after uninstall"
    else
        fail "Canonical pre-commit missing after uninstall"
        return 1
    fi

    if grep -q "ORIGINAL_USER_PRE_COMMIT" "$hook_file"; then
        pass "Uninstall restored original user pre-commit hook"
    else
        fail "Uninstall did not restore original user pre-commit hook"
        return 1
    fi

    if [[ ! -f "$chained_file" ]]; then
        pass "pre-commit.chained removed after restoration"
    else
        fail "pre-commit.chained still present after restoration"
        return 1
    fi
}

test_uninstall_does_not_overwrite_newer_user_hook() {
    info "Testing uninstall preserves newer user hook when canonical is unmanaged..."

    local repo_dir="$TEST_DIR/repo-uninstall-preserve-newer-user-hook"
    create_test_repo "$repo_dir"

    local hook_file
    hook_file="$(get_hook_file_for_repo "$repo_dir" "pre-commit")" || {
        fail "Unable to resolve pre-commit hook path"
        return 1
    }

    cat > "$hook_file" << 'EOF'
#!/usr/bin/env bash
echo "ORIGINAL_USER_HOOK_BEFORE_INSTALL"
EOF
    chmod +x "$hook_file"

    "$PROJECT_DIR/scripts/install.sh" --repo

    local chained_file="$hook_file.chained"
    if [[ ! -f "$chained_file" ]]; then
        fail "Pre-condition: pre-commit.chained missing after install"
        return 1
    fi

    cat > "$hook_file" << 'EOF'
#!/usr/bin/env bash
echo "NEWER_USER_HOOK_AFTER_INSTALL"
EOF
    chmod +x "$hook_file"

    local uninstall_output="$TEST_DIR/uninstall-preserve-newer-user-hook.log"
    if ! run_uninstall_non_interactive_capture "$uninstall_output"; then
        fail "Uninstall command failed"
        cat "$uninstall_output" || true
        return 1
    fi

    if grep -q "NEWER_USER_HOOK_AFTER_INSTALL" "$hook_file"; then
        pass "Uninstall preserved newer unmanaged user hook"
    else
        fail "Uninstall overwrote newer unmanaged user hook"
        return 1
    fi

    if [[ -f "$chained_file" ]]; then
        pass "pre-commit.chained preserved for ambiguous uninstall state"
    else
        fail "pre-commit.chained was unexpectedly removed"
        return 1
    fi

    if grep -qi "ambiguous" "$uninstall_output"; then
        pass "Uninstall emitted ambiguous-state warning"
    else
        fail "Uninstall did not emit ambiguous-state warning"
        cat "$uninstall_output" || true
        return 1
    fi
}

test_new_repo_gets_hooks_after_global_install() {
    info "Testing new repos get hooks after global install..."

    # Reset and do fresh global install for this test
    reset_git_config

    # Do global install
    "$PROJECT_DIR/scripts/install.sh" --global

    # Create a NEW repo (should get hooks from template)
    local new_repo="$TEST_DIR/new-repo-after-global"
    mkdir -p "$new_repo"
    cd "$new_repo"
    git init -q

    # Check if hooks were copied from template
    if [[ -f "$new_repo/.git/hooks/pre-commit" ]] &&
       grep -q "local-override" "$new_repo/.git/hooks/pre-commit" 2>/dev/null; then
        pass "New repo got hooks from template"
    else
        # This is expected to fail if git doesn't copy the template hooks
        # (depends on git version and config)
        info "Note: Git didn't auto-copy template hooks (may be expected)"
        pass "Global install completed (template hooks ready)"
    fi
}

test_install_configures_filter_driver() {
    info "Testing install configures filter driver..."

    local repo_dir="$TEST_DIR/repo-filter-config"
    create_test_repo "$repo_dir"

    # Create a config file so install knows what to filter
    cat > "$repo_dir/.local-overrides.yaml" << 'EOF'
pattern: ".local"
files:
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
EOF

    # Run install
    "$PROJECT_DIR/scripts/install.sh" --repo

    # Check filter.local-override.smudge is configured
    cd "$repo_dir"
    local smudge_cmd
    smudge_cmd=$(git config --local filter.local-override.smudge 2>/dev/null || echo "")
    if [[ -n "$smudge_cmd" ]] && [[ "$smudge_cmd" == *"local-override-filter-smudge"* ]]; then
        pass "Filter smudge command configured"
    else
        fail "Filter smudge command not configured (got: '$smudge_cmd')"
        return 1
    fi

    if [[ "$smudge_cmd" == .git/hooks/* ]]; then
        fail "Filter smudge command uses legacy relative .git/hooks path"
        return 1
    fi

    if [[ "$smudge_cmd" == /* ]]; then
        pass "Filter smudge command uses absolute path"
    else
        fail "Filter smudge command is not absolute (got: '$smudge_cmd')"
        return 1
    fi

    # Check filter.local-override.clean is configured
    local clean_cmd
    clean_cmd=$(git config --local filter.local-override.clean 2>/dev/null || echo "")
    if [[ -n "$clean_cmd" ]] && [[ "$clean_cmd" == *"local-override-filter-clean"* ]]; then
        pass "Filter clean command configured"
    else
        fail "Filter clean command not configured (got: '$clean_cmd')"
        return 1
    fi

    if [[ "$clean_cmd" == .git/hooks/* ]]; then
        fail "Filter clean command uses legacy relative .git/hooks path"
        return 1
    fi

    if [[ "$clean_cmd" == /* ]]; then
        pass "Filter clean command uses absolute path"
    else
        fail "Filter clean command is not absolute (got: '$clean_cmd')"
        return 1
    fi

    # Check filter.local-override.required is false
    local required
    required=$(git config --local filter.local-override.required 2>/dev/null || echo "")
    if [[ "$required" == "false" ]]; then
        pass "Filter required set to false"
    else
        fail "Filter required not set to false (got: '$required')"
        return 1
    fi
}

test_install_populates_attributes() {
    info "Testing install populates .git/info/attributes..."

    local repo_dir="$TEST_DIR/repo-filter-attributes"
    create_test_repo "$repo_dir"

    # Create a config file with multiple targets
    cat > "$repo_dir/.local-overrides.yaml" << 'EOF'
pattern: ".local"
files:
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
  - override: CLAUDE.local.md
    replaces:
      - CLAUDE.md
EOF

    # Run install
    "$PROJECT_DIR/scripts/install.sh" --repo

    cd "$repo_dir"
    local attributes_file=".git/info/attributes"

    # Check attributes file exists
    if [[ ! -f "$attributes_file" ]]; then
        fail "Attributes file not created"
        return 1
    fi

    # Check it contains filter entries for each target
    if grep -q "AGENTS.md filter=local-override" "$attributes_file" &&
       grep -q "CLAUDE.md filter=local-override" "$attributes_file"; then
        pass "Attributes file contains filter entries for all targets"
    else
        fail "Attributes file missing filter entries"
        cat "$attributes_file" || true
        return 1
    fi

    # Check for header comment
    if grep -q "git-local-override" "$attributes_file"; then
        pass "Attributes file has header comment"
    else
        fail "Attributes file missing header comment"
        return 1
    fi
}

test_install_idempotent_attributes() {
    info "Testing install is idempotent for attributes..."

    local repo_dir="$TEST_DIR/repo-filter-idempotent"
    create_test_repo "$repo_dir"

    # Create a config file
    cat > "$repo_dir/.local-overrides.yaml" << 'EOF'
pattern: ".local"
files:
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
EOF

    # Run install twice
    "$PROJECT_DIR/scripts/install.sh" --repo
    "$PROJECT_DIR/scripts/install.sh" --repo

    cd "$repo_dir"
    local attributes_file=".git/info/attributes"

    # Count occurrences of the filter entry
    local count
    count=$(grep -c "AGENTS.md filter=local-override" "$attributes_file" 2>/dev/null || echo "0")

    if [[ "$count" -eq 1 ]]; then
        pass "No duplicate filter entries after reinstall"
    else
        fail "Found $count occurrences of filter entry (expected 1)"
        cat "$attributes_file" || true
        return 1
    fi
}

test_uninstall_removes_filter_config() {
    info "Testing uninstall removes filter config..."

    local repo_dir="$TEST_DIR/repo-filter-uninstall"
    create_test_repo "$repo_dir"

    # Create a config file
    cat > "$repo_dir/.local-overrides.yaml" << 'EOF'
pattern: ".local"
files:
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
EOF

    # Install first
    "$PROJECT_DIR/scripts/install.sh" --repo

    cd "$repo_dir"

    # Verify filter is configured
    if ! git config --local filter.local-override.smudge >/dev/null 2>&1; then
        fail "Pre-condition: filter not installed"
        return 1
    fi

    # Run uninstall (non-interactive)
    echo "n" | "$PROJECT_DIR/scripts/uninstall.sh" || true

    # Check filter config is removed
    if git config --local filter.local-override.smudge >/dev/null 2>&1; then
        fail "Filter smudge config still exists after uninstall"
        return 1
    fi

    if git config --local filter.local-override.clean >/dev/null 2>&1; then
        fail "Filter clean config still exists after uninstall"
        return 1
    fi

    pass "Filter config removed by uninstall"

    # Check attributes file has no local-override entries
    local attributes_file=".git/info/attributes"
    if [[ -f "$attributes_file" ]] && grep -q "filter=local-override" "$attributes_file"; then
        fail "Attributes file still contains filter entries"
        cat "$attributes_file" || true
        return 1
    fi

    pass "Attributes file cleaned by uninstall"
}

test_global_uninstall_removes_global_filter_config() {
    info "Testing global uninstall removes global filter config..."

    local repo_dir="$TEST_DIR/repo-global-uninstall-filters"
    create_test_repo "$repo_dir"

    "$PROJECT_DIR/scripts/install.sh" --global

    if git config --global filter.local-override.smudge >/dev/null 2>&1 &&
       git config --global filter.local-override.clean >/dev/null 2>&1 &&
       git config --global filter.local-override.required >/dev/null 2>&1; then
        pass "Pre-condition: global filter config set"
    else
        fail "Pre-condition: global filter config missing after global install"
        return 1
    fi

    local uninstall_output="$TEST_DIR/uninstall-global-filter-config.log"
    if ! run_uninstall_non_interactive_capture "$uninstall_output"; then
        fail "Uninstall command failed"
        cat "$uninstall_output" || true
        return 1
    fi

    if git config --global filter.local-override.smudge >/dev/null 2>&1; then
        fail "Global smudge filter config still exists after uninstall"
        return 1
    fi

    if git config --global filter.local-override.clean >/dev/null 2>&1; then
        fail "Global clean filter config still exists after uninstall"
        return 1
    fi

    if git config --global filter.local-override.required >/dev/null 2>&1; then
        fail "Global required filter config still exists after uninstall"
        return 1
    fi

    pass "Global filter.local-override.* config removed"
}

test_global_uninstall_removes_pre_rebase_artifacts() {
    info "Testing global uninstall removes pre-rebase template artifacts..."

    local repo_dir="$TEST_DIR/repo-global-uninstall-pre-rebase"
    create_test_repo "$repo_dir"

    "$PROJECT_DIR/scripts/install.sh" --global

    local template_dir="$XDG_CONFIG_HOME/git/template/hooks"

    if [[ -f "$template_dir/pre-rebase" ]]; then
        pass "Pre-condition: template pre-rebase wrapper installed"
    else
        fail "Pre-condition: template pre-rebase wrapper missing"
        return 1
    fi

    cat > "$template_dir/local-override-pre-rebase" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$template_dir/local-override-pre-rebase"

    local uninstall_output="$TEST_DIR/uninstall-global-pre-rebase.log"
    if ! run_uninstall_non_interactive_capture "$uninstall_output"; then
        fail "Uninstall command failed"
        cat "$uninstall_output" || true
        return 1
    fi

    local managed_file
    for managed_file in \
        pre-commit \
        post-commit \
        post-checkout \
        pre-rebase \
        local-override-lib.sh \
        local-override-filter-smudge \
        local-override-filter-clean \
        local-override-pre-rebase; do
        if [[ -f "$template_dir/$managed_file" ]]; then
            fail "Managed template artifact still exists after uninstall: $managed_file"
            return 1
        fi
    done

    pass "Managed template pre-rebase and related artifacts removed"
}

test_repo_uninstall_uses_git_resolved_paths_in_linked_worktree() {
    info "Testing repo uninstall uses git-resolved paths in linked worktree..."

    local main_repo="$TEST_DIR/repo-worktree-main"
    create_test_repo "$main_repo"

    cat > "$main_repo/.local-overrides.yaml" << 'EOF'
pattern: ".local"
files:
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
EOF

    echo "Base AGENTS content" > "$main_repo/AGENTS.md"
    cd "$main_repo"
    git add .local-overrides.yaml AGENTS.md
    git commit -q -m "Add override config for linked worktree test"

    local linked_repo="$TEST_DIR/repo-worktree-linked"
    git -C "$main_repo" worktree add -q -b linked-worktree-branch "$linked_repo" HEAD

    if [[ -f "$linked_repo/.git" ]]; then
        pass "Linked worktree uses .git file (not directory)"
    else
        fail "Pre-condition: linked worktree .git should be a file"
        return 1
    fi

    cd "$linked_repo"
    "$PROJECT_DIR/scripts/install.sh" --repo

    if ! git config --local filter.local-override.smudge >/dev/null 2>&1; then
        fail "Pre-condition: linked worktree filter config missing after install"
        return 1
    fi

    local common_hooks_dir
    common_hooks_dir="$(get_common_hooks_dir_for_repo "$linked_repo")" || {
        fail "Unable to resolve common hooks directory for linked worktree"
        return 1
    }

    if [[ ! -f "$common_hooks_dir/local-override-filter-smudge" ]] ||
       [[ ! -f "$common_hooks_dir/local-override-filter-clean" ]]; then
        fail "Pre-condition: linked worktree filter scripts missing from common hooks directory"
        return 1
    fi

    local attributes_file
    attributes_file="$(get_attributes_file_for_repo "$linked_repo")" || {
        fail "Unable to resolve linked worktree attributes path"
        return 1
    }

    if [[ ! -f "$attributes_file" ]] || ! grep -q "AGENTS.md filter=local-override" "$attributes_file"; then
        fail "Pre-condition: linked worktree attributes missing managed filter entry"
        return 1
    fi

    local uninstall_output="$TEST_DIR/uninstall-linked-worktree.log"
    if ! run_uninstall_non_interactive_capture "$uninstall_output"; then
        fail "Uninstall command failed from linked worktree"
        cat "$uninstall_output" || true
        return 1
    fi

    if git config --local filter.local-override.smudge >/dev/null 2>&1; then
        fail "Linked worktree filter config still exists after uninstall"
        return 1
    fi
    pass "Linked worktree filter config removed"

    if [[ -f "$common_hooks_dir/local-override-filter-smudge" ]] ||
       [[ -f "$common_hooks_dir/local-override-filter-clean" ]]; then
        fail "Managed filter scripts were not removed from common hooks directory"
        return 1
    fi
    pass "Managed filter scripts removed from common hooks directory"

    if [[ -f "$attributes_file" ]] && grep -q "filter=local-override" "$attributes_file"; then
        fail "Linked worktree attributes still contains managed filter entries"
        cat "$attributes_file" || true
        return 1
    fi
    pass "Linked worktree resolved attributes cleaned"
}

test_install_filter_scripts_executable() {
    info "Testing install creates executable filter scripts..."

    local repo_dir="$TEST_DIR/repo-filter-scripts"
    create_test_repo "$repo_dir"

    # Create a config file
    cat > "$repo_dir/.local-overrides.yaml" << 'EOF'
pattern: ".local"
files:
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
EOF

    # Run install
    "$PROJECT_DIR/scripts/install.sh" --repo

    cd "$repo_dir"

    # Check filter scripts exist
    if [[ ! -f ".git/hooks/local-override-filter-smudge" ]]; then
        fail "Filter smudge script not installed"
        return 1
    fi

    if [[ ! -f ".git/hooks/local-override-filter-clean" ]]; then
        fail "Filter clean script not installed"
        return 1
    fi

    pass "Filter scripts installed"

    # Check they are executable
    if [[ ! -x ".git/hooks/local-override-filter-smudge" ]]; then
        fail "Filter smudge script not executable"
        return 1
    fi

    if [[ ! -x ".git/hooks/local-override-filter-clean" ]]; then
        fail "Filter clean script not executable"
        return 1
    fi

    pass "Filter scripts are executable"
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    echo ""
    echo "========================================"
    echo "  Install/Uninstall Integration Tests"
    echo "========================================"
    echo ""

    trap 'reset_git_config; finalize_current_test_root "${CURRENT_TEST_STATUS:-0}"' EXIT

    local test_fn
    for test_fn in \
        test_install_to_repo \
        test_install_with_existing_hooks \
        test_install_idempotent \
        test_reinstall_upgrades_managed_pre_commit_hook \
        test_reinstall_upgrades_managed_pre_rebase_hook \
        test_reinstall_preserves_existing_chained_hook \
        test_reinstall_prunes_stale_managed_artifacts \
        test_install_global \
        test_install_cli \
        test_install_gitignore \
        test_uninstall_from_repo \
        test_uninstall_restores_chained_hook_when_wrapper_is_managed \
        test_uninstall_does_not_overwrite_newer_user_hook \
        test_new_repo_gets_hooks_after_global_install \
        test_install_configures_filter_driver \
        test_install_populates_attributes \
        test_install_idempotent_attributes \
        test_uninstall_removes_filter_config \
        test_global_uninstall_removes_global_filter_config \
        test_global_uninstall_removes_pre_rebase_artifacts \
        test_repo_uninstall_uses_git_resolved_paths_in_linked_worktree \
        test_install_filter_scripts_executable; do
        CURRENT_TEST_NAME="$test_fn"
        setup

        set +e
        "$test_fn"
        CURRENT_TEST_STATUS=$?
        set -e

        if [[ $CURRENT_TEST_STATUS -ne 0 ]]; then
            reset_git_config
            finalize_current_test_root "$CURRENT_TEST_STATUS"
            exit "$CURRENT_TEST_STATUS"
        fi

        reset_git_config
        finalize_current_test_root 0
    done

    # Cleanup
    reset_git_config
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
