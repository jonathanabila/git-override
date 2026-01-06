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
# CONFIG FORMAT:
# We support two formats for backwards compatibility and user preference:
# - .local-overrides.yaml (YAML with 'files:' key) - preferred, more explicit
# - .local-overrides (plain text, one file per line) - simpler for small configs
# YAML is checked first; plain text is the fallback.
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
# Returns 0 if valid, 1 if invalid (missing required fields)
# Outputs warning/error messages to stderr
validate_config() {
    local repo_root="$1"
    local pattern
    pattern="$(read_pattern "$repo_root")"

    # Check if using plain text format (legacy, no pattern support)
    if [[ -f "$repo_root/.local-overrides" && ! -f "$repo_root/.local-overrides.yaml" ]]; then
        echo "Warning: Plain text .local-overrides does not support patterns." >&2
        echo "  Migrate to .local-overrides.yaml with 'pattern:' field." >&2
        return 1
    fi

    # Check if YAML config exists but pattern is missing
    if [[ -f "$repo_root/.local-overrides.yaml" && -z "$pattern" ]]; then
        echo "Error: Missing required 'pattern:' field in .local-overrides.yaml" >&2
        echo "  Add a pattern field at the top of your config:" >&2
        echo "    pattern: \".local\"" >&2
        echo "    files:" >&2
        echo "      - CLAUDE.md" >&2
        return 1
    fi

    return 0
}

# Convert path to local override path using specified pattern
# e.g., get_local_path "AGENTS.md" ".override" -> AGENTS.override.md
#       get_local_path "Makefile" ".local" -> Makefile.local
#
# Arguments:
#   $1 - original file path
#   $2 - pattern to use (e.g., ".override", ".local") - defaults to ".local"
#
# WHY PATTERN NAMING:
# The pattern infix (before extension) was chosen because:
# 1. It's visually obvious which file is the override
# 2. A single gitignore pattern (*.pattern.*) catches all override files
# 3. It sorts alphabetically next to the original file
get_local_path() {
    local path="$1"
    local pattern="${2:-.local}"
    local dir basename ext

    # Remove leading dot from pattern for insertion
    local pattern_infix="${pattern#.}"

    dir="$(dirname "$path")"
    basename="$(basename "$path")"

    if [[ "$basename" == *.* ]]; then
        ext="${basename##*.}"
        basename="${basename%.*}"
        if [[ "$dir" == "." ]]; then
            echo "${basename}.${pattern_infix}.${ext}"
        else
            echo "${dir}/${basename}.${pattern_infix}.${ext}"
        fi
    else
        if [[ "$dir" == "." ]]; then
            echo "${basename}.${pattern_infix}"
        else
            echo "${dir}/${basename}.${pattern_infix}"
        fi
    fi
}

# Read config file and output list of override-able files
# Supports both plain text (.local-overrides) and YAML (.local-overrides.yaml)
#
# Output format: path|override_path
#   - For simple entries: "CLAUDE.md|" (empty override_path)
#   - For explicit overrides: "config.json|config.mylocal.json"
#
# YAML supports two formats:
#   Simple: - CLAUDE.md
#   Explicit: - path: config.json
#               override: config.mylocal.json
read_config() {
    local repo_root="$1"
    local config_file=""
    local in_files_section=false
    local pending_path=""

    # Check for config files in order of preference
    if [[ -f "$repo_root/.local-overrides.yaml" ]]; then
        config_file="$repo_root/.local-overrides.yaml"

        while IFS= read -r line || [[ -n "$line" ]]; do
            # Skip empty lines and comments
            [[ -z "$line" || "$line" == \#* ]] && continue

            # Check for files: section start
            if [[ "$line" =~ ^files:[[:space:]]*$ ]]; then
                in_files_section=true
                continue
            fi

            # Skip pattern: line
            if [[ "$line" =~ ^pattern: ]]; then
                continue
            fi

            # Stop if we hit another top-level key (non-indented, ends with :)
            if [[ "$line" =~ ^[a-z_]+:[[:space:]]*$ && ! "$line" =~ ^[[:space:]] ]]; then
                in_files_section=false
                continue
            fi

            [[ "$in_files_section" != true ]] && continue

            # Handle per-file override: "  - path: config.json"
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+path:[[:space:]]+(.+)$ ]]; then
                # Emit any pending path without override first
                if [[ -n "$pending_path" ]]; then
                    echo "${pending_path}|"
                fi
                pending_path="${BASH_REMATCH[1]}"
                # Clean up quotes and whitespace
                pending_path="${pending_path#\"}"
                pending_path="${pending_path%\"}"
                pending_path="${pending_path#\'}"
                pending_path="${pending_path%\'}"
                pending_path="${pending_path#"${pending_path%%[![:space:]]*}"}"
                pending_path="${pending_path%"${pending_path##*[![:space:]]}"}"
                continue
            fi

            # Handle override: line (must follow path: line)
            if [[ -n "$pending_path" && "$line" =~ ^[[:space:]]+override:[[:space:]]+(.+)$ ]]; then
                local override="${BASH_REMATCH[1]}"
                override="${override#\"}"
                override="${override%\"}"
                override="${override#\'}"
                override="${override%\'}"
                override="${override#"${override%%[![:space:]]*}"}"
                override="${override%"${override##*[![:space:]]}"}"
                echo "${pending_path}|${override}"
                pending_path=""
                continue
            fi

            # Handle simple list entry: "  - CLAUDE.md"
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(.+)$ ]]; then
                # Emit any pending path without override first
                if [[ -n "$pending_path" ]]; then
                    echo "${pending_path}|"
                    pending_path=""
                fi

                local file="${BASH_REMATCH[1]}"
                # Skip if this is a path: entry (already handled above)
                if [[ "$file" =~ ^path: ]]; then
                    continue
                fi
                file="${file#\"}"
                file="${file%\"}"
                file="${file#\'}"
                file="${file%\'}"
                file="${file#"${file%%[![:space:]]*}"}"
                file="${file%"${file##*[![:space:]]}"}"
                [[ -n "$file" ]] && echo "${file}|"
            fi
        done < "$config_file"

        # Emit any trailing pending path
        if [[ -n "$pending_path" ]]; then
            echo "${pending_path}|"
        fi

    elif [[ -f "$repo_root/.local-overrides" ]]; then
        config_file="$repo_root/.local-overrides"
        # Plain text - one file per line (no explicit override support)
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Skip empty lines and comments
            [[ -z "$line" || "$line" == \#* ]] && continue
            # Trim whitespace
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -n "$line" ]] && echo "${line}|"
        done < "$config_file"
    fi
    # No config file = no overrides
}

# Get list of files that have local overrides available
# (files in config that have an override file present)
get_active_overrides() {
    local repo_root="$1"
    local pattern
    pattern="$(read_pattern "$repo_root")"
    [[ -z "$pattern" ]] && pattern=".local"

    local entry path override_path local_path
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue

        # Parse entry: "path|override_path"
        path="${entry%%|*}"
        override_path="${entry#*|}"

        # Determine local file path
        if [[ -n "$override_path" ]]; then
            local_path="$override_path"
        else
            local_path="$(get_local_path "$path" "$pattern")"
        fi

        # Check if local override file exists
        if [[ -f "$repo_root/$local_path" ]]; then
            echo "$path"
        fi
    done < <(read_config "$repo_root")
}
