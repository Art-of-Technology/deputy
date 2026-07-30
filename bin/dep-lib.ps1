#Requires -Version 7.0
# Deputy shared library. Dot-source from sibling scripts:  . "$PSScriptRoot\dep-lib.ps1"

$ErrorActionPreference = 'Stop'

$script:DeputyRoot = Split-Path -Parent $PSScriptRoot

function Get-DeputyPaths {
    $root = $script:DeputyRoot
    [pscustomobject]@{
        Root       = $root
        Bin        = Join-Path $root 'bin'
        State      = Join-Path $root 'state'
        Archive    = Join-Path $root 'state' 'archive'
        Logs       = Join-Path $root 'logs'
        ConfigFile = Join-Path $root 'config' 'deputy.json'
        WakeQueue  = Join-Path $root 'state' 'wake-queue.jsonl'
    }
}

function Initialize-Deputy {
    $p = Get-DeputyPaths
    foreach ($dir in @($p.State, $p.Archive, $p.Logs)) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    }
}

function Get-DeputyConfig {
    $defaults = [ordered]@{
        model                = $null
        permissionMode       = 'bypassPermissions'
        watchIntervalSeconds = 15
        stallMinutes         = 10
        branchPrefix         = 'deputy/'
    }
    $p = Get-DeputyPaths
    if (Test-Path $p.ConfigFile) {
        $user = Get-Content $p.ConfigFile -Raw | ConvertFrom-Json
        foreach ($prop in $user.PSObject.Properties) {
            if ($null -ne $prop.Value) { $defaults[$prop.Name] = $prop.Value }
        }
    }
    [pscustomobject]$defaults
}

function Get-ProjectProfile([string]$RepoPath) {
    # Delivery profile for a repo, from config\projects.json. An empty
    # validate list means auto-detect at validation time (see
    # Get-AutoValidateCommands). Explicit entries override detection.
    $file = Join-Path (Get-DeputyPaths).Root 'config' 'projects.json'
    $default = [pscustomobject]@{ delivery = 'no-mistakes'; validate = @() }
    if (-not (Test-Path $file)) { return $default }
    $cfg = Get-Content $file -Raw | ConvertFrom-Json
    if ($cfg.PSObject.Properties['default'] -and $cfg.default) { $default = $cfg.default }
    $leaf = Split-Path -Leaf $RepoPath
    foreach ($proj in ($cfg.projects ?? @())) {
        $isPath = $proj.match -match '[\\/]'
        if (($isPath -and ($proj.match -ieq $RepoPath)) -or (-not $isPath -and ($proj.match -ieq $leaf))) {
            return $proj
        }
    }
    $default
}

function Get-AutoValidateCommands([string]$Worktree) {
    # Detect validation commands for the repo. Manifests are read from
    # origin/<default> via git show, never from the task branch, so a posse
    # member's branch cannot reconfigure its own gate.
    $branch = Get-DefaultBranch $Worktree
    function Show-DefaultFile([string]$Path) {
        $content = git -C $Worktree show "origin/${branch}:$Path" 2>$null
        if ($LASTEXITCODE -eq 0) { $content -join "`n" } else { $null }
    }

    $commands = @()

    $pkgRaw = Show-DefaultFile 'package.json'
    if ($pkgRaw) {
        $pkg = try { $pkgRaw | ConvertFrom-Json } catch { $null }
        $scripts = if ($pkg -and $pkg.PSObject.Properties['scripts']) { $pkg.scripts } else { $null }
        $runner = 'npm'
        if (Show-DefaultFile 'pnpm-lock.yaml') { $runner = 'pnpm' }
        elseif (Show-DefaultFile 'yarn.lock') { $runner = 'yarn' }
        if ($scripts -and $scripts.PSObject.Properties['test']) { $commands += "$runner test" }
        if ($scripts -and $scripts.PSObject.Properties['lint']) { $commands += "$runner run lint" }
    }

    if (Show-DefaultFile 'Cargo.toml') { $commands += 'cargo test' }
    if (Show-DefaultFile 'go.mod') { $commands += 'go test ./...' }

    $tree = git -C $Worktree ls-tree -r --name-only "origin/$branch" 2>$null
    if ($LASTEXITCODE -eq 0 -and $tree) {
        if ($tree | Where-Object { $_ -match '\.(sln|csproj)$' } | Select-Object -First 1) {
            $commands += 'dotnet test'
        }
        if (($tree -contains 'pytest.ini') -or
            (($pyproject = Show-DefaultFile 'pyproject.toml') -and $pyproject -match '\[tool\.pytest')) {
            $commands += 'pytest'
        }
    }

    # No comma-wrap: callers re-wrap with @(), which would nest a wrapped array
    @($commands | Select-Object -Unique)
}

function Get-DefaultBranch([string]$RepoPath) {
    $ref = git -C $RepoPath symbolic-ref --short refs/remotes/origin/HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $ref) { return ($ref -replace '^origin/', '') }
    foreach ($b in 'main', 'master') {
        git -C $RepoPath show-ref --verify --quiet "refs/remotes/origin/$b" 2>$null
        if ($LASTEXITCODE -eq 0) { return $b }
    }
    (git -C $RepoPath rev-parse --abbrev-ref HEAD).Trim()
}

function New-TaskId {
    $suffix = -join ((97..122) | Get-Random -Count 3 | ForEach-Object { [char]$_ })
    'posse-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $suffix
}

function Assert-TaskId([string]$Id) {
    # Task ids become file names under state\; reject anything that does not
    # match the exact shape New-TaskId produces so a hostile id (e.g. one with
    # path separators or '..') cannot escape the state directory.
    if ($Id -notmatch '^posse-\d{8}-\d{6}-[a-z]{3}$') {
        throw "Invalid task id '$Id'. Expected the form posse-YYYYMMDD-HHMMSS-abc."
    }
    $Id
}

function Get-TaskStatePath([string]$Id) {
    Join-Path (Get-DeputyPaths).State "$(Assert-TaskId $Id).json"
}

function Read-TaskState([string]$Id) {
    $path = Get-TaskStatePath $Id
    if (-not (Test-Path $path)) {
        throw "No active task state for '$Id'. Run dep-posse.ps1 status to list tasks."
    }
    Get-Content $path -Raw | ConvertFrom-Json
}

function Read-TaskStateAny([string]$Id) {
    # Like Read-TaskState but also finds archived (returned) tasks
    $path = Get-TaskStatePath $Id
    if (-not (Test-Path $path)) {
        $path = Join-Path (Get-DeputyPaths).Archive "$(Assert-TaskId $Id).json"
    }
    if (-not (Test-Path $path)) {
        throw "No task state (active or archived) for '$Id'."
    }
    Get-Content $path -Raw | ConvertFrom-Json
}

function Write-TaskState($State) {
    $path = Get-TaskStatePath $State.id
    $tmp = "$path.tmp"
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Force $tmp $path
}

function Set-TaskField($State, [string]$Name, $Value) {
    $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Get-AllTasks {
    $p = Get-DeputyPaths
    Get-ChildItem -Path $p.State -Filter '*.json' -File -ErrorAction SilentlyContinue |
        ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
        Sort-Object spawnedAt
}

function Add-WakeEvent($WakeEvent) {
    $p = Get-DeputyPaths
    ($WakeEvent | ConvertTo-Json -Compress -Depth 8) | Add-Content -Path $p.WakeQueue -Encoding utf8
}

function Get-WorktreeProcessIds([string]$RepoPath, [string]$WorktreePath) {
    # Processes treehouse sees running inside a worktree (matched by CWD).
    Push-Location $RepoPath
    try { $raw = treehouse status --json 2>$null }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
    $pool = try { ($raw -join "`n") | ConvertFrom-Json } catch { return @() }
    $entry = $pool | Where-Object { $_.path -ieq $WorktreePath } | Select-Object -First 1
    if (-not $entry -or -not $entry.processes) { return @() }
    @($entry.processes | ForEach-Object {
        if ($_ -is [string]) { if ($_ -match '\((\d+)\)') { [int]$Matches[1] } }
        elseif ($_.PSObject.Properties['pid']) { [int]$_.pid }
        elseif ($_.PSObject.Properties['id']) { [int]$_.id }
    } | Where-Object { $_ })
}

function Test-TaskProcessAlive($State) {
    # The recorded pid can be a short-lived launcher (claude shims re-spawn
    # themselves), so fall back to treehouse's CWD-based process tracking.
    # Windows recycles pids, so a live pid only counts as ours when its start
    # time matches the recorded pidStartedAt (within a small tolerance).
    if ($State.pid) {
        $proc = Get-Process -Id $State.pid -ErrorAction SilentlyContinue
        if ($proc) {
            $recorded = $State.PSObject.Properties['pidStartedAt'] ? $State.pidStartedAt : $null
            if (-not $recorded) { return $true }  # pre-pidStartedAt record: cannot verify
            $started = try { $proc.StartTime } catch { $null }
            if ($started) {
                $expected = [datetime]::Parse($recorded, [cultureinfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind)
                if ([math]::Abs(($started - $expected).TotalSeconds) -le 2) { return $true }
            }
        }
    }
    if ($State.worktree -and (Test-Path $State.worktree) -and (Test-Path $State.repo)) {
        return @(Get-WorktreeProcessIds $State.repo $State.worktree).Count -gt 0
    }
    $false
}

function Stop-TaskProcessTree([int]$ProcessId) {
    # taskkill /T takes the whole child tree down (claude spawns helpers)
    taskkill /PID $ProcessId /T /F 2>$null | Out-Null
}

function Limit-Text([string]$Text, [int]$Max = 200) {
    if (-not $Text) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -le $Max) { $t } else { $t.Substring(0, $Max) + '...' }
}
