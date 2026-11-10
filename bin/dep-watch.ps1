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
decision is needed.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessage('PSReviewUnusedParameter', 'DeadSeconds',
    Justification = 'Used inside the nested Invoke-Scan function; the analyzer cannot see through the closure')]
param(
    [switch]$Wait,
    [int]$IntervalSeconds = 0,   # 0 = use config
    [int]$StallMinutes = 0,      # 0 = use config
    [int]$DeadSeconds = 90,      # log-silence grace before a dead process counts as died
    [int]$TimeoutMinutes = 0     # with -Wait: 0 = wait forever
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
    $active = @(Get-AllTasks | Where-Object { $_.status -in @('running', 'stalled') })
    foreach ($task in $active) {
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
            $events += New-Wake $task $task.status (Limit-Text $text 500)
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
            $events += New-Wake $task 'died' ($summary + (Limit-Text $errTail 300))
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
                $events += New-Wake $task 'stalled' $summary
            }
        }

        Write-TaskState $task
    }
    , $events
}

$deadline = if ($Wait -and $TimeoutMinutes -gt 0) { (Get-Date).AddMinutes($TimeoutMinutes) } else { $null }

while ($true) {
    $events = Invoke-Scan
    foreach ($e in $events) {
        Add-WakeEvent $e
        Write-Output ("[wake] {0}: {1} ({2})" -f $e.taskId, $e.event, $e.kind)
        if ($e.prUrl) { Write-Output ("  pr: {0}" -f $e.prUrl) }
        if ($e.prUrlRejected) { Write-Output ("  pr REJECTED (not this task's repo): {0}" -f $e.prUrlRejected) }
        if ($e.summary) { Write-Output ("  {0}" -f $e.summary) }
    }
    if ($events.Count -gt 0) {
        if ($Wait) { exit 0 } else { break }
    }
    if (-not $Wait) {
        Write-Output "watch: no new events."
        break
    }
    $stillActive = @(Get-AllTasks | Where-Object { $_.status -in @('running', 'stalled') })
    if ($stillActive.Count -eq 0) {
        Write-Output "watch: no active posse tasks."
        exit 0
    }
    if ($deadline -and (Get-Date) -gt $deadline) {
        Write-Output "watch: timed out after $TimeoutMinutes minutes with tasks still active."
        exit 2
    }
    Start-Sleep -Seconds $IntervalSeconds
}
