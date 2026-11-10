#Requires -Version 7.0
<#
.SYNOPSIS
Tests for the toolchain doctor (dep-doctor.ps1, and the treehouse version
guard dep-spawn.ps1 shares with it) and for the hardened process handling
behind dep-posse.ps1 kill and dep-return.ps1.

The hazard these pin down: an old treehouse can mislist the processes in a
worktree on Windows, and Deputy used to force-kill whatever treehouse listed.

No real treehouse is involved anywhere. In-process tests shadow it with a fake
function; end-to-end tests put fake treehouse/gh/claude shims first on PATH, so
they pass whatever versions the machine running them has installed.
#>

BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:repoRoot 'bin' 'dep-lib.ps1')
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:root = New-TempRoot

    $script:GOOD_HELP = @'
Usage:
  treehouse get [flags]

Flags:
      --json                  Print lease allocation as JSON (requires --lease)
      --lease                 Durably lease a worktree without opening a subshell
      --lease-holder string   Optional label recorded as the lease holder
'@
    # A help text that mentions --lease-holder but offers no --lease flag.
    $script:NO_LEASE_HELP = @'
Usage:
  treehouse get [flags]

Flags:
      --lease-holder string   Optional label recorded as the holder
'@

    # In-process fake: a function shadows any treehouse on PATH. What it prints
    # is driven by these script variables, set per test.
    $script:fakeVersion = 'v3.1.8'
    $script:fakeHelp = $script:GOOD_HELP
    $script:fakeStatus = '[]'
    function treehouse {
        $global:LASTEXITCODE = 0
        if ($args[0] -eq '--version') { return $script:fakeVersion }
        if ($args[0] -eq 'get' -and $args -contains '--help') { return $script:fakeHelp }
        if ($args[0] -eq 'status') { return $script:fakeStatus }
        $global:LASTEXITCODE = 1
    }

    function Set-FakeWorktreeProcesses {
        # Make the fake `treehouse status --json` list these pids in $Worktree.
        param([string]$Worktree, [object[]]$Processes)
        $script:fakeStatus = ConvertTo-Json -Depth 5 -InputObject @(
            [ordered]@{ path = $Worktree; processes = @($Processes) }
        )
    }

    function New-FakeProcess {
        param([int]$Id, [int]$Parent, [datetime]$Started, [string]$Exe = 'C:\fake\tool.exe', [string]$Cmd = 'tool')
        [pscustomobject]@{
            ProcessId = $Id; ParentProcessId = $Parent; ExecutablePath = $Exe
            CommandLine = $Cmd; StartTime = $Started
        }
    }

    function New-ToolShims {
        # Fake treehouse, gh and claude executables for end-to-end runs. The
        # treehouse shim prints version.txt / help.txt / status.json from its own
        # directory and logs every invocation to treehouse-calls.log.
        param([string]$Path)
        New-Item -ItemType Directory -Force $Path | Out-Null
        Set-Content -Path (Join-Path $Path 'treehouse.cmd') -Encoding ascii -Value @(
            '@echo off'
            'echo %*>>"%~dp0treehouse-calls.log"'
            'if "%1"=="--version" (type "%~dp0version.txt" & exit /b 0)'
            'if "%1"=="get" if "%2"=="--help" (type "%~dp0help.txt" & exit /b 0)'
            'if "%1"=="status" if exist "%~dp0status.json" (type "%~dp0status.json" & exit /b 0)'
            'exit /b 1'
        )
        foreach ($tool in 'gh', 'claude') {
            Set-Content -Path (Join-Path $Path "$tool.cmd") -Encoding ascii -Value '@exit /b 0'
        }
        Set-Content -Path (Join-Path $Path 'help.txt') -Encoding ascii -Value $script:GOOD_HELP
        Set-ShimVersion -Path $Path -Version 'v3.1.8'
        (Resolve-Path $Path).Path
    }

    function Set-ShimVersion {
        param([string]$Path, [string]$Version)
        Set-Content -Path (Join-Path $Path 'version.txt') -Encoding ascii -Value $Version
        Remove-Item (Join-Path $Path 'treehouse-calls.log') -ErrorAction SilentlyContinue
    }

    function Get-ShimCalls {
        param([string]$Path)
        $log = Join-Path $Path 'treehouse-calls.log'
        if (Test-Path $log) { @(Get-Content $log) } else { @() }
    }

    function Start-Sleeper {
        # A real, harmless process to point task state at.
        param([string]$WorkingDirectory)
        Start-Process -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 120' `
            -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru
    }
}

AfterAll {
    if ($script:root) { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }
}

Describe 'Test-TreehouseVersion' {
    It 'accepts <Text>' -TestCases @(
        @{ Text = 'v3.0.1' }
        @{ Text = '3.0.1' }
        @{ Text = 'v3.1.8' }
        @{ Text = 'treehouse version 3.1.8' }
        @{ Text = 'treehouse v3.1.8 (commit abc1234, built 2026-10-01)' }
        @{ Text = 'v3.10.0' }   # numeric, not lexical: 3.10 is newer than 3.9
        @{ Text = 'v10.0.0' }
        @{ Text = 'v3.0.2-rc1' }
    ) {
        Test-TreehouseVersion $Text | Should -BeTrue
    }

    It 'rejects <Text> as older than the floor' -TestCases @(
        @{ Text = 'v2.1.0' }
        @{ Text = 'v3.0.0' }      # the release an update must never stop at
        @{ Text = 'v2.99.99' }
        @{ Text = 'v0.9.12' }
        @{ Text = 'v3.0.1-rc1' }  # a pre-release of the floor sorts before it
    ) {
        Test-TreehouseVersion $Text | Should -BeFalse
    }

    It 'treats unparseable output <Text> as incompatible' -TestCases @(
        @{ Text = '' }
        @{ Text = 'treehouse (devel)' }
        @{ Text = 'v3' }
        @{ Text = 'v3.1' }
        @{ Text = 'unknown command "--version" for "treehouse"' }
    ) {
        ConvertTo-TreehouseVersion $Text | Should -BeNullOrEmpty
        Test-TreehouseVersion $Text | Should -BeFalse
    }

    It 'declares the floor once, as 3.0.1' {
        $script:TreehouseMinVersion | Should -Be ([version]'3.0.1')
    }
}

Describe 'Get-TreehouseProblems' {
    BeforeEach {
        $script:fakeVersion = 'v3.1.8'
        $script:fakeHelp = $script:GOOD_HELP
    }

    It 'reports nothing for a current treehouse' {
        @(Get-TreehouseProblems) | Should -HaveCount 0
    }

    It 'names the installed version, the floor and the fix when treehouse is old' {
        $script:fakeVersion = 'v2.1.0'
        $problems = @(Get-TreehouseProblems)
        $problems | Should -HaveCount 1
        $problems[0] | Should -Match 'treehouse 2\.1\.0 is older than the minimum 3\.0\.1'
        $problems[0] | Should -Match 'Fix: treehouse update'
        $problems[0] | Should -Match 'never to 3\.0\.0'
    }

    It 'treats an unparseable version as incompatible' {
        $script:fakeVersion = 'treehouse (devel)'
        $problems = @(Get-TreehouseProblems)
        $problems | Should -HaveCount 1
        $problems[0] | Should -Match 'treated as incompatible'
        $problems[0] | Should -Match 'Fix: treehouse update'
    }

    It 'reports a treehouse whose get has no --lease flag' {
        $script:fakeHelp = $script:NO_LEASE_HELP
        $problems = @(Get-TreehouseProblems)
        $problems | Should -HaveCount 1
        $problems[0] | Should -Match 'does not list --lease'
    }

    It 'reports a missing treehouse with its install command, and nothing else' {
        Mock Test-CommandOnPath { $false }
        $problems = @(Get-TreehouseProblems)
        $problems | Should -HaveCount 1
        $problems[0] | Should -Match 'treehouse is not on PATH\. Fix: '
    }
}

Describe 'Get-WorktreeProcessIds' {
    BeforeAll {
        $script:wt = Join-Path $script:root 'pool-wt'
        New-Item -ItemType Directory -Force $script:wt | Out-Null
    }

    BeforeEach {
        # Every pid is readable unless a test says otherwise.
        Mock Get-ProcessInfo { New-FakeProcess -Id $ProcessId -Parent 1 -Started (Get-Date) }
    }

    It 'returns the pids treehouse lists for the worktree' {
        Set-FakeWorktreeProcesses $script:wt @(@{ pid = 4321; name = 'claude.exe' }, @{ pid = 4322; name = 'node.exe' })
        @(Get-WorktreeProcessIds $script:root $script:wt) | Should -Be @(4321, 4322)
    }

    It 'drops pid 0 and pid 4' {
        Set-FakeWorktreeProcesses $script:wt @(
            @{ pid = 0; name = 'System Idle Process' }, @{ pid = 4; name = 'System' }, @{ pid = 4321; name = 'claude.exe' })
        @(Get-WorktreeProcessIds $script:root $script:wt) | Should -Be @(4321)
    }

    It 'drops pid 4 in the "name (pid)" string form too' {
        Set-FakeWorktreeProcesses $script:wt @('System (4)', 'claude.exe (4321)')
        @(Get-WorktreeProcessIds $script:root $script:wt) | Should -Be @(4321)
    }

    It 'drops any pid whose process cannot be read' {
        Mock Get-ProcessInfo { $null } -ParameterFilter { $ProcessId -eq 5555 }
        Set-FakeWorktreeProcesses $script:wt @(@{ pid = 5555 }, @{ pid = 4321 })
        @(Get-WorktreeProcessIds $script:root $script:wt) | Should -Be @(4321)
    }

    It 'returns nothing, with a warning, when the list exceeds the bound' {
        Set-FakeWorktreeProcesses $script:wt @(1000..1050 | ForEach-Object { @{ pid = $_ } })  # 51 pids
        $out = @(Get-WorktreeProcessIds $script:root $script:wt 3>&1)
        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        @($out | Where-Object { $_ -is [int] }) | Should -HaveCount 0
        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Match 'lists 51 processes'
        # The listing is rejected before a single process is inspected.
        Should -Invoke Get-ProcessInfo -Times 0 -Exactly
    }

    It 'still returns a list that is exactly at the bound' {
        Set-FakeWorktreeProcesses $script:wt @(1000..1049 | ForEach-Object { @{ pid = $_ } })  # 50 pids
        @(Get-WorktreeProcessIds $script:root $script:wt 3>&1) | Should -HaveCount 50
    }

    It 'returns nothing for a worktree treehouse does not list' {
        Set-FakeWorktreeProcesses (Join-Path $script:root 'another-wt') @(@{ pid = 4321 })
        @(Get-WorktreeProcessIds $script:root $script:wt) | Should -HaveCount 0
    }
}

Describe 'Test-PathUnder' {
    It 'is true for <Path> under <Root>' -TestCases @(
        @{ Path = 'C:\pool\1\repo'; Root = 'C:\pool\1\repo' }
        @{ Path = 'C:\pool\1\repo\'; Root = 'C:\pool\1\repo' }
        @{ Path = 'C:\pool\1\repo\src\app'; Root = 'C:\pool\1\repo\' }
        @{ Path = 'c:\POOL\1\Repo\src'; Root = 'C:\pool\1\repo' }
    ) {
        Test-PathUnder $Path $Root | Should -BeTrue
    }

    It 'is false for <Path> under <Root>' -TestCases @(
        @{ Path = 'C:\pool\10\repo'; Root = 'C:\pool\1' }      # sibling sharing a prefix
        @{ Path = 'C:\pool\1\repo-other'; Root = 'C:\pool\1\repo' }
        @{ Path = 'C:\pool'; Root = 'C:\pool\1\repo' }         # parent, not child
        @{ Path = 'C:\Windows\System32'; Root = 'C:\pool\1\repo' }
        @{ Path = ''; Root = 'C:\pool\1\repo' }
        @{ Path = 'C:\pool\1\repo'; Root = '' }
    ) {
        Test-PathUnder $Path $Root | Should -BeFalse
    }
}

Describe 'Test-ProcessStartMatch' {
    It 'matches the same instant held as a local DateTime and as a UTC DateTime' {
        $local = Get-Date
        Test-ProcessStartMatch $local $local.ToUniversalTime() | Should -BeTrue
    }

    It 'matches a DateTime against the round-trip string dep-spawn records' {
        $local = Get-Date
        Test-ProcessStartMatch $local $local.ToString('o') | Should -BeTrue
    }

    It 'matches what ConvertFrom-Json makes of the recorded value, in any culture' {
        # Task state is read back with ConvertFrom-Json, which yields a
        # DateTime. Re-parsing that through text is what this replaced.
        $local = Get-Date
        $state = (@{ pidStartedAt = $local.ToString('o') } | ConvertTo-Json) | ConvertFrom-Json
        $state.pidStartedAt | Should -BeOfType [datetime]
        $previous = [cultureinfo]::CurrentCulture
        try {
            [cultureinfo]::CurrentCulture = [cultureinfo]::GetCultureInfo('de-DE')
            Test-ProcessStartMatch $local $state.pidStartedAt | Should -BeTrue
        }
        finally { [cultureinfo]::CurrentCulture = $previous }
    }

    It 'does not match a start time more than the tolerance away' {
        $local = Get-Date
        Test-ProcessStartMatch $local $local.AddSeconds(5) | Should -BeFalse
    }

    It 'does not match when either side is missing or unparseable' {
        Test-ProcessStartMatch (Get-Date) $null | Should -BeFalse
        Test-ProcessStartMatch $null (Get-Date) | Should -BeFalse
        Test-ProcessStartMatch (Get-Date) 'not a date' | Should -BeFalse
    }
}

Describe 'Test-TaskProcessAlive' {
    It 'recognises a live pid whose recorded start time is a UTC DateTime' {
        $me = Get-Process -Id $PID
        $state = [pscustomobject]@{ pid = $PID; pidStartedAt = $me.StartTime.ToUniversalTime(); worktree = $null; repo = $null }
        Test-TaskProcessAlive $state | Should -BeTrue
    }

    It 'does not accept a live pid that started at another time (a recycled pid)' {
        $me = Get-Process -Id $PID
        $state = [pscustomobject]@{ pid = $PID; pidStartedAt = $me.StartTime.AddHours(-3); worktree = $null; repo = $null }
        Test-TaskProcessAlive $state | Should -BeFalse
    }
}

Describe 'Test-TaskOwnsProcess' {
    BeforeAll {
        $script:t0 = [datetime]'2026-01-01T12:00:00'
        $script:worktree = 'C:\pool\1\repo'
        $script:task = [pscustomobject]@{
            id = 'posse-20260101-120000-abc'; pid = 100; pidStartedAt = $script:t0.ToString('o')
            worktree = $script:worktree
        }
    }

    BeforeEach {
        # A fake process table: the member (100), its child (200) and grandchild
        # (300), and bystanders that have nothing to do with the task.
        $script:table = @{
            100 = New-FakeProcess -Id 100 -Parent 50 -Started $script:t0
            200 = New-FakeProcess -Id 200 -Parent 100 -Started $script:t0.AddSeconds(5)
            300 = New-FakeProcess -Id 300 -Parent 200 -Started $script:t0.AddSeconds(6)
            50  = New-FakeProcess -Id 50 -Parent 1 -Started $script:t0.AddHours(-1)
            500 = New-FakeProcess -Id 500 -Parent 50 -Started $script:t0.AddSeconds(9)
        }
        $script:cwds = @{}
        Mock Get-ProcessInfo { $script:table[$ProcessId] }
        Mock Get-ProcessWorkingDirectory { $script:cwds[$ProcessId] }
    }

    It 'owns the recorded member pid' {
        Test-TaskOwnsProcess $script:task 100 | Should -BeTrue
    }

    It 'owns a child and a grandchild of the member' {
        Test-TaskOwnsProcess $script:task 200 | Should -BeTrue
        Test-TaskOwnsProcess $script:task 300 | Should -BeTrue
    }

    It 'owns a child that outlived the member (the member was only a launcher)' {
        $script:table.Remove(100)
        Test-TaskOwnsProcess $script:task 200 | Should -BeTrue
    }

    It 'owns a process outside the tree that is working inside the worktree' {
        $script:cwds[500] = 'C:\pool\1\repo\src\'
        Test-TaskOwnsProcess $script:task 500 | Should -BeTrue
    }

    It 'does not own a bystander treehouse mislisted' {
        $script:cwds[500] = 'C:\Users\someone\project\'
        Test-TaskOwnsProcess $script:task 500 | Should -BeFalse
    }

    It 'does not own a bystander whose working directory cannot be read' {
        Test-TaskOwnsProcess $script:task 500 | Should -BeFalse
    }

    It 'does not own a process whose executable path and command line are both unreadable' {
        # Even one sitting right under the member pid: unreadable means hands off.
        $script:table[200] = New-FakeProcess -Id 200 -Parent 100 -Started $script:t0.AddSeconds(5) -Exe '' -Cmd ''
        $script:cwds[200] = $script:worktree
        Test-TaskOwnsProcess $script:task 200 | Should -BeFalse
    }

    It 'owns a readable process that exposes only a command line' {
        $script:table[200] = New-FakeProcess -Id 200 -Parent 100 -Started $script:t0.AddSeconds(5) -Exe ''
        Test-TaskOwnsProcess $script:task 200 | Should -BeTrue
    }

    It 'does not own a process that no longer exists' {
        Test-TaskOwnsProcess $script:task 999 | Should -BeFalse
    }

    It 'does not own pid 0 or pid 4, whatever they look like' {
        $script:table[4] = New-FakeProcess -Id 4 -Parent 100 -Started $script:t0.AddSeconds(5)
        $script:cwds[4] = $script:worktree
        Test-TaskOwnsProcess $script:task 4 | Should -BeFalse
        Test-TaskOwnsProcess $script:task 0 | Should -BeFalse
    }

    It 'does not own the member pid once Windows has recycled it' {
        $script:table[100] = New-FakeProcess -Id 100 -Parent 50 -Started $script:t0.AddHours(2)
        Test-TaskOwnsProcess $script:task 100 | Should -BeFalse
    }

    It 'does not own the child of a process that recycled the member pid' {
        # pid 100 now belongs to something that started after its "child" did:
        # that parent link points at a dead process, not at the member.
        $script:table[100] = New-FakeProcess -Id 100 -Parent 50 -Started $script:t0.AddHours(2)
        $script:table[600] = New-FakeProcess -Id 600 -Parent 100 -Started $script:t0.AddHours(-2)
        Test-TaskOwnsProcess $script:task 600 | Should -BeFalse
    }

    It 'cannot place anything by descent when the record has no start time' {
        $legacy = [pscustomobject]@{ id = $script:task.id; pid = 100; worktree = $script:worktree }
        Test-TaskOwnsProcess $legacy 200 | Should -BeFalse
        # ...but the working directory still can.
        $script:cwds[200] = $script:worktree
        Test-TaskOwnsProcess $legacy 200 | Should -BeTrue
    }
}

Describe 'Stop-TaskProcesses' {
    BeforeAll {
        $script:killWorktree = Join-Path $script:root 'kill-wt'
        New-Item -ItemType Directory -Force $script:killWorktree | Out-Null
        $script:killTask = [pscustomobject]@{
            id = 'posse-20260101-120000-abc'; pid = 100; pidStartedAt = (Get-Date).ToString('o')
            worktree = $script:killWorktree; repo = $script:root
        }
    }

    BeforeEach {
        $script:killedPids = @()
        Mock Stop-TaskProcessTree { $script:killedPids += $ProcessId }
        Mock Get-ProcessInfo { New-FakeProcess -Id $ProcessId -Parent 1 -Started (Get-Date) }
        Mock Get-OwnProcessChain { @(900, 901) }
    }

    It 'kills only the pids proven to be the task''s, and warns about the rest' {
        Mock Get-WorktreeProcessIds { @(200, 500) }
        Mock Test-TaskOwnsProcess { $ProcessId -in 100, 200 }
        $out = @(Stop-TaskProcesses $script:killTask 3>&1)
        $script:killedPids | Should -Be @(100, 200)
        @($out | Where-Object { $_ -is [int] }) | Should -Be @(100, 200)
        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $warnings | Should -HaveCount 1
        $warnings[0].Message | Should -Match 'left pid 500 running'
    }

    It 'kills nothing when nothing can be proven' {
        Mock Get-WorktreeProcessIds { @(500, 501) }
        Mock Test-TaskOwnsProcess { $false }
        @(Stop-TaskProcesses $script:killTask 3>$null) | Should -HaveCount 0
        $script:killedPids | Should -HaveCount 0
    }

    It 'never kills the calling process or its ancestors' {
        Mock Get-WorktreeProcessIds { @(900, 901, 200) }
        Mock Test-TaskOwnsProcess { $true }
        Stop-TaskProcesses $script:killTask | Out-Null
        $script:killedPids | Should -Be @(100, 200)
    }

    It 'skips a candidate that is already gone without warning about it' {
        Mock Get-WorktreeProcessIds { @() }
        Mock Get-ProcessInfo { $null }
        Mock Test-TaskOwnsProcess { $true }
        $out = @(Stop-TaskProcesses $script:killTask 3>&1)
        $out | Should -HaveCount 0
        $script:killedPids | Should -HaveCount 0
    }
}

Describe 'Get-ProcessWorkingDirectory' {
    It 'reads the working directory of another live process' {
        $dir = Join-Path $script:root 'cwd probe'
        New-Item -ItemType Directory -Force $dir | Out-Null
        $proc = Start-Sleeper -WorkingDirectory $dir
        try {
            $cwd = Get-ProcessWorkingDirectory $proc.Id
            Test-PathUnder $cwd $dir | Should -BeTrue
            Test-PathUnder $dir $cwd | Should -BeTrue
        }
        finally { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    }

    It 'returns nothing for a process it cannot open' {
        Get-ProcessWorkingDirectory 4 | Should -BeNullOrEmpty
    }
}

Describe 'toolbelt end to end, against fake tools on PATH' {
    BeforeAll {
        $script:shims = New-ToolShims -Path (Join-Path $script:root 'shims')
        $script:savedPath = $env:PATH
        $env:PATH = $script:shims + [System.IO.Path]::PathSeparator + $env:PATH

        # A Deputy install that is a real clone: on main, with an origin.
        $script:install = New-TestRepo -Path (Join-Path $script:root 'install') -WithRemote
        New-DeputyInstall -Path $script:install -SourceRoot $script:repoRoot | Out-Null
        # A repo for spawn to be pointed at.
        $script:target = New-TestRepo -Path (Join-Path $script:root 'target')
    }

    AfterAll {
        $env:PATH = $script:savedPath
    }

    BeforeEach {
        Set-ShimVersion -Path $script:shims -Version 'v3.1.8'
        Remove-Item (Join-Path $script:shims 'status.json') -ErrorAction SilentlyContinue
    }

    Context 'dep-doctor.ps1' {
        It 'prints nothing and exits 0 when the toolchain is healthy' {
            $run = Invoke-DeputyScript -InstallRoot $script:install -Script 'dep-doctor.ps1'
            $run.Output.Trim() | Should -BeNullOrEmpty
            $run.ExitCode | Should -Be 0
        }

        It 'exits 1 with one line naming the fix when treehouse is a major version behind' {
            Set-ShimVersion -Path $script:shims -Version 'v2.1.0'
            $run = Invoke-DeputyScript -InstallRoot $script:install -Script 'dep-doctor.ps1'
            $run.ExitCode | Should -Be 1
            $lines = @($run.Output.Trim() -split "`r?`n")
            $lines | Should -HaveCount 1
            $lines[0] | Should -Match 'treehouse 2\.1\.0 is older than the minimum 3\.0\.1\. Fix: treehouse update'
        }

        It 'exits 1 when the treehouse version cannot be parsed' {
            Set-ShimVersion -Path $script:shims -Version 'treehouse (devel)'
            $run = Invoke-DeputyScript -InstallRoot $script:install -Script 'dep-doctor.ps1'
            $run.ExitCode | Should -Be 1
            $run.Output | Should -Match 'treated as incompatible'
        }

        It 'reports a clone that is off its default branch' {
            Invoke-Git @('-C', $script:install, 'switch', '-q', '-c', 'side-quest')
            try {
                $run = Invoke-DeputyScript -InstallRoot $script:install -Script 'dep-doctor.ps1'
                $run.ExitCode | Should -Be 1
                $run.Output | Should -Match "is on branch 'side-quest', not its default branch 'main'"
                $run.Output | Should -Match 'switch main'
            }
            finally { Invoke-Git @('-C', $script:install, 'switch', '-q', 'main') }
        }

        It 'reports a clone that is behind origin, and changes nothing while doing so' {
            # Someone else pushes to origin.
            $other = Join-Path $script:root 'other-clone'
            Invoke-Git @('clone', '-q', "$($script:install).origin.git", $other)
            Invoke-Git @('-C', $other, 'config', 'user.email', 'posse@example.invalid')
            Invoke-Git @('-C', $other, 'config', 'user.name', 'Posse Test')
            Invoke-Git @('-C', $other, 'config', 'commit.gpgsign', 'false')
            Set-RepoFile -Repo $other -Path 'upstream.txt' -Content "newer`n"
            Invoke-Git @('-C', $other, 'add', '-A')
            Invoke-Git @('-C', $other, 'commit', '-q', '-m', 'upstream change')
            Invoke-Git @('-C', $other, 'push', '-q', 'origin', 'main')

            $refsBefore = (& git -C $script:install for-each-ref) -join "`n"
            $run = Invoke-DeputyScript -InstallRoot $script:install -Script 'dep-doctor.ps1'
            $run.ExitCode | Should -Be 1
            $run.Output | Should -Match 'is behind origin/main\. Fix: git -C ".+" pull --ff-only'
            # Report only: no fetch, no pull.
            ((& git -C $script:install for-each-ref) -join "`n") | Should -Be $refsBefore
            Test-Path (Join-Path $script:install 'upstream.txt') | Should -BeFalse
        }
    }

    Context 'dep-spawn.ps1' {
        It 'refuses to lease from an old treehouse, and never asks it for a worktree' {
            Set-ShimVersion -Path $script:shims -Version 'v2.1.0'
            $run = Invoke-DeputyScript -InstallRoot $script:install -Script 'dep-spawn.ps1' `
                -Arguments @('-Task', 'do a thing', '-Repo', $script:target)
            $run.ExitCode | Should -Not -Be 0
            $run.Output | Should -Match 'Refusing to lease a worktree'
            $run.Output | Should -Match 'treehouse 2\.1\.0 is older than the minimum 3\.0\.1'
            @(Get-ShimCalls $script:shims | Where-Object { $_ -match '--lease-holder' }) | Should -HaveCount 0
            @(Get-ChildItem (Join-Path $script:install 'state') -Filter 'posse-*' -ErrorAction SilentlyContinue) |
                Should -HaveCount 0
        }

        It 'refuses to lease when the treehouse version cannot be parsed' {
            Set-ShimVersion -Path $script:shims -Version 'who knows'
            $run = Invoke-DeputyScript -InstallRoot $script:install -Script 'dep-spawn.ps1' `
                -Arguments @('-Task', 'do a thing', '-Repo', $script:target)
            $run.ExitCode | Should -Not -Be 0
            $run.Output | Should -Match 'Refusing to lease a worktree'
            @(Get-ShimCalls $script:shims | Where-Object { $_ -match '--lease-holder' }) | Should -HaveCount 0
        }

        It 'goes on to lease when treehouse passes the check' {
            # The fake treehouse cannot actually lease, so the spawn still fails -
            # but past the guard, at the lease itself.
            $run = Invoke-DeputyScript -InstallRoot $script:install -Script 'dep-spawn.ps1' `
                -Arguments @('-Task', 'do a thing', '-Repo', $script:target)
            $run.Output | Should -Not -Match 'Refusing to lease'
            $run.Output | Should -Match 'treehouse failed to lease a worktree'
            @(Get-ShimCalls $script:shims | Where-Object { $_ -match '--lease-holder' }) | Should -HaveCount 1
        }
    }

    Context 'dep-posse.ps1 kill' {
        BeforeAll {
            $script:e2eWorktree = Join-Path $script:root 'e2e-wt'
            $script:elsewhere = Join-Path $script:root 'elsewhere'
            New-Item -ItemType Directory -Force $script:e2eWorktree, $script:elsewhere | Out-Null

            function Set-KillTaskState {
                param([int]$ProcessId, [string]$StartedAt)
                $id = New-TestTaskState -InstallRoot $script:install -Repo $script:target `
                    -Worktree $script:e2eWorktree -Branch 'deputy/x'
                $file = Join-Path $script:install 'state' "$id.json"
                $state = Get-Content $file -Raw | ConvertFrom-Json -AsHashtable
                $state.pid = $ProcessId
                $state.pidStartedAt = $StartedAt
                $state.status = 'running'
                ($state | ConvertTo-Json -Depth 6) | Set-Content -Path $file -Encoding utf8
                $id
            }

            function Set-ShimStatus {
                param([int[]]$ProcessIds)
                $json = ConvertTo-Json -Depth 5 -Compress -InputObject @(
                    [ordered]@{ path = $script:e2eWorktree; processes = @($ProcessIds | ForEach-Object { @{ pid = $_ } }) }
                )
                Set-Content -Path (Join-Path $script:shims 'status.json') -Encoding ascii -Value $json
            }
        }

        It 'kills the member, and leaves alone a bystander treehouse mislists in the worktree' {
            $member = Start-Sleeper -WorkingDirectory $script:e2eWorktree
            $bystander = Start-Sleeper -WorkingDirectory $script:elsewhere
            try {
                $id = Set-KillTaskState -ProcessId $member.Id -StartedAt $member.StartTime.ToString('o')
                Set-ShimStatus -ProcessIds 0, 4, $bystander.Id

                $run = Invoke-DeputyScript -InstallRoot $script:install -Script 'dep-posse.ps1' -Arguments @('kill', $id)
                $run.ExitCode | Should -Be 0
                $run.Output | Should -Match "killed process tree\(s\) for $id \(pid $($member.Id)\)"
                $run.Output | Should -Match "left pid $($bystander.Id) running"

                $member.WaitForExit(10000) | Should -BeTrue
                Get-Process -Id $bystander.Id -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
                (Get-TestTaskState -InstallRoot $script:install -Id $id).status | Should -Be 'killed'
            }
            finally {
                $member, $bystander | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'does not kill a process that merely holds the recorded pid (a recycled pid)' {
            # The record names this pid but a different start time, and the
            # process works somewhere else entirely: it is not the member.
            $stranger = Start-Sleeper -WorkingDirectory $script:elsewhere
            try {
                $id = Set-KillTaskState -ProcessId $stranger.Id -StartedAt $stranger.StartTime.AddHours(-6).ToString('o')
                $run = Invoke-DeputyScript -InstallRoot $script:install -Script 'dep-posse.ps1' -Arguments @('kill', $id)
                $run.ExitCode | Should -Be 0
                $run.Output | Should -Match 'nothing was killed'
                Get-Process -Id $stranger.Id -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }
            finally { Stop-Process -Id $stranger.Id -Force -ErrorAction SilentlyContinue }
        }

        It 'kills a straggler found only through the worktree, when the recorded pid is long dead' {
            $straggler = Start-Sleeper -WorkingDirectory $script:e2eWorktree
            try {
                $id = Set-KillTaskState -ProcessId 999999 -StartedAt (Get-Date).AddHours(-1).ToString('o')
                Set-ShimStatus -ProcessIds $straggler.Id
                $run = Invoke-DeputyScript -InstallRoot $script:install -Script 'dep-posse.ps1' -Arguments @('kill', $id)
                $run.ExitCode | Should -Be 0
                $run.Output | Should -Match "killed process tree\(s\) for $id \(pid $($straggler.Id)\)"
                $straggler.WaitForExit(10000) | Should -BeTrue
            }
            finally { Stop-Process -Id $straggler.Id -Force -ErrorAction SilentlyContinue }
        }
    }
}
