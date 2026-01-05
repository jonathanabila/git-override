#!/usr/bin/env bash
#
# install.sh
#
# Installs git-local-override hooks.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash
#   # or
#   ./install.sh
#
# Options:
#   --global    Install to git template directory (affects new clones)
#   --repo      Install to current repository only (default)
#   --cli       Also install the CLI tool to ~/.local/bin
#
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Determine if running from cloned repo or via curl
SCRIPT_DIR=""
PROJECT_DIR=""
REMOTE_BASE="https://raw.githubusercontent.com/your-org/git-local-override/main"

if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "$SCRIPT_DIR/../hooks" ]]; then
        PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    fi
fi

# Get hook content (from local file or remote URL)
get_hook_content() {
    local hook_name="$1"

    if [[ -n "$PROJECT_DIR" && -f "$PROJECT_DIR/hooks/$hook_name" ]]; then
        cat "$PROJECT_DIR/hooks/$hook_name"
    else
        curl -fsSL "$REMOTE_BASE/hooks/$hook_name"
    fi
}

get_lib_content() {
    if [[ -n "$PROJECT_DIR" && -f "$PROJECT_DIR/hooks/local-override-lib.sh" ]]; then
        cat "$PROJECT_DIR/hooks/local-override-lib.sh"
    else
        curl -fsSL "$REMOTE_BASE/hooks/local-override-lib.sh"
    fi
}

get_cli_content() {
    if [[ -n "$PROJECT_DIR" && -f "$PROJECT_DIR/bin/git-local-override" ]]; then
        cat "$PROJECT_DIR/bin/git-local-override"
    else
        curl -fsSL "$REMOTE_BASE/bin/git-local-override"
    fi
}

# Install hooks to a directory
install_hooks_to_dir() {
    local hooks_dir="$1"
    local lib_dir="$2"

    mkdir -p "$hooks_dir"
    mkdir -p "$lib_dir"

    # Install the shared library
    info "Installing shared library..."
    get_lib_content > "$lib_dir/local-override-lib.sh"
    chmod +x "$lib_dir/local-override-lib.sh"
    success "Installed: $lib_dir/local-override-lib.sh"

    # Install each hook
    for hook_type in post-checkout pre-commit post-commit; do
        local hook_file="$hooks_dir/$hook_type"
        local our_hook="local-override-$hook_type"

        # Get our hook content
        local hook_content
        hook_content="$(get_hook_content "$our_hook")"

        # Update SCRIPT_DIR to point to lib location
        hook_content="${hook_content//\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" \&\& pwd)\"/\"$lib_dir\"}"

        if [[ -f "$hook_file" ]]; then
            # Check if already installed
            if grep -q "local-override" "$hook_file" 2>/dev/null; then
                info "Hook already installed: $hook_type"
                continue
            fi

            # Chain existing hook
            mv "$hook_file" "$hook_file.chained"
            info "Preserved existing $hook_type hook as $hook_type.chained"
        fi

        # Write our hook
        echo "$hook_content" > "$hook_file"
        chmod +x "$hook_file"

        # Add chaining logic if there's an existing hook
        if [[ -f "$hook_file.chained" ]]; then
            cat >> "$hook_file" << 'EOF'

# Chain to existing hook
if [[ -x "${BASH_SOURCE[0]}.chained" ]]; then
    exec "${BASH_SOURCE[0]}.chained" "$@"
fi
EOF
        fi

        success "Installed $hook_type hook"
    done
}

# Install to current repository
install_to_repo() {
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        error "Not in a git repository"
        exit 1
    }

    local hooks_dir="$repo_root/.git/hooks"
    local lib_dir="$repo_root/.git/hooks"

    info "Installing hooks to repository: $repo_root"
    install_hooks_to_dir "$hooks_dir" "$lib_dir"
}

# Install to git template directory (affects new clones)
install_to_template() {
    local template_dir="${XDG_CONFIG_HOME:-$HOME/.config}/git/template/hooks"
    local lib_dir="${XDG_CONFIG_HOME:-$HOME/.config}/git/hooks"

    info "Installing hooks to git template: $template_dir"
    install_hooks_to_dir "$template_dir" "$lib_dir"

    # Configure git to use the template
    git config --global init.templateDir "${XDG_CONFIG_HOME:-$HOME/.config}/git/template"
    success "Configured git template directory"

    echo ""
    info "New repositories created with 'git init' or 'git clone' will have hooks installed."
    info "For existing repositories, run: ./install.sh --repo"
}

# Install CLI tool
install_cli() {
    local bin_dir="${HOME}/.local/bin"
    mkdir -p "$bin_dir"

    info "Installing CLI tool..."
    get_cli_content > "$bin_dir/git-local-override"
    chmod +x "$bin_dir/git-local-override"
    success "Installed: $bin_dir/git-local-override"

    # Check if bin_dir is in PATH
    if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
        warn "$bin_dir is not in your PATH"
        echo "  Add this to your shell profile:"
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
}

# Setup global gitignore for .local.* files
setup_gitignore() {
    local gitignore_file
    gitignore_file=$(git config --global core.excludesfile 2>/dev/null || echo "")

    if [[ -z "$gitignore_file" ]]; then
        gitignore_file="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
        git config --global core.excludesfile "$gitignore_file"
    fi

    gitignore_file="${gitignore_file/#\~/$HOME}"
    mkdir -p "$(dirname "$gitignore_file")"

    if ! grep -q '^\*\.local\.\*$' "$gitignore_file" 2>/dev/null; then
        {
            echo ""
            echo "# git-local-override - local override files"
            echo "*.local.*"
            echo "*.local"
        } >> "$gitignore_file"
        success "Added .local.* patterns to global gitignore"
    fi
}

print_usage() {
    cat << 'EOF'
git-local-override installer

Usage:
  install.sh [options]

Options:
  --repo      Install hooks to current repository (default)
  --global    Install hooks to git template (affects new repos)
  --cli       Also install the CLI tool to ~/.local/bin
  --help      Show this help message

Examples:
  # Install to current repo
  curl -fsSL https://.../install.sh | bash

  # Install globally (template) + CLI
  curl -fsSL https://.../install.sh | bash -s -- --global --cli

  # From cloned repo
  ./scripts/install.sh --repo
EOF
}

print_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Installation Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Create a .local-overrides.yaml in your repository:"
    echo "     files:"
    echo "       - CLAUDE.md"
    echo "       - AGENTS.md"
    echo ""
    echo "  2. Create your local override file:"
    echo "     cp CLAUDE.md CLAUDE.local.md"
    echo "     # Edit CLAUDE.local.md with your customizations"
    echo ""
    echo "  3. That's it! Git operations will automatically:"
    echo "     - Show your local content in working tree"
    echo "     - Commit original content"
    echo "     - Restore your local content after commits"
    echo ""
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

main() {
    local mode="repo"
    local install_cli_tool=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)
                mode="repo"
                shift
                ;;
            --global)
                mode="global"
                shift
                ;;
            --cli)
                install_cli_tool=true
                shift
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done

    echo ""
    echo -e "${BLUE}Installing git-local-override...${NC}"
    echo ""

    case "$mode" in
        repo)
            install_to_repo
            ;;
        global)
            install_to_template
            ;;
    esac

    setup_gitignore

    if [[ "$install_cli_tool" == true ]]; then
        install_cli
    fi

    print_summary
}

main "$@"
