# Deputy

Talk to one deputy. Ship with a posse.

Deputy turns a single Claude Code session into a supervisor for a posse of isolated, headless coding agents on **Windows**. You (the Sheriff) talk to one agent (the Deputy); it dispatches tasks to posse members that each run in their own [treehouse](https://github.com/kunchenguid/treehouse) git worktree, supervises them through a zero-token watcher, and brings you back finished pull requests or investigation reports.

Deputy is a native PowerShell reimagining of [firstmate](https://github.com/kunchenguid/firstmate). Where firstmate supervises interactive agents through tmux panes, Deputy runs posse members headless (`claude -p --output-format stream-json`) and supervises them through structured event logs - no terminal multiplexer required. A member is not one shot: its session can be resumed with a follow-up message, so a question, a correction or an API outage costs one line instead of a restart.

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
dep-watch.ps1 ..... polls stream-json logs + process liveness, and the pull
   |                request of every published task; wakes the Deputy only
   |                on: completed / failed / interrupted / blocked /
   |                needs-decision / died / stalled / merged / degraded / closed.
   |                Started by the session's Stop hook, and every wake is
   |                queued until acknowledged (dep-wake.ps1), so a restart
   |                or an API error loses nothing
   |
   |  dep-send.ps1 (interrupted, blocked, needs-decision: resume the member's
   |                session with a follow-up; it carries on where it was)
   v
delivery .......... direct-pr:   member already pushed and opened the PR
                    no-mistakes: dep-validate.ps1 gates the branch, then
                                 dep-publish.ps1 pushes and opens the PR
   |
   v
dep-pr.ps1 merge .. merges only a PR it has proven fit to merge
   |
   v
dep-return.ps1 .... proves the work landed, then: worktree back to the pool,
                    task state archived
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

# read the wakes nobody has acknowledged yet, then acknowledge the handled ones
pwsh -NoProfile -File bin\dep-wake.ps1 drain
pwsh -NoProfile -File bin\dep-wake.ps1 ack -Through <seq>

# answer a member that asked, or continue one that was cut off (its process must have exited)
pwsh -NoProfile -File bin\dep-send.ps1 <taskId> -Message "Continue where you left off."

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

# tear down (refuses work that has not landed; -Discard overrides, on your word only)
pwsh -NoProfile -File bin\dep-return.ps1 <taskId>
```

## Command reference

| Command | What it does |
| --- | --- |
| `dep-doctor.ps1` | Toolchain check: PowerShell 7+, `git` / `gh` / `claude` / `treehouse` on PATH, `gh auth status`, treehouse at least 3.0.1 with `get --lease`, and the Deputy clone on its default branch and not behind `origin`. One line per problem, each naming its fix; prints nothing when healthy. Exit 0 healthy, 1 on any problem. Report only - it never installs, updates or pulls |
| `dep-spawn.ps1 -Task <text> -Repo <path> [-Kind ship\|scout] [-Model <m>] [-PermissionMode <mode>] [-AllowedTools <rules>] [-Effort low\|medium\|high\|xhigh\|max] [-MaxBudgetUsd <n>]` | Lease a worktree, launch a headless posse member, register task state. The session gets an id Deputy chose (`--session-id`, kept as `sessionId` in task state) and the task id as its name, so it can be resumed. `-Effort` and `-MaxBudgetUsd` become `--effort` and `--max-budget-usd`; both default to the config and are left off when that is `null`. Refuses to lease when treehouse fails the doctor's version check |
| `dep-send.ps1 <taskId> -Message <text>` | Send a follow-up to a member whose process has exited: starts `claude -p --resume <sessionId>` in the task's worktree with the message on stdin and the same flags as the first run, appends to the same log, sets the task back to `running` and records the follow-up in task state. Refuses while the member is alive, when the watcher has not reported the run's outcome yet, and when the worktree is gone (see "Resumable members") |
| `dep-watch.ps1 [-Wait] [-IntervalSeconds n] [-StallMinutes n] [-DeadSeconds n] [-TimeoutMinutes n] [-PrPollSeconds n]` | Scan tasks for wake events, and poll the pull request of every published, unmerged task for `merged`, `degraded` and `closed` (see "Guarded merge, guarded teardown, and PR watching"); `-Wait` blocks until one fires (exit 0) or timeout (exit 2). A task counts as completed (or failed, interrupted, blocked, needs-decision) only when its final `result` event has arrived AND the member process has exited - a `result` seen while the process is alive is interim (the member may be waiting on background helpers) and wakes nobody. What the final result means is in "Resumable members". A task counts as died only when no process remains AND its log has been silent past `-DeadSeconds` (default 90). Every wake is appended to the durable queue with a sequence number before its task record is updated. One watcher at a time: it holds `state\watcher.lock` and touches `state\watcher.beat` on every poll, and a second one says so and exits 0 (see "Wakes that survive") |
| `dep-wake.ps1 drain` | Print every unacknowledged wake, oldest first, with what its task looks like now. The last line is the exact `ack -Through <seq>` command for what was printed. Changes nothing |
| `dep-wake.ps1 ack -Through <seq>` | Remove the wakes at or below `<seq>` from the queue, atomically and under the state lock. Refuses a sequence that was never handed out |
| `dep-session-start.ps1 [-Hook]` | Session-start report: doctor lines, `dep-posse.ps1 status`, watcher health, the drained queue. Always exits 0. Run by the `SessionStart` hook |
| `dep-hook-guard.ps1`, `dep-hook-stop.ps1` | The `Stop` / `StopFailure` hooks. Not for running by hand (see "Wakes that survive") |
| `dep-posse.ps1 status [-Watch]` | Posse table: status, liveness, age, gate, cost, PR; `-Watch` auto-refreshes with recent wakes |
| `dep-posse.ps1 logs <taskId> [-Tail n] [-Raw] [-Follow]` | Human-readable log tail (or raw stream-json), follow-ups shown as `[send]` lines; `-Follow` live-tails |
| `dep-posse.ps1 result <taskId>` | Final report text, the status the member reported, follow-ups sent, cost, scout report path, PR URL |
| `dep-posse.ps1 kill <taskId>` | Stop a runaway member's process tree (lease kept for inspection). Kills only processes proven to be the task's - see "What Deputy will kill" |
| `dep-validate.ps1 <taskId>` | Run the no-mistakes gate in the task's worktree; commits evidence on pass. Exit 0 passed, 1 failed, 2 unverified (no commands to run) |
| `dep-publish.ps1 <taskId> [-AllowUnverified]` | Push the branch and open the PR, recording its number and head commit (`prNumber`, `prHead`); refuses a failed or unverified gate, and a branch that moved after the gate judged it. On a task that already has a PR it pushes the branch's new validated commits to that PR, rewrites the PR description and moves `prHead` on. `-AllowUnverified` is the Sheriff's opt-in for repos with no gate, and labels the PR as never validated |
| `dep-pr.ps1 <view\|checks\|diff\|merge> <taskId> [-Method squash\|merge\|rebase] [-AllowNoChecks]` | PR operations over GitHub's REST API (`gh api`), so no `read:org` token scope is needed. `checks` exits 0 when nothing is failing or pending, 1 on a failing check, 8 when one is only pending. `merge` (squash by default) refuses a PR that is not fit to merge, listing every failing condition, and records the merge only when it is proven; branch cleanup happens in dep-return |
| `dep-return.ps1 <taskId> [-Discard]` | Prove the work landed (refuse with the reason and exit 1 otherwise), then kill stragglers (same proof as `kill`), return the lease (guarded by `--if-lease-id`), delete the task branch, archive state. `-Discard` skips the proof and needs the Sheriff's explicit word. The remote branch of an open PR is never deleted. After this the task can no longer be resumed |
| `dep-dashboard.ps1 [-Id <taskId>] [-Tail n]` | Live posse view in Windows Terminal: auto-refreshing status tab + a live-tail tab per active member. Re-running adds new members' tabs to the same window; `-Id` opens one task (active or archived) |

Inside a Deputy session, the `/dashboard` skill (`.claude\skills\dashboard`) opens the same posse view on request.

## Wakes that survive

A supervisor is only as good as its wake-up. Deputy used to depend on the model remembering to start the watcher after every wake: if it forgot, if the session was restarted, or if a turn ended on an API error, members finished and nobody was told. Three pieces replace "check back and hope":

**A durable queue.** Every wake gets a sequence number that only ever grows (`state\wake-queue.seq`) and is appended to `state\wake-queue.jsonl` before the task's record is updated - so a watcher killed at the worst moment leaves the wake behind, at the price of possibly reporting it twice, never of losing it. A wake stays queued until it is acknowledged. `dep-wake.ps1 drain` prints what is pending and ends with the exact `ack -Through <seq>` command; the ack removes those rows and nothing newer. The loop is: drain, handle, run the printed ack.

**One watcher, with a heartbeat.** A scanning watcher holds `state\watcher.lock` (its pid and process start time, so a recycled pid is never mistaken for it) and touches `state\watcher.beat` on every poll. A second watcher says a live one already holds the lock and exits 0. The lock of a watcher that is gone is reclaimed; one that is alive but stopped polling is replaced. `Test-WatcherHealthy` in `dep-lib.ps1` is the one definition of healthy: process alive and heartbeat fresh.

**Session hooks**, in the tracked `.claude\settings.json`:

| Hook | Script | What it does |
| --- | --- | --- |
| `SessionStart` | `dep-session-start.ps1 -Hook` | Puts the doctor's lines, the posse, the watcher's health and the drained wake queue into the session's context - on startup, resume, `/clear` and compaction |
| `Stop` (synchronous) | `dep-hook-guard.ps1` | If a task is running or stalled and no healthy watcher reports to this session, blocks the stop with a one-line instruction to start the watcher. At most three blocks in a row (`state\hook-guard.blocks`), then it lets the stop through with a warning to you, and stays that way until a watcher is healthy again |
| `Stop` and `StopFailure` (`asyncRewake`) | `dep-hook-stop.ps1` | If tasks are active and nothing healthy is watching for this session, runs the watcher in the hook's own foreground; when a wake arrives it exits 2 with the drained queue on stderr, which Claude Code hands to the idle session as a new turn. Also hands over any queued wake the session was never told about. After a `StopFailure` an already-delivered wake is repeated after a cooldown, at most five times, so an API outage cannot become a storm |

The two `Stop` hooks cooperate: the guard gives the watcher that the other hook is starting a few seconds to report healthy, so normally it blocks nothing and only speaks when the automatic start did not work. Set `"autoWatch": false` in `config\deputy.json` to switch the rewake hook off; the queue, the session-start report and the guard keep working, and the guard then asks the Deputy to start the watcher itself.

**The hooks do nothing in a posse worktree.** The same settings file is loaded by posse members working on Deputy itself, and a member that blocked its own stop or ran a watcher would be a second Deputy. Each hook exits at once, silently and without writing anything, when any of these holds: the session was spawned as a posse member (`dep-spawn.ps1` sets `DEPUTY_POSSE_TASK` in its environment), there is no `state\` beside `bin\`, or `.git` is a file (a linked worktree) rather than a directory (a clone).

**One Deputy session per directory.** A hook-started watcher wakes the session that started it. A watcher left by a session that has ended is replaced by the next session's first stop; two live sessions in one Deputy home would keep taking it from each other.

**What was verified on a real Claude Code** (2.1.322, Windows 11, hooks run in exec form through `pwsh`, no Git Bash involved):

| Behaviour | How it was checked | Result |
| --- | --- | --- |
| `SessionStart` stdout reaches the model | print mode and the interactive TUI | works |
| A synchronous `Stop` hook exiting 2 blocks the stop, stderr reaches the model | print mode | works |
| An `asyncRewake` `Stop` hook exiting 2 wakes an **idle** session | streaming-input session, and the interactive TUI driven through a pseudo console | works |
| The same on `StopFailure` (turn ended on an API error) | streaming-input session with an unusable model | works: the hook fires and its exit 2 starts a new turn |
| The real scripts end to end: stop, hook-started watcher, task finishes, idle session woken with the drain, model runs the printed ack | interactive TUI in a throwaway Deputy home | works |
| Background hook processes end with the session | interactive TUI | they did; the watcher additionally stops when its hook is gone |
| The guard's block, its give-up warning (`systemMessage`) and the `StopFailure` repeat, with the real scripts under a live session | - | not checked live; covered by the Pester suite against the scripts as processes |

In print mode (`claude -p`) Claude Code waits for an `asyncRewake` hook instead of going idle, so a one-shot Deputy is simply held until the wake arrives.

## Resumable members

A member used to be one shot: it could not ask a question, be corrected, or be continued after an outage. The only answer to any of those was a respawn, which starts from nothing and pays a second time for a context that can cost several dollars to build. Three things change that.

**A session Deputy can name.** `dep-spawn.ps1` generates a UUID per task, starts the member with `--session-id <uuid> -n <taskId>` and keeps the id as `sessionId` in task state. `dep-send.ps1 <taskId> -Message <text>` then starts `claude -p --resume <sessionId>` in the same worktree, with the message on stdin and the same flags as the first run - permissions, model, effort, budget and report schema belong to the process, not to the stored session, so a resumed run is given them again. The member carries on with everything it knew. It can be sent to any task whose process has exited and whose worktree is still leased, whatever its status; `dep-return.ps1` ends that.

**A structured final report.** Every member runs with `--json-schema`, so its last message is an object, not prose to be guessed at:

| Field | Meaning |
| --- | --- |
| `status` | `done`, `blocked`, `needs-decision` or `failed` (required) |
| `summary` | What it did and found, or what stopped it (required) |
| `tests` | The commands it ran and their results |
| `question` | What it needs answered, when `blocked` or `needs-decision` |
| `prUrl` | The pull request it opened (`direct-pr` delivery only) |

The watcher reads `structured_output` from the final `result` event and keeps it as `report` in task state; `result` holds the same report as readable text, which is also what `dep-publish.ps1` puts in the PR body. A result without a report that follows the schema is handled as text, as before. A PR URL is still only trusted when it points at the task's own repo, whether it came from the `prUrl` field or from the text; anything else is kept as `prUrlRejected` and shown as rejected.

**Wakes that say what to do next.** The final result decides the wake, and the task's status takes the same name:

| Final result | Wake | Answer |
| --- | --- | --- |
| report `done`, or plain text | `completed` | validate and publish, or read the report |
| report `blocked` | `blocked` | answer the member's question with `dep-send.ps1` |
| report `needs-decision` | `needs-decision` | get the Sheriff's decision, pass it on with `dep-send.ps1` |
| report `failed`, or an error result | `failed` | diagnose; correct it with `dep-send.ps1`, respawn, or escalate |
| error result from a transient server failure: `api_error_status` 429, 500, 502, 503 or 529, or a text naming one of those API errors or `overloaded` | `interrupted` | `dep-send.ps1 <taskId> -Message "Continue where you left off."` once, then escalate |

`interrupted`, `blocked` and `needs-decision` wakes print the member's question, how many follow-ups the task has already been sent, and the `dep-send.ps1` command. They go through the same durable queue as every other wake.

**One log, several runs.** A resumed run appends to the task's log. `dep-send.ps1` first writes a marker line (`{"type":"deputy","subtype":"follow_up",...}`, shown as `[send]` by `dep-posse.ps1 logs`) and records the byte offset after it as `logOffset`; the watcher reads results only from there on, so an earlier run's result is never mistaken for the resumed run's. A resumed run that writes nothing ends as `died`, not as a second `completed`. Each follow-up is kept in task state (`followUps`: number, time, the status it answered, pid, message) and its text in `state\<taskId>-followup-<n>.md`.

**A follow-up reopens the gate.** The member is about to change the branch, so `dep-send.ps1` clears `validation` and its notes; `dep-validate.ps1` has to judge the branch again. That works after publishing too: `dep-publish.ps1` on a task that already has a PR pushes the new validated commits to that same PR (a plain push, never a force), rewrites the PR description with the new summary and verdict, and moves the recorded `prHead` to the new commit. It refuses when the PR is no longer open or cannot be read, and does nothing when the PR is already at the branch's head.

**Cost.** The watcher keeps `total_cost_usd`, `num_turns` and `duration_ms` from each final result as `totalCostUsd`, `numTurns` and `durationMs`, and `dep-posse.ps1 status` shows the cost per task. `--max-budget-usd` caps one run: a member that reaches it ends as `failed` with `Reached maximum budget`, and a resumed run gets the cap afresh.

**What was verified on a real Claude Code** (2.1.322, Windows 11), by hand, in a throwaway git repository with a linked worktree under the temp directory and no remote:

| Behaviour | Result |
| --- | --- |
| `claude -p --session-id <uuid> -n <name>` uses the given id | works: the `init` and `result` events carry it |
| `--json-schema` in print mode | works: the `result` event has `structured_output` as an object, and `result` holds the same JSON as text |
| `claude -p --resume <uuid>` on a print-mode session that had finished and exited | works: same session id, the member recalled a codeword it had only been told in the first run, and it edited the file it had created |
| A second and a third resume of the same session | works |
| Resuming a session whose first run ended on an API error, with "Continue where you left off." | works: the session resumes under the same id. The first run had been cut off before any model output, so there was nothing to continue from but the prompt |
| The shape of a transient API failure (a local endpoint answering 529 to every request) | ten retries over about three minutes, then exit 1 and a `result` with `subtype: success`, `is_error: true`, `api_error_status: 529` and the text `API Error: 529 Overloaded...` |
| The shape of an exhausted budget | exit 1 and a `result` with `subtype: error_max_budget_usd`, `is_error: true`, `result: null` and `errors: ["Reached maximum budget ($...)"]` |
| What `total_cost_usd` counts after a resume | the whole session: a resumed run reported the running total, not its own cost. `num_turns` and `duration_ms` were per run. So Deputy keeps the latest cost and adds up the other two |
| What `--max-budget-usd` counts after a resume | the run: a resume with a cap below what the session had already cost still ran to the end |
| `--resume` with a session id that does not exist | exit 1, `No conversation found with session ID` on stderr, and an `error_during_execution` result: the task ends as `failed` |
| The real scripts end to end against the real CLI (a throwaway Deputy home; `treehouse` replaced by a shim that leased a linked worktree of the throwaway repo): `dep-spawn.ps1`, a `needs-decision` wake carrying the member's question, `dep-send.ps1` with the decision, a `completed` wake | works: both runs carried the session id from task state, the resumed run appended to the same log after the `[send]` marker, committed the file it had created in the first run, and quoted a codeword from the briefing |
| The same against a real treehouse lease | not checked: the hand runs deliberately left the real worktree pool alone |

## Guarded merge, guarded teardown, and PR watching

The two irreversible commands in the toolbelt used to be the two with no checks: `dep-return.ps1` reset the worktree and deleted the remote branch whatever state the work was in, and `dep-pr.ps1 merge` merged whatever state CI was in. Both relied on the supervising model getting the order right every time. They now prove the outcome themselves and refuse otherwise.

**Everything GitHub is read over REST.** `dep-pr.ps1` and the watcher call `gh api repos/{owner}/{repo}/pulls/{n}`, the check-runs and commit-status endpoints of the head commit, and the branch protection endpoint; the merge is a REST call too (`PUT .../pulls/{n}/merge`). gh's own `pr view`, `pr checks` and `pr merge` go through GraphQL queries that need the `read:org` token scope, which a supervisor's token often lacks; the REST endpoints need nothing beyond access to the repository. Owner, repo and number come from the task's recorded `prUrl`.

**`dep-pr.ps1 merge` refuses** unless the pull request is fit to merge. It reads the PR and reports every failing condition, not just the first:

| Condition | Refused when |
| --- | --- |
| State | the PR is not open (a PR that is already merged is recorded and reported, not merged again) |
| Draft | the PR is a draft |
| Conflicts | GitHub reports it not mergeable, or has not finished computing that after a few re-reads |
| Checks | any check run or commit status at the current head commit is failing or still pending (neutral and skipped runs count as successful), or the checks cannot be read |
| No checks | nothing is reported at the head while the base branch's protection requires checks. When the protection cannot be read - GitHub answers 403 or 404 to a token without admin rights on the repository - that is said, and the merge is refused unless `-AllowNoChecks` is passed. The flag never overrides a protection that was read and requires checks |
| Head | the head commit is not the one recorded at publish (`prHead`): somebody pushed to the PR after the gate judged it. A PR the member opened itself (`direct-pr`) has no recorded head, and is held to the HEAD of the task worktree |

The merge call names the head commit it expects (`sha`, the REST form of `gh pr merge --match-head-commit <sha>`), so GitHub refuses it if the head moves in between. Afterwards the PR is read again, and `mergedAt` and `mergeSha` go into task state only when that read shows it merged; otherwise the command prints `MERGE NOT PROVEN`, records nothing and exits 1.

**`dep-return.ps1` refuses** unless the work has landed. The test is one function, `Test-TaskLanded` in `dep-lib.ps1`:

- **Ship tasks.** The worktree is clean, untracked files included, and one of these holds: every commit ahead of the default branch is reachable from a remote-tracking branch after a `git fetch --prune`; or the task's pull request is merged and either its head contains the local HEAD or the local tree is identical to the freshly fetched default branch (a squash merge leaves no commit of the branch behind, only its content). A branch with nothing ahead of the default branch has nothing to lose.
- **Scout tasks.** The report file `state\<taskId>-report.md` exists.

Otherwise it prints `REFUSED`, with the reason, changes nothing and exits 1. `-Discard` overrides the refusal and throws the unlanded work away; it is yours to order, explicitly, for that task. The teardown records what it stood on (`landed`, `landedReason`, and `discarded` when the proof was overridden).

The remote branch is treated separately, because deleting it can destroy work the local proof just relied on: it is never deleted while the task's pull request is open - not with `-Discard` either - or while the PR cannot be read, and it is kept when it is the only place the commits exist (pushed, but not merged anywhere). It is deleted once the PR is merged or the commits are on another remote branch.

**PR watching.** Once a task has a pull request, the watcher reads it every `prPollMinutes` (default 5) until it is merged or the task is returned, and raises three wakes through the same durable queue as all the others:

| Wake | When | What the Deputy does |
| --- | --- | --- |
| `merged` | once, when the PR is seen merged. `mergedAt` and `mergeSha` are recorded. A merge `dep-pr.ps1 merge` made itself is already recorded and raises none | runs `dep-return.ps1` |
| `degraded` | once per head commit, when a check is failing at the PR's head. A PR counts as green from the moment it is published, since the gate passed on that commit, so the first red check is news | tells you |
| `closed` | once, when the PR is seen closed without merging. `prClosedAt` is recorded | tells you, and does not return the worktree without your word: the work has not landed |

A PR that was closed without merging stops counting as something to wait for: it may never change again, so it does not keep the watcher, the `Stop` hooks or a one-shot session waiting. It is still read whenever a watcher is running for another reason (and by `dep-publish.ps1`); when that shows it open again, `prClosedAt` is cleared and it counts as before.

A lookup that fails - no network, gh not signed in, a 404, a 500 - raises nothing and records nothing but the time of the attempt: an unreadable PR is never read as merged. The poll writes only its own fields onto the task record as it is on disk, under the state lock, so it cannot undo what another command recorded while the read was in flight. The same holds the other way round: `dep-pr.ps1 merge`, `dep-publish.ps1`, `dep-validate.ps1` and `dep-return.ps1` all read the record, then spend seconds or minutes on the network or the gate, so they too write only the fields they own (`Update-TaskState` in `dep-lib.ps1`) and never their stale copy of the whole record.

An open pull request counts as work for the watcher: the `Stop` hooks keep one running for it exactly as they do for a running member, and `dep-watch.ps1 -Wait` goes home only when no task is active and no published PR is waiting. In print mode (`claude -p`) that holds a one-shot Deputy until the PR is merged or closed; set `"prPollMinutes": 0` to switch PR watching off for such runs.

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
4. On red, the failure is recorded in task state and the Deputy sends the failure output back to the member (`dep-send.ps1`), which fixes it in the same session and worktree.

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
| `autoWatch` | `true` | Whether the `Stop` / `StopFailure` hook runs the watcher and rewakes the session (see "Wakes that survive") |
| `effort` | `null` | Default `--effort` for posse members: `low`, `medium`, `high`, `xhigh` or `max` (`null` = leave the flag off). `dep-spawn.ps1 -Effort` overrides it |
| `maxBudgetUsd` | `null` | Default `--max-budget-usd` for one run of a posse member (`null` = no cap). `dep-spawn.ps1 -MaxBudgetUsd` overrides it |
| `prPollMinutes` | `5` | Minutes between the watcher's reads of one published task's pull request (`0` = no PR watching, no `merged`, `degraded` or `closed` wakes) |

## Layout

```
bin\        toolbelt (dep-doctor, dep-spawn, dep-send, dep-watch, dep-wake, dep-posse, dep-validate, dep-publish, dep-pr, dep-return, dep-dashboard, dep-lib)
            and the session hooks (dep-session-start, dep-hook-guard, dep-hook-stop)
.claude\    settings.json (the session hooks), skills\
config\     deputy.json, projects.json
tools\      Deputy's own gate: Invoke-Lint.ps1, Invoke-Tests.ps1, plus the module pins (gate-modules.psd1) and Install-GateModules.ps1
tests\      Pester suite for the toolbelt
.github\    workflows\ci.yml runs the gate on pull requests and pushes to main
state\      one json per task, briefings and follow-up messages, wake-queue.jsonl + wake-queue.seq,
            watcher.lock + watcher.beat, hook counters, scout reports, validation records, archive\ (runtime)
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

The tests build throwaway git repos and throwaway Deputy installs under `$env:TEMP` - no network, and they never touch the real `state\` or `logs\`. They need only `git` and `pwsh`: no treehouse, no claude, and no signed-in `gh`. Where a test has to see what a member process was given (`dep-spawn.ps1`, `dep-send.ps1`), fake `claude` and `treehouse` shims go first on `PATH`. Everything that reads or merges a pull request (`dep-pr.ps1`, `dep-publish.ps1`, `dep-return.ps1`, the watcher's PR polling) runs against a fake `gh` on `PATH` that answers `gh api` from a routes file, and against local bare repositories as `origin`.

### CI

`.github\workflows\ci.yml` runs the same two commands on `windows-latest` for every pull request and every push to `main`, so a PR is checked however it was opened - not only when Deputy's own gate shipped it. The job installs the pinned modules with `tools\Install-GateModules.ps1` (cached, keyed on the pin file), fails on a non-zero exit from either command, runs with read-only `contents` permission, and cancels a run that a newer push to the same ref has superseded.

## Credits

Concept and task model from [firstmate](https://github.com/kunchenguid/firstmate) by kunchenguid; worktree pooling by [treehouse](https://github.com/kunchenguid/treehouse). MIT-licensed inspirations, reimagined for Windows.
