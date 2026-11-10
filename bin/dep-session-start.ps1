#Requires -Version 7.0
<#
.SYNOPSIS
The Deputy's session-start report: toolchain problems, the posse as it stands,
the watcher, and every wake nobody has acknowledged yet.

Run by the SessionStart hook in .claude\settings.json (with -Hook), so a
session that starts, resumes, or comes back from a compaction learns what
happened while nobody was listening instead of having to remember to ask.
Whatever it prints is added to the session's context.

It always exits 0: a report that cannot be produced must not stop a session
from starting. A section that fails says so in its place.

-Hook marks an invocation by the hook. Then, and only then, the script does
nothing at all outside the Deputy home (see Test-DeputyHome): the same hook
is loaded by posse members working in a worktree of this repository. Run by
hand, without -Hook, it always reports.

.EXAMPLE
pwsh -NoProfile -File bin\dep-session-start.ps1
#>
[CmdletBinding()]
param([switch]$Hook)

try {
    . "$PSScriptRoot\dep-lib.ps1"
    if ($Hook -and -not (Test-DeputyHome)) { exit 0 }
    $hookInput = $Hook ? (Read-HookInput) : $null
    Initialize-Deputy
}
catch {
    Write-Output "Deputy session start: could not load ($($_.Exception.Message))"
    exit 0
}

function Write-Section([string]$Title, [scriptblock]$Body) {
    try { & $Body | Write-Output }
    catch { Write-Output "${Title}: could not be read ($($_.Exception.Message))" }
}

Write-Output 'Deputy session start'

# The doctor reaches the network (gh, origin), so it runs when a session starts
# or resumes - not again on every /clear and compaction of the same session.
$source = Get-HookField $hookInput 'source'
if ($source -notin @('clear', 'compact')) {
    Write-Section 'Toolchain' {
        $problems = @(Get-DoctorProblems)
        if ($problems.Count -eq 0) { 'Toolchain: healthy.' }
        else {
            'Toolchain problems (dep-doctor.ps1). Relay every line to the Sheriff verbatim, fix included; do not run the fixes yourself:'
            $problems | ForEach-Object { "  $_" }
        }
    }
}

Write-Section 'Posse' {
    if (@(Get-AllTasks).Count -eq 0) { 'Posse: no tasks.' }
    else {
        'Posse (dep-posse.ps1 status):'
        (& "$PSScriptRoot\dep-posse.ps1" status | Out-String -Width 200).Trim("`r", "`n")
    }
}

Write-Section 'Watcher' {
    $health = Get-WatcherHealth
    if ($health.Healthy) { "Watcher: $($health.Reason)." }
    else {
        # A watcher has work while a member runs, and while a published pull
        # request is waiting to be merged (it polls those).
        $load = Get-WatchLoad
        if ($load.Total -gt 0) {
            $start = 'pwsh -NoProfile -File "{0}" -Wait' -f (Join-Path $PSScriptRoot 'dep-watch.ps1')
            $how = if ((Get-DeputyConfig).autoWatch) {
                "The stop hook starts one when this turn ends; to start it now, run in the background: $start"
            } else { "Start it in the background: $start" }
            $what = @()
            if ($load.Active -gt 0) { $what += "$($load.Active) task(s) are active" }
            if ($load.Pulls -gt 0) { $what += "$($load.Pulls) published pull request(s) are waiting to be merged" }
            "Watcher: $($health.Reason), and $($what -join ' and '). $how"
        }
        else { 'Watcher: not running (no active tasks).' }
    }
}

Write-Section 'Wake queue' {
    # The drain itself, so what the session sees here is exactly what
    # dep-wake.ps1 drain would print - ack command included.
    if (@(Get-PendingWakes).Count -gt 0) {
        'Wake queue (dep-wake.ps1 drain) - these wakes were never acknowledged. Handle them before anything else:'
    }
    & "$PSScriptRoot\dep-wake.ps1" drain
}
exit 0
