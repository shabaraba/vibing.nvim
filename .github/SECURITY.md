# Security Policy

## Supported Versions

We actively support the following versions of vibing.nvim:

| Version | Supported          |
| ------- | ------------------ |
| 1.x.x   | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a Vulnerability

If you discover a security vulnerability in vibing.nvim, please report it responsibly:

### Preferred Method: GitHub Security Advisories

1. Go to the [Security tab](https://github.com/shabaraba/vibing.nvim/security)
2. Click "Report a vulnerability"
3. Fill in the details of the vulnerability
4. Submit the report

### Alternative: Private Issue

If you cannot use Security Advisories, please:

1. Open a private issue or discussion
2. Include "SECURITY" in the title
3. Provide detailed information about the vulnerability

### What to Include

Please provide:

- Description of the vulnerability
- Steps to reproduce the issue
- Potential impact
- Suggested fix (if you have one)
- Your contact information (optional)

### What NOT to Do

- **Do not** open public issues for security vulnerabilities
- **Do not** disclose the vulnerability publicly until it has been addressed
- **Do not** exploit the vulnerability beyond verifying its existence

## Response Timeline

- **Initial Response**: Within 48 hours of report
- **Status Update**: Within 7 days
- **Fix Timeline**: Depends on severity
  - Critical: Within 7 days
  - High: Within 14 days
  - Medium: Within 30 days
  - Low: Next release cycle

## Security Best Practices for Users

### API Key Security

- **Never commit** your `ANTHROPIC_API_KEY` to version control
- Use environment variables or secure credential management
- Rotate API keys regularly
- Use separate API keys for development and production

### Configuration Security

- Review your vibing.nvim configuration for sensitive data
- Be cautious with `permissions.allow` settings
- Limit tool permissions to what you actually need
- Regularly audit allowed tools and commands

### Keep Updated

- Use the latest stable version of vibing.nvim
- Monitor for security updates
- Update dependencies regularly (`npm update`)
- Run `npm audit` to check for vulnerabilities

### Neovim Security

- Keep Neovim updated to the latest stable version
- Be careful with untrusted Lua code
- Review plugin configurations before use
- Use `--listen` socket with caution in multi-user environments

## Security Features in vibing.nvim

- **Permission System**: Control which tools Claude can use
- **Tool Allowlist/Denylist**: Fine-grained permission control
- **Session Isolation**: Chat sessions are isolated
- **No Persistent Storage of API Keys**: Keys must be provided via environment

## Disclosure Policy

When a security vulnerability is confirmed:

1. We will work on a fix privately
2. A security advisory will be published
3. A patched version will be released
4. Credit will be given to the reporter (unless anonymity is requested)
5. The vulnerability will be disclosed after users have had time to update

## Security Hall of Fame

We appreciate security researchers who help keep vibing.nvim secure. Responsible disclosures will be acknowledged here (with permission).

---

Thank you for helping keep vibing.nvim and its users safe!
