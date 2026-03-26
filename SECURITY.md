# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.3.x   | :white_check_mark: |
| 0.2.x   | :white_check_mark: |
| 0.1.x   | :white_check_mark: |
| 0.0.x   | :x:                |

## Reporting a Vulnerability

We take security seriously. If you discover a security vulnerability in git-local-override, please report it responsibly.

### How to Report

1. **Do NOT open a public GitHub issue** for security vulnerabilities
2. **Email**: Send details to the repository owner via GitHub's private vulnerability reporting feature, or contact [@jonathanabila](https://github.com/jonathanabila) directly
3. **Include**:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

### What to Expect

- **Acknowledgment**: Within 48 hours of your report
- **Status Update**: Within 7 days with our assessment
- **Resolution**: We aim to resolve critical issues within 30 days

### Scope

Security issues we're interested in:

- **Code execution vulnerabilities** in hook scripts
- **Path traversal** issues that could affect files outside the repository
- **Privilege escalation** through the install scripts
- **Injection vulnerabilities** in command handling

### Out of Scope

- Issues requiring physical access to the machine
- Social engineering attacks
- Denial of service attacks
- Issues in dependencies (report to upstream)

### Safe Harbor

We support safe harbor for security researchers who:

- Make a good faith effort to avoid privacy violations and data destruction
- Only interact with accounts you own or with explicit permission
- Do not exploit a vulnerability beyond what's necessary to demonstrate it
- Report vulnerabilities promptly

We will not pursue legal action against researchers who follow these guidelines.

## Security Best Practices for Users

### Current Trust Model

- `git-local-override` discovers `.local-overrides.yaml` recursively, not just at the repository root.
- The nearest config owns its subtree, so a nested config can change override behavior for files under that directory.
- Config `override:` and `replaces:` paths are resolved relative to the config file they appear in.
- Current behavior includes nested config files discovered from git's tracked and untracked file sets. Treat both committed and local `.local-overrides.yaml` files as authoritative inputs when evaluating repository behavior.

### Current Path-Boundary Limitations

- Config validation rejects lexical path escapes such as absolute paths and `..` traversal outside the owning subtree.
- Runtime file operations do not currently resolve symlinks before reading or writing managed targets and override files.
- Do not treat `git-local-override` as a symlink boundary. If a managed target or override path is a symlink, repository-local path validation alone is not a guarantee that runtime reads or writes stay inside the repository.

### Best Practices for Users

1. **Review all `.local-overrides.yaml` files**, not just the root one, before using the tool in a repository.
2. **Avoid using symlinked managed targets or symlinked override files** when repository-boundary guarantees matter.
3. **Inspect local override files** before creating them in untrusted repositories.
4. **Keep git-local-override updated** to receive security fixes.
5. **Use version pinning** when installing via curl to ensure reproducible installs:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/v0.3.0/scripts/install.sh | bash
   ```
