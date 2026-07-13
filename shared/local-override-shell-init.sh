# git-local-override shell integration
# Wraps git to transparently handle checkout/switch with overridden files.
# Usage: eval "$(git-local-override shell-init)"
git() {
    # Fast path: no git-local-override CLI available
    if ! command -v git-local-override >/dev/null 2>&1; then
        command git "$@"
        return $?
    fi

    # Detect checkout/switch subcommands
    local subcmd=""
    local has_dashdash=false
    local arg
    for arg in "$@"; do
        if [[ "$arg" == "--" ]]; then
            has_dashdash=true
            break
        fi
        # First non-flag argument is the subcommand
        if [[ -z "$subcmd" && "$arg" != -* ]]; then
            subcmd="$arg"
        fi
    done

    # Only intercept checkout and switch (not file checkouts with --)
    if [[ "$subcmd" != "checkout" && "$subcmd" != "switch" ]] || [[ "$has_dashdash" == true ]]; then
        command git "$@"
        return $?
    fi

    if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
        command git "$@"
        return $?
    fi

    # Get active override targets (one call; empty means nothing to intercept)
    local targets
    targets="$(git-local-override _get-active-targets 2>/dev/null)"

    if [[ -z "$targets" ]]; then
        command git "$@"
        return $?
    fi

    # Before checkout: restore originals for all active targets via the CLI's
    # restore front door. One anchored call — the old per-target
    # `git checkout HEAD --` loop resolved pathspecs against the user's cwd
    # (silently failing from subdirectories) and its smudge suppression did
    # not cover the experimental process filter mode.
    git-local-override _restore-active-targets 2>/dev/null || true

    # Run the actual git command
    local git_status=0
    command git "$@" || git_status=$?

    # On failure: re-apply overrides on current branch
    if [[ $git_status -ne 0 ]]; then
        git-local-override apply 2>/dev/null || true
    fi
    # On success: smudge filter re-applies overrides automatically;
    # post-checkout hook also copies override content as belt-and-suspenders

    return $git_status
}
