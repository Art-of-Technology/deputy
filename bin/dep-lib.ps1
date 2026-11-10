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
        # Tracked defaults, and the private overrides each user keeps for
        # themselves (gitignored). See Get-DeputyConfig and Get-ProjectProfile.
        ConfigFile        = Join-Path $root 'config' 'deputy.json'
        LocalConfigFile   = Join-Path $root 'config' 'deputy.local.json'
        ProjectsFile      = Join-Path $root 'config' 'projects.json'
        LocalProjectsFile = Join-Path $root 'config' 'projects.local.json'
        WakeQueue  = Join-Path $root 'state' 'wake-queue.jsonl'
        # Runtime files beside the queue. None of them may end in .json: every
        # state\*.json is read as a task (Get-AllTasks).
        WakeSeq       = Join-Path $root 'state' 'wake-queue.seq'
        StateLock     = Join-Path $root 'state' 'state.lock'
        WatcherLock   = Join-Path $root 'state' 'watcher.lock'
        WatcherBeat   = Join-Path $root 'state' 'watcher.beat'
        GuardBlocks   = Join-Path $root 'state' 'hook-guard.blocks'
        WakeAnnounced = Join-Path $root 'state' 'hook-stop.announced'
    }
}

function Test-DeputyHome {
    <#
    .SYNOPSIS
    Is this checkout the Deputy home, as opposed to a posse worktree of the
    Deputy repository?

    The tracked hooks in .claude\settings.json are loaded by every Claude
    session started in a checkout of this repo, and that includes posse members
    working on Deputy itself in a leased worktree. There the hooks must do
    nothing at all: a member that blocked its own stop, or ran a watcher, would
    be acting as a second Deputy. Three independent signs, any one of which
    means "not the home":

    - the session was given a task briefing: dep-spawn.ps1 marks every member
      it launches with DEPUTY_POSSE_TASK in its environment;
    - there is no state\ beside bin\: state\ is untracked runtime data that only
      the toolbelt creates, so a fresh worktree does not have one;
    - .git is a file, not a directory: a leased worktree is a linked git
      worktree, the home is a clone. This still holds for a member that ran a
      toolbelt script in its worktree and so grew a state\ of its own.

    Deliberately free of side effects - it must be safe to call before
    Initialize-Deputy, which would create the very state\ it looks for.
    #>
    if ($env:DEPUTY_POSSE_TASK) { return $false }
    $p = Get-DeputyPaths
    if (-not (Test-Path -LiteralPath $p.State -PathType Container)) { return $false }
    if (Test-Path -LiteralPath (Join-Path $p.Root '.git') -PathType Leaf) { return $false }
    $true
}

function Initialize-Deputy {
    $p = Get-DeputyPaths
    foreach ($dir in @($p.State, $p.Archive, $p.Logs)) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    }
}

# ---------------------------------------------------------------------------
# Configuration. Each file comes in two layers: the tracked defaults
# (config\deputy.json, config\projects.json), which every clone shares and which
# change only through pull requests, and a user's private overrides
# (config\deputy.local.json, config\projects.local.json), which are gitignored.
# Personal pins - a model, a budget, the gate of a repo only you work on - go in
# the local files, so a clone never drifts from main.
# ---------------------------------------------------------------------------

# The delivery modes a project can have (see README, "Delivery modes").
$script:DeliveryModes = @('no-mistakes', 'direct-pr')

function Get-ConfigDisplayName([string]$Path) {
    # A config file the way its owner knows it: config\<name>.
    'config\' + (Split-Path -Leaf $Path)
}

function Test-JsonObject($Value) {
    # Is this a JSON object as ConvertFrom-Json returns one? Not `-is [pscustomobject]`:
    # that accelerator is [psobject], which every value ConvertFrom-Json wraps passes,
    # strings and numbers included.
    $Value -is [System.Management.Automation.PSCustomObject]
}

function Read-ConfigFile([string]$Path) {
    # A config file's JSON object, or $null when the file is not there or holds
    # nothing. A file that is there but is not a JSON object is an error that
    # names it: falling back to the defaults would quietly ignore a pin its
    # owner believes is in force.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = Get-Content -LiteralPath $Path -Raw
    if (-not "$text".Trim()) { return $null }
    $name = Get-ConfigDisplayName $Path
    $parsed = try { $text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "$name is not valid JSON: $($_.Exception.Message)" }
    if (-not (Test-JsonObject $parsed)) { throw "$name must hold a JSON object." }
    $parsed
}

function Get-DeputyConfig {
    <#
    .SYNOPSIS
    The Deputy configuration: the built-in defaults, then config\deputy.json
    (tracked), then config\deputy.local.json (private), key by key. A later
    layer's value replaces an earlier one, and null in either file means the
    built-in default - so a local null can undo a tracked value.
    #>
    $builtIn = [ordered]@{
        model                = $null
        permissionMode       = 'bypassPermissions'
        watchIntervalSeconds = 15
        stallMinutes         = 10
        branchPrefix         = 'deputy/'
        # Whether the Stop / StopFailure hook runs the watcher itself and
        # rewakes the session (dep-hook-stop.ps1). Off leaves the queue, the
        # session-start report and the stop guard in place.
        autoWatch            = $true
        # Defaults for dep-spawn.ps1 -Effort and -MaxBudgetUsd. Null leaves the
        # flag off the member's command line.
        effort               = $null
        maxBudgetUsd         = $null
        # How often the watcher reads each published, unmerged task's pull
        # request (see Get-PrWatchTasks). 0 switches PR watching off.
        prPollMinutes        = 5
        # Launch members without the operator's personal MCP servers, skills
        # and slash commands (--strict-mcp-config --disable-slash-commands, see
        # Get-MemberArguments). Recorded per task at spawn, so a resumed run is
        # started the way its first run was.
        memberIsolation      = $true
    }
    $config = [ordered]@{}
    foreach ($name in $builtIn.Keys) { $config[$name] = $builtIn[$name] }
    $p = Get-DeputyPaths
    foreach ($file in $p.ConfigFile, $p.LocalConfigFile) {
        $layer = Read-ConfigFile $file
        if (-not $layer) { continue }
        foreach ($prop in $layer.PSObject.Properties) {
            $config[$prop.Name] = if ($null -ne $prop.Value) { $prop.Value } else { $builtIn[$prop.Name] }
        }
    }
    [pscustomobject]$config
}

function Assert-ProjectFields($Fields, [string]$Where) {
    # A projects default or entry must say something Deputy can act on. A typo
    # here is not harmless: an unknown delivery mode used to be read as
    # direct-pr, which has the member push.
    if (-not (Test-JsonObject $Fields)) { throw "$Where must be a JSON object." }
    $delivery = Get-EventField $Fields 'delivery'
    if ($null -ne $delivery -and $script:DeliveryModes -notcontains $delivery) {
        throw "$Where has delivery '$delivery', which is not one of: $($script:DeliveryModes -join ', ')."
    }
    $validate = $Fields.PSObject.Properties['validate']
    if ($validate -and $null -ne $validate.Value) {
        $commands = $validate.Value
        if ($commands -isnot [array] -or @($commands | Where-Object { $_ -isnot [string] -or -not $_.Trim() }).Count -gt 0) {
            throw "$Where has a validate value that is not a list of commands. Write it as [""command"", ...]."
        }
    }
}

function Test-ProjectMatch($Entry, [string]$RepoPath) {
    # Does a projects entry name this repo? A match with a slash in it is a
    # path, compared as a full path whatever its separators; anything else is
    # the repo's folder name.
    $match = [string](Get-EventField $Entry 'match')
    if ($match -match '[\\/]') { return Test-SamePath $match $RepoPath }
    $match -ieq (Split-Path -Leaf $RepoPath)
}

function Get-ProjectProfile([string]$RepoPath) {
    <#
    .SYNOPSIS
    A repo's delivery profile: its delivery mode and its gate commands.

    Read from config\projects.local.json (private) over config\projects.json
    (tracked). The default block is merged key by key: local over tracked over
    the built-in default (no-mistakes, auto-detected gate). Project entries are
    matched local first, then tracked, and the first match wins; it is laid
    over the default key by key, so an entry may name only what it changes. An
    empty validate list means auto-detect at validation time (see
    Get-AutoValidateCommands).

    Source and ValidateSource say where the profile and its gate commands came
    from, for the gate's evidence.
    #>
    $p = Get-DeputyPaths
    $layers = @(
        foreach ($file in $p.ProjectsFile, $p.LocalProjectsFile) {
            $config = Read-ConfigFile $file
            if (-not $config) { continue }
            $name = Get-ConfigDisplayName $file
            $default = Get-EventField $config 'default'
            if ($null -ne $default) { Assert-ProjectFields $default "$name (default)" }
            $entries = @(Get-EventField $config 'projects' | Where-Object { $null -ne $_ })
            foreach ($entry in $entries) {
                if (-not (Test-JsonObject $entry) -or -not "$(Get-EventField $entry 'match')".Trim()) {
                    throw "$name has a projects entry without a match (a repo folder name, or a full path)."
                }
                Assert-ProjectFields $entry "$name (match '$($entry.match)')"
            }
            [pscustomobject]@{ Name = $name; Default = $default; Entries = $entries }
        }
    )

    $result = [ordered]@{
        delivery = 'no-mistakes'; validate = @(); match = $null
        source = 'built-in default'; validateSource = 'built-in default'
    }
    $apply = {
        param($Fields, [string]$From)
        $result.source = $From
        foreach ($key in 'delivery', 'validate') {
            # Read the property itself: through the pipeline an empty list
            # would come back as null, and "validate": [] (auto-detect) could
            # never override a pinned default.
            $prop = $Fields.PSObject.Properties[$key]
            if (-not $prop -or $null -eq $prop.Value) { continue }
            $result[$key] = $prop.Value
            if ($key -eq 'validate') { $result.validateSource = $From }
        }
    }
    # The default: tracked, then local on top.
    foreach ($layer in $layers) {
        if ($layer.Default) { & $apply $layer.Default "$($layer.Name) (default)" }
    }
    # The entry: local entries are matched first.
    [array]::Reverse($layers)
    foreach ($layer in $layers) {
        $entry = $layer.Entries | Where-Object { Test-ProjectMatch $_ $RepoPath } | Select-Object -First 1
        if (-not $entry) { continue }
        $result.match = [string]$entry.match
        & $apply $entry "$($layer.Name) (match '$($entry.match)')"
        break
    }
    [pscustomobject]@{
        delivery       = [string]$result.delivery
        validate       = [string[]]@($result.validate)
        match          = $result.match
        source         = $result.source
        validateSource = $result.validateSource
    }
}

function Test-GitRef([string]$RepoPath, [string]$Ref) {
    git -C $RepoPath show-ref --verify --quiet $Ref 2>$null
    $LASTEXITCODE -eq 0
}

function Resolve-DefaultRef([string]$RepoPath) {
    # The trust anchor Deputy reads a repo's shape from: gate manifests and the
    # "is this branch actually ahead" check. It must never resolve to the
    # checked-out branch, because inside a posse worktree that is the task
    # branch - a member could otherwise add a manifest (or delete one) on its
    # own branch and reconfigure the gate that judges it.
    #
    # Preference order: the remote's default branch (authoritative, and not
    # reachable by editing files in a worktree), then - for a repo with no
    # remote at all - the local default branch by convention. Never a fallback
    # to HEAD: an unresolvable anchor returns Ref = $null, which callers must
    # treat as "cannot verify", not as "nothing to check".
    # Health is the machine-readable form of Source, so callers can react to a
    # bad anchor without parsing prose: 'ok' when it resolved cleanly, 'stale'
    # when origin/HEAD named a missing ref, 'unresolved' when there is no anchor
    # at all. Only the Sheriff can fix the last two, at the repo level.
    function New-Anchor([string]$Branch, [string]$Ref, [string]$Source, [switch]$Stale) {
        $health = if (-not $Ref) { 'unresolved' } elseif ($Stale) { 'stale' } else { 'ok' }
        [pscustomobject]@{ Branch = $Branch; Ref = $Ref; Source = $Source; Health = $health }
    }

    # Set when origin/HEAD names a ref that is not there (the default branch was
    # renamed or deleted since the clone). Falling through to the candidates
    # below is right: the repo still has a real default branch, and returning an
    # unverified ref would make callers deny good work with "no commits ahead of
    # <missing ref>". But it is not silent either - the staleness rides along in
    # the anchor's Source, which dep-validate reports, so the repo-level fix
    # (git remote set-head origin -a) is visible rather than guessed at.
    $stale = ''
    $ref = git -C $RepoPath symbolic-ref --short refs/remotes/origin/HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $ref) {
        $b = ((($ref -join '').Trim()) -replace '^origin/', '')
        if ($b) {
            if (Test-GitRef $RepoPath "refs/remotes/origin/$b") {
                return New-Anchor $b "refs/remotes/origin/$b" 'origin/HEAD'
            }
            $stale = "stale origin/HEAD (origin/$b is missing), fell back to "
        }
    }
    foreach ($b in 'main', 'master') {
        if (Test-GitRef $RepoPath "refs/remotes/origin/$b") {
            return New-Anchor $b "refs/remotes/origin/$b" "${stale}remote-tracking origin/$b" -Stale:([bool]$stale)
        }
    }
    # No remote-tracking default (no remote configured, or nothing fetched).
    # main/master are safe to accept even when checked out here: task branches
    # carry the configured branch prefix, so they are never named main/master.
    foreach ($b in 'main', 'master') {
        if (Test-GitRef $RepoPath "refs/heads/$b") {
            return New-Anchor $b "refs/heads/$b" "${stale}local branch $b" -Stale:([bool]$stale)
        }
    }
    New-Anchor $null $null "${stale}unresolved"
}

function Get-DefaultBranch([string]$RepoPath) {
    # Short name of the default branch, or $null when it cannot be resolved.
    (Resolve-DefaultRef $RepoPath).Branch
}

function Resolve-BaseRef([string]$RepoPath, [string]$BaseBranch) {
    <#
    .SYNOPSIS
    The anchor a task's work is measured against: the branch it was cut from.
    That is the task's base branch when it has one (dep-spawn.ps1 -BaseBranch,
    kept as baseBranch in task state), else the default branch
    (Resolve-DefaultRef). Same shape as Resolve-DefaultRef.

    A base branch resolves the way treehouse cuts from it: the remote-tracking
    origin/<base> first, then the local branch. It never falls back to the
    default branch - an unresolvable base returns Ref = $null (Health
    'unresolved'), because measuring the work against a branch it was not cut
    from would count the base's own commits as the member's.
    #>
    if (-not $BaseBranch) { return Resolve-DefaultRef $RepoPath }
    foreach ($ref in "refs/remotes/origin/$BaseBranch", "refs/heads/$BaseBranch") {
        if (Test-GitRef $RepoPath $ref) {
            $where = if ($ref -like 'refs/remotes/*') { "remote-tracking origin/$BaseBranch" } else { "local branch $BaseBranch" }
            return [pscustomobject]@{ Branch = $BaseBranch; Ref = $ref; Source = "base branch '$BaseBranch', $where"; Health = 'ok' }
        }
    }
    [pscustomobject]@{
        Branch = $null
        Ref    = $null
        Source = "base branch '$BaseBranch' is unresolved (no origin/$BaseBranch and no local $BaseBranch)"
        Health = 'unresolved'
    }
}

function Resolve-TaskBaseRef($State, [string]$RepoPath) {
    # A task's anchor, read in $RepoPath: its recorded base branch, or the
    # default branch when it has none.
    Resolve-BaseRef $RepoPath ([string](Get-EventField $State 'baseBranch'))
}

function Test-BranchName([string]$Name) {
    # Can git name a branch this? A leading dash is refused too, because a
    # command line would read it as an option.
    if (-not $Name -or $Name.StartsWith('-')) { return $false }
    git check-ref-format --branch $Name *> $null
    $LASTEXITCODE -eq 0
}

function Get-TaskBranchName([string]$Prefix, [string]$TaskId) {
    # A ship task's branch: the configured prefix and the task id. The id is
    # unique, so two tasks can never collide on a branch however alike their
    # briefings read - which names cut from the briefing's text did.
    $branch = '{0}{1}' -f $Prefix, (Assert-TaskId $TaskId)
    if (-not (Test-BranchName $branch)) {
        throw "'$branch' is not a valid branch name. Check branchPrefix ('$Prefix') in config\deputy.json and config\deputy.local.json."
    }
    $branch
}

function Get-AutoValidateCommands([string]$Worktree, [string]$DefaultRef) {
    # Detect validation commands for the repo. Manifests are read from the
    # default branch's ref via git show, never from the task branch or the
    # working tree, so a posse member's branch cannot reconfigure its own gate.
    if (-not $DefaultRef) { $DefaultRef = (Resolve-DefaultRef $Worktree).Ref }
    if (-not $DefaultRef) { return @() }  # no trust anchor: detect nothing
    function Show-DefaultFile([string]$Path) {
        $content = git -C $Worktree show "${DefaultRef}:$Path" 2>$null
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

    $tree = git -C $Worktree ls-tree -r --name-only $DefaultRef 2>$null
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

function Get-TaskStateFile([string]$Id) {
    # Where a task's record is right now: active, else archived (returned),
    # else $null.
    $path = Get-TaskStatePath $Id
    if (Test-Path -LiteralPath $path) { return $path }
    $path = Join-Path (Get-DeputyPaths).Archive "$(Assert-TaskId $Id).json"
    if (Test-Path -LiteralPath $path) { return $path }
    $null
}

function Read-TaskStateAny([string]$Id) {
    # Like Read-TaskState but also finds archived (returned) tasks
    $path = Get-TaskStateFile $Id
    if (-not $path) {
        throw "No task state (active or archived) for '$Id'."
    }
    Get-Content $path -Raw | ConvertFrom-Json
}

function Write-TaskState($State, [string]$Path) {
    # Writes the WHOLE record. Right for a record this process just created or
    # read a moment ago with nothing slow in between. A script that read the
    # record and then went to the network, ran a gate or waited on anything
    # must use Update-TaskState instead, or it undoes what others recorded
    # meanwhile. -Path is for Update-TaskState, which may write an archived one.
    if (-not $Path) { $Path = Get-TaskStatePath $State.id }
    $tmp = "$Path.tmp"
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Force $tmp $Path
}

function Update-TaskState {
    <#
    .SYNOPSIS
    Set a few fields on a task's record as it is on disk right now, under the
    state lock, and return the record as written ($null when there is none).

    For every writer that read the record a while ago - across a network call,
    a gate run, a push: writing its own stale copy back would undo whatever
    another script (the watcher, usually) recorded in the meantime. Only the
    named fields are touched.

    The record must be active unless -IncludeArchived is given, in which case a
    returned task's record is updated where it lies in the archive.
    #>
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [Parameter(Mandatory, Position = 1)][System.Collections.IDictionary]$Fields,
        [switch]$IncludeArchived
    )
    # Named outside the block: the analyzer does not see a parameter that is
    # only used inside a script block as used.
    $taskId = $Id
    $updates = $Fields
    $anywhere = [bool]$IncludeArchived
    Invoke-WithStateLock {
        $path = if ($anywhere) { Get-TaskStateFile $taskId } else { Get-TaskStatePath $taskId }
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
        $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        foreach ($name in @($updates.Keys)) { Set-TaskField $state $name $updates[$name] }
        Write-TaskState $state $path
        $state
    }
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

function Get-ActiveTasks {
    # Tasks whose member a watcher still has to watch.
    @(Get-AllTasks | Where-Object { $_.status -in @('running', 'stalled') })
}

function Test-TaskPrWatched($State) {
    # Does this task have a pull request the watcher should keep an eye on?
    # Published (or opened by the member), not yet seen merged, not returned.
    if ($State.kind -ne 'ship' -or $State.status -eq 'returned') { return $false }
    if (Get-EventField $State 'mergedAt') { return $false }
    [bool](Get-TaskPrRef $State)
}

function Get-PrWatchTasks {
    # Tasks whose pull request the watcher polls. None when PR watching is
    # switched off (prPollMinutes 0). A PR that was closed without merging is
    # still in here, so that a watcher which is running anyway notices when it
    # is reopened - but see Test-TaskPrPending for what keeps a watcher running.
    if ([double](Get-DeputyConfig).prPollMinutes -le 0) { return @() }
    @(Get-AllTasks | Where-Object { Test-TaskPrWatched $_ })
}

function Test-TaskPrPending($State) {
    # Is this task's pull request something to wait for? Watched, and not seen
    # closed without merging: a closed PR may never change again, so it must
    # not keep a watcher, the stop hooks or a one-shot session waiting. The
    # watcher clears prClosedAt when it sees the PR open again.
    (Test-TaskPrWatched $State) -and -not (Get-EventField $State 'prClosedAt')
}

function Get-WatchLoad {
    # Everything a watcher has work for: members that are running, and pull
    # requests that are open. A watcher is needed while Total is above zero.
    # A pull request that was closed without merging is not counted.
    $active = @(Get-ActiveTasks)
    $activeIds = @($active | ForEach-Object { $_.id })
    $pulls = @(Get-PrWatchTasks | Where-Object { (Test-TaskPrPending $_) -and $activeIds -notcontains $_.id })
    $parts = @()
    if ($active.Count -gt 0) { $parts += "$($active.Count) posse task(s) are active" }
    if ($pulls.Count -gt 0) { $parts += "$($pulls.Count) published pull request(s) are waiting to be merged" }
    [pscustomobject]@{
        Active = $active.Count
        Pulls  = $pulls.Count
        Total  = $active.Count + $pulls.Count
        Text   = $parts -join ' and '
    }
}

# ---------------------------------------------------------------------------
# State lock. One short-lived mutex for every read-modify-write of the runtime
# files beside the task records: the wake queue and its sequence counter, the
# watcher lock, the hook counters. It is an exclusively opened file, so the OS
# releases it when the holder exits, however it exits - there is no stale lock
# to reclaim.
# ---------------------------------------------------------------------------

$script:StateLockDepth = 0

function Invoke-WithStateLock {
    param(
        [Parameter(Mandatory, Position = 0)][scriptblock]$Body,
        [int]$TimeoutSeconds = 30
    )
    # Re-entrant within a process: a second exclusive open of the same file
    # would block on itself.
    if ($script:StateLockDepth -gt 0) { return (& $Body) }

    $lockPath = (Get-DeputyPaths).StateLock
    $lockDeadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lockHandle = $null
    while (-not $lockHandle) {
        try {
            $lockHandle = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            if ([datetime]::UtcNow -gt $lockDeadline) {
                throw "Timed out after $TimeoutSeconds seconds waiting for the state lock $lockPath."
            }
            Start-Sleep -Milliseconds 40
        }
    }
    $script:StateLockDepth++
    try { & $Body }
    finally {
        $script:StateLockDepth--
        $lockHandle.Dispose()
    }
}

function Write-FileAtomic([string]$Path, [string]$Content) {
    # Write beside the target, then rename over it, so a reader sees the old
    # file or the new one and never a half-written one. The rename is retried
    # briefly: a reader with the target open (a dashboard tailing the queue)
    # makes it fail for as long as that read lasts.
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Content)
    for ($attempt = 1; ; $attempt++) {
        try { Move-Item -Force -LiteralPath $tmp -Destination $Path -ErrorAction Stop; return }
        catch {
            if ($attempt -ge 10) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
}

# ---------------------------------------------------------------------------
# Durable wake queue. The watcher appends every wake to state\wake-queue.jsonl
# with a sequence number that only ever grows, and a wake stays there until it
# is acknowledged (dep-wake.ps1 ack). So a wake nobody was listening for - the
# session restarted, the turn ended on an API error, the watcher's output was
# lost - is still there for the next drain.
# ---------------------------------------------------------------------------

function Read-WakeQueueRows {
    # Every non-empty queue line, parsed. Seq is 0 for a row that cannot be
    # acknowledged by sequence: one written before the queue was sequenced, or
    # a torn line. Call under the state lock.
    $path = (Get-DeputyPaths).WakeQueue
    if (-not (Test-Path -LiteralPath $path)) { return }
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        if (-not $line.Trim()) { continue }
        $wake = try { $line | ConvertFrom-Json -ErrorAction Stop } catch { $null }
        $seq = 0L
        if ($wake -is [pscustomobject] -and $wake.PSObject.Properties['seq'] -and
            $wake.PSObject.Properties['taskId'] -and $wake.PSObject.Properties['event']) {
            $parsed = 0L
            if ([long]::TryParse([string]$wake.seq, [ref]$parsed) -and $parsed -gt 0) { $seq = $parsed }
        }
        [pscustomobject]@{ Seq = $seq; Wake = $wake; Line = $line }
    }
}

function Write-WakeQueueRows($Rows) {
    # Rows keep their original text: re-serialising would reformat timestamps.
    $rows = @($Rows)
    $text = if ($rows.Count -gt 0) {
        (($rows | ForEach-Object { $_.Line }) -join [Environment]::NewLine) + [Environment]::NewLine
    } else { '' }
    Write-FileAtomic (Get-DeputyPaths).WakeQueue $text
}

function Get-WakeSeqCounter {
    # The last sequence number handed out, or 0 when the counter is missing or
    # unreadable. Never trusted alone: see Get-HighestWakeSeq.
    $path = (Get-DeputyPaths).WakeSeq
    $value = 0L
    if (Test-Path -LiteralPath $path) {
        $text = try { [System.IO.File]::ReadAllText($path) } catch { '' }
        if (-not [long]::TryParse($text.Trim(), [ref]$value) -or $value -lt 0) { $value = 0L }
    }
    $value
}

function Get-HighestWakeSeq($Rows) {
    # The highest sequence in use: the counter or any queued row, whichever is
    # larger. Numbering past every queued row means a lost or corrupt counter
    # can never hand out a number that an outstanding ack would then consume.
    $highest = Get-WakeSeqCounter
    foreach ($row in @($Rows)) { if ($row.Seq -gt $highest) { $highest = $row.Seq } }
    $highest
}

function Test-FileEndsWithNewline([string]$Path) {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite)
    try {
        if ($stream.Length -eq 0) { return $true }
        $null = $stream.Seek(-1, [System.IO.SeekOrigin]::End)
        $stream.ReadByte() -eq 10
    }
    finally { $stream.Dispose() }
}

function Add-WakeEvent($WakeEvent) {
    # Give the wake the next sequence number and append it. Returns the wake
    # with its seq set. The counter is written before the row, so a crash
    # between the two skips a number rather than reusing one.
    $p = Get-DeputyPaths
    Invoke-WithStateLock {
        $seq = (Get-HighestWakeSeq (Read-WakeQueueRows)) + 1
        Write-FileAtomic $p.WakeSeq "$seq"
        if ($WakeEvent.PSObject.Properties['seq']) { $WakeEvent.seq = $seq }
        else { $WakeEvent | Add-Member -NotePropertyName 'seq' -NotePropertyValue $seq }
        $line = $WakeEvent | ConvertTo-Json -Compress -Depth 8
        # A writer killed mid-append leaves a line without its newline. Start a
        # fresh line so the torn one stays alone (drain retires it) instead of
        # swallowing this wake too.
        $prefix = ''
        if ((Test-Path -LiteralPath $p.WakeQueue) -and -not (Test-FileEndsWithNewline $p.WakeQueue)) {
            $prefix = [Environment]::NewLine
        }
        [System.IO.File]::AppendAllText($p.WakeQueue, $prefix + $line + [Environment]::NewLine)
    }
    $WakeEvent
}

function Get-PendingWakes {
    # Unacknowledged wakes, oldest first. Read only.
    Invoke-WithStateLock {
        Read-WakeQueueRows | Where-Object { $_.Seq -gt 0 } | Sort-Object Seq | ForEach-Object { $_.Wake }
    }
}

function Receive-Wakes {
    # The drain: unacknowledged wakes, oldest first, plus the text of any row
    # that could never be acknowledged. Those are retired here - the caller
    # must report them, because the queue was their only record.
    Invoke-WithStateLock {
        $rows = @(Read-WakeQueueRows)
        $unusable = @($rows | Where-Object { $_.Seq -le 0 })
        $usable = @($rows | Where-Object { $_.Seq -gt 0 } | Sort-Object Seq)
        if ($unusable.Count -gt 0) { Write-WakeQueueRows $usable }
        [pscustomobject]@{
            Wakes   = @($usable | ForEach-Object { $_.Wake })
            Retired = @($unusable | ForEach-Object { $_.Line })
        }
    }
}

function Complete-Wakes([long]$Through) {
    # The ack: remove every wake at or below $Through. A number that was never
    # handed out is refused - acknowledging it would also consume wakes that
    # have not happened yet, sight unseen.
    Invoke-WithStateLock {
        $rows = @(Read-WakeQueueRows)
        $highest = Get-HighestWakeSeq $rows
        if ($Through -gt $highest) {
            throw "Cannot acknowledge through seq $Through`: the highest wake sequence handed out is $highest. Run dep-wake.ps1 drain and use the command it prints."
        }
        $removed = @($rows | Where-Object { $_.Seq -gt 0 -and $_.Seq -le $Through })
        $kept = @($rows | Where-Object { $_.Seq -le 0 -or $_.Seq -gt $Through })
        if ($removed.Count -gt 0) { Write-WakeQueueRows $kept }
        [pscustomobject]@{
            Removed   = $removed.Count
            Remaining = @($kept | Where-Object { $_.Seq -gt 0 }).Count
        }
    }
}

function Get-TaskStatusNow([string]$Id) {
    # What a queued wake's task looks like right now: a wake can sit in the
    # queue long after the task moved on.
    try {
        $p = Get-DeputyPaths
        $name = "$(Assert-TaskId $Id).json"
        $active = Join-Path $p.State $name
        if (Test-Path -LiteralPath $active) { return [string](Get-Content $active -Raw | ConvertFrom-Json).status }
        if (Test-Path -LiteralPath (Join-Path $p.Archive $name)) { return 'returned' }
    }
    catch { $null = $_ }
    'unknown'
}

function Format-Wake {
    # One wake as the lines the Deputy reads. -Queued adds when it happened and
    # what its task looks like now, for a wake read back out of the queue.
    param([Parameter(Mandatory)]$Wake, [switch]$Queued)
    $head = '[wake] {0}: {1} ({2})' -f $Wake.taskId, $Wake.event, $Wake.kind
    if ($Wake.PSObject.Properties['seq'] -and $Wake.seq) { $head += " seq=$($Wake.seq)" }
    $head
    if ($Queued) {
        $at = ConvertTo-UtcDateTime $Wake.at
        $when = $at ? $at.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') : 'unknown time'
        '  queued: {0}; task now: {1}' -f $when, (Get-TaskStatusNow $Wake.taskId)
    }
    if ($Wake.prUrl) { '  pr: {0}' -f $Wake.prUrl }
    if ($Wake.prUrlRejected) { "  pr REJECTED (not this task's repo): {0}" -f $Wake.prUrlRejected }
    if ($Wake.summary) { '  {0}' -f $Wake.summary }
    if ($Wake.question) { '  question: {0}' -f $Wake.question }
    if ($script:FollowUpWakes -contains $Wake.event) {
        # These are answered in the member's own session, not with a respawn.
        '  follow-ups sent so far: {0}. Answer in the same session with: {1}' -f
            [int]$Wake.followUps, (Get-SendCommand $Wake.taskId)
    }
    if ($Wake.event -eq 'merged') {
        '  The work has landed. Tear the task down with: {0}' -f (Get-ReturnCommand $Wake.taskId)
    }
    if ($Wake.event -eq 'closed') {
        "  The work has NOT landed. Tell the Sheriff, and do not return the worktree without the Sheriff's word."
    }
}

function Get-WakeCommand([string]$Arguments) {
    'pwsh -NoProfile -File "{0}" {1}' -f (Join-Path (Get-DeputyPaths).Bin 'dep-wake.ps1'), $Arguments
}

function Format-WakeReport($Wakes) {
    # The drain report. Its LAST line is the exact command that acknowledges
    # everything above it - and nothing that arrives later.
    $wakes = @($Wakes)
    foreach ($wake in $wakes) { Format-Wake $wake -Queued }
    $through = ($wakes | ForEach-Object { [long]$_.seq } | Measure-Object -Maximum).Maximum
    "$($wakes.Count) unacknowledged wake(s). Handle each one, then acknowledge them with exactly this command:"
    Get-WakeCommand "ack -Through $through"
}

# ---------------------------------------------------------------------------
# Watcher singleton and heartbeat. One process scans at a time: it holds
# state\watcher.lock (its pid and start time, so a recycled pid is never
# mistaken for it) and touches state\watcher.beat on every poll. A watcher is
# healthy when the process in the lock is alive AND its heartbeat is fresh; a
# live process with a stale heartbeat is wedged, which is not the same thing.
# ---------------------------------------------------------------------------

function Get-WatcherStaleSeconds {
    # A scan can take a while (process checks, megabyte logs), so the heartbeat
    # gets generous room before the watcher counts as wedged.
    [math]::Max(120, 4 * [int](Get-DeputyConfig).watchIntervalSeconds)
}

function Read-WatcherLock {
    # The lock record, or $null when there is none or it cannot be read as one.
    $path = (Get-DeputyPaths).WatcherLock
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $lock = try { Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $null }
    if ($lock -isnot [pscustomobject]) { return $null }
    $lockPid = 0
    if (-not $lock.PSObject.Properties['pid'] -or -not [int]::TryParse([string]$lock.pid, [ref]$lockPid) -or $lockPid -le 0) {
        return $null
    }
    [pscustomobject]@{
        ProcessId = $lockPid
        StartedAt = $lock.PSObject.Properties['startedAt'] ? $lock.startedAt : $null
        Session   = $lock.PSObject.Properties['session'] ? [string]$lock.session : ''
    }
}

function Get-WatcherHealth {
    $p = Get-DeputyPaths
    $health = [pscustomobject]@{
        Healthy   = $false   # alive and polling
        Live      = $false   # the process in the lock is alive
        ProcessId = 0
        Session   = ''       # the Claude session whose stop hook started it, if any
        Reason    = 'no watcher is running'
    }
    $lock = Read-WatcherLock
    if (-not $lock) { return $health }
    $health.ProcessId = $lock.ProcessId
    $health.Session = $lock.Session

    $proc = Get-Process -Id $lock.ProcessId -ErrorAction SilentlyContinue
    $started = if ($proc) { try { $proc.StartTime } catch { $null } } else { $null }
    if (-not $proc -or -not (Test-ProcessStartMatch $started $lock.StartedAt)) {
        $health.Reason = "the watcher that held the lock (pid $($lock.ProcessId)) is gone"
        return $health
    }
    $health.Live = $true

    if (-not (Test-Path -LiteralPath $p.WatcherBeat)) {
        $health.Reason = "watcher pid $($lock.ProcessId) has not written a heartbeat"
        return $health
    }
    $age = ([datetime]::UtcNow - (Get-Item -LiteralPath $p.WatcherBeat).LastWriteTimeUtc).TotalSeconds
    if ($age -gt (Get-WatcherStaleSeconds)) {
        $health.Reason = 'watcher pid {0} has not polled for {1:n0} seconds' -f $lock.ProcessId, $age
        return $health
    }
    $health.Healthy = $true
    $health.Reason = "watcher pid $($lock.ProcessId) is polling"
    $health
}

function Test-WatcherHealthy {
    (Get-WatcherHealth).Healthy
}

function Test-WatcherServes($Health, [string]$Session) {
    # Will this watcher's wake reach the given Claude session? A watcher the
    # Deputy started by hand (no session recorded) reports to whoever started
    # it. One started by a stop hook wakes only the session that hook belongs
    # to - if that session has ended, its watcher is an orphan and its wakes go
    # nowhere but the queue.
    if (-not $Health.Healthy) { return $false }
    -not ($Session -and $Health.Session -and ($Health.Session -ne $Session))
}

function Set-WatcherBeat {
    [System.IO.File]::WriteAllText((Get-DeputyPaths).WatcherBeat, (Get-Date -Format o))
}

function Stop-Watcher([int]$ProcessId) {
    # Stop a watcher that has to be replaced. Only ever called for the process
    # the lock names (pid and start time already matched); it must also still
    # read as a watcher, or it is left alone. Killing one mid-scan is safe: a
    # wake is appended to the queue before its task record is written, so the
    # worst case is the same wake twice, never a lost one.
    $info = Get-ProcessInfo $ProcessId
    if (-not $info) { return $true }
    if ("$($info.CommandLine)" -notmatch 'dep-watch\.ps1') { return $false }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 50; $i++) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 100
    }
    $false
}

function Enter-WatcherLock([string]$Session) {
    <#
    .SYNOPSIS
    Become the one watcher. Returns Acquired, the Holder's health when someone
    else keeps the lock, and a Note when the lock was reclaimed or taken over.

    The lock of a watcher that is gone is reclaimed. A live watcher keeps it,
    with two exceptions where it is stopped and replaced: it is wedged (alive
    but not polling), or it was started by the stop hook of a different Claude
    session than the one asking, so its wake would reach nobody.
    #>
    $p = Get-DeputyPaths
    Invoke-WithStateLock {
        $note = ''
        $holder = Get-WatcherHealth
        if ($holder.Live) {
            if ($holder.Healthy -and (Test-WatcherServes $holder $Session)) {
                return [pscustomobject]@{ Acquired = $false; Holder = $holder; Note = '' }
            }
            $why = $holder.Healthy ? "it reports to another session ($($holder.Session))" : $holder.Reason
            if (-not (Stop-Watcher $holder.ProcessId)) {
                return [pscustomobject]@{
                    Acquired = $false; Holder = $holder
                    Note     = "pid $($holder.ProcessId) holds the watcher lock and should be replaced ($why), but it could not be stopped"
                }
            }
            $note = "took over from watcher pid $($holder.ProcessId): $why"
        }
        elseif ($holder.ProcessId) {
            $note = "reclaimed the lock: $($holder.Reason)"
        }
        $record = [ordered]@{
            pid       = $PID
            startedAt = (Get-Process -Id $PID).StartTime.ToString('o')
            session   = $Session
        }
        # The predecessor's heartbeat goes before the new identity is written,
        # so this watcher is never vouched for by a beat it did not write.
        Remove-Item -LiteralPath $p.WatcherBeat -Force -ErrorAction SilentlyContinue
        Write-FileAtomic $p.WatcherLock ($record | ConvertTo-Json -Compress)
        Set-WatcherBeat
        [pscustomobject]@{ Acquired = $true; Holder = $null; Note = $note }
    }
}

function Exit-WatcherLock {
    # Release the lock, if it is still this process's.
    $p = Get-DeputyPaths
    Invoke-WithStateLock {
        $lock = Read-WatcherLock
        if ($lock -and $lock.ProcessId -eq $PID) {
            Remove-Item -LiteralPath $p.WatcherLock, $p.WatcherBeat -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Session hooks (.claude\settings.json). Shared pieces of dep-hook-guard.ps1
# and dep-hook-stop.ps1.
# ---------------------------------------------------------------------------

# How many times in a row the stop guard may refuse a stop before it gives up
# and lets the session end, loudly.
$script:GuardMaxBlocks = 3

function Read-HookInput {
    # The JSON Claude Code hands a hook on stdin, or an empty object when there
    # is none (the script was run by hand) or it cannot be parsed.
    $empty = [pscustomobject]@{}
    if (-not [Console]::IsInputRedirected) { return $empty }
    $text = try { [Console]::In.ReadToEnd() } catch { '' }
    if (-not $text.Trim()) { return $empty }
    $parsed = try { $text | ConvertFrom-Json -ErrorAction Stop } catch { $null }
    if ($parsed -is [pscustomobject]) { $parsed } else { $empty }
}

function Get-HookField($HookInput, [string]$Name) {
    if ($HookInput -and $HookInput.PSObject.Properties[$Name]) { [string]$HookInput.$Name } else { '' }
}

function Get-StateCounter([string]$Path) {
    $value = 0
    if (Test-Path -LiteralPath $Path) {
        $text = try { [System.IO.File]::ReadAllText($Path) } catch { '' }
        if (-not [int]::TryParse($text.Trim(), [ref]$value) -or $value -lt 0) { $value = 0 }
    }
    $value
}

function Get-StopGuardDecision {
    <#
    .SYNOPSIS
    The stop guard's decision table, as a pure function.

    | tasks active | watcher healthy | blocks so far | action  | blocks after |
    | no           | any             | any           | allow   | 0            |
    | yes          | yes             | any           | allow   | 0            |
    | yes          | no              | below the max | block   | +1           |
    | yes          | no              | at the max    | release | unchanged    |

    'release' lets the stop through although nothing is watching, and says so.
    The count stays at the max afterwards, so a session that will not start a
    watcher is nagged a bounded number of times, not on every stop for ever;
    only a healthy watcher (or no tasks left) starts a new budget.
    #>
    param(
        [Parameter(Mandatory)][int]$ActiveTasks,
        [Parameter(Mandatory)][bool]$WatcherHealthy,
        [Parameter(Mandatory)][int]$Blocks,
        [int]$MaxBlocks = $script:GuardMaxBlocks
    )
    if ($ActiveTasks -le 0 -or $WatcherHealthy) {
        return [pscustomobject]@{ Action = 'allow'; Blocks = 0 }
    }
    if ($Blocks -lt $MaxBlocks) {
        return [pscustomobject]@{ Action = 'block'; Blocks = $Blocks + 1 }
    }
    [pscustomobject]@{ Action = 'release'; Blocks = $Blocks }
}

function Get-WakeAnnounced {
    # What the stop hook has already pushed at the session: the highest wake
    # sequence it announced, and how often it repeated that after API errors.
    $record = [pscustomobject]@{ Seq = 0L; Retries = 0 }
    $path = (Get-DeputyPaths).WakeAnnounced
    if (-not (Test-Path -LiteralPath $path)) { return $record }
    $parsed = try { Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $null }
    if ($parsed -is [pscustomobject]) {
        $seq = 0L; $retries = 0
        if ($parsed.PSObject.Properties['seq'] -and [long]::TryParse([string]$parsed.seq, [ref]$seq)) { $record.Seq = $seq }
        if ($parsed.PSObject.Properties['retries'] -and [int]::TryParse([string]$parsed.retries, [ref]$retries)) { $record.Retries = $retries }
    }
    $record
}

function Test-WakeAnnouncedSince([datetime]$SinceUtc) {
    # Did the stop hook push a wake at the session at or after this moment?
    $path = (Get-DeputyPaths).WakeAnnounced
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    (Get-Item -LiteralPath $path).LastWriteTimeUtc -ge $SinceUtc
}

function Set-WakeAnnounced([long]$Seq, [int]$Retries) {
    Write-FileAtomic (Get-DeputyPaths).WakeAnnounced (([ordered]@{ seq = $Seq; retries = $Retries }) | ConvertTo-Json -Compress)
}

# ---------------------------------------------------------------------------
# Toolchain health. Everything Deputy does stands on treehouse behaving, so the
# version floor lives here, once, and both dep-doctor.ps1 (which reports) and
# dep-spawn.ps1 (which refuses to lease) read it through the same functions.
# ---------------------------------------------------------------------------

# The oldest treehouse Deputy will lease from. Older releases can mislist the
# processes in a worktree on Windows, and Deputy kills what treehouse lists.
$script:TreehouseMinVersion = [version]'3.0.1'

# The one fix for an old treehouse. `treehouse update` goes to the latest
# release, which is the point: 3.0.0 is below the floor, so never stop there.
$script:TreehouseUpdateFix = 'treehouse update (with no tasks leased; it must go straight to the latest release, never to 3.0.0)'

function ConvertTo-TreehouseVersion([string]$Text) {
    # The version in `treehouse --version` output ('v3.1.8', 'treehouse version
    # 3.1.8', ...), or $null when there is none to find. A pre-release tag is
    # kept, because 3.0.1-rc1 sorts before 3.0.1 and so is below the floor.
    if (-not $Text) { return $null }
    if ($Text -notmatch '(?<![\w.])v?(?<core>\d+\.\d+\.\d+)(?<pre>-[0-9A-Za-z.-]+)?(?![\w.])') { return $null }
    $core = $null
    if (-not [version]::TryParse($Matches['core'], [ref]$core)) { return $null }
    [pscustomobject]@{
        Version    = $core
        PreRelease = [bool]$Matches['pre']
        Text       = $Matches['core'] + $Matches['pre']
    }
}

function Test-TreehouseVersion([string]$Text) {
    # True only when the text carries a version at or above the floor. Output
    # that cannot be parsed is incompatible: Deputy never guesses a version up.
    $parsed = ConvertTo-TreehouseVersion $Text
    if (-not $parsed) { return $false }
    if ($parsed.Version -gt $script:TreehouseMinVersion) { return $true }
    ($parsed.Version -eq $script:TreehouseMinVersion) -and -not $parsed.PreRelease
}

function Test-CommandOnPath([string]$Name) {
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-TreehouseProblems {
    # One line per treehouse problem, nothing when it is fit to lease from.
    if (-not (Test-CommandOnPath 'treehouse')) {
        'treehouse is not on PATH. Fix: irm https://kunchenguid.github.io/treehouse/install.ps1 | iex'
        return
    }
    $min = $script:TreehouseMinVersion
    $text = try { (treehouse --version 2>&1 | Out-String).Trim() } catch { '' }
    $parsed = ConvertTo-TreehouseVersion $text
    if (-not $parsed) {
        "treehouse --version printed '$(Limit-Text $text 60)', which is not a version Deputy can read, so it is treated as incompatible (need $min or later). Fix: $script:TreehouseUpdateFix"
    }
    elseif (-not (Test-TreehouseVersion $text)) {
        "treehouse $($parsed.Text) is older than the minimum $min. Fix: $script:TreehouseUpdateFix"
    }
    # The flags dep-spawn.ps1 leases with. All three are in treehouse 3.0.0 and
    # later, so the version floor covers them; asking the binary itself also
    # catches a build that reports a good version and lacks one.
    $help = try { (treehouse get --help 2>&1 | Out-String) } catch { '' }
    $needed = [ordered]@{
        '--lease'  = 'to lease worktrees'
        '--branch' = "to create each ship task's branch"
        '--base'   = 'to cut a worktree from a base branch'
    }
    foreach ($flag in $needed.Keys) {
        if ($help -notmatch ([regex]::Escape($flag) + '(?![\w-])')) {
            "treehouse get --help does not list $flag, which Deputy needs $($needed[$flag]). Fix: $script:TreehouseUpdateFix"
        }
    }
}

# ---------------------------------------------------------------------------
# Leases. dep-spawn.ps1 checks what treehouse handed it before a member is
# launched there, and gives back a lease it will not use.
# ---------------------------------------------------------------------------

function Get-LeaseProblems {
    <#
    .SYNOPSIS
    Is a fresh lease fit to launch a member in? One line per problem, nothing
    when it is.

    The lease must be a git worktree of its own - the top of the worktree git
    finds there (git rev-parse) - and not the repository's own checkout: a
    member launched anywhere else would work in, and could wreck, the
    Sheriff's checkout or some unrelated tree. A ship task's worktree must also
    be on the branch the lease was asked to create.

    Only git's answers are compared with each other, never with the path as
    treehouse or the caller wrote it: git may print a long path where the
    other has an 8.3 short one (C:\Users\RUNNER~1\...), and a path that differs
    only in spelling must not read as a different directory.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$LeasePath,
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$Branch
    )
    if (-not $LeasePath -or -not (Test-Path -LiteralPath $LeasePath -PathType Container)) {
        "the lease path '$LeasePath' is not a directory"
        return
    }
    $top = (git -C $LeasePath rev-parse --show-toplevel 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $top) {
        "'$LeasePath' is not inside a git worktree (git rev-parse --show-toplevel failed there)"
        return
    }
    # Empty when the lease is the top of its worktree, 'sub/dir/' below it.
    $prefix = (git -C $LeasePath rev-parse --show-prefix 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $prefix) {
        "git resolves the lease '$LeasePath' to the worktree '$top', not to the lease itself"
        return
    }
    $repoTop = (git -C $RepoPath rev-parse --show-toplevel 2>$null | Out-String).Trim()
    if (-not $repoTop) {
        "the checkout of '$RepoPath' cannot be resolved, so the lease cannot be shown to be separate from it"
        return
    }
    if (Test-SamePath $top $repoTop) {
        "the lease '$LeasePath' is the repository's own checkout, not an isolated worktree"
        return
    }
    if ($Branch) {
        $current = (git -C $LeasePath branch --show-current 2>$null | Out-String).Trim()
        if ($current -ne $Branch) {
            $on = if ($current) { "on '$current'" } else { 'on a detached HEAD' }
            "the worktree is $on, not on the task branch '$Branch'"
        }
    }
}

function Undo-Lease {
    <#
    .SYNOPSIS
    Give back a lease dep-spawn.ps1 took and will not launch a member in.
    Returns $true when treehouse released it.

    Guarded by the lease id, so nothing but that lease can be released, and
    never forced: without --force treehouse leaves a slot with changes in it
    alone rather than resetting it, and refuses a path it does not manage -
    which is what a lease that failed the isolation check may be.
    #>
    param([Parameter(Mandatory)]$Lease, [Parameter(Mandatory)][string]$RepoPath)
    Push-Location $RepoPath
    try {
        # Nothing on stdin: a confirmation prompt reads EOF and declines.
        $null | treehouse return $Lease.path --if-lease-id $Lease.lease_id *> $null
        $LASTEXITCODE -eq 0
    }
    catch { $false }
    finally { Pop-Location }
}

function Get-DeputyCloneProblems([string]$Root) {
    # Is the Deputy clone on its default branch, and not behind origin? Report
    # only: this never fetches, pulls or switches. ls-remote reads the remote
    # without touching a single local ref.
    git -C $Root rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) {
        "The Deputy directory $Root is not a git clone, so it cannot be checked for updates. Fix: reinstall with git clone (see ONBOARDING.md, 'Get Deputy')"
        return
    }
    $branch = (Resolve-DefaultRef $Root).Branch
    if (-not $branch) {
        "The default branch of the Deputy clone at $Root cannot be resolved. Fix: git -C `"$Root`" remote set-head origin -a"
        return
    }
    $current = (git -C $Root branch --show-current 2>$null | Out-String).Trim()
    if ($current -ne $branch) {
        $where = $current ? "branch '$current'" : 'a detached HEAD'
        "The Deputy clone at $Root is on $where, not its default branch '$branch'. Fix: git -C `"$Root`" switch $branch"
    }
    $remotes = @(git -C $Root remote 2>$null)
    if ($remotes -notcontains 'origin') { return }

    $previousPrompt = $env:GIT_TERMINAL_PROMPT
    $env:GIT_TERMINAL_PROMPT = '0'  # a doctor must fail, not sit at a credential prompt
    try { $listing = git -C $Root ls-remote origin "refs/heads/$branch" 2>$null; $code = $LASTEXITCODE }
    finally { $env:GIT_TERMINAL_PROMPT = $previousPrompt }
    if ($code -ne 0) {
        "Could not reach origin to check whether the Deputy clone at $Root is behind. Fix: git -C `"$Root`" ls-remote origin (resolve the error it prints)"
        return
    }
    $remoteSha = (("$($listing | Select-Object -First 1)") -split '\s+')[0]
    if (-not $remoteSha) {
        "origin has no branch '$branch' for the Deputy clone at $Root. Fix: git -C `"$Root`" remote set-head origin -a"
        return
    }
    # Behind means origin's tip is not already contained in the local default
    # branch. A commit this clone has never fetched is an unknown object, which
    # fails the ancestry test too - also behind.
    $local = (Test-GitRef $Root "refs/heads/$branch") ? "refs/heads/$branch" : 'HEAD'
    git -C $Root merge-base --is-ancestor $remoteSha $local *> $null
    if ($LASTEXITCODE -ne 0) {
        "The Deputy clone at $Root is behind origin/$branch. Fix: git -C `"$Root`" pull --ff-only"
    }
}

function Get-DoctorProblems {
    # Every toolchain problem dep-doctor.ps1 reports, one line each, each line
    # naming its exact fix. Empty when healthy. (The PowerShell version check is
    # in dep-doctor.ps1 itself: this file cannot even be parsed below 7.)
    $installFix = [ordered]@{
        git    = 'winget install --id Git.Git -e'
        gh     = 'winget install --id GitHub.cli -e'
        claude = 'irm https://claude.ai/install.ps1 | iex'
    }
    foreach ($tool in $installFix.Keys) {
        if (-not (Test-CommandOnPath $tool)) { "$tool is not on PATH. Fix: $($installFix[$tool])" }
    }
    if (Test-CommandOnPath 'gh') {
        gh auth status *> $null
        if ($LASTEXITCODE -ne 0) { 'gh is not authenticated (gh auth status failed). Fix: gh auth login' }
    }
    Get-TreehouseProblems
    if (Test-CommandOnPath 'git') { Get-DeputyCloneProblems (Get-DeputyPaths).Root }
}

# ---------------------------------------------------------------------------
# Process handling. Deputy force-kills process trees, so every pid is treated
# as a claim to be checked: treehouse's listing is evidence of where to look,
# never by itself a licence to kill.
# ---------------------------------------------------------------------------

# More processes than this in one worktree is not a posse member, it is
# treehouse mislisting (an old version can report the whole machine).
$script:MaxWorktreeProcesses = 50

# Pids that are never a posse member: the System Idle Process and System.
$script:ReservedProcessIds = @(0, 4)

function Get-ProcessInfo([int]$ProcessId) {
    # What Deputy can read about a live process, or $null when it is gone or
    # unreadable. ExecutablePath and CommandLine come back empty for processes
    # this user may not inspect, which is exactly what callers test for.
    $proc = try {
        Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
    }
    catch { $null }
    if (-not $proc) { return $null }
    [pscustomobject]@{
        ProcessId       = [int]$proc.ProcessId
        ParentProcessId = [int]$proc.ParentProcessId
        ExecutablePath  = $proc.ExecutablePath
        CommandLine     = $proc.CommandLine
        StartTime       = $proc.CreationDate
    }
}

function Get-ProcessWorkingDirectory([int]$ProcessId) {
    # The current directory of another process, read from its PEB, or $null
    # when it cannot be read (gone, protected, 32-bit, or this is not 64-bit
    # Windows). Deputy reads it itself rather than taking treehouse's word, so
    # a mislisted pid is caught here instead of being killed.
    if (-not ('Deputy.ProcessCwd' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Deputy {
    public static class ProcessCwd {
        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessBasicInformation {
            public IntPtr ExitStatus;
            public IntPtr PebBaseAddress;
            public IntPtr AffinityMask;
            public IntPtr BasePriority;
            public IntPtr UniqueProcessId;
            public IntPtr InheritedFromUniqueProcessId;
        }

        [DllImport("ntdll.dll")]
        private static extern int NtQueryInformationProcess(IntPtr process, int infoClass,
            ref ProcessBasicInformation info, int size, out int returned);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inherit, int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer,
            IntPtr size, out IntPtr read);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll")]
        private static extern bool IsWow64Process(IntPtr process, out bool wow64);

        private static byte[] Read(IntPtr process, IntPtr address, int size) {
            byte[] buffer = new byte[size];
            IntPtr read;
            if (!ReadProcessMemory(process, address, buffer, (IntPtr)size, out read)) return null;
            return read.ToInt64() == size ? buffer : null;
        }

        public static string Get(int processId) {
            // The offsets below are the 64-bit PEB layout; anything else is
            // reported as unreadable rather than guessed at.
            if (IntPtr.Size != 8) return null;
            const uint QueryInformation = 0x0400, VmRead = 0x0010;
            IntPtr process = OpenProcess(QueryInformation | VmRead, false, processId);
            if (process == IntPtr.Zero) return null;
            try {
                bool wow64;
                if (!IsWow64Process(process, out wow64) || wow64) return null;
                ProcessBasicInformation info = new ProcessBasicInformation();
                int returned;
                if (NtQueryInformationProcess(process, 0, ref info, Marshal.SizeOf(info), out returned) != 0) return null;
                if (info.PebBaseAddress == IntPtr.Zero) return null;

                // PEB.ProcessParameters
                byte[] pointer = Read(process, IntPtr.Add(info.PebBaseAddress, 0x20), 8);
                if (pointer == null) return null;
                IntPtr parameters = (IntPtr)BitConverter.ToInt64(pointer, 0);
                if (parameters == IntPtr.Zero) return null;

                // RTL_USER_PROCESS_PARAMETERS.CurrentDirectory.DosPath (UNICODE_STRING)
                byte[] unicodeString = Read(process, IntPtr.Add(parameters, 0x38), 16);
                if (unicodeString == null) return null;
                int length = BitConverter.ToUInt16(unicodeString, 0);
                IntPtr text = (IntPtr)BitConverter.ToInt64(unicodeString, 8);
                if (length == 0 || (length % 2) != 0 || text == IntPtr.Zero) return null;

                byte[] chars = Read(process, text, length);
                return chars == null ? null : Encoding.Unicode.GetString(chars);
            }
            finally { CloseHandle(process); }
        }
    }
}
'@
    }
    try { [Deputy.ProcessCwd]::Get($ProcessId) } catch { $null }
}

function Test-PathUnder([string]$Path, [string]$Root) {
    # Is $Path the directory $Root or somewhere beneath it? Compared on whole
    # path segments, so C:\pool\10 is not under C:\pool\1.
    if (-not $Path -or -not $Root) { return $false }
    try {
        $p = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
        $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    }
    catch { return $false }
    if (-not $r) { return $false }
    $p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or
        $p.StartsWith($r + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Test-SamePath([string]$A, [string]$B) {
    # Do two paths name the same directory, however their separators, case and
    # trailing slashes are written? (git prints C:/x/y where Windows has C:\x\y.)
    if (-not $A -or -not $B) { return $false }
    try {
        $x = [System.IO.Path]::GetFullPath($A).TrimEnd('\', '/')
        $y = [System.IO.Path]::GetFullPath($B).TrimEnd('\', '/')
    }
    catch { return $false }
    $x.Equals($y, [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-UtcDateTime($Value) {
    # Task state round-trips through JSON, and ConvertFrom-Json hands an ISO
    # timestamp back as a DateTime, not a string. Take either, and never turn a
    # DateTime back into text to re-parse it: that goes through the current
    # culture and loses the sub-second part.
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    $parsed = [datetimeoffset]::MinValue
    $ok = [datetimeoffset]::TryParse([string]$Value, [cultureinfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)
    if ($ok) { $parsed.UtcDateTime } else { $null }
}

function Test-ProcessStartMatch($Started, $Recorded) {
    # Windows recycles pids, so a pid is only the recorded process when its
    # start time is the recorded one (within a small tolerance).
    $a = ConvertTo-UtcDateTime $Started
    $b = ConvertTo-UtcDateTime $Recorded
    if ($null -eq $a -or $null -eq $b) { return $false }
    [math]::Abs(($a - $b).TotalSeconds) -le 2
}

function Get-WorktreeProcessIds([string]$RepoPath, [string]$WorktreePath) {
    # Processes treehouse sees running inside a worktree (matched by CWD),
    # filtered down to pids that can plausibly be a posse member's.
    Push-Location $RepoPath
    try { $raw = treehouse status --json 2>$null }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
    $pool = try { ($raw -join "`n") | ConvertFrom-Json } catch { return @() }
    $entry = $pool | Where-Object { $_.path -ieq $WorktreePath } | Select-Object -First 1
    if (-not $entry -or -not $entry.processes) { return @() }
    $listed = @($entry.processes | ForEach-Object {
        if ($_ -is [string]) { if ($_ -match '\((\d+)\)') { [int]$Matches[1] } }
        elseif ($_.PSObject.Properties['pid']) { [int]$_.pid }
        elseif ($_.PSObject.Properties['id']) { [int]$_.id }
    } | Where-Object { $_ -and $script:ReservedProcessIds -notcontains $_ } | Select-Object -Unique)

    if ($listed.Count -gt $script:MaxWorktreeProcesses) {
        Write-Warning ("treehouse lists $($listed.Count) processes in $WorktreePath, more than the " +
            "$script:MaxWorktreeProcesses a worktree can plausibly hold. Treating the listing as wrong and " +
            "ignoring all of it. Run dep-doctor.ps1 to check the treehouse version.")
        return @()
    }
    # A pid that cannot be read is gone, or was never ours to look at.
    @($listed | Where-Object { Get-ProcessInfo $_ })
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
            if (Test-ProcessStartMatch $started $recorded) { return $true }
        }
    }
    if ($State.worktree -and (Test-Path $State.worktree) -and (Test-Path $State.repo)) {
        return @(Get-WorktreeProcessIds $State.repo $State.worktree).Count -gt 0
    }
    $false
}

function Test-ProcessDescendsFromMember($Info, $State) {
    # Does this process sit in the tree under the recorded member pid? Walks
    # parent links upward. Every hop is checked against pid recycling: a parent
    # must have started no later than its child, and the member pid itself must
    # carry the recorded start time.
    $memberPid = [int]($State.pid ?? 0)
    $recorded = $State.PSObject.Properties['pidStartedAt'] ? $State.pidStartedAt : $null
    if (-not $memberPid -or -not $recorded) { return $false }  # no verifiable root

    $current = $Info
    for ($hop = 0; $hop -lt 32 -and $current; $hop++) {
        if ($current.ProcessId -eq $memberPid) {
            return Test-ProcessStartMatch $current.StartTime $recorded
        }
        $childStart = ConvertTo-UtcDateTime $current.StartTime
        if ($null -eq $childStart -or -not $current.ParentProcessId) { return $false }
        $parent = Get-ProcessInfo $current.ParentProcessId
        $parentStart = $parent ? (ConvertTo-UtcDateTime $parent.StartTime) : $null
        $parentIsOriginal = ($null -ne $parentStart) -and ($parentStart -le $childStart)
        if (-not $parentIsOriginal) {
            # The parent has exited (its pid is free, or reused by something
            # younger). Only a child of the member itself can still be placed:
            # it names the member pid and was born after the member started.
            $recordedStart = ConvertTo-UtcDateTime $recorded
            return ($current.ParentProcessId -eq $memberPid) -and ($null -ne $recordedStart) -and
                ($childStart -ge $recordedStart.AddSeconds(-2))
        }
        $current = $parent
    }
    $false
}

function Test-TaskOwnsProcess($State, [int]$ProcessId) {
    # The whole licence to kill. A pid is the task's only when Deputy can read
    # what it is (executable path or command line) AND can place it: in the
    # process tree under the recorded member pid, or working inside the task's
    # worktree. Anything unreadable or unplaceable is left alone.
    if ($script:ReservedProcessIds -contains $ProcessId) { return $false }
    $info = Get-ProcessInfo $ProcessId
    if (-not $info) { return $false }
    if (-not $info.ExecutablePath -and -not $info.CommandLine) { return $false }
    if (Test-ProcessDescendsFromMember $info $State) { return $true }
    if (-not $State.worktree) { return $false }
    Test-PathUnder (Get-ProcessWorkingDirectory $ProcessId) $State.worktree
}

function Get-OwnProcessChain {
    # This process and its ancestors. Killing any of them takes the caller
    # down with it, so they are never a kill target whatever else is true.
    $chain = @()
    $current = Get-ProcessInfo $PID
    for ($hop = 0; $hop -lt 32 -and $current; $hop++) {
        $chain += $current.ProcessId
        $childStart = ConvertTo-UtcDateTime $current.StartTime
        $parent = $current.ParentProcessId ? (Get-ProcessInfo $current.ParentProcessId) : $null
        $parentStart = $parent ? (ConvertTo-UtcDateTime $parent.StartTime) : $null
        if ($null -eq $parentStart -or $null -eq $childStart -or $parentStart -gt $childStart) { break }
        $current = $parent
    }
    if ($chain -notcontains $PID) { $chain += $PID }
    $chain
}

function Stop-TaskProcessTree([int]$ProcessId) {
    # taskkill /T takes the whole child tree down (claude spawns helpers)
    taskkill /PID $ProcessId /T /F 2>$null | Out-Null
}

function Stop-TaskProcesses($State) {
    # Stop a task's processes: the recorded member pid, plus whatever treehouse
    # lists in the worktree (the recorded pid may be a dead launcher). Each
    # candidate must pass Test-TaskOwnsProcess first; the rest are reported and
    # left running. Returns the pids whose trees were killed.
    $candidates = @()
    if ($State.pid) { $candidates += [int]$State.pid }
    if ($State.worktree -and $State.repo -and (Test-Path $State.worktree) -and (Test-Path $State.repo)) {
        $candidates += @(Get-WorktreeProcessIds $State.repo $State.worktree)
    }
    $own = @(Get-OwnProcessChain)
    $killed = @()
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if ($own -contains $candidate) { continue }
        # Checked one at a time, in order: killing a tree usually takes later
        # candidates with it, and those then read as gone rather than as ours.
        if (-not (Get-ProcessInfo $candidate)) { continue }
        if (Test-TaskOwnsProcess $State $candidate) {
            Stop-TaskProcessTree $candidate
            $killed += $candidate
        }
        else {
            Write-Warning ("left pid $candidate running: it could not be shown to belong to $($State.id) " +
                "(not readable, not under the member pid, and not working in the task worktree)")
        }
    }
    $killed
}

# ---------------------------------------------------------------------------
# Member sessions. A member is a headless claude session with an id Deputy
# chose, so it can be resumed: dep-spawn.ps1 starts it, dep-send.ps1 continues
# it with a follow-up message once its process has exited. Both build their
# command line and launch through the functions here, so a resumed run is
# started exactly like the first one.
# ---------------------------------------------------------------------------

$script:MemberEffortLevels = @('low', 'medium', 'high', 'xhigh', 'max')

# The statuses a member can end its structured final report with, and the wake
# each one becomes. 'done' and 'failed' keep the wakes they always had.
$script:MemberReportWakes = [ordered]@{
    'done'           = 'completed'
    'blocked'        = 'blocked'
    'needs-decision' = 'needs-decision'
    'failed'         = 'failed'
}

# Wakes that are answered with dep-send.ps1 rather than a respawn.
$script:FollowUpWakes = @('interrupted', 'blocked', 'needs-decision')

# HTTP statuses of a server-side failure that is expected to pass by itself.
$script:TransientApiStatuses = @(429, 500, 502, 503, 529)

function Get-MemberReportSchema {
    # The JSON schema of a member's final report, passed as --json-schema. One
    # line, and deliberately free of spaces and of anything a shell could read
    # as an operator: it travels on a command line.
    $schema = [ordered]@{
        type                 = 'object'
        properties           = [ordered]@{
            status   = [ordered]@{ type = 'string'; enum = @($script:MemberReportWakes.Keys) }
            summary  = [ordered]@{ type = 'string' }
            tests    = [ordered]@{ type = 'string' }
            question = [ordered]@{ type = 'string' }
            prUrl    = [ordered]@{ type = 'string' }
        }
        required             = @('status', 'summary')
        additionalProperties = $false
    }
    $schema | ConvertTo-Json -Compress -Depth 6
}

function Get-MemberReportInstructions([switch]$PullRequest) {
    # The closing section of every briefing: how a member fills in its report.
    $lines = @(
        'Your final message is your report to the Deputy, and it is structured: this session enforces a JSON schema on it. Fill it in honestly:'
        '- status: "done" (the task is finished and you verified it), "blocked" (you cannot go on without something only the Deputy or the Sheriff can provide), "needs-decision" (there is a choice that is not yours to make) or "failed" (you tried and could not do it).'
        '- summary: short and plain. What you did and found, or what stopped you.'
        '- tests: the commands you ran and their exact results. Leave it out if you ran none.'
        '- question: required when status is "blocked" or "needs-decision". The one thing you need answered, with the options you see and the one you recommend.'
    )
    if ($PullRequest) { $lines += '- prUrl: the URL of the pull request you opened. Leave it out if you opened none.' }
    $lines += 'This session can be resumed: the Deputy can answer your question with a follow-up message and you carry on here with everything you know. So when you are blocked or a decision is not yours, stop and ask instead of guessing.'
    $lines -join "`n"
}

# Every briefing carries this sentence, and AGENTS.md opens with it, word for
# word (a test holds the two together). A member working on a repository whose
# own instructions describe a Deputy - Deputy itself - must not take that role,
# and those instructions are loaded as project context whatever the hooks do.
$script:MemberRoleSentence = 'A posse member launched by Deputy into a worktree of this repository follows its briefing and is not the Deputy.'

function Get-MemberBriefing {
    <#
    .SYNOPSIS
    The briefing a member is given on stdin: who it is, its task, the ground
    rules of its kind, the definition of done of its delivery mode, and how to
    report. One function for every kind, so the parts they share cannot drift
    apart.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('ship', 'scout')][string]$Kind,
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][string]$Worktree,
        # ship: no-mistakes or direct-pr.
        [string]$Delivery,
        # ship: the branch the lease created and checked out.
        [string]$Branch,
        # The branch the worktree was cut from, when it is known.
        [string]$BaseBranch,
        # scout: where the full report goes.
        [string]$ReportPath
    )
    if ($Kind -eq 'ship') {
        if (-not $Branch) { throw 'A ship briefing needs the branch the lease created.' }
        if ($script:DeliveryModes -notcontains $Delivery) {
            throw "Delivery '$Delivery' is not one of: $($script:DeliveryModes -join ', ')."
        }
    }
    elseif (-not $ReportPath) { throw 'A scout briefing needs the report path.' }
    $base = if ($BaseBranch) { $BaseBranch } else { 'the default branch' }

    $lines = @(
        'You are a posse member reporting to the Deputy. Assignment kind: {0}.' -f $(
            if ($Kind -eq 'ship') { 'ship (deliver working code)' } else { 'scout (investigate and report, change nothing)' })
        ''
        'Task:'
        $Task
        ''
        'Your role:'
        ("- $script:MemberRoleSentence If this repository's own instructions (AGENTS.md, CLAUDE.md) describe a " +
            'Deputy or a supervisor, that role is not yours: do the work yourself, and never spawn, message or supervise posse members.')
        ''
        'Ground rules:'
    )
    if ($Kind -eq 'ship') {
        $lines += @(
            ("- You are in a leased git worktree at $Worktree, already on your own branch $Branch, cut from $base. " +
                'Work only inside this worktree and on this branch: do not switch branches, create other branches, or rebase onto another branch.')
            "- Implement the task with quality. Run the repo's relevant tests and lint before finishing, and fix failures you cause."
            '- If you are blocked or the task turns out to be wrong or impossible, stop and say so clearly instead of guessing.'
            ''
        )
        if ($Delivery -eq 'no-mistakes') {
            $lines += @(
                'Definition of done (no-mistakes delivery):'
                "- All your work is committed on $Branch with clear messages, and git status is clean. Never add co-author lines."
                '- Do NOT push and do NOT open a pull request. The Deputy validates your branch with its no-mistakes gate and publishes it.'
            )
        }
        else {
            $baseFlag = if ($BaseBranch) { "--base $BaseBranch " } else { '' }
            $lines += @(
                'Definition of done (direct-pr delivery):'
                "- All your work is committed on $Branch with clear messages. Never add co-author lines."
                ("- The branch is pushed and a pull request is open against $base (for example: gh pr create $baseFlag" +
                    '--title "..." --body "..."). If the repo has no remote you can push to, commit locally and say so in your report.')
            )
        }
    }
    else {
        $lines += @(
            ("- You are in a leased git worktree at $Worktree, on a detached HEAD of $base. It is read-only by convention: " +
                'do not modify files in the repo, do not commit, do not open pull requests.')
            '- Investigate thoroughly: read code, run read-only commands, trace the answer.'
            '- If you are blocked or the question turns out to be wrong or unanswerable, stop and say so clearly instead of guessing.'
            ''
            'Definition of done (scout):'
            "- Your full report is written as markdown to this exact path: $ReportPath"
            '- Nothing in the worktree is changed: git status is clean.'
        )
    }
    $lines += ''
    $lines += Get-MemberReportInstructions -PullRequest:($Kind -eq 'ship' -and $Delivery -eq 'direct-pr')
    if ($Kind -eq 'scout') {
        $lines += 'For a scout, summary holds the key findings in a few sentences; the full report is the file at the path above.'
    }
    $lines -join "`n"
}

function ConvertTo-InvariantNumber($Value) {
    # A number read from JSON or a command line as a double, or $null when it
    # is not one. Never through the current culture: 1.5 must not become 15.
    if ($null -eq $Value) { return $null }
    $parsed = 0.0
    $text = [string]::Format([cultureinfo]::InvariantCulture, '{0}', $Value)
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    $null
}

function Get-MemberArguments {
    <#
    .SYNOPSIS
    The claude arguments for a member run: a new session (-SessionId with
    -Name), or a finished one continued (-SessionId with -Resume).

    Everything except the session flags is the same for both, which is the
    point: permissions, isolation, model, effort, budget and the report schema
    belong to the process, not to the stored session, so a resumed run has to
    be given them again.

    -Isolation launches the member without the operator's personal setup:
    --strict-mcp-config (no MCP servers, since none are given with
    --mcp-config) and --disable-slash-commands (no skills, no slash commands).
    Authentication, the user's and the repository's CLAUDE.md, hooks and
    plugins' agents are not affected (see README, "Member environment").
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [switch]$Resume,
        [string]$Name,
        [string]$Model,
        [string]$PermissionMode = 'bypassPermissions',
        [string[]]$AllowedTools,
        [switch]$Isolation,
        [string]$Effort,
        $MaxBudgetUsd,
        [string[]]$AddDir
    )
    $parsedId = [guid]::Empty
    if (-not [guid]::TryParse($SessionId, [ref]$parsedId)) { throw "Session id '$SessionId' is not a UUID." }
    if ($Effort -and $script:MemberEffortLevels -notcontains $Effort) {
        throw "Effort '$Effort' is not one of: $($script:MemberEffortLevels -join ', ')."
    }

    $arguments = @('-p', '--output-format', 'stream-json', '--verbose')
    if ($Model) { $arguments += @('--model', "$Model") }
    if ($PermissionMode -eq 'bypassPermissions') { $arguments += '--dangerously-skip-permissions' }
    else {
        # Nobody can answer a permission prompt in a headless run. With
        # --permission-prompts none anything that would prompt is denied on
        # the spot, so the member hears no and can report what it could not
        # do; the permission mode and the grants still decide everything else.
        $arguments += @('--permission-mode', $PermissionMode, '--permission-prompts', 'none')
        if ($AllowedTools) { $arguments += @('--allowedTools', ($AllowedTools -join ',')) }
    }
    if ($Isolation) { $arguments += @('--strict-mcp-config', '--disable-slash-commands') }
    foreach ($dir in @($AddDir | Where-Object { $_ })) { $arguments += @('--add-dir', $dir) }
    if ($Effort) { $arguments += @('--effort', $Effort) }
    if ($null -ne $MaxBudgetUsd -and "$MaxBudgetUsd" -ne '') {
        $budget = ConvertTo-InvariantNumber $MaxBudgetUsd
        if ($null -eq $budget -or $budget -le 0) { throw "MaxBudgetUsd '$MaxBudgetUsd' is not a positive amount." }
        $arguments += @('--max-budget-usd', $budget.ToString([cultureinfo]::InvariantCulture))
    }
    $arguments += @('--json-schema', (Get-MemberReportSchema))
    if ($Resume) { $arguments += @('--resume', $SessionId) }
    else {
        $arguments += @('--session-id', $SessionId)
        if ($Name) { $arguments += @('-n', $Name) }
    }
    $arguments
}

function Get-TaskMemberArguments($State, [switch]$Resume) {
    # A task's member arguments, from what its record says it was spawned with.
    $read = { param($name) if ($State.PSObject.Properties[$name]) { $State.$name } else { $null } }
    $settings = @{
        SessionId      = [string](& $read 'sessionId')
        Resume         = [bool]$Resume
        Name           = $State.id
        Model          = [string](& $read 'model')
        PermissionMode = [string](& $read 'permissionMode')
        AllowedTools   = @(& $read 'allowedTools' | Where-Object { $_ })
        # A task spawned before memberIsolation existed ran without it, and a
        # resumed run must not change the environment the session started in.
        Isolation      = [bool](& $read 'memberIsolation')
        Effort         = [string](& $read 'effort')
        MaxBudgetUsd   = (& $read 'maxBudgetUsd')
        # Scouts write their report into the deputy state dir, outside their worktree
        AddDir         = @(if ($State.kind -eq 'scout') { (Get-DeputyPaths).State })
    }
    if (-not $settings.PermissionMode) { $settings.PermissionMode = 'bypassPermissions' }
    Get-MemberArguments @settings
}

function ConvertTo-ProcessArgument([string]$Value) {
    # One argument, quoted the way the Windows C runtime reads a command line:
    # backslashes are literal except in front of a double quote, where they
    # double, and a quote inside the argument is escaped with one more.
    if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
    $text = [System.Text.StringBuilder]::new('"')
    $backslashes = 0
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq [char]'\') { $backslashes++; continue }
        if ($char -eq [char]'"') { $null = $text.Append([char]'\', (2 * $backslashes) + 1) }
        else { $null = $text.Append([char]'\', $backslashes) }
        $null = $text.Append($char)
        $backslashes = 0
    }
    $null = $text.Append([char]'\', 2 * $backslashes).Append([char]'"')
    $text.ToString()
}

function Get-MemberCommandLine([string]$Executable, [string[]]$Arguments) {
    # The program to start and its full command line. A .cmd or .bat shim is
    # not an executable, so it runs under cmd.exe; /s makes cmd strip exactly
    # the outer pair of quotes and take the rest as written.
    $line = (@($Executable) + @($Arguments) | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' '
    if ($Executable -match '\.(cmd|bat)$') {
        $shell = $env:ComSpec
        return [pscustomobject]@{
            FilePath    = $shell
            CommandLine = '{0} /d /s /c "{1}"' -f (ConvertTo-ProcessArgument $shell), $line
        }
    }
    [pscustomobject]@{ FilePath = $Executable; CommandLine = $line }
}

function Start-MemberProcess {
    <#
    .SYNOPSIS
    Start a member process in a worktree: stdin from a file, stdout and stderr
    APPENDED to the task's logs, no window. Returns its pid and start time.

    Start-Process cannot do this - its redirection truncates the target, and a
    resumed run has to continue the log the first run wrote. So the process is
    created directly, with the three files as its standard handles and nothing
    else inherited: a member that inherited the caller's own output pipe would
    hold it open for as long as it runs.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$StdinFile,
        [Parameter(Mandatory)][string]$StdoutLog,
        [Parameter(Mandatory)][string]$StderrLog
    )
    if (-not ('Deputy.MemberLauncher' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Deputy {
    public static class MemberLauncher {
        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes {
            public int Length;
            public IntPtr SecurityDescriptor;
            public int InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo {
            public int Cb;
            public IntPtr Reserved;
            public IntPtr Desktop;
            public IntPtr Title;
            public int X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
            public short ShowWindow;
            public short Reserved2Size;
            public IntPtr Reserved2;
            public IntPtr StdInput, StdOutput, StdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfoEx {
            public StartupInfo StartupInfo;
            public IntPtr AttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation {
            public IntPtr Process, Thread;
            public int ProcessId, ThreadId;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateFileW(string name, uint access, uint share,
            ref SecurityAttributes security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute,
            IntPtr value, IntPtr size, IntPtr previous, IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr list);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool CreateProcessW(string application, System.Text.StringBuilder commandLine,
            IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint flags,
            IntPtr environment, string currentDirectory, ref StartupInfoEx startupInfo,
            out ProcessInformation processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit,
            out long kernel, out long user);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        private static readonly IntPtr InvalidHandle = new IntPtr(-1);

        private static IntPtr Open(string path, uint access, uint disposition) {
            SecurityAttributes security = new SecurityAttributes();
            security.Length = Marshal.SizeOf(typeof(SecurityAttributes));
            security.InheritHandle = 1;
            const uint ShareAll = 0x1 | 0x2 | 0x4, AttributeNormal = 0x80;
            IntPtr handle = CreateFileW(path, access, ShareAll, ref security, disposition, AttributeNormal, IntPtr.Zero);
            if (handle == InvalidHandle) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot open " + path);
            }
            return handle;
        }

        // Returns { pid, creation time as a UTC file time }.
        public static long[] Start(string application, string commandLine, string workingDirectory,
            string stdinFile, string stdoutLog, string stderrLog) {
            const uint GenericRead = 0x80000000, AppendData = 0x0004, Synchronize = 0x00100000;
            const uint OpenExisting = 3, OpenAlways = 4;
            const int UseStdHandles = 0x100, UseShowWindow = 0x1;
            const uint ExtendedStartupInfo = 0x00080000, NewConsole = 0x00000010;
            IntPtr HandleListAttribute = new IntPtr(0x00020002);

            IntPtr input = IntPtr.Zero, output = IntPtr.Zero, error = IntPtr.Zero;
            IntPtr attributeList = IntPtr.Zero, handleList = IntPtr.Zero;
            bool listReady = false;
            try {
                input = Open(stdinFile, GenericRead, OpenExisting);
                // Append-only access: every write lands at the end of the file,
                // whatever else has written to it since.
                output = Open(stdoutLog, AppendData | Synchronize, OpenAlways);
                error = Open(stderrLog, AppendData | Synchronize, OpenAlways);

                // Only these three handles are inherited.
                handleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
                Marshal.WriteIntPtr(handleList, 0, input);
                Marshal.WriteIntPtr(handleList, IntPtr.Size, output);
                Marshal.WriteIntPtr(handleList, IntPtr.Size * 2, error);
                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                attributeList = Marshal.AllocHGlobal(size);
                if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref size)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot prepare the handle list");
                }
                listReady = true;
                if (!UpdateProcThreadAttribute(attributeList, 0, HandleListAttribute, handleList,
                        (IntPtr)(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot set the handle list");
                }

                StartupInfoEx startup = new StartupInfoEx();
                startup.StartupInfo.Cb = Marshal.SizeOf(typeof(StartupInfoEx));
                // A console of its own, hidden, which the member's own child
                // processes share instead of each opening a window.
                startup.StartupInfo.Flags = UseStdHandles | UseShowWindow;
                startup.StartupInfo.ShowWindow = 0;
                startup.StartupInfo.StdInput = input;
                startup.StartupInfo.StdOutput = output;
                startup.StartupInfo.StdError = error;
                startup.AttributeList = attributeList;

                ProcessInformation info;
                System.Text.StringBuilder line = new System.Text.StringBuilder(commandLine);
                if (!CreateProcessW(application, line, IntPtr.Zero, IntPtr.Zero, true,
                        ExtendedStartupInfo | NewConsole, IntPtr.Zero, workingDirectory, ref startup, out info)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot start " + application);
                }
                try {
                    long creation, exit, kernel, user;
                    if (!GetProcessTimes(info.Process, out creation, out exit, out kernel, out user)) creation = 0;
                    return new long[] { info.ProcessId, creation };
                }
                finally {
                    CloseHandle(info.Thread);
                    CloseHandle(info.Process);
                }
            }
            finally {
                if (listReady) DeleteProcThreadAttributeList(attributeList);
                if (attributeList != IntPtr.Zero) Marshal.FreeHGlobal(attributeList);
                if (handleList != IntPtr.Zero) Marshal.FreeHGlobal(handleList);
                if (input != IntPtr.Zero) CloseHandle(input);
                if (output != IntPtr.Zero) CloseHandle(output);
                if (error != IntPtr.Zero) CloseHandle(error);
            }
        }
    }
}
'@
    }

    $claude = Get-Command claude -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $command = Get-MemberCommandLine $claude.Source $Arguments

    # Mark the member's environment (it is inherited from this process) so that
    # Deputy's own session hooks can tell a posse member from the Deputy: a
    # member working on the Deputy repository itself loads the same
    # .claude\settings.json, and there the hooks must do nothing (see
    # Test-DeputyHome).
    $previousMarker = $env:DEPUTY_POSSE_TASK
    $env:DEPUTY_POSSE_TASK = $TaskId
    try {
        $started = [Deputy.MemberLauncher]::Start($command.FilePath, $command.CommandLine, $WorkingDirectory,
            $StdinFile, $StdoutLog, $StderrLog)
    }
    finally { $env:DEPUTY_POSSE_TASK = $previousMarker }

    [pscustomobject]@{
        ProcessId = [int]$started[0]
        StartedAt = if ($started[1] -gt 0) { [datetime]::FromFileTimeUtc($started[1]).ToLocalTime().ToString('o') } else { $null }
    }
}

function Get-EventField($Object, [string]$Name) {
    # A property of a parsed JSON object, or $null when it is not there.
    if ($Object -is [pscustomobject] -and $Object.PSObject.Properties[$Name]) { $Object.$Name } else { $null }
}

function Test-TransientApiError($ResultEvent, [string]$Text) {
    # Did this error result come from a server-side failure that is expected to
    # pass (rate limit, overload, a 5xx)? The session itself is intact then, so
    # it is continued rather than started again. The status field decides when
    # it is there; the text is read only for an API error it names.
    $status = 0
    if ([int]::TryParse([string](Get-EventField $ResultEvent 'api_error_status'), [ref]$status) -and
        $script:TransientApiStatuses -contains $status) {
        return $true
    }
    if ($status -gt 0) { return $false }  # a status that is not transient: believe it
    if ($Text -match '(?i)\boverloaded(_error)?\b') { return $true }
    $Text -match ('(?i)\bAPI\s+error\b\D{0,20}(' + ($script:TransientApiStatuses -join '|') + ')\b')
}

function Get-MemberReport($ResultEvent) {
    # The structured final report in a result event, or $null when there is
    # none that follows the schema (an older session, a schema the member could
    # not satisfy). The caller then falls back to the result text.
    $structured = Get-EventField $ResultEvent 'structured_output'
    if ($structured -isnot [pscustomobject]) { return $null }
    $status = [string](Get-EventField $structured 'status')
    if (-not $script:MemberReportWakes.Contains($status)) { return $null }
    $report = [ordered]@{ status = $status }
    foreach ($field in 'summary', 'tests', 'question', 'prUrl') {
        $value = Get-EventField $structured $field
        $report[$field] = if ($null -ne $value -and "$value".Trim()) { "$value".Trim() } else { $null }
    }
    [pscustomobject]$report
}

function Format-MemberReport($Report, [switch]$NoQuestion) {
    # A structured report as the text a person reads: in dep-posse.ps1 result,
    # and as the summary of the pull request.
    $parts = @()
    if ($Report.summary) { $parts += $Report.summary }
    if ($Report.tests) { $parts += "Tests: $($Report.tests)" }
    if ($Report.question -and -not $NoQuestion) { $parts += "Question: $($Report.question)" }
    if ($parts.Count -eq 0) { $parts += "The member reported '$($Report.status)' and said nothing else." }
    $parts -join "`n`n"
}

function Get-MemberOutcome($ResultEvent) {
    <#
    .SYNOPSIS
    What a member's final result event means: the wake it becomes, the text of
    the result, and the structured report when there is one.

    | result                                       | wake                    |
    | is_error, transient API failure              | interrupted             |
    | is_error, anything else                      | failed                  |
    | structured report                            | by its status (see map) |
    | plain text (no report, or not to the schema) | completed               |
    #>
    $text = [string](Get-EventField $ResultEvent 'result')
    if (-not $text.Trim()) {
        # An error result often has no text, only a list of errors.
        $text = (@(Get-EventField $ResultEvent 'errors') | Where-Object { $_ } | ForEach-Object { "$_" }) -join '; '
    }
    if (Get-EventField $ResultEvent 'is_error') {
        if (-not $text.Trim()) { $text = "The session ended with an error ($(Get-EventField $ResultEvent 'subtype'))." }
        $wake = if (Test-TransientApiError $ResultEvent $text) { 'interrupted' } else { 'failed' }
        return [pscustomobject]@{ Wake = $wake; Text = $text; Report = $null }
    }
    $report = Get-MemberReport $ResultEvent
    if ($report) {
        return [pscustomobject]@{
            Wake   = $script:MemberReportWakes[$report.status]
            Text   = Format-MemberReport $report
            Report = $report
        }
    }
    [pscustomobject]@{ Wake = 'completed'; Text = $text; Report = $null }
}

function Get-TaskFollowUps($State) {
    # The follow-up messages dep-send.ps1 has sent to a task, oldest first.
    @(Get-EventField $State 'followUps' | Where-Object { $_ })
}

function Get-ReturnCommand([string]$Id) {
    'pwsh -NoProfile -File "{0}" {1}' -f (Join-Path (Get-DeputyPaths).Bin 'dep-return.ps1'), $Id
}

function Get-SendCommand([string]$Id, [string]$Message = '...') {
    'pwsh -NoProfile -File "{0}" {1} -Message "{2}"' -f (Join-Path (Get-DeputyPaths).Bin 'dep-send.ps1'), $Id, $Message
}

# ---------------------------------------------------------------------------
# GitHub over REST. Every read of a pull request, and the merge itself, goes
# through `gh api`: gh's own `pr view`, `pr checks` and `pr merge` use GraphQL
# queries that need the read:org token scope, which a supervisor's token often
# does not have. The REST endpoints below need nothing beyond access to the
# repository.
# ---------------------------------------------------------------------------

function Invoke-GhApi {
    <#
    .SYNOPSIS
    One REST call through `gh api`. Returns Ok, the HTTP Status (0 when gh never
    got an answer: not installed, not signed in, no network), the parsed Json,
    the body Text, and an Error line when it failed. Never throws.

    -Fields become query parameters (-f) and are for GET; -Body is sent as the
    JSON request body on stdin, so its text never has to survive a command line.
    #>
    param(
        [Parameter(Mandatory, Position = 0)][string]$Endpoint,
        [string]$Method = 'GET',
        [System.Collections.IDictionary]$Fields,
        [System.Collections.IDictionary]$Body,
        [string]$Accept,
        # The body is not JSON (a diff): leave it as text.
        [switch]$Raw
    )
    $result = [pscustomobject]@{ Ok = $false; Status = 0; Json = $null; Text = ''; Error = '' }
    if (-not (Test-CommandOnPath 'gh')) {
        $result.Error = 'gh is not on PATH'
        return $result
    }
    # --include puts the status line and headers in front of the body, for
    # errors too, so the status is read from the response and not guessed from
    # an error message.
    $arguments = @('api', '--include', '--method', $Method)
    if ($Accept) { $arguments += @('-H', "Accept: $Accept") }
    if ($Fields) { foreach ($name in @($Fields.Keys)) { $arguments += @('-f', "$name=$($Fields[$name])") } }
    if ($Body) { $arguments += @('--input', '-') }
    $arguments += $Endpoint

    # gh writes UTF-8 whatever the console's code page is.
    $previousEncoding = $null
    try {
        $previousEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    }
    catch { $previousEncoding = $null }
    try {
        $all = if ($Body) { ($Body | ConvertTo-Json -Depth 8 -Compress) | & gh @arguments 2>&1 }
        else { & gh @arguments 2>&1 }
        $exit = $LASTEXITCODE
    }
    catch {
        $result.Error = "gh could not be run: $($_.Exception.Message)"
        return $result
    }
    finally {
        if ($previousEncoding) { try { [Console]::OutputEncoding = $previousEncoding } catch { $null = $_ } }
    }

    $stderr = (@($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) |
        ForEach-Object { "$_" }) -join ' '
    $lines = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    $bodyLines = $lines
    if ($lines.Count -gt 0 -and $lines[0] -match '^HTTP/\S+\s+(\d{3})\b') {
        $result.Status = [int]$Matches[1]
        $blank = [array]::IndexOf($lines, '')
        $bodyLines = if ($blank -ge 0 -and $blank + 1 -lt $lines.Count) { $lines[($blank + 1)..($lines.Count - 1)] } else { @() }
    }
    elseif ($stderr -match '\(HTTP (\d{3})\)') { $result.Status = [int]$Matches[1] }
    $result.Text = $bodyLines -join "`n"
    if (-not $Raw -and $result.Text.Trim()) {
        $result.Json = try { $result.Text | ConvertFrom-Json -ErrorAction Stop } catch { $null }
    }
    $result.Ok = ($exit -eq 0) -and ($result.Status -eq 0 -or ($result.Status -ge 200 -and $result.Status -lt 300))
    if (-not $result.Ok) {
        $message = [string](Get-EventField $result.Json 'message')
        $said = if ($message) { $message } elseif ($stderr) { $stderr } else { "gh api exited $exit" }
        $result.Error = if ($result.Status) { "HTTP $($result.Status): $(Limit-Text $said 200)" } else { Limit-Text $said 200 }
    }
    $result
}

function Get-TaskPrRef($State) {
    # The pull request a task record names, as owner, repo and number, or $null
    # when it names none. The number comes from the URL, so a PR the member
    # opened itself (direct-pr delivery) is addressed the same way as one
    # dep-publish.ps1 opened.
    $url = [string](Get-EventField $State 'prUrl')
    if ($url -notmatch '^https://github\.com/([^/\s]+)/([^/\s]+)/pull/(\d+)') { return $null }
    [pscustomobject]@{
        Owner  = $Matches[1]
        Repo   = $Matches[2]
        Number = [int]$Matches[3]
        Url    = $Matches[0]
        Api    = "repos/$($Matches[1])/$($Matches[2])"
    }
}

function Get-PullRequest($Ref) {
    # The pull request as GitHub has it right now. Ok is false, with the Status
    # and an Error, when it could not be read - which is never the same thing as
    # "not merged" or "closed", and callers must not read it as either.
    $response = Invoke-GhApi "$($Ref.Api)/pulls/$($Ref.Number)"
    $pr = $response.Json
    if (-not $response.Ok -or $pr -isnot [pscustomobject] -or -not (Get-EventField $pr 'state')) {
        return [pscustomobject]@{
            Ok     = $false
            Status = $response.Status
            Error  = if ($response.Error) { $response.Error } else { 'the response was not a pull request' }
        }
    }
    $head = Get-EventField $pr 'head'
    $base = Get-EventField $pr 'base'
    $merged = [bool](Get-EventField $pr 'merged') -or ($null -ne (Get-EventField $pr 'merged_at'))
    [pscustomobject]@{
        Ok             = $true
        Status         = $response.Status
        Error          = ''
        Number         = $Ref.Number
        # open, closed (without merging) or merged
        State          = if ($merged) { 'merged' } else { [string]$pr.state }
        Merged         = $merged
        MergedAt       = Get-EventField $pr 'merged_at'
        MergeSha       = if ($merged) { [string](Get-EventField $pr 'merge_commit_sha') } else { '' }
        Draft          = [bool](Get-EventField $pr 'draft')
        # $true, $false, or $null while GitHub is still working it out
        Mergeable      = Get-EventField $pr 'mergeable'
        MergeableState = [string](Get-EventField $pr 'mergeable_state')
        HeadSha        = [string](Get-EventField $head 'sha')
        HeadRef        = [string](Get-EventField $head 'ref')
        BaseRef        = [string](Get-EventField $base 'ref')
        Title          = [string](Get-EventField $pr 'title')
        Url            = [string](Get-EventField $pr 'html_url')
        Raw            = $pr
    }
}

function Get-PrChecks($Ref, [string]$Sha) {
    <#
    .SYNOPSIS
    Every check reported at one commit: check runs (GitHub Actions and other
    apps) and commit statuses (the older API some CI still reports through).
    Each is success, pending or failure. A check run that is neutral or skipped
    counts as success, as GitHub itself counts it.

    Ok is false when either list could not be read: "no checks" is only ever
    said about a commit whose checks were actually read.
    #>
    $checks = @()
    $failed = { param($why) [pscustomobject]@{ Ok = $false; Error = $why; Checks = @(); Failing = @(); Pending = @() } }

    for ($page = 1; $page -le 20; $page++) {
        $response = Invoke-GhApi "$($Ref.Api)/commits/$Sha/check-runs" -Fields ([ordered]@{ per_page = 100; page = $page })
        if (-not $response.Ok -or $response.Json -isnot [pscustomobject]) {
            return (& $failed "check runs could not be read ($($response.Error))")
        }
        $runs = @(Get-EventField $response.Json 'check_runs' | Where-Object { $_ })
        foreach ($run in $runs) {
            $conclusion = [string](Get-EventField $run 'conclusion')
            $state = if ((Get-EventField $run 'status') -ne 'completed') { 'pending' }
            elseif ($conclusion -in @('success', 'neutral', 'skipped')) { 'success' }
            else { 'failure' }
            $checks += [pscustomobject]@{
                Name   = [string](Get-EventField $run 'name')
                State  = $state
                Detail = if ($state -eq 'pending') { [string](Get-EventField $run 'status') } else { $conclusion }
                Url    = [string](Get-EventField $run 'html_url')
            }
        }
        $total = [int](Get-EventField $response.Json 'total_count')
        if ($runs.Count -eq 0 -or $checks.Count -ge $total) { break }
    }

    $statuses = @()
    for ($page = 1; $page -le 20; $page++) {
        $response = Invoke-GhApi "$($Ref.Api)/commits/$Sha/status" -Fields ([ordered]@{ per_page = 100; page = $page })
        if (-not $response.Ok -or $response.Json -isnot [pscustomobject]) {
            return (& $failed "commit statuses could not be read ($($response.Error))")
        }
        $batch = @(Get-EventField $response.Json 'statuses' | Where-Object { $_ })
        foreach ($status in $batch) {
            $reported = [string](Get-EventField $status 'state')
            $statuses += [pscustomobject]@{
                Name   = [string](Get-EventField $status 'context')
                State  = if ($reported -eq 'success') { 'success' } elseif ($reported -eq 'pending') { 'pending' } else { 'failure' }
                Detail = $reported
                Url    = [string](Get-EventField $status 'target_url')
            }
        }
        $total = [int](Get-EventField $response.Json 'total_count')
        if ($batch.Count -eq 0 -or $statuses.Count -ge $total) { break }
    }

    $checks = @($checks) + @($statuses)
    [pscustomobject]@{
        Ok      = $true
        Error   = ''
        Checks  = @($checks)
        Failing = @($checks | Where-Object { $_.State -eq 'failure' })
        Pending = @($checks | Where-Object { $_.State -eq 'pending' })
    }
}

function Get-RequiredChecks($Ref, [string]$Branch) {
    # The status checks a branch's protection requires. Readable is false when
    # the protection could not be read at all - GitHub answers 404 or 403 to a
    # token without admin rights on the repository, and to an unprotected
    # branch alike, so neither answer says "nothing is required".
    $response = Invoke-GhApi "$($Ref.Api)/branches/$([uri]::EscapeDataString($Branch))/protection"
    if (-not $response.Ok -or $response.Json -isnot [pscustomobject]) {
        return [pscustomobject]@{
            Readable = $false
            Required = @()
            Error    = if ($response.Error) { $response.Error } else { 'the response was not a branch protection' }
        }
    }
    $required = Get-EventField $response.Json 'required_status_checks'
    $names = @(Get-EventField $required 'contexts') +
        @(Get-EventField $required 'checks' | ForEach-Object { Get-EventField $_ 'context' })
    [pscustomobject]@{
        Readable = $true
        Required = @($names | Where-Object { $_ } | Select-Object -Unique)
        Error    = ''
    }
}

function Format-Sha([string]$Sha) {
    if ($Sha.Length -gt 10) { $Sha.Substring(0, 10) } else { $Sha }
}

# ---------------------------------------------------------------------------
# Teardown. dep-return.ps1 resets a worktree and deletes branches, which cannot
# be taken back, so it proves the work is somewhere else first.
# ---------------------------------------------------------------------------

function Test-TaskLanded($State) {
    <#
    .SYNOPSIS
    Has this task's work landed somewhere that survives a teardown? The one
    test dep-return.ps1 runs before it returns anything.

    A ship task has landed when its worktree is clean (untracked files count as
    dirty) and one of these holds:

    - every commit ahead of its base is reachable from a remote-tracking
      branch, after a fetch;
    - its pull request is merged, and either the PR's head contains the local
      HEAD or the local tree is identical to the freshly fetched base (a squash
      merge leaves no commit of the branch behind, only its content).

    The base is the task's base branch when it was spawned with one, else the
    default branch (Resolve-TaskBaseRef). A branch with no commits ahead of its
    base has nothing to lose, and neither has a task whose worktree and local
    branch are both gone. A scout has landed when its report file exists.

    Returns Landed and the Reason either way, plus what dep-return.ps1 needs to
    know about the remote branch: PrState (none, open, closed, merged, or
    unknown when a recorded PR could not be read) and KeepRemoteBranch with
    KeepRemoteReason - set while the PR is open or unreadable, and when the
    task's own remote branch is the only place the commits exist.
    #>
    $verdict = [pscustomobject]@{
        Landed           = $false
        Reason           = ''
        PrState          = 'none'
        KeepRemoteBranch = $false
        KeepRemoteReason = ''
    }

    if ($State.kind -eq 'scout') {
        $report = Join-Path (Get-DeputyPaths).State "$(Assert-TaskId $State.id)-report.md"
        $verdict.Landed = Test-Path -LiteralPath $report -PathType Leaf
        $verdict.Reason = if ($verdict.Landed) { "the scout report exists at $report" }
        else { "the scout wrote no report: $report does not exist" }
        return $verdict
    }

    $ref = Get-TaskPrRef $State
    $pr = $null
    if ($ref) {
        $pr = Get-PullRequest $ref
        $verdict.PrState = if ($pr.Ok) { $pr.State } else { 'unknown' }
        if ($verdict.PrState -eq 'open') {
            $verdict.KeepRemoteBranch = $true
            $verdict.KeepRemoteReason = "pull request #$($ref.Number) is still open"
        }
        elseif ($verdict.PrState -eq 'unknown') {
            $verdict.KeepRemoteBranch = $true
            $verdict.KeepRemoteReason = "pull request #$($ref.Number) could not be read ($($pr.Error)), so it may still be open"
        }
    }
    $prNote = switch ($verdict.PrState) {
        'none' { 'The task has no pull request.' }
        'open' { "Pull request #$($ref.Number) is open, not merged." }
        'closed' { "Pull request #$($ref.Number) was closed without merging." }
        'unknown' { "Pull request #$($ref.Number) could not be read ($($pr.Error))." }
        default { '' }
    }

    # Where the commits live: the worktree while it exists, else the task
    # branch in the repository the worktree was leased from.
    $branch = [string](Get-EventField $State 'branch')
    $hasWorktree = $State.worktree -and (Test-Path -LiteralPath $State.worktree -PathType Container)
    $dir = if ($hasWorktree) { $State.worktree } else { $State.repo }
    $isRepo = $false
    if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) {
        git -C $dir rev-parse --git-dir *> $null
        $isRepo = ($LASTEXITCODE -eq 0)
    }
    if (-not $isRepo) {
        $verdict.Landed = $true
        $verdict.Reason = 'neither the worktree nor the repository is there any more, so nothing local is left to lose'
        return $verdict
    }

    if ($hasWorktree) {
        $dirty = @(git -C $dir status --porcelain 2>$null)
        if ($LASTEXITCODE -ne 0) {
            $verdict.Reason = "git status failed in $dir, so the worktree cannot be shown to be clean"
            return $verdict
        }
        if ($dirty.Count -gt 0) {
            $verdict.Reason = "the worktree has $($dirty.Count) uncommitted or untracked path(s): " +
                (Limit-Text ($dirty -join '; ') 200)
            return $verdict
        }
        $tip = (git -C $dir rev-parse --verify --quiet 'HEAD^{commit}' 2>$null | Out-String).Trim()
    }
    elseif ($branch -and (Test-GitRef $dir "refs/heads/$branch")) {
        $tip = (git -C $dir rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>$null | Out-String).Trim()
    }
    else {
        $verdict.Landed = $true
        $verdict.Reason = 'the worktree is gone and the task branch does not exist locally, so nothing local is left to lose'
        return $verdict
    }
    if (-not $tip) {
        $verdict.Reason = "the task's HEAD commit cannot be resolved in $dir"
        return $verdict
    }

    # What is on the remote is only known after a fetch. --prune, so a remote
    # branch that was deleted does not go on vouching for commits.
    $hasOrigin = @(git -C $dir remote 2>$null) -contains 'origin'
    $fetched = $false
    if ($hasOrigin) {
        $previousPrompt = $env:GIT_TERMINAL_PROMPT
        $env:GIT_TERMINAL_PROMPT = '0'  # fail, do not sit at a credential prompt
        try { git -C $dir fetch --quiet --prune origin *> $null; $fetched = ($LASTEXITCODE -eq 0) }
        finally { $env:GIT_TERMINAL_PROMPT = $previousPrompt }
    }

    # Ahead of what the task was cut from: its base branch, else the default.
    $anchor = Resolve-TaskBaseRef $State $dir
    if (-not $anchor.Ref) {
        $what = if (Get-EventField $State 'baseBranch') { 'the base branch' } else { 'the default branch' }
        $verdict.Reason = "$what of $dir cannot be resolved ($($anchor.Source)), so nothing can be proven about what is ahead of it"
        return $verdict
    }
    $ahead = @(git -C $dir rev-list $tip "^$($anchor.Ref)" 2>$null)
    if ($LASTEXITCODE -ne 0) {
        $verdict.Reason = "git could not list the commits ahead of $($anchor.Ref)"
        return $verdict
    }
    if ($ahead.Count -eq 0) {
        $verdict.Landed = $true
        $verdict.Reason = "there are no commits ahead of $($anchor.Ref)"
        return $verdict
    }
    if ($hasOrigin -and -not $fetched) {
        $verdict.Reason = "origin could not be fetched, so what is on the remote cannot be proven ($($ahead.Count) commit(s) are ahead of $($anchor.Ref))"
        return $verdict
    }

    $unpushed = @(git -C $dir rev-list $tip "^$($anchor.Ref)" --not --remotes=origin 2>$null)
    if ($unpushed.Count -eq 0) {
        $verdict.Landed = $true
        $verdict.Reason = "every commit ahead of $($anchor.Ref) is on a remote-tracking branch"
        # Is the task's own remote branch the only one holding them? Then
        # deleting it would delete the work, unless the PR took it in.
        $others = @(git -C $dir for-each-ref --format='%(refname)' refs/remotes/origin 2>$null |
            Where-Object { $_ -and $_ -ne "refs/remotes/origin/$branch" })
        $elsewhere = $false
        if ($others.Count -gt 0) {
            $onlyHere = @(git -C $dir rev-list $tip --not @others 2>$null)
            $elsewhere = ($LASTEXITCODE -eq 0) -and ($onlyHere.Count -eq 0)
        }
        if (-not $elsewhere -and $verdict.PrState -ne 'merged' -and -not $verdict.KeepRemoteBranch) {
            $verdict.KeepRemoteBranch = $true
            $verdict.KeepRemoteReason = "origin/$branch is the only place its commits exist"
        }
        return $verdict
    }

    $first = (git -C $dir log -1 --format='%h %s' $unpushed[-1] 2>$null | Out-String).Trim()
    $missing = "$($unpushed.Count) commit(s) ahead of $($anchor.Ref) are on no remote-tracking branch (oldest: $(Limit-Text $first 80))"
    if ($verdict.PrState -ne 'merged') {
        $verdict.Reason = "$missing. $prNote"
        return $verdict
    }

    # Merged. The PR's head may be a commit this clone never fetched (someone
    # pushed to the PR, and the branch is deleted on merge): ask for it.
    if ($pr.HeadSha -and $pr.HeadSha -ne $tip) {
        git -C $dir cat-file -e "$($pr.HeadSha)^{commit}" *> $null
        if ($LASTEXITCODE -ne 0) { git -C $dir fetch --quiet origin "refs/pull/$($ref.Number)/head" *> $null }
    }
    $contained = $false
    if ($pr.HeadSha) {
        git -C $dir merge-base --is-ancestor $tip $pr.HeadSha *> $null
        $contained = ($LASTEXITCODE -eq 0)
    }
    if ($contained) {
        $verdict.Landed = $true
        $verdict.Reason = "pull request #$($ref.Number) is merged and its head $(Format-Sha $pr.HeadSha) contains the local HEAD"
        return $verdict
    }
    $localTree = (git -C $dir rev-parse --verify --quiet "$tip^{tree}" 2>$null | Out-String).Trim()
    $defaultTree = (git -C $dir rev-parse --verify --quiet "$($anchor.Ref)^{tree}" 2>$null | Out-String).Trim()
    if ($fetched -and $localTree -and $localTree -eq $defaultTree) {
        $verdict.Landed = $true
        $verdict.Reason = "pull request #$($ref.Number) is merged and the local tree is identical to $($anchor.Ref)"
        return $verdict
    }
    $verdict.Reason = "$missing. Pull request #$($ref.Number) is merged, but its head $(Format-Sha $pr.HeadSha) does not " +
        "contain the local HEAD $(Format-Sha $tip) and the local tree differs from $($anchor.Ref), so some local work was never part of it"
    $verdict
}

function Limit-Text([string]$Text, [int]$Max = 200) {
    if (-not $Text) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -le $Max) { $t } else { $t.Substring(0, $Max) + '...' }
}

function Get-FirstSentence([string]$Text) {
    if (-not $Text) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim()
    $idx = $t.IndexOf('. ')
    if ($idx -ge 0) { $t.Substring(0, $idx + 1) } else { $t }
}

function Format-PrTitle([string]$Text, [int]$Max = 80) {
    # A PR title is a headline, so it is cut like one. Limit-Text's blunt
    # substring shipped "...degrade into a vacuous p..." on a real PR, which had
    # to be corrected by hand: break on a word boundary instead, and shed
    # whatever the break leaves dangling.
    if (-not $Text) { return '' }
    # The title can come from a posse member's commit subject (see Get-PrTitle),
    # so treat the text as untrusted display data: the Deputy and the Sheriff
    # both read it in a terminal. Escape sequences go first, whole, so that
    # dropping the ESC does not leave its parameters behind as visible noise -
    # a CSI sequence can recolour or overwrite what is printed, and an OSC one
    # carries a payload of its own.
    $t = $Text -replace '\x1B\[[0-9;:<=>?]*[ -/]*[@-~]', ''
    $t = $t -replace '\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)?', ''
    # Whitespace collapses before the control strip, so tab and newline survive
    # as spaces. What is left to drop is invisible: remaining control
    # characters, and format characters such as the bidi overrides that make a
    # title read as something other than what it says.
    $t = ($t -replace '\s+', ' ') -replace '[\p{Cc}\p{Cf}]', ''
    $t = $t.Trim() -replace '[\s.,;:]+$', ''
    if ($t.Length -le $Max) { return $t }

    $ellipsis = '...'
    $budget = $t.Substring(0, $Max - $ellipsis.Length)
    $space = $budget.LastIndexOf(' ')
    # A single word wider than the whole budget has no boundary to break on:
    # cut it anyway rather than looping forever or returning nothing.
    if ($space -lt 1) { return $budget + $ellipsis }

    # Trailing punctuation, and a trailing function word (connective, article,
    # bare auxiliary) that reads as a clause broken off mid-thought, both go.
    # Never the last remaining word, so the result cannot collapse to empty.
    $connectives = @('a', 'an', 'and', 'are', 'as', 'at', 'be', 'been', 'being', 'but', 'by', 'can',
        'could', 'did', 'do', 'does', 'for', 'from', 'had', 'has', 'have', 'if', 'in', 'into', 'is',
        'it', 'its', 'may', 'might', 'must', 'no', 'not', 'of', 'on', 'or', 'over', 'per', 'should',
        'so', 'than', 'that', 'the', 'their', 'to', 'via', 'was', 'were', 'when', 'which', 'while',
        'who', 'will', 'with', 'without', 'would')
    $cut = $budget.Substring(0, $space)
    while ($true) {
        $cut = $cut -replace '[\s\p{P}]+$', ''
        $words = @($cut -split ' ')
        if ($words.Count -le 1 -or -not ($connectives -contains $words[-1].ToLowerInvariant())) { break }
        $cut = ($words[0..($words.Count - 2)] -join ' ')
    }
    if (-not $cut) { $cut = $budget }
    $cut + $ellipsis
}

# The subject of Deputy's own validation-evidence commit, defined in one place
# because two sites depend on it agreeing: dep-validate.ps1 writes the commit,
# and Get-PrTitle excludes it when counting the member's own commits. Kept as
# separate copies, an edit to one would leave the exclusion silently not
# matching, and the evidence commit's subject would become the PR title.
$script:EvidenceCommitPrefix = 'deputy: validation evidence'

function New-EvidenceCommitMessage([string]$Id) {
    "$script:EvidenceCommitPrefix for $Id"
}

function Test-EvidenceCommitSubject([string]$Subject) {
    if (-not $Subject) { return $false }
    $Subject.StartsWith($script:EvidenceCommitPrefix, [StringComparison]::Ordinal)
}

function Get-PrTitle {
    <#
    .SYNOPSIS
    The PR title for a task branch: its single commit subject when it has one,
    else the first sentence of the briefing.

    A commit subject is already written as an imperative headline, while a
    briefing's first sentence is a specification and reads like one. When the
    branch carries several commits no single subject covers them, so the
    briefing is the honest source there. Deputy's own evidence commit is not
    the member's work and never counts as the branch's commit.

    The subject is a posse member's text, so it is display data the Sheriff has
    not written: Format-PrTitle sanitises it. A subject left empty by that is no
    headline at all, and the briefing is used instead.
    #>
    param([string]$Worktree, [string]$DefaultRef, [string]$Briefing)
    $title = ''
    if ($Worktree -and $DefaultRef) {
        $subjects = @(git -C $Worktree log "$DefaultRef..HEAD" --format=%s 2>$null |
            Where-Object { $_ -and -not (Test-EvidenceCommitSubject $_) })
        if ($subjects.Count -eq 1) { $title = Format-PrTitle $subjects[0] }
    }
    if (-not $title) { $title = Format-PrTitle (Get-FirstSentence $Briefing) }
    $title
}

function Remove-Secret([string]$Text) {
    # Best-effort redaction of secrets in captured command output before it
    # lands anywhere PR-viewable. Pattern-based, so not exhaustive: test
    # suites should avoid printing secrets in the first place.
    if (-not $Text) { return '' }
    $t = $Text
    # key=value / key: value pairs for common secret-bearing key names
    $t = $t -replace '(?i)\b([\w-]*(?:api[_-]?key|secret|password|token|authorization))([ \t]*[=:][ \t]*)("[^"]*"|''[^'']*''|(?:bearer[ \t]+|basic[ \t]+)?[^\s"'']+)', '${1}${2}[REDACTED]'
    # credentials embedded in connection URIs (scheme://user:pass@host)
    $t = $t -replace '(?i)\b(postgres(?:ql)?|mysql|mongodb(?:\+srv)?)://[^\s@/]*:[^\s@/]*@', '${1}://[REDACTED]@'
    # well-known standalone token shapes: GitHub, OpenAI-style, JWT
    $t = $t -creplace '\bgh[pousr]_[A-Za-z0-9]{20,}', '[REDACTED]'
    $t = $t -creplace '\bsk-[A-Za-z0-9_-]{20,}', '[REDACTED]'
    $t = $t -creplace '\beyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '[REDACTED]'
    $t
}
