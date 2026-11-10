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

Further down: what the final result MEANS. A transient API failure is
`interrupted`, a structured final report maps by its status (`blocked` and
`needs-decision` are wakes of their own), and after dep-send.ps1 resumed a
member only the current run's result counts.
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

    function New-ResultEvent {
        # A result event with exactly these fields on top of the basics, for
        # the shapes New-StreamEvent does not cover: API errors, structured
        # reports, usage.
        param([hashtable]$Fields = @{})
        $resultEvent = [ordered]@{ type = 'result'; subtype = 'success'; is_error = $false; result = '' }
        foreach ($key in $Fields.Keys) { $resultEvent[$key] = $Fields[$key] }
        $resultEvent | ConvertTo-Json -Compress -Depth 8
    }

    function New-ReportEvent {
        # The result event of a member that ended with a structured report.
        param([hashtable]$Report, [hashtable]$Fields = @{})
        $all = @{ result = ($Report | ConvertTo-Json -Compress); structured_output = $Report }
        foreach ($key in $Fields.Keys) { $all[$key] = $Fields[$key] }
        New-ResultEvent $all
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
            [int]$IdleMinutes = 0,
            # Make the task's repo a git repo whose origin is this URL.
            [string]$Origin,
            # Extra or overriding fields of the task record.
            [hashtable]$Extra = @{}
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
        foreach ($key in $Extra.Keys) { $state[$key] = $Extra[$key] }
        ($state | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $stateDir "$id.json") -Encoding utf8

        if ($Origin) {
            Invoke-Git @('init', '-q', $dir)
            Invoke-Git @('-C', $dir, 'remote', 'add', 'origin', $Origin)
        }

        [pscustomobject]@{ Install = $install; Id = $id; Log = $log; Member = $member }
    }

    function Invoke-FinishedWatch {
        # Scan a task whose member has exited with these log lines; return the
        # run, the task record and the one wake it queued (or $null).
        param([string[]]$Lines, [string]$Origin, [hashtable]$Extra = @{}, [string[]]$Arguments = @())
        $scenario = New-WatchScenario -Exited -Lines $Lines -Origin $Origin -Extra $Extra
        $run = Invoke-Watch $scenario $Arguments
        $wakes = Get-WakeQueue $scenario
        [pscustomobject]@{
            Run   = $run
            State = Get-TestTaskState -InstallRoot $scenario.Install -Id $scenario.Id
            Wake  = if ($wakes.Count -gt 0) { $wakes[0] } else { $null }
            Wakes = $wakes
        }
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

Describe 'dep-watch.ps1 with a result that is a transient API failure' {
    It 'wakes with interrupted, not failed, for api_error_status <Status>' -ForEach @(
        @{ Status = 429 }, @{ Status = 500 }, @{ Status = 502 }, @{ Status = 503 }, @{ Status = 529 }
    ) {
        $watched = Invoke-FinishedWatch -Lines @(
            (New-StreamEvent init),
            (New-ResultEvent @{ is_error = $true; api_error_status = $Status; result = "API Error: $Status upstream trouble" })
        )
        $watched.Run.Output | Should -Match ': interrupted \(scout\)'
        $watched.Wake.event | Should -Be 'interrupted'
        $watched.State.status | Should -Be 'interrupted'
    }

    It 'reads the real shape of an overloaded API: success subtype, is_error, status 529' {
        # Captured from claude 2.1.322 against an endpoint answering 529.
        $watched = Invoke-FinishedWatch -Lines @(
            (New-StreamEvent init),
            ('{"type":"result","subtype":"success","is_error":true,"api_error_status":529,"num_turns":1,' +
            '"total_cost_usd":0,"duration_ms":184897,"terminal_reason":"api_error","result":"API Error: 529 ' +
            'Overloaded. This is a server-side issue, usually temporary - try again in a moment."}')
        )
        $watched.Wake.event | Should -Be 'interrupted'
        $watched.Wake.summary | Should -Match 'API Error: 529 Overloaded'
    }

    It 'recognises <Name> from the text when there is no status field' -ForEach @(
        @{ Name = 'an overloaded error'; Text = '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}' }
        @{ Name = 'an API error 503'; Text = 'API Error: 503 Service Unavailable' }
        @{ Name = 'an API error (429 ...)'; Text = 'API Error (429 {"type":"rate_limit_error"})' }
    ) {
        $watched = Invoke-FinishedWatch -Lines @(
            (New-StreamEvent init),
            (New-StreamEvent result -IsError $Text)
        )
        $watched.Wake.event | Should -Be 'interrupted'
    }

    It 'says how to continue the member, and that no follow-up was sent yet' {
        $watched = Invoke-FinishedWatch -Lines @(
            (New-StreamEvent init),
            (New-ResultEvent @{ is_error = $true; api_error_status = 529; result = 'API Error: 529 Overloaded.' })
        )
        $watched.Wake.followUps | Should -Be 0
        $watched.Run.Output | Should -Match 'follow-ups sent so far: 0\.'
        $watched.Run.Output | Should -Match 'dep-send\.ps1" posse-20260101-120000-abc -Message'
    }

    It 'keeps <Name> as failed' -ForEach @(
        @{ Name = 'a client error (400)'; Fields = @{ is_error = $true; api_error_status = 400; result = 'API Error: 400 invalid request' } }
        @{ Name = 'an authentication error (401)'; Fields = @{ is_error = $true; api_error_status = 401; result = 'API Error: 401 unauthorized' } }
        @{ Name = 'a 404 that mentions an overloaded queue'; Fields = @{ is_error = $true; api_error_status = 404; result = 'API Error: 404 model not found (the overloaded one was retired)' } }
        @{ Name = 'an error whose text happens to hold the number 500'; Fields = @{ is_error = $true; result = 'The script processed 500 rows and then crashed.' } }
    ) {
        $watched = Invoke-FinishedWatch -Lines @((New-StreamEvent init), (New-ResultEvent $Fields))
        $watched.Wake.event | Should -Be 'failed'
        $watched.State.status | Should -Be 'failed'
    }

    It 'reports an error result that has no text by its errors: an exhausted budget is failed' {
        # Captured from claude 2.1.322 with --max-budget-usd.
        $watched = Invoke-FinishedWatch -Lines @(
            (New-StreamEvent init),
            ('{"type":"result","subtype":"error_max_budget_usd","is_error":true,"api_error_status":null,' +
            '"result":null,"errors":["Reached maximum budget ($0.0001)"],"num_turns":1,"total_cost_usd":0.0147}')
        )
        $watched.Wake.event | Should -Be 'failed'
        $watched.Wake.summary | Should -Be 'Reached maximum budget ($0.0001)'
        $watched.State.result | Should -Be 'Reached maximum budget ($0.0001)'
    }

    It 'names the subtype when an error result says nothing at all' {
        $watched = Invoke-FinishedWatch -Lines @(
            (New-StreamEvent init),
            (New-ResultEvent @{ subtype = 'error_max_turns'; is_error = $true; result = $null })
        )
        $watched.Wake.event | Should -Be 'failed'
        $watched.Wake.summary | Should -Match 'error_max_turns'
    }
}

Describe 'dep-watch.ps1 with a structured final report' {
    It 'completes on status done, with the summary and tests as the result' {
        $watched = Invoke-FinishedWatch -Lines @(
            (New-StreamEvent init),
            (New-ReportEvent @{ status = 'done'; summary = 'Fixed the flaky test.'; tests = 'npm test: 42 passed' })
        )
        $watched.Run.Output | Should -Match ': completed \(scout\)'
        $watched.Wake.event | Should -Be 'completed'
        $watched.Wake.summary | Should -Be 'Fixed the flaky test. Tests: npm test: 42 passed'
        $watched.Wake.question | Should -BeNullOrEmpty
        $watched.State.status | Should -Be 'completed'
        $watched.State.result | Should -Be "Fixed the flaky test.`n`nTests: npm test: 42 passed"
        $watched.State.report.status | Should -Be 'done'
        $watched.State.report.tests | Should -Be 'npm test: 42 passed'
        # Not a wake that is answered with dep-send.ps1
        $watched.Run.Output | Should -Not -Match 'follow-ups sent so far'
    }

    It 'wakes with <Status> and carries the question' -ForEach @(
        @{ Status = 'blocked'; Question = 'The staging database is unreachable. Can you restart it?' }
        @{ Status = 'needs-decision'; Question = 'Keep the v1 endpoint or remove it? I recommend keeping it.' }
    ) {
        $watched = Invoke-FinishedWatch -Lines @(
            (New-StreamEvent init),
            (New-ReportEvent @{ status = $Status; summary = 'Stopped half way.'; question = $Question })
        )
        $watched.Run.Output | Should -Match ": $Status \(scout\)"
        $watched.Run.Output | Should -Match ('question: ' + [regex]::Escape($Question))
        $watched.Run.Output | Should -Match 'follow-ups sent so far: 0\. Answer in the same session with: .*dep-send\.ps1'
        $watched.Wake.event | Should -Be $Status
        $watched.Wake.question | Should -Be $Question
        # The question has a line of its own, so the summary does not repeat it
        $watched.Wake.summary | Should -Be 'Stopped half way.'
        $watched.State.status | Should -Be $Status
        $watched.State.report.question | Should -Be $Question
        $watched.State.result | Should -Be "Stopped half way.`n`nQuestion: $Question"
    }

    It 'leaves a blocked task out of the tasks a watcher still watches' {
        $scenario = New-WatchScenario -Exited -Lines @(
            (New-StreamEvent init),
            (New-ReportEvent @{ status = 'blocked'; summary = 'Stuck.'; question = 'Which way?' })
        )
        $null = Invoke-Watch $scenario
        $again = Invoke-Watch $scenario
        $again.Output | Should -Not -Match '\[wake\]'
        (Get-WakeQueue $scenario).Count | Should -Be 1
    }

    It 'fails on status failed' {
        $watched = Invoke-FinishedWatch -Lines @(
            (New-StreamEvent init),
            (New-ReportEvent @{ status = 'failed'; summary = 'The migration cannot be written without the schema.' })
        )
        $watched.Wake.event | Should -Be 'failed'
        $watched.State.status | Should -Be 'failed'
        $watched.State.report.status | Should -Be 'failed'
    }

    It 'lets an error result win over a structured report' {
        $watched = Invoke-FinishedWatch -Lines @(
            (New-StreamEvent init),
            (New-ReportEvent @{ status = 'done'; summary = 'All good.' } @{ is_error = $true; api_error_status = 529 })
        )
        $watched.Wake.event | Should -Be 'interrupted'
        $watched.State.report | Should -BeNullOrEmpty
    }

    It 'falls back to the text when <Name>' -ForEach @(
        @{ Name = 'there is no structured output'; Fields = @{ result = 'Plain text report.' } }
        @{ Name = 'the structured output is null'; Fields = @{ result = 'Plain text report.'; structured_output = $null } }
        @{ Name = 'the status is not one of the four'; Fields = @{ result = 'Plain text report.'; structured_output = @{ status = 'finished'; summary = 'x' } } }
        @{ Name = 'the structured output is not an object'; Fields = @{ result = 'Plain text report.'; structured_output = 'done' } }
    ) {
        $watched = Invoke-FinishedWatch -Lines @((New-StreamEvent init), (New-ResultEvent $Fields))
        $watched.Wake.event | Should -Be 'completed'
        $watched.Wake.summary | Should -Be 'Plain text report.'
        $watched.State.result | Should -Be 'Plain text report.'
        $watched.State.report | Should -BeNullOrEmpty
    }

    Context 'the pull request URL' {
        It 'trusts the prUrl field when it points at the task''s own repo' {
            $watched = Invoke-FinishedWatch -Origin 'https://github.com/acme/widgets.git' -Lines @(
                (New-StreamEvent init),
                (New-ReportEvent @{ status = 'done'; summary = 'Opened the PR.'; prUrl = 'https://github.com/acme/widgets/pull/7' })
            )
            $watched.State.prUrl | Should -Be 'https://github.com/acme/widgets/pull/7'
            $watched.Wake.prUrl | Should -Be 'https://github.com/acme/widgets/pull/7'
            $watched.Wake.prUrlRejected | Should -BeNullOrEmpty
        }

        It 'rejects a prUrl field that points at another repo' {
            $watched = Invoke-FinishedWatch -Origin 'https://github.com/acme/widgets.git' -Lines @(
                (New-StreamEvent init),
                (New-ReportEvent @{ status = 'done'; summary = 'Opened the PR.'; prUrl = 'https://github.com/evil/widgets/pull/7' })
            )
            $watched.State.prUrl | Should -BeNullOrEmpty
            $watched.State.prUrlRejected | Should -Be 'https://github.com/evil/widgets/pull/7'
            $watched.Run.Output | Should -Match 'pr REJECTED'
        }

        It 'rejects a prUrl field that is not a pull request URL' {
            $watched = Invoke-FinishedWatch -Origin 'https://github.com/acme/widgets.git' -Lines @(
                (New-StreamEvent init),
                (New-ReportEvent @{ status = 'done'; summary = 'Opened the PR.'; prUrl = 'see the branch on the server' })
            )
            $watched.State.prUrl | Should -BeNullOrEmpty
            $watched.State.prUrlRejected | Should -Be 'see the branch on the server'
        }

        It 'does not go looking in the summary when the report has no prUrl field' {
            # With a structured report the URL has a field of its own; a URL
            # mentioned in prose is a reference, not the task's PR.
            $watched = Invoke-FinishedWatch -Origin 'https://github.com/acme/widgets.git' -Lines @(
                (New-StreamEvent init),
                (New-ReportEvent @{ status = 'done'; summary = 'Same fix as https://github.com/acme/widgets/pull/3.' })
            )
            $watched.State.prUrl | Should -BeNullOrEmpty
            $watched.State.prUrlRejected | Should -BeNullOrEmpty
        }

        It 'still finds the URL in a plain text result, and still checks the repo' {
            $own = Invoke-FinishedWatch -Origin 'git@github.com:acme/widgets.git' -Lines @(
                (New-StreamEvent init),
                (New-StreamEvent result 'Done. PR: https://github.com/Acme/Widgets/pull/9')
            )
            $own.State.prUrl | Should -Be 'https://github.com/Acme/Widgets/pull/9'

            $foreign = Invoke-FinishedWatch -Origin 'git@github.com:acme/widgets.git' -Lines @(
                (New-StreamEvent init),
                (New-StreamEvent result 'Done. PR: https://github.com/evil/widgets/pull/9')
            )
            $foreign.State.prUrl | Should -BeNullOrEmpty
            $foreign.State.prUrlRejected | Should -Be 'https://github.com/evil/widgets/pull/9'
        }
    }
}

Describe 'dep-watch.ps1 recording what a run cost' {
    It 'persists total_cost_usd, num_turns and duration_ms from the final result' {
        $watched = Invoke-FinishedWatch -Lines @(
            (New-StreamEvent init),
            (New-ResultEvent @{ result = 'Done.'; total_cost_usd = 1.2345; num_turns = 12; duration_ms = 61000 })
        )
        $watched.State.totalCostUsd | Should -Be 1.2345
        $watched.State.numTurns | Should -Be 12
        $watched.State.durationMs | Should -Be 61000
    }

    It 'records them for an interrupted run too' {
        $watched = Invoke-FinishedWatch -Lines @(
            (New-StreamEvent init),
            (New-ResultEvent @{ is_error = $true; api_error_status = 529; result = 'API Error: 529'; total_cost_usd = 0.5; num_turns = 3; duration_ms = 1000 })
        )
        $watched.State.totalCostUsd | Should -Be 0.5
        $watched.State.numTurns | Should -Be 3
    }

    It 'takes the session total for cost and adds up turns and duration after a follow-up' {
        # A resumed run reports the cost of the whole session so far, but only
        # its own turns and duration (observed on claude 2.1.322).
        $watched = Invoke-FinishedWatch -Extra @{ totalCostUsd = 2.0; numTurns = 10; durationMs = 5000 } -Lines @(
            (New-StreamEvent init),
            (New-ResultEvent @{ result = 'Done.'; total_cost_usd = 2.75; num_turns = 4; duration_ms = 3000 })
        )
        $watched.State.totalCostUsd | Should -Be 2.75
        $watched.State.numTurns | Should -Be 14
        $watched.State.durationMs | Should -Be 8000
    }

    It 'never lowers the recorded cost' {
        # A run cut off before its first request reports a cost of 0.
        $watched = Invoke-FinishedWatch -Extra @{ totalCostUsd = 2.0 } -Lines @(
            (New-StreamEvent init),
            (New-ResultEvent @{ is_error = $true; api_error_status = 529; result = 'API Error: 529'; total_cost_usd = 0 })
        )
        $watched.State.totalCostUsd | Should -Be 2.0
    }

    It 'leaves the usage alone when the result carries none' {
        $watched = Invoke-FinishedWatch -Lines @((New-StreamEvent init), (New-StreamEvent result 'Done.'))
        $watched.State.PSObject.Properties['totalCostUsd'] | Should -BeNullOrEmpty
    }

    It 'shows the cost in dep-posse.ps1 status and result' {
        $scenario = New-WatchScenario -Exited -Lines @(
            (New-StreamEvent init),
            (New-ResultEvent @{ result = 'Done.'; total_cost_usd = 3.456; num_turns = 7; duration_ms = 90000 })
        )
        $null = Invoke-Watch $scenario
        $status = Invoke-DeputyScript -InstallRoot $scenario.Install -Script 'dep-posse.ps1' -Arguments @('status')
        $status.Output | Should -Match '\bCost\b'
        $status.Output | Should -Match '\$3\.46'
        $result = Invoke-DeputyScript -InstallRoot $scenario.Install -Script 'dep-posse.ps1' -Arguments @('result', $scenario.Id)
        $result.Output | Should -Match 'Cost: \$3\.46 over 7 turn\(s\), 90s of member time'
    }

    It 'shows a dash for a task whose cost is not known' {
        $scenario = New-WatchScenario -Lines @((New-StreamEvent init))
        $status = Invoke-DeputyScript -InstallRoot $scenario.Install -Script 'dep-posse.ps1' -Arguments @('status')
        $status.ExitCode | Should -Be 0
        $status.Output | Should -Match '\bCost\b'
        $status.Output | Should -Not -Match '\$'
    }
}

Describe 'dep-watch.ps1 with a resumed member' {
    BeforeAll {
        # The log of a task dep-send.ps1 resumed: the first run and its result,
        # the follow-up marker, and nothing from the resumed run yet.
        $firstRun = @(
            (New-StreamEvent init),
            (New-ReportEvent @{ status = 'needs-decision'; summary = 'First run.'; question = 'Which way?' }),
            '{"type":"deputy","subtype":"follow_up","number":1,"message":"Go left."}'
        )
        $script:resumed = New-WatchScenario -Exited -Lines $firstRun
        $offset = (Get-Item $script:resumed.Log).Length
        $statePath = Join-Path $script:resumed.Install 'state' "$($script:resumed.Id).json"
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        $state | Add-Member -NotePropertyName logOffset -NotePropertyValue $offset
        $state | Add-Member -NotePropertyName followUps -NotePropertyValue @(@{ number = 1; message = 'Go left.' })
        ($state | ConvertTo-Json -Depth 6) | Set-Content -Path $statePath -Encoding utf8

        $script:silentRun = Invoke-Watch $script:resumed
        $script:silentStatus = (Get-TestTaskState -InstallRoot $script:resumed.Install -Id $script:resumed.Id).status
    }

    It 'does not report the earlier run''s result as the resumed run''s' {
        $script:silentRun.Output | Should -Not -Match '\[wake\]'
        $script:silentStatus | Should -Be 'running'
    }

    It 'reports the resumed run''s own result, with the follow-up counted' {
        Add-StreamEvent $script:resumed.Log @(
            (New-StreamEvent init),
            (New-ReportEvent @{ status = 'blocked'; summary = 'Second run.'; question = 'And now?' })
        )
        $run = Invoke-Watch $script:resumed
        $run.Output | Should -Match ': blocked \(scout\)'
        $run.Output | Should -Match 'follow-ups sent so far: 1\.'
        $wake = (Get-WakeQueue $script:resumed)[0]
        $wake.summary | Should -Be 'Second run.'
        $wake.question | Should -Be 'And now?'
        $wake.followUps | Should -Be 1
    }

    It 'reports a resumed run that wrote nothing as died, not as completed' {
        $scenario = New-WatchScenario -Exited -Lines @(
            (New-StreamEvent init),
            (New-StreamEvent result 'First run finished.'),
            '{"type":"deputy","subtype":"follow_up","number":1,"message":"Carry on."}'
        ) -Extra @{ logOffset = 100000 }
        # Its offset is past the end of the log: the resumed run has no output.
        $run = Invoke-Watch $scenario @('-DeadSeconds', '0')
        $run.Output | Should -Match ': died \(scout\)'
        $run.Output | Should -Match 'without a result'
        $run.Output | Should -Not -Match 'First run finished'
    }
}