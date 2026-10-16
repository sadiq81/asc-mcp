# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 3.1.x   | Yes       |
| 3.0.x   | Security fixes only |
| < 3.0   | No        |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do NOT open a public issue**
2. Email: **fullback.94@gmail.com**
3. Include: description, reproduction steps, and impact assessment
4. You will receive a response within 48 hours

## Security Best Practices for Users

- **Never commit `.p8` private keys** to version control
- Use environment variables or a `companies.json` file outside your repo
- Add `companies.json`, `*.p8`, `*.pem`, `*.key` to your `.gitignore`
- Rotate App Store Connect API keys periodically
- Use `--workers` flag to limit exposed tools to only what you need
- JWT tokens are held in memory only and expire after 20 minutes
- Prefer read-only MCP smoke checks (`auth_generate_token`, `auth_token_status`, `apps_list limit=1`) after reloads
- Review tool annotations before approving high-risk actions such as submit, release, delete, revoke, clear, or cancel

## Hardening in this fork

- **Upload file guard.** Upload tools refuse hidden paths (`~/.ssh`, `~/.aws`, `.env`, …) and key, certificate and keychain files (`.p8`, `.pem`, `.key`, `.p12`, `.cer`, `.der`, `.keychain`, `.mobileprovision`). Symlinks are resolved before the check. To restrict uploads further, set `ASC_MCP_UPLOAD_DIRS` to one or more absolute folders separated by `:`.
- **Apple-only API host.** `defaultURL` in `companies.json` must be `https://api.appstoreconnect.apple.com`, so a tampered config cannot send signed tokens elsewhere.
- **Stricter `--read-only`.** A tool whose name contains a write verb (`create`, `delete`, `submit`, …) is blocked even if it also contains `_get` or `_list`.
- **Key permission warning.** A warning is printed to stderr when a `.p8` file is readable by other users. Fix it with `chmod 600`.
