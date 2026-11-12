#Requires -Version 7.0
<#
.SYNOPSIS
Watch running posse tasks and the pull requests of published ones, and surface
actionable wake events: completed, failed, interrupted, blocked,
needs-decision, died, stalled, merged, degraded, closed.

A task is completed (or failed, interrupted, blocked, needs-decision) only when
its final result event has arrived AND the member process has exited. A result
event seen while the process is still alive is interim and produces no wake on
its own.

What the final result means is decided by Get-MemberOutcome (dep-lib.ps1):
- an error result caused by a transient server failure (HTTP 429, 500, 502,
  503, 529, "overloaded") is `interrupted`, not `failed`: the session is intact
  and dep-send.ps1 continues it;
- a structured final report (the --json-schema every member is started with)
  maps by its status: done is `completed`, blocked is `blocked`, needs-decision
  is `needs-decision`, failed is `failed`;
- a result with no structured report is handled as text, as it always was.

Only the current run is read: after dep-send.ps1 resumes a member, the log
holds the earlier runs' results too, and the task's logOffset marks where the
current one starts.

When a run ends, its usage is added to the task (Read-MemberRun and
Add-RunUsage, dep-lib.ps1): the turns and duration of every result event in the
run, since each one covers only its own segment, and the session's running
cost. The model the member reports in its init event is kept as reportedModel;
when it is not the model the task was started with, the member's wakes say so.

Once a task has a pull request, the watcher keeps reading it until it is seen
merged or the task is returned: every prPollMinutes (config, default 5; 0
switches it off), over REST (`gh api`), so no read:org token scope is needed.
- `merged`, once: the PR was merged. mergedAt and mergeSha are recorded, and
  the task is not polled again. A merge dep-pr.ps1 merge made itself is already
  recorded and raises no wake.
- `degraded`, once per head commit: a check is failing at the PR's current
  head. A PR counts as green from the moment it is published - the gate passed
  on that commit - so the first failing check is news, and so is the first
  one after every new head.
- `closed`, once: the PR was closed without merging. prClosedAt is recorded,
  and from then on the PR no longer counts as something to wait for: it does
  not keep this watcher, the stop hooks or a one-shot session waiting. It is
  still read whenever a watcher is running for another reason, and when that
  shows it open again prClosedAt is cleared and it counts as before.
A PR that cannot be read (no network, gh not signed in, a 404) produces
nothing at all: a failed lookup is never a merge, and never a wake.

Default: one scan, print any events, exit.
-Wait: block (polling) until at least one actionable event occurs, print it,
exit 0. Exits 0 immediately if no task is active and no published pull request
is waiting to be merged; exits 2 on timeout.
Designed to run as a background process so the Deputy is woken only when a
decision is needed. Exits 1 only when the watcher lock is held by a process
that should be replaced and cannot be.

Every wake is appended to the durable queue (state\wake-queue.jsonl) with a
sequence number before anything else happens, so printing it here is no longer
the only way it is seen: dep-wake.ps1 drain shows every wake that has not been
acknowledged, whoever was or was not listening when it fired.

Only one watcher scans at a time. It holds state\watcher.lock (pid plus process
start time) and touches state\watcher.beat on every poll. If a live watcher
already holds the lock, this one says so and exits 0 without scanning. The lock
of a watcher that is gone is reclaimed; a watcher that is alive but no longer
polling is replaced.

-Session and -OwnerPid are for dep-hook-stop.ps1, which runs the watcher on
behalf of one Claude session: the session id is recorded in the lock, and the
watcher exits when the hook process that owns it is gone.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessage('PSReviewUnusedParameter', 'DeadSeconds',
    Justification = 'Used inside the nested Invoke-Scan function; the analyzer cannot see through the closure')]
param(
    [switch]$Wait,
    [int]$IntervalSeconds = 0,   # 0 = use config
    [int]$StallMinutes = 0,      # 0 = use config
    [int]$PrPollSeconds = 0,     # seconds between reads of one pull request; 0 = use config (prPollMinutes)
    [int]$DeadSeconds = 90,      # log-silence grace before a dead process counts as died
    [int]$TimeoutMinutes = 0,    # with -Wait: 0 = wait forever
    [string]$Session = '',       # the Claude session a stop hook runs this watcher for
    [int]$OwnerPid = 0           # with -Wait: exit when this process is gone
)

. "$PSScriptRoot\dep-lib.ps1"
Initialize-Deputy
$config = Get-DeputyConfig
if ($IntervalSeconds -le 0) { $IntervalSeconds = [int]$config.watchIntervalSeconds }
if ($StallMinutes -le 0) { $StallMinutes = [int]$config.stallMinutes }
if ($PrPollSeconds -le 0) { $PrPollSeconds = [int]([double]$config.prPollMinutes * 60) }

function Test-PrUrlBelongsToRepo([string]$RepoPath, [string]$Owner, [string]$Repo) {
    # Only trust a PR URL that points at the task's own repo. The URL comes
    # from the posse member's final message, so a prompt-injected member could
    # otherwise steer the Deputy into merging a foreign PR (dep-pr.ps1 passes
    # prUrl straight to gh). Owner/repo compare case-insensitively (GitHub
    # treats them that way); no origin remote means no URL can be trusted.
    $origin = @(git -C $RepoPath remote get-url origin 2>$null)[0]
    if ($LASTEXITCODE -ne 0 -or -not $origin) { return $false }
    $pattern = 'github\.com[:/]{0}/{1}(\.git)?/?$' -f [regex]::Escape($Owner), [regex]::Escape($Repo)
    $origin.Trim() -match $pattern
}

function Set-TaskPrUrl($Task, [string]$Text, $Report) {
    # A structured report names its PR in a field of its own; otherwise the
    # URL is looked for in the result text. Either way it is the member's word,
    # and is only kept as prUrl when it points at the task's own repo.
    $claimed = $Report ? [string]$Report.prUrl : $Text
    if (-not $claimed) { return }
    if ($claimed -match 'https://github\.com/([^/\s)"'']+)/([^/\s)"'']+)/pull/\d+') {
        if (Test-PrUrlBelongsToRepo $Task.repo $Matches[1] $Matches[2]) {
            Set-TaskField $Task 'prUrl' $Matches[0]
            # The PR is polled from here on; its first read is one interval away.
            Set-TaskField $Task 'prCheckedAt' (Get-Date -Format o)
        }
        else {
            Set-TaskField $Task 'prUrlRejected' $Matches[0]
        }
    }
    elseif ($Report) {
        # The prUrl field held something that is not a pull request URL.
        Set-TaskField $Task 'prUrlRejected' (Limit-Text $claimed 200)
    }
}

# The wakes that are about the member's run, as opposed to its pull request.
$script:MemberWakes = @($script:MemberReportWakes.Values) + @('interrupted', 'died', 'stalled')

function New-Wake($Task, [string]$EventName, [string]$Summary) {
    $report = Get-EventField $Task 'report'
    [pscustomobject]@{
        seq           = 0   # set by Add-WakeEvent
        at            = (Get-Date -Format o)
        taskId        = $Task.id
        event         = $EventName
        kind          = $Task.kind
        # A ship task's delivery mode decides what its completed wake calls
        # for: gated is validated and published by the Deputy, direct-pr
        # already has its pull request.
        delivery      = Get-TaskDelivery $Task
        repo          = $Task.repo
        prUrl         = $Task.prUrl
        prUrlRejected = $Task.prUrlRejected
        summary       = $Summary
        # For the wakes that are answered with dep-send.ps1: what the member
        # asked, and how many follow-ups it has been sent already.
        question      = ($EventName -in @('blocked', 'needs-decision') -and $report) ? $report.question : $null
        followUps     = @(Get-TaskFollowUps $Task).Count
        # The member runs on another model than the one it was started with
        # (a typo in a model name, or an alias claude resolved). Only on the
        # wakes about the member itself, not on the pull request's.
        modelMismatch = ($EventName -in $script:MemberWakes) ? (Get-TaskModelMismatch $Task) : $null
    }
}

function Invoke-Scan {
    $events = @()
    foreach ($task in (Get-ActiveTasks)) {
        $wake = $null
        $size = if (Test-Path $task.stdoutLog) { (Get-Item $task.stdoutLog).Length } else { 0 }
        $alive = Test-TaskProcessAlive $task

        if ($size -ne $task.lastLogBytes) {
            Set-TaskField $task 'lastLogBytes' $size
            Set-TaskField $task 'lastActivityAt' (Get-Date -Format o)
            if ($task.status -eq 'stalled') {
                Set-TaskField $task 'status' 'running'
                Set-TaskField $task 'stallNotified' $false
            }
        }

        # Only the current run counts: after dep-send.ps1 the log also holds
        # the earlier runs, which were handled when they ended.
        $run = Read-MemberRun $task.stdoutLog ([long](Get-EventField $task 'logOffset'))
        $session = $run ? $run.Result : $null
        # The model the member says it runs on, as soon as its init event is
        # there, so dep-posse.ps1 status can show it while it works.
        if ($run -and $run.ReportedModel) { Set-TaskField $task 'reportedModel' $run.ReportedModel }

        # Completion needs BOTH signals: the last result event with nothing
        # after it, and no member process. A result seen while the process is
        # alive is interim - the member may be waiting on background helpers
        # and go on to do more work - so it must not wake the Deputy.
        if ($session -and -not $session.Interim -and -not $alive) {
            # The wake and the task's status share one name: completed, failed,
            # interrupted, blocked or needs-decision.
            $outcome = Get-MemberOutcome $session.Event
            Set-TaskField $task 'status' $outcome.Wake
            Set-TaskField $task 'endedAt' (Get-Date -Format o)
            Set-TaskField $task 'result' $outcome.Text
            Set-TaskField $task 'report' $outcome.Report
            Set-TaskPrUrl $task $outcome.Text $outcome.Report
            Add-RunUsage $task $run
            # The wake carries the question on a line of its own (New-Wake), so
            # the summary does not repeat it.
            $said = $outcome.Report ? (Format-MemberReport $outcome.Report -NoQuestion) : $outcome.Text
            $wake = New-Wake $task $outcome.Wake (Limit-Text $said 500)
        }
        elseif (-not $alive -and ((Get-Date) - [datetime]$task.lastActivityAt).TotalSeconds -ge $DeadSeconds) {
            # No process (by pid or worktree occupancy) AND the log has been
            # silent past the grace period. The grace matters: the recorded pid
            # can be a short-lived launcher, and treehouse only sees processes
            # while a tool command runs in the worktree - a healthy member's
            # log keeps growing (tool_progress events), so silence + no
            # process is the real death signal.
            Set-TaskField $task 'status' 'died'
            Set-TaskField $task 'endedAt' (Get-Date -Format o)
            # The run is over all the same, and what it did before it died
            # counts towards the task.
            Add-RunUsage $task $run
            $errTail = if (Test-Path $task.stderrLog) {
                (Get-Content $task.stderrLog -Tail 3 -ErrorAction SilentlyContinue) -join ' | '
            } else { '' }
            # Reaching here with a result means it was interim: the session
            # carried on after it and never produced a final one.
            $summary = if ($session) {
                "process exited without a final result; its only result was an interim result: " +
                (Limit-Text $session.Text 200) + " | stderr: "
            } else { "process exited without a result. stderr: " }
            $wake = New-Wake $task 'died' ($summary + (Limit-Text $errTail 300))
        }
        elseif ($task.status -eq 'running' -and -not $task.stallNotified) {
            $idleMinutes = ((Get-Date) - [datetime]$task.lastActivityAt).TotalMinutes
            if ($idleMinutes -ge $StallMinutes) {
                Set-TaskField $task 'status' 'stalled'
                Set-TaskField $task 'stallNotified' $true
                $summary = "no log activity for {0:n0} minutes; process still alive" -f $idleMinutes
                if ($session -and -not $session.Interim) {
                    # A member that never exits after its last result lands
                    # here rather than hanging forever as 'running'.
                    $summary += ". A result event is present but the task is not completed until the " +
                        "process exits (it may be waiting on background helpers, or hung): " +
                        (Limit-Text $session.Text 200)
                }
                $wake = New-Wake $task 'stalled' $summary
            }
        }

        # Queue first, task record second. Once the record says 'completed'
        # the task is never scanned again, so a watcher killed between the two
        # writes must leave the wake behind, not the record: the worst case is
        # then the same wake twice, never a task that finished and told nobody.
        if ($wake) { $events += Add-WakeEvent $wake }
        Write-TaskState $task
    }
    $events += @(Invoke-PrScan)
    , $events
}

function Get-PrObservation($Task) {
    <#
    .SYNOPSIS
    Read one task's pull request and say what changed: the fields to record,
    and the wake to raise, if any.

    | what the read shows                           | wake     | recorded                 |
    | the PR could not be read                      | none     | prCheckedAt              |
    | merged                                        | merged   | mergedAt, mergeSha       |
    | open, a check failing at a head not yet told  | degraded | prDegradedHead           |
    | open and nothing failing, or already told     | none     | prCheckedAt              |
    | closed without merging, not yet told          | closed   | prClosedAt               |
    | closed without merging, already told          | none     | prCheckedAt              |
    | open again after it was seen closed           | none     | prClosedAt cleared       |
    #>
    $fields = [ordered]@{ prCheckedAt = (Get-Date -Format o) }
    $observation = [pscustomobject]@{ Fields = $fields; Event = ''; Summary = '' }
    $ref = Get-TaskPrRef $Task
    $pr = Get-PullRequest $ref
    # Silent on purpose. An unreadable PR says nothing about the PR.
    if (-not $pr.Ok) { return $observation }

    if ($pr.Merged) {
        $fields['mergedAt'] = $pr.MergedAt ?? (Get-Date -Format o)
        $fields['mergeSha'] = $pr.MergeSha
        $observation.Event = 'merged'
        $observation.Summary = "Pull request #$($ref.Number) was merged" +
            $(if ($pr.MergeSha) { " as $(Format-Sha $pr.MergeSha)" }) + '.'
        return $observation
    }
    $knownClosed = [bool](Get-EventField $Task 'prClosedAt')
    if ($pr.State -ne 'open') {
        # Closed without merging. Said once; the record is what remembers.
        if (-not $knownClosed) {
            $fields['prClosedAt'] = (Get-Date -Format o)
            $observation.Event = 'closed'
            $observation.Summary = "Pull request #$($ref.Number) was closed without merging."
        }
        return $observation
    }
    # Open. If it had been seen closed, it was reopened: wait for it again.
    if ($knownClosed) { $fields['prClosedAt'] = $null }
    if (-not $pr.HeadSha) { return $observation }
    if ($pr.HeadSha -eq [string](Get-EventField $Task 'prDegradedHead')) { return $observation }

    $checks = Get-PrChecks $ref $pr.HeadSha
    if (-not $checks.Ok -or $checks.Failing.Count -eq 0) { return $observation }
    $fields['prDegradedHead'] = $pr.HeadSha
    $observation.Event = 'degraded'
    $names = @($checks.Failing | ForEach-Object { "$($_.Name) ($($_.Detail))" }) -join ', '
    $summary = "Pull request #$($ref.Number) has $($checks.Failing.Count) failing check(s) at $(Format-Sha $pr.HeadSha): $names."
    $published = [string](Get-EventField $Task 'prHead')
    if ($published -and $published -ne $pr.HeadSha) {
        $summary += " That is not the commit Deputy published ($(Format-Sha $published)): somebody pushed to the PR."
    }
    $observation.Summary = $summary
    $observation
}

function Invoke-PrScan {
    # Poll the pull request of every published, unmerged task that is due.
    $events = @()
    if ($PrPollSeconds -le 0) { return $events }
    foreach ($task in (Get-PrWatchTasks)) {
        $last = ConvertTo-UtcDateTime (Get-EventField $task 'prCheckedAt')
        if ($last -and ([datetime]::UtcNow - $last).TotalSeconds -lt $PrPollSeconds) { continue }
        Set-WatcherBeat   # a read can take seconds, and there may be several
        $observation = Get-PrObservation $task

        # The read took a moment, and other scripts write this record too
        # (dep-pr.ps1 merge, dep-publish.ps1, dep-return.ps1). So the second
        # look, the wake and the write happen together under the state lock:
        # a task that was returned, or whose merge or closing is already
        # recorded, needs no wake, and nobody can record either in between.
        $queued = Invoke-WithStateLock {
            $current = try { Read-TaskState $task.id } catch { $null }
            if (-not $current) { return }
            if ($observation.Event -eq 'merged' -and (Get-EventField $current 'mergedAt')) { return }
            if ($observation.Event -eq 'closed' -and (Get-EventField $current 'prClosedAt')) { return }

            # Queue first, record second, as above: a watcher killed in between
            # repeats the wake rather than losing it. Only the fields this poll
            # owns are written, onto the record as it is on disk now.
            if ($observation.Event) {
                Add-WakeEvent (New-Wake $current $observation.Event (Limit-Text $observation.Summary 500))
            }
            $null = Update-TaskState $task.id $observation.Fields
        }
        if ($queued) { $events += $queued }
    }
    $events
}

$drainHint = 'Drain and acknowledge: ' + (Get-WakeCommand 'drain')

# One watcher at a time, one-shot scans included: two scanners would each see
# the same finished task and queue its wake twice.
$claim = Enter-WatcherLock -Session $Session
if (-not $claim.Acquired) {
    $holder = $claim.Holder
    if ($claim.Note) {
        # Not the clean case: the holder should have been replaced and could
        # not be, so nothing is scanning. Say so and fail.
        Write-Output "watch: $($claim.Note). Nothing is scanning the posse. This needs the Sheriff: check what pid $($holder.ProcessId) is."
        exit 1
    }
    $reportsTo = $holder.Session ?
        "It was started by the stop hook of session $($holder.Session) and wakes that session when a wake fires." :
        'It reports to whoever started it.'
    Write-Output ("watch: a live watcher (pid {0}) already holds the watcher lock, so this one is not starting. {1} Every wake also lands in the queue." -f
        $holder.ProcessId, $reportsTo)
    Write-Output $drainHint
    exit 0
}
if ($claim.Note) { Write-Output "watch: $($claim.Note)." }

$deadline = if ($Wait -and $TimeoutMinutes -gt 0) { (Get-Date).AddMinutes($TimeoutMinutes) } else { $null }

try {
    while ($true) {
        Set-WatcherBeat
        $events = Invoke-Scan
        foreach ($e in $events) { Format-Wake $e | Write-Output }
        if ($events.Count -gt 0) {
            Write-Output $drainHint
            if ($Wait) { exit 0 } else { break }
        }
        if (-not $Wait) {
            Write-Output "watch: no new events."
            break
        }
        if ((Get-WatchLoad).Total -eq 0) {
            Write-Output "watch: no active posse tasks and no published pull request waiting to be merged."
            exit 0
        }
        if ($deadline -and (Get-Date) -gt $deadline) {
            Write-Output "watch: timed out after $TimeoutMinutes minutes with tasks still active."
            exit 2
        }
        if ($OwnerPid -gt 0 -and -not (Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue)) {
            # The stop hook that ran this watcher is gone, so nothing would
            # hear its wake. Stand down and let the next session start its own.
            Write-Output "watch: owner process $OwnerPid is gone; stopping."
            exit 0
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}
finally { Exit-WatcherLock }
