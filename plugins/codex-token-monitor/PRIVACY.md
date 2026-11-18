# Privacy Policy

Effective date: July 29, 2026

Codex Token Monitor is a local Windows companion for Codex. This policy describes the data the plugin accesses and how it is handled.

## Data Accessed

The plugin reads local files under the active Codex data directory, normally `%USERPROFILE%\.codex`:

- `sessions\**\rollout-*.jsonl` for token-count events, task state, timestamps, and user questions
- `session_index.jsonl` for task identifiers and task titles

The Windows selection watcher uses Microsoft UI Automation to inspect the local ChatGPT desktop app window. It reads the title of the selected Codex sidebar task. It does not interact with other applications.

## Data Displayed

The companion can display:

- Codex task titles and abbreviated session identifiers
- Current and historical user questions
- Token counts, context-window usage, call counts, timestamps, duration, and turn status

## Data Storage

The plugin does not create a separate history database. Historical data is rebuilt from Codex's existing local session files.

While running, the plugin uses `%LOCALAPPDATA%\CodexTokenMonitor` for process coordination. The selected task title is temporarily written to `selected-task.txt`. A temporary usage snapshot contains the active session path, task title, current user question, and token metrics so parsing can run outside the UI process. These files are removed on normal exit. Process and snapshot state files may remain after an abnormal termination and are replaced or cleaned during later runs.

If the user explicitly enables login startup, the plugin writes one command under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`. Login startup is disabled by default and can be removed with `DisableAutostart` or the uninstall script.

## Network And Telemetry

The companion code does not create network connections, transmit session content, collect analytics, or send telemetry. Codex and the ChatGPT desktop app operate independently under their own terms and privacy policies.

## Retention And Deletion

The plugin's history is retained only as long as Codex retains the corresponding local session files. Stopping or uninstalling the plugin does not delete Codex sessions. The uninstall script removes the plugin registration and optional startup entry but does not remove user conversations.

## Security Reports

Report privacy or security concerns through the repository's GitHub Security Advisory feature. Do not include session files, prompts, credentials, or other sensitive data in a public issue.

## Changes

Material privacy changes will be documented in the repository and release notes.
