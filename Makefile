# git-local-override Makefile
#
# Usage:
#   make install    - Install globally
#   make uninstall  - Remove global installation
#   make test       - Run test suite
#   make clean      - Clean test artifacts
#   make help       - Show this help

.PHONY: install uninstall test clean help check-bash lint fmt fmt-check \
       ci coverage \
       test-docker test-docker-bash3 test-docker-unit test-docker-install \
       test-docker-gitops test-docker-worktree test-docker-precommit \
       test-docker-filter-process \
       docker-build docker-build-bash3

# Default target
.DEFAULT_GOAL := help

# Source directories
SRC_BIN := bin
SRC_HOOKS := hooks
SRC_SCRIPTS := scripts
SRC_SHARED := shared
SRC_TESTS := tests

# Source files
CLI_TOOL := $(SRC_BIN)/git-local-override
HOOK_SCRIPTS := $(wildcard $(SRC_HOOKS)/local-override-*)
INSTALL_SCRIPT := $(SRC_SCRIPTS)/install.sh
UNINSTALL_SCRIPT := $(SRC_SCRIPTS)/uninstall.sh
RESOLVER := $(SRC_SHARED)/local-override-resolver.sh
TEST_SCRIPTS := $(wildcard $(SRC_TESTS)/*.sh) \
	$(wildcard $(SRC_TESTS)/docker/*.sh) \
	$(wildcard $(SRC_TESTS)/integration/*.sh)

# All shell sources covered by the lint gate
LINT_FILES := $(CLI_TOOL) $(HOOK_SCRIPTS) $(INSTALL_SCRIPT) $(UNINSTALL_SCRIPT) \
	$(RESOLVER) $(TEST_SCRIPTS)

#------------------------------------------------------------------------------
# Installation
#------------------------------------------------------------------------------

install: check-bash ## Install git-local-override globally
	@echo "Installing git-local-override..."
	@./$(INSTALL_SCRIPT)
	@echo ""
	@echo "Installation complete!"
	@echo "Run 'git-local-override help' to get started."

uninstall: ## Remove git-local-override installation
	@echo "Uninstalling git-local-override..."
	@./$(UNINSTALL_SCRIPT)

#------------------------------------------------------------------------------
# Development
#------------------------------------------------------------------------------

test: check-bash clean-test ## Run the test suite
	@echo "Running test suite..."
	@cd $(SRC_TESTS) && ./run-tests.sh

test-verbose: check-bash clean-test ## Run tests with verbose output
	@echo "Running test suite (verbose)..."
	@cd $(SRC_TESTS) && bash -x ./run-tests.sh

clean: clean-test ## Clean all generated files
	@echo "Cleaned."

clean-test: ## Clean test artifacts only
	@rm -rf $(SRC_TESTS)/test-repo $(SRC_TESTS)/test-config
	@rm -rf $(SRC_TESTS)/integration/test-workspace
	@rm -rf $(SRC_TESTS)/integration/test-gitops
	@rm -rf $(SRC_TESTS)/integration/test-precommit
	@echo "Test artifacts cleaned."

#------------------------------------------------------------------------------
# Docker Testing
#------------------------------------------------------------------------------

DOCKER_IMAGE := git-local-override-test
DOCKER_IMAGE_BASH3 := git-local-override-test:bash3

docker-build: ## Build the Docker test image
	@echo "Building Docker test image..."
	@docker build -t $(DOCKER_IMAGE) -f $(SRC_TESTS)/docker/Dockerfile .

docker-build-bash3: ## Build the bash 3.2 compatibility test image
	@echo "Building bash 3.2 compatibility test image..."
	@docker build -t $(DOCKER_IMAGE_BASH3) -f $(SRC_TESTS)/docker/Dockerfile.bash3 .

# The entrypoint owns the suite table; `all` runs every suite in one
# container, so adding a suite touches the entrypoint only.
test-docker: docker-build ## Run all tests in Docker
	@echo "Running all tests in Docker..."
	@docker run --rm -e CI=true $(DOCKER_IMAGE) all

test-docker-filter-process: docker-build ## Run filter.process roundtrip verification in Docker
	@docker run --rm $(DOCKER_IMAGE) filterprocess

test-docker-bash3: docker-build-bash3 ## Run tests under genuine bash 3.2.57 (bash-version compatibility)
	@echo "Running tests under genuine bash 3.2.57..."
	@docker run --rm -e CI=true $(DOCKER_IMAGE_BASH3) unit install gitops worktree

test-docker-unit: docker-build ## Run unit tests in Docker
	@docker run --rm $(DOCKER_IMAGE) unit

test-docker-install: docker-build ## Run install/uninstall tests in Docker
	@docker run --rm $(DOCKER_IMAGE) install

test-docker-gitops: docker-build ## Run git operations tests in Docker
	@docker run --rm $(DOCKER_IMAGE) gitops

test-docker-worktree: docker-build ## Run linked worktree tests in Docker
	@docker run --rm -e CI=true $(DOCKER_IMAGE) worktree

test-docker-precommit: docker-build ## Run pre-commit tests in Docker
	@docker run --rm $(DOCKER_IMAGE) precommit

#------------------------------------------------------------------------------
# Coverage (opt-in diagnostic; NOT a CI gate)
#------------------------------------------------------------------------------

COVERAGE_DIR := coverage

coverage: docker-build ## Run the unit suite under kcov and write coverage/index.html
	@echo "Running unit suite under kcov..."
	@mkdir -p $(COVERAGE_DIR)
	@docker run --rm -v "$$PWD/$(COVERAGE_DIR):/out" $(DOCKER_IMAGE) coverage
	@echo "Coverage report: $(COVERAGE_DIR)/index.html"

#------------------------------------------------------------------------------
# Quality
#------------------------------------------------------------------------------

check-bash: ## Verify bash is available
	@command -v bash >/dev/null 2>&1 || { echo "Error: bash is required"; exit 1; }
	@echo "Bash version: $$(bash --version | head -1)"

lint: ## Check scripts for common issues (requires shellcheck)
	@test ! -f $(SRC_HOOKS)/local-override-resolver.sh \
		|| { echo "ERROR: hooks/local-override-resolver.sh must not exist; $(RESOLVER) is the only copy (installers place the runtime copy)"; exit 1; }
	@command -v shellcheck >/dev/null 2>&1 || { echo "Warning: shellcheck not installed, skipping lint"; exit 0; }
	@echo "Linting scripts..."
	@shellcheck -S warning -s bash $(LINT_FILES)
	@echo "Lint complete."

fmt: ## Format shell scripts (requires shfmt)
	@command -v shfmt >/dev/null 2>&1 || { echo "Warning: shfmt not installed, skipping format"; exit 0; }
	@echo "Formatting scripts..."
	@shfmt -i 4 -w $(CLI_TOOL) $(HOOK_SCRIPTS) $(INSTALL_SCRIPT) $(UNINSTALL_SCRIPT)
	@echo "Format complete."

fmt-check: ## Check shell script formatting (requires shfmt)
	@command -v shfmt >/dev/null 2>&1 || { echo "Warning: shfmt not installed, skipping format check"; exit 0; }
	@echo "Checking format..."
	@shfmt -i 4 -d $(CLI_TOOL) $(HOOK_SCRIPTS) $(INSTALL_SCRIPT) $(UNINSTALL_SCRIPT)
	@echo "Format check complete."

check-docs-sync: ## Verify doc version pins and CLI command coverage match the code
	@$(SRC_TESTS)/check-docs-sync.sh

# NOTE: fmt-check is not part of `ci` yet — the tree predates shfmt and is not
# formatted under any shfmt flag combination (see plan 005); adding the gate
# requires a maintainer decision (mass-reformat vs. dropping the gate).
ci: lint check-docs-sync test-docker test-docker-bash3 ## Run the full CI-equivalent suite (requires Docker)

#------------------------------------------------------------------------------
# Help
#------------------------------------------------------------------------------

help: ## Show this help message
	@echo "git-local-override - Manage local file overrides for tracked git files"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make install          # Install globally"
	@echo "  make test             # Run tests locally"
	@echo "  make test-docker      # Run all tests in Docker"
	@echo "  make test-docker-bash3 # Test bash 3.2 compatibility"
	@echo "  make lint             # Check for issues"
	@echo "  make uninstall        # Remove installation"
