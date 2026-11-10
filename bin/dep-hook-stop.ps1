#Requires -Version 7.0
<#
.SYNOPSIS
Stop / StopFailure hook (asyncRewake): keep a watcher running for this session
without the model having to remember to start one, and wake the session when a
wake arrives.

Claude Code runs an asyncRewake hook in the background after the turn ends.
When the hook exits 2, its stderr is handed to the session as a new turn, even
if the session is sitting idle. So this hook:

1. hands over any wake in the durable queue that it has not pushed at the
   session before (exit 2 with the drain report);
2. otherwise, if tasks are active - or a published pull request is still
   waiting to be merged, which the watcher polls - and no healthy watcher
   reports to this session, runs dep-watch.ps1 -Wait in its own foreground
   and, when that returns a wake, exits 2 with the drain report;
3. otherwise exits 0 and says nothing.

It runs on StopFailure too, which is the turn ending on an API error - the
case where the model never got the chance to start a watcher at all. After a
StopFailure, a wake that was already pushed once is pushed again after a
cooldown (the turn that was told about it may be the one that failed), a
bounded number of times, so a persistent API error cannot turn into a storm.

The report always comes from the queue, never from the watcher's output, and
pushing a wake never acknowledges it: only dep-wake.ps1 ack does.

Switch it off with "autoWatch": false in config\deputy.json. The queue, the
session-start report and the stop guard keep working without it.

Does nothing outside the Deputy home (see Test-DeputyHome): this hook is also
loaded by posse members working in a worktree of this repository.

Never run it by hand: a watcher parked under a short-lived tool process wakes
nobody. Start dep-watch.ps1 -Wait as a background process instead.
#>
[CmdletBinding()]
param(
    # After a StopFailure: seconds to wait before pushing an already-pushed
    # wake again, multiplied by the number of the attempt.
    [int]$RetryCooldownSeconds = 60,
    # How often one wake is pushed again after StopFailures.
    [int]$MaxRetries = 5
)

function Send-Rewake($Wakes, [string]$Note) {
    # Exit 2 from an asyncRewake hook: stderr becomes the session's next turn.
    $lines = @("Deputy wake: the watcher reported while this session was idle.$Note")
    $lines += @(Format-WakeReport $Wakes)
    [Console]::Error.WriteLine($lines -join [Environment]::NewLine)
    exit 2
}

try {
    . "$PSScriptRoot\dep-lib.ps1"
    if (-not (Test-DeputyHome)) { exit 0 }
    if (-not (Get-DeputyConfig).autoWatch) { exit 0 }

    $hookInput = Read-HookInput
    $session = Get-HookField $hookInput 'session_id'
    $afterFailure = (Get-HookField $hookInput 'hook_event_name') -eq 'StopFailure'
    $watch = Join-Path $PSScriptRoot 'dep-watch.ps1'
    $quickReturns = 0
    $watchExit = 0

    while ($true) {
        $pending = @(Get-PendingWakes)
        if ($pending.Count -gt 0) {
            $top = [long]($pending | ForEach-Object { [long]$_.seq } | Measure-Object -Maximum).Maximum
            $announced = Get-WakeAnnounced
            if ($top -gt $announced.Seq) {
                Set-WakeAnnounced $top 0
                Send-Rewake $pending ''
            }
            if ($afterFailure -and $announced.Retries -lt $MaxRetries) {
                $afterFailure = $false   # one repeat per hook run
                Start-Sleep -Seconds ($RetryCooldownSeconds * ($announced.Retries + 1))
                $pending = @(Get-PendingWakes)
                if ($pending.Count -gt 0) {
                    $top = [long]($pending | ForEach-Object { [long]$_.seq } | Measure-Object -Maximum).Maximum
                    Set-WakeAnnounced $top ($announced.Retries + 1)
                    Send-Rewake $pending ' (Repeated: the turn that was told about these may have ended on an API error.)'
                }
            }
        }

        # The watcher this hook ran did not end on its own terms: it was
        # replaced (another session's stop hook took the lock over) or it
        # crashed. Either way, stand down rather than fight for the lock.
        if ($watchExit -ne 0) { exit 0 }
        # Work for a watcher is a running member, or a published pull request
        # that has not been merged yet (the watcher polls it).
        if ((Get-WatchLoad).Total -eq 0) { exit 0 }
        if (Test-WatcherServes (Get-WatcherHealth) $session) { exit 0 }

        # Park on the watcher. It returns when a wake fires, when there is
        # nothing left to watch, or at once when another live watcher holds the lock;
        # the next pass through the loop works out which from the queue and
        # the lock, not from what it printed.
        $started = [datetime]::UtcNow
        & pwsh -NoProfile -File $watch -Wait -Session $session -OwnerPid $PID *> $null
        $watchExit = $LASTEXITCODE
        if (([datetime]::UtcNow - $started).TotalSeconds -lt 5) {
            # Came straight back. If that keeps happening without a wake to
            # show for it, the watcher cannot run here: stand down and leave
            # it to the stop guard, which tells the Deputy.
            $quickReturns++
            if ($quickReturns -ge 3) { exit 0 }
            Start-Sleep -Seconds 2
        }
        else { $quickReturns = 0 }
    }
}
catch {
    # Never exit 2 on an error: that would wake the session with a stack trace.
    exit 0
}
