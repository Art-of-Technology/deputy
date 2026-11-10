# Deputy

Talk to one deputy. Ship with a posse.

Deputy turns a single Claude Code session into a supervisor for a posse of isolated, headless coding agents on **Windows**. You (the Sheriff) talk to one agent (the Deputy); it dispatches tasks to posse members that each run in their own [treehouse](https://github.com/kunchenguid/treehouse) git worktree, supervises them through a zero-token watcher, and brings you back finished pull requests or investigation reports.

Deputy is a native PowerShell reimagining of [firstmate](https://github.com/kunchenguid/firstmate). Where firstmate supervises interactive agents through tmux panes, Deputy runs posse members headless (`claude -p --output-format stream-json`) and supervises them through structured event logs - no terminal multiplexer required.

## How it works

```
Sheriff (you)
   |
   v
Deputy ............ interactive Claude Code session launched in this directory
   |  dep-spawn.ps1 (leases a treehouse worktree, launches headless claude)
   v
posse member ...... own worktree, own branch; as many in parallel as you like
posse member ......   ship: implement + test + commit    scout: investigate
   |
   v
dep-watch.ps1 ..... polls stream-json logs + process liveness; wakes the
   |                Deputy only on: completed / failed / died / stalled
   v
delivery .......... direct-pr:   member already pushed and opened the PR
                    no-mistakes: dep-validate.ps1 gates the branch, then
                                 dep-publish.ps1 pushes and opens the PR
   |
   v
dep-return.ps1 .... worktree back to the pool, task state archived
```

- **Ship tasks** implement, test, and commit; how the PR happens depends on the repo's delivery mode (below).
- **Scout tasks** investigate and write a markdown report to `state\<taskId>-report.md`; they change nothing.
- **Isolation** comes from treehouse's worktree pool: leases are durable (survive crashes and reboots), guarded against races (`--if-lease-id`), and worktrees are recycled between tasks.

## Prerequisites

- Windows with PowerShell 7 or later
- git, and [GitHub CLI](https://cli.github.com/) authenticated (`gh auth login`)
- [treehouse](https://github.com/kunchenguid/treehouse) **3.0.1 or later** on PATH, with `treehouse get --lease`
- [Claude Code](https://claude.com/claude-code) on PATH

Check all of it in one go - silent means healthy, otherwise one line per problem with the exact fix:

```powershell
pwsh -NoProfile -File bin\dep-doctor.ps1
```

**Updating treehouse.** Older treehouse releases can mislist the processes in a worktree on Windows, which is why there is a floor and why `dep-spawn.ps1` refuses to lease below it. Update with `treehouse update`, with no tasks leased, and make sure it lands on the latest release: an update must go straight there, never to 3.0.0, which is below the floor. Confirm with `treehouse --version` and re-run the doctor.

## Quickstart

```powershell
cd C:\apps\deputy
claude   # AGENTS.md (loaded via CLAUDE.md) makes the session your Deputy
```

Then just talk: "Fix the flaky auth test in C:\src\myapp and add dark mode to the settings page." The Deputy spawns two posse members, watches them, and returns with two PRs.

You can also drive the toolbelt directly:

```powershell
# dispatch (taskId like posse-20260729-114756-thv is printed on spawn)
pwsh -NoProfile -File bin\dep-spawn.ps1 -Task "Fix the flaky auth test" -Repo C:\src\myapp
pwsh -NoProfile -File bin\dep-spawn.ps1 -Task "Why is startup slow?" -Repo C:\src\myapp -Kind scout

# supervise (blocks until something needs you)
pwsh -NoProfile -File bin\dep-watch.ps1 -Wait

# inspect
pwsh -NoProfile -File bin\dep-posse.ps1 status
pwsh -NoProfile -File bin\dep-posse.ps1 logs <taskId>
pwsh -NoProfile -File bin\dep-posse.ps1 result <taskId>

# deliver (no-mistakes repos: gate, then publish)
pwsh -NoProfile -File bin\dep-validate.ps1 <taskId>
pwsh -NoProfile -File bin\dep-publish.ps1 <taskId>

# deliver (all repos: review and merge)
pwsh -NoProfile -File bin\dep-pr.ps1 checks <taskId>
pwsh -NoProfile -File bin\dep-pr.ps1 diff <taskId>
pwsh -NoProfile -File bin\dep-pr.ps1 merge <taskId>

# tear down
pwsh -NoProfile -File bin\dep-return.ps1 <taskId>
```

## Command reference

| Command | What it does |
| --- | --- |
| `dep-doctor.ps1` | Toolchain check: PowerShell 7+, `git` / `gh` / `claude` / `treehouse` on PATH, `gh auth status`, treehouse at least 3.0.1 with `get --lease`, and the Deputy clone on its default branch and not behind `origin`. One line per problem, each naming its fix; prints nothing when healthy. Exit 0 healthy, 1 on any problem. Report only - it never installs, updates or pulls |
| `dep-spawn.ps1 -Task <text> -Repo <path> [-Kind ship\|scout] [-Model <m>] [-PermissionMode <mode>] [-AllowedTools <rules>]` | Lease a worktree, launch a headless posse member, register task state. Refuses to lease when treehouse fails the doctor's version check |
| `dep-watch.ps1 [-Wait] [-IntervalSeconds n] [-StallMinutes n] [-DeadSeconds n] [-TimeoutMinutes n]` | Scan tasks for wake events; `-Wait` blocks until one fires (exit 0) or timeout (exit 2). A task counts as completed (or failed) only when its final `result` event has arrived AND the member process has exited - a `result` seen while the process is alive is interim (the member may be waiting on background helpers) and wakes nobody. A task counts as died only when no process remains AND its log has been silent past `-DeadSeconds` (default 90) |
| `dep-posse.ps1 status [-Watch]` | Posse table: status, liveness, age, PR; `-Watch` auto-refreshes with recent wakes |
| `dep-posse.ps1 logs <taskId> [-Tail n] [-Raw] [-Follow]` | Human-readable log tail (or raw stream-json); `-Follow` live-tails |
| `dep-posse.ps1 result <taskId>` | Final report text, scout report path, PR URL |
| `dep-posse.ps1 kill <taskId>` | Stop a runaway member's process tree (lease kept for inspection). Kills only processes proven to be the task's - see "What Deputy will kill" |
| `dep-validate.ps1 <taskId>` | Run the no-mistakes gate in the task's worktree; commits evidence on pass. Exit 0 passed, 1 failed, 2 unverified (no commands to run) |
| `dep-publish.ps1 <taskId> [-AllowUnverified]` | Push the branch and open the PR; refuses a failed or unverified gate. `-AllowUnverified` is the Sheriff's opt-in for repos with no gate, and labels the PR as never validated |
| `dep-pr.ps1 <view\|checks\|diff\|merge> <taskId> [-Method squash\|merge\|rebase]` | PR operations via gh (merge defaults to squash; branch cleanup happens in dep-return) |
| `dep-return.ps1 <taskId>` | Kill stragglers (same proof as `kill`), return the lease (guarded by `--if-lease-id`), delete the task branch, archive state |
| `dep-dashboard.ps1 [-Id <taskId>] [-Tail n]` | Live posse view in Windows Terminal: auto-refreshing status tab + a live-tail tab per active member. Re-running adds new members' tabs to the same window; `-Id` opens one task (active or archived) |

Inside a Deputy session, the `/dashboard` skill (`.claude\skills\dashboard`) opens the same posse view on request.

## What Deputy will kill

`dep-posse.ps1 kill` and `dep-return.ps1` force-kill process trees, so a pid is treated as a claim to check, not an instruction. The candidates are the member pid recorded at spawn and whatever treehouse lists in the task's worktree; treehouse's listing says where to look, and is never by itself a licence to kill. A candidate is killed only when both of these hold:

- **It can be read.** Its executable path or its command line is readable. A process Deputy cannot inspect is left alone.
- **It can be placed.** Either it sits in the process tree under the recorded member pid - checked hop by hop against pid recycling, with the member pid itself required to carry the recorded start time - or its working directory, which Deputy reads from the process itself, is inside the task worktree.

On top of that, pid 0 and pid 4 are never candidates, a worktree listing of more than 50 processes is discarded whole as a mislisting (with a warning), and the calling process and its ancestors are never killed. Anything that fails the proof is left running and named in a `left pid N running` warning, so it is visible rather than silently skipped.

## Delivery modes (no-mistakes gate)

**No-mistakes is the default for every repo** - Deputy works on repos it has never seen, so the gate cannot depend on a hand-maintained list. The flow:

1. The member's job ends at "implement, test, commit locally" (it never pushes or opens PRs).
2. On completion the Deputy runs `dep-validate.ps1` in the worktree - a deterministic gate the member has no control over.
3. On green, the evidence (commands, exit codes, output, validated commit sha, gate source) is committed to the branch, PR-viewable at `.deputy/evidence/<taskId>.md`, and `dep-publish.ps1` pushes and opens the PR.
4. On red, the failure is recorded in task state and the Deputy respawns the member with the failure output in its briefing.

Captured command output in the evidence is redacted on a best-effort basis (common `key=value` secrets, connection-string credentials, well-known token shapes) before it is written anywhere. Redaction is pattern-based and cannot catch everything - test suites should not print secrets.

**Gate commands are auto-detected** unless configured. Detection reads manifests with `git show` from the repo's default branch - never from the task branch or the worktree's files, so a branch cannot reconfigure its own gate:

| Found on default branch | Gate command |
| --- | --- |
| `package.json` with `test` / `lint` scripts | `npm test` / `npm run lint` (pnpm/yarn by lockfile) |
| `Cargo.toml` | `cargo test` |
| `go.mod` | `go test ./...` |
| `*.sln` / `*.csproj` | `dotnet test` |
| `pytest.ini` or `[tool.pytest]` in `pyproject.toml` | `pytest` |

The default branch is resolved as `origin/HEAD`, then `origin/main` / `origin/master`, then - for a repo with no remote configured - the local `main` / `master`. Every candidate must actually exist: a stale `origin/HEAD` left by a default branch that was renamed or deleted upstream falls through to the next candidate. Never the checked-out branch, which inside a posse worktree is the task branch. A repo with no remote and an unconventional default branch name resolves to nothing at all; pin its commands in `config\projects.json`.

**A bad anchor is loud, whatever the gate.** The anchor decides which ref manifests are read from and what "ahead of the default branch" means, so every run records its provenance in the evidence (`- default-branch anchor: ...`) - including runs whose commands were pinned rather than detected. A stale or unresolvable anchor additionally prints `ANCHOR WARNING` in the gate output, is kept as `anchorWarning` in task state, and shows up in `dep-posse.ps1 result`. It does not fail the branch: it is the repo that needs fixing (`git remote set-head origin -a`), and only the Sheriff can do that. An anchor that resolved normally stays out of the gate's output.

The gate's *command list* is Deputy-controlled; the test code those commands execute lives on the task branch, and is reviewed on the PR like any other change.

**An empty gate is not a pass.** If nothing is configured and nothing is detected, `dep-validate.ps1` records `validation=unverified`, exits 2, and says so loudly - a gate that gates nothing must not read as green. `dep-publish.ps1` refuses an unverified task the same way it refuses a failed one. Two ways forward:

1. Pin the repo's gate commands in `config\projects.json` and re-run `dep-validate.ps1` - fixes the repo for good.
2. `dep-publish.ps1 <taskId> -AllowUnverified` - the Sheriff's explicit opt-in for a repo with genuinely nothing to run. The PR body then states in plain text that no tests and no lint were executed against the branch, and the task records `publishedUnverified`.

`config\projects.json` overrides detection per repo - pin exact commands, or opt a repo out to `direct-pr` (the member pushes and opens the PR itself; needs `gh` access):

```json
{
  "default": { "delivery": "no-mistakes", "validate": [] },
  "projects": [
    { "match": "myapp", "delivery": "no-mistakes", "validate": ["npm run test:ci"] },
    { "match": "legacy-app", "delivery": "direct-pr", "validate": [] }
  ]
}
```

`match` is a repo folder name, or a full path if it contains a slash. An empty `validate` list means auto-detect.

The security property of no-mistakes: the agent that wrote the code never holds the pen on validation or publishing. Members need no `gh` or push access at all, and a branch cannot rubber-stamp its own gate.

**Whose text the PR title is.** `dep-publish.ps1` derives the title from the branch's one member commit subject when there is exactly one of them (Deputy's own evidence commit never counts), and from the Sheriff's briefing otherwise. That is a trust boundary worth naming rather than leaving implicit: on a single-commit branch, the title of a pull request on your organisation's repository is text a headless posse member wrote, where it used to be the Sheriff's own words. What that text can do is deliberately bounded to being a headline:

- **The title only.** The base and head branches, the briefing quoted in the body, the gate verdict and the evidence are the Deputy's or the Sheriff's. A member still never pushes and never holds a `gh` credential.
- **Sanitised before use.** Terminal escape sequences are stripped, along with control characters and invisible format characters such as bidi overrides - a title is read in the Deputy's and the Sheriff's terminals, where an escape sequence can recolour or overwrite what they see and a bidi override can make text read as something other than what it says. Whitespace is then collapsed and the result is cut to 80 characters on a word boundary. A subject with nothing left after that falls back to the briefing.
- **Plain text on GitHub**, which renders no markup in a PR title.
- **Only on a green gate**, since publishing refuses a failed or unverified task.

So the title is a summary the branch proposed for itself, not a claim Deputy vouches for. It is worth a glance when you review the PR; the diff and the evidence are what actually attest to the work.

## Permissions for posse members

Headless members cannot answer permission prompts: anything not pre-approved stalls the task on its first gated action. Two ways to run them:

1. **`bypassPermissions`** (the config default): members run fully unattended. Simple, and appropriate for repos and machines you trust - which is the usual posture for an autonomous posse.
2. **`acceptEdits` + explicit grants**: least privilege, recommended for no-mistakes repos since members need so little:

   ```powershell
   pwsh -NoProfile -File bin\dep-spawn.ps1 ... -PermissionMode acceptEdits -AllowedTools "Bash(git *),Bash(npm *)"
   ```

   Pass `-AllowedTools` as a single comma-joined string when invoking via `pwsh -File` (it does not parse array literals). Scout members automatically get `--add-dir` access to `state\` for their report.

Two traps worth knowing:

- The target repo's own `.claude/settings.json` allowlist does **not** apply: leased worktrees are untrusted directories, so project settings are not honored there. Grants must come from the spawner (`-AllowedTools`) or your user-level settings.
- `bypassPermissions` means members run shell commands unattended in their worktree. Point Deputy only at repos you trust, on a machine you trust.

## Configuration

`config\deputy.json`:

| Key | Default | Meaning |
| --- | --- | --- |
| `model` | `null` | Model for posse members (`null` = account default) |
| `permissionMode` | `bypassPermissions` | Default permission mode for headless members (see Permissions above) |
| `watchIntervalSeconds` | `15` | Watcher poll interval |
| `stallMinutes` | `10` | Minutes without log activity before a stalled wake |
| `branchPrefix` | `deputy/` | Branch name prefix for ship tasks |

## Layout

```
bin\        toolbelt (dep-doctor, dep-spawn, dep-watch, dep-posse, dep-validate, dep-publish, dep-pr, dep-return, dep-dashboard, dep-lib)
config\     deputy.json, projects.json
tools\      Deputy's own gate: Invoke-Lint.ps1, Invoke-Tests.ps1, plus the module pins (gate-modules.psd1) and Install-GateModules.ps1
tests\      Pester suite for the toolbelt
.github\    workflows\ci.yml runs the gate on pull requests and pushes to main
state\      one json per task, wake-queue.jsonl, scout reports, validation records, archive\   (runtime)
logs\       <taskId>.jsonl stream logs + stderr                                                (runtime)
AGENTS.md   the Deputy's operating contract (harness-neutral)
CLAUDE.md   loads AGENTS.md into Claude Code sessions
ONBOARDING.md   first 10 minutes for new users
PSScriptAnalyzerSettings.psd1   lint gate settings
```

## Working on Deputy itself

Deputy gates its own repo with the same mechanism it applies to everything else: `config\projects.json` pins `match: deputy` to the two commands below, so a posse member working on Deputy is validated rather than waved through.

```powershell
pwsh -NoProfile -File tools\Invoke-Lint.ps1    # PSScriptAnalyzer over bin\, tools\, tests\ (exit 1 on any finding)
pwsh -NoProfile -File tools\Invoke-Tests.ps1   # Pester suite in tests\ (-Filter dep-lib to narrow)
```

Both run on exact module versions pinned in `tools\gate-modules.psd1`, and refuse to run on any other version so that a result never depends on whose machine produced it. Install them once (and again after a pin changes):

```powershell
pwsh -NoProfile -File tools\Install-GateModules.ps1
```

The tests build throwaway git repos and throwaway Deputy installs under `$env:TEMP` - no network, and they never touch the real `state\` or `logs\`. They need only `git` and `pwsh`: no treehouse, no claude, and no signed-in `gh`.

### CI

`.github\workflows\ci.yml` runs the same two commands on `windows-latest` for every pull request and every push to `main`, so a PR is checked however it was opened - not only when Deputy's own gate shipped it. The job installs the pinned modules with `tools\Install-GateModules.ps1` (cached, keyed on the pin file), fails on a non-zero exit from either command, runs with read-only `contents` permission, and cancels a run that a newer push to the same ref has superseded.

## Credits

Concept and task model from [firstmate](https://github.com/kunchenguid/firstmate) by kunchenguid; worktree pooling by [treehouse](https://github.com/kunchenguid/treehouse). MIT-licensed inspirations, reimagined for Windows.
