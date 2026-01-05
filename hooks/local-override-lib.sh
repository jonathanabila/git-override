#!/usr/bin/env bash
#
# local-override-lib.sh
#
# Shared library for git-local-override hooks.
# This file is sourced by the hook scripts.
#
# Config file: .local-overrides (plain text, one file per line)
# or .local-overrides.yaml (YAML format with 'files:' key)
#

# Get repo root
get_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

# Convert path to local override path
# e.g., AGENTS.md -> AGENTS.local.md
#       Makefile -> Makefile.local
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
