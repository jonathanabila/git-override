#!/usr/bin/env bash
#
# Docker entrypoint for running tests
#
# Usage:
#   ./entrypoint.sh all           # Run all tests
#   ./entrypoint.sh unit          # Run unit tests only
#   ./entrypoint.sh install       # Run install/uninstall tests
#   ./entrypoint.sh gitops        # Run git operations tests
#   ./entrypoint.sh worktree      # Run linked worktree tests
#   ./entrypoint.sh precommit     # Run pre-commit tests
#   ./entrypoint.sh filterprocess # Run filter.process roundtrip verifier
#   ./entrypoint.sh coverage      # Run unit suite under kcov (writes to /out)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TESTS_DIR="$PROJECT_DIR/tests"
INTEGRATION_DIR="$TESTS_DIR/integration"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() {
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  $*${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
}

# The suite table: SUITE_NAMES is the single list of suite names (also the
# canonical execution order), and run_named_suite is the single name->runner
# mapping. Arg validation, run-all, and the help string all derive from
# SUITE_NAMES — adding a suite means touching exactly these two places.
SUITE_NAMES="unit install gitops worktree precommit filterprocess"

# Track test results
SUITES_RUN=0
SUITES_PASSED=0
FAILED_SUITES=()

run_suite() {
    local name="$1"
    local script="$2"
    shift 2

    header "Running: $name"
    ((SUITES_RUN++)) || true

    if "$script" "$@"; then
        success "$name passed"
        ((SUITES_PASSED++)) || true
    else
        error "$name failed"
        FAILED_SUITES+=("$name")
    fi
}

run_named_suite() {
    local suite="$1"

    case "$suite" in
        unit)
            run_suite "Unit Tests" "$TESTS_DIR/run-tests.sh"
            ;;
        install)
            run_suite "Install/Uninstall Tests" "$INTEGRATION_DIR/test-install.sh"
            ;;
        gitops)
            run_suite "Git Operations Tests" "$INTEGRATION_DIR/test-git-ops.sh"
            ;;
        worktree)
            run_suite "Linked Worktree Tests" "$INTEGRATION_DIR/test-worktrees.sh"
            ;;
        precommit)
            if command -v pre-commit &>/dev/null; then
                run_suite "Pre-commit Framework Tests" "$INTEGRATION_DIR/test-precommit.sh"
            else
                info "Skipping pre-commit tests (pre-commit not installed)"
            fi
            ;;
        filterprocess)
            run_suite "Filter Process Roundtrip" "$TESTS_DIR/bench-filter-process.sh" --verify-only
            ;;
    esac
}

print_summary() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Test Summary${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "Bash version: $(bash --version | head -1)"
    echo "Git version: $(git --version)"
    if command -v pre-commit &>/dev/null; then
        echo "Pre-commit version: $(pre-commit --version)"
    fi
    echo ""

    if [[ $SUITES_PASSED -eq $SUITES_RUN ]]; then
        echo -e "${GREEN}All $SUITES_RUN test suites passed!${NC}"
        return 0
    else
        echo -e "${RED}$SUITES_PASSED/$SUITES_RUN test suites passed${NC}"
        echo ""
        echo "Failed suites:"
        for suite in "${FAILED_SUITES[@]}"; do
            echo "  - $suite"
        done
        return 1
    fi
}

main() {
    # Coverage is a standalone diagnostic, not part of the pass/fail suite
    # tracking, so it short-circuits before the normal dispatch.
    if [[ "${1:-}" == "coverage" ]]; then
        header "git-local-override Coverage (kcov)"
        exec "$TESTS_DIR/coverage.sh"
    fi

    header "git-local-override Docker Test Runner"

    info "Bash version: $(bash --version | head -1)"
    info "Git version: $(git --version)"
    if command -v pre-commit &>/dev/null; then
        info "Pre-commit version: $(pre-commit --version)"
    else
        info "Pre-commit: not installed"
    fi

    # Self-verify the interpreter under test. The bash3 image sets
    # EXPECT_BASH_MAJOR=3; if the image ever regresses to a newer bash, fail
    # loudly instead of silently testing the wrong interpreter version.
    if [[ -n "${EXPECT_BASH_MAJOR:-}" && "${BASH_VERSINFO[0]}" -ne "${EXPECT_BASH_MAJOR}" ]]; then
        error "Expected bash major version ${EXPECT_BASH_MAJOR}, got ${BASH_VERSION}"
        exit 1
    fi

    # Parse arguments against the suite table. Suites always execute in the
    # canonical SUITE_NAMES order (deduped), regardless of argument order —
    # same semantics as the old per-suite flags.
    local requested=""
    local arg suite

    if [[ $# -eq 0 ]]; then
        requested="$SUITE_NAMES"
    else
        for arg in "$@"; do
            if [[ "$arg" == "all" ]]; then
                requested="$SUITE_NAMES"
                continue
            fi
            if [[ " $SUITE_NAMES " == *" $arg "* ]]; then
                requested="$requested $arg"
            else
                error "Unknown test suite: $arg"
                echo "Available: all $SUITE_NAMES"
                exit 1
            fi
        done
    fi

    for suite in $SUITE_NAMES; do
        if [[ " $requested " == *" $suite "* ]]; then
            run_named_suite "$suite"
        fi
    done

    print_summary
}

main "$@"
