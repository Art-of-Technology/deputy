#Requires -Version 7.0
<#
.SYNOPSIS
Send a follow-up message to a posse member whose process has exited: resume
its session in its worktree and let it carry on.

A member is not one shot. Its session id was chosen at spawn (sessionId in
task state), so a finished session can be continued with everything the member
already knows: an answer to its question, a correction, or a plain "continue"
after an API outage. That is a one-line follow-up instead of a respawn that
starts from nothing and pays for the context a second time.

It refuses unless the task's process is gone and its worktree still exists:
you cannot type into a running member, and a returned task has no worktree to
work in. The resumed run is started with the same flags as the first one
(permissions, isolation, model, effort, budget, report schema), reads the
message on stdin, and appends to the same log. The task goes back to
`running`, and the watcher reports the resumed run's result as a new wake.
Each follow-up is recorded in task state (followUps).

A gate verdict from an earlier run is cleared: the member is about to change
the branch, so dep-validate.ps1 has to judge it again. That holds after
publishing too: when the task already has a PR, dep-validate.ps1 followed by
dep-publish.ps1 pushes the member's new commits to that same PR.

.EXAMPLE
.\dep-send.ps1 posse-20260729-114756-thv -Message "Continue where you left off."
.\dep-send.ps1 posse-20260729-114756-thv -Message "Use the v2 endpoint. Keep the old one working."
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Id,

    [Parameter(Mandatory)]
    [string]$Message
)

. "$PSScriptRoot\dep-lib.ps1"
Initialize-Deputy
$paths = Get-DeputyPaths
$task = Read-TaskState $Id

if (-not $Message.Trim()) { throw 'The message is empty. Say what the member should do next.' }

$sessionId = [string](Get-EventField $task 'sessionId')
if (-not $sessionId) {
    throw "Task $Id has no recorded session id (it was spawned before members were resumable), so it cannot be resumed. Respawn it with dep-spawn.ps1 instead."
}
if (-not $task.worktree -or -not (Test-Path -LiteralPath $task.worktree -PathType Container)) {
    throw "The worktree of $Id is gone ($($task.worktree)), so there is nowhere to resume it. Respawn it with dep-spawn.ps1 instead."
}
if (Test-TaskProcessAlive $task) {
    throw "Task $Id still has a live process: you cannot type into a running member. Wait for its wake, or stop it first with dep-posse.ps1 kill $Id."
}
if ($task.status -in @('running', 'stalled')) {
    # The process is gone but the watcher has not said how the run ended. A
    # follow-up now would bury that outcome under the next run.
    throw "Task $Id has exited but the watcher has not reported its outcome yet (status '$($task.status)'). Wait for its wake, then send."
}

$followUps = @(Get-TaskFollowUps $task)
$number = $followUps.Count + 1
$arguments = @(Get-TaskMemberArguments $task -Resume)

# The message goes to the member on stdin, like the briefing did.
$messageFile = Join-Path $paths.State "$Id-followup-$number.md"
Set-Content -LiteralPath $messageFile -Value $Message -Encoding utf8

# Mark the follow-up in the log, on a line of its own, and note where the
# resumed run's output begins: the log still holds the earlier runs' result
# events, and the watcher must not read one of those as this run's.
$marker = [ordered]@{
    type    = 'deputy'
    subtype = 'follow_up'
    number  = $number
    at      = (Get-Date -Format o)
    message = $Message
} | ConvertTo-Json -Compress
$prefix = ''
if ((Test-Path -LiteralPath $task.stdoutLog) -and -not (Test-FileEndsWithNewline $task.stdoutLog)) { $prefix = "`n" }
[System.IO.File]::AppendAllText($task.stdoutLog, $prefix + $marker + "`n")
$logOffset = (Get-Item -LiteralPath $task.stdoutLog).Length

$launched = Start-MemberProcess -TaskId $Id -Arguments $arguments -WorkingDirectory $task.worktree `
    -StdinFile $messageFile -StdoutLog $task.stdoutLog -StderrLog $task.stderrLog

$previousStatus = $task.status
$now = Get-Date -Format o
Set-TaskField $task 'followUps' @($followUps + [pscustomobject]@{
        number      = $number
        at          = $now
        afterStatus = $previousStatus
        pid         = $launched.ProcessId
        message     = $Message
    })
Set-TaskField $task 'pid' $launched.ProcessId
Set-TaskField $task 'pidStartedAt' $launched.StartedAt
Set-TaskField $task 'status' 'running'
Set-TaskField $task 'endedAt' $null
Set-TaskField $task 'logOffset' $logOffset
Set-TaskField $task 'lastLogBytes' $logOffset
Set-TaskField $task 'lastActivityAt' $now
Set-TaskField $task 'stallNotified' $false

# Whatever the gate said, it said about a branch the member is about to change.
$hadVerdict = [bool](Get-EventField $task 'validation')
foreach ($stale in 'validation', 'validationNote', 'validationError', 'validationEvidence', 'validatedHead') {
    if ($task.PSObject.Properties[$stale]) { Set-TaskField $task $stale $null }
}
Write-TaskState $task

Write-Output "sent follow-up #$number to $Id (was $previousStatus) pid=$($launched.ProcessId)"
Write-Output "  session:  $sessionId"
Write-Output "  worktree: $($task.worktree)"
Write-Output "  log:      $($task.stdoutLog)"
if ($hadVerdict) {
    Write-Output "  The earlier gate verdict was cleared: run dep-validate.ps1 $Id again once the member is done."
}
Write-Output "Supervise with: pwsh -NoProfile -File `"$(Join-Path $paths.Bin 'dep-watch.ps1')`" -Wait"
