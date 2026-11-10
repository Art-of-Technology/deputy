#Requires -Version 7.0
<#
.SYNOPSIS
Publish a validated ship task: push its branch and open the PR - or, when the
task already has a PR, push the branch's new validated commits to it.

In no-mistakes delivery the posse member never pushes or talks to GitHub;
publishing is the Deputy's deterministic step, and it refuses to run unless
dep-validate.ps1 has marked the task validation=passed for the commit the
branch is at now.

A task whose gate had no commands to run is validation=unverified: nothing
about the branch is proven, so publishing is refused too. -AllowUnverified
overrides that, and is only for the Sheriff's explicit approval: the PR body
then says in plain text that the branch was never validated.

The first publish records the PR's number and the commit it was opened at
(`prNumber`, `prHead`) in task state. That head is what dep-pr.ps1 merge later
insists the PR is still at.

Publishing again is how a follow-up reaches a PR that is already open: after
dep-send.ps1 the member changed the branch and the gate verdict was cleared, so
run dep-validate.ps1 again and then this script. It pushes the new commits to
the same PR (a plain push, never a force), rewrites the PR body with the new
summary and gate verdict, and moves the recorded `prHead` to the new commit. It
refuses when the PR is no longer open, and does nothing when the PR is already
at the branch's head.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Id,

    # Sheriff-approved escape hatch for repos with no gate. Never self-serve.
    [switch]$AllowUnverified
)

. "$PSScriptRoot\dep-lib.ps1"
Initialize-Deputy
$task = Read-TaskState $Id

function Save-Publish([System.Collections.IDictionary]$Fields) {
    # Record what this publish established. Only these fields, under the state
    # lock, onto the record as it is on disk now: the push and the GitHub calls
    # take seconds, and the watcher may have written to the record meanwhile.
    if (-not (Update-TaskState $Id $Fields)) { throw "Task $Id has no active record left to write to." }
}

if ($task.kind -ne 'ship') { throw "dep-publish only applies to ship tasks; $Id is '$($task.kind)'." }
if (-not (Test-Path $task.worktree)) { throw "Worktree gone: $($task.worktree)." }
if (Get-EventField $task 'mergedAt') {
    throw "Task $Id is already merged ($($task.prUrl)). There is nothing left to publish to."
}

$validation = if ($task.PSObject.Properties['validation']) { $task.validation } else { $null }
$validationNote = if ($task.PSObject.Properties['validationNote']) { $task.validationNote } else { $null }
$unverified = ($validation -eq 'unverified')
if ($unverified -and -not $AllowUnverified) {
    throw ("Refusing to publish: the gate for task $Id ran nothing (validation 'unverified'" +
        $(if ($validationNote) { " - $validationNote" }) + "). Nothing about this branch is verified. " +
        "Pin gate commands for this repo in config\projects.json and re-run dep-validate.ps1 $Id, or - " +
        'with the Sheriff explicitly approving an unverified merge - re-run with -AllowUnverified.')
}
if (-not $unverified -and $validation -ne 'passed') {
    throw "Refusing to publish: task $Id has validation state '$validation'. Run dep-validate.ps1 $Id first."
}

$wt = $task.worktree
$head = (git -C $wt rev-parse --verify --quiet 'HEAD^{commit}' 2>$null | Out-String).Trim()
if (-not $head) { throw "Cannot resolve HEAD in $wt." }

# The verdict is about one commit. If the branch has moved since, it is a
# verdict about something else.
$validatedHead = [string](Get-EventField $task 'validatedHead')
if ($validatedHead -and $validatedHead -ne $head) {
    throw ("Refusing to publish: the branch is at $(Format-Sha $head), but the gate judged $(Format-Sha $validatedHead). " +
        "Run dep-validate.ps1 $Id again.")
}
if ($unverified) {
    Write-Output "WARNING: publishing $Id with an UNVERIFIED gate (-AllowUnverified). Nothing was run against this branch."
}

function Get-PrBody {
    $evidenceNote = if ($unverified) {
        "**NOT VALIDATED.** The Deputy's no-mistakes gate had no commands to run for this repo" +
        $(if ($validationNote) { " ($validationNote)" }) +
        ', so no tests and no lint were executed against this branch. Review it on that basis.'
    } elseif ($task.PSObject.Properties['validationEvidence'] -and $task.validationEvidence) {
        "Validated by the Deputy no-mistakes gate; evidence at ``$($task.validationEvidence)`` on this branch."
    } else {
        'Published by Deputy.'
    }
    $summary = if ($task.PSObject.Properties['result'] -and $task.result) {
        $task.result
    } else {
        Get-FirstSentence $task.task
    }
    @"
## Summary

$summary

## Briefing

<details><summary>Full task briefing</summary>

$($task.task)

</details>

---

$evidenceNote

Posse task: $Id
"@
}

if ($task.prUrl) {
    # The task already has a PR: bring it up to the branch's validated head.
    $ref = Get-TaskPrRef $task
    if (-not $ref) { throw "Task $Id records '$($task.prUrl)' as its PR, which is not a GitHub pull request URL." }
    $pr = Get-PullRequest $ref
    if (-not $pr.Ok) {
        throw "Pull request #$($ref.Number) could not be read ($($pr.Error)), so it is not known to be open. Nothing was pushed."
    }
    if ($pr.State -ne 'open') {
        throw "Pull request #$($ref.Number) is $($pr.State), not open. Nothing was pushed."
    }
    if ($pr.HeadSha -eq $head) {
        Save-Publish ([ordered]@{ prNumber = $ref.Number; prHead = $head; prClosedAt = $null })
        Write-Output "nothing to push: PR #$($ref.Number) is already at $head"
        Write-Output "  pr:     $($task.prUrl)"
        exit 0
    }

    git -C $wt push origin $task.branch 2>&1 | ForEach-Object { Write-Output "  $_" }
    if ($LASTEXITCODE -ne 0) {
        throw "git push failed for branch '$($task.branch)'. Nothing was recorded; PR #$($ref.Number) is still at $(Format-Sha $pr.HeadSha)."
    }

    Save-Publish ([ordered]@{
            prNumber            = $ref.Number
            prHead              = $head
            # A fresh head: give its checks one poll interval before the watcher reads them.
            prCheckedAt         = (Get-Date -Format o)
            # It was just read open, whatever an earlier poll saw.
            prClosedAt          = $null
            publishedUnverified = [bool]$unverified
        })

    # The body carries the summary and the gate verdict, and both are about
    # the head that was just replaced.
    $edit = Invoke-GhApi "$($ref.Api)/pulls/$($ref.Number)" -Method PATCH -Body ([ordered]@{ body = (Get-PrBody) })
    if (-not $edit.Ok) {
        Write-Output "WARNING: the commits were pushed, but the PR description could not be updated ($($edit.Error)). It still describes the previous head."
    }

    Write-Output "updated PR #$($ref.Number) for $Id"
    Write-Output "  branch: $($task.branch)"
    Write-Output "  head:   $(Format-Sha $pr.HeadSha) -> $head"
    Write-Output "  pr:     $($task.prUrl)"
    exit 0
}

$anchor = Resolve-DefaultRef $wt
$defaultBranch = $anchor.Branch
if (-not $defaultBranch) {
    throw "Cannot resolve the default branch of $wt to open a PR against. Is 'origin' configured?"
}

git -C $wt push -u origin $task.branch 2>&1 | ForEach-Object { Write-Output "  $_" }
if ($LASTEXITCODE -ne 0) { throw "git push failed for branch '$($task.branch)'." }

$title = Get-PrTitle -Worktree $wt -DefaultRef $anchor.Ref -Briefing $task.task
$body = Get-PrBody

Push-Location $wt
try {
    $prOut = gh pr create --base $defaultBranch --head $task.branch --title $title --body $body 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "gh pr create failed: $(Limit-Text $prOut 300)" }
}
finally { Pop-Location }

$published = [ordered]@{}
if ($prOut -match 'https://github\.com/[^\s]+/pull/\d+') {
    $published['prUrl'] = $Matches[0]
    Set-TaskField $task 'prUrl' $Matches[0]
    $ref = Get-TaskPrRef $task
    if ($ref) { $published['prNumber'] = $ref.Number }
    # The commit the PR was opened at. dep-pr.ps1 merge refuses a PR whose head
    # is anything else, until a later publish moves this on.
    $published['prHead'] = $head
    # The watcher polls the PR from here on; its first look is one interval away.
    $published['prCheckedAt'] = (Get-Date -Format o)
}
else {
    Write-Output "WARNING: gh pr create succeeded but printed no pull request URL, so no PR is recorded for ${Id}: $(Limit-Text $prOut 200)"
}
if ($unverified) { $published['publishedUnverified'] = $true }
if ($published.Count -gt 0) { Save-Publish $published }

Write-Output "published $Id"
Write-Output "  branch: $($task.branch) -> $defaultBranch"
Write-Output "  pr:     $($task.prUrl)"
Write-Output "  head:   $head"
