#!/usr/bin/env bash
set -euo pipefail

# Release script for git-local-override
# Converts [Unreleased] section to a versioned release before the signed commit/tag step

VERSION="${1:-}"
DATE=$(date +%Y-%m-%d)
CHANGELOG="CHANGELOG.md"
VERSION_FILE="VERSION"

die() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    echo "Usage: $0 <version>" >&2
    echo "Example: $0 0.0.6" >&2
    echo "Prepares CHANGELOG.md for a stable release; signed commit, signed tag, and publish happen separately." >&2
    exit 1
}

# Validate arguments
if [[ -z "$VERSION" ]]; then
    usage
fi

# Validate version format
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    die "Invalid version format. Use semantic versioning (e.g., 0.0.6)"
fi

# Check changelog exists
if [[ ! -f "$CHANGELOG" ]]; then
    die "CHANGELOG.md not found"
fi

if [[ ! -f "$VERSION_FILE" ]]; then
    die "VERSION not found"
fi

# Check if [Unreleased] section has content
if ! grep -A2 "## \[Unreleased\]" "$CHANGELOG" | grep -q "^###"; then
    die "No changes found in [Unreleased] section"
fi

# Check if version already exists
if grep -q "## \[$VERSION\]" "$CHANGELOG"; then
    die "Version $VERSION already exists in changelog"
fi

# Get previous version for comparison link
PREV_VERSION=$(grep -oE '\[[0-9]+\.[0-9]+\.[0-9]+\]' "$CHANGELOG" | head -1 | tr -d '[]')

if [[ -z "$PREV_VERSION" ]]; then
    die "Could not determine previous version from changelog"
fi

# Create backup
cp "$CHANGELOG" "${CHANGELOG}.bak"

# Insert new version section after [Unreleased]
# Using awk for cross-platform compatibility (sed -i behaves differently on macOS vs Linux)
awk -v version="$VERSION" -v date="$DATE" '
    /^## \[Unreleased\]/ {
        print $0
        print ""
        print "## [" version "] - " date
        next
    }
    { print }
' "$CHANGELOG" > "${CHANGELOG}.tmp" && mv "${CHANGELOG}.tmp" "$CHANGELOG"

# Add comparison link at bottom (before the last link)
# Find the line with the first version link and insert before it
awk -v version="$VERSION" -v prev="$PREV_VERSION" '
    /^\['"$PREV_VERSION"'\]:/ && !added {
        print "[" version "]: https://github.com/jonathanabila/git-override/compare/v" prev "...v" version
        added = 1
    }
    { print }
' "$CHANGELOG" > "${CHANGELOG}.tmp" && mv "${CHANGELOG}.tmp" "$CHANGELOG"

# Remove backup on success
rm -f "${CHANGELOG}.bak"

printf '%s\n' "$VERSION" > "$VERSION_FILE"

# Bump hardcoded documentation version pins from the previous release to this one.
# release.sh otherwise only updates CHANGELOG.md and VERSION, leaving the pinned
# install/pre-commit snippets stale (they had to be re-bumped by hand for v0.6.0
# and v0.7.0). Each of these files pins `v<prev>` in a `rev:` line or a
# `/v<prev>/scripts/install.sh` URL; a global literal replace is safe because no
# other `v<prev>` string occurs in them. `make check-docs-sync` guards the result.
PIN_FILES="README.md SECURITY.md .pre-commit-hooks.yaml bin/git-local-override"
PREV_PIN_ESC=$(printf '%s' "$PREV_VERSION" | sed 's/[.]/\\./g')
UPDATED_PINS=""
for pin_file in $PIN_FILES; do
    if [[ ! -f "$pin_file" ]]; then
        echo "Warning: pin file $pin_file not found; skipping" >&2
        continue
    fi
    if ! grep -qF "v${PREV_VERSION}" "$pin_file"; then
        echo "Warning: no v${PREV_VERSION} pin found in $pin_file; skipping" >&2
        continue
    fi
    sed "s/v${PREV_PIN_ESC}/v${VERSION}/g" "$pin_file" > "${pin_file}.tmp" \
        && mv "${pin_file}.tmp" "$pin_file"
    UPDATED_PINS="${UPDATED_PINS} ${pin_file}"
done

# Assert no stale pin remains in any of the pin files after the bump.
for pin_file in $PIN_FILES; do
    [[ -f "$pin_file" ]] || continue
    if grep -qF "v${PREV_VERSION}" "$pin_file"; then
        die "Stale version pin v${PREV_VERSION} still present in $pin_file after bump"
    fi
done

echo "Released version $VERSION"
if [[ -n "$UPDATED_PINS" ]]; then
    echo "Bumped doc version pins (v${PREV_VERSION} -> v${VERSION}):${UPDATED_PINS}"
fi
echo ""
echo "Next steps:"
echo "  1. Review changes: git diff -- CHANGELOG.md VERSION"
echo "  2. Signed commit: git add CHANGELOG.md VERSION && git commit -S -m 'chore(release): v$VERSION'"
echo "  3. Signed tag: git tag -s v$VERSION -m 'v$VERSION'"
echo "  4. Push commit: git push origin main"
echo "  5. Push tag to publish GitHub release: git push origin v$VERSION"
