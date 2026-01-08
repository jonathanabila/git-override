#!/usr/bin/env bash
#
# local-override-lib.sh
#
# Shared library for git-local-override hooks.
# This file is sourced by the hook scripts.
#
# WHY THIS EXISTS:
# All three hooks (pre-commit, post-commit, post-checkout) need the same
# core functions. Duplicating code would make maintenance harder and risk
# divergence. This shared library is copied alongside the hooks during install.
#
# CONFIG FORMAT (v2):
# Uses explicit override/replaces format in .local-overrides.yaml:
#
#   pattern: ".local"
#   files:
#     - override: CLAUDE.local.md
#       replaces:
#         - CLAUDE.md
#     - override: AGENTS.local.md
#       replaces:
#         - AGENTS.md
#         - CLAUDE.md
#

# Get repo root
get_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

# Read the pattern field from config file
# Returns the pattern string, or empty if not found
read_pattern() {
    local repo_root="$1"
    local config_file="$repo_root/.local-overrides.yaml"

    [[ -f "$config_file" ]] || return 0

    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue
        # Match pattern: "pattern: .something" or 'pattern: ".something"'
        if [[ "$line" =~ ^pattern:[[:space:]]*(.+)$ ]]; then
            local pattern="${BASH_REMATCH[1]}"
            # Remove quotes if present
            pattern="${pattern#\"}"
            pattern="${pattern%\"}"
            pattern="${pattern#\'}"
            pattern="${pattern%\'}"
            # Trim whitespace
            pattern="${pattern#"${pattern%%[![:space:]]*}"}"
            pattern="${pattern%"${pattern##*[![:space:]]}"}"
            echo "$pattern"
            return
        fi
    done < "$config_file"
}

# Validate config file format
# Returns 0 if valid, 1 if invalid
# Outputs warning/error messages to stderr
validate_config() {
    local repo_root="$1"
    local config_file="$repo_root/.local-overrides.yaml"

    # Check if config exists
    if [[ ! -f "$config_file" ]]; then
        return 0  # No config is valid (nothing to do)
    fi

    # Check for required pattern field
    local pattern
    pattern="$(read_pattern "$repo_root")"
    if [[ -z "$pattern" ]]; then
        echo "Error: Missing required 'pattern:' field in .local-overrides.yaml" >&2
        echo "  Add a pattern field at the top of your config:" >&2
        echo "    pattern: \".local\"" >&2
        return 1
    fi

    # Check for duplicate target files
    local seen_targets=""
    local entry target override
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue
        target="${entry%%|*}"
        override="${entry#*|}"

        # Check if target was already seen
        if echo "$seen_targets" | grep -qxF "$target"; then
            echo "Error: Duplicate target file '$target' in config" >&2
            echo "  Each file can only appear in one 'replaces:' list" >&2
            return 1
        fi
        seen_targets="$seen_targets
$target"
    done < <(read_config "$repo_root")

    return 0
}

# Read config file and output list of target|override pairs
# Output format: target|override (one line per target file)
#
# Example config:
#   files:
#     - override: AGENTS.local.md
#       replaces:
#         - AGENTS.md
#         - CLAUDE.md
#
# Example output:
#   AGENTS.md|AGENTS.local.md
#   CLAUDE.md|AGENTS.local.md
#
read_config() {
    local repo_root="$1"
    local config_file="$repo_root/.local-overrides.yaml"

    [[ -f "$config_file" ]] || return 0

    local in_files_section=false
    local in_replaces_section=false
    local current_override=""
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue

        # Check for files: section start
        if [[ "$line" =~ ^files:[[:space:]]*$ ]]; then
            in_files_section=true
            in_replaces_section=false
            continue
        fi

        # Skip pattern: line
        if [[ "$line" =~ ^pattern: ]]; then
            continue
        fi

        # Stop if we hit another top-level key (non-indented, ends with :)
        if [[ "$line" =~ ^[a-z_]+:[[:space:]]*$ && ! "$line" =~ ^[[:space:]] ]]; then
            in_files_section=false
            in_replaces_section=false
            continue
        fi

        [[ "$in_files_section" != true ]] && continue

        # Handle override: line "  - override: AGENTS.local.md"
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+override:[[:space:]]+(.+)$ ]]; then
            current_override="${BASH_REMATCH[1]}"
            # Clean up quotes and whitespace
            current_override="${current_override#\"}"
            current_override="${current_override%\"}"
            current_override="${current_override#\'}"
            current_override="${current_override%\'}"
            current_override="${current_override#"${current_override%%[![:space:]]*}"}"
            current_override="${current_override%"${current_override##*[![:space:]]}"}"
            in_replaces_section=false
            continue
        fi

        # Handle replaces: section start
        if [[ -n "$current_override" && "$line" =~ ^[[:space:]]+replaces:[[:space:]]*$ ]]; then
            in_replaces_section=true
            continue
        fi

        # Handle target files in replaces section "      - AGENTS.md"
        if [[ "$in_replaces_section" == true && "$line" =~ ^[[:space:]]+-[[:space:]]+(.+)$ ]]; then
            local target="${BASH_REMATCH[1]}"
            # Clean up quotes and whitespace
            target="${target#\"}"
            target="${target%\"}"
            target="${target#\'}"
            target="${target%\'}"
            target="${target#"${target%%[![:space:]]*}"}"
            target="${target%"${target##*[![:space:]]}"}"
            [[ -n "$target" ]] && echo "${target}|${current_override}"
            continue
        fi

        # If we encounter a new list item without replaces, reset state
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
            in_replaces_section=false
            current_override=""
        fi
    done < "$config_file"
}

# Get list of files that have local overrides available
# (files in config that have an override file present)
get_active_overrides() {
    local repo_root="$1"

    local entry target override
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue

        # Parse entry: "target|override"
        target="${entry%%|*}"
        override="${entry#*|}"

        # Check if override file exists
        if [[ -n "$override" && -f "$repo_root/$override" ]]; then
            echo "$target"
        fi
    done < <(read_config "$repo_root")
}

# Get unique override files from config
# Returns list of unique override file paths
get_override_files() {
    local repo_root="$1"
    local seen=""

    local entry override
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue

        override="${entry#*|}"
        [[ -z "$override" ]] && continue

        # Check if already seen
        if ! echo "$seen" | grep -qxF "$override"; then
            echo "$override"
            seen="$seen
$override"
        fi
    done < <(read_config "$repo_root")
}

# Get all targets for a specific override file
# Arguments: $1 = repo_root, $2 = override file path
get_targets_for_override() {
    local repo_root="$1"
    local override_file="$2"

    local entry target override
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue

        target="${entry%%|*}"
        override="${entry#*|}"

        if [[ "$override" == "$override_file" ]]; then
            echo "$target"
        fi
    done < <(read_config "$repo_root")
}
