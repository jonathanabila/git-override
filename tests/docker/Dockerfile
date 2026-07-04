# Dockerfile for git-local-override integration tests
#
# This provides an isolated environment for testing:
# - Install/uninstall scripts
# - Real git operations (commit, checkout, branch switching)
# - Pre-commit framework integration
#
FROM ubuntu:22.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies. fd-find installs the binary as `fdfind`; symlink it to
# `fd` on PATH so the resolver's fd discovery strategy (and the fd-strategy leg
# of the worktree tests) is exercised here.
RUN apt-get update && apt-get install -y \
    bash \
    git \
    curl \
    fd-find \
    python3 \
    python3-pip \
    && ln -s "$(command -v fdfind)" /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir pre-commit

# Configure git for testing
RUN git config --global user.email "test@example.com" \
    && git config --global user.name "Test User" \
    && git config --global init.defaultBranch main

# Create a non-root user for realistic testing
RUN useradd -m -s /bin/bash testuser
USER testuser
WORKDIR /home/testuser

# Copy project files
COPY --chown=testuser:testuser . /home/testuser/project

WORKDIR /home/testuser/project

# Rebuild the copied source as a standalone git repo so Docker runs from
# either a normal clone or a host worktree use a portable hook source.
RUN rm -rf .git \
    && git init -q \
    && git config user.email "test@example.com" \
    && git config user.name "Test User" \
    && git add . \
    && git commit -q -m "Test source snapshot"

# Set up PATH for CLI tool testing
ENV PATH="/home/testuser/.local/bin:${PATH}"

# Entry point runs the test suite
ENTRYPOINT ["./tests/docker/entrypoint.sh"]
CMD ["all"]
