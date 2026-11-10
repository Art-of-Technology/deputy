# Deputy - first 10 minutes

Deputy lets you talk to one agent (the Deputy) that dispatches coding tasks to a posse of isolated agents and brings you back validated pull requests. This guide gets you from zero to your first delivered PR.

## 1. Install the prerequisites (one time)

Everything runs natively on Windows. You need:

1. **PowerShell 7+** - check with `pwsh --version`; install via `winget install Microsoft.PowerShell` if missing.
2. **git** - `winget install Git.Git` if missing.
3. **GitHub CLI, authenticated** - `winget install GitHub.cli`, then `gh auth login` (choose HTTPS; make sure the account has push access to the repos you'll work on).
4. **treehouse 3.0.1 or later** (worktree pool manager) - `irm https://kunchenguid.github.io/treehouse/install.ps1 | iex` (from https://github.com/kunchenguid/treehouse). Verify with `treehouse --version`.
5. **Claude Code** - https://claude.com/claude-code. Verify with `claude --version`.

Minimum versions: PowerShell 7 and treehouse 3.0.1. Older treehouse releases can mislist the processes in a worktree on Windows, so Deputy refuses to lease from them. If you already have treehouse, run `treehouse update` with no tasks leased and check it landed on the latest release - an update must go straight to the latest, never to 3.0.0, which is below the minimum.

## 2. Get Deputy

```powershell
git clone https://github.com/Art-of-Technology/deputy C:\apps\deputy
cd C:\apps\deputy
```

The clone is the whole install - no build step. Your clone is also your instance: task state and logs live inside it, private to you.

Now check the toolchain. The doctor prints one line per problem, each with the exact command that fixes it, and nothing at all when everything is in order:

```powershell
pwsh -NoProfile -File bin\dep-doctor.ps1
```

Your Deputy runs the same check at the start of every session and tells you about anything it finds.

## 3. Launch your Deputy

```powershell
cd C:\apps\deputy
claude
```

That's it. The operating contract in this directory (`AGENTS.md`, loaded via `CLAUDE.md`) turns the session into your Deputy. You are the Sheriff.

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
- **A gate with nothing to run is not a pass**: if your repo has no detectable test command, the Deputy reports the work as *unverified* and refuses to publish until you pin commands in `config\projects.json` or explicitly approve publishing unvalidated work.
- **Failures are normal output**: if a member gets stuck or its work fails the gate, the Deputy diagnoses, retries with better instructions, or escalates to you with its analysis.
- **Security posture**: posse members run unattended (`bypassPermissions` by default) inside their worktrees. Point Deputy at repos you trust, on a machine you trust. For least privilege, see "Permissions for posse members" in the README.

## 6. Useful commands while work is in flight

Ask the Deputy in plain language ("what's the posse doing?"), or run directly:

```powershell
pwsh -NoProfile -File bin\dep-posse.ps1 status        # posse table
pwsh -NoProfile -File bin\dep-posse.ps1 logs <taskId> # readable live log
```

## Troubleshooting

- **Member stalls immediately** - almost always permissions: headless agents cannot answer prompts. Keep the default permission mode, or grant tools explicitly (README, Permissions section).
- **`gh` errors about token scopes** - `gh pr view` needs `read:org`; re-auth with `gh auth login` or add the scope to your PAT.
- **Spawn refuses with "Refusing to lease a worktree"** - treehouse is older than 3.0.1 or its version cannot be read. Run `pwsh -NoProfile -File bin\dep-doctor.ps1` and apply the fix it names (`treehouse update`, with no tasks leased, straight to the latest release - never to 3.0.0).
- **Worktree stuck as leased** - `treehouse status` (run inside the repo) to inspect; `pwsh -NoProfile -File bin\dep-return.ps1 <taskId>` releases it safely.

## Updating

```powershell
cd C:\apps\deputy
git pull
```

Then re-run `pwsh -NoProfile -File bin\dep-doctor.ps1`. It also tells you when your clone has fallen behind `origin` (it only reports - it never pulls for you).
