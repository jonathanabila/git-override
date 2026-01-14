#!/usr/bin/env bash
#
# uninstall-local-override.sh
#
# Removes the git local-override system.
# This removes:
#   - CLI tool from ~/.local/bin
#   - Global template hooks from ~/.config/git/template/hooks (if --global was used)
#   - Gitignore patterns for *.local.* files
#
# Note: This does NOT automatically remove hooks from individual repositories.
# You must manually remove hooks from each repo's .git/hooks/ directory.
#
set -euo pipefail

# Configuration directories
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/git"
TEMPLATE_HOOKS_DIR="$CONFIG_DIR/template/hooks"
BIN_DIR="${HOME}/.local/bin"

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
}

remove_template_hooks() {
    info "Removing global template hook scripts..."

    if [[ ! -d "$TEMPLATE_HOOKS_DIR" ]]; then
        info "No global template hooks directory found"
        return 0
    fi

    # Remove our hooks and shared library
    for hook in local-override-post-checkout local-override-pre-commit local-override-post-commit local-override-lib.sh; do
        local hook_file="$TEMPLATE_HOOKS_DIR/$hook"

        if [[ -f "$hook_file" ]]; then
            rm "$hook_file"
            success "Removed: $hook_file"
        fi
    done

    # Also check for the wrapper hooks we create
    for hook_type in post-checkout pre-commit post-commit; do
        local hook_file="$TEMPLATE_HOOKS_DIR/$hook_type"
        if [[ -f "$hook_file" ]] && grep -q "local-override" "$hook_file" 2>/dev/null; then
            rm "$hook_file"
            success "Removed: $hook_file"
        fi
    done

    # Remove hooks directory if empty
    if [[ -d "$TEMPLATE_HOOKS_DIR" ]] && [[ -z "$(ls -A "$TEMPLATE_HOOKS_DIR" 2>/dev/null)" ]]; then
        rmdir "$TEMPLATE_HOOKS_DIR"
        info "Removed empty directory: $TEMPLATE_HOOKS_DIR"
    fi
}

remove_git_template_config() {
    # Check if we set the git template directory
    local template_dir
    template_dir=$(git config --global init.templateDir 2>/dev/null || echo "")

    if [[ "$template_dir" == *"/.config/git/template"* ]]; then
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
    warn "Repository hooks are NOT automatically removed."
    echo ""
    echo "If you installed hooks in repositories, you should manually clean them up:"
    echo ""
    echo "Option 1: In each repository, remove the hooks:"
    echo "  $ rm .git/hooks/post-checkout .git/hooks/pre-commit .git/hooks/post-commit"
    echo "  $ mv .git/hooks/post-checkout.chained .git/hooks/post-checkout  # if exists"
    echo "  $ mv .git/hooks/pre-commit.chained .git/hooks/pre-commit        # if exists"
    echo "  $ mv .git/hooks/post-commit.chained .git/hooks/post-commit      # if exists"
    echo ""
    echo "Option 2: Just leave them - they'll silently do nothing without the global scripts."
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
    remove_git_template_config
    remove_gitignore_patterns
    print_warning_about_repos
    print_summary
}

main "$@"
