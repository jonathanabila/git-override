#!/usr/bin/env bash
#
# local-override-resolver.sh
#
# Shared recursive config resolver for git-local-override.
#

CONFIG_FILE_NAME=".local-overrides.yaml"

# Cache for discover_config_files results (temp file path, empty = no cache)
_DISCOVER_CACHE_FILE=""
_DISCOVER_CACHE_ROOT=""

local_override_trace_enabled() {
    [[ "${GIT_LOCAL_OVERRIDE_TRACE:-0}" == "1" ]]
}

local_override_trace_log() {
    if local_override_trace_enabled; then
        printf 'Trace: %s\n' "$*" >&2
    fi
}

resolver_now_milliseconds() {
    if command -v perl >/dev/null 2>&1; then
        perl -MTime::HiRes=time -e 'printf("%.0f\n", time() * 1000)'
        return 0
    fi

    printf '%s000\n' "$(date +%s)"
}

resolver_elapsed_milliseconds() {
    local start_ms="$1"
    local end_ms

    end_ms="$(resolver_now_milliseconds)"
    printf '%s\n' "$((end_ms - start_ms))"
}

count_list_entries() {
    local input="${1:-}"
    local line=""
    local count=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        ((count++)) || true
    done <<< "$input"

    printf '%s\n' "$count"
}

cache_config_files() {
    local repo_root="$1"
    if [[ -n "$_DISCOVER_CACHE_FILE" && -f "$_DISCOVER_CACHE_FILE" \
        && "$_DISCOVER_CACHE_ROOT" == "$repo_root" ]]; then
        return 0
    fi
    clear_config_files_cache
    _DISCOVER_CACHE_FILE="$(mktemp)"
    _DISCOVER_CACHE_ROOT="$repo_root"
    discover_config_files "$repo_root" > "$_DISCOVER_CACHE_FILE"
}

clear_config_files_cache() {
    if [[ -n "$_DISCOVER_CACHE_FILE" && -f "$_DISCOVER_CACHE_FILE" ]]; then
        rm -f "$_DISCOVER_CACHE_FILE"
    fi
    _DISCOVER_CACHE_FILE=""
    _DISCOVER_CACHE_ROOT=""
}

get_cached_config_files() {
    local repo_root="$1"
    if [[ -n "$_DISCOVER_CACHE_FILE" && -f "$_DISCOVER_CACHE_FILE" \
        && "$_DISCOVER_CACHE_ROOT" == "$repo_root" ]]; then
        local_override_trace_log "discover_config_files cache=hit file=$_DISCOVER_CACHE_FILE"
        cat "$_DISCOVER_CACHE_FILE"
    else
        local_override_trace_log "discover_config_files cache=miss"
        discover_config_files "$repo_root"
    fi
}

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

# Repo-relative directories of linked worktrees that live INSIDE repo_root.
# Another checkout's config is not a subtree config of this checkout.
get_nested_worktree_dirs() {
    local repo_root="$1"
    local canonical_root=""
    local line=""
    local wt_path=""

    # `git worktree list` resolves symlinks in the paths it prints (e.g. macOS
    # /var -> /private/var), so compare against repo_root's resolved form too
    # or every entry silently fails the prefix match.
    canonical_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null || echo "$repo_root")"

    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            worktree\ *)
                wt_path="${line#worktree }"
                [[ "$wt_path" == "$canonical_root" ]] && continue
                case "$wt_path" in
                    "$canonical_root"/*)
                        printf '%s\n' "${wt_path#"$canonical_root"/}"
                        ;;
                esac
                ;;
        esac
    done < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null)
}

discover_config_files() {
    local repo_root="$1"
    local seen=""
    local path=""
    local discover_output=""
    local strategy="git"
    local trace_on=false
    local discover_start_ms
    local tracked_start_ms
    local tracked_ms=0
    local ignored_start_ms
    local ignored_ms=0
    local tracked_output=""
    local ignored_output=""
    local combined_output=""
    local nested_dirs=""
    local nested_dir=""
    local under_nested=false

    nested_dirs="$(get_nested_worktree_dirs "$repo_root")"

    if local_override_trace_enabled; then
        trace_on=true
        discover_start_ms="$(resolver_now_milliseconds)"
        tracked_start_ms="$discover_start_ms"
    fi

    if command -v fd >/dev/null 2>&1; then
        strategy="fd"
        discover_output="$(fd --hidden --no-ignore --glob "$CONFIG_FILE_NAME" "$repo_root" 2>/dev/null || true)"
        combined_output="$(printf '%s\n' "$discover_output" | LC_ALL=C sort)"
        tracked_output="$combined_output"
        if [[ "$trace_on" == true ]]; then
            tracked_ms="$(resolver_elapsed_milliseconds "$tracked_start_ms")"
        fi
    else
        tracked_output="$(git -C "$repo_root" ls-files --cached --others --exclude-standard --full-name -- "$CONFIG_FILE_NAME" "*/$CONFIG_FILE_NAME" 2>/dev/null || true)"

        if [[ "$trace_on" == true ]]; then
            tracked_ms="$(resolver_elapsed_milliseconds "$tracked_start_ms")"
            ignored_start_ms="$(resolver_now_milliseconds)"
        fi

        ignored_output="$(git -C "$repo_root" ls-files --others --ignored --exclude-standard --full-name -- "$CONFIG_FILE_NAME" "*/$CONFIG_FILE_NAME" 2>/dev/null || true)"
        combined_output="$({ printf '%s\n' "$tracked_output"; printf '%s\n' "$ignored_output"; } | LC_ALL=C sort)"

        if [[ "$trace_on" == true ]]; then
            ignored_ms="$(resolver_elapsed_milliseconds "$ignored_start_ms")"
        fi
    fi

    while IFS= read -r path || [[ -n "$path" ]]; do
        [[ -n "$path" ]] || continue
        path="${path#"$repo_root"/}"
        path="${path#./}"
        [[ "$path" == "$CONFIG_FILE_NAME" || "$path" == */$CONFIG_FILE_NAME ]] || continue
        [[ -f "$repo_root/$path" ]] || continue

        if [[ -n "$nested_dirs" ]]; then
            under_nested=false
            while IFS= read -r nested_dir; do
                [[ -n "$nested_dir" ]] || continue
                case "$path" in
                    "$nested_dir"/*)
                        under_nested=true
                        break
                        ;;
                esac
            done <<< "$nested_dirs"
            if [[ "$under_nested" == true ]]; then
                local_override_trace_log "discover: skipping nested-worktree config $path"
                continue
            fi
        fi

        if echo "$seen" | grep -qxF "$path"; then
            continue
        fi

        seen="$seen
$path"
        printf '%s\n' "$path"
    done <<< "$combined_output"

    if [[ "$trace_on" == true ]]; then
        local_override_trace_log "discover_config_files strategy=${strategy} tracked_ms=${tracked_ms} ignored_ms=${ignored_ms} total_ms=$(resolver_elapsed_milliseconds "$discover_start_ms") count=$(count_list_entries "$seen")"
    fi
}

has_any_config() {
    local repo_root="$1"
    local config_path=""

    while IFS= read -r config_path || [[ -n "$config_path" ]]; do
        [[ -n "$config_path" ]] || continue
        return 0
    done < <(get_cached_config_files "$repo_root")

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
    done < <(get_cached_config_files "$repo_root")

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
    local validate_start_ms
    local config_start_ms
    local config_entry_count=0

    validate_start_ms="$(resolver_now_milliseconds)"

    if ! has_any_config "$repo_root"; then
        return 0
    fi

    while IFS= read -r config_path || [[ -n "$config_path" ]]; do
        [[ -n "$config_path" ]] || continue
        config_start_ms="$(resolver_now_milliseconds)"
        config_entry_count=0

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
            ((config_entry_count++)) || true
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

        local_override_trace_log "validate_config config=$config_path pattern=$pattern entries=$config_entry_count ms=$(resolver_elapsed_milliseconds "$config_start_ms")"
    done < <(get_cached_config_files "$repo_root")

    local_override_trace_log "validate_config total_ms=$(resolver_elapsed_milliseconds "$validate_start_ms") unique_targets=$(count_list_entries "$seen_targets")"

    return 0
}

read_config() {
    local repo_root="$1"
    local seen_targets=""
    local config_path=""
    local entry=""
    local target=""
    local read_start_ms
    local emitted_count=0
    local duplicate_skip_count=0
    local shadowed_skip_count=0

    read_start_ms="$(resolver_now_milliseconds)"

    while IFS= read -r config_path || [[ -n "$config_path" ]]; do
        [[ -n "$config_path" ]] || continue

        while IFS= read -r entry || [[ -n "$entry" ]]; do
            [[ -n "$entry" ]] || continue
            target="${entry%%|*}"

            if target_is_shadowed_by_child_config "$repo_root" "$config_path" "$target"; then
                ((shadowed_skip_count++)) || true
                continue
            fi

            if echo "$seen_targets" | grep -qxF "$target"; then
                ((duplicate_skip_count++)) || true
                continue
            fi

            seen_targets="$seen_targets
$target"
            ((emitted_count++)) || true
            printf '%s\n' "$entry"
        done < <(read_config_entries_for_file "$repo_root" "$config_path")
    done < <(get_cached_config_files "$repo_root")

    local_override_trace_log "read_config emitted=$emitted_count shadowed_skips=$shadowed_skip_count duplicate_skips=$duplicate_skip_count total_ms=$(resolver_elapsed_milliseconds "$read_start_ms")"
}

get_override_for_target() {
    local target_path="$1"
    local repo_root="$2"
    local owner_config=""
    local entry=""
    local target=""
    local override=""

    owner_config="$(find_nearest_config_for_path "$repo_root" "$target_path" 2>/dev/null || true)"
    [[ -n "$owner_config" ]] || return 1

    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue
        target="${entry%%|*}"
        override="${entry#*|}"
        if [[ "$target" == "$target_path" ]]; then
            printf '%s\n' "$override"
            return 0
        fi
    done < <(read_config_entries_for_file "$repo_root" "$owner_config")

    return 1
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
    done < <(get_cached_config_files "$repo_root")

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

worktree_fallback_disabled() {
    [[ "${GIT_LOCAL_OVERRIDE_DISABLE_WORKTREE_FALLBACK:-0}" == "1" ]]
}

is_linked_worktree() {
    local repo_root="$1"
    local git_dir=""
    local common_dir=""

    git_dir="$(git -C "$repo_root" rev-parse --git-dir 2>/dev/null || echo "")"
    common_dir="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null || echo "")"
    [[ -n "$git_dir" && -n "$common_dir" ]] || return 1

    [[ "$git_dir" != "$common_dir" ]]
}

# First "worktree " entry of `git worktree list --porcelain` is the main
# worktree — unless its block carries the `bare` attribute, in which case
# there is no main checkout to resolve against and we return 1.
get_main_worktree_root() {
    local repo_root="$1"
    local line=""
    local first_root=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$first_root" ]]; then
            case "$line" in
                worktree\ *) first_root="${line#worktree }" ;;
            esac
            continue
        fi
        case "$line" in
            bare) return 1 ;;
            "" | worktree\ *) break ;;
        esac
    done < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null)

    [[ -n "$first_root" ]] || return 1
    printf '%s\n' "$first_root"
}

# The root that configs and override files are resolved against. Normally the
# checkout root itself; for a linked worktree with no config of its own, the
# main worktree root (a worktree-local config always wins, all-or-nothing).
get_resolution_root() {
    local repo_root="$1"
    local main_root=""

    if worktree_fallback_disabled; then
        printf '%s\n' "$repo_root"
        return 0
    fi

    if ! is_linked_worktree "$repo_root"; then
        printf '%s\n' "$repo_root"
        return 0
    fi

    if has_any_config "$repo_root"; then
        printf '%s\n' "$repo_root"
        return 0
    fi

    main_root="$(get_main_worktree_root "$repo_root" 2>/dev/null || echo "")"
    if [[ -z "$main_root" || ! -d "$main_root" ]]; then
        local_override_trace_log "get_resolution_root: no main worktree root; fallback skipped"
        printf '%s\n' "$repo_root"
        return 0
    fi

    local_override_trace_log "get_resolution_root: falling back to main worktree root $main_root"
    printf '%s\n' "$main_root"
}

# Returns the ABSOLUTE path of the override file for a managed target, or
# nothing. Resolves against the checkout's resolution root, so linked
# worktrees without their own config inherit the main worktree's overrides.
get_override_for_file() {
    local repo_root="$1"
    local file_path="$2"
    local resolution_root=""
    local override=""

    resolution_root="$(get_resolution_root "$repo_root")"
    override="$(get_override_for_target "$file_path" "$resolution_root" 2>/dev/null || true)"
    [[ -n "$override" ]] || return 0

    printf '%s/%s\n' "$resolution_root" "$override"
}

is_rebase_in_progress() {
    local repo_root="$1"
    local rebase_merge_path=""
    local rebase_apply_path=""

    rebase_merge_path="$(git -C "$repo_root" rev-parse --git-path rebase-merge 2>/dev/null || true)"
    rebase_apply_path="$(git -C "$repo_root" rev-parse --git-path rebase-apply 2>/dev/null || true)"

    if [[ "${GIT_REFLOG_ACTION:-}" == rebase* ]]; then
        return 0
    fi

    if [[ -n "$rebase_merge_path" && -d "$rebase_merge_path" ]]; then
        return 0
    fi

    if [[ -n "$rebase_apply_path" && -d "$rebase_apply_path" ]]; then
        return 0
    fi

    return 1
}
