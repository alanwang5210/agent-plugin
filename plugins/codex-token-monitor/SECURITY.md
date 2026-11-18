# Security Policy

## Supported Versions

Security fixes are applied to the latest beta release on the `main` branch.

## Reporting A Vulnerability

Use GitHub's private security advisory flow for `alanwang5210/codex-token-monitor`.

Do not open a public issue containing:

- Codex rollout or session files
- User prompts or model responses
- Credentials, tokens, cookies, or environment variables
- Screenshots containing private task names or questions

Provide a minimal reproduction with synthetic data. Include the Windows version, ChatGPT desktop app version, Codex CLI version, plugin version, and the affected script.

## Security Boundaries

- The companion reads local Codex data and writes only its local state directory unless login startup is explicitly enabled.
- The selection watcher limits UI Automation queries to the ChatGPT desktop app process.
- The companion contains no network or telemetry implementation.
- Installer and uninstaller scripts invoke the local `codex` CLI and should be reviewed before execution.
