# Deputy

Talk to one deputy. Ship with a posse.

Deputy turns a single Claude Code session into a supervisor for a fleet of isolated, headless coding agents on **Windows**. You (the Sheriff) talk to one agent (the Deputy); it dispatches tasks to posse members that each run in their own [treehouse](https://github.com/kunchenguid/treehouse) git worktree, supervises them through a zero-token watcher, and brings you back finished pull requests or investigation reports.

Deputy is a native PowerShell reimagining of [firstmate](https://github.com/kunchenguid/firstmate). Where firstmate supervises interactive agents through tmux panes, Deputy runs posse members headless (`claude -p --output-format stream-json`) and supervises them through structured event logs - no terminal multiplexer required.

## How it works

```
Sheriff (you)
   |
   v
Deputy ......... interactive Claude Code session launched in this directory
   |  dep-spawn.ps1
   v
posse member ... headless claude -p, own treehouse worktree, own branch
posse member ... (as many in parallel as you like)
   |
   v
dep-watch.ps1 .. polls stream-json logs + process liveness; wakes the
                 Deputy only on: completed / failed / died / stalled
```

- **Ship tasks** implement, test, and commit; how the PR happens depends on the repo's delivery mode (below).
- **Scout tasks** investigate and write a markdown report; they change nothing.
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
# dispatch
pwsh -NoProfile -File bin\dep-spawn.ps1 -Task "Fix the flaky auth test" -Repo C:\src\myapp
pwsh -NoProfile -File bin\dep-spawn.ps1 -Task "Why is startup slow?" -Repo C:\src\myapp -Kind scout

# supervise (blocks until something needs you)
pwsh -NoProfile -File bin\dep-watch.ps1 -Wait

# inspect
pwsh -NoProfile -File bin\dep-posse.ps1 status
pwsh -NoProfile -File bin\dep-posse.ps1 logs posse-20260729-104800-abc
pwsh -NoProfile -File bin\dep-posse.ps1 result posse-20260729-104800-abc

# deliver
pwsh -NoProfile -File bin\dep-pr.ps1 checks posse-20260729-104800-abc
pwsh -NoProfile -File bin\dep-pr.ps1 merge posse-20260729-104800-abc

# tear down
pwsh -NoProfile -File bin\dep-return.ps1 posse-20260729-104800-abc
```

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

`match` is a repo folder name, or a full path if it contains a slash. Unmatched repos use `default`.

- **direct-pr**: the posse member pushes and opens the PR itself (needs `gh` access).
- **no-mistakes**: the member's job ends at "implement, test, commit locally". On completion the Deputy runs `dep-validate.ps1` in the worktree - a deterministic gate whose commands come from Deputy's own config, never from the repo being validated. On green, the evidence is committed to the branch (PR-viewable at `.deputy/evidence/<taskId>.md`) and `dep-publish.ps1` pushes and opens the PR. On red, the failure is recorded in task state and the Deputy respawns the member with the failure output in its briefing.

The security property of no-mistakes: the agent that wrote the code never holds the pen on validation or publishing. Members need no `gh` or push access at all (`-AllowedTools "Bash(git *),Bash(npm *)"` suffices), and a branch cannot rubber-stamp its own gate.

## Configuration

`config\deputy.json`:

| Key | Default | Meaning |
| --- | --- | --- |
| `model` | `null` | Model for posse members (`null` = account default) |
| `permissionMode` | `bypassPermissions` | Permission mode for headless members. They cannot answer prompts, so anything stricter will stall on the first gated action. For a stricter setup, use `acceptEdits` plus explicit grants: `dep-spawn.ps1 ... -PermissionMode acceptEdits -AllowedTools 'Bash(git *)','Bash(gh *)','Bash(npm *)'`. Note the target repo's own `.claude/settings.json` allowlist does not help: leased worktrees are untrusted directories, so project settings are not honored there |
| `watchIntervalSeconds` | `15` | Watcher poll interval |
| `stallMinutes` | `10` | Minutes without log activity before a stalled wake |
| `branchPrefix` | `deputy/` | Branch name prefix for ship tasks |

Security note: `bypassPermissions` means posse members run shell commands unattended in their worktree. Treat it like any autonomous agent setup - point Deputy only at repos you trust, on a machine you trust.

## Layout

```
bin\        toolbelt (dep-spawn, dep-watch, dep-posse, dep-validate, dep-publish, dep-pr, dep-return, dep-lib)
config\     deputy.json, projects.json
state\      one json per task, wake-queue.jsonl, scout reports, archive\   (runtime)
logs\       <taskId>.jsonl stream logs + stderr                            (runtime)
CLAUDE.md   the Deputy's operating contract
```

## Credits

Concept and task model from [firstmate](https://github.com/kunchenguid/firstmate) by kunchenguid; worktree pooling by [treehouse](https://github.com/kunchenguid/treehouse). MIT-licensed inspirations, reimagined for Windows.
