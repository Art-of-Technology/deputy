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

A gate with no commands is neither: it proves nothing, so it is recorded as
validation=unverified and dep-publish.ps1 refuses it unless the Sheriff
approves -AllowUnverified. Fix an unverified repo by pinning its commands in
config\projects.json.

Exit codes: 0 = passed, 1 = failed, 2 = unverified (nothing ran).
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

$wt = $task.worktree

# A re-run must not inherit the previous run's verdict or its explanation
foreach ($stale in 'validationNote', 'validationError', 'anchorWarning') { Set-TaskField $task $stale $null }

$anchor = Resolve-DefaultRef $wt
$projProfile = Get-ProjectProfile $task.repo
$commands = @($projProfile.validate)
$gateSource = 'configured in deputy config\projects.json'
if ($commands.Count -eq 0) {
    $commands = @(Get-AutoValidateCommands $wt $anchor.Ref)
    $gateSource = if ($anchor.Ref) {
        "auto-detected from manifests on $($anchor.Ref) ($($anchor.Source))"
    }
    else { 'auto-detection had no trusted default branch to read manifests from' }
}

# The anchor is the gate's trust root whether or not detection ran: it decides
# which ref manifests are read from, and what "ahead of the default branch"
# means. So its provenance is reported here, before the gate and independently
# of how the commands were resolved - a repo that pins its commands used to be
# the one place a stale origin/HEAD stayed invisible. Proportionate on purpose:
# a healthy anchor is recorded in the evidence only, while a stale or
# unresolved one is printed and kept in task state, because those are the cases
# that need a repo-level fix from the Sheriff.
$anchorWarning = switch ($anchor.Health) {
    'stale' {
        "$($anchor.Source). The gate anchored on $($anchor.Ref) instead. Fix it at the repo level " +
        "with: git remote set-head origin -a (in $($task.repo))"
    }
    'unresolved' {
        'could not resolve a trusted default branch for this repo (no origin/HEAD, no origin/main ' +
        'or origin/master, no local main or master), so the branch was not checked for being ahead ' +
        "of the default branch and manifests could not be read from a trusted ref (anchor: $($anchor.Source))"
    }
    default { $null }
}
if ($anchorWarning) {
    Write-Output "ANCHOR WARNING: $anchorWarning"
    Set-TaskField $task 'anchorWarning' $anchorWarning
}

function Deny-Validation([string]$Reason) {
    Set-TaskField $task 'validation' 'failed'
    Set-TaskField $task 'validationError' $Reason
    Write-TaskState $task
    Write-Output "VALIDATION FAILED: $Reason"
    exit 1
}

function Deny-Verification([string]$Reason) {
    # Nothing ran, so nothing is proven. Recorded as its own outcome: a
    # supervising agent must not be able to read this as a pass.
    Set-TaskField $task 'validation' 'unverified'
    Set-TaskField $task 'validationNote' $Reason
    Write-TaskState $task
    Write-Output "VALIDATION UNVERIFIED: $Reason"
    Write-Output 'The gate ran nothing, so nothing about this branch is verified. This is NOT a pass.'
    Write-Output "Fix: pin this repo's gate commands in config\projects.json, then re-run dep-validate.ps1 $Id."
    Write-Output 'dep-publish.ps1 refuses an unverified task unless the Sheriff approves -AllowUnverified.'
    exit 2
}

# Preconditions: the member must have left a clean, committed branch. Checked
# before the gate contents, because a dirty or empty branch is a real failure
# whether or not there are commands to run.
$currentBranch = (git -C $wt rev-parse --abbrev-ref HEAD).Trim()
if ($currentBranch -ne $task.branch) {
    Deny-Validation "worktree is on '$currentBranch', expected branch '$($task.branch)'"
}
$dirty = git -C $wt status --porcelain
if ($dirty) {
    Deny-Validation ("working tree is dirty (uncommitted changes): " + (Limit-Text ($dirty -join '; ') 200))
}
if ($anchor.Ref) {
    $commits = git -C $wt log "$($anchor.Ref)..HEAD" --oneline 2>$null
    if (-not $commits) {
        Deny-Validation "no commits on '$($task.branch)' ahead of $($anchor.Ref)"
    }
}

if ($commands.Count -eq 0) {
    if ($anchor.Ref) {
        Deny-Verification ("no gate commands are configured for this repo in config\projects.json, " +
            "and none could be detected from the manifests on $($anchor.Ref)")
    }
    else {
        Deny-Verification ('no gate commands are configured for this repo in config\projects.json, ' +
            'and no trusted default branch could be resolved (no origin/HEAD, no origin/main or ' +
            'origin/master, no local main or master), so manifests could not be read at all')
    }
}
Write-Output "gate ($gateSource): $($commands -join '; ')"

# Environmental setup: JS gates need node_modules in the (possibly recycled)
# worktree. Only install when the manifest actually declares dependencies,
# so bare-bones repos do not grow an unexpected package-lock.json.
$setupResults = @()
$needsNode = @($commands | Where-Object { $_ -match '^(npm|pnpm|yarn)\b' }).Count -gt 0
if ($needsNode -and (Test-Path (Join-Path $wt 'package.json')) -and -not (Test-Path (Join-Path $wt 'node_modules'))) {
    $pkg = try { Get-Content (Join-Path $wt 'package.json') -Raw | ConvertFrom-Json } catch { $null }
    $hasDeps = $pkg -and (
        ($pkg.PSObject.Properties['dependencies'] -and @($pkg.dependencies.PSObject.Properties).Count -gt 0) -or
        ($pkg.PSObject.Properties['devDependencies'] -and @($pkg.devDependencies.PSObject.Properties).Count -gt 0)
    )
    if ($hasDeps) {
        $install = if (Test-Path (Join-Path $wt 'pnpm-lock.yaml')) { 'pnpm install --frozen-lockfile' }
                   elseif (Test-Path (Join-Path $wt 'yarn.lock')) { 'yarn install --frozen-lockfile' }
                   elseif (Test-Path (Join-Path $wt 'package-lock.json')) { 'npm ci' }
                   else { 'npm install' }
        Write-Output "setup: $install"
        Push-Location $wt
        try {
            $setupOut = pwsh -NoProfile -Command $install 2>&1 | Out-String
            $setupExit = $LASTEXITCODE
        }
        finally { Pop-Location }
        $setupResults += [pscustomobject]@{ command = "(setup) $install"; exit = $setupExit; passed = ($setupExit -eq 0); output = $setupOut.Trim() }
        if ($setupExit -ne 0) {
            Deny-Validation ("environment setup failed (not a code problem): '$install' exit ${setupExit}: " + (Limit-Text $setupOut 300))
        }
    }
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
    "- gate source: $gateSource"
    "- default-branch anchor: $($anchor.Ref ? "$($anchor.Ref) ($($anchor.Source))" : $anchor.Source)"
    "- verdict: $($allPassed ? 'PASSED' : 'FAILED')"
    $(if ($anchorWarning) { "- anchor warning: $anchorWarning" })
    ''
    '| command | exit | result |'
    '| --- | --- | --- |'
)
foreach ($r in @($setupResults + $results)) {
    $lines += "| ``$($r.command)`` | $($r.exit) | $($r.passed ? 'PASS' : 'FAIL') |"
}
foreach ($r in @($setupResults + $results)) {
    # Redact before truncating so a cut cannot split a secret past the patterns
    $lines += @('', "## Output: ``$($r.command)``", '', '```', (Limit-Text (Remove-Secret $r.output) 2000), '```')
}
$evidence = $lines -join "`n"

if ($allPassed) {
    # Commit evidence to the branch so it is reviewable on the PR
    $evidenceDir = Join-Path $wt '.deputy\evidence'
    New-Item -ItemType Directory -Force $evidenceDir | Out-Null
    $evidenceFile = Join-Path $evidenceDir "$Id.md"
    Set-Content -Path $evidenceFile -Value $evidence -Encoding utf8
    git -C $wt add '.deputy/evidence' 2>&1 | Out-Null
    git -C $wt commit -m (New-EvidenceCommitMessage $Id) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Deny-Validation 'failed to commit validation evidence' }

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
    Deny-Validation $summary
}
