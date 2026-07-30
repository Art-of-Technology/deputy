---
name: dashboard
description: Open the Deputy fleet dashboard in Windows Terminal. Use when the user asks to open, show, or watch the dashboard, or wants to watch the posse work. Invocable as /dashboard.
---

# Deputy fleet dashboard

Open the live fleet view by running, from the repo root:

```powershell
pwsh -NoProfile -File bin/dep-dashboard.ps1
```

If the user names a specific task, pass its id:

```powershell
pwsh -NoProfile -File bin/dep-dashboard.ps1 -Id <taskId>
```

Optional parameters: `-Id <taskId>` (open one task, active or archived) and `-Tail <n>` (log tail length).

## What to expect (relay this to the user)

- It opens (or reuses) a Windows Terminal window named `deputy` with an auto-refreshing fleet-status tab plus one live-tail tab per active posse member.
- It is a read-only viewing surface; it does not change any task state.
- Re-running it after new spawns adds tabs for the new members to the same window.
- If `wt.exe` (Windows Terminal) is not on PATH, the script throws with install instructions (Microsoft Store or `winget install Microsoft.WindowsTerminal`).
