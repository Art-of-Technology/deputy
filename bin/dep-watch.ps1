#Requires -Version 7.0
<#
.SYNOPSIS
Watch running posse tasks and surface actionable wake events: completed,
failed, died, stalled.

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

function Get-ResultEvent([string]$LogPath) {
    # A finished stream-json session ends with a single {"type":"result",...} line
    if (-not (Test-Path $LogPath)) { return $null }
    foreach ($line in (Get-Content $LogPath -Tail 5 -ErrorAction SilentlyContinue)) {
        if ($line -and $line -like '*"type":"result"*') {
            try { return $line | ConvertFrom-Json } catch { return $null }
        }
    }
    $null
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

        $result = Get-ResultEvent $task.stdoutLog
        if ($result) {
            $ok = -not $result.is_error
            Set-TaskField $task 'status' ($ok ? 'completed' : 'failed')
            Set-TaskField $task 'endedAt' (Get-Date -Format o)
            $text = if ($result.PSObject.Properties['result']) { [string]$result.result } else { '' }
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
            $events += New-Wake $task 'died' ("process exited without a result. stderr: " + (Limit-Text $errTail 300))
        }
        elseif ($task.status -eq 'running' -and -not $task.stallNotified) {
            $idleMinutes = ((Get-Date) - [datetime]$task.lastActivityAt).TotalMinutes
            if ($idleMinutes -ge $StallMinutes) {
                Set-TaskField $task 'status' 'stalled'
                Set-TaskField $task 'stallNotified' $true
                $events += New-Wake $task 'stalled' ("no log activity for {0:n0} minutes; process still alive" -f $idleMinutes)
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
