#Requires -Version 7.0
<#
.SYNOPSIS
End-to-end tests for the watcher's completion contract: dep-watch.ps1 run as a
real process against a throwaway Deputy install, a fake stream-json log and a
real member process.

The regression these pin down: a member that started background helpers
emitted a `result` event mid-session, and the watcher woke the Deputy with
`completed` while the member was still alive and still writing its report.
A task is completed only when its final result has arrived AND the member
process has exited.
#>

BeforeAll {
    $script:sourceRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:root = New-TempRoot
    $script:n = 0
    $script:members = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()

    function Start-FakeMember {
        # A real, long-lived process standing in for the headless member.
        $proc = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 600')
        $script:members.Add($proc)
        $proc
    }

    function Stop-FakeMember($Process) {
        if (-not $Process.HasExited) { $Process.Kill() }
        $Process.WaitForExit()
    }

    function New-StreamEvent {
        # One stream-json line, shaped like the headless member's output.
        param(
            [Parameter(Mandatory)][ValidateSet('init', 'assistant', 'user', 'result')][string]$Type,
            [string]$Text = '',
            [switch]$IsError
        )
        $streamEvent = switch ($Type) {
            'init' { [ordered]@{ type = 'system'; subtype = 'init'; session_id = 'test' } }
            'assistant' {
                [ordered]@{
                    type    = 'assistant'
                    message = [ordered]@{ role = 'assistant'; content = @([ordered]@{ type = 'text'; text = $Text }) }
                }
            }
            'user' {
                [ordered]@{
                    type    = 'user'
                    message = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; content = $Text }) }
                }
            }
            'result' {
                [ordered]@{
                    type     = 'result'
                    subtype  = ($IsError ? 'error_during_execution' : 'success')
                    is_error = [bool]$IsError
                    result   = $Text
                }
            }
        }
        $streamEvent | ConvertTo-Json -Compress -Depth 8
    }

    function Add-StreamEvent([string]$LogPath, [string[]]$Lines) {
        Add-Content -Path $LogPath -Value $Lines -Encoding utf8
    }

    function New-WatchScenario {
        <#
        .SYNOPSIS
        A running scout task in a throwaway install: registered state, a
        stream-json log, and a member process (live unless -Exited).
        #>
        param(
            [string[]]$Lines = @(),
            [switch]$Exited,
            # Pretend the log has been silent this long (and fully seen).
            [int]$IdleMinutes = 0
        )
        $script:n++
        $dir = Join-Path $script:root "case$($script:n)"
        $install = New-DeputyInstall -Path (Join-Path $dir 'deputy') -SourceRoot $script:sourceRoot
        $stateDir = Join-Path $install 'state'
        $logDir = Join-Path $install 'logs'
        New-Item -ItemType Directory -Force $stateDir, $logDir | Out-Null

        $id = 'posse-20260101-120000-abc'
        $log = Join-Path $logDir "$id.jsonl"
        Set-Content -Path $log -Value $Lines -Encoding utf8

        $member = Start-FakeMember
        $startedAt = $member.StartTime.ToString('o')
        if ($Exited) { Stop-FakeMember $member }

        $state = [ordered]@{
            id             = $id
            kind           = 'scout'
            task           = 'test task'
            repo           = $dir
            # No such directory: liveness is judged by the pid alone, so the
            # tests never need treehouse.
            worktree       = Join-Path $dir 'no-such-worktree'
            pid            = $member.Id
            pidStartedAt   = $startedAt
            status         = 'running'
            spawnedAt      = '2026-01-01T12:00:00.0000000+00:00'
            stdoutLog      = $log
            stderrLog      = Join-Path $logDir "$id.err.log"
            lastLogBytes   = ($IdleMinutes -gt 0 ? (Get-Item $log).Length : 0)
            lastActivityAt = (Get-Date).AddMinutes(-$IdleMinutes).ToString('o')
            stallNotified  = $false
            prUrl          = $null
            result         = $null
        }
        ($state | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $stateDir "$id.json") -Encoding utf8

        [pscustomobject]@{ Install = $install; Id = $id; Log = $log; Member = $member }
    }

    function Invoke-Watch($Scenario, [string[]]$Arguments = @()) {
        Invoke-DeputyScript -InstallRoot $Scenario.Install -Script 'dep-watch.ps1' -Arguments $Arguments
    }

    function Get-WakeQueue($Scenario) {
        $path = Join-Path $Scenario.Install 'state' 'wake-queue.jsonl'
        if (-not (Test-Path $path)) { return , @() }
        , @(Get-Content $path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }

    $script:interimText = 'Not finished yet: helper agents are still running and the report is a placeholder.'
    $script:finalText = 'Scout finished. The full report has been written.'
}

AfterAll {
    foreach ($member in $script:members) {
        if (-not $member.HasExited) { $member.Kill() }
    }
    if ($script:root) { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }
}

Describe 'dep-watch.ps1 with an interim result and a live member' {
    BeforeAll {
        $script:live = New-WatchScenario -Lines @(
            (New-StreamEvent init),
            (New-StreamEvent assistant 'Starting helper agents in the background.'),
            (New-StreamEvent result $script:interimText)
        )
        $script:liveRun = Invoke-Watch $script:live
    }

    It 'emits no wake while the member process is alive' {
        $script:liveRun.ExitCode | Should -Be 0
        $script:liveRun.Output | Should -Not -Match '\[wake\]'
        $script:liveRun.Output | Should -Match 'no new events'
        (Get-WakeQueue $script:live).Count | Should -Be 0
    }

    It 'leaves the task running and records no result' {
        $state = Get-TestTaskState -InstallRoot $script:live.Install -Id $script:live.Id
        $state.status | Should -Be 'running'
        $state.result | Should -BeNullOrEmpty
    }

    Context 'once the member carries on and emits its final result' {
        BeforeAll {
            Add-StreamEvent $script:live.Log @(
                (New-StreamEvent user 'helper agent finished'),
                (New-StreamEvent assistant 'Helpers are done. Writing the full report.'),
                (New-StreamEvent result $script:finalText)
            )
            $script:stillAliveRun = Invoke-Watch $script:live
            $script:stillAliveStatus = (Get-TestTaskState -InstallRoot $script:live.Install -Id $script:live.Id).status

            Stop-FakeMember $script:live.Member
            $script:exitedRun = Invoke-Watch $script:live
            $script:repeatRun = Invoke-Watch $script:live
        }

        It 'still emits no wake until the process has exited' {
            $script:stillAliveRun.Output | Should -Not -Match '\[wake\]'
            $script:stillAliveStatus | Should -Be 'running'
        }

        It 'emits exactly one completed wake after the process exits' {
            $script:exitedRun.Output | Should -Match '\[wake\] posse-20260101-120000-abc: completed \(scout\)'
            $script:repeatRun.Output | Should -Not -Match '\[wake\]'
            $wakes = Get-WakeQueue $script:live
            $wakes.Count | Should -Be 1
            $wakes[0].event | Should -Be 'completed'
        }

        It 'carries the last result, not the interim one' {
            $wake = (Get-WakeQueue $script:live)[0]
            $wake.summary | Should -Be $script:finalText
            $script:exitedRun.Output | Should -Not -Match 'Not finished yet'
            $state = Get-TestTaskState -InstallRoot $script:live.Install -Id $script:live.Id
            $state.status | Should -Be 'completed'
            $state.result | Should -Be $script:finalText
        }
    }
}

Describe 'dep-watch.ps1 with a final result after the member exited' {
    It 'completes on the first scan with the last result when earlier results exist' {
        $scenario = New-WatchScenario -Exited -Lines @(
            (New-StreamEvent init),
            (New-StreamEvent result $script:interimText),
            (New-StreamEvent assistant 'Carrying on.'),
            (New-StreamEvent user 'tool output'),
            (New-StreamEvent assistant 'More work.'),
            (New-StreamEvent user 'tool output'),
            (New-StreamEvent assistant 'Wrapping up.'),
            (New-StreamEvent result $script:finalText)
        )
        $run = Invoke-Watch $scenario
        $run.Output | Should -Match ': completed \(scout\)'
        $wakes = Get-WakeQueue $scenario
        $wakes.Count | Should -Be 1
        $wakes[0].summary | Should -Be $script:finalText
        (Get-TestTaskState -InstallRoot $scenario.Install -Id $scenario.Id).result | Should -Be $script:finalText
    }

    It 'reports failed when the final result is an error' {
        $scenario = New-WatchScenario -Exited -Lines @(
            (New-StreamEvent init),
            (New-StreamEvent result -IsError 'The session blew up.')
        )
        $run = Invoke-Watch $scenario
        $run.Output | Should -Match ': failed \(scout\)'
        (Get-TestTaskState -InstallRoot $scenario.Install -Id $scenario.Id).status | Should -Be 'failed'
    }

    It 'ignores a final result line that is still being written' {
        $scenario = New-WatchScenario -Exited -Lines @(
            (New-StreamEvent init),
            (New-StreamEvent assistant 'Working.'),
            '{"type":"result","subtype":"success","is_error":false,"result":"Scout fin'
        )
        $run = Invoke-Watch $scenario
        $run.Output | Should -Not -Match '\[wake\]'
        (Get-TestTaskState -InstallRoot $scenario.Install -Id $scenario.Id).status | Should -Be 'running'
    }
}

Describe 'dep-watch.ps1 with a member that dies after only an interim result' {
    BeforeAll {
        $script:dead = New-WatchScenario -Exited -Lines @(
            (New-StreamEvent init),
            (New-StreamEvent result $script:interimText),
            (New-StreamEvent assistant 'Helpers are done. Writing the full report.')
        )
        $script:graceRun = Invoke-Watch $script:dead
        $script:deadRun = Invoke-Watch $script:dead @('-DeadSeconds', '0')
    }

    It 'does not complete the task on the interim result' {
        $script:graceRun.Output | Should -Not -Match '\[wake\]'
    }

    It 'emits a died wake, not completed, once the log has been silent past the grace' {
        $script:deadRun.Output | Should -Match ': died \(scout\)'
        $wakes = Get-WakeQueue $script:dead
        $wakes.Count | Should -Be 1
        $wakes[0].event | Should -Be 'died'
        (Get-TestTaskState -InstallRoot $script:dead.Install -Id $script:dead.Id).status | Should -Be 'died'
    }

    It 'says the only result was interim and quotes it' {
        $wake = (Get-WakeQueue $script:dead)[0]
        $wake.summary | Should -Match 'interim result'
        $wake.summary | Should -Match 'Not finished yet'
    }
}

Describe 'dep-watch.ps1 with a member that never exits after its final result' {
    BeforeAll {
        $script:hung = New-WatchScenario -IdleMinutes 60 -Lines @(
            (New-StreamEvent init),
            (New-StreamEvent result $script:finalText)
        )
        $script:hungRun = Invoke-Watch $script:hung
        Stop-FakeMember $script:hung.Member
        $script:hungExitRun = Invoke-Watch $script:hung
    }

    It 'falls through to a stalled wake that says a result is waiting on process exit' {
        $script:hungRun.Output | Should -Match ': stalled \(scout\)'
        $script:hungRun.Output | Should -Match 'result event is present'
        $script:hungRun.Output | Should -Not -Match ': completed'
    }

    It 'completes once the process does exit' {
        $script:hungExitRun.Output | Should -Match ': completed \(scout\)'
        $wakes = Get-WakeQueue $script:hung
        @($wakes | ForEach-Object event) | Should -Be @('stalled', 'completed')
        $wakes[1].summary | Should -Be $script:finalText
    }
}
