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
#   --resolve-ambiguous-hooks  Repair unmanaged hook + existing .chained states
#   --cli       Also install the CLI tool to ~/.local/bin
#
# INSTALLATION MODES:
# - --repo: Installs hooks directly to .git/hooks/ in current repository.
#   Best for single-repo usage or when different repos need different versions.
#
# - --global: Installs to git's template directory (~/.config/git/template/hooks/).
#   Git copies these to .git/hooks/ on every `git init` or `git clone`.
#   Best for teams where all repos should have hooks automatically.
#
# WHY GLOBAL GITIGNORE:
# We add *.local.* patterns to the global gitignore so that:
# 1. Local override files never appear in `git status`
# 2. They can't be accidentally staged or committed
# 3. Users don't need to modify each repo's .gitignore
#
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Exact marker used to identify installer-managed wrapper hooks.
# Ownership checks MUST use this marker (not fuzzy matching).
MANAGED_HOOK_MARKER_PREFIX="# git-local-override-managed-hook:"

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Determine if running from cloned repo or via curl
SCRIPT_DIR=""
PROJECT_DIR=""
REMOTE_BASE="https://raw.githubusercontent.com/jonathanabila/git-override/main"

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

get_shared_resolver_content() {
    if [[ -n "$PROJECT_DIR" && -f "$PROJECT_DIR/shared/local-override-resolver.sh" ]]; then
        cat "$PROJECT_DIR/shared/local-override-resolver.sh"
    else
        curl -fsSL "$REMOTE_BASE/shared/local-override-resolver.sh"
    fi
}

get_version_content() {
    if [[ -n "$PROJECT_DIR" && -f "$PROJECT_DIR/VERSION" ]]; then
        cat "$PROJECT_DIR/VERSION"
    else
        curl -fsSL "$REMOTE_BASE/VERSION"
    fi
}

get_cli_content() {
    if [[ -n "$PROJECT_DIR" && -f "$PROJECT_DIR/bin/git-local-override" ]]; then
        cat "$PROJECT_DIR/bin/git-local-override"
    else
        curl -fsSL "$REMOTE_BASE/bin/git-local-override"
    fi
}

managed_hook_marker_line() {
    local hook_type="$1"
    printf '%s %s' "$MANAGED_HOOK_MARKER_PREFIX" "$hook_type"
}

is_managed_wrapper_hook() {
    local hook_file="$1"
    local hook_type="$2"
    local marker

    [[ -f "$hook_file" ]] || return 1
    marker="$(managed_hook_marker_line "$hook_type")"
    grep -qxF "$marker" "$hook_file" 2>/dev/null
}

is_legacy_managed_hook() {
    local hook_file="$1"
    local hook_type="$2"

    [[ -f "$hook_file" ]] || return 1

    if is_managed_wrapper_hook "$hook_file" "$hook_type"; then
        return 1
    fi

    grep -qF "# local-override-$hook_type" "$hook_file" 2>/dev/null || return 1
    grep -qF 'source "$SCRIPT_DIR/local-override-lib.sh"' "$hook_file" 2>/dev/null || return 1
}

append_chain_logic() {
    local hook_file="$1"

    cat >> "$hook_file" << 'EOF'

# Chain to existing hook
if [[ -x "${BASH_SOURCE[0]}.chained" ]]; then
    exec "${BASH_SOURCE[0]}.chained" "$@"
fi
EOF
}

write_managed_wrapper_hook() {
    local hook_file="$1"
    local hook_type="$2"
    local hook_content="$3"
    local marker
    local temp_file

    marker="$(managed_hook_marker_line "$hook_type")"

    temp_file="$(mktemp "${hook_file}.tmp.XXXXXX")"

    printf '%s\n' "$hook_content" > "$temp_file"
    printf '%s\n' "$marker" >> "$temp_file"

    if [[ -f "$hook_file.chained" ]]; then
        append_chain_logic "$temp_file"
    fi

    chmod +x "$temp_file"
    mv "$temp_file" "$hook_file"
}

current_timestamp() {
    date '+%Y%m%d-%H%M%S'
}

create_hooks_backup_dir() {
    local hooks_dir="$1"
    local timestamp="$2"
    local backup_dir="$hooks_dir/backup-$timestamp"
    local counter=0

    while [[ -e "$backup_dir" ]]; do
        ((counter++)) || true
        backup_dir="$hooks_dir/backup-$timestamp-$counter"
    done

    mkdir "$backup_dir" || return 1
    printf '%s\n' "$backup_dir"
}

unique_stale_hook_path() {
    local hook_file="$1"
    local timestamp="$2"
    local stale_path="$hook_file.chained.stale-$timestamp"
    local counter=0

    while [[ -e "$stale_path" ]]; do
        ((counter++)) || true
        stale_path="$hook_file.chained.stale-$timestamp-$counter"
    done

    printf '%s\n' "$stale_path"
}

resolve_ambiguous_hook_state() {
    local hook_file="$1"
    local hook_type="$2"
    local hook_content="$3"
    local hooks_dir
    local chained_file="$hook_file.chained"
    local timestamp
    local backup_dir
    local stale_file

    hooks_dir="$(dirname "$hook_file")"
    timestamp="$(current_timestamp)"

    info "Resolving ambiguous state for $hook_type"

    backup_dir="$(create_hooks_backup_dir "$hooks_dir" "$timestamp")" || {
        warn "Unable to create backup directory for $hook_type repair; preserving existing files"
        return 1
    }

    if ! cp -p "$hook_file" "$backup_dir/$hook_type"; then
        warn "Unable to back up existing $hook_type hook; preserving existing files"
        rm -rf "$backup_dir" 2>/dev/null || true
        return 1
    fi

    if ! cp -p "$chained_file" "$backup_dir/$hook_type.chained"; then
        warn "Unable to back up existing $hook_type.chained; preserving existing files"
        rm -rf "$backup_dir" 2>/dev/null || true
        return 1
    fi

    info "Backed up $hook_type and $hook_type.chained to $backup_dir"

    stale_file="$(unique_stale_hook_path "$hook_file" "$timestamp")"
    if ! mv "$chained_file" "$stale_file"; then
        warn "Unable to move existing $hook_type.chained aside; preserving existing files"
        return 1
    fi
    info "Moved existing $hook_type.chained to $(basename "$stale_file")"

    if ! mv "$hook_file" "$chained_file"; then
        warn "Unable to promote existing $hook_type to $hook_type.chained; restoring original chained hook"
        mv "$stale_file" "$chained_file" 2>/dev/null || true
        return 1
    fi
    info "Promoted existing $hook_type to $hook_type.chained"

    if ! write_managed_wrapper_hook "$hook_file" "$hook_type" "$hook_content"; then
        warn "Unable to install managed $hook_type hook; restoring original files"
        mv "$chained_file" "$hook_file" 2>/dev/null || true
        mv "$stale_file" "$chained_file" 2>/dev/null || true
        return 1
    fi

    success "Installed $hook_type hook"
}

prune_stale_managed_artifacts() {
    local hooks_dir="$1"
    local artifact

    # Older installer versions could leave these helper-style artifacts behind.
    # They are not used by the current wrapper model and should be pruned on reinstall.
    for artifact in \
        local-override-post-checkout \
        local-override-pre-commit \
        local-override-post-commit \
        local-override-pre-rebase; do
        local artifact_file="$hooks_dir/$artifact"
        if [[ -f "$artifact_file" ]]; then
            rm "$artifact_file"
            info "Removed stale managed artifact: $artifact"
        fi
    done
}

prune_stale_managed_chained_hooks() {
    local hooks_dir="$1"
    local hook_type
    local chained_file

    for hook_type in post-checkout pre-commit post-commit pre-rebase; do
        chained_file="$hooks_dir/$hook_type.chained"
        if is_legacy_managed_hook "$chained_file" "$hook_type"; then
            rm "$chained_file"
            info "Removed stale managed chained hook: $hook_type.chained"
        fi
    done
}

# Resolve git common directory as an absolute path
get_common_git_dir() {
    local repo_root="$1"
    local common_git_dir

    common_git_dir="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null || echo "")"
    if [[ -z "$common_git_dir" ]]; then
        error "Unable to resolve git common directory"
        exit 1
    fi

    if [[ "$common_git_dir" != /* ]]; then
        common_git_dir="$repo_root/$common_git_dir"
    fi

    echo "$common_git_dir"
}

# Read config file and output list of target|override pairs
# Output format: target|override (one line per target file)
read_config_pairs() {
    local repo_root="$1"
    local lib_file=""

    if [[ -n "$PROJECT_DIR" && -f "$PROJECT_DIR/shared/local-override-resolver.sh" ]]; then
        lib_file="$PROJECT_DIR/shared/local-override-resolver.sh"
    else
        lib_file="$(mktemp)"
        get_shared_resolver_content > "$lib_file"
    fi

    # shellcheck disable=SC1090
    source "$lib_file"
    read_config "$repo_root"

    if [[ -z "$PROJECT_DIR" || "$lib_file" != "$PROJECT_DIR/shared/local-override-resolver.sh" ]]; then
        rm -f "$lib_file"
    fi
}

install_filter_scripts_to_dir() {
    local hooks_dir="$1"

    mkdir -p "$hooks_dir"

    local filter_script
    for filter_script in local-override-filter-smudge local-override-filter-clean; do
        get_hook_content "$filter_script" > "$hooks_dir/$filter_script"
        chmod +x "$hooks_dir/$filter_script"
        success "Installed: $hooks_dir/$filter_script"
    done
}

install_shared_resolver_to_dir() {
    local target_dir="$1"

    mkdir -p "$target_dir"
    get_shared_resolver_content > "$target_dir/local-override-resolver.sh"
    chmod +x "$target_dir/local-override-resolver.sh"
    success "Installed: $target_dir/local-override-resolver.sh"
}

sync_attributes() {
    local repo_root="$1"
    local attributes_file
    local temp_file

    attributes_file="$(git -C "$repo_root" rev-parse --git-path info/attributes 2>/dev/null || echo "")"
    if [[ -z "$attributes_file" ]]; then
        error "Unable to resolve git attributes path"
        exit 1
    fi

    if [[ "$attributes_file" != /* ]]; then
        attributes_file="$repo_root/$attributes_file"
    fi

    temp_file="$(mktemp)"

    mkdir -p "$(dirname "$attributes_file")"

    if [[ -f "$attributes_file" ]]; then
        local line
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == *"filter=local-override"* ]]; then
                continue
            fi
            if [[ "$line" == *"Auto-generated by git-local-override"* ]]; then
                continue
            fi
            echo "$line" >> "$temp_file"
        done < "$attributes_file"
    fi

    if git -C "$repo_root" ls-files --cached --others --exclude-standard --full-name 2>/dev/null | grep -qxE '(.*/)?\.local-overrides\.yaml'; then
        local seen_targets=""
        local entry
        local target
        local has_targets=false

        while IFS= read -r entry || [[ -n "$entry" ]]; do
            [[ -z "$entry" ]] && continue

            target="${entry%%|*}"
            [[ -z "$target" ]] && continue

            if echo "$seen_targets" | grep -qxF "$target"; then
                continue
            fi
            seen_targets="$seen_targets
$target"
            has_targets=true
        done < <(read_config_pairs "$repo_root")

        if [[ "$has_targets" == true ]]; then
            if [[ -s "$temp_file" ]]; then
                echo "" >> "$temp_file"
            fi

            echo "# Auto-generated by git-local-override — do not edit manually" >> "$temp_file"

            while IFS= read -r target || [[ -n "$target" ]]; do
                [[ -z "$target" ]] && continue
                echo "$target filter=local-override" >> "$temp_file"
            done <<< "$seen_targets"
        fi
    fi

    mv "$temp_file" "$attributes_file"
    success "Synced git attributes: $attributes_file"
}

install_filters() {
    local repo_root="$1"
    local hooks_dir="$2"
    local common_git_dir
    local smudge_script
    local clean_script

    info "Installing filter driver scripts..."
    install_filter_scripts_to_dir "$hooks_dir"

    common_git_dir="$(get_common_git_dir "$repo_root")"
    smudge_script="$common_git_dir/hooks/local-override-filter-smudge"
    clean_script="$common_git_dir/hooks/local-override-filter-clean"

    git -C "$repo_root" config --local filter.local-override.smudge "$smudge_script %f"
    git -C "$repo_root" config --local filter.local-override.clean "$clean_script %f"
    git -C "$repo_root" config --local filter.local-override.required false
    success "Configured local filter.local-override"

    sync_attributes "$repo_root"
}

repair_legacy_skip_worktree() {
    local repo_root="$1"
    local lib_file="$2"
    local repaired_count="0"
    local entry=""
    local target=""
    local seen_targets=""
    local ls_output=""

    if ! git -C "$repo_root" ls-files --cached --others --exclude-standard --full-name 2>/dev/null | grep -qxE '(.*/)?\.local-overrides\.yaml'; then
        return 0
    fi
    [[ -f "$lib_file" ]] || return 0

    repaired_count="$({
        # shellcheck disable=SC1090
        source "$lib_file"

        while IFS= read -r entry || [[ -n "$entry" ]]; do
            [[ -z "$entry" ]] && continue

            target="${entry%%|*}"
            [[ -n "$target" ]] || continue

            if echo "$seen_targets" | grep -qxF "$target"; then
                continue
            fi
            seen_targets="$seen_targets
$target"

            if ! git -C "$repo_root" ls-files --error-unmatch -- "$target" >/dev/null 2>&1; then
                continue
            fi

            ls_output="$(git -C "$repo_root" ls-files -v -- "$target" 2>/dev/null || true)"
            if [[ "${ls_output:0:1}" != "S" ]]; then
                continue
            fi

            git -C "$repo_root" update-index --no-skip-worktree -- "$target"
            ((repaired_count++)) || true
        done < <(read_config "$repo_root")

        printf '%s\n' "$repaired_count"
    })"

    if [[ -n "$repaired_count" && "$repaired_count" -gt 0 ]]; then
        info "Cleared legacy skip-worktree on $repaired_count managed file(s)"
    fi
}

# Install hooks to a directory
install_hooks_to_dir() {
    local hooks_dir="$1"
    local lib_dir="$2"
    local resolve_ambiguous_hooks="${3:-false}"

    mkdir -p "$hooks_dir"
    mkdir -p "$lib_dir"

    prune_stale_managed_artifacts "$hooks_dir"
    prune_stale_managed_chained_hooks "$hooks_dir"

    # Install the shared library
    info "Installing shared library..."
    get_lib_content > "$lib_dir/local-override-lib.sh"
    chmod +x "$lib_dir/local-override-lib.sh"
    success "Installed: $lib_dir/local-override-lib.sh"
    install_shared_resolver_to_dir "$lib_dir"

    # Install each hook
    for hook_type in post-checkout pre-commit post-commit pre-rebase; do
        local hook_file="$hooks_dir/$hook_type"
        local our_hook="local-override-$hook_type"

        # Get our hook content (lib is in same dir, so SCRIPT_DIR works as-is)
        local hook_content
        hook_content="$(get_hook_content "$our_hook")"

        if [[ -f "$hook_file" ]]; then
            if is_managed_wrapper_hook "$hook_file" "$hook_type"; then
                info "Refreshing managed hook: $hook_type"
                write_managed_wrapper_hook "$hook_file" "$hook_type" "$hook_content"
                success "Installed $hook_type hook"
                continue
            fi

            # HOOK CHAINING: Preserve existing unmanaged hooks by renaming to .chained
            # Our hook runs first, then calls the chained hook with same args.
            # This ensures compatibility with other tools (husky, pre-commit, etc.)
            if [[ -f "$hook_file.chained" ]]; then
                if [[ "$resolve_ambiguous_hooks" == true ]]; then
                    if ! resolve_ambiguous_hook_state "$hook_file" "$hook_type" "$hook_content"; then
                        warn "Repair skipped for $hook_type; preserving existing files"
                    fi
                else
                    warn "Ambiguous state for $hook_type: unmanaged hook with existing $hook_type.chained; preserving both"
                fi
                continue
            fi

            mv "$hook_file" "$hook_file.chained"
            info "Preserved existing $hook_type hook as $hook_type.chained"
        fi

        write_managed_wrapper_hook "$hook_file" "$hook_type" "$hook_content"

        success "Installed $hook_type hook"
    done
}

# Install to current repository
install_to_repo() {
    local resolve_ambiguous_hooks="${1:-false}"
    local repo_root
    local common_git_dir
    local hooks_dir
    local lib_dir

    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        error "Not in a git repository"
        exit 1
    }

    common_git_dir="$(get_common_git_dir "$repo_root")"
    hooks_dir="$common_git_dir/hooks"
    lib_dir="$common_git_dir/hooks"

    info "Installing hooks to repository: $repo_root"
    install_hooks_to_dir "$hooks_dir" "$lib_dir" "$resolve_ambiguous_hooks"
    install_filters "$repo_root" "$hooks_dir"
    repair_legacy_skip_worktree "$repo_root" "$lib_dir/local-override-lib.sh"
}

# Install to git template directory (affects new clones)
install_to_template() {
    local resolve_ambiguous_hooks="${1:-false}"
    local template_dir="${XDG_CONFIG_HOME:-$HOME/.config}/git/template/hooks"
    # Put lib in the same directory as hooks so it gets copied with git init
    local lib_dir="$template_dir"

    info "Installing hooks to git template: $template_dir"
    install_hooks_to_dir "$template_dir" "$lib_dir" "$resolve_ambiguous_hooks"
    install_filter_scripts_to_dir "$template_dir"

    # Configure git to use the template
    git config --global init.templateDir "${XDG_CONFIG_HOME:-$HOME/.config}/git/template"
    success "Configured git template directory"

    git config --global filter.local-override.smudge "$template_dir/local-override-filter-smudge %f"
    git config --global filter.local-override.clean "$template_dir/local-override-filter-clean %f"
    git config --global filter.local-override.required false
    success "Configured global filter.local-override"

    echo ""
    info "New repositories created with 'git init' or 'git clone' will have hooks installed."
    info "For existing repositories, run: ./install.sh --repo"
    info "Run './install.sh --repo' inside each repository to sync .git/info/attributes from .local-overrides.yaml"
}

# Install CLI tool
install_cli() {
    local bin_dir="${HOME}/.local/bin"
    local data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/git-local-override"
    mkdir -p "$bin_dir"
    mkdir -p "$data_dir"

    info "Installing CLI tool..."
    get_cli_content > "$bin_dir/git-local-override"
    chmod +x "$bin_dir/git-local-override"
    success "Installed: $bin_dir/git-local-override"
    get_shared_resolver_content > "$data_dir/local-override-resolver.sh"
    chmod +x "$data_dir/local-override-resolver.sh"
    success "Installed: $data_dir/local-override-resolver.sh"
    get_version_content > "$data_dir/VERSION"
    success "Installed: $data_dir/VERSION"

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
  --resolve-ambiguous-hooks   Safely repair ambiguous unmanaged hook + .chained states during install
  --cli       Also install the CLI tool to ~/.local/bin
  --help      Show this help message

Examples:
  # Install to current repo
  curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash -s -- --cli

  # Install globally (template) + CLI
  curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/main/scripts/install.sh | bash -s -- --global --cli

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
    echo ""
    echo "     pattern: \".local\""
    echo "     files:"
    echo "       - override: CLAUDE.local.md"
    echo "         replaces:"
    echo "           - CLAUDE.md"
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
    local resolve_ambiguous_hooks=false

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
            --resolve-ambiguous-hooks)
                resolve_ambiguous_hooks=true
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
            install_to_repo "$resolve_ambiguous_hooks"
            ;;
        global)
            install_to_template "$resolve_ambiguous_hooks"
            ;;
    esac

    setup_gitignore

    if [[ "$install_cli_tool" == true ]]; then
        install_cli
    fi

    print_summary
}

main "$@"
