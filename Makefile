# git-local-override Makefile
#
# Usage:
#   make install    - Install globally
#   make uninstall  - Remove global installation
#   make test       - Run test suite
#   make clean      - Clean test artifacts
#   make help       - Show this help

.PHONY: install uninstall test clean help check-bash lint \
       test-docker test-docker-bash3 test-docker-unit test-docker-install \
       test-docker-gitops test-docker-precommit docker-build docker-build-bash3

# Default target
.DEFAULT_GOAL := help

# Installation directories
PREFIX ?= $(HOME)/.local
CONFIG_DIR ?= $(HOME)/.config/git
BIN_DIR := $(PREFIX)/bin
TEMPLATE_HOOKS_DIR := $(CONFIG_DIR)/template/hooks

# Source directories
SRC_BIN := bin
SRC_HOOKS := hooks
SRC_SCRIPTS := scripts
SRC_TESTS := tests

# Source files
CLI_TOOL := $(SRC_BIN)/git-local-override
HOOK_SCRIPTS := $(wildcard $(SRC_HOOKS)/local-override-*)
INSTALL_SCRIPT := $(SRC_SCRIPTS)/install.sh
UNINSTALL_SCRIPT := $(SRC_SCRIPTS)/uninstall.sh

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

test-docker: docker-build ## Run all tests in Docker
	@echo "Running all tests in Docker..."
	@docker run --rm $(DOCKER_IMAGE) all

test-docker-bash3: docker-build-bash3 ## Run tests with bash 3.2 (macOS compatibility)
	@echo "Running tests with bash 3.2..."
	@docker run --rm $(DOCKER_IMAGE_BASH3) unit install gitops

test-docker-unit: docker-build ## Run unit tests in Docker
	@docker run --rm $(DOCKER_IMAGE) unit

test-docker-install: docker-build ## Run install/uninstall tests in Docker
	@docker run --rm $(DOCKER_IMAGE) install

test-docker-gitops: docker-build ## Run git operations tests in Docker
	@docker run --rm $(DOCKER_IMAGE) gitops

test-docker-precommit: docker-build ## Run pre-commit tests in Docker
	@docker run --rm $(DOCKER_IMAGE) precommit

#------------------------------------------------------------------------------
# Quality
#------------------------------------------------------------------------------

check-bash: ## Verify bash is available
	@command -v bash >/dev/null 2>&1 || { echo "Error: bash is required"; exit 1; }
	@echo "Bash version: $$(bash --version | head -1)"

lint: ## Check scripts for common issues (requires shellcheck)
	@command -v shellcheck >/dev/null 2>&1 || { echo "Warning: shellcheck not installed, skipping lint"; exit 0; }
	@echo "Linting scripts..."
	@shellcheck -s bash $(CLI_TOOL) $(HOOK_SCRIPTS) $(INSTALL_SCRIPT) $(UNINSTALL_SCRIPT) || true
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

#------------------------------------------------------------------------------
# Manual Installation (alternative to install script)
#------------------------------------------------------------------------------

install-manual: check-bash ## Install manually without running install script
	@echo "Creating directories..."
	@mkdir -p $(BIN_DIR)
	@mkdir -p $(TEMPLATE_HOOKS_DIR)

	@echo "Installing CLI tool..."
	@cp $(CLI_TOOL) $(BIN_DIR)/
	@chmod +x $(BIN_DIR)/git-local-override

	@echo "Installing hook scripts to git template directory..."
	@cp $(HOOK_SCRIPTS) $(TEMPLATE_HOOKS_DIR)/
	@cp $(SRC_HOOKS)/local-override-lib.sh $(TEMPLATE_HOOKS_DIR)/
	@chmod +x $(TEMPLATE_HOOKS_DIR)/local-override-*

	@echo "Configuring git template directory..."
	@git config --global init.templateDir $(CONFIG_DIR)/template

	@echo ""
	@echo "Installation complete!"
	@echo ""
	@echo "Make sure $(BIN_DIR) is in your PATH:"
	@echo '  export PATH="$$HOME/.local/bin:$$PATH"'
	@echo ""
	@echo "New repos will have hooks automatically. For existing repos, run:"
	@echo "  ./scripts/install.sh --repo"

uninstall-manual: ## Uninstall manually
	@echo "Removing CLI tool..."
	@rm -f $(BIN_DIR)/git-local-override

	@echo "Removing hook scripts from git template..."
	@rm -f $(TEMPLATE_HOOKS_DIR)/local-override-*

	@echo ""
	@echo "Uninstallation complete."
	@echo "Note: You may want to unset init.templateDir:"
	@echo "  git config --global --unset init.templateDir"

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
