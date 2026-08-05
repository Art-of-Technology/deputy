#Requires -Version 7.0
<#
.SYNOPSIS
Publish a validated ship task: push its branch and open the PR.

In no-mistakes delivery the posse member never pushes or talks to GitHub;
publishing is the Deputy's deterministic step, and it refuses to run unless
dep-validate.ps1 has marked the task validation=passed.

A task whose gate had no commands to run is validation=unverified: nothing
about the branch is proven, so publishing is refused too. -AllowUnverified
overrides that, and is only for the Sheriff's explicit approval: the PR body
then says in plain text that the branch was never validated.
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

if ($task.kind -ne 'ship') { throw "dep-publish only applies to ship tasks; $Id is '$($task.kind)'." }
if (-not (Test-Path $task.worktree)) { throw "Worktree gone: $($task.worktree)." }
if ($task.prUrl) { throw "Task $Id already has a PR: $($task.prUrl)" }

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
if ($unverified) {
    Write-Output "WARNING: publishing $Id with an UNVERIFIED gate (-AllowUnverified). Nothing was run against this branch."
}

$wt = $task.worktree
$defaultBranch = Get-DefaultBranch $wt
if (-not $defaultBranch) {
    throw "Cannot resolve the default branch of $wt to open a PR against. Is 'origin' configured?"
}

git -C $wt push -u origin $task.branch 2>&1 | ForEach-Object { Write-Output "  $_" }
if ($LASTEXITCODE -ne 0) { throw "git push failed for branch '$($task.branch)'." }

function Get-FirstSentence([string]$Text) {
    if (-not $Text) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim()
    $idx = $t.IndexOf('. ')
    if ($idx -ge 0) { $t.Substring(0, $idx + 1) } else { $t }
}

$title = Limit-Text (Get-FirstSentence $task.task) 70
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
$body = @"
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

Push-Location $wt
try {
    $prOut = gh pr create --base $defaultBranch --head $task.branch --title $title --body $body 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "gh pr create failed: $(Limit-Text $prOut 300)" }
}
finally { Pop-Location }

if ($prOut -match 'https://github\.com/[^\s]+/pull/\d+') {
    Set-TaskField $task 'prUrl' $Matches[0]
}
if ($unverified) { Set-TaskField $task 'publishedUnverified' $true }
Write-TaskState $task

Write-Output "published $Id"
Write-Output "  branch: $($task.branch) -> $defaultBranch"
Write-Output "  pr:     $($task.prUrl)"
