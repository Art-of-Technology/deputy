#Requires -Version 7.0
<#
.SYNOPSIS
Tests for the watcher singleton and heartbeat: dep-watch.ps1 run as a real
process against a throwaway Deputy install, plus Test-WatcherHealthy.

What these pin down: only one watcher scans at a time, a second one says so
and leaves; the lock of a watcher that is gone (or whose pid was recycled) is
reclaimed; a watcher that is alive but no longer polling is not mistaken for a
healthy one, and is replaced.
#>

BeforeAll {
    $script:sourceRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:root = New-TempRoot
    $script:n = 0
    $script:processes = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    # A posse member running this suite carries the marker; the watchers under
    # test must not inherit it.
    $script:savedMarker = $env:DEPUTY_POSSE_TASK
    $env:DEPUTY_POSSE_TASK = $null

    function New-LockInstall {
        # A throwaway install with one running task, so a waiting watcher has
        # something to wait for.
        $script:n++
        $install = New-DeputyInstall -Path (Join-Path $script:root "case$($script:n)" 'deputy') -SourceRoot $script:sourceRoot
        $task = New-TestRunningTask -InstallRoot $install
        $script:processes.Add($task.Member)
        [pscustomobject]@{ Root = $install; Task = $task; State = (Join-Path $install 'state') }
    }

    function Start-Watcher($Install, [string[]]$Arguments = @('-IntervalSeconds', '1')) {
        $watcher = Start-TestWatcher -InstallRoot $Install.Root -Arguments $Arguments
        $script:processes.Add($watcher.Process)
        $watcher
    }

    function Invoke-Watch($Install, [string[]]$Arguments = @()) {
        Invoke-DeputyScript -InstallRoot $Install.Root -Script 'dep-watch.ps1' -Arguments $Arguments
    }

    function Get-LockRecord($Install) {
        $path = Join-Path $Install.State 'watcher.lock'
        if (Test-Path $path) { Get-Content $path -Raw | ConvertFrom-Json } else { $null }
    }

    function Set-LockRecord($Install, [int]$ProcessId, [datetime]$StartedAt, [string]$Session = '') {
        ([ordered]@{ pid = $ProcessId; startedAt = $StartedAt.ToString('o'); session = $Session } | ConvertTo-Json -Compress) |
            Set-Content -Path (Join-Path $Install.State 'watcher.lock') -Encoding utf8
    }

    function Start-Sleeper {
        $proc = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 600')
        $script:processes.Add($proc)
        $proc
    }
}

AfterAll {
    foreach ($proc in $script:processes) {
        if (-not $proc.HasExited) { $proc.Kill() }
    }
    $env:DEPUTY_POSSE_TASK = $script:savedMarker
    if ($script:root) { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }
}

Describe 'dep-watch.ps1 -Wait as the one watcher' {
    BeforeAll {
        $script:one = New-LockInstall
        . (Join-Path $script:one.Root 'bin' 'dep-lib.ps1')
        $script:first = Start-Watcher $script:one
    }

    It 'holds state\watcher.lock with its pid and process start time' {
        $lock = Get-LockRecord $script:one
        $lock.pid | Should -Be $script:first.Process.Id
        Test-ProcessStartMatch $script:first.Process.StartTime $lock.startedAt | Should -BeTrue
    }

    It 'is healthy' {
        Test-WatcherHealthy | Should -BeTrue
    }

    It 'touches state\watcher.beat on every poll' {
        $beat = Join-Path $script:one.State 'watcher.beat'
        $before = (Get-Item $beat).LastWriteTimeUtc
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline -and (Get-Item $beat).LastWriteTimeUtc -le $before) { Start-Sleep -Milliseconds 200 }
        (Get-Item $beat).LastWriteTimeUtc | Should -BeGreaterThan $before
    }

    It 'makes a second watcher exit cleanly with a message, and keeps the lock' {
        $second = Invoke-Watch $script:one @('-Wait')
        $second.ExitCode | Should -Be 0
        $second.Output | Should -Match "a live watcher \(pid $($script:first.Process.Id)\) already holds the watcher lock"
        $second.Output | Should -Match 'dep-wake\.ps1" drain'
        $script:first.Process.HasExited | Should -BeFalse
        (Get-LockRecord $script:one).pid | Should -Be $script:first.Process.Id
    }

    It 'keeps a one-shot scan out as well, so a wake is never queued twice' {
        $scan = Invoke-Watch $script:one
        $scan.ExitCode | Should -Be 0
        $scan.Output | Should -Match 'already holds the watcher lock'
        $scan.Output | Should -Not -Match 'no new events'
    }

    It 'reports the wake with its sequence number, then releases the lock and the heartbeat' {
        Complete-TestTask $script:one.Task 'The member finished.'
        Wait-TestProcessExit $script:first.Process | Should -BeTrue
        $script:first.Process.ExitCode | Should -Be 0
        $output = Get-Content $script:first.OutFile -Raw
        $output | Should -Match '\[wake\] posse-20260101-120000-abc: completed \(scout\) seq=1'
        $output | Should -Match 'The member finished\.'
        $output | Should -Match 'Drain and acknowledge: .*dep-wake\.ps1" drain'
        Test-Path (Join-Path $script:one.State 'watcher.lock') | Should -BeFalse
        Test-Path (Join-Path $script:one.State 'watcher.beat') | Should -BeFalse
        Test-WatcherHealthy | Should -BeFalse
    }
}

Describe 'dep-watch.ps1 lock reclaim' {
    It 'reclaims the lock of a watcher that is gone' {
        $install = New-LockInstall
        $dead = Start-Sleeper
        $started = $dead.StartTime
        $dead.Kill(); $dead.WaitForExit()
        Set-LockRecord $install $dead.Id $started

        $watcher = Start-Watcher $install
        (Get-LockRecord $install).pid | Should -Be $watcher.Process.Id
        Complete-TestTask $install.Task
        Wait-TestProcessExit $watcher.Process | Should -BeTrue
        Get-Content $watcher.OutFile -Raw | Should -Match "reclaimed the lock: the watcher that held the lock \(pid $($dead.Id)\) is gone"
    }

    It 'reclaims a lock whose pid now belongs to a different process' {
        # Windows recycles pids: the pid is alive, but it started at another
        # time, so it is not the watcher that wrote the lock.
        $install = New-LockInstall
        $other = Start-Sleeper
        Set-LockRecord $install $other.Id $other.StartTime.AddHours(-1)

        $run = Invoke-Watch $install
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'reclaimed the lock'
        $run.Output | Should -Match 'no new events'
        $other.HasExited | Should -BeFalse
    }

    It 'treats a lock it cannot read as no lock' {
        $install = New-LockInstall
        Set-Content (Join-Path $install.State 'watcher.lock') 'not json at all'
        $run = Invoke-Watch $install
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'no new events'
        $run.Output | Should -Not -Match 'already holds'
    }

    It 'leaves no lock behind after a one-shot scan' {
        $install = New-LockInstall
        $null = Invoke-Watch $install
        Test-Path (Join-Path $install.State 'watcher.lock') | Should -BeFalse
    }

    It 'replaces a watcher that is alive but has stopped polling' {
        $install = New-LockInstall
        # Polls once, then sleeps for ten minutes: alive, and soon stale.
        $wedged = Start-Watcher $install @('-IntervalSeconds', '600')
        (Get-Item (Join-Path $install.State 'watcher.beat')).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-30)

        $run = Invoke-Watch $install
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match "took over from watcher pid $($wedged.Process.Id): .*has not polled for"
        $run.Output | Should -Match 'no new events'
        Wait-TestProcessExit $wedged.Process 10 | Should -BeTrue
    }

    It 'does not stop a live process that holds the lock but is not a watcher' {
        # Same pid and start time as the lock says, but not dep-watch.ps1:
        # nothing Deputy may kill. The lock stays with it.
        $install = New-LockInstall
        $impostor = Start-Sleeper
        Set-LockRecord $install $impostor.Id $impostor.StartTime
        Set-Content (Join-Path $install.State 'watcher.beat') 'old'
        (Get-Item (Join-Path $install.State 'watcher.beat')).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-30)

        $run = Invoke-Watch $install
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'could not be stopped'
        $run.Output | Should -Match 'Nothing is scanning the posse'
        $impostor.HasExited | Should -BeFalse
        (Get-LockRecord $install).pid | Should -Be $impostor.Id
    }
}

Describe 'dep-watch.ps1 run for a session by the stop hook' {
    It 'records the session in the lock' {
        $install = New-LockInstall
        $null = Start-Watcher $install @('-IntervalSeconds', '1', '-Session', 'session-a')
        (Get-LockRecord $install).session | Should -Be 'session-a'
    }

    It 'is replaced when another session asks, because its wake would reach nobody' {
        $install = New-LockInstall
        $orphan = Start-Watcher $install @('-IntervalSeconds', '1', '-Session', 'session-a')
        $run = Invoke-Watch $install @('-Session', 'session-b')
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match "took over from watcher pid $($orphan.Process.Id): it reports to another session \(session-a\)"
        Wait-TestProcessExit $orphan.Process 10 | Should -BeTrue
    }

    It 'is left alone when <Case> asks' -TestCases @(
        @{ Case = 'the same session'; Arguments = @('-Session', 'session-a') }
        @{ Case = 'nobody in particular'; Arguments = @() }
    ) {
        $install = New-LockInstall
        $watcher = Start-Watcher $install @('-IntervalSeconds', '1', '-Session', 'session-a')
        $run = Invoke-Watch $install $Arguments
        $run.Output | Should -Match 'already holds the watcher lock'
        $run.Output | Should -Match 'started by the stop hook of session session-a'
        $watcher.Process.HasExited | Should -BeFalse
    }

    It 'stops when the process that owns it is gone' {
        $install = New-LockInstall
        $owner = Start-Sleeper
        $watcher = Start-Watcher $install @('-IntervalSeconds', '1', '-OwnerPid', "$($owner.Id)")
        $owner.Kill(); $owner.WaitForExit()

        Wait-TestProcessExit $watcher.Process | Should -BeTrue
        $watcher.Process.ExitCode | Should -Be 0
        Get-Content $watcher.OutFile -Raw | Should -Match "owner process $($owner.Id) is gone"
        Test-Path (Join-Path $install.State 'watcher.lock') | Should -BeFalse
    }
}

Describe 'Test-WatcherHealthy' {
    BeforeAll {
        $script:health = New-LockInstall
        . (Join-Path $script:health.Root 'bin' 'dep-lib.ps1')
        $script:me = Get-Process -Id $PID
        $script:beat = Join-Path $script:health.State 'watcher.beat'
        $script:lock = Join-Path $script:health.State 'watcher.lock'
    }

    BeforeEach {
        Remove-Item $script:lock, $script:beat -Force -ErrorAction SilentlyContinue
    }

    It 'is false when there is no lock' {
        Test-WatcherHealthy | Should -BeFalse
        (Get-WatcherHealth).Reason | Should -Be 'no watcher is running'
    }

    It 'is false when the process in the lock is gone' {
        $dead = Start-Sleeper
        $started = $dead.StartTime
        $dead.Kill(); $dead.WaitForExit()
        Set-LockRecord $script:health $dead.Id $started
        Set-WatcherBeat
        Test-WatcherHealthy | Should -BeFalse
        (Get-WatcherHealth).Live | Should -BeFalse
    }

    It 'is false when the process is alive but never wrote a heartbeat' {
        Set-LockRecord $script:health $PID $script:me.StartTime
        Test-WatcherHealthy | Should -BeFalse
        (Get-WatcherHealth).Live | Should -BeTrue
    }

    It 'is false when the process is alive but its heartbeat is stale' {
        Set-LockRecord $script:health $PID $script:me.StartTime
        Set-WatcherBeat
        (Get-Item $script:beat).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(-(Get-WatcherStaleSeconds) - 5)
        Test-WatcherHealthy | Should -BeFalse
        (Get-WatcherHealth).Reason | Should -Match 'has not polled for'
    }

    It 'is true when the process is alive and its heartbeat is fresh' {
        Set-LockRecord $script:health $PID $script:me.StartTime
        Set-WatcherBeat
        (Get-Item $script:beat).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(-(Get-WatcherStaleSeconds) + 30)
        Test-WatcherHealthy | Should -BeTrue
    }

    It 'gives the heartbeat at least two minutes, and four poll intervals' {
        Get-WatcherStaleSeconds | Should -BeGreaterOrEqual 120
        Get-WatcherStaleSeconds | Should -BeGreaterOrEqual (4 * (Get-DeputyConfig).watchIntervalSeconds)
    }

    It 'serves <Asking> when the watcher was started for <Owner>: <Expected>' -TestCases @(
        @{ Owner = 'nobody'; Asking = 'a session'; OwnerId = ''; AskingId = 'session-a'; Expected = $true }
        @{ Owner = 'nobody'; Asking = 'nobody'; OwnerId = ''; AskingId = ''; Expected = $true }
        @{ Owner = 'the same session'; Asking = 'a session'; OwnerId = 'session-a'; AskingId = 'session-a'; Expected = $true }
        @{ Owner = 'another session'; Asking = 'a session'; OwnerId = 'session-b'; AskingId = 'session-a'; Expected = $false }
        @{ Owner = 'a session'; Asking = 'nobody'; OwnerId = 'session-b'; AskingId = ''; Expected = $true }
    ) {
        Set-LockRecord $script:health $PID $script:me.StartTime $OwnerId
        Set-WatcherBeat
        Test-WatcherServes (Get-WatcherHealth) $AskingId | Should -Be $Expected
    }

    It 'never serves anyone when it is not healthy' {
        Test-WatcherServes (Get-WatcherHealth) '' | Should -BeFalse
    }
}
