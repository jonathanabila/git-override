# typed: false
# frozen_string_literal: true

# DRAFT — UNPUBLISHED. Do not point a tap at this file as-is.
#
# This is a design-spike draft produced by plan 023 (see
# plans/023-homebrew-design.md). It has NOT been published to a Homebrew tap and
# the sha256 below is a placeholder. Before this can ship, a maintainer must:
#   1. Decide to own a tap (jonathanabila/homebrew-tap) — ongoing per-release cost.
#   2. Resolve the repo-name/URL discrepancy (see the design doc): the GitHub
#      remote is `jonathanabila/git-override` (NOT `git-local-override`, which is
#      only the local checkout directory name). The `url` below is drafted against
#      the real remote `git-override`. Confirm before first release.
#   3. Compute the real sha256 for the v0.6.0 source tarball.
#
# Install model (validated without brew via a temp libexec+wrapper layout — see
# the design doc "Install layout" section): the FULL tree (CLI + shared resolver
# + VERSION + hooks) is installed under `libexec`, PRESERVING the `bin/ <-> shared/`
# sibling relationship the runtime relies on. The user-facing `bin` entry is a
# generated exec wrapper (`bin.write_exec_script`), NOT a symlink — a symlink
# breaks support-file resolution because the CLI computes SCRIPT_DIR without
# dereferencing symlinks (documented pitfall in the design doc).
class GitLocalOverride < Formula
  desc "Maintain local, uncommitted modifications to git-tracked files via git hooks"
  homepage "https://github.com/jonathanabila/git-override"
  # NOTE: repo name is `git-override` (the GitHub remote), not `git-local-override`.
  url "https://github.com/jonathanabila/git-override/archive/refs/tags/v0.6.0.tar.gz"
  version "0.6.0"
  # PLACEHOLDER — compute at real release time with:
  #   curl -fsSL <url> | shasum -a 256
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on "bash"

  def install
    # Install the full support tree under libexec, preserving the bin/ <-> shared/
    # sibling layout. The CLI resolves `$SCRIPT_DIR/../shared/local-override-resolver.sh`
    # and `$SCRIPT_DIR/../VERSION`, so these MUST remain siblings of bin/.
    libexec.install "bin/git-local-override"
    libexec.install "shared"
    libexec.install "VERSION"
    libexec.install "hooks"

    # Ensure the CLI keeps `libexec/bin/git-local-override` as its real path so
    # SCRIPT_DIR resolves to `libexec/bin` at runtime.
    (libexec/"bin").mkpath
    mv libexec/"git-local-override", libexec/"bin/git-local-override"

    # Generate an EXEC WRAPPER in HOMEBREW_PREFIX/bin (NOT a symlink). The wrapper
    # execs the real script so BASH_SOURCE[0] points inside libexec/bin and the
    # sibling shared/ + VERSION resolve correctly. A `bin.install_symlink` here
    # would set SCRIPT_DIR to HOMEBREW_PREFIX/bin and break resolution.
    bin.write_exec_script libexec/"bin/git-local-override"
  end

  def caveats
    <<~EOS
      git-local-override installs the CLI and hook scripts only. It does NOT modify
      your global git config on install (unlike the curl installer, which sets
      `git config --global init.templateDir`).

      There is no `git-local-override install` subcommand; wire the hooks yourself:

        # Per repository (recommended): wire the filter driver in the current repo
        cd your/repo && git-local-override sync-filters

        # Global (new clones/inits): opt in to git's template dir explicitly
        mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/git/template/hooks"
        cp #{libexec}/hooks/local-override-* \\
           "${XDG_CONFIG_HOME:-$HOME/.config}/git/template/hooks/"
        git config --global init.templateDir \\
           "${XDG_CONFIG_HOME:-$HOME/.config}/git/template"

      Keeping the global-config mutation as an explicit user step is deliberate: a
      formula must not silently change your git configuration on `brew install`.
      See the project README for details.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/git-local-override version")
    assert_match version.to_s, shell_output("#{bin}/git-local-override --version")
  end
end
