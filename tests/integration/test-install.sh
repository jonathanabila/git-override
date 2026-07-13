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

# Colors, counters, pass/fail/info, and finish_suite come from test-lib.sh.

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

get_index_flag_for_repo() {
    local repo_dir="$1"
    local target="$2"
    local ls_output=""

    ls_output="$(git -C "$repo_dir" ls-files -v -- "$target" 2>/dev/null || true)"
    printf '%s\n' "${ls_output:0:1}"
}

run_uninstall_non_interactive_capture() {
    local output_file="$1"
    printf 'n\nn\nn\nn\n' | "$PROJECT_DIR/scripts/uninstall.sh" > "$output_file" 2>&1
}

count_matching_paths() {
    local pattern="$1"
    local count=0
    local path

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        ((count++)) || true
    done < <(compgen -G "$pattern" || true)

    printf '%s\n' "$count"
}

first_matching_path() {
    local pattern="$1"
    local path

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        printf '%s\n' "$path"
        return 0
    done < <(compgen -G "$pattern" || true)

    return 1
}

write_ambiguous_hook_state() {
    local repo_dir="$1"
    local hook_name="$2"
    local canonical_body="$3"
    local chained_body="$4"
    local hook_file

    hook_file="$(get_hook_file_for_repo "$repo_dir" "$hook_name")" || return 1

    cat > "$hook_file" <<EOF
#!/usr/bin/env bash
echo "$canonical_body"
EOF
    chmod +x "$hook_file"

    cat > "$hook_file.chained" <<EOF
#!/usr/bin/env bash
echo "$chained_body"
EOF
    chmod +x "$hook_file.chained"
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

test_install_executes_chained_pre_commit_hook() {
    info "Testing installed wrapper executes chained pre-commit hook..."

    local repo_dir="$TEST_DIR/repo-chain-exec-pre-commit"
    create_test_repo "$repo_dir"

    local hook_file
    hook_file="$(get_hook_file_for_repo "$repo_dir" "pre-commit")" || {
        fail "Unable to resolve pre-commit hook path"
        return 1
    }

    cat > "$hook_file" << 'EOF'
#!/usr/bin/env bash
echo "CHAINED_PRE_COMMIT_RAN" >> chained-pre-commit.log
exit 0
EOF
    chmod +x "$hook_file"

    "$PROJECT_DIR/scripts/install.sh" --repo

    cd "$repo_dir"
    echo "hook chaining check" >> README.md
    git add README.md
    git commit -q -m "Trigger chained pre-commit"

    if [[ -f "$repo_dir/chained-pre-commit.log" ]] && grep -q "CHAINED_PRE_COMMIT_RAN" "$repo_dir/chained-pre-commit.log"; then
        pass "Chained pre-commit hook executed through managed wrapper"
    else
        fail "Chained pre-commit hook did not execute after install"
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

test_reinstall_prunes_stale_managed_post_commit_chained_hook() {
    info "Testing reinstall prunes stale managed post-commit.chained hook..."

    local repo_dir="$TEST_DIR/repo-prune-stale-post-commit-chained"
    create_test_repo "$repo_dir"

    "$PROJECT_DIR/scripts/install.sh" --repo

    local hook_file
    hook_file="$(get_hook_file_for_repo "$repo_dir" "post-commit")" || {
        fail "Unable to resolve post-commit hook path"
        return 1
    }

    cat > "$hook_file.chained" << 'EOF'
#!/usr/bin/env bash
#
# local-override-post-commit
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/local-override-lib.sh"
echo "STALE_POST_COMMIT_CHAINED"
EOF
    chmod +x "$hook_file.chained"

    "$PROJECT_DIR/scripts/install.sh" --repo

    if [[ ! -f "$hook_file.chained" ]]; then
        pass "Reinstall removed stale managed post-commit.chained"
    else
        fail "Stale managed post-commit.chained was not removed"
        return 1
    fi
}

test_install_warns_on_ambiguous_pre_commit_hook() {
    info "Testing plain install preserves ambiguous pre-commit hook state..."

    local repo_dir="$TEST_DIR/repo-ambiguous-warning-pre-commit"
    create_test_repo "$repo_dir"

    local hook_file
    hook_file="$(get_hook_file_for_repo "$repo_dir" "pre-commit")" || {
        fail "Unable to resolve pre-commit hook path"
        return 1
    }

    write_ambiguous_hook_state "$repo_dir" "pre-commit" "AMBIGUOUS_CANONICAL_PRE_COMMIT" "AMBIGUOUS_CHAINED_PRE_COMMIT" || {
        fail "Unable to create ambiguous pre-commit hook state"
        return 1
    }

    local output_file="$TEST_DIR/install-ambiguous-warning.log"
    if ! "$PROJECT_DIR/scripts/install.sh" --repo > "$output_file" 2>&1; then
        fail "Install failed for ambiguous warning scenario"
        return 1
    fi

    if grep -q "Ambiguous state for pre-commit" "$output_file"; then
        pass "Install emitted ambiguous-state warning"
    else
        fail "Install did not emit ambiguous-state warning"
        return 1
    fi

    if grep -q "AMBIGUOUS_CANONICAL_PRE_COMMIT" "$hook_file"; then
        pass "Canonical pre-commit remained unmanaged"
    else
        fail "Canonical pre-commit was unexpectedly rewritten"
        return 1
    fi

    if grep -q "AMBIGUOUS_CHAINED_PRE_COMMIT" "$hook_file.chained"; then
        pass "Existing pre-commit.chained remained unchanged"
    else
        fail "Existing pre-commit.chained was unexpectedly rewritten"
        return 1
    fi

    local marker
    marker="$(managed_hook_marker_for_test "pre-commit")"
    if grep -qxF "$marker" "$hook_file"; then
        fail "Managed marker was unexpectedly installed in warning-only mode"
        return 1
    fi
    pass "Managed wrapper not installed in warning-only mode"
}

test_install_repairs_ambiguous_pre_commit_hook() {
    info "Testing repair mode resolves ambiguous pre-commit hook state..."

    local repo_dir="$TEST_DIR/repo-ambiguous-repair-pre-commit"
    create_test_repo "$repo_dir"

    local hook_file
    local hooks_dir
    hook_file="$(get_hook_file_for_repo "$repo_dir" "pre-commit")" || {
        fail "Unable to resolve pre-commit hook path"
        return 1
    }
    hooks_dir="$(get_common_hooks_dir_for_repo "$repo_dir")" || {
        fail "Unable to resolve hooks directory"
        return 1
    }

    write_ambiguous_hook_state "$repo_dir" "pre-commit" "AMBIGUOUS_CANONICAL_PRE_COMMIT" "AMBIGUOUS_CHAINED_PRE_COMMIT" || {
        fail "Unable to create ambiguous pre-commit hook state"
        return 1
    }

    local output_file="$TEST_DIR/install-ambiguous-repair-pre-commit.log"
    if ! "$PROJECT_DIR/scripts/install.sh" --repo --resolve-ambiguous-hooks > "$output_file" 2>&1; then
        fail "Repair install failed for pre-commit"
        return 1
    fi

    local marker
    marker="$(managed_hook_marker_for_test "pre-commit")"
    if grep -qxF "$marker" "$hook_file"; then
        pass "Canonical pre-commit became managed"
    else
        fail "Canonical pre-commit did not become managed"
        return 1
    fi

    if grep -q '"${BASH_SOURCE\[0\]}\.chained"' "$hook_file"; then
        pass "Managed pre-commit chains to .chained"
    else
        fail "Managed pre-commit does not chain to .chained"
        return 1
    fi

    if grep -q "AMBIGUOUS_CANONICAL_PRE_COMMIT" "$hook_file.chained"; then
        pass "New pre-commit.chained contains prior canonical hook"
    else
        fail "New pre-commit.chained missing prior canonical hook content"
        return 1
    fi

    local stale_count
    stale_count="$(count_matching_paths "$hook_file.chained.stale-*")"
    if [[ "$stale_count" == "1" ]]; then
        pass "One stale pre-commit.chained backup created"
    else
        fail "Expected one stale pre-commit.chained backup, found $stale_count"
        return 1
    fi

    local stale_file
    stale_file="$(first_matching_path "$hook_file.chained.stale-*")" || {
        fail "Unable to locate stale pre-commit.chained backup"
        return 1
    }
    if grep -q "AMBIGUOUS_CHAINED_PRE_COMMIT" "$stale_file"; then
        pass "Stale pre-commit.chained backup preserved prior chained content"
    else
        fail "Stale pre-commit.chained backup missing prior chained content"
        return 1
    fi

    local backup_count
    backup_count="$(count_matching_paths "$hooks_dir/backup-*")"
    if [[ "$backup_count" == "1" ]]; then
        pass "One hooks backup directory created"
    else
        fail "Expected one hooks backup directory, found $backup_count"
        return 1
    fi

    local backup_dir
    backup_dir="$(first_matching_path "$hooks_dir/backup-*")" || {
        fail "Unable to locate hooks backup directory"
        return 1
    }

    if [[ -f "$backup_dir/pre-commit" ]] && grep -q "AMBIGUOUS_CANONICAL_PRE_COMMIT" "$backup_dir/pre-commit"; then
        pass "Backup directory preserved original pre-commit"
    else
        fail "Backup directory missing original pre-commit content"
        return 1
    fi

    if [[ -f "$backup_dir/pre-commit.chained" ]] && grep -q "AMBIGUOUS_CHAINED_PRE_COMMIT" "$backup_dir/pre-commit.chained"; then
        pass "Backup directory preserved original pre-commit.chained"
    else
        fail "Backup directory missing original pre-commit.chained content"
        return 1
    fi

    if grep -q "Resolving ambiguous state for pre-commit" "$output_file" &&
       grep -q "Backed up pre-commit and pre-commit.chained" "$output_file" &&
       grep -q "Moved existing pre-commit.chained to" "$output_file" &&
       grep -q "Promoted existing pre-commit to pre-commit.chained" "$output_file"; then
        pass "Repair install output described repair actions"
    else
        fail "Repair install output did not describe expected actions"
        return 1
    fi
}

test_repair_install_is_idempotent_after_pre_commit_repair() {
    info "Testing repair mode is idempotent after pre-commit repair..."

    local repo_dir="$TEST_DIR/repo-ambiguous-repair-idempotent-pre-commit"
    create_test_repo "$repo_dir"

    local hook_file
    hook_file="$(get_hook_file_for_repo "$repo_dir" "pre-commit")" || {
        fail "Unable to resolve pre-commit hook path"
        return 1
    }

    write_ambiguous_hook_state "$repo_dir" "pre-commit" "AMBIGUOUS_CANONICAL_PRE_COMMIT" "AMBIGUOUS_CHAINED_PRE_COMMIT" || {
        fail "Unable to create ambiguous pre-commit hook state"
        return 1
    }

    if ! "$PROJECT_DIR/scripts/install.sh" --repo --resolve-ambiguous-hooks > "$TEST_DIR/install-ambiguous-repair-idempotent-first.log" 2>&1; then
        fail "Initial repair install failed"
        return 1
    fi

    local chained_before="$TEST_DIR/pre-commit.repaired.chained.before"
    cp "$hook_file.chained" "$chained_before"

    local stale_count_before
    stale_count_before="$(count_matching_paths "$hook_file.chained.stale-*")"

    local second_output="$TEST_DIR/install-ambiguous-repair-idempotent-second.log"
    if ! "$PROJECT_DIR/scripts/install.sh" --repo --resolve-ambiguous-hooks > "$second_output" 2>&1; then
        fail "Second repair install failed"
        return 1
    fi

    local marker
    marker="$(managed_hook_marker_for_test "pre-commit")"
    if grep -qxF "$marker" "$hook_file"; then
        pass "Canonical pre-commit stayed managed after second repair install"
    else
        fail "Canonical pre-commit lost managed marker after second repair install"
        return 1
    fi

    if cmp -s "$chained_before" "$hook_file.chained"; then
        pass "pre-commit.chained remained stable after second repair install"
    else
        fail "pre-commit.chained changed on second repair install"
        return 1
    fi

    local stale_count_after
    stale_count_after="$(count_matching_paths "$hook_file.chained.stale-*")"
    if [[ "$stale_count_before" == "$stale_count_after" ]]; then
        pass "Second repair install did not create extra stale hooks"
    else
        fail "Second repair install created extra stale hooks"
        return 1
    fi

    if grep -q "Refreshing managed hook: pre-commit" "$second_output"; then
        pass "Second repair install behaved like managed hook refresh"
    else
        fail "Second repair install did not report managed hook refresh"
        return 1
    fi
}

test_install_repairs_ambiguous_post_checkout_hook() {
    info "Testing repair mode resolves ambiguous post-checkout hook state..."

    local repo_dir="$TEST_DIR/repo-ambiguous-repair-post-checkout"
    create_test_repo "$repo_dir"

    local hook_file
    local hooks_dir
    hook_file="$(get_hook_file_for_repo "$repo_dir" "post-checkout")" || {
        fail "Unable to resolve post-checkout hook path"
        return 1
    }
    hooks_dir="$(get_common_hooks_dir_for_repo "$repo_dir")" || {
        fail "Unable to resolve hooks directory"
        return 1
    }

    write_ambiguous_hook_state "$repo_dir" "post-checkout" "AMBIGUOUS_CANONICAL_POST_CHECKOUT" "AMBIGUOUS_CHAINED_POST_CHECKOUT" || {
        fail "Unable to create ambiguous post-checkout hook state"
        return 1
    }

    local output_file="$TEST_DIR/install-ambiguous-repair-post-checkout.log"
    if ! "$PROJECT_DIR/scripts/install.sh" --repo --resolve-ambiguous-hooks > "$output_file" 2>&1; then
        fail "Repair install failed for post-checkout"
        return 1
    fi

    local marker
    marker="$(managed_hook_marker_for_test "post-checkout")"
    if grep -qxF "$marker" "$hook_file"; then
        pass "Canonical post-checkout became managed"
    else
        fail "Canonical post-checkout did not become managed"
        return 1
    fi

    if grep -q "AMBIGUOUS_CANONICAL_POST_CHECKOUT" "$hook_file.chained"; then
        pass "New post-checkout.chained contains prior canonical hook"
    else
        fail "New post-checkout.chained missing prior canonical hook content"
        return 1
    fi

    local stale_file
    stale_file="$(first_matching_path "$hook_file.chained.stale-*")" || {
        fail "Unable to locate stale post-checkout.chained backup"
        return 1
    }
    if grep -q "AMBIGUOUS_CHAINED_POST_CHECKOUT" "$stale_file"; then
        pass "Stale post-checkout.chained backup preserved prior chained content"
    else
        fail "Stale post-checkout.chained backup missing prior chained content"
        return 1
    fi

    local backup_dir
    backup_dir="$(first_matching_path "$hooks_dir/backup-*")" || {
        fail "Unable to locate post-checkout backup directory"
        return 1
    }
    if [[ -f "$backup_dir/post-checkout" ]] && [[ -f "$backup_dir/post-checkout.chained" ]]; then
        pass "Backup directory created for post-checkout repair"
    else
        fail "Backup directory missing post-checkout repair files"
        return 1
    fi

    if grep -q "Resolving ambiguous state for post-checkout" "$output_file"; then
        pass "Repair output mentioned post-checkout repair"
    else
        fail "Repair output missing post-checkout repair message"
        return 1
    fi
}

test_reinstall_repairs_precommit_migration_legacy_post_checkout_hook() {
    info "Testing reinstall repairs duplicate post-checkout.legacy left by pre-commit migration mode..."

    local repo_dir="$TEST_DIR/repo-precommit-migration-legacy-post-checkout"
    create_test_repo "$repo_dir"

    local hook_file
    hook_file="$(get_hook_file_for_repo "$repo_dir" "post-checkout")" || {
        fail "Unable to resolve post-checkout hook path"
        return 1
    }

    cat > "$hook_file" << 'EOF'
#!/usr/bin/env bash
# File generated by pre-commit: https://pre-commit.com
# ID: 138fd403232d2ddd5efb44317e38bf03

# start templated
INSTALL_PYTHON=/tmp/fake-pre-commit-python
ARGS=(hook-impl --config=.pre-commit-config.yaml --hook-type=post-checkout)
# end templated

HERE="$(cd "$(dirname "$0")" && pwd)"
ARGS+=(--hook-dir "$HERE" -- "$@")

exit 0
EOF
    chmod +x "$hook_file"

    cp "$PROJECT_DIR/hooks/local-override-post-checkout" "$hook_file.legacy"
    chmod +x "$hook_file.legacy"

    local output_file="$TEST_DIR/install-precommit-migration-legacy-post-checkout.log"
    if ! "$PROJECT_DIR/scripts/install.sh" --repo > "$output_file" 2>&1; then
        fail "Reinstall failed while repairing pre-commit migration mode"
        cat "$output_file" || true
        return 1
    fi

    local marker
    marker="$(managed_hook_marker_for_test "post-checkout")"
    if grep -qxF "$marker" "$hook_file"; then
        pass "Canonical post-checkout became managed after reinstall"
    else
        fail "Canonical post-checkout did not become managed after reinstall"
        return 1
    fi

    if [[ -f "$hook_file.chained" ]] && grep -q "File generated by pre-commit" "$hook_file.chained"; then
        pass "Pre-commit wrapper preserved as post-checkout.chained"
    else
        fail "Pre-commit wrapper was not preserved as post-checkout.chained"
        return 1
    fi

    if [[ ! -f "$hook_file.legacy" ]]; then
        pass "Duplicate managed post-checkout.legacy removed during reinstall"
    else
        fail "Duplicate managed post-checkout.legacy still exists after reinstall"
        return 1
    fi
}

test_reinstall_repairs_transitioned_precommit_legacy_post_checkout_hook() {
    info "Testing reinstall repairs stale post-checkout.legacy after managed hook transition..."

    local repo_dir="$TEST_DIR/repo-transitioned-precommit-legacy-post-checkout"
    create_test_repo "$repo_dir"

    if ! "$PROJECT_DIR/scripts/install.sh" --repo >/dev/null 2>&1; then
        fail "Initial install failed before transitioned legacy repair test"
        return 1
    fi

    local hook_file
    hook_file="$(get_hook_file_for_repo "$repo_dir" "post-checkout")" || {
        fail "Unable to resolve post-checkout hook path"
        return 1
    }

    cat > "$hook_file.chained" << 'EOF'
#!/usr/bin/env bash
# File generated by pre-commit: https://pre-commit.com
# ID: 138fd403232d2ddd5efb44317e38bf03

# start templated
INSTALL_PYTHON=/tmp/fake-pre-commit-python
ARGS=(hook-impl --config=.pre-commit-config.yaml --hook-type=post-checkout)
# end templated

HERE="$(cd "$(dirname "$0")" && pwd)"
ARGS+=(--hook-dir "$HERE" -- "$@")

exit 0
EOF
    chmod +x "$hook_file.chained"

    cp "$PROJECT_DIR/hooks/local-override-post-checkout" "$hook_file.legacy"
    chmod +x "$hook_file.legacy"

    local output_file="$TEST_DIR/install-transitioned-precommit-legacy-post-checkout.log"
    if ! "$PROJECT_DIR/scripts/install.sh" --repo > "$output_file" 2>&1; then
        fail "Reinstall failed while repairing transitioned pre-commit legacy state"
        cat "$output_file" || true
        return 1
    fi

    local marker
    marker="$(managed_hook_marker_for_test "post-checkout")"
    if grep -qxF "$marker" "$hook_file"; then
        pass "Canonical post-checkout remained managed after transitioned repair"
    else
        fail "Canonical post-checkout did not remain managed after transitioned repair"
        return 1
    fi

    if grep -q 'exec "${BASH_SOURCE\[0\]}\.chained" "\$@"' "$hook_file"; then
        pass "Managed post-checkout still chains after transitioned repair"
    else
        fail "Managed post-checkout lost chain logic after transitioned repair"
        return 1
    fi

    if [[ -f "$hook_file.chained" ]] && grep -q "File generated by pre-commit" "$hook_file.chained"; then
        pass "Pre-commit wrapper preserved as post-checkout.chained after transitioned repair"
    else
        fail "Pre-commit wrapper missing after transitioned repair"
        return 1
    fi

    if [[ ! -f "$hook_file.legacy" ]]; then
        pass "Stale transitioned post-checkout.legacy removed during reinstall"
    else
        fail "Stale transitioned post-checkout.legacy still exists after reinstall"
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

test_reinstall_clears_legacy_skip_worktree_and_preserves_foreign_attributes() {
    info "Testing reinstall clears legacy skip-worktree and preserves foreign attrs..."

    local repo_dir="$TEST_DIR/repo-reinstall-legacy-skip-worktree"
    create_test_repo "$repo_dir"

    cat > "$repo_dir/AGENTS.md" << 'EOF'
# Original AGENTS
EOF

    cd "$repo_dir"
    git add AGENTS.md
    git commit -q -m "Add AGENTS target"

    cat > "$repo_dir/.local-overrides.yaml" << 'EOF'
pattern: ".local"
files:
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
EOF

    cat > "$repo_dir/AGENTS.local.md" << 'EOF'
# Local AGENTS
EOF

    "$PROJECT_DIR/scripts/install.sh" --repo >/dev/null 2>&1

    local attributes_file
    attributes_file="$(get_attributes_file_for_repo "$repo_dir")" || {
        fail "Unable to resolve attributes file"
        return 1
    }

    cat > "$attributes_file" << 'EOF'
**/AGENTS.md filter=agents-local

# Auto-generated by git-local-override - do not edit manually
README.md filter=local-override
EOF

    cp AGENTS.local.md AGENTS.md
    git update-index --skip-worktree -- AGENTS.md

    if [[ "$(get_index_flag_for_repo "$repo_dir" "AGENTS.md")" == "S" ]]; then
        pass "Pre-condition: legacy skip-worktree bit set on AGENTS.md"
    else
        fail "Pre-condition: unable to set legacy skip-worktree bit on AGENTS.md"
        return 1
    fi

    local output_file="$TEST_DIR/reinstall-legacy-skip-worktree.log"
    if ! "$PROJECT_DIR/scripts/install.sh" --repo > "$output_file" 2>&1; then
        fail "Reinstall failed during legacy skip-worktree test"
        cat "$output_file" || true
        return 1
    fi

    if [[ "$(get_index_flag_for_repo "$repo_dir" "AGENTS.md")" != "S" ]]; then
        pass "Reinstall cleared legacy skip-worktree bit"
    else
        fail "Reinstall did not clear legacy skip-worktree bit"
        return 1
    fi

    if grep -q "Cleared legacy skip-worktree on 1 managed file(s)" "$output_file"; then
        pass "Reinstall reported legacy skip-worktree repair"
    else
        fail "Reinstall did not report legacy skip-worktree repair"
        cat "$output_file" || true
        return 1
    fi

    local repair_marker
    repair_marker="$(git -C "$repo_dir" rev-parse --absolute-git-dir)/local-override-skipworktree-repaired"
    if [[ -f "$repair_marker" ]]; then
        pass "install writes skip-worktree repair marker"
    else
        fail "install did not write skip-worktree repair marker ($repair_marker)"
        return 1
    fi

    if grep -q '^\*\*/AGENTS.md filter=agents-local$' "$attributes_file"; then
        pass "Foreign attributes entry preserved on reinstall"
    else
        fail "Foreign attributes entry was removed during reinstall"
        cat "$attributes_file" || true
        return 1
    fi

    if grep -q '^AGENTS.md filter=local-override$' "$attributes_file"; then
        pass "Managed local-override entry refreshed on reinstall"
    else
        fail "Managed local-override entry missing after reinstall"
        cat "$attributes_file" || true
        return 1
    fi

    if grep -q '^README.md filter=local-override$' "$attributes_file"; then
        fail "Stale managed attributes entry was not removed on reinstall"
        cat "$attributes_file" || true
        return 1
    fi
    pass "Stale managed local-override entries removed without touching foreign attrs"
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

test_install_global_filter_inherited_in_new_repo() {
    info "Testing install.sh --global filter driver works end-to-end in a fresh repo..."

    # Sandbox guard: global-config writes must land inside the per-test root,
    # never in the developer's real ~/.gitconfig.
    if [[ "$HOME" == "$CURRENT_TEST_ROOT"/* && "$XDG_CONFIG_HOME" == "$CURRENT_TEST_ROOT"/* ]]; then
        pass "Sandboxed HOME/XDG_CONFIG_HOME in effect"
    else
        fail "Global-config sandbox not in effect (HOME=$HOME, XDG_CONFIG_HOME=$XDG_CONFIG_HOME)"
        return 1
    fi

    "$PROJECT_DIR/scripts/install.sh" --global >/dev/null

    # A brand-new repo created AFTER the global install inherits the template
    # hooks (init.templateDir) and the global filter driver.
    local repo_dir="$TEST_DIR/repo-global-inherit"
    mkdir -p "$repo_dir"
    cd "$repo_dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"

    local global_clean local_clean
    global_clean=$(git config --get filter.local-override.clean 2>/dev/null || echo "")
    local_clean=$(git config --local --get filter.local-override.clean 2>/dev/null || echo "")
    if [[ -n "$global_clean" && -z "$local_clean" ]]; then
        pass "Filter driver resolves from the inherited global config only"
    else
        fail "Filter driver not inherited from global config (effective: '$global_clean', local: '$local_clean')"
        return 1
    fi

    # Managed target: original committed first, override created after, so the
    # initial commit is clean of override content.
    cat > .local-overrides.yaml << 'EOF'
pattern: ".local"
files:
  - override: notes.local.md
    replaces:
      - notes.md
EOF
    printf 'original tracked notes\n' > notes.md
    git add .local-overrides.yaml notes.md
    git commit -q -m "Add managed target"
    printf 'LOCAL OVERRIDE notes\n' > notes.local.md

    # A real branch switch fires the template-installed post-checkout hook,
    # which syncs .git/info/attributes and arms the inherited filter driver.
    git checkout -q -b feature
    git checkout -q -

    if grep -q "notes.md filter=local-override" .git/info/attributes 2>/dev/null; then
        pass "Template post-checkout hook armed the attributes in the fresh repo"
    else
        fail "Attributes not armed after branch switch: $(cat .git/info/attributes 2>/dev/null || echo '<missing>')"
        return 1
    fi

    # End-to-end smudge through the inherited global driver: a file checkout
    # must serve the override content.
    rm -f notes.md
    git checkout -- notes.md
    printf 'LOCAL OVERRIDE notes\n' > .expected-override.md
    if cmp -s notes.md .expected-override.md; then
        pass "Inherited smudge filter served override content on checkout"
    else
        fail "Inherited smudge did not serve override (got: '$(cat notes.md)')"
        return 1
    fi

    # End-to-end clean: staging the override-bearing worktree file must put the
    # original tracked bytes in the index (file-based cmp, no $(...)).
    git add notes.md
    git show :notes.md > .staged-notes.md
    printf 'original tracked notes\n' > .expected-original.md
    if cmp -s .staged-notes.md .expected-original.md; then
        pass "Inherited clean filter staged the original tracked content"
    else
        fail "Inherited clean did not restore original in index"
        return 1
    fi

    # The filters that just fired must be the INHERITED ones: if the plan-050
    # self-heal had kicked in (i.e. the global config were broken), it would
    # have written a local driver and masked the inheritance bug.
    local_clean=$(git config --local --get filter.local-override.clean 2>/dev/null || echo "")
    if [[ -z "$local_clean" ]]; then
        pass "No local driver was self-healed — the global driver did the work"
    else
        fail "Local driver appeared ('$local_clean') — global inheritance did not carry the flow"
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
    local resolver_path="${XDG_DATA_HOME:-$HOME/.local/share}/git-local-override/local-override-resolver.sh"
    local version_path="${XDG_DATA_HOME:-$HOME/.local/share}/git-local-override/VERSION"
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

    if [[ -f "$resolver_path" ]]; then
        pass "CLI shared resolver installed"
    else
        fail "CLI shared resolver not installed"
        return 1
    fi

    if [[ -f "$version_path" ]]; then
        pass "CLI version file installed"
    else
        fail "CLI version file not installed"
        return 1
    fi

    # Check CLI works
    if "$cli_path" help | grep -q "git-local-override"; then
        pass "CLI tool functional"
    else
        fail "CLI tool not functional"
        return 1
    fi

    if [[ "$("$cli_path" --version)" == "$(tr -d '\r' < "$PROJECT_DIR/VERSION")" ]]; then
        pass "Installed CLI reports expected version"
    else
        fail "Installed CLI version output is wrong"
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

test_uninstall_removes_all_installed_artifacts() {
    info "Testing uninstall removes every installed artifact..."

    # Reset global config first
    reset_git_config

    local repo_dir="$TEST_DIR/repo-uninstall-artifacts"
    create_test_repo "$repo_dir"

    # Install CLI + repo hooks/filters
    "$PROJECT_DIR/scripts/install.sh" --repo --cli

    local data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/git-local-override"
    local shell_init_file="$data_dir/local-override-shell-init.sh"
    local resolver_file="$data_dir/local-override-resolver.sh"
    local version_file="$data_dir/VERSION"

    local hooks_dir
    hooks_dir="$(get_common_hooks_dir_for_repo "$repo_dir")" || {
        fail "Pre-condition: could not resolve hooks dir"
        return 1
    }
    local filter_process_hook="$hooks_dir/local-override-filter-process"

    # Pre-conditions: the newer installed artifacts must be present
    if [[ -f "$shell_init_file" ]]; then
        pass "Pre-condition: shell-init installed in data dir"
    else
        fail "Pre-condition: shell-init not installed in data dir"
        return 1
    fi

    if [[ -f "$filter_process_hook" ]]; then
        pass "Pre-condition: filter-process installed in hooks dir"
    else
        fail "Pre-condition: filter-process not installed in hooks dir"
        return 1
    fi

    # Run uninstall (non-interactive)
    local uninstall_output="$TEST_DIR/uninstall-artifacts.out"
    run_uninstall_non_interactive_capture "$uninstall_output"

    # filter-process must be gone from the hooks dir
    if [[ ! -f "$filter_process_hook" ]]; then
        pass "filter-process removed from hooks dir"
    else
        fail "filter-process still present in hooks dir"
        return 1
    fi

    # Data dir either removed entirely, or contains none of the CLI data files
    if [[ ! -d "$data_dir" ]]; then
        pass "CLI data dir removed"
    elif [[ ! -f "$resolver_file" && ! -f "$shell_init_file" && ! -f "$version_file" ]]; then
        pass "CLI data files removed from data dir"
    else
        fail "CLI data files survive in data dir after uninstall"
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

    # Copying hooks from init.templateDir at `git init` is core git behavior,
    # not version-dependent, so the template copy MUST happen.
    if [[ -f "$new_repo/.git/hooks/pre-commit" ]] &&
       grep -q "local-override" "$new_repo/.git/hooks/pre-commit" 2>/dev/null; then
        pass "New repo got hooks from template"
    else
        fail "New repo did not get hooks from git template"
        echo "  init.templateDir: $(git config --global init.templateDir 2>/dev/null || echo '<unset>')"
        echo "  template hooks dir contents:"
        ls -la "$(git config --global init.templateDir 2>/dev/null)/hooks" 2>&1 | sed 's/^/    /' || true
        echo "  new repo hooks dir contents:"
        ls -la "$new_repo/.git/hooks" 2>&1 | sed 's/^/    /' || true
        return 1
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

test_install_filter_process_mode() {
    info "Testing opt-in filter.process install wiring (experimental)..."

    local repo_dir="$TEST_DIR/repo-filter-process"
    create_test_repo "$repo_dir"

    # Config + a committed managed target to drive smudge/clean end to end.
    cat > "$repo_dir/.local-overrides.yaml" << 'EOF'
pattern: ".local"
files:
  - override: AGENTS.local.md
    replaces:
      - AGENTS.md
EOF
    printf 'original tracked content\n' > "$repo_dir/AGENTS.md"
    git -C "$repo_dir" add .local-overrides.yaml AGENTS.md
    git -C "$repo_dir" commit -q -m "Add managed target"

    # Opt-in process-mode install.
    ( cd "$repo_dir" && GIT_LOCAL_OVERRIDE_FILTER_PROCESS=1 "$PROJECT_DIR/scripts/install.sh" --repo )

    cd "$repo_dir"

    # filter.local-override.process is set to an existing, executable script.
    local process_cmd
    process_cmd=$(git config --local filter.local-override.process 2>/dev/null || echo "")
    if [[ -n "$process_cmd" ]] && [[ "$process_cmd" == *"local-override-filter-process"* ]]; then
        pass "Filter process command configured"
    else
        fail "Filter process command not configured (got: '$process_cmd')"
        return 1
    fi
    if [[ -x "$process_cmd" ]]; then
        pass "Filter process script exists and is executable"
    else
        fail "Filter process script missing or not executable (got: '$process_cmd')"
        return 1
    fi

    # Process mode replaces per-file mode: smudge must NOT be set.
    local smudge_cmd
    smudge_cmd=$(git config --local filter.local-override.smudge 2>/dev/null || echo "")
    if [[ -z "$smudge_cmd" ]]; then
        pass "Per-file smudge unset in process mode"
    else
        fail "Per-file smudge still set in process mode (got: '$smudge_cmd')"
        return 1
    fi

    # End-to-end smudge through the real protocol: checkout serves override.
    printf 'LOCAL OVERRIDE content\n' > "$repo_dir/AGENTS.local.md"
    rm -f "$repo_dir/AGENTS.md"
    git -C "$repo_dir" checkout -- AGENTS.md
    if [[ "$(cat "$repo_dir/AGENTS.md")" == "LOCAL OVERRIDE content" ]]; then
        pass "Process-mode smudge served override content on checkout"
    else
        fail "Process-mode smudge did not serve override (got: '$(cat "$repo_dir/AGENTS.md")')"
        return 1
    fi

    # End-to-end clean: staging the override yields the original tracked bytes.
    git -C "$repo_dir" add AGENTS.md
    local staged_file="$repo_dir/.staged-agents.md"
    git -C "$repo_dir" show :AGENTS.md > "$staged_file"
    printf 'original tracked content\n' > "$repo_dir/.expected-agents.md"
    if cmp -s "$staged_file" "$repo_dir/.expected-agents.md"; then
        pass "Process-mode clean staged the original tracked content"
    else
        fail "Process-mode clean did not restore original in index"
        return 1
    fi

    # doctor treats a .process driver as healthy.
    if "$PROJECT_DIR/bin/git-local-override" doctor >/dev/null 2>&1; then
        pass "doctor reports healthy with filter.process driver"
    else
        fail "doctor failed with filter.process driver"
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
        local-override-resolver.sh \
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
       [[ ! -f "$common_hooks_dir/local-override-filter-clean" ]] ||
       [[ ! -f "$common_hooks_dir/local-override-resolver.sh" ]]; then
        fail "Pre-condition: linked worktree managed helper scripts missing from common hooks directory"
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
       [[ -f "$common_hooks_dir/local-override-filter-clean" ]] ||
       [[ -f "$common_hooks_dir/local-override-resolver.sh" ]]; then
        fail "Managed helper scripts were not removed from common hooks directory"
        return 1
    fi
    pass "Managed helper scripts removed from common hooks directory"

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

    if [[ ! -f ".git/hooks/local-override-resolver.sh" ]]; then
        fail "Shared resolver script not installed"
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
    local test_exit
    for test_fn in \
        test_install_to_repo \
        test_install_with_existing_hooks \
        test_install_executes_chained_pre_commit_hook \
        test_install_idempotent \
        test_reinstall_upgrades_managed_pre_commit_hook \
        test_reinstall_upgrades_managed_pre_rebase_hook \
        test_reinstall_preserves_existing_chained_hook \
        test_reinstall_prunes_stale_managed_post_commit_chained_hook \
        test_install_warns_on_ambiguous_pre_commit_hook \
        test_install_repairs_ambiguous_pre_commit_hook \
        test_repair_install_is_idempotent_after_pre_commit_repair \
        test_install_repairs_ambiguous_post_checkout_hook \
        test_reinstall_repairs_precommit_migration_legacy_post_checkout_hook \
        test_reinstall_repairs_transitioned_precommit_legacy_post_checkout_hook \
        test_reinstall_prunes_stale_managed_artifacts \
        test_reinstall_clears_legacy_skip_worktree_and_preserves_foreign_attributes \
        test_install_global \
        test_install_global_filter_inherited_in_new_repo \
        test_install_cli \
        test_install_gitignore \
        test_uninstall_from_repo \
        test_uninstall_removes_all_installed_artifacts \
        test_uninstall_restores_chained_hook_when_wrapper_is_managed \
        test_uninstall_does_not_overwrite_newer_user_hook \
        test_new_repo_gets_hooks_after_global_install \
        test_install_configures_filter_driver \
        test_install_filter_process_mode \
        test_install_populates_attributes \
        test_install_idempotent_attributes \
        test_uninstall_removes_filter_config \
        test_global_uninstall_removes_global_filter_config \
        test_global_uninstall_removes_pre_rebase_artifacts \
        test_repo_uninstall_uses_git_resolved_paths_in_linked_worktree \
        test_install_filter_scripts_executable; do
        CURRENT_TEST_NAME="$test_fn"
        setup

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

    finish_suite
}

main "$@"
