#Requires -Version 7.0
<#
.SYNOPSIS
Fixtures for Deputy's tests: throwaway git repos and throwaway Deputy installs.

Everything lives in a temp directory, nothing touches the network, and the
caller is expected to remove the root in an AfterAll block.
#>

function New-TempRoot {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('dep-test-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    New-Item -ItemType Directory -Force $path | Out-Null
    (Resolve-Path $path).Path
}

function Invoke-Git {
    # git is chatty on stderr (autocrlf, branch hints); tests only care about
    # the exit code, so swallow the streams and surface failures as errors.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("git {0} failed ({1}): {2}" -f ($Arguments -join ' '), $LASTEXITCODE, ($output -join "`n"))
    }
}

function Set-RepoFile {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $full = Join-Path $Repo $Path
    $dir = Split-Path -Parent $full
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    Set-Content -Path $full -Value $Content -Encoding utf8 -NoNewline
}

function New-TestRepo {
    <#
    .SYNOPSIS
    Build a throwaway repo whose default branch holds $Files, then optionally
    branch off to $TaskBranch and mutate the files there - the shape of a posse
    worktree mid-task.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$DefaultBranch = 'main',
        [hashtable]$Files = @{},
        # Give the repo a real (local, bare) origin, as a cloned repo would have.
        [switch]$WithRemote,
        # Skip refs/remotes/origin/HEAD, as a shallow or older clone might.
        [switch]$NoOriginHead,
        [string]$TaskBranch,
        [hashtable]$TaskFiles = @{},
        [string[]]$TaskDeletes = @()
    )

    New-Item -ItemType Directory -Force $Path | Out-Null
    $Path = (Resolve-Path $Path).Path
    Invoke-Git @('init', '-q', '-b', $DefaultBranch, $Path)
    Invoke-Git @('-C', $Path, 'config', 'user.email', 'posse@example.invalid')
    Invoke-Git @('-C', $Path, 'config', 'user.name', 'Posse Test')
    Invoke-Git @('-C', $Path, 'config', 'core.autocrlf', 'false')
    Invoke-Git @('-C', $Path, 'config', 'commit.gpgsign', 'false')

    Set-RepoFile -Repo $Path -Path 'README.md' -Content "# fixture`n"
    foreach ($name in $Files.Keys) { Set-RepoFile -Repo $Path -Path $name -Content $Files[$name] }
    Invoke-Git @('-C', $Path, 'add', '-A')
    Invoke-Git @('-C', $Path, 'commit', '-q', '-m', 'default branch')

    if ($WithRemote) {
        $bare = "$Path.origin.git"
        Invoke-Git @('init', '-q', '--bare', '-b', $DefaultBranch, $bare)
        Invoke-Git @('-C', $Path, 'remote', 'add', 'origin', $bare)
        Invoke-Git @('-C', $Path, 'push', '-q', '-u', 'origin', $DefaultBranch)
        if ($NoOriginHead) {
            # push -u does not create origin/HEAD, but be explicit about it
            & git -C $Path symbolic-ref --delete refs/remotes/origin/HEAD 2>&1 | Out-Null
        }
        else {
            Invoke-Git @('-C', $Path, 'remote', 'set-head', 'origin', '-a')
        }
    }

    if ($TaskBranch) {
        Invoke-Git @('-C', $Path, 'checkout', '-q', '-b', $TaskBranch)
        foreach ($name in $TaskFiles.Keys) { Set-RepoFile -Repo $Path -Path $name -Content $TaskFiles[$name] }
        foreach ($name in $TaskDeletes) { Invoke-Git @('-C', $Path, 'rm', '-q', '-f', $name) }
        Set-RepoFile -Repo $Path -Path 'work.txt' -Content "task work`n"
        Invoke-Git @('-C', $Path, 'add', '-A')
        Invoke-Git @('-C', $Path, 'commit', '-q', '-m', 'task work')
    }

    $Path
}

function New-DeputyInstall {
    <#
    .SYNOPSIS
    A throwaway copy of the Deputy toolbelt with its own config and state, so
    end-to-end runs never write to the real installation's state\ or logs\.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SourceRoot,
        [string]$Match,
        [string[]]$Validate = @()
    )
    New-Item -ItemType Directory -Force (Join-Path $Path 'config') | Out-Null
    Copy-Item -Recurse -Force (Join-Path $SourceRoot 'bin') (Join-Path $Path 'bin')
    $projects = [ordered]@{
        default  = [ordered]@{ delivery = 'no-mistakes'; validate = @() }
        projects = @(
            if ($Match) { [ordered]@{ match = $Match; delivery = 'no-mistakes'; validate = $Validate } }
        )
    }
    ($projects | ConvertTo-Json -Depth 6) |
        Set-Content -Path (Join-Path $Path 'config' 'projects.json') -Encoding utf8
    (Resolve-Path $Path).Path
}

function New-TestTaskState {
    <#
    .SYNOPSIS
    Register a finished ship task in a throwaway Deputy install's state dir.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Branch,
        [string]$Id = 'posse-20260101-120000-abc',
        [string]$Task = 'test task'
    )
    $stateDir = Join-Path $InstallRoot 'state'
    New-Item -ItemType Directory -Force $stateDir | Out-Null
    $state = [ordered]@{
        id         = $Id
        kind       = 'ship'
        task       = $Task
        repo       = $Repo
        worktree   = $Worktree
        branch     = $Branch
        delivery   = 'no-mistakes'
        validation = $null
        status     = 'completed'
        spawnedAt  = '2026-01-01T12:00:00.0000000+00:00'
    }
    ($state | ConvertTo-Json -Depth 6) |
        Set-Content -Path (Join-Path $stateDir "$Id.json") -Encoding utf8
    $Id
}

function Get-TestTaskState {
    param([Parameter(Mandatory)][string]$InstallRoot, [Parameter(Mandatory)][string]$Id)
    Get-Content (Join-Path $InstallRoot 'state' "$Id.json") -Raw | ConvertFrom-Json
}

function Invoke-DeputyScript {
    <#
    .SYNOPSIS
    Run a toolbelt script from a throwaway install as a real process, so exit
    codes and stdout are what the Deputy would actually see.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$Script,
        [string[]]$Arguments = @()
    )
    $path = Join-Path $InstallRoot 'bin' $Script
    $out = & pwsh -NoProfile -File $path @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}
