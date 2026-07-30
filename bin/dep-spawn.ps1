#Requires -Version 7.0
<#
.SYNOPSIS
Spawn a posse member: lease a treehouse worktree and launch a headless claude
session in it to work the given task.

.EXAMPLE
.\dep-spawn.ps1 -Task "Fix the flaky auth test" -Repo C:\src\myapp
.\dep-spawn.ps1 -Task "Why is startup slow?" -Repo C:\src\myapp -Kind scout
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
    [string[]]$AllowedTools
)

. "$PSScriptRoot\dep-lib.ps1"
Initialize-Deputy
$config = Get-DeputyConfig
$paths = Get-DeputyPaths

$repoPath = (Resolve-Path $Repo).Path
git -C $repoPath rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) { throw "'$repoPath' is not a git repository." }

$id = New-TaskId
if (-not $Model) { $Model = $config.model }
if (-not $PermissionMode) { $PermissionMode = $config.permissionMode }

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

Your final message is your report to the Deputy. Keep it short: what you changed and your test results (or the blocker).
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

Your final message is your report to the Deputy. Keep it short: what you changed, test results, and the PR URL (or the blocker).
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

Your final message is your report summary to the Deputy: the key findings in a few sentences, and note that the full report is at the path above.
"@
}

$briefingFile = Join-Path $paths.State "$id-briefing.md"
Set-Content -Path $briefingFile -Value $briefing -Encoding utf8

$stdoutLog = Join-Path $paths.Logs "$id.jsonl"
$stderrLog = Join-Path $paths.Logs "$id.err.log"

$claudeArgs = @('-p', '--output-format', 'stream-json', '--verbose')
if ($Model) { $claudeArgs += @('--model', "$Model") }
if ($PermissionMode -eq 'bypassPermissions') { $claudeArgs += '--dangerously-skip-permissions' }
else {
    $claudeArgs += @('--permission-mode', $PermissionMode)
    if ($AllowedTools) { $claudeArgs += @('--allowedTools', ($AllowedTools -join ',')) }
}
# Scouts write their report into the deputy state dir, outside their worktree
if ($Kind -eq 'scout') { $claudeArgs += @('--add-dir', $paths.State) }

# Start-Process with redirected stdio needs a real executable, not a .cmd shim
$claudeCmd = Get-Command claude -ErrorAction Stop
$exe = $claudeCmd.Source
if ($exe -match '\.(cmd|bat)$') {
    $claudeArgs = @('/d', '/c', $exe) + $claudeArgs
    $exe = $env:ComSpec
}

# Start-Process joins -ArgumentList elements with spaces but does NOT quote
# them, so args containing spaces get split. Pre-quote into a single string.
$argString = ($claudeArgs | ForEach-Object {
    if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
}) -join ' '

$proc = Start-Process -FilePath $exe -ArgumentList $argString `
    -WorkingDirectory $lease.path `
    -RedirectStandardInput $briefingFile `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog `
    -WindowStyle Hidden -PassThru

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
    pid            = $proc.Id
    pidStartedAt   = $(try { $proc.StartTime.ToString('o') } catch { $null })
    model          = $Model
    permissionMode = $PermissionMode
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
}
Write-TaskState $state

Write-Output ("spawned $id ($Kind{0}) pid=$($proc.Id)" -f ($delivery ? ", $delivery" : ''))
Write-Output "  repo:     $repoPath"
Write-Output "  worktree: $($lease.path)"
if ($Kind -eq 'ship') { Write-Output "  branch:   $branch" }
Write-Output "  log:      $stdoutLog"
Write-Output "Supervise with: pwsh -NoProfile -File `"$(Join-Path $paths.Bin 'dep-watch.ps1')`" -Wait"
