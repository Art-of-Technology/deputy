#Requires -Version 7.0
<#
.SYNOPSIS
Tests for the durable wake queue: sequence allocation (Add-WakeEvent), and the
drain and ack of dep-wake.ps1, run as real processes against a throwaway
Deputy install.

What these pin down: a wake is never lost and never acknowledged unseen. Its
sequence number only grows, survives a lost or corrupt counter, and an ack
removes exactly the wakes at or below the number it names.
#>

BeforeAll {
    $script:sourceRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:root = New-TempRoot
    $script:n = 0

    function New-QueueInstall {
        # A throwaway install with state\. Each test dot-sources the install's
        # own copy of the library, so Add-WakeEvent and friends act on it.
        $script:n++
        $install = New-DeputyInstall -Path (Join-Path $script:root "case$($script:n)" 'deputy') -SourceRoot $script:sourceRoot
        New-Item -ItemType Directory -Force (Join-Path $install 'state') | Out-Null
        $install
    }

    function Invoke-PrintedCommand([string]$Command) {
        # Run a command line exactly as the toolbelt printed it, the way the
        # Deputy would paste it into a shell.
        $file = Join-Path $script:root ('printed-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
        Set-Content -Path $file -Value $Command -Encoding utf8
        $out = & pwsh -NoProfile -File $file 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    }

    function New-TestWake([string]$Summary = 'done', [string]$Id = 'posse-20260101-120000-abc') {
        [pscustomobject]@{
            seq = 0; at = (Get-Date -Format o); taskId = $Id; event = 'completed'; kind = 'scout'
            repo = 'C:\nowhere'; prUrl = $null; prUrlRejected = $null; summary = $Summary
        }
    }

    function Get-QueueSeqs([string]$Install) {
        # The queued sequence numbers in file order, as '1,2,3' ('' when empty).
        $path = Join-Path $Install 'state' 'wake-queue.jsonl'
        if (-not (Test-Path $path)) { return '' }
        @(Get-Content $path | Where-Object { $_ } | ForEach-Object { [long]($_ | ConvertFrom-Json).seq }) -join ','
    }

    function Invoke-Wake([string]$Install, [string[]]$Arguments) {
        Invoke-DeputyScript -InstallRoot $Install -Script 'dep-wake.ps1' -Arguments $Arguments
    }

    function Get-LastLine([string]$Text) {
        @($Text -split "`r?`n" | Where-Object { $_.Trim() })[-1]
    }
}

AfterAll {
    if ($script:root) { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }
}

Describe 'Wake sequence allocation' {
    It 'numbers wakes 1, 2, 3 and records the last number in wake-queue.seq' {
        $install = New-QueueInstall
        . (Join-Path $install 'bin' 'dep-lib.ps1')
        $seqs = 1..3 | ForEach-Object { (Add-WakeEvent (New-TestWake "wake $_")).seq }
        ($seqs -join ',') | Should -Be '1,2,3'
        Get-QueueSeqs $install | Should -Be '1,2,3'
        (Get-Content (Join-Path $install 'state' 'wake-queue.seq') -Raw).Trim() | Should -Be '3'
    }

    It 'never reuses a number after the queue has been acknowledged empty' {
        $install = New-QueueInstall
        . (Join-Path $install 'bin' 'dep-lib.ps1')
        1..3 | ForEach-Object { $null = Add-WakeEvent (New-TestWake) }
        $null = Complete-Wakes 3
        Get-QueueSeqs $install | Should -Be ''
        (Add-WakeEvent (New-TestWake)).seq | Should -Be 4
    }

    It 'numbers past every queued row when the counter is <Case>' -TestCases @(
        @{ Case = 'missing'; Counter = $null }
        @{ Case = 'corrupt'; Counter = 'not a number' }
        @{ Case = 'behind the queue'; Counter = '2' }
        @{ Case = 'negative'; Counter = '-7' }
    ) {
        $install = New-QueueInstall
        . (Join-Path $install 'bin' 'dep-lib.ps1')
        1..5 | ForEach-Object { $null = Add-WakeEvent (New-TestWake) }
        $counter = Join-Path $install 'state' 'wake-queue.seq'
        if ($null -eq $Counter) { Remove-Item $counter } else { Set-Content $counter $Counter }
        (Add-WakeEvent (New-TestWake)).seq | Should -Be 6
        (Get-Content $counter -Raw).Trim() | Should -Be '6'
    }

    It 'keeps counting from the counter when it is ahead of the queue' {
        $install = New-QueueInstall
        . (Join-Path $install 'bin' 'dep-lib.ps1')
        Set-Content (Join-Path $install 'state' 'wake-queue.seq') '40'
        (Add-WakeEvent (New-TestWake)).seq | Should -Be 41
    }

    It 'hands out unique, gapless numbers to processes appending at the same time' {
        $install = New-QueueInstall
        . (Join-Path $install 'bin' 'dep-lib.ps1')
        $lib = Join-Path $install 'bin' 'dep-lib.ps1'
        $command = ". '$lib'; 1..10 | ForEach-Object { `$null = Add-WakeEvent ([pscustomobject]@{ seq = 0; at = (Get-Date -Format o); " +
            "taskId = 'posse-20260101-120000-abc'; event = 'completed'; kind = 'scout'; summary = 'x' }) }"
        # Encoded, because Start-Process does not quote its arguments.
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
        $writers = 1..4 | ForEach-Object {
            Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded)
        }
        $writers | ForEach-Object { $_.WaitForExit(120000) | Should -BeTrue }
        $seqs = @((Get-QueueSeqs $install) -split ',' | ForEach-Object { [int]$_ } | Sort-Object)
        ($seqs -join ',') | Should -Be ((1..40) -join ',')
    }

    It 'starts a fresh line after a torn one, so a killed writer costs one row and not two' {
        $install = New-QueueInstall
        . (Join-Path $install 'bin' 'dep-lib.ps1')
        $null = Add-WakeEvent (New-TestWake 'first')
        $queue = Join-Path $install 'state' 'wake-queue.jsonl'
        # A writer killed mid-append: half a row, no newline.
        [System.IO.File]::AppendAllText($queue, '{"seq":2,"taskId":"posse-20260101-120000-abc","event":"comp')
        (Add-WakeEvent (New-TestWake 'after the tear')).seq | Should -Be 2

        $run = Invoke-Wake $install @('drain')
        $run.Output | Should -Match 'retired 1 row\(s\)'
        $run.Output | Should -Match 'after the tear'
        Get-QueueSeqs $install | Should -Be '1,2'
    }
}

Describe 'dep-wake.ps1 drain' {
    BeforeAll {
        $script:drainInstall = New-QueueInstall
        . (Join-Path $script:drainInstall 'bin' 'dep-lib.ps1')
        $null = Add-WakeEvent (New-TestWake 'the first report')
        $null = Add-WakeEvent (New-TestWake 'the second report')
        $script:drainRun = Invoke-Wake $script:drainInstall @('drain')
    }

    It 'prints every unacknowledged wake, oldest first, with its sequence number' {
        $script:drainRun.ExitCode | Should -Be 0
        $script:drainRun.Output | Should -Match '(?s)seq=1.*the first report.*seq=2.*the second report'
        $script:drainRun.Output | Should -Match '2 unacknowledged wake\(s\)'
    }

    It 'ends with the exact ack command for the highest sequence printed' {
        $expected = 'pwsh -NoProfile -File "{0}" ack -Through 2' -f (Join-Path $script:drainInstall 'bin' 'dep-wake.ps1')
        Get-LastLine $script:drainRun.Output | Should -Be $expected
    }

    It 'changes nothing: an unacknowledged wake is printed again by the next drain' {
        $again = Invoke-Wake $script:drainInstall @('drain')
        $again.Output | Should -Be $script:drainRun.Output
        Get-QueueSeqs $script:drainInstall | Should -Be '1,2'
    }

    It 'empties the queue when the printed command is run as printed' {
        $ack = Invoke-PrintedCommand (Get-LastLine $script:drainRun.Output)
        $ack.ExitCode | Should -Be 0
        $ack.Output | Should -Match 'acknowledged 2 wake\(s\) through seq 2'
        Get-QueueSeqs $script:drainInstall | Should -Be ''
        (Invoke-Wake $script:drainInstall @('drain')).Output | Should -Match 'no unacknowledged wakes'
    }

    It 'says so when there is no queue at all' {
        $install = New-QueueInstall
        . (Join-Path $install 'bin' 'dep-lib.ps1')
        $run = Invoke-Wake $install @('drain')
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'no unacknowledged wakes'
    }

    It 'shows what the task of a queued wake looks like now' {
        $install = New-QueueInstall
        . (Join-Path $install 'bin' 'dep-lib.ps1')
        $null = New-TestTaskState -InstallRoot $install -Repo $install -Worktree $install -Branch 'deputy/x'
        $null = Add-WakeEvent (New-TestWake 'still here')
        $null = Add-WakeEvent (New-TestWake 'long gone' 'posse-20260101-120000-xyz')
        $output = (Invoke-Wake $install @('drain')).Output
        $output | Should -Match '(?s)seq=1\s+queued: .*task now: completed.*seq=2\s+queued: .*task now: unknown'
    }

    It 'retires rows written before the queue was sequenced, and reports them once' {
        $install = New-QueueInstall
        . (Join-Path $install 'bin' 'dep-lib.ps1')
        $queue = Join-Path $install 'state' 'wake-queue.jsonl'
        Set-Content $queue '{"at":"2026-01-01T12:00:00+00:00","taskId":"posse-20250101-120000-old","event":"completed","kind":"ship","summary":"from an older Deputy"}'
        $null = Add-WakeEvent (New-TestWake 'sequenced')

        $first = Invoke-Wake $install @('drain')
        $first.Output | Should -Match 'retired 1 row\(s\)'
        $first.Output | Should -Match 'posse-20250101-120000-old'
        $first.Output | Should -Match '1 unacknowledged wake\(s\)'
        Get-LastLine $first.Output | Should -Match 'ack -Through 1$'

        $second = Invoke-Wake $install @('drain')
        $second.Output | Should -Not -Match 'retired'
        $second.Output | Should -Match 'sequenced'
    }
}

Describe 'dep-wake.ps1 ack' {
    It 'removes the wakes at or below -Through and keeps the newer ones' {
        $install = New-QueueInstall
        . (Join-Path $install 'bin' 'dep-lib.ps1')
        1..5 | ForEach-Object { $null = Add-WakeEvent (New-TestWake "wake $_") }
        $run = Invoke-Wake $install @('ack', '-Through', '3')
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'acknowledged 3 wake\(s\) through seq 3'
        $run.Output | Should -Match '2 newer wake\(s\) are still unacknowledged'
        Get-QueueSeqs $install | Should -Be '4,5'
    }

    It 'leaves a wake that arrived after the drain for the next drain' {
        $install = New-QueueInstall
        . (Join-Path $install 'bin' 'dep-lib.ps1')
        $null = Add-WakeEvent (New-TestWake 'seen')
        $command = Get-LastLine (Invoke-Wake $install @('drain')).Output
        $null = Add-WakeEvent (New-TestWake 'arrived while handling')

        (Invoke-PrintedCommand $command).ExitCode | Should -Be 0
        Get-QueueSeqs $install | Should -Be '2'
        (Invoke-Wake $install @('drain')).Output | Should -Match 'arrived while handling'
    }

    It 'is a no-op the second time' {
        $install = New-QueueInstall
        . (Join-Path $install 'bin' 'dep-lib.ps1')
        1..2 | ForEach-Object { $null = Add-WakeEvent (New-TestWake) }
        $null = Invoke-Wake $install @('ack', '-Through', '1')
        $again = Invoke-Wake $install @('ack', '-Through', '1')
        $again.ExitCode | Should -Be 0
        $again.Output | Should -Match 'acknowledged 0 wake\(s\)'
        Get-QueueSeqs $install | Should -Be '2'
    }

    It 'refuses a sequence that was never handed out, and removes nothing' {
        $install = New-QueueInstall
        . (Join-Path $install 'bin' 'dep-lib.ps1')
        1..2 | ForEach-Object { $null = Add-WakeEvent (New-TestWake) }
        $run = Invoke-Wake $install @('ack', '-Through', '3')
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match 'highest wake sequence handed out is 2'
        Get-QueueSeqs $install | Should -Be '1,2'
    }

    It 'refuses to run without -Through' {
        $install = New-QueueInstall
        . (Join-Path $install 'bin' 'dep-lib.ps1')
        $null = Add-WakeEvent (New-TestWake)
        $run = Invoke-Wake $install @('ack')
        $run.ExitCode | Should -Not -Be 0
        Get-QueueSeqs $install | Should -Be '1'
    }

    It 'waits for the state lock, then rewrites the queue in one step' {
        $install = New-QueueInstall
        . (Join-Path $install 'bin' 'dep-lib.ps1')
        1..3 | ForEach-Object { $null = Add-WakeEvent (New-TestWake) }
        $out = Join-Path $install 'ack.out'
        $held = [System.IO.File]::Open((Join-Path $install 'state' 'state.lock'), [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $ack = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden -RedirectStandardOutput $out `
                -ArgumentList @('-NoProfile', '-File', ('"{0}"' -f (Join-Path $install 'bin' 'dep-wake.ps1')), 'ack', '-Through', '2')
            # While another process holds the lock the ack must not have touched the queue.
            $ack.WaitForExit(3000) | Should -BeFalse
            Get-QueueSeqs $install | Should -Be '1,2,3'
        }
        finally { $held.Dispose() }
        $ack.WaitForExit(30000) | Should -BeTrue
        $ack.ExitCode | Should -Be 0
        Get-QueueSeqs $install | Should -Be '3'
        Test-Path (Join-Path $install 'state' 'wake-queue.jsonl.tmp') | Should -BeFalse
    }
}
