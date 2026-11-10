#Requires -Version 7.0
<#
.SYNOPSIS
Tests for the session hooks: the tracked .claude\settings.json, the stop
guard's decision table (dep-hook-guard.ps1), the rewake hook
(dep-hook-stop.ps1) and the session-start report (dep-session-start.ps1).
Every script runs as a real process, with the hook's JSON on stdin, against a
throwaway Deputy install.

The rule these pin down hardest: the hooks do nothing at all in a posse
worktree. The same settings file is loaded by posse members working on the
Deputy repository itself, and a member that blocked its own stop or started a
watcher would be acting as a second Deputy.
#>

BeforeAll {
    $script:sourceRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:root = New-TempRoot
    $script:n = 0
    $script:processes = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    $script:me = Get-Process -Id $PID
    # A posse member running this suite carries the marker. The hooks under
    # test must see what a Deputy session would see, so it is cleared here and
    # set explicitly by the tests that are about it.
    $script:savedMarker = $env:DEPUTY_POSSE_TASK
    $env:DEPUTY_POSSE_TASK = $null

    function New-HookInstall {
        <#
        .SYNOPSIS
        A throwaway Deputy home. -Tasks registers that many running tasks,
        -Wakes queues that many unacknowledged wakes, -NoAutoWatch switches
        the rewake hook off in its config.
        #>
        param([int]$Tasks = 0, [int]$Wakes = 0, [switch]$NoAutoWatch, [switch]$NoState)
        $script:n++
        $install = New-DeputyInstall -Path (Join-Path $script:root "case$($script:n)" 'deputy') -SourceRoot $script:sourceRoot
        $state = Join-Path $install 'state'
        if (-not $NoState) { New-Item -ItemType Directory -Force $state | Out-Null }
        # Poll every second, so a watcher the hook starts reacts quickly.
        ([ordered]@{ watchIntervalSeconds = 1; autoWatch = (-not $NoAutoWatch) } | ConvertTo-Json) |
            Set-Content -Path (Join-Path $install 'config' 'deputy.json') -Encoding utf8
        $taskList = @(for ($i = 0; $i -lt $Tasks; $i++) {
            $task = New-TestRunningTask -InstallRoot $install -Id ('posse-20260101-12000{0}-abc' -f $i)
            $script:processes.Add($task.Member)
            $task
        })
        for ($i = 1; $i -le $Wakes; $i++) {
            $row = [ordered]@{
                seq = $i; at = (Get-Date -Format o); taskId = 'posse-20260101-110000-xyz'; event = 'completed'
                kind = 'ship'; summary = "queued report $i"
            }
            Add-Content -Path (Join-Path $state 'wake-queue.jsonl') -Value ($row | ConvertTo-Json -Compress) -Encoding utf8
            Set-Content -Path (Join-Path $state 'wake-queue.seq') -Value $i
        }
        [pscustomobject]@{ Root = $install; State = $state; Tasks = $taskList }
    }

    function Set-FakeWatcher {
        # Make the install look like it has a healthy watcher: a lock naming a
        # live process (this one) and a fresh heartbeat.
        param($Install, [string]$Session = '')
        ([ordered]@{ pid = $PID; startedAt = $script:me.StartTime.ToString('o'); session = $Session } | ConvertTo-Json -Compress) |
            Set-Content -Path (Join-Path $Install.State 'watcher.lock') -Encoding utf8
        Set-Content -Path (Join-Path $Install.State 'watcher.beat') -Value (Get-Date -Format o)
    }

    function Remove-FakeWatcher($Install) {
        Remove-Item (Join-Path $Install.State 'watcher.lock'), (Join-Path $Install.State 'watcher.beat') -Force -ErrorAction SilentlyContinue
    }

    function Invoke-Guard($Install, [string[]]$Arguments = @('-GraceSeconds', '0'), [hashtable]$HookInput = @{}) {
        Invoke-DeputyHook -InstallRoot $Install.Root -Script 'dep-hook-guard.ps1' -Arguments $Arguments -HookInput $HookInput
    }

    function Invoke-StopHook($Install, [hashtable]$HookInput = @{}, [string[]]$Arguments = @()) {
        Invoke-DeputyHook -InstallRoot $Install.Root -Script 'dep-hook-stop.ps1' -Arguments $Arguments -HookInput $HookInput
    }

    function Invoke-SessionStart($Install, [hashtable]$HookInput = @{ hook_event_name = 'SessionStart'; source = 'compact' }, [string[]]$Arguments = @('-Hook')) {
        Invoke-DeputyHook -InstallRoot $Install.Root -Script 'dep-session-start.ps1' -Arguments $Arguments -HookInput $HookInput
    }

    function Get-GuardBlocks($Install) {
        $path = Join-Path $Install.State 'hook-guard.blocks'
        if (Test-Path $path) { [int](Get-Content $path -Raw).Trim() } else { 0 }
    }

    function Get-StateSnapshot($Install) {
        # Every file under the install except its code, with a content hash:
        # equal snapshots mean a hook touched nothing.
        @(Get-ChildItem -Path $Install.Root -Recurse -File |
            Where-Object { $_.FullName -notlike (Join-Path $Install.Root 'bin' '*') } |
            Sort-Object FullName |
            ForEach-Object { '{0} {1}' -f $_.FullName.Substring($Install.Root.Length), (Get-FileHash $_.FullName).Hash }) -join "`n"
    }

    function Get-NonEmptyLines([string]$Text) {
        , @($Text -split "`r?`n" | Where-Object { $_.Trim() })
    }

    function Start-StopHook($Install, [string]$Session = 'session-test', [string]$EventName = 'Stop') {
        # The rewake hook as a background process, as Claude Code runs it.
        $stdin = Join-Path $Install.Root ('hook-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.in')
        ([ordered]@{ session_id = $Session; hook_event_name = $EventName } | ConvertTo-Json -Compress) | Set-Content $stdin -Encoding utf8
        $stderr = "$stdin.err"
        $proc = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden `
            -RedirectStandardInput $stdin -RedirectStandardError $stderr -RedirectStandardOutput "$stdin.out" `
            -ArgumentList @('-NoProfile', '-File', ('"{0}"' -f (Join-Path $Install.Root 'bin' 'dep-hook-stop.ps1')))
        $script:processes.Add($proc)
        [pscustomobject]@{ Process = $proc; ErrorFile = $stderr; OutFile = "$stdin.out" }
    }

    function Wait-WatcherLock($Install, [int]$TimeoutSeconds = 30) {
        # The lock record once a watcher holds it, or $null on timeout.
        $path = Join-Path $Install.State 'watcher.lock'
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            $lock = if (Test-Path $path) { try { Get-Content $path -Raw | ConvertFrom-Json } catch { $null } } else { $null }
            if ($lock -and $lock.pid) { return $lock }
            Start-Sleep -Milliseconds 100
        }
        $null
    }

    function New-ToolShims {
        # Fake gh, claude and treehouse first on PATH, so the doctor inside the
        # session-start report never touches the network or the real tools.
        $path = Join-Path $script:root 'shims'
        New-Item -ItemType Directory -Force $path | Out-Null
        foreach ($tool in 'gh', 'claude') {
            Set-Content -Path (Join-Path $path "$tool.cmd") -Encoding ascii -Value '@exit /b 0'
        }
        Set-Content -Path (Join-Path $path 'treehouse.cmd') -Encoding ascii -Value @(
            '@echo off'
            'if "%1"=="--version" (echo v3.1.8 & exit /b 0)'
            'if "%1"=="get" (echo       --lease                 Durably lease a worktree & exit /b 0)'
            'exit /b 1'
        )
        $path
    }
}

AfterAll {
    foreach ($proc in $script:processes) {
        if (-not $proc.HasExited) { $proc.Kill() }
    }
    $env:DEPUTY_POSSE_TASK = $script:savedMarker
    if ($script:root) { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }
}

Describe '.claude\settings.json' {
    BeforeAll {
        $script:settingsPath = Join-Path $script:sourceRoot '.claude' 'settings.json'
        $script:settings = Get-Content $script:settingsPath -Raw | ConvertFrom-Json
        function Get-Hooks([string]$EventName) {
            , @($script:settings.hooks.$EventName | ForEach-Object { $_.hooks })
        }
        function Get-HookScript($HookEntry) {
            Split-Path -Leaf (@($HookEntry.args) | Where-Object { $_ -like '*.ps1' } | Select-Object -First 1)
        }
    }


    It 'runs dep-session-start.ps1 -Hook on SessionStart' {
        $hooks = Get-Hooks 'SessionStart'
        $hooks.Count | Should -Be 1
        Get-HookScript $hooks[0] | Should -Be 'dep-session-start.ps1'
        $hooks[0].args | Should -Contain '-Hook'
    }

    It 'runs the guard synchronously and the rewake hook with asyncRewake on Stop' {
        $hooks = Get-Hooks 'Stop'
        $guard = @($hooks | Where-Object { (Get-HookScript $_) -eq 'dep-hook-guard.ps1' })
        $rewake = @($hooks | Where-Object { (Get-HookScript $_) -eq 'dep-hook-stop.ps1' })
        $guard.Count | Should -Be 1
        $rewake.Count | Should -Be 1
        $guard[0].PSObject.Properties['asyncRewake'] | Should -BeNullOrEmpty
        $guard[0].PSObject.Properties['async'] | Should -BeNullOrEmpty
        $rewake[0].asyncRewake | Should -BeTrue
    }

    It 'runs the rewake hook with asyncRewake on StopFailure, and no guard' {
        $hooks = Get-Hooks 'StopFailure'
        $hooks.Count | Should -Be 1
        Get-HookScript $hooks[0] | Should -Be 'dep-hook-stop.ps1'
        $hooks[0].asyncRewake | Should -BeTrue
    }

    It 'starts every hook as pwsh in exec form, from a script that exists under bin\' {
        # Exec form (command + args) needs no shell, so the hooks do not depend
        # on Git Bash being installed.
        $all = @('SessionStart', 'Stop', 'StopFailure' | ForEach-Object { Get-Hooks $_ } | ForEach-Object { $_ })
        $all.Count | Should -Be 4
        foreach ($hookEntry in $all) {
            $hookEntry.type | Should -Be 'command'
            $hookEntry.command | Should -Be 'pwsh'
            $script = @($hookEntry.args) | Where-Object { $_ -like '*.ps1' }
            $script | Should -BeLike '${CLAUDE_PROJECT_DIR}/bin/dep-*.ps1'
            Join-Path $script:sourceRoot 'bin' (Split-Path -Leaf $script) | Should -Exist
        }
    }

    It 'names no user, machine or repository path' {
        Get-Content $script:settingsPath -Raw | Should -Not -Match '(?i)[a-z]:[\\/]|\\Users\\|/home/'
    }
}

Describe 'Get-StopGuardDecision' {
    BeforeAll {
        . (Join-Path $script:sourceRoot 'bin' 'dep-lib.ps1')
    }

    It 'with <Active> active task(s), watcher healthy=<Healthy>, <Blocks> block(s) so far: <Action>, then <After> block(s)' -TestCases @(
        # No task is active: nothing to guard, whatever else is true.
        @{ Active = 0; Healthy = $false; Blocks = 0; Action = 'allow'; After = 0 }
        @{ Active = 0; Healthy = $true; Blocks = 0; Action = 'allow'; After = 0 }
        @{ Active = 0; Healthy = $false; Blocks = 2; Action = 'allow'; After = 0 }
        @{ Active = 0; Healthy = $false; Blocks = 3; Action = 'allow'; After = 0 }
        # Tasks are active and something is watching them.
        @{ Active = 1; Healthy = $true; Blocks = 0; Action = 'allow'; After = 0 }
        @{ Active = 4; Healthy = $true; Blocks = 2; Action = 'allow'; After = 0 }
        @{ Active = 1; Healthy = $true; Blocks = 3; Action = 'allow'; After = 0 }
        # Tasks are active and nothing is watching: block, three times at most.
        @{ Active = 1; Healthy = $false; Blocks = 0; Action = 'block'; After = 1 }
        @{ Active = 1; Healthy = $false; Blocks = 1; Action = 'block'; After = 2 }
        @{ Active = 4; Healthy = $false; Blocks = 2; Action = 'block'; After = 3 }
        # The budget is spent: let it through, loudly, and stay that way.
        @{ Active = 1; Healthy = $false; Blocks = 3; Action = 'release'; After = 3 }
        @{ Active = 4; Healthy = $false; Blocks = 9; Action = 'release'; After = 9 }
    ) {
        $decision = Get-StopGuardDecision -ActiveTasks $Active -WatcherHealthy $Healthy -Blocks $Blocks
        $decision.Action | Should -Be $Action
        $decision.Blocks | Should -Be $After
    }
}

Describe 'dep-hook-guard.ps1' {
    It 'lets the stop through, silently, when no task is active' {
        $install = New-HookInstall
        $run = Invoke-Guard $install
        $run.ExitCode | Should -Be 0
        $run.Output.Trim() | Should -BeNullOrEmpty
        $run.ErrorOutput.Trim() | Should -BeNullOrEmpty
    }

    It 'lets the stop through when every task has finished' {
        $install = New-HookInstall
        $null = New-TestTaskState -InstallRoot $install.Root -Repo $install.Root -Worktree $install.Root -Branch 'deputy/x'
        (Invoke-Guard $install).ExitCode | Should -Be 0
    }

    It 'blocks with a one-line instruction to start the watcher when a task is running and nothing watches' {
        $install = New-HookInstall -Tasks 2
        $run = Invoke-Guard $install
        $run.ExitCode | Should -Be 2
        $run.Output.Trim() | Should -BeNullOrEmpty
        $lines = Get-NonEmptyLines $run.ErrorOutput
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match '^Deputy stop guard \(1/3\): 2 posse task\(s\) are active and no watcher is running\.'
        $lines[0] | Should -BeLike ('*pwsh -NoProfile -File "{0}" -Wait' -f (Join-Path $install.Root 'bin' 'dep-watch.ps1'))
        Get-GuardBlocks $install | Should -Be 1
    }

    It 'counts a stalled task as active' {
        $install = New-HookInstall -Tasks 1
        $file = Join-Path $install.State "$($install.Tasks[0].Id).json"
        $state = Get-Content $file -Raw | ConvertFrom-Json
        $state.status = 'stalled'
        ($state | ConvertTo-Json -Depth 6) | Set-Content $file -Encoding utf8
        (Invoke-Guard $install).ExitCode | Should -Be 2
    }

    It 'lets the stop through when a healthy watcher is running' {
        $install = New-HookInstall -Tasks 1
        Set-FakeWatcher $install
        $run = Invoke-Guard $install
        $run.ExitCode | Should -Be 0
        $run.ErrorOutput.Trim() | Should -BeNullOrEmpty
    }

    It 'does not count a watcher that reports to another session' {
        $install = New-HookInstall -Tasks 1
        Set-FakeWatcher $install -Session 'some-other-session'
        $run = Invoke-Guard $install
        $run.ExitCode | Should -Be 2
        $run.ErrorOutput | Should -Match 'the running watcher reports to another session \(some-other-session\)'
    }

    It 'does not count a watcher whose heartbeat is stale' {
        $install = New-HookInstall -Tasks 1
        Set-FakeWatcher $install
        (Get-Item (Join-Path $install.State 'watcher.beat')).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-30)
        $run = Invoke-Guard $install
        $run.ExitCode | Should -Be 2
        $run.ErrorOutput | Should -Match 'has not polled for'
    }

    Context 'when the watcher never comes' {
        BeforeAll {
            $script:stuck = New-HookInstall -Tasks 1
            $script:stuckRuns = @(1..5 | ForEach-Object { Invoke-Guard $script:stuck })
        }

        It 'blocks three stops in a row, numbering them' {
            @($script:stuckRuns[0..2] | ForEach-Object ExitCode) | Should -Be @(2, 2, 2)
            $script:stuckRuns[0].ErrorOutput | Should -Match '\(1/3\)'
            $script:stuckRuns[1].ErrorOutput | Should -Match '\(2/3\)'
            $script:stuckRuns[2].ErrorOutput | Should -Match '\(3/3\)'
        }

        It 'then lets the stop through loudly, with a message for the Sheriff' {
            $fourth = $script:stuckRuns[3]
            $fourth.ExitCode | Should -Be 0
            $fourth.ErrorOutput.Trim() | Should -BeNullOrEmpty
            $message = ($fourth.Output | ConvertFrom-Json).systemMessage
            $message | Should -Match 'DEPUTY STOP GUARD GAVE UP'
            $message | Should -Match 'NOTHING WILL WAKE THE DEPUTY'
            $message | Should -Match 'dep-watch\.ps1" -Wait'
        }

        It 'keeps letting it through instead of starting a new round of blocks' {
            $script:stuckRuns[4].ExitCode | Should -Be 0
            ($script:stuckRuns[4].Output | ConvertFrom-Json).systemMessage | Should -Match 'GAVE UP'
            Get-GuardBlocks $script:stuck | Should -Be 3
        }

        It 'starts a new budget once a watcher has been healthy' {
            Set-FakeWatcher $script:stuck
            $healthy = Invoke-Guard $script:stuck
            $healthy.ExitCode | Should -Be 0
            $healthy.Output.Trim() | Should -BeNullOrEmpty
            Get-GuardBlocks $script:stuck | Should -Be 0

            Remove-FakeWatcher $script:stuck
            $run = Invoke-Guard $script:stuck
            $run.ExitCode | Should -Be 2
            $run.ErrorOutput | Should -Match '\(1/3\)'
        }
    }

    Context 'beside the rewake hook (autoWatch on)' {
        It 'waits for the watcher the rewake hook is starting, then lets the stop through' {
            $install = New-HookInstall -Tasks 1
            $lock = Join-Path $install.State 'watcher.lock'
            $beat = Join-Path $install.State 'watcher.beat'
            $record = [ordered]@{ pid = $PID; startedAt = $script:me.StartTime.ToString('o'); session = 'session-test' } | ConvertTo-Json -Compress
            $late = Start-ThreadJob {
                Start-Sleep -Seconds 2
                Set-Content -Path $using:lock -Value $using:record -Encoding utf8
                Set-Content -Path $using:beat -Value 'beat'
            }
            try {
                $run = Invoke-Guard $install @('-GraceSeconds', '30')
                $run.ExitCode | Should -Be 0
                $run.ErrorOutput.Trim() | Should -BeNullOrEmpty
                Get-GuardBlocks $install | Should -Be 0
            }
            finally { $late | Remove-Job -Force }
        }

        It 'blocks once the wait is over and no watcher came' {
            $install = New-HookInstall -Tasks 1
            $run = Invoke-Guard $install @('-GraceSeconds', '1')
            $run.ExitCode | Should -Be 2
        }

        It 'lets the stop through when the rewake hook has just handed the session a wake' {
            $install = New-HookInstall -Tasks 1 -Wakes 1
            $announced = Join-Path $install.State 'hook-stop.announced'
            # The rewake hook runs beside the guard and announces a moment later.
            $late = Start-ThreadJob {
                Start-Sleep -Seconds 2
                Set-Content -Path $using:announced -Value '{"seq":1,"retries":0}'
            }
            try {
                $run = Invoke-Guard $install @('-GraceSeconds', '30')
                $run.ExitCode | Should -Be 0
                $run.ErrorOutput.Trim() | Should -BeNullOrEmpty
                Get-GuardBlocks $install | Should -Be 0
            }
            finally { $late | Remove-Job -Force }
        }

        It 'is not fooled by a wake that was handed over long ago' {
            $install = New-HookInstall -Tasks 1 -Wakes 1
            $announced = Join-Path $install.State 'hook-stop.announced'
            Set-Content $announced '{"seq":1,"retries":0}'
            (Get-Item $announced).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-10)
            (Invoke-Guard $install @('-GraceSeconds', '1')).ExitCode | Should -Be 2
        }
    }

    It 'blocks at once, without waiting, when autoWatch is off' {
        $install = New-HookInstall -Tasks 1 -NoAutoWatch
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-Guard $install @('-GraceSeconds', '60')
        $run.ExitCode | Should -Be 2
        $timer.Elapsed.TotalSeconds | Should -BeLessThan 30
    }

    It 'fails open, and says so, when it cannot read the posse' {
        $install = New-HookInstall -Tasks 1
        Set-Content (Join-Path $install.State 'posse-20260101-999999-bad.json') '{ this is not json'
        $run = Invoke-Guard $install
        $run.ExitCode | Should -Be 0
        $run.ErrorOutput | Should -Match 'Deputy stop guard failed and let the stop through'
    }
}

Describe 'dep-hook-stop.ps1' {
    It 'does nothing when no task is active and the queue is empty' {
        $install = New-HookInstall
        $run = Invoke-StopHook $install
        $run.ExitCode | Should -Be 0
        $run.Output.Trim() | Should -BeNullOrEmpty
        $run.ErrorOutput.Trim() | Should -BeNullOrEmpty
        Test-Path (Join-Path $install.State 'watcher.lock') | Should -BeFalse
    }

    Context 'with a wake in the queue that the session was never told about' {
        BeforeAll {
            $script:queued = New-HookInstall -Wakes 2
            $script:queuedRun = Invoke-StopHook $script:queued
        }

        It 'exits 2 at once, with the drain report on stderr' {
            $script:queuedRun.ExitCode | Should -Be 2
            $script:queuedRun.Output.Trim() | Should -BeNullOrEmpty
            $script:queuedRun.ErrorOutput | Should -Match '^Deputy wake:'
            $script:queuedRun.ErrorOutput | Should -Match '(?s)seq=1.*queued report 1.*seq=2.*queued report 2'
        }

        It 'ends the report with the exact ack command' {
            $expected = 'pwsh -NoProfile -File "{0}" ack -Through 2' -f (Join-Path $script:queued.Root 'bin' 'dep-wake.ps1')
            (Get-NonEmptyLines $script:queuedRun.ErrorOutput)[-1] | Should -Be $expected
        }

        It 'does not acknowledge anything by pushing it' {
            @(Get-Content (Join-Path $script:queued.State 'wake-queue.jsonl') | Where-Object { $_ }).Count | Should -Be 2
        }

        It 'does not push the same wake again on the next stop' {
            $again = Invoke-StopHook $script:queued
            $again.ExitCode | Should -Be 0
            $again.ErrorOutput.Trim() | Should -BeNullOrEmpty
        }

        It 'pushes it again after a StopFailure, since the turn that heard it may have died' {
            $retry = Invoke-StopHook $script:queued @{ hook_event_name = 'StopFailure' } @('-RetryCooldownSeconds', '0')
            $retry.ExitCode | Should -Be 2
            $retry.ErrorOutput | Should -Match 'Repeated: the turn that was told about these may have ended on an API error'
            (Get-Content (Join-Path $script:queued.State 'hook-stop.announced') -Raw | ConvertFrom-Json).retries | Should -Be 1
        }

        It 'stops repeating after the retry limit, so an API outage cannot become a storm' {
            $runs = @(1..3 | ForEach-Object {
                Invoke-StopHook $script:queued @{ hook_event_name = 'StopFailure' } @('-RetryCooldownSeconds', '0', '-MaxRetries', '2')
            })
            @($runs | ForEach-Object ExitCode) | Should -Be @(2, 0, 0)
        }

        It 'pushes a newer wake as soon as one arrives' {
            $row = [ordered]@{ seq = 3; at = (Get-Date -Format o); taskId = 'posse-20260101-110000-xyz'; event = 'failed'; kind = 'ship'; summary = 'a newer one' }
            Add-Content -Path (Join-Path $script:queued.State 'wake-queue.jsonl') -Value ($row | ConvertTo-Json -Compress) -Encoding utf8
            $run = Invoke-StopHook $script:queued
            $run.ExitCode | Should -Be 2
            $run.ErrorOutput | Should -Match 'a newer one'
            (Get-NonEmptyLines $run.ErrorOutput)[-1] | Should -Match 'ack -Through 3$'
        }
    }

    It 'leaves a healthy watcher that reports to this session alone' {
        $install = New-HookInstall -Tasks 1
        Set-FakeWatcher $install -Session 'session-test'
        $before = Get-Content (Join-Path $install.State 'watcher.lock') -Raw
        $run = Invoke-StopHook $install
        $run.ExitCode | Should -Be 0
        $run.ErrorOutput.Trim() | Should -BeNullOrEmpty
        Get-Content (Join-Path $install.State 'watcher.lock') -Raw | Should -Be $before
    }

    It 'leaves a watcher the Deputy started by hand alone' {
        $install = New-HookInstall -Tasks 1
        Set-FakeWatcher $install
        (Invoke-StopHook $install).ExitCode | Should -Be 0
    }

    It 'starts nothing when autoWatch is off' {
        $install = New-HookInstall -Tasks 1 -Wakes 1 -NoAutoWatch
        $run = Invoke-StopHook $install
        $run.ExitCode | Should -Be 0
        $run.ErrorOutput.Trim() | Should -BeNullOrEmpty
        Test-Path (Join-Path $install.State 'watcher.lock') | Should -BeFalse
        Test-Path (Join-Path $install.State 'hook-stop.announced') | Should -BeFalse
    }

    Context 'with a task running and nothing watching it' {
        BeforeAll {
            $script:parked = New-HookInstall -Tasks 1
            $script:parkedHook = Start-StopHook $script:parked -Session 'session-a'
            $script:parkedLock = Wait-WatcherLock $script:parked
        }

        It 'runs the watcher itself, for its own session' {
            $script:parkedLock | Should -Not -BeNullOrEmpty
            $script:parkedLock.session | Should -Be 'session-a'
            $script:parkedHook.Process.HasExited | Should -BeFalse
        }

        It 'satisfies the stop guard of that session' {
            $run = Invoke-Guard $script:parked @('-GraceSeconds', '0') @{ session_id = 'session-a' }
            $run.ExitCode | Should -Be 0
        }

        It 'exits 2 with the wake report when the task finishes' {
            Complete-TestTask $script:parked.Tasks[0] 'The member is done.'
            Wait-TestProcessExit $script:parkedHook.Process | Should -BeTrue
            $script:parkedHook.Process.ExitCode | Should -Be 2
            $report = Get-Content $script:parkedHook.ErrorFile -Raw
            $report | Should -Match '^Deputy wake:'
            $report | Should -Match '\[wake\] posse-20260101-120000-abc: completed \(scout\) seq=1'
            $report | Should -Match 'The member is done\.'
            (Get-NonEmptyLines $report)[-1] | Should -Match 'dep-wake\.ps1" ack -Through 1$'
            (Get-Content $script:parkedHook.OutFile -Raw) | Should -BeNullOrEmpty
        }

        It 'leaves no watcher lock behind' {
            Test-Path (Join-Path $script:parked.State 'watcher.lock') | Should -BeFalse
        }
    }

    It 'stands down quietly when another session takes its watcher over' {
        $install = New-HookInstall -Tasks 1
        $hook = Start-StopHook $install -Session 'session-a'
        $lock = Wait-WatcherLock $install
        $lock.session | Should -Be 'session-a'

        # Another session's stop hook asks for the watcher: session-a's is replaced.
        $takeover = Invoke-DeputyScript -InstallRoot $install.Root -Script 'dep-watch.ps1' -Arguments @('-Session', 'session-b')
        $takeover.Output | Should -Match 'took over from watcher'

        Wait-TestProcessExit $hook.Process | Should -BeTrue
        $hook.Process.ExitCode | Should -Be 0
        (Get-Content $hook.ErrorFile -Raw) | Should -BeNullOrEmpty
    }
}

Describe 'dep-session-start.ps1' {
    BeforeAll {
        $script:shims = New-ToolShims
        $script:savedPath = $env:PATH
        $env:PATH = "$script:shims;$env:PATH"
    }

    AfterAll {
        $env:PATH = $script:savedPath
    }

    Context 'in a Deputy home with a task running and a wake queued' {
        BeforeAll {
            $script:home1 = New-HookInstall -Tasks 1 -Wakes 1
            $script:startRun = Invoke-SessionStart $script:home1 @{ hook_event_name = 'SessionStart'; source = 'startup' }
        }

        It 'exits 0 and opens with a recognisable header' {
            $script:startRun.ExitCode | Should -Be 0
            (Get-NonEmptyLines $script:startRun.Output)[0] | Should -Be 'Deputy session start'
        }

        It 'prints the doctor lines, to be relayed verbatim' {
            # The throwaway install is not a git clone, which the doctor reports.
            $script:startRun.Output | Should -Match 'Toolchain problems \(dep-doctor\.ps1\)\. Relay every line to the Sheriff verbatim'
            $script:startRun.Output | Should -Match 'is not a git clone'
        }

        It 'prints the posse as dep-posse.ps1 status shows it' {
            $script:startRun.Output | Should -Match 'Posse \(dep-posse\.ps1 status\):'
            $script:startRun.Output | Should -Match 'posse-20260101-120000-abc\s+scout\s+running'
        }

        It 'says that nothing is watching the active task' {
            $script:startRun.Output | Should -Match 'Watcher: no watcher is running, and 1 task\(s\) are active'
        }

        It 'prints the drain, ending with the exact ack command' {
            $script:startRun.Output | Should -Match 'queued report 1'
            $expected = 'pwsh -NoProfile -File "{0}" ack -Through 1' -f (Join-Path $script:home1.Root 'bin' 'dep-wake.ps1')
            (Get-NonEmptyLines $script:startRun.Output)[-1] | Should -Be $expected
        }

        It 'acknowledges nothing' {
            @(Get-Content (Join-Path $script:home1.State 'wake-queue.jsonl') | Where-Object { $_ }).Count | Should -Be 1
        }

        It 'skips the doctor after a <Source>, but still reports the posse and the queue' -TestCases @(
            @{ Source = 'compact' }
            @{ Source = 'clear' }
        ) {
            $run = Invoke-SessionStart $script:home1 @{ hook_event_name = 'SessionStart'; source = $Source }
            $run.ExitCode | Should -Be 0
            $run.Output | Should -Not -Match 'Toolchain'
            $run.Output | Should -Match 'posse-20260101-120000-abc'
            $run.Output | Should -Match 'queued report 1'
        }
    }

    It 'reports a quiet home in a few lines' {
        $install = New-HookInstall
        $run = Invoke-SessionStart $install
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'Posse: no tasks\.'
        $run.Output | Should -Match 'Watcher: not running \(no active tasks\)\.'
        $run.Output | Should -Match 'wake queue: no unacknowledged wakes\.'
    }

    It 'still exits 0, and says what it could not read, when the state is broken' {
        $install = New-HookInstall -Wakes 1
        Set-Content (Join-Path $install.State 'posse-20260101-999999-bad.json') '{ this is not json'
        $run = Invoke-SessionStart $install
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'Posse: could not be read'
        $run.Output | Should -Match 'queued report 1'
    }

    It 'reports when run by hand in a fresh clone that has no state\ yet' {
        $install = New-HookInstall -NoState
        $run = Invoke-DeputyScript -InstallRoot $install.Root -Script 'dep-session-start.ps1'
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'Deputy session start'
        $run.Output | Should -Match 'Posse: no tasks\.'
    }
}

Describe 'The hooks in a posse worktree' {
    BeforeAll {
        # What each hook does in a real Deputy home with a task running, a
        # wake queued and nothing watching. Each of these is something a posse
        # member must never do.
        $script:hookCases = @(
            @{ Script = 'dep-session-start.ps1'; Arguments = @('-Hook'); HookInput = @{ hook_event_name = 'SessionStart'; source = 'compact' } }
            @{ Script = 'dep-hook-guard.ps1'; Arguments = @('-GraceSeconds', '0'); HookInput = @{ hook_event_name = 'Stop' } }
            @{ Script = 'dep-hook-stop.ps1'; Arguments = @(); HookInput = @{ hook_event_name = 'Stop' } }
            @{ Script = 'dep-hook-stop.ps1'; Arguments = @(); HookInput = @{ hook_event_name = 'StopFailure' } }
        )

        function Invoke-EveryHook($Install) {
            foreach ($case in $script:hookCases) {
                $run = Invoke-DeputyHook -InstallRoot $Install.Root -Script $case.Script -Arguments $case.Arguments -HookInput $case.HookInput
                [pscustomobject]@{
                    Name = "$($case.Script) ($($case.HookInput.hook_event_name))"; ExitCode = $run.ExitCode
                    Output = $run.Output.Trim(); ErrorOutput = $run.ErrorOutput.Trim()
                }
            }
        }

        function Assert-HooksDidNothing($Install) {
            $before = Get-StateSnapshot $Install
            foreach ($run in (Invoke-EveryHook $Install)) {
                $run.ExitCode | Should -Be 0 -Because "$($run.Name) must not act in a posse worktree"
                $run.Output | Should -BeNullOrEmpty -Because "$($run.Name) must print nothing in a posse worktree"
                $run.ErrorOutput | Should -BeNullOrEmpty -Because "$($run.Name) must print nothing in a posse worktree"
            }
            Get-StateSnapshot $Install | Should -Be $before -Because 'a hook must not write anything in a posse worktree'
        }
    }

    It 'acts in the Deputy home, so the cases below prove something' {
        $install = New-HookInstall -Tasks 1 -Wakes 1
        $runs = @(Invoke-EveryHook $install)
        $runs[0].Output | Should -Match 'Deputy session start'
        $runs[1].ExitCode | Should -Be 2
        $runs[2].ExitCode | Should -Be 2
    }

    It 'do nothing when the session was given a task briefing (DEPUTY_POSSE_TASK is set)' {
        $install = New-HookInstall -Tasks 1 -Wakes 1
        $env:DEPUTY_POSSE_TASK = 'posse-20260101-120000-abc'
        try { Assert-HooksDidNothing $install }
        finally { $env:DEPUTY_POSSE_TASK = $null }
    }

    It 'do nothing when the checkout is a linked git worktree, even one that grew a state\ of its own' {
        $install = New-HookInstall -Tasks 1 -Wakes 1
        # A linked worktree has a .git FILE pointing at the real repository.
        Set-Content (Join-Path $install.Root '.git') 'gitdir: C:/somewhere/else/.git/worktrees/1'
        Assert-HooksDidNothing $install
    }

    It 'do nothing, and do not create state\, when there is no state\ beside bin\' {
        $install = New-HookInstall -NoState
        Assert-HooksDidNothing $install
        Test-Path $install.State | Should -BeFalse
        Test-Path (Join-Path $install.Root 'logs') | Should -BeFalse
    }

    It 'treats a clone (a .git directory) with state\ as the Deputy home' {
        $install = New-HookInstall -Tasks 1
        New-Item -ItemType Directory -Force (Join-Path $install.Root '.git') | Out-Null
        (Invoke-Guard $install).ExitCode | Should -Be 2
    }

    It 'marks every member it starts, so the first case holds for real members' {
        # This pins the contract in the source: the marker is set around the
        # launch and restored afterwards. The launch is Start-MemberProcess in
        # dep-lib.ps1, shared by the two scripts that start a member - the
        # first run (dep-spawn.ps1) and a resumed one (dep-send.ps1) - so both
        # must go through it with their task id. dep-send.Tests.ps1 checks the
        # same thing on what a member process actually receives.
        $lib = Get-Content (Join-Path $script:sourceRoot 'bin' 'dep-lib.ps1') -Raw
        $lib | Should -Match '(?s)\$env:DEPUTY_POSSE_TASK = \$TaskId\s+try \{\s+\$started = \[Deputy\.MemberLauncher\]::Start\(.*?finally \{ \$env:DEPUTY_POSSE_TASK = \$previousMarker \}'
        $spawn = Get-Content (Join-Path $script:sourceRoot 'bin' 'dep-spawn.ps1') -Raw
        $spawn | Should -Match 'Start-MemberProcess -TaskId \$id\b'
        $send = Get-Content (Join-Path $script:sourceRoot 'bin' 'dep-send.ps1') -Raw
        $send | Should -Match 'Start-MemberProcess -TaskId \$Id\b'
        # Nothing starts a member any other way.
        foreach ($script in Get-ChildItem (Join-Path $script:sourceRoot 'bin') -Filter '*.ps1') {
            $text = Get-Content $script.FullName -Raw
            if ($script.Name -ne 'dep-lib.ps1') { $text | Should -Not -Match 'MemberLauncher' }
            $text | Should -Not -Match 'Start-Process[^\r\n]*claude'
        }
    }
}
