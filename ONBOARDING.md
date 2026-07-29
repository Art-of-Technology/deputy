# Deputy - first 10 minutes

Deputy lets you talk to one agent (the Deputy) that dispatches coding tasks to a fleet of isolated agents (the posse) and brings you back validated pull requests. This guide gets you from zero to your first delivered PR.

## 1. Install the prerequisites (one time)

Everything runs natively on Windows. You need:

1. **PowerShell 7+** - check with `pwsh --version`; install via `winget install Microsoft.PowerShell` if missing.
2. **git** - `winget install Git.Git` if missing.
3. **GitHub CLI, authenticated** - `winget install GitHub.cli`, then `gh auth login` (choose HTTPS; make sure the account has push access to the repos you'll work on).
4. **treehouse** (worktree pool manager) - PowerShell installer from https://github.com/kunchenguid/treehouse. Verify with `treehouse --version`.
5. **Claude Code** - https://claude.com/claude-code. Verify with `claude --version`.

## 2. Get Deputy

```powershell
git clone https://github.com/Art-of-Technology/deputy C:\apps\deputy
cd C:\apps\deputy
```

The clone is the whole install - no build step. Your clone is also your instance: task state and logs live inside it, private to you.

## 3. Launch your Deputy

```powershell
cd C:\apps\deputy
claude
```

That's it. The `CLAUDE.md` in this directory turns the session into your Deputy. You are the Sheriff.

## 4. Give it work

Talk naturally. Include the repo path the first time; parallel requests are encouraged:

> Fix the flaky login test in C:\src\myapp, and separately investigate why the nightly export job is slow.

The Deputy will:
- dispatch each task to its own posse member, in its own isolated git worktree (your checkout of the repo is never touched),
- go quiet while they work - a watcher wakes it only when something needs a decision,
- for code tasks: run the repo's tests as a validation gate it controls, commit the evidence, and open a PR,
- for investigations: bring you back a written report,
- ask **you** before merging anything.

## 5. What to expect

- **Delivered PRs** carry a validation evidence file at `.deputy/evidence/<taskId>.md` - proof of what was run and that it passed, pinned to the validated commit.
- **Validation is automatic**: the gate detects `npm test`/`lint`, `cargo test`, `go test`, `dotnet test`, or `pytest` from the repo's default branch. To pin exact commands or opt a repo out, edit `config\projects.json` (see README).
- **Failures are normal output**: if a member gets stuck or its work fails the gate, the Deputy diagnoses, retries with better instructions, or escalates to you with its analysis.
- **Security posture**: posse members run unattended (`bypassPermissions` by default) inside their worktrees. Point Deputy at repos you trust, on a machine you trust. For least privilege, see "Permissions for posse members" in the README.

## 6. Useful commands while work is in flight

Ask the Deputy in plain language ("what's the posse doing?"), or run directly:

```powershell
pwsh -NoProfile -File bin\dep-posse.ps1 status        # fleet table
pwsh -NoProfile -File bin\dep-posse.ps1 logs <taskId> # readable live log
```

## Troubleshooting

- **Member stalls immediately** - almost always permissions: headless agents cannot answer prompts. Keep the default permission mode, or grant tools explicitly (README, Permissions section).
- **`gh` errors about token scopes** - `gh pr view` needs `read:org`; re-auth with `gh auth login` or add the scope to your PAT.
- **Worktree stuck as leased** - `treehouse status` (run inside the repo) to inspect; `pwsh -NoProfile -File bin\dep-return.ps1 <taskId>` releases it safely.

## Updating

```powershell
cd C:\apps\deputy
git pull
```
