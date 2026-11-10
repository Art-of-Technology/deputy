#Requires -Version 7.0
<#
.SYNOPSIS
Watch running posse tasks and the pull requests of published ones, and surface
actionable wake events: completed, failed, interrupted, blocked,
needs-decision, died, stalled, merged, degraded.

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

function ConvertFrom-StreamLine([string]$Line) {
    # One stream-json line as an object, or $null for anything unparseable
    # (a line the member is still writing, stray non-JSON output).
    try { $Line | ConvertFrom-Json -ErrorAction Stop } catch { $null }
}

function Get-SessionResult([string]$LogPath, [long]$Offset = 0) {
    <#
    .SYNOPSIS
    The LAST {"type":"result",...} event in a stream-json log, and whether the
    session carried on after it.

    A result event is not proof the member is done: a member that started
    background helpers emits one at the end of each turn, then resumes when a
    helper reports back and emits another. So the last result is the only
    candidate for the final one, and it is Interim when assistant or user
    events follow it. Returns $null when the log holds no result event.

    -Offset is where the current run starts in the log, in bytes. Everything
    before it belongs to runs that were already handled.
    #>
    if (-not (Test-Path $LogPath)) { return $null }
    $last = $null
    $continued = $false
    try {
        # Share the file with the member, which is still appending to it.
        $stream = [System.IO.FileStream]::new($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    }
    catch { return $null }
    try {
        if ($Offset -gt 0) {
            # A log shorter than its recorded offset has no current run yet.
            if ($Offset -gt $stream.Length) { return $null }
            $null = $stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        }
        $reader = [System.IO.StreamReader]::new($stream)
        while ($null -ne ($line = $reader.ReadLine())) {
            # Cheap substring tests first: logs run to megabytes, and only the
            # few candidate lines are worth parsing. Nested occurrences of
            # these keys are escaped inside JSON strings, and the parsed
            # top-level type is what decides.
            if ($line.Contains('"type":"result"')) {
                $parsed = ConvertFrom-StreamLine $line
                if ($parsed -and $parsed.PSObject.Properties['type'] -and $parsed.type -eq 'result') {
                    $last = $parsed
                    $continued = $false
                }
            }
            elseif ($last -and -not $continued -and
                ($line.Contains('"type":"assistant"') -or $line.Contains('"type":"user"'))) {
                $parsed = ConvertFrom-StreamLine $line
                if ($parsed -and $parsed.PSObject.Properties['type'] -and $parsed.type -in @('assistant', 'user')) {
                    $continued = $true
                }
            }
        }
    }
    finally { $stream.Dispose() }
    if (-not $last) { return $null }
    [pscustomobject]@{
        Event   = $last
        Text    = (Get-MemberOutcome $last).Text
        Interim = $continued
    }
}

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

function Set-TaskUsage($Task, $ResultEvent) {
    # What the run cost, from its final result. total_cost_usd is the cost of
    # the whole session, earlier runs included (a resumed run reports the
    # running total), so it replaces the stored figure and never lowers it.
    # num_turns and duration_ms count the one run, so they add up.
    $cost = ConvertTo-InvariantNumber (Get-EventField $ResultEvent 'total_cost_usd')
    if ($null -ne $cost) {
        $known = ConvertTo-InvariantNumber (Get-EventField $Task 'totalCostUsd')
        Set-TaskField $Task 'totalCostUsd' ([math]::Max($cost, [double]($known ?? 0)))
    }
    foreach ($pair in @(@('num_turns', 'numTurns'), @('duration_ms', 'durationMs'))) {
        $value = ConvertTo-InvariantNumber (Get-EventField $ResultEvent $pair[0])
        if ($null -ne $value) {
            $known = ConvertTo-InvariantNumber (Get-EventField $Task $pair[1])
            Set-TaskField $Task $pair[1] ([long]($value + ($known ?? 0)))
        }
    }
}

function New-Wake($Task, [string]$EventName, [string]$Summary) {
    $report = Get-EventField $Task 'report'
    [pscustomobject]@{
        seq           = 0   # set by Add-WakeEvent
        at            = (Get-Date -Format o)
        taskId        = $Task.id
        event         = $EventName
        kind          = $Task.kind
        repo          = $Task.repo
        prUrl         = $Task.prUrl
        prUrlRejected = $Task.prUrlRejected
        summary       = $Summary
        # For the wakes that are answered with dep-send.ps1: what the member
        # asked, and how many follow-ups it has been sent already.
        question      = ($EventName -in @('blocked', 'needs-decision') -and $report) ? $report.question : $null
        followUps     = @(Get-TaskFollowUps $Task).Count
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

        # Completion needs BOTH signals: the last result event with nothing
        # after it, and no member process. A result seen while the process is
        # alive is interim - the member may be waiting on background helpers
        # and go on to do more work - so it must not wake the Deputy.
        $session = Get-SessionResult $task.stdoutLog ([long](Get-EventField $task 'logOffset'))
        if ($session -and -not $session.Interim -and -not $alive) {
            # The wake and the task's status share one name: completed, failed,
            # interrupted, blocked or needs-decision.
            $outcome = Get-MemberOutcome $session.Event
            Set-TaskField $task 'status' $outcome.Wake
            Set-TaskField $task 'endedAt' (Get-Date -Format o)
            Set-TaskField $task 'result' $outcome.Text
            Set-TaskField $task 'report' $outcome.Report
            Set-TaskPrUrl $task $outcome.Text $outcome.Report
            Set-TaskUsage $task $session.Event
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
    | closed without merging                        | none     | prCheckedAt              |
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
    if ($pr.State -ne 'open' -or -not $pr.HeadSha) { return $observation }
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
        # (dep-pr.ps1 merge, dep-publish.ps1, dep-return.ps1). Look again before
        # saying anything: a task that was returned, or whose merge is already
        # recorded, needs no wake.
        $current = try { Read-TaskState $task.id } catch { $null }
        if (-not $current) { continue }
        if ($observation.Event -eq 'merged' -and (Get-EventField $current 'mergedAt')) { continue }

        # Queue first, record second, as above: a watcher killed in between
        # repeats the wake rather than losing it. Only the fields this poll
        # owns are written, onto the record as it is on disk now.
        if ($observation.Event) {
            $events += Add-WakeEvent (New-Wake $current $observation.Event (Limit-Text $observation.Summary 500))
        }
        $null = Update-TaskState $task.id $observation.Fields
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
