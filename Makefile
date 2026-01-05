# git-local-override Makefile
#
# Usage:
#   make install    - Install globally
#   make uninstall  - Remove global installation
#   make test       - Run test suite
#   make clean      - Clean test artifacts
#   make help       - Show this help

.PHONY: install uninstall test clean help check-bash lint

# Default target
.DEFAULT_GOAL := help

# Installation directories
PREFIX ?= $(HOME)/.local
CONFIG_DIR ?= $(HOME)/.config/git
BIN_DIR := $(PREFIX)/bin
HOOKS_DIR := $(CONFIG_DIR)/hooks
OVERRIDES_DIR := $(CONFIG_DIR)/local-overrides

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
	@echo "Test artifacts cleaned."

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
	@mkdir -p $(HOOKS_DIR)
	@mkdir -p $(OVERRIDES_DIR)

	@echo "Installing CLI tool..."
	@cp $(CLI_TOOL) $(BIN_DIR)/
	@chmod +x $(BIN_DIR)/git-local-override

	@echo "Installing hook scripts..."
	@cp $(HOOK_SCRIPTS) $(HOOKS_DIR)/
	@chmod +x $(HOOKS_DIR)/local-override-*

	@echo "Creating default allowlist..."
	@if [ ! -f $(OVERRIDES_DIR)/allowlist ]; then \
		echo "# Global allowlist for git local-override" > $(OVERRIDES_DIR)/allowlist; \
		echo "**/AGENTS.md" >> $(OVERRIDES_DIR)/allowlist; \
		echo "**/CLAUDE.md" >> $(OVERRIDES_DIR)/allowlist; \
		echo "CLAUDE.md" >> $(OVERRIDES_DIR)/allowlist; \
	fi

	@echo ""
	@echo "Installation complete!"
	@echo ""
	@echo "Make sure $(BIN_DIR) is in your PATH:"
	@echo '  export PATH="$$HOME/.local/bin:$$PATH"'

uninstall-manual: ## Uninstall manually
	@echo "Removing CLI tool..."
	@rm -f $(BIN_DIR)/git-local-override

	@echo "Removing hook scripts..."
	@rm -f $(HOOKS_DIR)/local-override-*

	@echo ""
	@echo "Uninstallation complete."
	@echo "Note: Allowlist and registry files preserved in $(OVERRIDES_DIR)"

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
	@echo "  make install      # Install globally"
	@echo "  make test         # Run tests"
	@echo "  make lint         # Check for issues"
	@echo "  make uninstall    # Remove installation"
