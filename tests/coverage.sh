#!/usr/bin/env bash
#
# Run the unit suite under kcov and write an HTML coverage report.
#
# This is an opt-in diagnostic (invoked via `make coverage`), NOT a CI gate. It
# instruments bin/, hooks/, and shared/ while running tests/run-tests.sh. kcov
# re-injects its bash tracer into child processes via BASH_ENV, so the git hooks
# and filter drivers that the suite spawns as separate processes are followed
# too; whatever is not reached still shows up as uncovered in the report.
#
# Usage:
#   tests/coverage.sh [OUTPUT_DIR]
#
# OUTPUT_DIR defaults to /out (the mount point used by `make coverage`). Falls
# back to <project>/coverage when run directly outside the container.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTPUT_DIR="${1:-}"
if [[ -z "$OUTPUT_DIR" ]]; then
    if [[ -d /out ]]; then
        OUTPUT_DIR="/out"
    else
        OUTPUT_DIR="$PROJECT_DIR/coverage"
    fi
fi

if ! command -v kcov >/dev/null 2>&1; then
    echo "Error: kcov is not installed. Run 'make coverage' (uses the Docker image) instead." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "Running unit suite under kcov..."
echo "  sources:  bin/ hooks/ shared/"
echo "  report:   $OUTPUT_DIR/index.html"

kcov \
    --include-path="$PROJECT_DIR/bin,$PROJECT_DIR/hooks,$PROJECT_DIR/shared" \
    "$OUTPUT_DIR" \
    "$PROJECT_DIR/tests/run-tests.sh"

echo "Coverage report written to $OUTPUT_DIR/index.html"
