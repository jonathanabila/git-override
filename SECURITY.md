# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.0.x   | :white_check_mark: |

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

1. **Review the config file** (`.local-overrides.yaml`) before using in a repository - it's controlled by the repo maintainer
2. **Inspect local override files** before creating them in untrusted repositories
3. **Keep git-local-override updated** to receive security fixes
4. **Use version pinning** when installing via curl to ensure reproducible installs:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/jonathanabila/git-override/v0.0.3/scripts/install.sh | bash
   ```
