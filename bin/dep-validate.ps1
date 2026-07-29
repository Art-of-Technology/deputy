#Requires -Version 7.0
<#
.SYNOPSIS
Run the no-mistakes validation gate for a finished ship task, in its worktree.

The gate is deterministic and Deputy-controlled: commands come from
config\projects.json, never from the repo under validation, and the posse
member is not involved. On a green run the evidence is committed to the task
branch (PR-viewable) and the task is marked validation=passed, which is what
authorizes dep-publish.ps1. On a red run the failure summary is recorded in
task state for the respawn briefing.

Exit codes: 0 = passed, 1 = failed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Id
)

. "$PSScriptRoot\dep-lib.ps1"
Initialize-Deputy
$task = Read-TaskState $Id

if ($task.kind -ne 'ship') { throw "dep-validate only applies to ship tasks; $Id is '$($task.kind)'." }
if (-not (Test-Path $task.worktree)) { throw "Worktree gone: $($task.worktree). Was the task already returned?" }

$projProfile = Get-ProjectProfile $task.repo
$commands = @($projProfile.validate)
if ($commands.Count -eq 0) {
    Write-Output "no validation commands configured for this repo; nothing to gate"
    Set-TaskField $task 'validation' 'passed'
    Write-TaskState $task
    exit 0
}

$wt = $task.worktree

function Fail-Validation([string]$Reason) {
    Set-TaskField $task 'validation' 'failed'
    Set-TaskField $task 'validationError' $Reason
    Write-TaskState $task
    Write-Output "VALIDATION FAILED: $Reason"
    exit 1
}

# Preconditions: the member must have left a clean, committed branch
$currentBranch = (git -C $wt rev-parse --abbrev-ref HEAD).Trim()
if ($currentBranch -ne $task.branch) {
    Fail-Validation "worktree is on '$currentBranch', expected branch '$($task.branch)'"
}
$dirty = git -C $wt status --porcelain
if ($dirty) {
    Fail-Validation ("working tree is dirty (uncommitted changes): " + (Limit-Text ($dirty -join '; ') 200))
}
$defaultBranch = Get-DefaultBranch $wt
$commits = git -C $wt log "origin/$defaultBranch..HEAD" --oneline 2>$null
if (-not $commits) {
    Fail-Validation "no commits on '$($task.branch)' ahead of origin/$defaultBranch"
}

# Run the gate
$results = @()
$allPassed = $true
foreach ($cmd in $commands) {
    Write-Output "validate: $cmd"
    Push-Location $wt
    try {
        $output = pwsh -NoProfile -Command $cmd 2>&1 | Out-String
        $exit = $LASTEXITCODE
    }
    finally { Pop-Location }
    $passed = ($exit -eq 0)
    if (-not $passed) { $allPassed = $false }
    Write-Output ("  -> {0} (exit {1})" -f ($passed ? 'PASS' : 'FAIL'), $exit)
    $results += [pscustomobject]@{ command = $cmd; exit = $exit; passed = $passed; output = $output.Trim() }
}

# Evidence document
$headSha = (git -C $wt rev-parse HEAD).Trim()
$lines = @(
    '# Deputy validation evidence'
    ''
    "- task: $Id"
    "- branch: $($task.branch)"
    "- validated commit: $headSha"
    "- validated at: $(Get-Date -Format o)"
    "- verdict: $($allPassed ? 'PASSED' : 'FAILED')"
    ''
    '| command | exit | result |'
    '| --- | --- | --- |'
)
foreach ($r in $results) {
    $lines += "| ``$($r.command)`` | $($r.exit) | $($r.passed ? 'PASS' : 'FAIL') |"
}
foreach ($r in $results) {
    $lines += @('', "## Output: ``$($r.command)``", '', '```', (Limit-Text $r.output 2000), '```')
}
$evidence = $lines -join "`n"

if ($allPassed) {
    # Commit evidence to the branch so it is reviewable on the PR
    $evidenceDir = Join-Path $wt '.deputy\evidence'
    New-Item -ItemType Directory -Force $evidenceDir | Out-Null
    $evidenceFile = Join-Path $evidenceDir "$Id.md"
    Set-Content -Path $evidenceFile -Value $evidence -Encoding utf8
    git -C $wt add '.deputy/evidence' 2>&1 | Out-Null
    git -C $wt commit -m "deputy: validation evidence for $Id" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail-Validation 'failed to commit validation evidence' }

    Set-TaskField $task 'validation' 'passed'
    Set-TaskField $task 'validationEvidence' ".deputy/evidence/$Id.md"
    Write-TaskState $task
    Write-Output "VALIDATION PASSED: evidence committed at .deputy/evidence/$Id.md"
    exit 0
}
else {
    $failed = @($results | Where-Object { -not $_.passed })
    $summary = ($failed | ForEach-Object { "'$($_.command)' exit $($_.exit): " + (Limit-Text $_.output 300) }) -join ' | '
    # Keep failure evidence out of the branch; record it deputy-side instead
    $stateEvidence = Join-Path (Get-DeputyPaths).State "$Id-validation.md"
    Set-Content -Path $stateEvidence -Value $evidence -Encoding utf8
    Fail-Validation $summary
}
