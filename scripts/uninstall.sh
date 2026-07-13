#!/usr/bin/env bash
#
# uninstall-local-override.sh
#
# Removes the git local-override system.
# This removes:
#   - CLI tool from ~/.local/bin
#   - CLI shared resolver from ~/.local/share/git-local-override
#   - Repository managed hooks/config (when run inside a repository)
#   - Global template managed hooks (if --global was used)
#   - Global filter.local-override.* config
#   - Gitignore patterns for *.local.* files (with confirmation)
#
set -euo pipefail

# Configuration directories
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/git"
TEMPLATE_HOOKS_DIR="$CONFIG_DIR/template/hooks"
BIN_DIR="${HOME}/.local/bin"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/git-local-override"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# The canonical primitives this script needs — get_repo_root,
# get_common_git_dir, get_attributes_file_path, sync_attributes_entries, and
# the managed-hook marker predicate (is_managed_wrapper_hook) — live in the
# shared resolver. Locate it via an offline-only ladder (uninstall must never
# need the network): the source checkout, then the installed copies this
# script is about to remove. Sourcing loads the functions into memory first,
# so removal order does not matter. Note an *installed* (possibly older)
# resolver is the right one to use here: its attributes/marker formats match
# what is actually on disk.
SCRIPT_DIR=""
PROJECT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$SCRIPT_DIR/../shared/local-override-resolver.sh" ]]; then
        PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    fi
fi

# Minimal inline probe (the resolver cannot locate itself): the current
# repo's common hooks dir, where repo installs place a resolver copy.
repo_hooks_resolver_candidate() {
    local repo_root=""
    local common_dir=""

    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
    [[ -n "$repo_root" ]] || return 1
    common_dir="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null || echo "")"
    [[ -n "$common_dir" ]] || return 1
    [[ "$common_dir" == /* ]] || common_dir="$repo_root/$common_dir"
    printf '%s\n' "$common_dir/hooks/local-override-resolver.sh"
}

RESOLVER_AVAILABLE=false
resolver_candidate=""
for resolver_candidate in \
    "${PROJECT_DIR:+$PROJECT_DIR/shared/local-override-resolver.sh}" \
    "$DATA_DIR/local-override-resolver.sh" \
    "$(repo_hooks_resolver_candidate 2>/dev/null || true)" \
    "$TEMPLATE_HOOKS_DIR/local-override-resolver.sh"; do
    [[ -n "$resolver_candidate" && -f "$resolver_candidate" ]] || continue
    # shellcheck disable=SC1090
    source "$resolver_candidate"
    RESOLVER_AVAILABLE=true
    break
done

reconcile_wrapper_hook_on_uninstall() {
    local hooks_dir="$1"
    local hook_type="$2"
    local scope_label="$3"
    local hook_file="$hooks_dir/$hook_type"
    local chained_file="$hook_file.chained"

    if [[ -f "$hook_file" ]] && is_managed_wrapper_hook "$hook_file" "$hook_type"; then
        if [[ -f "$chained_file" ]]; then
            rm "$hook_file"
            mv "$chained_file" "$hook_file"
            success "Restored chained $scope_label hook: $hook_type"
        else
            rm "$hook_file"
            success "Removed managed $scope_label hook: $hook_type"
        fi
        return 0
    fi

    if [[ ! -f "$hook_file" && -f "$chained_file" ]]; then
        mv "$chained_file" "$hook_file"
        success "Restored chained $scope_label hook: $hook_type"
        return 0
    fi

    if [[ -f "$hook_file" && -f "$chained_file" ]]; then
        warn "Ambiguous state for $scope_label hook '$hook_type': canonical hook is unmanaged while $hook_type.chained exists; preserving both"
    fi
}

remove_managed_hook_artifacts() {
    local hooks_dir="$1"
    local scope_label="$2"
    local artifact

    # The removable set derives from the resolver's runtime manifest (only
    # called when RESOLVER_AVAILABLE=true): the runtime files themselves plus
    # the prefixed helper-style hook copies older installers left behind.
    for artifact in $(managed_runtime_files) $(managed_hook_types | sed 's/^/local-override-/'); do
        local artifact_file="$hooks_dir/$artifact"
        if [[ -f "$artifact_file" ]]; then
            rm "$artifact_file"
            success "Removed $scope_label artifact: $artifact_file"
        fi
    done
}

remove_repo_managed_state() {
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

    if [[ -z "$repo_root" ]]; then
        info "Not in a git repository, skipping repository-managed cleanup"
        return 0
    fi

    if [[ "$RESOLVER_AVAILABLE" != true ]]; then
        warn "Shared resolver not found (no checkout or installed copy); skipping repository hook and attributes cleanup"
    else
        local common_git_dir
        common_git_dir="$(get_common_git_dir "$repo_root" 2>/dev/null || echo "")"
        if [[ -z "$common_git_dir" ]]; then
            warn "Unable to resolve git common directory; skipping repository hook cleanup"
        else
            local hooks_dir="$common_git_dir/hooks"
            if [[ -d "$hooks_dir" ]]; then
                info "Reconciling repository hooks in: $hooks_dir"
                local hook_type
                for hook_type in $(managed_hook_types); do
                    reconcile_wrapper_hook_on_uninstall "$hooks_dir" "$hook_type" "repository"
                done
                remove_managed_hook_artifacts "$hooks_dir" "repository"
            fi
        fi
    fi

    info "Removing local filter driver configuration..."
    git -C "$repo_root" config --local --remove-section filter.local-override 2>/dev/null || true
    git -C "$repo_root" config --local --unset-all filter.local-override.smudge 2>/dev/null || true
    git -C "$repo_root" config --local --unset-all filter.local-override.clean 2>/dev/null || true
    git -C "$repo_root" config --local --unset-all filter.local-override.required 2>/dev/null || true
    success "Removed local filter.local-override config"

    if [[ "$RESOLVER_AVAILABLE" == true ]]; then
        local attributes_file
        attributes_file="$(get_attributes_file_path "$repo_root" 2>/dev/null || echo "")"
        if [[ -z "$attributes_file" ]]; then
            warn "Unable to resolve git attributes path; skipping attributes cleanup"
        elif [[ -f "$attributes_file" ]]; then
            # The resolver's canonical rewrite with empty entries: foreign
            # lines kept, managed block dropped — exactly "uninstall". The
            # -f guard keeps uninstall from creating an attributes file
            # where none existed.
            if sync_attributes_entries "$repo_root" ""; then
                success "Removed local-override entries from: $attributes_file"
            else
                warn "Unable to rewrite $attributes_file; managed entries may remain"
            fi
        fi
    fi
}

#------------------------------------------------------------------------------
# Uninstallation Functions
#------------------------------------------------------------------------------

remove_cli_tool() {
    info "Removing CLI tool..."

    local cli_tool="$BIN_DIR/git-local-override"

    if [[ -f "$cli_tool" ]]; then
        rm "$cli_tool"
        success "Removed: $cli_tool"
    else
        info "CLI tool not found (already removed?)"
    fi

    local resolver_file="$DATA_DIR/local-override-resolver.sh"
    if [[ -f "$resolver_file" ]]; then
        rm "$resolver_file"
        success "Removed: $resolver_file"
    fi

    local shell_init_file="$DATA_DIR/local-override-shell-init.sh"
    if [[ -f "$shell_init_file" ]]; then
        rm "$shell_init_file"
        success "Removed: $shell_init_file"
    fi

    local version_file="$DATA_DIR/VERSION"
    if [[ -f "$version_file" ]]; then
        rm "$version_file"
        success "Removed: $version_file"
    fi

    if [[ -d "$DATA_DIR" ]] && [[ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
        rmdir "$DATA_DIR" 2>/dev/null || true
    fi
}

remove_template_hooks() {
    info "Removing global template hook scripts..."

    if [[ ! -d "$TEMPLATE_HOOKS_DIR" ]]; then
        info "No global template hooks directory found"
        return 0
    fi

    if [[ "$RESOLVER_AVAILABLE" != true ]]; then
        warn "Shared resolver not found (no checkout or installed copy); skipping template hook cleanup"
        return 0
    fi

    # Reconcile wrapper hooks safely.
    local hook_type
    for hook_type in $(managed_hook_types); do
        reconcile_wrapper_hook_on_uninstall "$TEMPLATE_HOOKS_DIR" "$hook_type" "template"
    done

    # Remove managed helper/filter artifacts.
    remove_managed_hook_artifacts "$TEMPLATE_HOOKS_DIR" "template"

    # Remove hooks directory if empty
    if [[ -d "$TEMPLATE_HOOKS_DIR" ]] && [[ -z "$(ls -A "$TEMPLATE_HOOKS_DIR" 2>/dev/null)" ]]; then
        rmdir "$TEMPLATE_HOOKS_DIR"
        info "Removed empty directory: $TEMPLATE_HOOKS_DIR"
    fi
}

uninstall_filters() {
    # Kept for backward compatibility; repo filter cleanup is handled by
    # remove_repo_managed_state() to ensure git-resolved paths and hook symmetry.
    remove_repo_managed_state
}

remove_global_filter_config() {
    info "Removing global filter.local-override config..."

    git config --global --remove-section filter.local-override 2>/dev/null || true
    git config --global --unset-all filter.local-override.smudge 2>/dev/null || true
    git config --global --unset-all filter.local-override.clean 2>/dev/null || true
    git config --global --unset-all filter.local-override.required 2>/dev/null || true

    success "Removed global filter.local-override config"
}

remove_git_template_config() {
    # Check if we set the git template directory
    local template_dir
    template_dir=$(git config --global init.templateDir 2>/dev/null || echo "")
    local expected_template_dir="${XDG_CONFIG_HOME:-$HOME/.config}/git/template"

    if [[ "$template_dir" == "$expected_template_dir" ]]; then
        echo ""
        read -p "Remove git template directory config? [y/N] " -n 1 -r
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            git config --global --unset init.templateDir
            success "Removed git template directory configuration"
        else
            info "Preserved git template directory configuration"
        fi
    fi
}

remove_gitignore_patterns() {
    info "Checking global gitignore..."

    local gitignore_file
    gitignore_file=$(git config --global core.excludesfile 2>/dev/null || echo "")

    if [[ -z "$gitignore_file" ]]; then
        info "No global gitignore configured"
        return 0
    fi

    # Expand ~ in path
    gitignore_file="${gitignore_file/#\~/$HOME}"

    if [[ ! -f "$gitignore_file" ]]; then
        info "Global gitignore file not found: $gitignore_file"
        return 0
    fi

    # Check if our patterns exist (look for our comment or the patterns)
    if ! grep -q 'git-local-override\|git local-override' "$gitignore_file" 2>/dev/null; then
        info "No local-override patterns found in gitignore"
        return 0
    fi

    echo ""
    echo "Found local-override patterns in: $gitignore_file"
    read -p "Remove gitignore patterns? [y/N] " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Create temp file without our patterns
        local temp_file
        temp_file=$(mktemp)

        local skip_block=false
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Match our comment (both old and new style)
            if [[ "$line" == *"git local-override"* || "$line" == *"git-local-override"* ]]; then
                skip_block=true
                continue
            fi
            if [[ "$skip_block" == true ]]; then
                if [[ "$line" == "*.local.*" || "$line" == "*.local" ]]; then
                    continue
                fi
                skip_block=false
            fi
            echo "$line" >> "$temp_file"
        done < "$gitignore_file"

        mv "$temp_file" "$gitignore_file"
        success "Removed patterns from: $gitignore_file"
    else
        info "Preserved gitignore patterns"
    fi
}

print_warning_about_repos() {
    echo ""
    info "Repository cleanup runs only when uninstall is executed inside that repository."
    echo "Run ./scripts/uninstall.sh inside each repo where hooks were installed."
    echo ""
}

print_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Uninstallation Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    echo ""
    echo -e "${BLUE}Uninstalling git local-override system...${NC}"
    echo ""

    remove_cli_tool
    remove_template_hooks
    remove_global_filter_config
    uninstall_filters
    remove_git_template_config
    remove_gitignore_patterns
    print_warning_about_repos
    print_summary
}

main "$@"
