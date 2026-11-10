#Requires -Version 7.0
<#
.SYNOPSIS
Tear down a posse task: stop any lingering process, return the leased
worktree to the treehouse pool, delete the task branch (local and remote,
best effort), and archive the task state.

Returning a worktree resets it and deleting a branch cannot be taken back, so
this script proves the work landed before it touches anything, and refuses
(exit 1, with the reason) when it cannot. The proof is Test-TaskLanded in
dep-lib.ps1:

- a ship task's worktree is clean, untracked files included, and either every
  commit ahead of the default branch is on a remote-tracking branch after a
  fetch, or its pull request is merged and contains the local work (the PR's
  head contains the local HEAD, or the local tree is identical to the up-to-date
  default branch, which is what a squash merge leaves);
- a scout task's report file exists.

-Discard overrides a refusal and throws the unlanded work away. It needs the
Sheriff's explicit word, every time: it is the one way this script destroys
work.

The remote branch is never deleted while the task's pull request is open - not
with -Discard either - or while the PR cannot be read, and it is kept when it
is the only place the commits exist.

The lease return is guarded with --if-lease-id so a stale task record can
never release a worktree that has since been re-leased by someone else.

.EXAMPLE
.\dep-return.ps1 posse-20260729-114756-thv
.\dep-return.ps1 posse-20260729-114756-thv -Discard   # only on the Sheriff's explicit word
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Id,

    # Return the task although its work has not landed. The Sheriff's call.
    [switch]$Discard
)

. "$PSScriptRoot\dep-lib.ps1"
Initialize-Deputy
$paths = Get-DeputyPaths
$task = Read-TaskState $Id

# Before anything irreversible: has the work landed?
$verdict = Test-TaskLanded $task
if (-not $verdict.Landed) {
    if (-not $Discard) {
        Write-Output "REFUSED to return ${Id}: its work has not landed. $($verdict.Reason)"
        Write-Output 'Nothing was changed: the worktree, the branches and the task record are as they were.'
        if ($task.kind -eq 'ship') {
            Write-Output "To keep the work: publish it (dep-validate.ps1 $Id, then dep-publish.ps1 $Id), or have the member commit what is loose (dep-send.ps1 $Id)."
        }
        Write-Output "To throw it away - only on the Sheriff's explicit word: dep-return.ps1 $Id -Discard"
        exit 1
    }
    Write-Output "DISCARDING unlanded work of $Id (-Discard): $($verdict.Reason)"
}
else {
    Write-Output "landed: $($verdict.Reason)"
}

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

        # An open pull request lives on its remote branch: deleting the branch
        # closes the PR, so that is never done here, whatever the flags. The
        # other reason to keep it (the branch is the only copy of the commits)
        # is exactly what -Discard gives up.
        $prUndecided = $verdict.PrState -in @('open', 'unknown')
        if ($verdict.KeepRemoteBranch -and ($prUndecided -or -not $Discard)) {
            Write-Output "kept remote branch origin/$($task.branch): $($verdict.KeepRemoteReason)"
        }
        else {
            git -C $task.repo push origin --delete $task.branch *> $null
            if ($LASTEXITCODE -eq 0) { Write-Output "deleted remote branch: origin/$($task.branch)" }
            else { Write-Output "remote branch not deleted (already gone, never pushed, or no origin): $($task.branch)" }
        }
    }
}

Set-TaskField $task 'finalStatus' $task.status
Set-TaskField $task 'status' 'returned'
Set-TaskField $task 'returnedAt' (Get-Date -Format o)
# What the teardown stood on: the proof, or the fact that there was none.
Set-TaskField $task 'landed' $verdict.Landed
Set-TaskField $task 'landedReason' $verdict.Reason
if (-not $verdict.Landed) { Set-TaskField $task 'discarded' $true }
Write-TaskState $task

# Archive state and briefing; logs stay in logs\ for the record
Move-Item -Force (Get-TaskStatePath $Id) (Join-Path $paths.Archive "$Id.json")
$briefing = [string](Get-EventField $task 'briefing')
if ($briefing -and (Test-Path -LiteralPath $briefing)) {
    Move-Item -Force $briefing (Join-Path $paths.Archive "$Id-briefing.md")
}
# So do the follow-up messages dep-send.ps1 wrote for it
Get-ChildItem -Path $paths.State -Filter "$Id-followup-*.md" -File -ErrorAction SilentlyContinue |
    ForEach-Object { Move-Item -Force $_.FullName (Join-Path $paths.Archive $_.Name) }

Write-Output "archived $Id (final status: $($task.finalStatus))"
