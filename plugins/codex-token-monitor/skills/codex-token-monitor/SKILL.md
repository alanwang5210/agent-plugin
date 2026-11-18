---
name: codex-token-monitor
description: Use when the user asks to start, show, stop, restart, configure, or inspect the live Codex token usage monitor for local desktop or CLI sessions.
---

# Codex Token Monitor

Control the local companion with the scripts in this plugin's `scripts` directory. Resolve the plugin root as two directories above this `SKILL.md` file.

## Actions

- Start: run `TokenMonitor.Control.ps1 -Action Start`.
- Bring the existing window forward: run `TokenMonitor.Control.ps1 -Action Show`.
- Stop: run `TokenMonitor.Control.ps1 -Action Stop`.
- Restart: run `TokenMonitor.Control.ps1 -Action Restart`.
- Process status: run `TokenMonitor.Control.ps1 -Action Status`.
- Current exact usage without opening a window: run `CodexTokenMonitor.ps1 -Headless`.
- Enable or disable Windows login startup only when the user explicitly asks, using `EnableAutostart` or `DisableAutostart`.

Use Windows PowerShell with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script-path> -Action <action>
```

## Platform, Privacy And Accuracy

This companion supports Windows only. On other operating systems, explain the limitation and do not run the scripts.

The companion reads local Codex rollout JSONL files. It displays task titles and current or historical user questions to identify rounds. It does not display model responses, tool-call payloads, credentials, or rate-limit details. Report values as Codex-provided usage, not estimates.

`last_token_usage` is the most recent model response. `total_token_usage` is cumulative processing for the selected session. The companion calculates the current turn from the latest `user_message` through subsequent cumulative token snapshots, so tool-loop model calls are included once and duplicate snapshots are ignored. It displays the indexed task name (falling back to the first user question), round number, and current user question without persisting those texts. Context percentage is the last input token count divided by the model context window.

The `History` button rebuilds up to the 100 most recent turn summaries from the complete local rollout. Historical summaries include the user question, token breakdown, model-call count, completion state, and elapsed time; they are not persisted in a separate database.

The companion follows the task selected in the Codex sidebar through Windows UI Automation. UI Automation and token snapshot parsing run in separate hidden watcher processes so the WinForms UI thread remains responsive. The user can clear `Follow Codex selection` to pin the currently displayed task. UI Automation exposes the selected task title but not its thread id, so duplicate task titles resolve to the most recently updated matching local session.
