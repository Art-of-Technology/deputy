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
        [string]$Task = 'test task',
        # The branch the task was cut from, when it is not the default branch.
        [string]$BaseBranch
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
        baseBranch = $BaseBranch ? $BaseBranch : $null
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

function Invoke-DeputyLib {
    <#
    .SYNOPSIS
    Evaluate one dep-lib.ps1 expression in a separate process, from a
    throwaway install, and return its result parsed from JSON. Throws, with
    what the process said, when the expression fails.

    In-process tests dot-source the source tree's dep-lib.ps1, which reads the
    real install's config; this reads the throwaway install's own.
    #>
    param([Parameter(Mandatory)][string]$InstallRoot, [Parameter(Mandatory)][string]$Command)
    $lib = Join-Path $InstallRoot 'bin' 'dep-lib.ps1'
    $out = & pwsh -NoProfile -Command ". '$lib'; ($Command) | ConvertTo-Json -Depth 8 -Compress" 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("'$Command' failed: " + (($out | ForEach-Object { "$_" }) -join ' ')) }
    ($out -join "`n") | ConvertFrom-Json
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
    processes, accepts every `return` without touching the worktree, and logs
    every invocation to treehouse-calls.log.

    When the leased path is a git worktree, the lease does what treehouse
    does to it: it cuts the slot from the base (--base, else the lease's own
    base_branch, else where it is), on the new branch -b names, and fails
    when that branch already exists. -LeaseBase is the base_branch the lease
    reports when no --base is given, like a pool configured with base_branch.
    #>
    param([Parameter(Mandatory)][string]$Path, [string]$LeasePath, [string]$LeaseBase)
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
        'if "%1"=="get" if "%2"=="--help" goto help'
        'if "%1"=="get" goto lease'
        'if "%1"=="return" exit /b 0'
        'exit /b 1'
        ':help'
        'echo       --base string     Branch to cut this worktree from'
        'echo   -b, --branch string   Create and check out a new Git branch at the acquired commit'
        'echo       --lease           Durably lease a worktree without opening a subshell'
        'exit /b 0'
        ':lease'
        'pwsh -NoProfile -File "%~dp0fake-treehouse-get.ps1" %*'
        'exit /b %ERRORLEVEL%'
    )
    Set-Content -Path (Join-Path $Path 'fake-treehouse-get.ps1') -Encoding utf8 -Value @'
$arguments = @($args | ForEach-Object { "$_" })
function Get-Flag([string[]]$Names) {
    for ($i = 0; $i -lt $arguments.Count - 1; $i++) { if ($Names -contains $arguments[$i]) { return $arguments[$i + 1] } }
    $null
}
$leaseFile = Join-Path $PSScriptRoot 'lease.json'
if (-not (Test-Path $leaseFile)) { [Console]::Error.WriteLine('fake treehouse: no lease.json'); exit 1 }
$lease = Get-Content $leaseFile -Raw | ConvertFrom-Json
$branch = Get-Flag @('-b', '--branch')
$base = Get-Flag @('--base')
if (-not $base -and $lease.PSObject.Properties['base_branch']) { $base = $lease.base_branch }
& git -C $lease.path rev-parse --git-dir *> $null
if ($LASTEXITCODE -eq 0) {
    $start = if ($base) { $base } else { 'HEAD' }
    if ($branch) { & git -C $lease.path switch -q -c $branch $start *> $null }
    elseif ($base) { & git -C $lease.path switch -q --detach $start *> $null }
    if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("branch ""$branch"" could not be cut from $start"); exit 1 }
}
$out = [ordered]@{ path = $lease.path; lease_id = $lease.lease_id }
if ($base) { $out.base_branch = $base }
[Console]::Out.WriteLine(($out | ConvertTo-Json -Compress))
exit 0
'@
    if ($LeasePath) {
        $lease = [ordered]@{ path = $LeasePath; lease_id = 'lease-test' }
        if ($LeaseBase) { $lease.base_branch = $LeaseBase }
        ($lease | ConvertTo-Json -Compress) | Set-Content -Path (Join-Path $Path 'lease.json') -Encoding ascii
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

function New-GhShim {
    <#
    .SYNOPSIS
    A fake gh for tests that read or merge pull requests. Put the returned
    directory first on PATH. Nothing reaches GitHub.

    `gh api` answers from gh-routes.json in the shim's directory (written by
    Set-GhRoutes): a map from "METHOD endpoint" to a route with
    - status: the HTTP status (default 200);
    - body:   the JSON body, or text: a raw body (a diff);
    - fail:   answer with no HTTP response at all (no network, not signed in);
    - then:   routes to put in place once this one was hit - how a merge call
              turns the pull request into a merged one;
    - patchFile: @{ path; fields } - set these fields in that JSON file while
              the request is being answered. That is another process writing
              to a task record in the middle of the caller's work.
    A request with no route gets a 404. Like the real gh with --include, it
    prints the status line and headers before the body, for errors too, and
    exits 1 with `gh: <message> (HTTP <status>)` on stderr for a status of 400
    or above. `gh pr create` prints the URL in the "pr create" route. Every
    invocation is recorded as a JSON line in gh-calls.jsonl.
    #>
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Force $Path | Out-Null
    $Path = (Resolve-Path $Path).Path
    Set-Content -Path (Join-Path $Path 'gh.cmd') -Encoding ascii -Value @(
        '@echo off'
        'pwsh -NoProfile -File "%~dp0fake-gh.ps1" %*'
    )
    Set-Content -Path (Join-Path $Path 'fake-gh.ps1') -Encoding utf8 -Value @'
$arguments = @($args | ForEach-Object { "$_" })
$routesFile = Join-Path $PSScriptRoot 'gh-routes.json'
$routes = if (Test-Path $routesFile) { Get-Content $routesFile -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
function Write-Call($Call) {
    Add-Content -Path (Join-Path $PSScriptRoot 'gh-calls.jsonl') -Value ($Call | ConvertTo-Json -Compress -Depth 10) -Encoding utf8
}

if ($arguments.Count -ge 2 -and $arguments[0] -eq 'pr' -and $arguments[1] -eq 'create') {
    Write-Call ([ordered]@{ kind = 'pr create'; args = $arguments })
    $route = $routes['pr create']
    if (-not $route) { [Console]::Error.WriteLine('fake gh: no "pr create" route'); exit 1 }
    [Console]::Out.WriteLine($route.url)
    exit 0
}
if ($arguments.Count -eq 0 -or $arguments[0] -ne 'api') {
    Write-Call ([ordered]@{ kind = 'other'; args = $arguments })
    [Console]::Error.WriteLine("fake gh: only 'api' and 'pr create' are supported, got: $($arguments -join ' ')")
    exit 1
}

$method = 'GET'; $endpoint = $null; $fields = [ordered]@{}; $headers = @(); $inputText = $null
for ($i = 1; $i -lt $arguments.Count; $i++) {
    switch -CaseSensitive ($arguments[$i]) {
        { $_ -in '--include', '-i' } { continue }
        { $_ -in '--method', '-X' } { $method = $arguments[++$i]; continue }
        { $_ -in '-H', '--header' } { $headers += $arguments[++$i]; continue }
        { $_ -in '-f', '-F', '--raw-field', '--field' } {
            $pair = $arguments[++$i] -split '=', 2
            $fields[$pair[0]] = $pair[1]
            continue
        }
        '--input' { $i++; $inputText = [Console]::In.ReadToEnd(); continue }
        default { $endpoint = $arguments[$i] }
    }
}
Write-Call ([ordered]@{
    kind = 'api'; method = $method; endpoint = $endpoint; fields = $fields; headers = $headers
    input = if ($inputText) { $inputText | ConvertFrom-Json } else { $null }
})

$route = $routes["$method $endpoint"]
if (-not $route) { $route = @{ status = 404; body = @{ message = 'Not Found' } } }
if ($route.fail) {
    [Console]::Error.WriteLine([string]$route.fail)
    exit 1
}
$status = if ($route.status) { [int]$route.status } else { 200 }
$reason = switch ($status) { 200 { 'OK' } 403 { 'Forbidden' } 404 { 'Not Found' } 405 { 'Method Not Allowed' } 409 { 'Conflict' } default { 'Status' } }
[Console]::Out.WriteLine("HTTP/2.0 $status $reason")
[Console]::Out.WriteLine('Content-Type: application/json; charset=utf-8')
[Console]::Out.WriteLine('X-Github-Request-Id: FAKE')
[Console]::Out.WriteLine('')
if ($null -ne $route.text) { [Console]::Out.WriteLine([string]$route.text) }
elseif ($null -ne $route.body) { [Console]::Out.WriteLine(($route.body | ConvertTo-Json -Compress -Depth 20)) }

if ($route.then) {
    foreach ($key in @($route.then.Keys)) { $routes[$key] = $route.then[$key] }
    ($routes | ConvertTo-Json -Depth 30) | Set-Content -Path $routesFile -Encoding utf8
}
if ($route.patchFile) {
    $document = Get-Content $route.patchFile.path -Raw | ConvertFrom-Json
    foreach ($key in @($route.patchFile.fields.Keys)) {
        $document | Add-Member -NotePropertyName $key -NotePropertyValue $route.patchFile.fields[$key] -Force
    }
    ($document | ConvertTo-Json -Depth 20) | Set-Content -Path $route.patchFile.path -Encoding utf8
}
if ($status -ge 400) {
    $message = if ($route.body -and $route.body.message) { $route.body.message } else { $reason }
    [Console]::Error.WriteLine("gh: $message (HTTP $status)")
    exit 1
}
exit 0
'@
    $Path
}

function Set-GhRoutes {
    # Replace the fake gh's routes. See New-GhShim for what a route is.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][System.Collections.IDictionary]$Routes)
    ($Routes | ConvertTo-Json -Depth 30) | Set-Content -Path (Join-Path $Path 'gh-routes.json') -Encoding utf8
}

function Get-GhCalls {
    # Every recorded invocation of the fake gh, oldest first, one object each
    # (so it can be piped; wrap it in @() to count or index).
    param([Parameter(Mandatory)][string]$Path)
    $log = Join-Path $Path 'gh-calls.jsonl'
    if (-not (Test-Path $log)) { return }
    Get-Content $log | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }
}

function New-PullRequestJson {
    # A pull request as GitHub's REST API returns it, cut down to what Deputy reads.
    param(
        [int]$Number = 7,
        [string]$Repo = 'acme/widgets',
        [ValidateSet('open', 'closed')][string]$State = 'open',
        [switch]$Merged,
        [switch]$Draft,
        [string]$HeadSha = ('a' * 40),
        [string]$HeadRef = 'deputy/task',
        [string]$BaseRef = 'main',
        # 'null' for "GitHub has not computed it yet".
        [ValidateSet('true', 'false', 'null')][string]$Mergeable = 'true',
        [string]$MergeableState = 'clean',
        [string]$MergeSha = ('f' * 40)
    )
    [ordered]@{
        number           = $Number
        state            = if ($Merged) { 'closed' } else { $State }
        title            = 'Fixture pull request'
        html_url         = "https://github.com/$Repo/pull/$Number"
        user             = [ordered]@{ login = 'fixture-bot' }
        body             = 'Fixture body.'
        draft            = [bool]$Draft
        merged           = [bool]$Merged
        merged_at        = if ($Merged) { '2026-01-02T03:04:05Z' } else { $null }
        merge_commit_sha = if ($Merged) { $MergeSha } else { $null }
        mergeable        = switch ($Mergeable) { 'true' { $true } 'false' { $false } default { $null } }
        mergeable_state  = $MergeableState
        head             = [ordered]@{ sha = $HeadSha; ref = $HeadRef }
        base             = [ordered]@{ ref = $BaseRef }
        additions        = 3
        deletions        = 1
        changed_files    = 2
        commits          = 1
    }
}

function New-CheckRunsJson {
    # The check-runs listing of one commit. Each entry is @{ name; conclusion }
    # for a finished run, or @{ name; status } for one still queued or running.
    param([hashtable[]]$Runs = @())
    [ordered]@{
        total_count = $Runs.Count
        check_runs  = @($Runs | ForEach-Object {
                [ordered]@{
                    name       = $_.name
                    status     = if ($_.status) { $_.status } else { 'completed' }
                    conclusion = $_.conclusion
                    html_url   = "https://github.com/acme/widgets/runs/$($_.name)"
                }
            })
    }
}

function New-CommitStatusJson {
    # The combined status of one commit: @{ context; state } per entry.
    param([hashtable[]]$Statuses = @())
    [ordered]@{
        state       = 'pending'
        total_count = $Statuses.Count
        statuses    = @($Statuses | ForEach-Object { [ordered]@{ context = $_.context; state = $_.state; target_url = '' } })
    }
}

function New-PrRoutes {
    <#
    .SYNOPSIS
    The fake gh routes of one pull request: the PR itself, and the check runs
    and commit statuses at its head. -Protection adds the base branch's
    protection: a hashtable is its body (status 200), a number is the HTTP
    status GitHub refuses the read with.
    #>
    param(
        [Parameter(Mandatory)]$PullRequest,
        [hashtable[]]$Runs = @(),
        [hashtable[]]$Statuses = @(),
        $Protection
    )
    $api = 'repos/' + (($PullRequest.html_url -replace '^https://github\.com/', '') -replace '/pull/\d+$', '')
    $sha = $PullRequest.head.sha
    $routes = [ordered]@{
        "GET $api/pulls/$($PullRequest.number)" = @{ body = $PullRequest }
        "GET $api/commits/$sha/check-runs"      = @{ body = (New-CheckRunsJson -Runs $Runs) }
        "GET $api/commits/$sha/status"          = @{ body = (New-CommitStatusJson -Statuses $Statuses) }
    }
    if ($Protection -is [System.Collections.IDictionary]) {
        $routes["GET $api/branches/$($PullRequest.base.ref)/protection"] = @{ body = $Protection }
    }
    elseif ($Protection) {
        $routes["GET $api/branches/$($PullRequest.base.ref)/protection"] = @{
            status = [int]$Protection
            body   = @{ message = if ([int]$Protection -eq 403) { 'Resource not accessible by personal access token' } else { 'Not Found' } }
        }
    }
    $routes
}
