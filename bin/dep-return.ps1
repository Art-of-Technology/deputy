#Requires -Version 7.0
<#
.SYNOPSIS
Tear down a posse task: stop any lingering process, return the leased
worktree to the treehouse pool, delete the task branch (local and remote,
best effort), and archive the task state.

The lease return is guarded with --if-lease-id so a stale task record can
never release a worktree that has since been re-leased by someone else.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Id
)

. "$PSScriptRoot\dep-lib.ps1"
Initialize-Deputy
$paths = Get-DeputyPaths
$task = Read-TaskState $Id

# Only pids proven to belong to this task are killed (see Test-TaskOwnsProcess):
# a recycled member pid, or a process treehouse mislists, is left alone.
$stopped = @(Stop-TaskProcesses $task)
if ($stopped.Count -gt 0) {
    Write-Output "stopped live process tree(s) (pid $($stopped -join ', '))"
}

if ($task.worktree -and (Test-Path $task.worktree)) {
    treehouse return $task.worktree --if-lease-id $task.leaseId --force 2>&1 |
        ForEach-Object { Write-Output "  $_" }
    if ($LASTEXITCODE -ne 0) {
        throw "treehouse return failed for $($task.worktree). Inspect with 'treehouse status' and return it manually."
    }
    Write-Output "worktree returned to pool: $($task.worktree)"
}
else {
    Write-Output "worktree already gone: $($task.worktree)"
}

# Branch cleanup is best effort: the local branch usually only existed in the
# worktree, and the remote branch may already be gone (or never pushed).
if ($task.branch) {
    $head = git -C $task.repo branch --show-current 2>$null
    if ($head -eq $task.branch) {
        Write-Output "skipped branch cleanup: $($task.branch) is checked out in $($task.repo)"
    }
    else {
        git -C $task.repo branch -D $task.branch *> $null
        if ($LASTEXITCODE -eq 0) { Write-Output "deleted local branch: $($task.branch)" }
        else { Write-Output "local branch not present, nothing to delete: $($task.branch)" }

        git -C $task.repo push origin --delete $task.branch *> $null
        if ($LASTEXITCODE -eq 0) { Write-Output "deleted remote branch: origin/$($task.branch)" }
        else { Write-Output "remote branch not deleted (already gone, never pushed, or no origin): $($task.branch)" }
    }
}

Set-TaskField $task 'finalStatus' $task.status
Set-TaskField $task 'status' 'returned'
Set-TaskField $task 'returnedAt' (Get-Date -Format o)
Write-TaskState $task

# Archive state and briefing; logs stay in logs\ for the record
Move-Item -Force (Get-TaskStatePath $Id) (Join-Path $paths.Archive "$Id.json")
if (Test-Path $task.briefing) {
    Move-Item -Force $task.briefing (Join-Path $paths.Archive "$Id-briefing.md")
}

Write-Output "archived $Id (final status: $($task.finalStatus))"
