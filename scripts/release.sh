#!/usr/bin/env bash
set -euo pipefail

# Release script for git-local-override
# Converts [Unreleased] section to a versioned release

VERSION="${1:-}"
DATE=$(date +%Y-%m-%d)
CHANGELOG="CHANGELOG.md"

die() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    echo "Usage: $0 <version>" >&2
    echo "Example: $0 0.0.6" >&2
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

echo "Released version $VERSION"
echo ""
echo "Next steps:"
echo "  1. Review changes: git diff CHANGELOG.md"
echo "  2. Commit: git add CHANGELOG.md && git commit -m 'chore(release): v$VERSION'"
echo "  3. Tag: git tag v$VERSION"
echo "  4. Push: git push origin main --tags"
