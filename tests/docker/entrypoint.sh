#!/usr/bin/env bash
#
# Docker entrypoint for running tests
#
# Usage:
#   ./entrypoint.sh all           # Run all tests
#   ./entrypoint.sh unit          # Run unit tests only
#   ./entrypoint.sh install       # Run install/uninstall tests
#   ./entrypoint.sh gitops        # Run git operations tests
#   ./entrypoint.sh precommit     # Run pre-commit tests
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
    header "git-local-override Docker Test Runner"

    info "Bash version: $(bash --version | head -1)"
    info "Git version: $(git --version)"
    if command -v pre-commit &>/dev/null; then
        info "Pre-commit version: $(pre-commit --version)"
    else
        info "Pre-commit: not installed"
    fi

    # Parse arguments
    local run_all=false
    local run_unit=false
    local run_install=false
    local run_gitops=false
    local run_precommit=false

    if [[ $# -eq 0 ]] || [[ "$1" == "all" ]]; then
        run_all=true
    else
        for arg in "$@"; do
            case "$arg" in
                unit) run_unit=true ;;
                install) run_install=true ;;
                gitops) run_gitops=true ;;
                precommit) run_precommit=true ;;
                all) run_all=true ;;
                *)
                    error "Unknown test suite: $arg"
                    echo "Available: all, unit, install, gitops, precommit"
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
        run_precommit_tests
    else
        [[ "$run_unit" == true ]] && run_unit_tests
        [[ "$run_install" == true ]] && run_install_tests
        [[ "$run_gitops" == true ]] && run_gitops_tests
        [[ "$run_precommit" == true ]] && run_precommit_tests
    fi

    print_summary
}

main "$@"
