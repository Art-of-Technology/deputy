#Requires -Version 7.0
<#
.SYNOPSIS
Spawn a posse member: lease a treehouse worktree and launch a headless claude
session in it to work the given task.

The session gets an id Deputy chose (--session-id, recorded as sessionId in
task state) and the task id as its name, so that dep-send.ps1 can resume it
with a follow-up message once its process has exited.

.EXAMPLE
.\dep-spawn.ps1 -Task "Fix the flaky auth test" -Repo C:\src\myapp
.\dep-spawn.ps1 -Task "Why is startup slow?" -Repo C:\src\myapp -Kind scout
.\dep-spawn.ps1 -Task "Rework the cache layer" -Repo C:\src\myapp -Effort high -MaxBudgetUsd 15
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Task,

    [Parameter(Mandatory)]
    [string]$Repo,

    [ValidateSet('ship', 'scout')]
    [string]$Kind = 'ship',

    [string]$Model,

    [ValidateSet('', 'acceptEdits', 'auto', 'bypassPermissions', 'dontAsk', 'manual', 'plan')]
    [string]$PermissionMode,

    # Permission rules granted by the spawner, e.g. 'Bash(git *)','Bash(gh *)'.
    # Needed for non-bypass modes: a leased worktree is an untrusted directory,
    # so the repo's own .claude/settings.json allowlist is not honored there.
    [string[]]$AllowedTools,

    # Reasoning effort for the member (--effort). Default: the effort key in
    # config\deputy.json; when that is null too, the flag is left off.
    [ValidateSet('', 'low', 'medium', 'high', 'xhigh', 'max')]
    [string]$Effort,

    # Spending cap in USD for one run of the member (--max-budget-usd).
    # Default: the maxBudgetUsd key in config\deputy.json; null leaves it off.
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

$id = New-TaskId
if (-not $Model) { $Model = $config.model }
if (-not $PermissionMode) { $PermissionMode = $config.permissionMode }
# The config's values go into variables of their own: $Effort and $MaxBudgetUsd
# are typed parameters, and a bad config value assigned to one of them fails
# with a message about a variable instead of about the config.
$memberEffort = $Effort ? $Effort : $config.effort
$memberBudget = ($null -ne $MaxBudgetUsd) ? $MaxBudgetUsd : $config.maxBudgetUsd

# What the member is launched with. It goes into task state as it is, because
# dep-send.ps1 has to start a resumed run with the same settings. Building the
# arguments here, before anything is leased, also means a bad effort level or
# budget costs no worktree.
$sessionId = [guid]::NewGuid().ToString()
$member = [pscustomobject]@{
    id             = $id
    kind           = $Kind
    sessionId      = $sessionId
    model          = $Model
    permissionMode = $PermissionMode
    allowedTools   = @($AllowedTools | Where-Object { $_ })
    effort         = $memberEffort ? "$memberEffort" : $null
    maxBudgetUsd   = $memberBudget
}
$claudeArgs = @(Get-TaskMemberArguments $member)

# Lease a worktree. The treehouse pool is per-repo, so run from inside it.
Push-Location $repoPath
try {
    $leaseRaw = treehouse get --lease --json --lease-holder "deputy:$id" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $leaseRaw) {
        throw "treehouse failed to lease a worktree for '$repoPath' (exit $LASTEXITCODE)."
    }
    $lease = ($leaseRaw -join "`n") | ConvertFrom-Json
}
finally { Pop-Location }

# Branch name for ship tasks
$slug = ($Task.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
if (-not $slug) { $slug = $id }  # all-punctuation task: 'deputy/' alone is not a valid ref
$branch = '{0}{1}' -f $config.branchPrefix, $slug

$projProfile = Get-ProjectProfile $repoPath
$delivery = if ($Kind -eq 'ship') { $projProfile.delivery } else { $null }

# Briefing prompt, delivered via stdin to avoid argument quoting issues
if ($Kind -eq 'ship' -and $delivery -eq 'no-mistakes') {
    $briefing = @"
You are a posse member reporting to the Deputy. Assignment kind: ship (deliver working code).

Task:
$Task

Ground rules:
- You are in a leased git worktree at $($lease.path), on a detached HEAD of the default branch. Work only inside this worktree.
- First create and switch to a branch named: $branch
- Implement the task with quality. Run the repo's relevant tests and lint before finishing, and fix failures you cause.
- Commit all your work with clear messages. Never add co-author lines.
- Do NOT push and do NOT open a pull request. This repo uses the Deputy's no-mistakes gate: after you finish, the Deputy validates your branch and publishes it. Leave the worktree checked out on your branch with a clean status.
- If you are blocked or the task turns out to be wrong or impossible, stop and say so clearly instead of guessing.

$(Get-MemberReportInstructions)
"@
}
elseif ($Kind -eq 'ship') {
    $briefing = @"
You are a posse member reporting to the Deputy. Assignment kind: ship (deliver working code).

Task:
$Task

Ground rules:
- You are in a leased git worktree at $($lease.path), on a detached HEAD of the default branch. Work only inside this worktree.
- First create and switch to a branch named: $branch
- Implement the task with quality. Run the repo's relevant tests and lint before finishing, and fix failures you cause.
- Commit with clear messages. Never add co-author lines.
- Push the branch and open a pull request with gh (for example: gh pr create --title "..." --body "..."). If the repo has no remote you can push to, commit locally and say so in your report.
- If you are blocked or the task turns out to be wrong or impossible, stop and say so clearly instead of guessing.

$(Get-MemberReportInstructions -PullRequest)
"@
}
else {
    $reportPath = Join-Path $paths.State "$id-report.md"
    $briefing = @"
You are a posse member reporting to the Deputy. Assignment kind: scout (investigate and report, change nothing).

Task:
$Task

Ground rules:
- You are in a leased read-only-by-convention git worktree at $($lease.path). Do not modify files in the repo, do not commit, do not open PRs.
- Investigate thoroughly: read code, run read-only commands, trace the answer.
- Write your full report as markdown to this exact path: $reportPath

$(Get-MemberReportInstructions)
For a scout, summary holds the key findings in a few sentences; the full report is the file at the path above.
"@
}

$briefingFile = Join-Path $paths.State "$id-briefing.md"
Set-Content -Path $briefingFile -Value $briefing -Encoding utf8

$stdoutLog = Join-Path $paths.Logs "$id.jsonl"
$stderrLog = Join-Path $paths.Logs "$id.err.log"

$launched = Start-MemberProcess -TaskId $id -Arguments $claudeArgs -WorkingDirectory $lease.path `
    -StdinFile $briefingFile -StdoutLog $stdoutLog -StderrLog $stderrLog
$state = [pscustomobject]@{
    id             = $id
    kind           = $Kind
    task           = $Task
    repo           = $repoPath
    worktree       = $lease.path
    leaseId        = $lease.lease_id
    branch         = if ($Kind -eq 'ship') { $branch } else { $null }
    delivery       = $delivery
    validation     = $null
    pid            = $launched.ProcessId
    pidStartedAt   = $launched.StartedAt
    sessionId      = $sessionId
    model          = $Model
    permissionMode = $PermissionMode
    allowedTools   = $member.allowedTools
    effort         = $member.effort
    maxBudgetUsd   = $member.maxBudgetUsd
    status         = 'running'
    result         = $null
    prUrl          = $null
    stdoutLog      = $stdoutLog
    stderrLog      = $stderrLog
    briefing       = $briefingFile
    spawnedAt      = (Get-Date -Format o)
    endedAt        = $null
    lastLogBytes   = 0
    lastActivityAt = (Get-Date -Format o)
    stallNotified  = $false
    # Where the current run's output starts in the log. dep-send.ps1 moves it
    # forward, so the watcher never reads an earlier run's result as this one's.
    logOffset      = 0
    followUps      = @()
    report         = $null
    totalCostUsd   = $null
    numTurns       = $null
    durationMs     = $null
}
Write-TaskState $state

Write-Output ("spawned $id ($Kind{0}) pid=$($launched.ProcessId)" -f ($delivery ? ", $delivery" : ''))
Write-Output "  repo:     $repoPath"
Write-Output "  worktree: $($lease.path)"
if ($Kind -eq 'ship') { Write-Output "  branch:   $branch" }
Write-Output "  log:      $stdoutLog"
Write-Output "  session:  $sessionId"
Write-Output "Supervise with: pwsh -NoProfile -File `"$(Join-Path $paths.Bin 'dep-watch.ps1')`" -Wait"
