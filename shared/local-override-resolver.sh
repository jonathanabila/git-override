#!/usr/bin/env bash
#
# local-override-resolver.sh
#
# Shared recursive config resolver for git-local-override.
#

CONFIG_FILE_NAME=".local-overrides.yaml"

trim_config_value() {
    local value="$1"

    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    printf '%s\n' "$value"
}

config_dir_for_path() {
    local config_path="$1"

    if [[ "$config_path" == */* ]]; then
        printf '%s\n' "${config_path%/*}"
    else
        printf '.\n'
    fi
}

path_is_within_dir() {
    local path="$1"
    local dir="$2"

    if [[ "$dir" == "." ]]; then
        return 0
    fi

    [[ "$path" == "$dir" || "$path" == "$dir/"* ]]
}

dir_is_descendant_of() {
    local parent_dir="$1"
    local child_dir="$2"

    if [[ "$parent_dir" == "." ]]; then
        [[ "$child_dir" != "." ]]
        return
    fi

    [[ "$child_dir" == "$parent_dir/"* ]]
}

normalize_config_path() {
    local base_dir="$1"
    local raw_path="$2"
    local combined_path=""
    local part=""
    local normalized=""
    local last_index=0
    local -a path_parts
    local -a normalized_parts

    [[ -n "$raw_path" ]] || return 1
    [[ "$raw_path" != /* ]] || return 1

    if [[ "$base_dir" == "." || -z "$base_dir" ]]; then
        combined_path="$raw_path"
    else
        combined_path="$base_dir/$raw_path"
    fi

    IFS='/' read -r -a path_parts <<< "$combined_path"
    for part in "${path_parts[@]}"; do
        if [[ -z "$part" || "$part" == "." ]]; then
            continue
        fi

        if [[ "$part" == ".." ]]; then
            if [[ ${#normalized_parts[@]} -eq 0 ]]; then
                return 1
            fi
            last_index=$((${#normalized_parts[@]} - 1))
            unset "normalized_parts[$last_index]"
            continue
        fi

        normalized_parts+=("$part")
    done

    for part in "${normalized_parts[@]}"; do
        if [[ -n "$normalized" ]]; then
            normalized="$normalized/$part"
        else
            normalized="$part"
        fi
    done

    [[ -n "$normalized" ]] || return 1
    printf '%s\n' "$normalized"
}

discover_config_files() {
    local repo_root="$1"
    local seen=""
    local path=""

    while IFS= read -r path || [[ -n "$path" ]]; do
        [[ -n "$path" ]] || continue
        [[ "$path" == "$CONFIG_FILE_NAME" || "$path" == */$CONFIG_FILE_NAME ]] || continue
        [[ -f "$repo_root/$path" ]] || continue

        if echo "$seen" | grep -qxF "$path"; then
            continue
        fi

        seen="$seen
$path"
        printf '%s\n' "$path"
    done < <(git -C "$repo_root" ls-files --cached --others --exclude-standard --full-name 2>/dev/null | LC_ALL=C sort)
}

has_any_config() {
    local repo_root="$1"
    local config_path=""

    while IFS= read -r config_path || [[ -n "$config_path" ]]; do
        [[ -n "$config_path" ]] || continue
        return 0
    done < <(discover_config_files "$repo_root")

    return 1
}

read_pattern_from_config() {
    local repo_root="$1"
    local config_path="$2"
    local config_file="$repo_root/$config_path"
    local line=""

    [[ -f "$config_file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" =~ ^pattern:[[:space:]]*(.+)$ ]]; then
            trim_config_value "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "$config_file"

    return 0
}

read_pattern() {
    local repo_root="$1"
    read_pattern_from_config "$repo_root" "$CONFIG_FILE_NAME"
}

find_nearest_config_for_path() {
    local repo_root="$1"
    local path="$2"
    local current_dir=""
    local candidate=""

    if [[ "$path" == */* ]]; then
        current_dir="${path%/*}"
    else
        current_dir="."
    fi

    while true; do
        if [[ "$current_dir" == "." ]]; then
            candidate="$CONFIG_FILE_NAME"
        else
            candidate="$current_dir/$CONFIG_FILE_NAME"
        fi

        if [[ -f "$repo_root/$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi

        if [[ "$current_dir" == "." ]]; then
            break
        fi

        if [[ "$current_dir" == */* ]]; then
            current_dir="${current_dir%/*}"
        else
            current_dir="."
        fi
    done

    return 1
}

get_effective_pattern_for_config() {
    local repo_root="$1"
    local config_path="$2"
    local current_config="$config_path"
    local current_dir=""
    local pattern=""

    while true; do
        pattern="$(read_pattern_from_config "$repo_root" "$current_config")"
        if [[ -n "$pattern" ]]; then
            printf '%s\n' "$pattern"
            return 0
        fi

        current_dir="$(config_dir_for_path "$current_config")"
        if [[ "$current_dir" == "." ]]; then
            break
        fi

        if [[ "$current_dir" == */* ]]; then
            current_dir="${current_dir%/*}"
            current_config="$current_dir/$CONFIG_FILE_NAME"
        else
            current_config="$CONFIG_FILE_NAME"
        fi
    done

    return 0
}

read_config_entries_for_file() {
    local repo_root="$1"
    local config_path="$2"
    local config_file="$repo_root/$config_path"
    local config_dir=""
    local current_override=""
    local in_files_section=false
    local in_replaces_section=false
    local line=""
    local target=""

    [[ -f "$config_file" ]] || return 0

    config_dir="$(config_dir_for_path "$config_path")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" =~ ^files:[[:space:]]*$ ]]; then
            in_files_section=true
            in_replaces_section=false
            continue
        fi

        if [[ "$line" =~ ^pattern: ]]; then
            continue
        fi

        if [[ "$line" =~ ^[a-z_]+:[[:space:]]*$ && ! "$line" =~ ^[[:space:]] ]]; then
            in_files_section=false
            in_replaces_section=false
            continue
        fi

        [[ "$in_files_section" == true ]] || continue

        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+override:[[:space:]]+(.+)$ ]]; then
            current_override="$(trim_config_value "${BASH_REMATCH[1]}")"
            current_override="$(normalize_config_path "$config_dir" "$current_override")" || return 1
            in_replaces_section=false
            continue
        fi

        if [[ -n "$current_override" && "$line" =~ ^[[:space:]]+replaces:[[:space:]]*$ ]]; then
            in_replaces_section=true
            continue
        fi

        if [[ "$in_replaces_section" == true && "$line" =~ ^[[:space:]]+-[[:space:]]+(.+)$ ]]; then
            target="$(trim_config_value "${BASH_REMATCH[1]}")"
            target="$(normalize_config_path "$config_dir" "$target")" || return 1
            [[ -n "$target" ]] && printf '%s|%s\n' "$target" "$current_override"
            continue
        fi

        if [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
            in_replaces_section=false
            current_override=""
        fi
    done < "$config_file"
}

target_is_shadowed_by_child_config() {
    local repo_root="$1"
    local config_path="$2"
    local target="$3"
    local config_dir=""
    local child_config=""
    local child_dir=""

    config_dir="$(config_dir_for_path "$config_path")"

    while IFS= read -r child_config || [[ -n "$child_config" ]]; do
        [[ -n "$child_config" ]] || continue
        [[ "$child_config" != "$config_path" ]] || continue

        child_dir="$(config_dir_for_path "$child_config")"
        if dir_is_descendant_of "$config_dir" "$child_dir" && path_is_within_dir "$target" "$child_dir"; then
            return 0
        fi
    done < <(discover_config_files "$repo_root")

    return 1
}

validate_config() {
    local repo_root="$1"
    local seen_targets=""
    local config_path=""
    local config_dir=""
    local pattern=""
    local entry=""
    local target=""
    local override=""

    if ! has_any_config "$repo_root"; then
        return 0
    fi

    while IFS= read -r config_path || [[ -n "$config_path" ]]; do
        [[ -n "$config_path" ]] || continue

        pattern="$(get_effective_pattern_for_config "$repo_root" "$config_path")"
        if [[ -z "$pattern" ]]; then
            echo "Error: Missing required 'pattern:' field for '$config_path'" >&2
            echo "  Add a pattern field there or in an ancestor $CONFIG_FILE_NAME:" >&2
            echo "    pattern: \".local\"" >&2
            return 1
        fi

        config_dir="$(config_dir_for_path "$config_path")"

        while IFS= read -r entry || [[ -n "$entry" ]]; do
            [[ -n "$entry" ]] || continue
            target="${entry%%|*}"
            override="${entry#*|}"

            if ! path_is_within_dir "$target" "$config_dir"; then
                echo "Error: Target '$target' in '$config_path' escapes its subtree" >&2
                return 1
            fi

            if ! path_is_within_dir "$override" "$config_dir"; then
                echo "Error: Override '$override' in '$config_path' escapes its subtree" >&2
                return 1
            fi

            if [[ "$target" == "$override" ]]; then
                echo "Error: Target '$target' in '$config_path' cannot replace itself" >&2
                return 1
            fi

            if [[ "$target" == "$CONFIG_FILE_NAME" || "$target" == */$CONFIG_FILE_NAME ]]; then
                echo "Error: '$config_path' cannot manage another $CONFIG_FILE_NAME file ('$target')" >&2
                return 1
            fi

            if target_is_shadowed_by_child_config "$repo_root" "$config_path" "$target"; then
                echo "Error: Target '$target' in '$config_path' belongs to a child subtree config" >&2
                return 1
            fi

            if echo "$seen_targets" | grep -qxF "$target"; then
                echo "Error: Duplicate target file '$target' across recursive configs" >&2
                echo "  Each file can only appear in one effective 'replaces:' list" >&2
                return 1
            fi

            seen_targets="$seen_targets
$target"
        done < <(read_config_entries_for_file "$repo_root" "$config_path")
    done < <(discover_config_files "$repo_root")

    return 0
}

read_config() {
    local repo_root="$1"
    local seen_targets=""
    local config_path=""
    local entry=""
    local target=""

    while IFS= read -r config_path || [[ -n "$config_path" ]]; do
        [[ -n "$config_path" ]] || continue

        while IFS= read -r entry || [[ -n "$entry" ]]; do
            [[ -n "$entry" ]] || continue
            target="${entry%%|*}"

            if target_is_shadowed_by_child_config "$repo_root" "$config_path" "$target"; then
                continue
            fi

            if echo "$seen_targets" | grep -qxF "$target"; then
                continue
            fi

            seen_targets="$seen_targets
$target"
            printf '%s\n' "$entry"
        done < <(read_config_entries_for_file "$repo_root" "$config_path")
    done < <(discover_config_files "$repo_root")
}

get_override_for_target() {
    local target_path="$1"
    local repo_root="$2"
    local entry=""
    local target=""
    local override=""

    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue
        target="${entry%%|*}"
        override="${entry#*|}"
        if [[ "$target" == "$target_path" ]]; then
            printf '%s\n' "$override"
            return 0
        fi
    done < <(read_config "$repo_root")

    return 1
}

get_override_for_file() {
    local repo_root="$1"
    local file_path="$2"

    get_override_for_target "$file_path" "$repo_root" || return 0
}

get_config_for_target() {
    local target_path="$1"
    local repo_root="$2"
    local config_path=""
    local entry=""
    local target=""

    while IFS= read -r config_path || [[ -n "$config_path" ]]; do
        [[ -n "$config_path" ]] || continue

        while IFS= read -r entry || [[ -n "$entry" ]]; do
            [[ -n "$entry" ]] || continue
            target="${entry%%|*}"
            if [[ "$target" == "$target_path" ]]; then
                printf '%s\n' "$config_path"
                return 0
            fi
        done < <(read_config_entries_for_file "$repo_root" "$config_path")
    done < <(discover_config_files "$repo_root")

    return 1
}

get_active_overrides() {
    local repo_root="$1"
    local entry=""
    local target=""
    local override=""

    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue
        target="${entry%%|*}"
        override="${entry#*|}"

        if [[ -n "$override" && -f "$repo_root/$override" ]]; then
            printf '%s\n' "$target"
        fi
    done < <(read_config "$repo_root")
}

get_override_files() {
    local repo_root="$1"
    local seen=""
    local entry=""
    local override=""

    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue
        override="${entry#*|}"
        [[ -z "$override" ]] && continue

        if ! echo "$seen" | grep -qxF "$override"; then
            printf '%s\n' "$override"
            seen="$seen
$override"
        fi
    done < <(read_config "$repo_root")
}

get_targets_for_override() {
    local repo_root="$1"
    local override_file="$2"
    local entry=""
    local target=""
    local override=""

    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue
        target="${entry%%|*}"
        override="${entry#*|}"

        if [[ "$override" == "$override_file" ]]; then
            printf '%s\n' "$target"
        fi
    done < <(read_config "$repo_root")
}

clear_legacy_skip_worktree() {
    local repo_root="$1"
    local repaired_count=0
    local seen_targets=""
    local entry=""
    local target=""
    local ls_output=""

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
}
