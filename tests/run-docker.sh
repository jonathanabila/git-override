#!/usr/bin/env bash
#
# Run tests inside Docker containers
#
# Usage:
#   ./run-docker.sh              # Run all tests
#   ./run-docker.sh unit         # Run unit tests only
#   ./run-docker.sh bash3        # Run bash 3.2 compatibility tests
#   ./run-docker.sh bash3 unit   # Run unit tests with bash 3.2
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Default values
USE_BASH3=false
TEST_SUITES=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        bash3|bash32)
            USE_BASH3=true
            shift
            ;;
        *)
            TEST_SUITES+=("$1")
            shift
            ;;
    esac
done

# Default to all tests if none specified
if [[ ${#TEST_SUITES[@]} -eq 0 ]]; then
    TEST_SUITES=("all")
fi

# Select Dockerfile
if [[ "$USE_BASH3" == true ]]; then
    DOCKERFILE="$SCRIPT_DIR/docker/Dockerfile.bash3"
    IMAGE_NAME="git-local-override-test:bash3"
    info "Using bash 3.2 compatibility image"
else
    DOCKERFILE="$SCRIPT_DIR/docker/Dockerfile"
    IMAGE_NAME="git-local-override-test:latest"
    info "Using standard test image"
fi

# Build the image
info "Building Docker image: $IMAGE_NAME"
docker build -t "$IMAGE_NAME" -f "$DOCKERFILE" "$PROJECT_DIR"

# Run the tests
info "Running tests: ${TEST_SUITES[*]}"
docker run --rm "$IMAGE_NAME" "${TEST_SUITES[@]}"

exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    success "All tests passed!"
else
    error "Some tests failed (exit code: $exit_code)"
fi

exit $exit_code
