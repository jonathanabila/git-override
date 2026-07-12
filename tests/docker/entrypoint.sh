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

# Track test results
SUITES_RUN=0
SUITES_PASSED=0
FAILED_SUITES=()

run_suite() {
    local name="$1"
    local script="$2"

    header "Running: $name"
    ((SUITES_RUN++)) || true

    if "$script"; then
        success "$name passed"
        ((SUITES_PASSED++)) || true
    else
        error "$name failed"
        FAILED_SUITES+=("$name")
    fi
}

run_unit_tests() {
    run_suite "Unit Tests" "$TESTS_DIR/run-tests.sh"
}

run_install_tests() {
    if [[ -f "$INTEGRATION_DIR/test-install.sh" ]]; then
        run_suite "Install/Uninstall Tests" "$INTEGRATION_DIR/test-install.sh"
    else
        info "Skipping install tests (not found)"
    fi
}

run_gitops_tests() {
    if [[ -f "$INTEGRATION_DIR/test-git-ops.sh" ]]; then
        run_suite "Git Operations Tests" "$INTEGRATION_DIR/test-git-ops.sh"
    else
        info "Skipping git operations tests (not found)"
    fi
}

run_worktree_tests() {
    if [[ -f "$INTEGRATION_DIR/test-worktrees.sh" ]]; then
        run_suite "Linked Worktree Tests" "$INTEGRATION_DIR/test-worktrees.sh"
    else
        info "Skipping linked worktree tests (not found)"
    fi
}

run_precommit_tests() {
    if [[ -f "$INTEGRATION_DIR/test-precommit.sh" ]]; then
        # Check if pre-commit is available
        if command -v pre-commit &>/dev/null; then
            run_suite "Pre-commit Framework Tests" "$INTEGRATION_DIR/test-precommit.sh"
        else
            info "Skipping pre-commit tests (pre-commit not installed)"
        fi
    else
        info "Skipping pre-commit tests (not found)"
    fi
}

run_filterprocess_tests() {
    # bench-filter-process.sh needs the --verify-only argument, which run_suite
    # cannot pass through, so replicate its pass/fail-by-exit-code tracking here.
    header "Running: Filter Process Roundtrip"
    ((SUITES_RUN++)) || true
    if "$TESTS_DIR/bench-filter-process.sh" --verify-only; then
        success "Filter Process Roundtrip passed"
        ((SUITES_PASSED++)) || true
    else
        error "Filter Process Roundtrip failed"
        FAILED_SUITES+=("Filter Process Roundtrip")
    fi
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

    # Parse arguments
    local run_all=false
    local run_unit=false
    local run_install=false
    local run_gitops=false
    local run_worktree=false
    local run_precommit=false
    local run_filterprocess=false

    if [[ $# -eq 0 ]] || [[ "$1" == "all" ]]; then
        run_all=true
    else
        for arg in "$@"; do
            case "$arg" in
                unit) run_unit=true ;;
                install) run_install=true ;;
                gitops) run_gitops=true ;;
                worktree) run_worktree=true ;;
                precommit) run_precommit=true ;;
                filterprocess) run_filterprocess=true ;;
                all) run_all=true ;;
                *)
                    error "Unknown test suite: $arg"
                    echo "Available: all, unit, install, gitops, worktree, precommit, filterprocess"
                    exit 1
                    ;;
            esac
        done
    fi

    # Run requested test suites
    if [[ "$run_all" == true ]]; then
        run_unit_tests
        run_install_tests
        run_gitops_tests
        run_worktree_tests
        run_precommit_tests
        run_filterprocess_tests
    else
        [[ "$run_unit" == true ]] && run_unit_tests
        [[ "$run_install" == true ]] && run_install_tests
        [[ "$run_gitops" == true ]] && run_gitops_tests
        [[ "$run_worktree" == true ]] && run_worktree_tests
        [[ "$run_precommit" == true ]] && run_precommit_tests
        [[ "$run_filterprocess" == true ]] && run_filterprocess_tests
    fi

    print_summary
}

main "$@"
