# Deputy

Talk to one deputy. Ship with a posse.

Deputy turns a single Claude Code session into a supervisor for a fleet of isolated, headless coding agents on **Windows**. You (the Sheriff) talk to one agent (the Deputy); it dispatches tasks to posse members that each run in their own [treehouse](https://github.com/kunchenguid/treehouse) git worktree, supervises them through a zero-token watcher, and brings you back finished pull requests or investigation reports.

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

- Windows with PowerShell 7+
- git, and [GitHub CLI](https://cli.github.com/) authenticated (`gh auth login`)
- [treehouse](https://github.com/kunchenguid/treehouse) on PATH
- [Claude Code](https://claude.com/claude-code) on PATH

## Quickstart

```powershell
cd C:\apps\deputy
claude   # this directory's CLAUDE.md makes the session your Deputy
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
| `dep-spawn.ps1 -Task <text> -Repo <path> [-Kind ship\|scout] [-Model <m>] [-PermissionMode <mode>] [-AllowedTools <rules>]` | Lease a worktree, launch a headless posse member, register task state |
| `dep-watch.ps1 [-Wait] [-IntervalSeconds n] [-StallMinutes n] [-TimeoutMinutes n]` | Scan tasks for wake events; `-Wait` blocks until one fires (exit 0) or timeout (exit 2) |
| `dep-posse.ps1 status` | Fleet table: status, liveness, age, PR |
| `dep-posse.ps1 logs <taskId> [-Tail n] [-Raw]` | Human-readable log tail (or raw stream-json) |
| `dep-posse.ps1 result <taskId>` | Final report text, scout report path, PR URL |
| `dep-posse.ps1 kill <taskId>` | Stop a runaway member's process tree (lease kept for inspection) |
| `dep-validate.ps1 <taskId>` | Run the no-mistakes gate in the task's worktree; commits evidence on pass |
| `dep-publish.ps1 <taskId>` | Push the branch and open the PR; refuses unless validation passed |
| `dep-pr.ps1 <view\|checks\|diff\|merge> <taskId> [-Method squash\|merge\|rebase]` | PR operations via gh (merge defaults to squash + delete branch) |
| `dep-return.ps1 <taskId>` | Kill stragglers, return the lease (guarded by `--if-lease-id`), archive state |

## Delivery modes (no-mistakes gate)

Per-repo delivery is configured in `config\projects.json`:

```json
{
  "default": { "delivery": "direct-pr", "validate": [] },
  "projects": [
    {
      "match": "myapp",
      "delivery": "no-mistakes",
      "validate": ["npm test", "npm run lint"]
    }
  ]
}
```

`match` is a repo folder name, or a full path if it contains a slash. Unmatched repos use `default`. The shipped file contains a worked example - replace it with your own repos.

- **direct-pr**: the posse member pushes and opens the PR itself (needs `gh` access).
- **no-mistakes**: the member's job ends at "implement, test, commit locally". On completion the Deputy runs `dep-validate.ps1` in the worktree - a deterministic gate whose commands come from Deputy's own config, never from the repo being validated. On green, the evidence (commands, exit codes, output, validated commit sha) is committed to the branch, PR-viewable at `.deputy/evidence/<taskId>.md`, and `dep-publish.ps1` pushes and opens the PR. On red, the failure is recorded in task state and the Deputy respawns the member with the failure output in its briefing.

The security property of no-mistakes: the agent that wrote the code never holds the pen on validation or publishing. Members need no `gh` or push access at all, and a branch cannot rubber-stamp its own gate.

## Permissions for posse members

Headless members cannot answer permission prompts: anything not pre-approved stalls the task on its first gated action. Two ways to run them:

1. **`bypassPermissions`** (the config default): members run fully unattended. Simple, and appropriate for repos and machines you trust - which is the usual posture for an autonomous fleet.
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
bin\        toolbelt (dep-spawn, dep-watch, dep-posse, dep-validate, dep-publish, dep-pr, dep-return, dep-lib)
config\     deputy.json, projects.json
state\      one json per task, wake-queue.jsonl, scout reports, validation records, archive\   (runtime)
logs\       <taskId>.jsonl stream logs + stderr                                                (runtime)
CLAUDE.md   the Deputy's operating contract
```

## Credits

Concept and task model from [firstmate](https://github.com/kunchenguid/firstmate) by kunchenguid; worktree pooling by [treehouse](https://github.com/kunchenguid/treehouse). MIT-licensed inspirations, reimagined for Windows.
