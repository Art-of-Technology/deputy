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

Your own settings are private too. Put them in `config\deputy.local.json` (models, budget, permission mode, ...) and `config\projects.local.json` (the gate commands, delivery mode or model of the repos you work on). Both are gitignored and win over the tracked `config\deputy.json` and `config\projects.json`, which you leave as they are on `main` - so `git pull` never conflicts with your pins. Create a local file only when you need it, with only the keys you want to change; the README's "Configuration" section has the details.

**Which model the posse runs on** is set in the config, never by whatever model your own Claude Code session happens to be on. The tracked `config\deputy.json` pins one model per kind of task (`models.ship`, `models.scout`), so every member runs on a model somebody chose. To run your members on another model, pin it in `config\deputy.local.json` - only the kind you name changes:

```json
{ "models": { "scout": "claude-sonnet-5-5" } }
```

or for one repo only, in `config\projects.local.json`:

```json
{ "projects": [ { "match": "myapp", "model": "claude-sonnet-5-5" } ] }
```

The Deputy names the model in every spawn it confirms, `dep-posse.ps1 status` shows it per task, and a member that reports running on a different model than the one it was given is flagged (`MODEL MISMATCH`) - usually a typo in the model name.

Now check the toolchain. The doctor prints one line per problem, each with the exact command that fixes it, and nothing at all when everything is in order:

```powershell
pwsh -NoProfile -File bin\dep-doctor.ps1
```

Your Deputy gets the same check at the start of every session - a session hook runs it, together with a report of the posse and of anything that finished while no session was open - and tells you about anything it finds.

## 3. Launch your Deputy

```powershell
cd C:\apps\deputy
claude
```

That's it. The operating contract in this directory (`AGENTS.md`, loaded via `CLAUDE.md`) turns the session into your Deputy. You are the Sheriff.

## 4. Give it work

Talk naturally. Include the repo path the first time; parallel requests are encouraged:

> Fix the flaky login test in C:\src\myapp, and separately investigate why the nightly export job is slow.

Work lands on the repo's default branch unless you say otherwise. To work on another branch, name it ("backport the fix onto release/2.4 in C:\src\myapp"): the member's worktree is cut from it, the gate checks against it and the PR targets it.

The Deputy will:
- dispatch each task to its own posse member, in its own isolated git worktree (your checkout of the repo is never touched),
- go quiet while they work - a watcher wakes it only when something needs a decision,
- for code tasks: run the repo's tests as a validation gate it controls, commit the evidence, and open a PR,
- for investigations: bring you back a written report,
- ask **you** before merging anything.

## 5. What to expect

- **Delivered PRs** carry a validation evidence file at `.deputy/evidence/<taskId>.md` - proof of what was run and that it passed, pinned to the validated commit.
- **Validation is automatic**: the gate detects `npm test`/`lint`, `cargo test`, `go test`, `dotnet test`, or `pytest` from the repo's default branch. To pin exact commands or opt a repo out, add the repo to your `config\projects.local.json` (see README, "Delivery modes").
- **A gate with nothing to run is not a pass**: if your repo has no detectable test command, the Deputy reports the work as *unverified* and refuses to publish until you pin commands in `config\projects.local.json` or explicitly approve publishing unvalidated work.
- **Merging and tearing down are guarded**: the Deputy merges only a PR that is open, conflict-free, green at its current commit and unchanged since it was published, and tells you every reason when it will not. It returns a worktree only after proving the work landed (pushed, or merged); throwing unlanded work away takes your explicit word.
- **Open PRs are watched**: after a PR is opened the Deputy is told when it is merged (it then tears the task down) and when a check on it turns red (it then tells you).
- **Failures are normal output**: if a member gets stuck or its work fails the gate, the Deputy diagnoses, retries with better instructions, or escalates to you with its analysis.
- **Security posture**: posse members run unattended (`bypassPermissions` by default) inside their worktrees. Point Deputy at repos you trust, on a machine you trust. For least privilege, see "Permissions for posse members" in the README.

## 6. Useful commands while work is in flight

Ask the Deputy in plain language ("what's the posse doing?"), or run directly:

```powershell
pwsh -NoProfile -File bin\dep-posse.ps1 status        # posse table
pwsh -NoProfile -File bin\dep-posse.ps1 logs <taskId> # readable live log
```

## Troubleshooting

- **Member reports it was denied permission** - headless agents cannot answer prompts, so outside `bypassPermissions` anything not granted is denied and the member reports it (usually as `blocked`). Keep the default permission mode, or grant the tools it needs with `-AllowedTools` (README, "Permissions for posse members").
- **`gh` errors about token scopes** - `gh pr view` needs `read:org`; re-auth with `gh auth login` or add the scope to your PAT.
- **Spawn refuses with "Refusing to launch a member"** - the worktree treehouse leased was not a worktree of its own (or not on the task's new branch), so nothing was started in it and the lease was given back. The line after it says what was wrong; `treehouse status` (run inside the repo) shows the pool.
- **Spawn refuses with "Refusing to lease a worktree"** - treehouse is older than 3.0.1, its version cannot be read, or its `get` lacks a flag Deputy needs. Run `pwsh -NoProfile -File bin\dep-doctor.ps1` and apply the fix it names (`treehouse update`, with no tasks leased, straight to the latest release - never to 3.0.0).
- **Spawn warns about the old flat "model"/"effort" keys** - your `config\deputy.local.json` (or `config\deputy.json`, if you changed it) still has `"model": "..."` or `"effort": "..."` as a single value. It is still read, as the value for every kind, for one more release. Move it to `"models": { "ship": "...", "scout": "..." }` and `"effort": { "ship": ..., "scout": ... }`.
- **A wake or the status says `MODEL MISMATCH`** - the member reports running on another model than it was started with. Check the model name in `-Model`, your project entry or `models` in the config; an alias (`opus`) is reported as the full model id, which shows up here too.
- **Worktree stuck as leased** - `treehouse status` (run inside the repo) to inspect; `pwsh -NoProfile -File bin\dep-return.ps1 <taskId>` releases it safely: it refuses, and says why, if the task's work has not landed anywhere (add `-Discard` only when you mean to throw that work away).

## Updating

```powershell
cd C:\apps\deputy
git pull
```

Then re-run `pwsh -NoProfile -File bin\dep-doctor.ps1`. It also tells you when your clone has fallen behind `origin` (it only reports - it never pulls for you).
