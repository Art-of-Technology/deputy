#Requires -Version 7.0
<#
.SYNOPSIS
Stop hook (synchronous): do not let the Deputy end a turn while posse tasks
are active and nothing is watching them.

If any task is running or stalled and no healthy watcher will report to this
session, the stop is blocked (exit 2) with a one-line instruction to start the
watcher. At most three stops in a row are blocked; the count lives in
state\hook-guard.blocks. After that the stop is let through with a warning to
the Sheriff, and stays let through until a watcher is healthy again or no task
is active - a guard that cannot be satisfied must not trap the session.
The decision table is Get-StopGuardDecision in dep-lib.ps1.

It cooperates with dep-hook-stop.ps1, which runs on the same Stop event and
starts the watcher itself (config autoWatch): the guard gives that watcher a
few seconds to come up before judging, so in the normal case it blocks nothing
and only speaks up when the automatic start did not work.

Does nothing outside the Deputy home (see Test-DeputyHome): this hook is also
loaded by posse members working in a worktree of this repository.

Never run it by hand; it reads the hook's JSON on stdin.
#>
[CmdletBinding()]
param(
    # How long to wait for dep-hook-stop.ps1's watcher to report healthy.
    [int]$GraceSeconds = 20
)

$hookStarted = [datetime]::UtcNow
try {
    . "$PSScriptRoot\dep-lib.ps1"
    if (-not (Test-DeputyHome)) { exit 0 }

    $session = Get-HookField (Read-HookInput) 'session_id'
    $paths = Get-DeputyPaths
    $autoWatch = [bool](Get-DeputyConfig).autoWatch
    $active = @(Get-ActiveTasks).Count
    $health = Get-WatcherHealth
    $serving = Test-WatcherServes $health $session

    if ($active -gt 0 -and -not $serving -and $autoWatch) {
        # dep-hook-stop.ps1 was started beside this hook, for the same stop. It
        # is either starting the watcher, or handing the session a queued wake
        # - in which case the session is about to be woken and there is nothing
        # to block. Wait for evidence of one or the other; if neither shows up,
        # the automatic start is not working and the decision below blocks.
        # (The slack covers the two hooks not starting at the same instant.)
        $since = $hookStarted.AddSeconds(-5)
        $deadline = [datetime]::UtcNow.AddSeconds($GraceSeconds)
        while ($true) {
            if (Test-WakeAnnouncedSince $since) { exit 0 }
            $health = Get-WatcherHealth
            $serving = Test-WatcherServes $health $session
            if ($serving -or [datetime]::UtcNow -ge $deadline) { break }
            Start-Sleep -Milliseconds 250
        }
    }

    $decision = Invoke-WithStateLock {
        $blocks = Get-StateCounter $paths.GuardBlocks
        $verdict = Get-StopGuardDecision -ActiveTasks $active -WatcherHealthy $serving -Blocks $blocks
        if ($verdict.Blocks -ne $blocks) { Write-FileAtomic $paths.GuardBlocks "$($verdict.Blocks)" }
        $verdict
    }

    $start = 'pwsh -NoProfile -File "{0}" -Wait' -f (Join-Path $paths.Bin 'dep-watch.ps1')
    $why = $health.Healthy ? "the running watcher reports to another session ($($health.Session))" : $health.Reason
    switch ($decision.Action) {
        'block' {
            $message = ("Deputy stop guard ({0}/{1}): {2} posse task(s) are active and {3}. " +
                "Start the watcher as a background process before ending the turn: {4}") -f
                $decision.Blocks, $script:GuardMaxBlocks, $active, $why, $start
            [Console]::Error.WriteLine($message)
            exit 2
        }
        'release' {
            # Exit 0 with a systemMessage: shown to the Sheriff, not fed back
            # to the model, which has already been told the maximum number of
            # times.
            $message = ("DEPUTY STOP GUARD GAVE UP: {0} posse task(s) are active and {1}. The stop was blocked {2} times " +
                "and is now being let through, so NOTHING WILL WAKE THE DEPUTY when a task finishes. Start the watcher " +
                "({3}) or check on the posse with dep-posse.ps1 status.") -f $active, $why, $script:GuardMaxBlocks, $start
            Write-Output (([ordered]@{ systemMessage = $message }) | ConvertTo-Json -Compress)
            exit 0
        }
    }
    exit 0
}
catch {
    # A guard that is itself broken must fail open, and say so.
    [Console]::Error.WriteLine("Deputy stop guard failed and let the stop through: $($_.Exception.Message)")
    exit 0
}
