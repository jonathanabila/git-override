#!/usr/bin/env bash
#
# check-docs-sync.sh — guard against recurring documentation drift.
#
# This is a CI gate (invoked via `make check-docs-sync`, part of `make ci`),
# NOT a member of the unit suite — mirroring how `make check-resolver-sync`
# is run. It performs two checks:
#
#   (a) Pin check: every hardcoded documentation version pin (the pre-commit
#       `rev: vX.Y.Z` snippets and the pinned `/vX.Y.Z/scripts/install.sh`
#       install URLs) matches the current `VERSION`. `scripts/release.sh` bumps
#       these automatically; this check catches a missed or stale bump.
#
#   (b) Command coverage check: every public CLI command in the dispatch `case`
#       of `bin/git-local-override` appears in both the `help` text and the
#       README `## CLI Commands` table.
#
# Bash 3.2 compatible. Run from anywhere; the repo root is resolved from the
# script's own path.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

CLI="bin/git-local-override"
README="README.md"

# Internal/undocumented dispatch cases that are intentionally NOT in the README
# command table (help lists the two filters; the README omits them by design).
INTERNAL_COMMANDS="_get-active-targets filter-smudge filter-clean"

fail=0

#------------------------------------------------------------------------------
# (a) Version pin check
#------------------------------------------------------------------------------

expected="v$(cat VERSION)"
pin_files="README.md SECURITY.md .pre-commit-hooks.yaml bin/git-local-override"

# Two pin shapes: `rev: vX.Y.Z` snippet lines and `/vX.Y.Z/scripts/install.sh`
# URLs. Scoping to these avoids flagging CHANGELOG-style historical versions.
pin_re='(rev: v[0-9]+\.[0-9]+\.[0-9]+|/v[0-9]+\.[0-9]+\.[0-9]+/scripts/install\.sh)'

pin_count=0
while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    pin_count=$((pin_count + 1))
    file="${match%%:*}"
    rest="${match#*:}"
    lineno="${rest%%:*}"
    ver="$(printf '%s\n' "$match" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [[ "$ver" != "$expected" ]]; then
        echo "  pin mismatch: $file:$lineno pins $ver, expected $expected" >&2
        fail=1
    fi
done < <(grep -nHE "$pin_re" $pin_files 2>/dev/null || true)

if [[ "$pin_count" -eq 0 ]]; then
    echo "ERROR: no version pins found — the pin patterns may have moved" >&2
    fail=1
fi

#------------------------------------------------------------------------------
# (b) Command coverage check
#------------------------------------------------------------------------------

# Public command list: the `<cmd>)` patterns from the dispatch `case "$cmd" in`
# block, taking the first alias of each (e.g. `remove|rm` -> `remove`,
# `version|--version` -> `version`), minus the internal cases and `*)`.
# The trailing `*)` default is dropped here so the unquoted `for` loop below
# never glob-expands a bare `*` into repo filenames.
commands="$(awk '/case "\$cmd" in/{f=1; next} f && /esac/{exit} f{print}' "$CLI" \
    | sed -E 's/^[[:space:]]*([^)]*)\).*/\1/' \
    | cut -d'|' -f1 \
    | grep -vFx '*')"

help_out="$(bash "$CLI" help 2>/dev/null || true)"

# Extract the README `## CLI Commands` section only (heading to the next `## `),
# so `doctor` in the Troubleshooting section can't mask a missing table row.
readme_section="$(awk '/^## .*CLI Commands/{f=1; print; next} /^## /{if(f) exit} f{print}' "$README")"

missing_help=""
missing_readme=""
command_count=0

for cmd in $commands; do
    [[ -z "$cmd" ]] && continue
    [[ "$cmd" == "*" ]] && continue
    skip=0
    for internal in $INTERNAL_COMMANDS; do
        if [[ "$cmd" == "$internal" ]]; then
            skip=1
            break
        fi
    done
    [[ "$skip" -eq 1 ]] && continue

    command_count=$((command_count + 1))

    if ! printf '%s\n' "$help_out" | grep -qF "$cmd"; then
        missing_help="${missing_help} ${cmd}"
        fail=1
    fi

    if [[ "$cmd" == "version" ]]; then
        if ! printf '%s\n' "$readme_section" | grep -qE 'git-local-override (--version|version)'; then
            missing_readme="${missing_readme} ${cmd}"
            fail=1
        fi
    else
        if ! printf '%s\n' "$readme_section" | grep -qF "git-local-override $cmd"; then
            missing_readme="${missing_readme} ${cmd}"
            fail=1
        fi
    fi
done

if [[ -n "$missing_help" ]]; then
    echo "  missing from help:${missing_help}" >&2
fi
if [[ -n "$missing_readme" ]]; then
    echo "  missing from README table:${missing_readme}" >&2
fi

#------------------------------------------------------------------------------
# Result
#------------------------------------------------------------------------------

if [[ "$fail" -ne 0 ]]; then
    echo "ERROR: documentation is out of sync (see above)" >&2
    exit 1
fi

echo "docs in sync: $pin_count pins @ $expected, $command_count commands covered"
