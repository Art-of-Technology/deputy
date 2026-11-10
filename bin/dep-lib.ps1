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
    $help = try { (treehouse get --help 2>&1 | Out-String) } catch { '' }
    if ($help -notmatch '--lease(?![\w-])') {
        "treehouse get --help does not list --lease, which Deputy needs to lease worktrees. Fix: $script:TreehouseUpdateFix"
    }
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
