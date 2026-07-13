#!/usr/bin/env bash
#
# pin-manifest.sh — the single definition of which files carry hardcoded
# documentation version pins, and what a pin looks like.
#
# Sourced by BOTH sides of the pin lifecycle so they can never diverge:
#   - scripts/release.sh   (the writer: bumps v<prev> -> v<new> in PIN_FILES)
#   - tests/check-docs-sync.sh (the checker: greps PIN_RE and compares to VERSION)
#
# Add a new doc that pins the release version by adding it to PIN_FILES here —
# the releaser starts bumping it and the CI gate starts checking it, together.
#
# Bash 3.2 compatible. Paths are repo-root-relative.

# shellcheck disable=SC2034  # consumed by the sourcing scripts
PIN_FILES="README.md SECURITY.md .pre-commit-hooks.yaml bin/git-local-override"

# Two pin shapes: `rev: vX.Y.Z` snippet lines and `/vX.Y.Z/scripts/install.sh`
# URLs. Scoping to these avoids flagging CHANGELOG-style historical versions.
# shellcheck disable=SC2034  # consumed by tests/check-docs-sync.sh
PIN_RE='(rev: v[0-9]+\.[0-9]+\.[0-9]+|/v[0-9]+\.[0-9]+\.[0-9]+/scripts/install\.sh)'
