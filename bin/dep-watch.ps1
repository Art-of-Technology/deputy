#Requires -Version 7.0
<#
.SYNOPSIS
Watch running posse tasks and surface actionable wake events: completed,
failed, died, stalled.

A task is completed (or failed) only when its final result event has arrived
AND the member process has exited. A result event seen while the process is
still alive is interim and produces no wake on its own.

Default: one scan, print any events, exit.
-Wait: block (polling) until at least one actionable event occurs, print it,
exit 0. Exits 0 immediately if no tasks are active; exits 2 on timeout.
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

function ConvertFrom-StreamLine([string]$Line) {
    # One stream-json line as an object, or $null for anything unparseable
    # (a line the member is still writing, stray non-JSON output).
    try { $Line | ConvertFrom-Json -ErrorAction Stop } catch { $null }
}

function Get-SessionResult([string]$LogPath) {
    <#
    .SYNOPSIS
    The LAST {"type":"result",...} event in a stream-json log, and whether the
    session carried on after it.

    A result event is not proof the member is done: a member that started
    background helpers emits one at the end of each turn, then resumes when a
    helper reports back and emits another. So the last result is the only
    candidate for the final one, and it is Interim when assistant or user
    events follow it. Returns $null when the log holds no result event.
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
        Text    = $last.PSObject.Properties['result'] ? [string]$last.result : ''
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

function New-Wake($Task, [string]$EventName, [string]$Summary) {
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
        $session = Get-SessionResult $task.stdoutLog
        if ($session -and -not $session.Interim -and -not $alive) {
            $ok = -not ($session.Event.PSObject.Properties['is_error'] -and $session.Event.is_error)
            Set-TaskField $task 'status' ($ok ? 'completed' : 'failed')
            Set-TaskField $task 'endedAt' (Get-Date -Format o)
            $text = $session.Text
            Set-TaskField $task 'result' $text
            if ($text -match 'https://github\.com/([^/\s)"'']+)/([^/\s)"'']+)/pull/\d+') {
                if (Test-PrUrlBelongsToRepo $task.repo $Matches[1] $Matches[2]) {
                    Set-TaskField $task 'prUrl' $Matches[0]
                }
                else {
                    Set-TaskField $task 'prUrlRejected' $Matches[0]
                }
            }
            $wake = New-Wake $task $task.status (Limit-Text $text 500)
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
    , $events
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
        if ((Get-ActiveTasks).Count -eq 0) {
            Write-Output "watch: no active posse tasks."
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