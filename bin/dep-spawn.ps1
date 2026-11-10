#Requires -Version 7.0
<#
.SYNOPSIS
Spawn a posse member: lease a treehouse worktree and launch a headless claude
session in it to work the given task.

What is settled here, before the member starts, so that it cannot go wrong
later:

- A ship task's branch is <branchPrefix><taskId>, unique per task, and the
  lease creates it (treehouse get -b): the member starts on it and is told not
  to switch. A scout gets a detached worktree.
- -BaseBranch cuts the worktree from that branch (treehouse get --base) and is
  kept as baseBranch in task state; dep-validate.ps1, dep-publish.ps1 and
  dep-return.ps1 then measure the work against it instead of the default
  branch. Without it, a lease that treehouse cut from another branch than the
  default (a pool configured with base_branch) records that branch the same
  way, so the work is never measured against a branch it was not cut from.
- The lease must be a git worktree of its own and not the repository's own
  checkout (Get-LeaseProblems). Otherwise nothing is launched, and the lease is
  given back.
- The member is launched isolated from the operator's MCP servers, skills and
  slash commands unless memberIsolation is off in the config; what it was
  launched with is recorded, so a resumed run gets the same.
- The model and effort are chosen here, once (Resolve-MemberSettings): -Model
  and -Effort, else the repo's project profile, else the per-kind default in
  the config (models.<kind>, effort.<kind>), else the flag is left off and the
  member runs on the account default. Both are recorded with where they came
  from, and a resumed run reuses them, so a follow-up cannot change the model.
- A lease that is given back because nothing was launched in it takes its new
  branch with it. If the branch is still there afterwards, that is said, with
  the command that removes it.

The session gets an id Deputy chose (--session-id, recorded as sessionId in
task state) and the task id as its name, so that dep-send.ps1 can resume it
with a follow-up message once its process has exited.

.EXAMPLE
.\dep-spawn.ps1 -Task "Fix the flaky auth test" -Repo C:\src\myapp
.\dep-spawn.ps1 -Task "Why is startup slow?" -Repo C:\src\myapp -Kind scout
.\dep-spawn.ps1 -Task "Backport the session fix" -Repo C:\src\myapp -BaseBranch release/2.4
.\dep-spawn.ps1 -Task "Rework the cache layer" -Repo C:\src\myapp -Effort high -MaxBudgetUsd 15
.\dep-spawn.ps1 -Task "Fix the typo in the README" -Repo C:\src\myapp -Model claude-sonnet-5-5
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Task,

    [Parameter(Mandatory)]
    [string]$Repo,

    [ValidateSet('ship', 'scout')]
    [string]$Kind = 'ship',

    # The branch to cut the worktree from, when the work does not belong on
    # the default branch (a release branch, another task's branch). The gate
    # anchors on it and the pull request targets it.
    [string]$BaseBranch,

    # The model for the member (--model). Default: the repo's project profile,
    # else models.<kind> in the config; when neither names one, the flag is left
    # off and the member runs on the account default.
    [string]$Model,

    [ValidateSet('', 'acceptEdits', 'auto', 'bypassPermissions', 'dontAsk', 'manual', 'plan')]
    [string]$PermissionMode,

    # Permission rules granted by the spawner, e.g. 'Bash(git *)','Bash(gh *)'.
    # Needed for the modes other than bypassPermissions: a headless member
    # cannot answer a prompt, so whatever is neither granted nor allowed by the
    # mode is denied (see README, "Permissions for posse members").
    [string[]]$AllowedTools,

    # Reasoning effort for the member (--effort). Default: the repo's project
    # profile, else effort.<kind> in the config; when neither names one, the
    # flag is left off.
    [ValidateSet('', 'low', 'medium', 'high', 'xhigh', 'max')]
    [string]$Effort,

    # Spending cap in USD for one run of the member (--max-budget-usd).
    # Default: the maxBudgetUsd key in the config; null leaves it off.
    [Nullable[double]]$MaxBudgetUsd
)

. "$PSScriptRoot\dep-lib.ps1"
Initialize-Deputy
$config = Get-DeputyConfig
$paths = Get-DeputyPaths

$repoPath = (Resolve-Path $Repo).Path
git -C $repoPath rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) { throw "'$repoPath' is not a git repository." }

# Never lease from a treehouse Deputy cannot trust: the same check dep-doctor.ps1
# reports, enforced here before anything is leased or launched.
$treehouseProblems = @(Get-TreehouseProblems)
if ($treehouseProblems.Count -gt 0) {
    throw ("Refusing to lease a worktree: treehouse is not fit for use.`n  " +
        ($treehouseProblems -join "`n  ") + "`nRun dep-doctor.ps1 for the full toolchain check.")
}

# Everything that can be refused is checked before anything is leased: a bad
# value must not cost a worktree.
if ($BaseBranch -and -not (Test-BranchName $BaseBranch)) {
    throw "-BaseBranch '$BaseBranch' is not a valid branch name."
}
$id = New-TaskId
$branch = if ($Kind -eq 'ship') { Get-TaskBranchName $config.branchPrefix $id } else { $null }
$projProfile = Get-ProjectProfile $repoPath
$delivery = if ($Kind -eq 'ship') { $projProfile.delivery } else { $null }
if ($config.memberIsolation -isnot [bool]) {
    throw "memberIsolation in the config must be true or false, not '$($config.memberIsolation)'."
}

$legacyWarning = Get-LegacyConfigWarning $config
if ($legacyWarning) { Write-Warning $legacyWarning }
$chosen = Resolve-MemberSettings -Kind $Kind -Model $Model -Effort $Effort -Config $config -Project $projProfile
if (-not $PermissionMode) { $PermissionMode = $config.permissionMode }
# The config's value goes into a variable of its own: $MaxBudgetUsd is a typed
# parameter, and a bad config value assigned to it fails with a message about a
# variable instead of about the config.
$memberBudget = ($null -ne $MaxBudgetUsd) ? $MaxBudgetUsd : $config.maxBudgetUsd

# What the member is launched with. It goes into task state as it is, because
# dep-send.ps1 has to start a resumed run with the same settings.
$sessionId = [guid]::NewGuid().ToString()
$member = [pscustomobject]@{
    id              = $id
    kind            = $Kind
    sessionId       = $sessionId
    model           = $chosen.model
    permissionMode  = $PermissionMode
    allowedTools    = @($AllowedTools | Where-Object { $_ })
    memberIsolation = $config.memberIsolation
    effort          = $chosen.effort
    maxBudgetUsd    = $memberBudget
}
$claudeArgs = @(Get-TaskMemberArguments $member)

# Lease a worktree. The treehouse pool is per-repo, so run from inside it. A
# ship task's branch is created by the lease, cut from the base.
$leaseArgs = @('get', '--lease', '--json', '--lease-holder', "deputy:$id")
if ($branch) { $leaseArgs += @('-b', $branch) }
if ($BaseBranch) { $leaseArgs += @('--base', $BaseBranch) }
Push-Location $repoPath
try {
    $leaseOutput = @(treehouse @leaseArgs 2>&1)
    $leaseExit = $LASTEXITCODE
}
finally { Pop-Location }
$leaseRaw = @($leaseOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
if ($leaseExit -ne 0 -or -not ($leaseRaw -join '').Trim()) {
    $said = @($leaseOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join ' '
    throw ("treehouse failed to lease a worktree for '$repoPath' (exit $leaseExit)" + $(if ($said.Trim()) { ": $(Limit-Text $said 300)" } else { '.' }))
}
$lease = ($leaseRaw -join "`n") | ConvertFrom-Json

$launched = $null
try {
    # Isolation: the member must work in a worktree of its own, on its branch.
    $leaseProblems = @(Get-LeaseProblems -LeasePath $lease.path -RepoPath $repoPath -Branch $branch)
    if ($leaseProblems.Count -gt 0) {
        throw ("Refusing to launch a member: the lease is not an isolated worktree of its own.`n  " + ($leaseProblems -join "`n  "))
    }

    # What the worktree was cut from. Without -BaseBranch that is treehouse's
    # choice; when it is not the default branch (a pool configured with
    # base_branch), it is the task's base all the same: measuring the work
    # against the default branch would count that branch's commits as the
    # member's, and open the pull request against the wrong branch.
    $leaseBase = [string](Get-EventField $lease 'base_branch')
    $taskBase = $BaseBranch ? $BaseBranch : $null
    $baseNote = ''
    if (-not $taskBase -and $leaseBase) {
        $defaultBranch = Get-DefaultBranch $repoPath
        if ($defaultBranch -and $leaseBase -ne $defaultBranch) {
            $taskBase = $leaseBase
            $baseNote = " (treehouse cut the worktree from it; the default branch is $defaultBranch)"
        }
    }

    $reportPath = if ($Kind -eq 'scout') { Join-Path $paths.State "$id-report.md" } else { $null }
    $briefing = Get-MemberBriefing -Kind $Kind -Task $Task -Worktree $lease.path -Delivery $delivery `
        -Branch $branch -BaseBranch ($taskBase ? $taskBase : $leaseBase) -ReportPath $reportPath

    # Delivered via stdin, to avoid argument quoting issues.
    $briefingFile = Join-Path $paths.State "$id-briefing.md"
    Set-Content -Path $briefingFile -Value $briefing -Encoding utf8

    $stdoutLog = Join-Path $paths.Logs "$id.jsonl"
    $stderrLog = Join-Path $paths.Logs "$id.err.log"
    $launched = Start-MemberProcess -TaskId $id -Arguments $claudeArgs -WorkingDirectory $lease.path `
        -StdinFile $briefingFile -StdoutLog $stdoutLog -StderrLog $stderrLog
}
catch {
    $failure = $_
    if ($launched) { throw $failure }
    # Nothing runs in the lease: give it back rather than leave it held, and
    # with it the branch it created, which carries no work.
    $returned = Undo-Lease -Lease $lease -RepoPath $repoPath
    $note = if ($returned) { "The lease was returned." }
    else {
        "The lease could NOT be returned: inspect it with 'treehouse status' in $repoPath, and return $($lease.path) by hand."
    }
    $branchNote = if ($branch) { Remove-UnusedTaskBranch -RepoPath $repoPath -Branch $branch -LeaseReturned:$returned }
    throw ("$($failure.Exception.Message)`n$note" + $(if ($branchNote) { "`n$branchNote" }))
}

$state = [pscustomobject]@{
    id              = $id
    kind            = $Kind
    task            = $Task
    repo            = $repoPath
    worktree        = $lease.path
    leaseId         = $lease.lease_id
    branch          = $branch
    # Set when the work is measured against a branch other than the default
    # branch: -BaseBranch, or the base treehouse cut a worktree from.
    baseBranch      = $taskBase
    delivery        = $delivery
    validation      = $null
    pid             = $launched.ProcessId
    pidStartedAt    = $launched.StartedAt
    sessionId       = $sessionId
    # What the member was started with, and why; a resumed run reuses both.
    # reportedModel is what the member itself says it runs on (dep-watch.ps1).
    model           = $member.model
    modelSource     = $chosen.modelSource
    reportedModel   = $null
    permissionMode  = $PermissionMode
    allowedTools    = $member.allowedTools
    memberIsolation = $member.memberIsolation
    effort          = $member.effort
    effortSource    = $chosen.effortSource
    maxBudgetUsd    = $member.maxBudgetUsd
    status          = 'running'
    result          = $null
    prUrl           = $null
    stdoutLog       = $stdoutLog
    stderrLog       = $stderrLog
    briefing        = $briefingFile
    spawnedAt       = (Get-Date -Format o)
    endedAt         = $null
    lastLogBytes    = 0
    lastActivityAt  = (Get-Date -Format o)
    stallNotified   = $false
    # Where the current run's output starts in the log. dep-send.ps1 moves it
    # forward, so the watcher never reads an earlier run's result as this one's.
    logOffset       = 0
    followUps       = @()
    report          = $null
    totalCostUsd    = $null
    numTurns        = $null
    durationMs      = $null
}
Write-TaskState $state

Write-Output ("spawned $id ($Kind{0}) pid=$($launched.ProcessId)" -f ($delivery ? ", $delivery" : ''))
Write-Output "  repo:     $repoPath"
Write-Output "  worktree: $($lease.path)"
if ($branch) { Write-Output "  branch:   $branch" }
if ($taskBase) { Write-Output "  base:     $taskBase$baseNote" }
Write-Output ('  model:    ' + $(if ($chosen.model) { "$($chosen.model) ($($chosen.modelSource))" }
        else { "account default (no -Model, no project model and no models.$Kind in the config)" }))
if ($chosen.effort) { Write-Output "  effort:   $($chosen.effort) ($($chosen.effortSource))" }
Write-Output "  log:      $stdoutLog"
Write-Output "  session:  $sessionId"
Write-Output "Supervise with: pwsh -NoProfile -File `"$(Join-Path $paths.Bin 'dep-watch.ps1')`" -Wait"
