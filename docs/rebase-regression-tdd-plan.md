# Rebase Regression TDD Plan

> **Status: Implemented and shipped (pre-rebase hook). Retained for historical reference.**

## Goal

Reproduce and fix a `git rebase` failure caused by `git-local-override` when a local override file remains present for a tracked target like `AGENTS.md`.

## Problem Statement

Observed behavior in a downstream repo:

- `git status` appears clean before rebase
- `AGENTS.md` working tree content differs from `HEAD`
- `git rebase origin/dev` fails with:
  - `Your local changes to the following files would be overwritten by checkout: AGENTS.md`
- Moving the local override file out of the repo allows the rebase to succeed

Confirmed signals:

- `skip-worktree` is not the only explanation
- `filter-clean` currently returns `HEAD:$file_path`
- `pre-rebase` is installed, so missing hook installation is not the root cause
- `post-checkout` is installed and is not rebase-aware

## Root Cause Hypothesis

There are likely two cooperating bugs:

1. `hooks/local-override-filter-clean` uses `HEAD:$file_path`
   - This can make `git status` appear clean even when the working tree content differs from what rebase/checkouts need to compare against
   - `HEAD` is the wrong reference during rebase and other nontrivial checkout/index transitions

2. Override reapplication is not disabled during rebase
   - `hooks/local-override-post-checkout`
   - `hooks/local-override-post-commit`
   - likely `hooks/local-override-filter-smudge`
   - These may reintroduce override content during rebase internal checkouts

## TDD Strategy

1. Establish a baseline for existing rebase-related tests
2. Add a failing regression test that reproduces the exact bug
3. Add a proof test for the current workaround
4. Implement the smallest safe fix set
5. Re-run focused tests
6. Run broader validation
7. Classify every failure as:
   - pre-existing
   - expected due to retiring buggy behavior
   - true regression introduced by the fix

## New Regression Test Requirements

The new failing test must prove:

- The override file exists and remains present during rebase
- The target file in the working tree differs from `HEAD`
- `git status` still appears clean before rebase
- The file is not only hidden by `skip-worktree`
- `git rebase <base>` fails with `would be overwritten by checkout`

## Workaround Proof Test Requirements

The workaround test must prove:

- Same setup as the regression test
- Remove or move the override file immediately before rebase
- `git rebase <base>` succeeds

## Pseudo-Shell: Regression Test

```bash
test_rebase_fails_when_override_file_remains_present() {
    info "Testing rebase failure with override file present and filters active..."

    cd "$TEST_DIR"

    local default_branch
    default_branch=$(git rev-parse --abbrev-ref HEAD)

    git branch -D rebase-override-present 2>/dev/null || true

    git checkout -q -b rebase-override-present

    cat > AGENTS.local.md <<'EOF'
# MY LOCAL AGENTS
local customized content
EOF

    cp AGENTS.local.md AGENTS.md
    git update-index --no-skip-worktree AGENTS.md 2>/dev/null || true

    echo "feature-line" >> README.md
    git add README.md
    git commit -q -m "Feature commit for rebase reproduction"

    git checkout -q "$default_branch"
    git update-index --no-skip-worktree AGENTS.md 2>/dev/null || true
    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout HEAD -- AGENTS.md
    echo "# Upstream AGENTS change" > AGENTS.md
    GIT_LOCAL_OVERRIDE_DISABLE=1 git add AGENTS.md
    git commit -q --no-verify -m "Upstream updates AGENTS"

    GIT_LOCAL_OVERRIDE_DISABLE=1 git checkout -q rebase-override-present

    working_hash=$(shasum AGENTS.md | awk '{print $1}')
    head_hash=$(git show HEAD:AGENTS.md | shasum | awk '{print $1}')

    if [[ "$working_hash" == "$head_hash" ]]; then
        fail "Setup invalid: working tree does not differ from HEAD"
        return 1
    fi

    status_output=$(git status --porcelain=v2 -- AGENTS.md 2>/dev/null || true)

    if [[ -n "$status_output" ]]; then
        fail "Setup invalid: AGENTS.md already visible in status: $status_output"
        return 1
    fi

    local rebase_output
    local rebase_status
    set +e
    rebase_output=$(git rebase "$default_branch" 2>&1)
    rebase_status=$?
    set -e

    if [[ $rebase_status -eq 0 ]]; then
        fail "Expected rebase failure, but rebase succeeded"
        return 1
    fi

    if ! echo "$rebase_output" | grep -q "would be overwritten by checkout"; then
        fail "Rebase failed for unexpected reason: $rebase_output"
        return 1
    fi

    pass "Reproduced rebase failure with override file present"

    git rebase --abort 2>/dev/null || true
    git checkout -q "$default_branch" 2>/dev/null || true
}
```

## Pseudo-Shell: Workaround Test

```bash
test_rebase_succeeds_when_override_file_removed_before_rebase() {
    # same setup as the failing test

    rm -f AGENTS.local.md

    local rebase_output
    local rebase_status
    set +e
    rebase_output=$(git rebase "$default_branch" 2>&1)
    rebase_status=$?
    set -e

    if [[ $rebase_status -ne 0 ]]; then
        fail "Expected rebase success after removing override file: $rebase_output"
        git rebase --abort 2>/dev/null || true
        return 1
    fi

    pass "Rebase succeeds when override file is removed"
}
```

## Implementation Checklist

- Establish baseline
  - Run existing rebase-related tests
  - Record current pass/fail state

- Add red tests
  - Add the new regression test
  - Add the workaround proof test
  - Confirm regression test fails on current code
  - Confirm workaround test passes

- Implement the smallest safe fix set
  - Add `is_rebase_in_progress()` to `hooks/local-override-lib.sh`
  - Guard `hooks/local-override-post-checkout` during rebase
  - Guard `hooks/local-override-post-commit` during rebase
  - Guard `hooks/local-override-filter-smudge` during rebase
  - Fix `hooks/local-override-filter-clean` to stop using `HEAD:$file_path`
  - Make clean filter prefer current index content, with safe fallbacks

- Validate focused behavior
  - Re-run new regression test
  - Re-run workaround test
  - Re-run existing rebase/git-ops tests

- Validate broader behavior
  - Run `tests/run-tests.sh`
  - Run integration suites
  - Run Docker suites

- Classify failures
  - Note exact failing test and message
  - Compare against pre-change baseline
  - Explain whether the failure is:
    - pre-existing
    - expected due to retiring buggy behavior
    - true regression

- Update docs/tests if needed
  - Adjust README claims if necessary
  - Add regression coverage for the rebase scenario permanently

## Expected Fix Direction

The likely robust fix is a combination of:

- correctness fix:
  - stop using `HEAD` in `filter-clean`

- lifecycle fix:
  - disable override reapplication/filter behavior during rebase

`pre-rebase` remains useful, but is not sufficient by itself.

## Success Criteria

- The new regression test fails before the fix and passes after
- Rebase succeeds with the override file still present
- Existing related tests pass or are explicitly updated for retired buggy behavior
- Any remaining failures are explained and shown not to be regressions introduced by the fix
