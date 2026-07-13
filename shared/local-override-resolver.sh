#!/usr/bin/env bash
#
# local-override-resolver.sh
#
# Shared recursive config resolver for git-local-override.
#

CONFIG_FILE_NAME=".local-overrides.yaml"

# Sentinel emitted (as the target field) by read_config_entries_for_file when
# a config entry fails path normalization. Consumers read the parser through
# process substitution, so its exit status is invisible to them — the sentinel
# is how the failure stays visible. validate_config fails on it (the gate);
# other consumers skip it. Must never collide with a real repo-relative path.
LOCAL_OVERRIDE_PARSE_ERROR_SENTINEL="__LOCAL_OVERRIDE_PARSE_ERROR__"

# Cache for discover_config_files results (temp file path, empty = no cache)
_DISCOVER_CACHE_FILE=""
_DISCOVER_CACHE_ROOT=""
# Discovery mode the cache was built with (full|hot). A hot cache must not be
# served to a full caller, so the mode is part of the reuse key.
_DISCOVER_CACHE_MODE=""

local_override_trace_enabled() {
    [[ "${GIT_LOCAL_OVERRIDE_TRACE:-0}" == "1" ]]
}

# Tag-aware trace log (single canonical implementation; lib.sh no longer
# shadows it). A single argument prints untagged `Trace: <msg>`; two or more
# arguments print `Trace[<tag>]: <msg...>` (the first arg is the tag). This
# keeps every existing call site's format: 1-arg resolver calls stay untagged,
# and 2-arg calls (clean core, hook code) stay tagged regardless of entry point.
local_override_trace_log() {
    if local_override_trace_enabled; then
        if [[ $# -ge 2 ]]; then
            local trace_tag="$1"
            shift
            printf 'Trace[%s]: %s\n' "$trace_tag" "$*" >&2
        else
            printf 'Trace: %s\n' "${1:-}" >&2
        fi
    fi
}

# Where the resolver file itself lives, captured at source time. This is the
# anchor for locate_support_file: in a source checkout the resolver sits in
# shared/; installed, it sits in the CLI data dir or a git hooks dir.
LOCAL_OVERRIDE_RESOLVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

# Locate a support file (VERSION, local-override-shell-init.sh, ...) via the
# single canonical fallback ladder:
#   1. next to the resolver itself (source-checkout shared/ files, and every
#      file in a CLI data-dir install)
#   2. the checkout root, only when the resolver runs from a source tree
#      (its directory is named shared/) — e.g. the repo-root VERSION file
#   3. the CLI data dir (hooks running from .git/hooks alongside an
#      installed CLI)
# Prints the absolute path; returns 1 when not found (never dies — callers
# that want fatal behavior die at the call site).
locate_support_file() {
    local name="$1"
    local data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/git-local-override"

    if [[ -n "$LOCAL_OVERRIDE_RESOLVER_DIR" && -f "$LOCAL_OVERRIDE_RESOLVER_DIR/$name" ]]; then
        printf '%s\n' "$LOCAL_OVERRIDE_RESOLVER_DIR/$name"
        return 0
    fi

    if [[ "${LOCAL_OVERRIDE_RESOLVER_DIR##*/}" == "shared" ]]; then
        local checkout_root="${LOCAL_OVERRIDE_RESOLVER_DIR%/*}"
        if [[ -n "$checkout_root" && -f "$checkout_root/$name" ]]; then
            printf '%s\n' "$checkout_root/$name"
            return 0
        fi
    fi

    if [[ -f "$data_dir/$name" ]]; then
        printf '%s\n' "$data_dir/$name"
        return 0
    fi

    return 1
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

# Git-dir/path helpers. These use the return-non-zero contract (never die):
# the resolver is sourced by hooks that must not hard-exit. Callers that want
# fatal behavior (the CLI) die at the call site.
get_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

# Memoized git context (one combined rev-parse instead of five). Keyed by
# repo root: consumers only trust it when their root argument matches
# _GIT_CTX_ROOT, so multi-root callers (apply --all-worktrees) fall back to
# per-call spawns. Loaded only from a process whose cwd is the worktree top
# (true for git-invoked filters and hooks) because the --git-path/--git-dir
# outputs are cwd-relative.
_GIT_CTX_ROOT=""
_GIT_CTX_GIT_DIR=""
_GIT_CTX_COMMON_DIR=""
_GIT_CTX_REBASE_MERGE=""
_GIT_CTX_REBASE_APPLY=""

load_git_context() {
    local output=""
    local line_num=0
    local line=""

    _GIT_CTX_ROOT=""
    output="$(git rev-parse --show-toplevel --git-dir --git-common-dir \
        --git-path rebase-merge --git-path rebase-apply 2>/dev/null)" || return 1

    while IFS= read -r line; do
        line_num=$((line_num + 1))
        case "$line_num" in
            1) _GIT_CTX_ROOT="$line" ;;
            2) _GIT_CTX_GIT_DIR="$line" ;;
            3) _GIT_CTX_COMMON_DIR="$line" ;;
            4) _GIT_CTX_REBASE_MERGE="$line" ;;
            5) _GIT_CTX_REBASE_APPLY="$line" ;;
        esac
    done <<< "$output"

    [[ -n "$_GIT_CTX_ROOT" && "$line_num" -ge 5 ]] || { _GIT_CTX_ROOT=""; return 1; }
}

# Git common directory as an absolute path (shared across linked worktrees).
get_common_git_dir() {
    local repo_root="$1"
    local common_git_dir=""

    common_git_dir="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null || echo "")"
    [[ -n "$common_git_dir" ]] || return 1

    if [[ "$common_git_dir" != /* ]]; then
        common_git_dir="$repo_root/$common_git_dir"
    fi

    printf '%s\n' "$common_git_dir"
}

get_attributes_file_path() {
    local repo_root="$1"
    local attributes_path=""

    attributes_path="$(git -C "$repo_root" rev-parse --git-path info/attributes 2>/dev/null || echo "")"
    [[ -n "$attributes_path" ]] || return 1

    if [[ "$attributes_path" != /* ]]; then
        attributes_path="$repo_root/$attributes_path"
    fi

    printf '%s\n' "$attributes_path"
}

# Exact marker line identifying installer-managed wrapper hooks. This is the
# single definition of "a hook we own": the installer writes it into every
# generated wrapper, and installer/uninstaller test for it with
# is_managed_wrapper_hook before rewriting or removing a hook. Ownership
# checks MUST use this exact marker (never fuzzy matching) so user-authored
# hooks are never touched. (The CLI's detect_hooks_installed deliberately
# keeps a looser heuristic — it answers "is something of ours here?" for
# status display, not "is this file ours to modify?")
MANAGED_HOOK_MARKER_PREFIX="# git-local-override-managed-hook:"

managed_hook_marker_line() {
    local hook_type="$1"
    printf '%s %s' "$MANAGED_HOOK_MARKER_PREFIX" "$hook_type"
}

is_managed_wrapper_hook() {
    local hook_file="$1"
    local hook_type="$2"
    local marker=""

    [[ -f "$hook_file" ]] || return 1
    marker="$(managed_hook_marker_line "$hook_type")"
    grep -qxF "$marker" "$hook_file" 2>/dev/null
}

# The managed-runtime manifest. These lists are the single definition of
# WHAT the installers materialize and the uninstaller may remove: the git
# hook types installed as managed wrapper hooks, the filter scripts, and the
# support libs that must travel together into a hooks dir for the runtime to
# resolve. install.sh (which may acquire files via curl), uninstall.sh, the
# test fixtures, and the bench harness all iterate these instead of carrying
# their own copies of the file set (which had already drifted apart).
managed_hook_types() {
    printf '%s\n' post-checkout pre-commit post-commit pre-rebase
}

managed_filter_scripts() {
    printf '%s\n' \
        local-override-filter-smudge \
        local-override-filter-clean \
        local-override-filter-process
}

# Everything that must sit NEXT TO the hook entry points: the filter scripts
# plus the shared lib and the resolver itself.
managed_runtime_files() {
    managed_filter_scripts
    printf '%s\n' local-override-lib.sh local-override-resolver.sh
}

# Where a managed runtime file lives in a SOURCE CHECKOUT (the resolver is
# the one file that ships from shared/, not hooks/). Owns the source-tree
# layout so copy-based callers don't re-encode it.
managed_runtime_source_path() {
    local project_dir="$1"
    local runtime_file="$2"

    if [[ "$runtime_file" == "local-override-resolver.sh" ]]; then
        printf '%s\n' "$project_dir/shared/local-override-resolver.sh"
    else
        printf '%s\n' "$project_dir/hooks/$runtime_file"
    fi
}

# Copy-based materializer for source checkouts: copies the managed runtime
# into <dest_dir>, and (unless <include_entry_hooks> is "false") the four
# entry hooks under their bare git hook names. Test fixtures and the bench
# harness call this; the real installers keep their own acquisition
# (install.sh can run via curl with no checkout on disk) but iterate the
# same manifest functions above. Returns non-zero on the first failed copy.
install_managed_runtime_from_checkout() {
    local project_dir="$1"
    local dest_dir="$2"
    local include_entry_hooks="${3:-true}"

    mkdir -p "$dest_dir" || return 1

    local runtime_file
    while IFS= read -r runtime_file || [[ -n "$runtime_file" ]]; do
        [[ -n "$runtime_file" ]] || continue
        cp "$(managed_runtime_source_path "$project_dir" "$runtime_file")" \
            "$dest_dir/$runtime_file" || return 1
        chmod +x "$dest_dir/$runtime_file" || return 1
    done < <(managed_runtime_files)

    [[ "$include_entry_hooks" == "false" ]] && return 0

    local hook_type
    while IFS= read -r hook_type || [[ -n "$hook_type" ]]; do
        [[ -n "$hook_type" ]] || continue
        cp "$project_dir/hooks/local-override-$hook_type" "$dest_dir/$hook_type" || return 1
        chmod +x "$dest_dir/$hook_type" || return 1
    done < <(managed_hook_types)
}

# Single writer for the filter.local-override.* driver config. Every site
# that configures the driver — install.sh (repo and template), the CLI's
# sync-filters, and the hooks' self-heal — goes through here, so the driver
# contract (script names, the %f convention, required=false, and which mode
# is active) lives in one place.
#
#   scope_target: a repo checkout root (written with `--local` there), or the
#                 literal string "global" (written with `--global`)
#   script_dir:   absolute directory holding the filter scripts
#   mode:         "scripts" (per-file %f smudge/clean, the default) or
#                 "process" (the experimental long-running filter, plan 019)
#
# Owns mode exclusivity: configuring one mode unsets the other, so the config
# never claims both drivers at once. Reads no environment switches — callers
# resolve the GIT_LOCAL_OVERRIDE_FILTER_PROCESS opt-in themselves. Prints
# nothing; returns non-zero on the first failed write (return-non-zero
# contract: callers choose fatal vs skip).
configure_filter_driver() {
    local scope_target="$1"
    local script_dir="$2"
    local mode="${3:-scripts}"

    local git_cfg
    if [[ "$scope_target" == "global" ]]; then
        git_cfg=(git config --global)
    else
        git_cfg=(git -C "$scope_target" config --local)
    fi

    if [[ "$mode" == "process" ]]; then
        "${git_cfg[@]}" --unset-all filter.local-override.smudge 2>/dev/null || true
        "${git_cfg[@]}" --unset-all filter.local-override.clean 2>/dev/null || true
        "${git_cfg[@]}" filter.local-override.process \
            "$script_dir/local-override-filter-process" || return 1
    else
        "${git_cfg[@]}" --unset-all filter.local-override.process 2>/dev/null || true
        "${git_cfg[@]}" filter.local-override.smudge \
            "$script_dir/local-override-filter-smudge %f" || return 1
        "${git_cfg[@]}" filter.local-override.clean \
            "$script_dir/local-override-filter-clean %f" || return 1
    fi

    "${git_cfg[@]}" filter.local-override.required false || return 1
}

# Canonical attributes-rewrite core. Preserves foreign lines in
# .git/info/attributes, drops the managed `filter=local-override` block, and
# regenerates it from the given `target|override` config entries (deduped).
# Return-non-zero contract (resolver never dies); the CLI dies at its call site.
# This is the single implementation the hook (lib.sh), the CLI, and the
# installer all delegate to (precedent: run_local_override_smudge/clean).
sync_attributes_entries() {
    local repo_root="$1"
    local config_entries="${2:-}"
    local attributes_file=""
    local temp_file=""
    local line=""
    local seen_targets=""
    local entry=""
    local target=""
    local has_targets=false
    local trace_on=false
    local total_start_ms=0
    local preserved_line_count=0
    local managed_target_count=0

    if local_override_trace_enabled; then
        trace_on=true
        total_start_ms="$(resolver_now_milliseconds)"
    fi

    attributes_file="$(get_attributes_file_path "$repo_root")" || return 1
    temp_file="$(mktemp)"

    mkdir -p "$(dirname "$attributes_file")"

    if [[ -f "$attributes_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == *"filter=local-override"* ]]; then
                continue
            fi
            if [[ "$line" == *"Auto-generated by git-local-override"* ]]; then
                continue
            fi
            printf '%s\n' "$line" >> "$temp_file"
            ((preserved_line_count++)) || true
        done < "$attributes_file"
    fi

    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -n "$entry" ]] || continue

        target="${entry%%|*}"
        [[ -n "$target" ]] || continue

        if [[ $'\n'"$seen_targets"$'\n' == *$'\n'"$target"$'\n'* ]]; then
            continue
        fi

        seen_targets="$seen_targets
$target"
        has_targets=true
        ((managed_target_count++)) || true
    done <<< "$config_entries"

    if [[ "$has_targets" == true ]]; then
        if [[ -s "$temp_file" ]]; then
            printf '\n' >> "$temp_file"
        fi

        printf '%s\n' '# Auto-generated by git-local-override — do not edit manually' >> "$temp_file"

        local attr_line_target=""
        while IFS= read -r target || [[ -n "$target" ]]; do
            [[ -n "$target" ]] || continue
            case "$target" in
                *[[:space:]]* | *'"'* | *'\'*)
                    # Quote per git's gitattributes double-quote form: escape
                    # backslash and double-quote, wrap in quotes. Whitespace is
                    # preserved literally inside the quotes.
                    attr_line_target="${target//\\/\\\\}"
                    attr_line_target="${attr_line_target//\"/\\\"}"
                    attr_line_target="\"$attr_line_target\""
                    ;;
                *)
                    attr_line_target="$target"
                    ;;
            esac
            printf '%s filter=local-override\n' "$attr_line_target" >> "$temp_file"
        done <<< "$seen_targets"
    fi

    # Explicit guard: callers may run inside an `if (subshell)` where errexit
    # is suppressed and a bare mv failure would leave attributes silently stale.
    mv "$temp_file" "$attributes_file" || return 1

    if [[ "$trace_on" == true ]]; then
        local_override_trace_log "sync_attributes path=$attributes_file preserved_lines=$preserved_line_count managed_targets=$managed_target_count total=$(resolver_elapsed_milliseconds "$total_start_ms")ms"
    fi
}

clear_legacy_skip_worktree() {
    local repo_root="$1"
    local config_entries="${2:-}"
    local repaired_count=0
    local seen_targets=""
    local entry=""
    local target=""
    local ls_output=""

    if [[ -z "$config_entries" ]]; then
        config_entries="$(read_config "$repo_root")"
    fi

    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue

        target="${entry%%|*}"
        [[ -n "$target" ]] || continue

        if [[ $'\n'"$seen_targets"$'\n' == *$'\n'"$target"$'\n'* ]]; then
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
    done <<< "$config_entries"

    printf '%s\n' "$repaired_count"
}

# Per-worktree marker recording that the one-time legacy skip-worktree repair has
# already run. skip-worktree is per-worktree index state, so the marker is keyed
# to the per-worktree absolute git dir (like get_post_commit_state_file), not the
# shared common dir — each worktree migrates its own index once.
skip_worktree_repair_marker() {
    local repo_root="$1"
    local worktree_git_dir=""

    worktree_git_dir="$(git -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null || echo "")"
    [[ -n "$worktree_git_dir" ]] || return 1

    printf '%s\n' "$worktree_git_dir/local-override-skipworktree-repaired"
}

# One-shot gated form of clear_legacy_skip_worktree for the hot paths
# (post-checkout, pre-commit, pre-rebase). Once the per-worktree marker exists the
# repair is skipped, so the two git subprocesses per managed target are only paid
# once per worktree instead of on every checkout/commit. install/sync-filters call
# the ungated clear_legacy_skip_worktree directly and remain the escape hatch for
# stray legacy bits. Prints the repaired count (0 when short-circuited) to match
# the count contract callers expect.
clear_legacy_skip_worktree_once() {
    local repo_root="$1"
    local config_entries="${2:-}"
    local marker=""
    local repaired=""

    marker="$(skip_worktree_repair_marker "$repo_root" 2>/dev/null || true)"
    if [[ -n "$marker" && -f "$marker" ]]; then
        printf '0\n'
        return 0
    fi

    repaired="$(clear_legacy_skip_worktree "$repo_root" "$config_entries")"
    [[ -n "$marker" ]] && : > "$marker"
    printf '%s\n' "$repaired"
}

cache_config_files() {
    local repo_root="$1"
    local mode="${2:-full}"
    local extra_paths="${3:-}"
    # Already cached for this root+mode; callers that mutate config files must
    # clear_config_files_cache first. Serving a hot cache to a full caller
    # (or vice versa) would hide/leak ignored configs, so the mode is keyed.
    if [[ -n "$_DISCOVER_CACHE_FILE" && -f "$_DISCOVER_CACHE_FILE" \
        && "$_DISCOVER_CACHE_ROOT" == "$repo_root" \
        && "$_DISCOVER_CACHE_MODE" == "$mode" ]]; then
        return 0
    fi
    clear_config_files_cache
    _DISCOVER_CACHE_FILE="$(mktemp)"
    _DISCOVER_CACHE_ROOT="$repo_root"
    _DISCOVER_CACHE_MODE="$mode"
    discover_config_files "$repo_root" "$mode" "$extra_paths" > "$_DISCOVER_CACHE_FILE"
}

clear_config_files_cache() {
    if [[ -n "$_DISCOVER_CACHE_FILE" && -f "$_DISCOVER_CACHE_FILE" ]]; then
        rm -f "$_DISCOVER_CACHE_FILE"
    fi
    _DISCOVER_CACHE_FILE=""
    _DISCOVER_CACHE_ROOT=""
    _DISCOVER_CACHE_MODE=""
}

get_cached_config_files() {
    local repo_root="$1"
    if [[ -n "$_DISCOVER_CACHE_FILE" && -f "$_DISCOVER_CACHE_FILE" \
        && "$_DISCOVER_CACHE_ROOT" == "$repo_root" ]]; then
        local_override_trace_log "discover_config_files cache=hit mode=$_DISCOVER_CACHE_MODE file=$_DISCOVER_CACHE_FILE"
        cat "$_DISCOVER_CACHE_FILE"
    else
        local_override_trace_log "discover_config_files cache=miss"
        discover_config_files "$repo_root"
    fi
}

# True when the discovery cache is already populated for repo_root, regardless
# of mode. A read-only consumer can reuse whatever is cached: a full cache is a
# superset of hot, and a hot cache populated earlier in the same process was
# stamp-validated before being cached. Lets a delegating read-only command
# (e.g. status -> list) skip re-deriving hot/full and avoids thrashing the
# mode key when the outer command settled on full. Callers that mutate config
# files must still clear_config_files_cache first.
config_files_cached_for() {
    local repo_root="$1"
    [[ -n "$_DISCOVER_CACHE_FILE" && -f "$_DISCOVER_CACHE_FILE" \
        && "$_DISCOVER_CACHE_ROOT" == "$repo_root" ]]
}

# Keyed to the per-worktree git dir (like the post-commit state file) so
# linked worktrees don't share a stale stamp.
get_config_stamp_file() {
    local repo_root="$1"
    local worktree_git_dir=""

    worktree_git_dir="$(git -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null || echo "")"
    [[ -n "$worktree_git_dir" ]] || return 1

    printf '%s\n' "$worktree_git_dir/local-override-config-stamp"
}

# Content stamp of the discovered config set: one "path|cksum size" line per
# discovered config file. Captures adds/removes/edits of gitignored or
# untracked configs, which a tracked HEAD diff cannot see. Content-based
# (cksum) rather than mtime-based: `stat` flags differ between BSD and GNU,
# mtime only has one-second granularity, and config files are small enough
# that reading them is negligible next to the discovery walk itself.
compute_config_stamp() {
    local resolution_root="$1"
    local config_path=""
    local checksum=""

    while IFS= read -r config_path || [[ -n "$config_path" ]]; do
        [[ -n "$config_path" ]] || continue
        checksum="$(cksum < "$resolution_root/$config_path" 2>/dev/null || printf 'unreadable\n')"
        printf '%s|%s\n' "$config_path" "$checksum"
    done < <(get_cached_config_files "$resolution_root")
}

# Record the config stamp after a successful full (slow-path) resolution,
# which is the authority for what the synced attributes were built from.
write_config_stamp() {
    local repo_root="$1"
    local resolution_root="$2"
    local stamp_file=""

    stamp_file="$(get_config_stamp_file "$repo_root" 2>/dev/null || true)"
    [[ -n "$stamp_file" ]] || return 0

    compute_config_stamp "$resolution_root" > "$stamp_file"
}

# Succeeds only when a recorded stamp exists and matches the current on-disk
# config set. A missing stamp (fresh install, first checkout) fails the match
# so callers fall back to the full slow path, which records it.
config_stamp_matches() {
    local repo_root="$1"
    local resolution_root="$2"
    local stamp_file=""
    local stored_stamp=""
    local current_stamp=""

    stamp_file="$(get_config_stamp_file "$repo_root" 2>/dev/null || true)"
    [[ -n "$stamp_file" && -f "$stamp_file" ]] || return 1

    stored_stamp="$(cat "$stamp_file" 2>/dev/null || true)"
    current_stamp="$(compute_config_stamp "$resolution_root")"

    [[ "$stored_stamp" == "$current_stamp" ]]
}

# Paths recorded in the checkout's config stamp (first |-field per line).
# Used by hot-mode discovery to re-check known gitignored configs without a
# full ignored-tree walk. Missing stamp => empty output.
get_stamped_config_paths() {
    local repo_root="$1"
    local stamp_file=""
    local line=""

    stamp_file="$(get_config_stamp_file "$repo_root" 2>/dev/null || true)"
    [[ -n "$stamp_file" && -f "$stamp_file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        printf '%s\n' "${line%%|*}"
    done < "$stamp_file"
}

# Populate the discovery cache for a read-only consumer: hot mode (non-ignored
# tree ∪ stamped gitignored configs) first, then fall back to a full walk if the
# config stamp no longer matches. Leaves the cache populated. Callers that mutate
# config files must NOT use this (they need an unconditional full walk).
# Hot first so config_stamp_matches's compute_config_stamp reads the hot
# cache (cache=hit) instead of triggering a throwaway uncached discovery.
# $1 = checkout root (stamp location), $2 = resolution root (config content).
# NOTE: post-checkout deliberately does NOT use this — its drift path also
# re-syncs attributes and writes the stamp, which this kernel does not do.
discover_config_files_hot_then_full() {
    local checkout_root="$1"
    local resolution_root="$2"
    cache_config_files "$resolution_root" hot "$(get_stamped_config_paths "$checkout_root")"
    if ! config_stamp_matches "$checkout_root" "$resolution_root"; then
        clear_config_files_cache
        cache_config_files "$resolution_root"
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

# Reject a managed path whose on-disk form is a symlink or resolves outside
# the repo root. Lexical validation (normalize_config_path) is not enough:
# cp/redirect follow symlinks, so a committed symlink target lets a hostile
# repo write outside the checkout. $1 = repo root, $2 = repo-relative path.
# Returns 0 when the path is safe to read/write, 1 when it must be refused.
path_is_symlink_safe() {
    local repo_root="$1"
    local rel_path="$2"
    local full_path="$repo_root/$rel_path"
    local resolved=""
    local resolved_root=""

    # Any symlink component on the path is refused outright.
    if [[ -L "$full_path" ]]; then
        return 1
    fi

    # Resolve the parent dir (it may legitimately not exist yet for a new
    # override file) and confirm the final real path stays under the repo root.
    resolved_root="$(cd "$repo_root" 2>/dev/null && pwd -P)" || return 1
    local parent_dir=""
    parent_dir="$(dirname "$full_path")"
    if [[ -d "$parent_dir" ]]; then
        resolved="$(cd "$parent_dir" 2>/dev/null && pwd -P)/$(basename "$full_path")" || return 1
        case "$resolved" in
            "$resolved_root"/*) return 0 ;;
            *) return 1 ;;
        esac
    fi

    return 0
}

# Memo for local_override_follow_symlinks_enabled, keyed by repo root. Filter
# processes are short-lived, so a config change mid-process is not a real
# scenario (tests reset by sourcing in a subshell).
_LO_FOLLOW_SYMLINKS_ROOT=""
_LO_FOLLOW_SYMLINKS_VALUE=""

# True iff the user locally opted in to following symlinked override sources.
# The key is read from git config (--local or global scope) — never from
# .local-overrides.yaml — so repo-shipped content can never enable it.
# $1 = repo root. Returns 0 when enabled.
local_override_follow_symlinks_enabled() {
    local repo_root="$1"

    if [[ -z "$_LO_FOLLOW_SYMLINKS_ROOT" || "$repo_root" != "$_LO_FOLLOW_SYMLINKS_ROOT" ]]; then
        _LO_FOLLOW_SYMLINKS_ROOT="$repo_root"
        _LO_FOLLOW_SYMLINKS_VALUE="$(git -C "$repo_root" config --get --type=bool \
            local-override.followSymlinkedOverrides 2>/dev/null || echo "false")"
    fi

    [[ "$_LO_FOLLOW_SYMLINKS_VALUE" == "true" ]]
}

# Override-source counterpart of path_is_symlink_safe. Overrides are only ever
# READ (cp source, cat, cmp), so a symlink the USER created may be followed
# once they opt in locally. The escape hatch never applies to a symlink git
# tracks at that path: a hostile repo can commit a symlink, but it cannot set
# the opt-in (git config is not repo-shippable content) and a committed link
# is tracked — either condition alone keeps the read refused. Dangling links
# are treated as a missing override, not followed.
# $1 = anchor dir, $2 = path relative to anchor, $3 = repo root (opt-in scope).
# Returns 0 when the override may be read.
override_path_is_symlink_safe() {
    local anchor_dir="$1"
    local rel_path="$2"
    local repo_root="$3"
    local full_path="$anchor_dir/$rel_path"

    if [[ ! -L "$full_path" ]]; then
        path_is_symlink_safe "$anchor_dir" "$rel_path"
        return
    fi

    local_override_follow_symlinks_enabled "$repo_root" || return 1

    # A tracked symlink is repo-controlled content: always refused.
    if git -C "$anchor_dir" ls-files --error-unmatch -- "$rel_path" >/dev/null 2>&1; then
        return 1
    fi

    # -f follows the link: dangling symlinks are not followed.
    [[ -f "$full_path" ]]
}

# Classify a symlinked override for display. $1=repo root, $2=repo-relative
# override path (caller has confirmed it IS a symlink). Prints one of:
#   followed       - opt-in on, untracked, resolves to a regular file
#   ignored-optout - opt-in off
#   tracked-refused- tracked by git (always refused)
#   dangling       - resolves to nothing
classify_symlinked_override() {
    local repo_root="$1"
    local rel_path="$2"
    if override_path_is_symlink_safe "$repo_root" "$rel_path" "$repo_root"; then
        printf 'followed\n'
    elif ! local_override_follow_symlinks_enabled "$repo_root"; then
        printf 'ignored-optout\n'
    elif git -C "$repo_root" ls-files --error-unmatch -- "$rel_path" >/dev/null 2>&1; then
        printf 'tracked-refused\n'
    else
        printf 'dangling\n'
    fi
}

# Write-side front door for applying an override onto a target — the
# counterpart of the read-side resolve_safe_override_for_file. Every cp of
# override content into the working tree goes through here, so the write-side
# safety invariant (both symlink gates, anchored on the TRUE resolution root)
# lives in one place.
#
#   checkout_root:   worktree whose target file is written
#   resolution_root: root that configs/overrides resolve against (the main
#                    checkout for fallback worktrees). The override
#                    containment check anchors HERE — never the override's
#                    own (possibly symlinked) parent dir.
#   target:          checkout-relative target path
#   override:        resolution-root-relative override path, or an absolute
#                    path that must sit under the resolution root (the
#                    post-commit reapply state records absolute paths)
#   verbosity:       "loud" (default) — refusals print one stderr line;
#                    "trace" — refusals log only under GIT_LOCAL_OVERRIDE_TRACE=1
#                    (routine refusals, e.g. an ignored symlinked override,
#                    must not print on every commit)
#
# Returns: 0 applied, 1 skipped (target or override file missing), 2 refused
# (symlink gate or anchoring failure), 3 copy failed. Never dies.
apply_override_to_target() {
    local checkout_root="$1"
    local resolution_root="$2"
    local target="$3"
    local override="$4"
    local verbosity="${5:-loud}"

    local refusal=""
    local override_rel="$override"
    if [[ "$override" == /* ]]; then
        override_rel="${override#"$resolution_root"/}"
        if [[ "$override_rel" == "$override" ]]; then
            refusal="refusing symlinked override for $target"
        fi
    fi

    if [[ -z "$refusal" ]]; then
        local full_target="$checkout_root/$target"
        local full_override="$resolution_root/$override_rel"

        [[ -f "$full_override" && -f "$full_target" ]] || return 1

        if ! path_is_symlink_safe "$checkout_root" "$target"; then
            refusal="refusing symlinked path for $target"
        elif ! override_path_is_symlink_safe "$resolution_root" "$override_rel" "$checkout_root"; then
            refusal="refusing symlinked override for $target"
        else
            cp "$full_override" "$full_target" 2>/dev/null || return 3
            return 0
        fi
    fi

    if [[ "$verbosity" == "trace" ]]; then
        local_override_trace_log "apply" "$refusal"
    else
        printf 'git-local-override: %s\n' "$refusal" >&2
    fi
    return 2
}

# Restore-side front door — the counterpart of apply_override_to_target for
# putting tracked HEAD content back onto a target. Every HEAD-restore of a
# managed target goes through here, so the restore invariants (the target
# symlink gate, filter suppression that works in BOTH filter modes, and an
# unconditional worktree write) live in one place.
#
# The worktree write is a blob redirect (`git show`), never `git checkout`:
# an applied override is stat-clean by construction (the clean-filter
# roundtrip), and checkout trusts the stat cache — it exits 0 without
# rewriting the file, leaving override bytes in place. The redirect writes
# unconditionally; that is also why the symlink gate is load-bearing here
# (a redirect writes THROUGH a symlinked target where checkout would
# replace it).
#
#   checkout_root: worktree whose target is restored
#   target:        checkout-relative target path
#   mode:          "worktree" — write HEAD bytes to the working tree only,
#                  leaving index state (e.g. a user's staged change) intact;
#                  "full" — working tree AND index. The re-stage runs under
#                  GIT_LOCAL_OVERRIDE_DISABLE=1, which both filter modes
#                  honor (a `-c filter.local-override.smudge=` override
#                  suppresses nothing in process mode — git never consults
#                  the smudge key when filter.<driver>.process is set)
#   verbosity:     "loud" (default) — refusals print one stderr line;
#                  "trace" — refusals log only under GIT_LOCAL_OVERRIDE_TRACE=1
#
# Returns: 0 restored, 1 skipped (target absent from HEAD — nothing to
# restore from), 2 refused (symlink gate), 3 restore failed. Never dies.
restore_target_to_head() {
    local checkout_root="$1"
    local target="$2"
    local mode="$3"
    local verbosity="${4:-loud}"

    git -C "$checkout_root" cat-file -e "HEAD:$target" 2>/dev/null || return 1

    if ! path_is_symlink_safe "$checkout_root" "$target"; then
        if [[ "$verbosity" == "trace" ]]; then
            local_override_trace_log "restore" "refusing symlinked path for $target"
        else
            printf 'git-local-override: refusing symlinked path for %s\n' "$target" >&2
        fi
        return 2
    fi

    local full_target="$checkout_root/$target"
    local parent_dir=""
    parent_dir="$(dirname "$full_target")"
    if [[ ! -d "$parent_dir" ]]; then
        mkdir -p "$parent_dir" 2>/dev/null || return 3
    fi

    git -C "$checkout_root" show "HEAD:$target" > "$full_target" 2>/dev/null || return 3

    if [[ "$mode" == "full" ]]; then
        GIT_LOCAL_OVERRIDE_DISABLE=1 git -C "$checkout_root" add -- "$target" 2>/dev/null || return 3
    fi

    return 0
}

# Emit `git worktree list --porcelain` records NUL-terminated. `-z` (git >=
# 2.36) is preferred: it is the only form that survives newlines in worktree
# paths. Older gits fall back to converting the newline-terminated porcelain
# output to NUL records — identical parsing, with the pre-existing
# newline-in-path limitation confined to those gits.
list_worktrees_porcelain_nul() {
    local repo_root="$1"

    if git -C "$repo_root" worktree list --porcelain -z 2>/dev/null; then
        return 0
    fi
    git -C "$repo_root" worktree list --porcelain 2>/dev/null | tr '\n' '\0'
}

# Repo-relative directories of linked worktrees that live INSIDE repo_root.
# Another checkout's config is not a subtree config of this checkout.
get_nested_worktree_dirs() {
    local repo_root="$1"
    local canonical_root=""
    local common_dir=""
    local line=""
    local wt_path=""

    # No linked worktrees can exist without a $GIT_COMMON_DIR/worktrees dir, so
    # skip the `git worktree list` spawn entirely in the common single-checkout
    # case (this runs on every discovery). Reuse the memoized git context when
    # it matches, else resolve the common dir with one cheap rev-parse.
    if [[ -n "$_GIT_CTX_ROOT" && "$repo_root" == "$_GIT_CTX_ROOT" ]]; then
        common_dir="$_GIT_CTX_COMMON_DIR"
    else
        common_dir="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null || echo "")"
    fi
    [[ -n "$common_dir" ]] || return 0
    # --git-common-dir is ".git" (relative to repo_root) for a main worktree and
    # absolute for a linked one; anchor the relative form before the -d test.
    case "$common_dir" in
        /*) ;;
        *) common_dir="$repo_root/$common_dir" ;;
    esac
    [[ -d "$common_dir/worktrees" ]] || return 0

    # `git worktree list` resolves symlinks in the paths it prints (e.g. macOS
    # /var -> /private/var), so compare against repo_root's resolved form too
    # or every entry silently fails the prefix match.
    canonical_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null || echo "$repo_root")"

    while IFS= read -r -d '' line || [[ -n "$line" ]]; do
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
    done < <(list_worktrees_porcelain_nul "$repo_root")
}

# discover_config_files <repo_root> [<mode>] [<extra_paths>]
#   mode = full (default): pass 1 (non-ignored tree) ∪ pass 2 (directly-ignored
#          configs in walked directories). Every existing caller keeps today's
#          contract.
#   mode = hot: pass 1 only ∪ <extra_paths> (newline-separated repo-relative
#          list — the config stamp's known gitignored configs). No ignored-tree
#          walk, so a brand-new gitignored config is invisible until
#          sync-filters/apply (full discovery) registers it.
# Neither mode descends into wholly-ignored directories or `.git`, so configs
# planted inside vendored/ignored trees are never discovered (see plan 043).
discover_config_files() {
    local repo_root="$1"
    local mode="${2:-full}"
    local extra_paths="${3:-}"
    local seen=""
    local path=""
    local strategy="$mode"
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

    # Pass 1: the non-ignored tree (tracked + untracked-not-ignored). This is
    # O(non-ignored tree) and is the only walk hot mode performs.
    tracked_output="$(git -C "$repo_root" ls-files --cached --others --exclude-standard --full-name -- "$CONFIG_FILE_NAME" "*/$CONFIG_FILE_NAME" 2>/dev/null || true)"

    if [[ "$trace_on" == true ]]; then
        tracked_ms="$(resolver_elapsed_milliseconds "$tracked_start_ms")"
    fi

    if [[ "$mode" == "hot" ]]; then
        # Hot mode: pass 1 plus the caller-supplied extra paths (stamped
        # gitignored configs). Extras join the candidate set BEFORE the sort so
        # ordering/dedup/filtering match pass-1 results exactly.
        combined_output="$({ printf '%s\n' "$tracked_output"; printf '%s\n' "$extra_paths"; } | LC_ALL=C sort)"
    else
        # Pass 2 (full only): directly-ignored configs. --directory keeps git
        # from descending into wholly-ignored directories — it collapses each to
        # its dir name (trailing slash), which the basename filter below then
        # drops, so node_modules/x/.local-overrides.yaml is never discovered. Do
        # NOT add git's emptiness-probing flag: it forces descent into ignored
        # dirs to test emptiness, which is exactly the walk we are avoiding.
        if [[ "$trace_on" == true ]]; then
            ignored_start_ms="$(resolver_now_milliseconds)"
        fi

        ignored_output="$(git -C "$repo_root" ls-files --others --ignored --exclude-standard --directory --full-name -- "$CONFIG_FILE_NAME" "*/$CONFIG_FILE_NAME" 2>/dev/null || true)"
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

        if [[ $'\n'"$seen"$'\n' == *$'\n'"$path"$'\n'* ]]; then
            continue
        fi

        seen="$seen
$path"
        printf '%s\n' "$path"
    done <<< "$combined_output"

    if [[ "$trace_on" == true ]]; then
        local_override_trace_log "discover_config_files strategy=${strategy} excluded=$(count_list_entries "$nested_dirs") tracked_ms=${tracked_ms} ignored_ms=${ignored_ms} total_ms=$(resolver_elapsed_milliseconds "$discover_start_ms") count=$(count_list_entries "$seen")"
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
            if ! current_override="$(normalize_config_path "$config_dir" "$current_override")"; then
                echo "Error: Override path in '$config_path' is invalid or escapes its subtree" >&2
                printf '%s|%s\n' "$LOCAL_OVERRIDE_PARSE_ERROR_SENTINEL" "$config_path"
                return 1
            fi
            in_replaces_section=false
            continue
        fi

        if [[ -n "$current_override" && "$line" =~ ^[[:space:]]+replaces:[[:space:]]*$ ]]; then
            in_replaces_section=true
            continue
        fi

        if [[ "$in_replaces_section" == true && "$line" =~ ^[[:space:]]+-[[:space:]]+(.+)$ ]]; then
            target="$(trim_config_value "${BASH_REMATCH[1]}")"
            if ! target="$(normalize_config_path "$config_dir" "$target")"; then
                echo "Error: Target path in '$config_path' is invalid or escapes its subtree" >&2
                printf '%s|%s\n' "$LOCAL_OVERRIDE_PARSE_ERROR_SENTINEL" "$config_path"
                return 1
            fi
            [[ -n "$target" ]] && printf '%s|%s\n' "$target" "$current_override"
            continue
        fi

        if [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
            in_replaces_section=false
            current_override=""
        fi
    done < "$config_file"
}

# Sentinel-free view of read_config_entries_for_file. The raw parser signals
# a parse error IN-BAND (the LOCAL_OVERRIDE_PARSE_ERROR_SENTINEL entry),
# because process substitution swallows its return code; validate_config is
# the one gate that inspects the sentinel and surfaces the error. Every other
# consumer wants "the valid entries, parse errors skipped" — this reader owns
# that skip so consumers never see the sentinel or re-filter it.
read_valid_config_entries_for_file() {
    local repo_root="$1"
    local config_path="$2"

    local entry
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -n "$entry" ]] || continue
        [[ "${entry%%|*}" == "$LOCAL_OVERRIDE_PARSE_ERROR_SENTINEL" ]] && continue
        printf '%s\n' "$entry"
    done < <(read_config_entries_for_file "$repo_root" "$config_path")
}

# Active-override predicate: a configured pair is active when the override
# file exists (at the resolution root) and the target file exists (in the
# checkout). One definition for the CLI's apply/status counting and the
# shell wrapper's active-target enumeration.
# $1 = resolution root, $2 = checkout root, $3 = target, $4 = override.
override_is_active() {
    local resolution_root="$1"
    local checkout_root="$2"
    local target="$3"
    local override="$4"

    [[ -f "$resolution_root/$override" && -f "$checkout_root/$target" ]]
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

            if [[ "$target" == "$LOCAL_OVERRIDE_PARSE_ERROR_SENTINEL" ]]; then
                echo "Error: '$override' contains an invalid path entry" >&2
                return 1
            fi

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

            case "$target" in
                *'*'* | *'?'* | *'['* | *']'*)
                    echo "Error: Target '$target' in '$config_path' contains a glob/attribute metacharacter (* ? [ ]) and cannot be managed" >&2
                    return 1
                    ;;
            esac

            if target_is_shadowed_by_child_config "$repo_root" "$config_path" "$target"; then
                echo "Error: Target '$target' in '$config_path' belongs to a child subtree config" >&2
                return 1
            fi

            if [[ $'\n'"$seen_targets"$'\n' == *$'\n'"$target"$'\n'* ]]; then
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

            if [[ $'\n'"$seen_targets"$'\n' == *$'\n'"$target"$'\n'* ]]; then
                ((duplicate_skip_count++)) || true
                continue
            fi

            seen_targets="$seen_targets
$target"
            ((emitted_count++)) || true
            printf '%s\n' "$entry"
        done < <(read_valid_config_entries_for_file "$repo_root" "$config_path")
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
    done < <(read_valid_config_entries_for_file "$repo_root" "$owner_config")

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
        done < <(read_valid_config_entries_for_file "$repo_root" "$config_path")
    done < <(get_cached_config_files "$repo_root")

    return 1
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

        if ! [[ $'\n'"$seen"$'\n' == *$'\n'"$override"$'\n'* ]]; then
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

    if [[ -n "$_GIT_CTX_ROOT" && "$1" == "$_GIT_CTX_ROOT" ]]; then
        git_dir="$_GIT_CTX_GIT_DIR"
        common_dir="$_GIT_CTX_COMMON_DIR"
    else
        git_dir="$(git -C "$repo_root" rev-parse --git-dir 2>/dev/null || echo "")"
        common_dir="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null || echo "")"
    fi
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

    while IFS= read -r -d '' line || [[ -n "$line" ]]; do
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
    done < <(list_worktrees_porcelain_nul "$repo_root")

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

# Safe front door for the filter cores and reapply path. Given the checkout
# repo root and a managed target path, prints the ABSOLUTE override path and
# returns 0 only when a readable, symlink-safe override exists — otherwise
# returns 1 with no output. Centralizes the "true resolution root + relative
# override" containment convention so callers can never anchor the symlink
# check on the override's own (possibly symlinked) parent directory (the
# SEC-01 bypass). $1 = checkout repo root, $2 = target file path (%f).
resolve_safe_override_for_file() {
    local repo_root="$1"
    local file_path="$2"
    local resolution_root=""
    local override_rel=""
    local override_abs=""

    resolution_root="$(get_resolution_root "$repo_root")"
    override_rel="$(get_override_for_target "$file_path" "$resolution_root" 2>/dev/null || true)"
    [[ -n "$override_rel" ]] || return 1

    override_abs="$resolution_root/$override_rel"
    [[ -f "$override_abs" ]] || return 1

    # True resolution root as the containment anchor; relative override as the
    # path. This is the same safe convention the CLI (apply/add) already uses.
    override_path_is_symlink_safe "$resolution_root" "$override_rel" "$repo_root" || return 1

    printf '%s\n' "$override_abs"
}

is_rebase_in_progress() {
    local repo_root="$1"
    local rebase_merge_path=""
    local rebase_apply_path=""

    # Free env check first — avoids spawning git when a rebase set it.
    if [[ "${GIT_REFLOG_ACTION:-}" == rebase* ]]; then
        return 0
    fi

    if [[ -n "$_GIT_CTX_ROOT" && "$1" == "$_GIT_CTX_ROOT" ]]; then
        rebase_merge_path="$_GIT_CTX_REBASE_MERGE"
        rebase_apply_path="$_GIT_CTX_REBASE_APPLY"
    else
        rebase_merge_path="$(git -C "$repo_root" rev-parse --git-path rebase-merge 2>/dev/null || true)"
        rebase_apply_path="$(git -C "$repo_root" rev-parse --git-path rebase-apply 2>/dev/null || true)"
    fi

    if [[ -n "$rebase_merge_path" && -d "$rebase_merge_path" ]]; then
        return 0
    fi

    if [[ -n "$rebase_apply_path" && -d "$rebase_apply_path" ]]; then
        return 0
    fi

    return 1
}

# True while a merge or cherry-pick is in progress (MERGE_HEAD /
# CHERRY_PICK_HEAD exists). At the concluding `git commit` of a conflicted
# merge/cherry-pick — or a `merge --no-commit` — HEAD is still "ours", so a
# pre-commit restore to HEAD:target would silently overwrite the genuine
# resolution staged in the index. Hooks use this to skip that restore.
# File checks (-f), not directory checks: both sentinels are plain ref files.
is_merge_or_cherry_pick_in_progress() {
    local repo_root="$1"
    local merge_head_path=""
    local cherry_pick_head_path=""

    merge_head_path="$(git -C "$repo_root" rev-parse --git-path MERGE_HEAD 2>/dev/null || true)"
    if [[ -n "$merge_head_path" && -f "$merge_head_path" ]]; then
        return 0
    fi

    cherry_pick_head_path="$(git -C "$repo_root" rev-parse --git-path CHERRY_PICK_HEAD 2>/dev/null || true)"
    if [[ -n "$cherry_pick_head_path" && -f "$cherry_pick_head_path" ]]; then
        return 0
    fi

    return 1
}

# Pre-commit deciders. The pre-commit hook's branching — which overrides get
# a grouped restore, and whether a staged managed target is leaking override
# bytes — lives here as directly callable functions (same split as the
# smudge/clean filter cores); the hook keeps only git mutations and
# user-facing messages.

# Usage: staged_contains <needle> <staged-path>...
# True when <needle> exactly matches one of the staged paths.
staged_contains() {
    local needle="$1"
    shift
    local staged_path=""
    for staged_path in "$@"; do
        [[ "$staged_path" == "$needle" ]] && return 0
    done
    return 1
}

# Byte-exact leak predicate: is the stage-0 blob of <target> identical to the
# override file? While a path is unmerged (or has no HEAD version), the clean
# filter passes working-tree bytes through during `git add`, so a blind add
# of an unedited conflicted/new file stages override bytes verbatim — this is
# how pre-commit detects it. File-based cmp, never $(...): command
# substitution strips trailing newlines and cannot carry NUL. Returns 1 when
# the override file does not exist.
staged_blob_matches_override() {
    local repo_root="$1"
    local target="$2"
    local override_abs="$3"
    local staged_tmp=""

    [[ -f "$override_abs" ]] || return 1

    staged_tmp="$(mktemp)"
    GIT_LOCAL_OVERRIDE_DISABLE=1 git -C "$repo_root" show ":$target" > "$staged_tmp" 2>/dev/null || true
    if cmp -s "$staged_tmp" "$override_abs"; then
        rm -f "$staged_tmp"
        return 0
    fi
    rm -f "$staged_tmp"
    return 1
}

# Grouped-restore decider: given the effective `target|override` entries and
# the staged paths, print the unique override files (resolution-root-relative)
# that have at least one staged target and an existing override file. If ANY
# target in a group is staged, ALL its targets are restored — callers expand
# each printed override back to its targets via the entries.
# Usage: precommit_plan_restores <resolution_root> <entries> <staged-path>...
precommit_plan_restores() {
    local resolution_root="$1"
    local entries="$2"
    shift 2

    local entry target override seen=""
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue
        target="${entry%%|*}"
        override="${entry#*|}"

        staged_contains "$target" "$@" || continue
        [[ -f "$resolution_root/$override" ]] || continue
        if [[ $'\n'"$seen"$'\n' != *$'\n'"$override"$'\n'* ]]; then
            seen="$seen
$override"
            printf '%s\n' "$override"
        fi
    done <<< "$entries"
}

# Merge/cherry-pick backstop decider: print `target|override` for the first
# staged managed target whose staged blob is byte-identical to its override
# (the blind-`git add`-of-override-content case); print nothing and return 1
# when no staged target leaks. The caller owns the refusal message.
# Usage: precommit_find_merge_leak <repo_root> <resolution_root> <entries> <staged-path>...
precommit_find_merge_leak() {
    local repo_root="$1"
    local resolution_root="$2"
    local entries="$3"
    shift 3

    local entry target override
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue
        target="${entry%%|*}"
        override="${entry#*|}"

        staged_contains "$target" "$@" || continue
        if staged_blob_matches_override "$repo_root" "$target" "$resolution_root/$override"; then
            printf '%s|%s\n' "$target" "$override"
            return 0
        fi
    done <<< "$entries"

    return 1
}

# Entries-scoped sibling of get_targets_for_override: expand one override
# file back to its targets WITHIN an already-computed entries list — the
# Group concept (all targets sharing one override) as a callable function.
# Pre-commit's grouped restore iterates this instead of re-filtering the
# entries inline. $1 = override path (as it appears in the entries),
# $2 = newline-delimited `target|override` entries.
targets_for_override_in_entries() {
    local override_file="$1"
    local entries="$2"

    local entry target override
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue
        target="${entry%%|*}"
        override="${entry#*|}"
        if [[ "$override" == "$override_file" ]]; then
            printf '%s\n' "$target"
        fi
    done <<< "$entries"
}

# New-target leak decider — the named sibling of precommit_find_merge_leak.
# A target absent from HEAD has no canonical content to restore; committing
# it would leak local content into history if what's staged is the override.
# git add always creates a stage-0 index blob, so the leak is detected by
# comparing that blob to the override, not by the index being absent.
# $1 = checkout root, $2 = target, $3 = absolute override path.
# Returns 0 when the commit must be refused; the caller owns the message.
precommit_new_target_leaks() {
    local repo_root="$1"
    local target="$2"
    local override_abs="$3"

    git -C "$repo_root" cat-file -e ":$target" 2>/dev/null || return 1
    staged_blob_matches_override "$repo_root" "$target" "$override_abs"
}

# ---------------------------------------------------------------------------
# Smudge/clean filter cores.
#
# These are the single, canonical implementation of the git smudge/clean
# filters. They are shared by BOTH entry points:
#   - the git-invoked hook scripts hooks/local-override-filter-{smudge,clean}
#   - the CLI subcommands `git-local-override filter-{smudge,clean}`
# Git actually runs the hooks, so the hook behavior is authoritative; routing
# the CLI subcommands through the same core keeps them byte-identical on stdout
# and prevents the two from silently drifting.
#
# INTENTIONAL ASYMMETRY (do not "fix"): the smudge core carries an
# is_rebase_in_progress passthrough guard; the clean core deliberately has NO
# rebase guard. During a rebase git checks out tracked blobs as part of its
# internal machinery, and emitting the override there interferes with the
# rebase (commit 75d4df6, "fix(rebase): prevent override interference during
# rebase internals"). The clean path has no such hazard, so it keeps
# transforming even mid-rebase. Keep this difference.
#
# BYTE-EXACTNESS: never capture filter output via $(...) — command
# substitution strips trailing newlines and cannot carry NUL bytes, which
# would break the clean(smudge(original)) == original roundtrip invariant. The
# clean core captures stdin and `git show` output into temp files instead.
# ---------------------------------------------------------------------------

# Reads original blob content on stdin, writes smudged content to stdout.
# $1 = file path (%f). Emits the local override content when a safe override
# exists, otherwise passes the incoming blob through unchanged.
run_local_override_smudge() {
    local file_path="${1:-}"

    if [[ "${GIT_LOCAL_OVERRIDE_DISABLE:-0}" == "1" ]]; then
        cat
        return 0
    fi

    local repo_root
    if load_git_context; then
        repo_root="$_GIT_CTX_ROOT"
    else
        cat
        return 0
    fi

    # During rebase, always passthrough tracked blob content (see 75d4df6).
    if is_rebase_in_progress "$repo_root"; then
        cat
        return 0
    fi

    local override_file
    override_file="$(resolve_safe_override_for_file "$repo_root" "$file_path")" || override_file=""

    # A repo-shipped or refused symlinked override yields no path here and falls
    # through to plain passthrough. User-created symlinks pass only behind the
    # local opt-in (read side only), enforced inside the helper.
    if [[ -n "$override_file" ]]; then
        cat > /dev/null
        cat "$override_file"
        return 0
    fi

    cat
}

# Reads working-tree content on stdin, writes cleaned content to stdout.
# $1 = file path (%f). When the incoming content is exactly the local override,
# substitutes the original tracked content from the git index so git sees the
# file as unmodified; otherwise passes the input through unchanged.
#
# NOTE: no is_rebase_in_progress guard here — this is deliberate; see the
# "INTENTIONAL ASYMMETRY" note above (commit 75d4df6).
run_local_override_clean() {
    local file_path="${1:-}"
    local stdin_tmp=""
    local override_file=""
    local compare_matched="no"
    local trace_on=false
    local total_start_ms=0
    local phase_start_ms=0
    local resolve_override_ms=0
    local git_show_ms=0

    if local_override_trace_enabled; then
        trace_on=true
        total_start_ms="$(resolver_now_milliseconds)"
    fi

    stdin_tmp="$(mktemp "${TMPDIR:-/tmp}/local-override-clean.XXXXXX")"
    cat > "$stdin_tmp"

    if [[ "${GIT_LOCAL_OVERRIDE_DISABLE:-0}" == "1" ]]; then
        cat "$stdin_tmp"
        rm -f "$stdin_tmp"
        return 0
    fi

    local repo_root
    if load_git_context; then
        repo_root="$_GIT_CTX_ROOT"
    else
        cat "$stdin_tmp"
        rm -f "$stdin_tmp"
        return 0
    fi

    override_file="$(resolve_safe_override_for_file "$repo_root" "$file_path")" || override_file=""
    if [[ "$trace_on" == true ]]; then
        resolve_override_ms="$(resolver_elapsed_milliseconds "$total_start_ms")"
    fi

    if [[ -n "$override_file" ]]; then
        # Only transform when incoming content is exactly the local override.
        # If caller already provided original/tracked content (e.g., pre-commit
        # restored file), passthrough avoids clobbering intended staged content.
        if cmp -s "$stdin_tmp" "$override_file"; then
            compare_matched="yes"
            if [[ "$trace_on" == true ]]; then
                phase_start_ms="$(resolver_now_milliseconds)"
            fi
            # Single `git show` captured to a temp file (not `$(...)`, which
            # strips trailing newlines and would break byte-exact roundtrip).
            local index_tmp
            index_tmp="$(mktemp "${TMPDIR:-/tmp}/local-override-index.XXXXXX")"
            if git -C "$repo_root" show ":$file_path" > "$index_tmp" 2>/dev/null; then
                cat "$index_tmp"
                if [[ "$trace_on" == true ]]; then
                    git_show_ms="$(resolver_elapsed_milliseconds "$phase_start_ms")"
                    local_override_trace_log "clean" "file=$file_path override=$override_file matched=$compare_matched transformed=1 resolve_override=${resolve_override_ms}ms git_show=${git_show_ms}ms total=$(resolver_elapsed_milliseconds "$total_start_ms")ms"
                fi
                rm -f "$index_tmp" "$stdin_tmp"
                return 0
            fi
            rm -f "$index_tmp"
        fi
    fi

    if [[ "$trace_on" == true ]]; then
        local_override_trace_log "clean" "file=$file_path override=${override_file:-none} matched=$compare_matched transformed=0 resolve_override=${resolve_override_ms}ms total=$(resolver_elapsed_milliseconds "$total_start_ms")ms"
    fi

    cat "$stdin_tmp"
    rm -f "$stdin_tmp"
}
