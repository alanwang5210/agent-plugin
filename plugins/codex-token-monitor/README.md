# Codex Token Monitor

This personal-account package contains the locally installed Windows runtime
from version 0.1.0-beta.2. It reads local Codex session events and displays
Codex-reported usage. It does not upload session history or usage data.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1
- A supported local Codex environment with session files on the computer

## Install and use

Open this plugin in the personal section of the Plugins Directory and install
it in a supported desktop environment. Start a new chat with the plugin enabled.
Ask to start, show, stop, or inspect Codex Token Monitor.

The skill uses scripts relative to the installed plugin root. No source checkout
or machine-specific absolute path is required. Windows login startup remains an
explicit opt-in action.

## Account distribution

The package can be retrieved through the same personal account on another
supported Windows computer. It remains desktop-only. Installation does not
transfer old session logs, local usage history, or startup preferences.

This is a saved package snapshot, not an automatic GitHub synchronization.
Subsequent local source changes require a new account release.

The runtime scripts and bundled skill are unchanged from the installed version.
The package adds a portable manifest, explicitly declares its local executor
requirement, and relocates the skill directory to match its declared name.
Repository-specific marketplace and installation helpers are not included.

See [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md), [TERMS.md](TERMS.md),
and [LICENSE](LICENSE). The source repository is
https://github.com/alanwang5210/codex-token-monitor.
