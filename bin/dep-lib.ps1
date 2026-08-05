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
