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

# Convert path to local override path
# e.g., AGENTS.md -> AGENTS.local.md
#       Makefile -> Makefile.local
#
# WHY .local NAMING:
# The ".local" infix (before extension) was chosen because:
# 1. It's visually obvious which file is the override
# 2. A single gitignore pattern (*.local.*) catches all override files
# 3. It sorts alphabetically next to the original file
get_local_path() {
    local path="$1"
    local dir basename ext

    dir="$(dirname "$path")"
    basename="$(basename "$path")"

    if [[ "$basename" == *.* ]]; then
        ext="${basename##*.}"
        basename="${basename%.*}"
        if [[ "$dir" == "." ]]; then
            echo "${basename}.local.${ext}"
        else
            echo "${dir}/${basename}.local.${ext}"
        fi
    else
        if [[ "$dir" == "." ]]; then
            echo "${basename}.local"
        else
            echo "${dir}/${basename}.local"
        fi
    fi
}

# Read config file and output list of override-able files
# Supports both plain text (.local-overrides) and YAML (.local-overrides.yaml)
read_config() {
    local repo_root="$1"
    local config_file=""

    # Check for config files in order of preference
    if [[ -f "$repo_root/.local-overrides.yaml" ]]; then
        config_file="$repo_root/.local-overrides.yaml"
        # Parse YAML - extract lines under 'files:' that start with '  - '
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Skip empty lines and comments
            [[ -z "$line" || "$line" == \#* ]] && continue
            # Match lines like '  - CLAUDE.md' or '- CLAUDE.md'
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(.+)$ ]]; then
                local file="${BASH_REMATCH[1]}"
                # Remove quotes if present
                file="${file#\"}"
                file="${file%\"}"
                file="${file#\'}"
                file="${file%\'}"
                # Trim whitespace
                file="${file#"${file%%[![:space:]]*}"}"
                file="${file%"${file##*[![:space:]]}"}"
                [[ -n "$file" ]] && echo "$file"
            fi
        done < "$config_file"
    elif [[ -f "$repo_root/.local-overrides" ]]; then
        config_file="$repo_root/.local-overrides"
        # Plain text - one file per line
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Skip empty lines and comments
            [[ -z "$line" || "$line" == \#* ]] && continue
            # Trim whitespace
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -n "$line" ]] && echo "$line"
        done < "$config_file"
    fi
    # No config file = no overrides
}

# Get list of files that have local overrides available
# (files in config that have a .local. version)
get_active_overrides() {
    local repo_root="$1"

    while IFS= read -r path || [[ -n "$path" ]]; do
        [[ -z "$path" ]] && continue
        local local_path
        local_path="$(get_local_path "$path")"

        # Check if local override file exists
        if [[ -f "$repo_root/$local_path" ]]; then
            echo "$path"
        fi
    done < <(read_config "$repo_root")
}
