#Requires -Version 7.0
<#
.SYNOPSIS
Publish a validated ship task: push its branch and open the PR.

In no-mistakes delivery the posse member never pushes or talks to GitHub;
publishing is the Deputy's deterministic step, and it refuses to run unless
dep-validate.ps1 has marked the task validation=passed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Id
)

. "$PSScriptRoot\dep-lib.ps1"
Initialize-Deputy
$task = Read-TaskState $Id

if ($task.kind -ne 'ship') { throw "dep-publish only applies to ship tasks; $Id is '$($task.kind)'." }
if (-not (Test-Path $task.worktree)) { throw "Worktree gone: $($task.worktree)." }
if ($task.prUrl) { throw "Task $Id already has a PR: $($task.prUrl)" }

$validation = if ($task.PSObject.Properties['validation']) { $task.validation } else { $null }
if ($validation -ne 'passed') {
    throw "Refusing to publish: task $Id has validation state '$validation'. Run dep-validate.ps1 $Id first."
}

$wt = $task.worktree
$defaultBranch = Get-DefaultBranch $wt

git -C $wt push -u origin $task.branch 2>&1 | ForEach-Object { Write-Output "  $_" }
if ($LASTEXITCODE -ne 0) { throw "git push failed for branch '$($task.branch)'." }

$title = Limit-Text $task.task 70
$evidenceNote = if ($task.PSObject.Properties['validationEvidence'] -and $task.validationEvidence) {
    "Validated by the Deputy no-mistakes gate; evidence at ``$($task.validationEvidence)`` on this branch."
} else {
    'Published by Deputy.'
}
$body = @"
$($task.task)

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
Write-TaskState $task

Write-Output "published $Id"
Write-Output "  branch: $($task.branch) -> $defaultBranch"
Write-Output "  pr:     $($task.prUrl)"
