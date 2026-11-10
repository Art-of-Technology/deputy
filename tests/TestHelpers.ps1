#Requires -Version 7.0
<#
.SYNOPSIS
Fixtures for Deputy's tests: throwaway git repos, throwaway Deputy installs,
running tasks backed by real processes, and hook and watcher runners.

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
        # Point origin/HEAD at a branch that is not there, as a clone whose
        # default branch was since renamed or deleted upstream would have.
        [switch]$DanglingOriginHead,
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
        elseif ($DanglingOriginHead) {
            Invoke-Git @('-C', $Path, 'symbolic-ref', 'refs/remotes/origin/HEAD',
                'refs/remotes/origin/renamed-away')
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

function New-StreamResultLine {
    # A final stream-json result event, as a headless member emits it.
    param([string]$Text = 'Done.', [switch]$IsError)
    [ordered]@{
        type     = 'result'
        subtype  = ($IsError ? 'error_during_execution' : 'success')
        is_error = [bool]$IsError
        result   = $Text
    } | ConvertTo-Json -Compress
}

function New-MemberShims {
    <#
    .SYNOPSIS
    Fake claude and treehouse executables for end-to-end runs of dep-spawn.ps1
    and dep-send.ps1. Put the returned directory first on PATH.

    The claude shim prints an init event and a result event - the content of
    claude-result.json in its own directory when that file exists, a plain
    success otherwise - and then records the invocation as one JSON line in
    claude-calls.jsonl: its arguments, what it read on stdin, its working
    directory and the DEPUTY_POSSE_TASK marker. The treehouse shim passes the
    doctor's checks, leases the worktree named in lease.json, lists no
    processes, and logs every invocation to treehouse-calls.log.
    #>
    param([Parameter(Mandatory)][string]$Path, [string]$LeasePath)
    New-Item -ItemType Directory -Force $Path | Out-Null
    $Path = (Resolve-Path $Path).Path
    Set-Content -Path (Join-Path $Path 'claude.cmd') -Encoding ascii -Value @(
        '@echo off'
        'pwsh -NoProfile -File "%~dp0fake-claude.ps1" %*'
    )
    Set-Content -Path (Join-Path $Path 'fake-claude.ps1') -Encoding utf8 -Value @(
        '$call = [ordered]@{'
        '    args   = @($args | ForEach-Object { "$_" })'
        '    stdin  = [Console]::In.ReadToEnd()'
        '    cwd    = (Get-Location).Path'
        '    marker = $env:DEPUTY_POSSE_TASK'
        '}'
        '[Console]::Out.WriteLine(''{"type":"system","subtype":"init","session_id":"fake"}'')'
        '$result = Join-Path $PSScriptRoot ''claude-result.json'''
        'if (Test-Path $result) { [Console]::Out.WriteLine((Get-Content $result -Raw).Trim()) }'
        'else { [Console]::Out.WriteLine(''{"type":"result","subtype":"success","is_error":false,"result":"Fake member finished."}'') }'
        '$line = $call | ConvertTo-Json -Compress -Depth 4'
        'Add-Content -Path (Join-Path $PSScriptRoot ''claude-calls.jsonl'') -Value $line -Encoding utf8'
    )
    Set-Content -Path (Join-Path $Path 'treehouse.cmd') -Encoding ascii -Value @(
        '@echo off'
        'echo %*>>"%~dp0treehouse-calls.log"'
        'if "%1"=="--version" (echo v3.1.8& exit /b 0)'
        'if "%1"=="get" if "%2"=="--help" (echo       --lease   lease the worktree& exit /b 0)'
        'if "%1"=="get" (type "%~dp0lease.json" & exit /b 0)'
        'exit /b 1'
    )
    if ($LeasePath) {
        ([ordered]@{ path = $LeasePath; lease_id = 'lease-test' } | ConvertTo-Json -Compress) |
            Set-Content -Path (Join-Path $Path 'lease.json') -Encoding ascii
    }
    $Path
}

function Get-MemberShimCalls {
    # Every recorded invocation of the claude shim, oldest first.
    param([Parameter(Mandatory)][string]$Path)
    $log = Join-Path $Path 'claude-calls.jsonl'
    if (-not (Test-Path $log)) { return , @() }
    , @(Get-Content $log | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Wait-MemberShimCall {
    # Wait until the claude shim has recorded $Count invocations (recording is
    # its last act, after it wrote its output). True when it has.
    param([Parameter(Mandatory)][string]$Path, [int]$Count = 1, [int]$TimeoutSeconds = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-MemberShimCalls -Path $Path).Count -ge $Count) { return $true }
        Start-Sleep -Milliseconds 200
    }
    $false
}

function Wait-TestProcessGone {
    # True when no process with this id is left within the timeout.
    param([Parameter(Mandatory)][int]$ProcessId, [int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 100
    }
    $false
}

function New-TestRunningTask {
    <#
    .SYNOPSIS
    Register a running scout task in a throwaway install, backed by a real
    process standing in for the member. The caller owns the process: kill it
    (Complete-TestTask does) and the watcher sees the member exit.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [string]$Id = 'posse-20260101-120000-abc',
        [string[]]$Lines = @('{"type":"system","subtype":"init","session_id":"test"}')
    )
    $stateDir = Join-Path $InstallRoot 'state'
    $logDir = Join-Path $InstallRoot 'logs'
    New-Item -ItemType Directory -Force $stateDir, $logDir | Out-Null
    $log = Join-Path $logDir "$Id.jsonl"
    Set-Content -Path $log -Value $Lines -Encoding utf8

    $member = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 600')
    $state = [ordered]@{
        id             = $Id
        kind           = 'scout'
        task           = 'test task'
        repo           = $InstallRoot
        # No such directory: liveness is judged by the pid alone, so the tests
        # never need treehouse.
        worktree       = Join-Path $InstallRoot 'no-such-worktree'
        pid            = $member.Id
        pidStartedAt   = $member.StartTime.ToString('o')
        status         = 'running'
        spawnedAt      = '2026-01-01T12:00:00.0000000+00:00'
        stdoutLog      = $log
        stderrLog      = Join-Path $logDir "$Id.err.log"
        lastLogBytes   = 0
        lastActivityAt = (Get-Date).ToString('o')
        stallNotified  = $false
        prUrl          = $null
        result         = $null
    }
    ($state | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $stateDir "$Id.json") -Encoding utf8
    [pscustomobject]@{ Id = $Id; Log = $log; Member = $member }
}

function Complete-TestTask {
    # The member writes its final result and exits.
    param([Parameter(Mandatory)]$Task, [string]$Text = 'Done.')
    Add-Content -Path $Task.Log -Value (New-StreamResultLine $Text) -Encoding utf8
    if (-not $Task.Member.HasExited) { $Task.Member.Kill() }
    $Task.Member.WaitForExit()
}

function Invoke-DeputyHook {
    <#
    .SYNOPSIS
    Run a hook script from a throwaway install the way Claude Code does: the
    hook's JSON on stdin, stdout and stderr kept apart, and the exit code.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$Script,
        [hashtable]$HookInput = @{},
        [string[]]$Arguments = @()
    )
    $path = Join-Path $InstallRoot 'bin' $Script
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $json = [ordered]@{ session_id = 'session-test'; hook_event_name = 'Stop' }
        foreach ($key in $HookInput.Keys) { $json[$key] = $HookInput[$key] }
        $out = ($json | ConvertTo-Json -Compress) | & pwsh -NoProfile -File $path @Arguments 2> $errFile | Out-String
        $code = $LASTEXITCODE
        [pscustomobject]@{ ExitCode = $code; Output = $out; ErrorOutput = (Get-Content $errFile -Raw) ?? '' }
    }
    finally { Remove-Item $errFile -Force -ErrorAction SilentlyContinue }
}

function Start-TestWatcher {
    <#
    .SYNOPSIS
    Start dep-watch.ps1 -Wait from a throwaway install as a real background
    process and wait until it holds the watcher lock. Output goes to OutFile.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [string[]]$Arguments = @('-IntervalSeconds', '1'),
        [int]$TimeoutSeconds = 30
    )
    $outFile = Join-Path $InstallRoot ('watch-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.out')
    $proc = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile `
        -ArgumentList (@('-NoProfile', '-File', ('"{0}"' -f (Join-Path $InstallRoot 'bin' 'dep-watch.ps1')), '-Wait') + $Arguments)
    $lock = Join-Path $InstallRoot 'state' 'watcher.lock'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
        if ((Test-Path $lock) -and ((Get-Content $lock -Raw -ErrorAction SilentlyContinue) -match ('"pid":\s*{0}\b' -f $proc.Id))) { break }
        Start-Sleep -Milliseconds 100
    }
    [pscustomobject]@{ Process = $proc; OutFile = $outFile }
}

function Wait-TestProcessExit {
    # True when the process exits within the timeout.
    param([Parameter(Mandatory)]$Process, [int]$TimeoutSeconds = 30)
    $Process.WaitForExit($TimeoutSeconds * 1000)
}
