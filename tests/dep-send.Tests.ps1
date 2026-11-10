#Requires -Version 7.0
<#
.SYNOPSIS
Tests for resumable members: the arguments dep-spawn.ps1 and dep-send.ps1 give
claude, the launch itself, and what dep-send.ps1 does to a task.

The scripts run as real processes against a throwaway Deputy install, with
fake claude and treehouse shims first on PATH. The claude shim records the
arguments and stdin it was given, so "argument construction" is checked on
what a member process actually received, not on a string the script built.

What these pin down: a member used to be one shot. Its session had no id
Deputy knew, so a member that asked a question or was cut off by an API
outage could only be started again from nothing.
#>

BeforeAll {
    $script:sourceRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:sourceRoot 'bin' 'dep-lib.ps1')
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:root = New-TempRoot
    $script:n = 0
    $script:sleepers = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    $script:savedPath = $env:PATH
    $script:schema = Get-MemberReportSchema

    function New-SendScenario {
        <#
        .SYNOPSIS
        A finished ship task in a throwaway install: a worktree directory, a
        log holding the first run, and a member process that has exited (or
        is still alive with -Alive). The shims go first on PATH.
        #>
        param(
            [string]$Status = 'needs-decision',
            [hashtable]$State = @{},
            [string[]]$Remove = @(),
            [switch]$Alive
        )
        $script:n++
        $dir = Join-Path $script:root "case$($script:n)"
        $install = New-DeputyInstall -Path (Join-Path $dir 'deputy') -SourceRoot $script:sourceRoot
        $stateDir = Join-Path $install 'state'
        $logDir = Join-Path $install 'logs'
        $worktree = Join-Path $dir 'worktree'
        New-Item -ItemType Directory -Force $stateDir, $logDir, $worktree | Out-Null
        $shims = New-MemberShims -Path (Join-Path $dir 'shims')
        $env:PATH = $shims + [System.IO.Path]::PathSeparator + $script:savedPath

        $id = 'posse-20260101-120000-abc'
        $log = Join-Path $logDir "$id.jsonl"
        $briefing = Join-Path $stateDir "$id-briefing.md"
        Set-Content -Path $briefing -Value 'test briefing' -Encoding utf8
        Set-Content -Path $log -Encoding utf8 -Value @(
            '{"type":"system","subtype":"init","session_id":"first"}'
            (New-StreamResultLine 'First run: should I use the v2 endpoint?')
        )

        $member = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 600')
        $script:sleepers.Add($member)
        $startedAt = $member.StartTime.ToString('o')
        if (-not $Alive) { $member.Kill(); $member.WaitForExit() }

        $record = [ordered]@{
            id             = $id
            kind           = 'ship'
            task           = 'test task'
            repo           = $dir
            worktree       = $worktree
            branch         = 'deputy/test-task'
            delivery       = 'no-mistakes'
            validation     = 'passed'
            validationNote = 'left over from the first run'
            pid            = $member.Id
            pidStartedAt   = $startedAt
            sessionId      = '0f8fad5b-d9cb-469f-a165-70867728950e'
            model          = 'test-model'
            permissionMode = 'bypassPermissions'
            allowedTools   = @()
            effort         = 'high'
            maxBudgetUsd   = 2.5
            status         = $Status
            result         = 'First run: should I use the v2 endpoint?'
            spawnedAt      = '2026-01-01T12:00:00.0000000+00:00'
            endedAt        = '2026-01-01T12:05:00.0000000+00:00'
            stdoutLog      = $log
            stderrLog      = Join-Path $logDir "$id.err.log"
            briefing       = $briefing
            lastLogBytes   = (Get-Item $log).Length
            lastActivityAt = (Get-Date).ToString('o')
            stallNotified  = $true
            logOffset      = 0
            followUps      = @()
            prUrl          = $null
        }
        foreach ($key in $State.Keys) { $record[$key] = $State[$key] }
        foreach ($key in $Remove) { $record.Remove($key) }
        ($record | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $stateDir "$id.json") -Encoding utf8

        [pscustomobject]@{
            Install = $install; Id = $id; Log = $log; Shims = $shims; Worktree = $worktree
            Member = $member; FirstRunBytes = (Get-Item $log).Length
        }
    }

    function Invoke-Send($Scenario, [string]$Message) {
        Invoke-DeputyScript -InstallRoot $Scenario.Install -Script 'dep-send.ps1' `
            -Arguments @($Scenario.Id, '-Message', $Message)
    }

    function Wait-ResumedRun($Scenario, [int]$Count = 1) {
        # The shim has recorded its call, and the process dep-send.ps1 started
        # has gone, so the watcher sees a member that has exited.
        Wait-MemberShimCall -Path $Scenario.Shims -Count $Count | Should -BeTrue
        $state = Get-TestTaskState -InstallRoot $Scenario.Install -Id $Scenario.Id
        Wait-TestProcessGone -ProcessId $state.pid | Should -BeTrue
    }

    function Get-FlagValue([string[]]$Arguments, [string]$Flag) {
        $index = [array]::IndexOf($Arguments, $Flag)
        if ($index -lt 0 -or $index + 1 -ge $Arguments.Count) { return $null }
        $Arguments[$index + 1]
    }
}

AfterAll {
    $env:PATH = $script:savedPath
    foreach ($sleeper in $script:sleepers) {
        if (-not $sleeper.HasExited) { $sleeper.Kill() }
    }
    if ($script:root) { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }
}

Describe 'Get-MemberReportSchema' {
    It 'is one line of JSON with the four statuses and the five fields' {
        $script:schema | Should -Not -Match '\s'
        $parsed = $script:schema | ConvertFrom-Json
        @($parsed.properties.status.enum) | Should -Be @('done', 'blocked', 'needs-decision', 'failed')
        @($parsed.properties.PSObject.Properties.Name) | Should -Be @('status', 'summary', 'tests', 'question', 'prUrl')
        @($parsed.required) | Should -Be @('status', 'summary')
    }

    It 'holds nothing a shell reads as an operator' {
        # It crosses cmd.exe when claude is a .cmd shim.
        $script:schema | Should -Not -Match '[&|<>^%()!]'
    }
}

Describe 'Get-MemberArguments' {
    BeforeAll { $script:sid = '0f8fad5b-d9cb-469f-a165-70867728950e' }

    It 'starts a new session with its id and name, and the report schema' {
        $arguments = @(Get-MemberArguments -SessionId $script:sid -Name 'posse-20260101-120000-abc')
        $arguments | Should -Be @('-p', '--output-format', 'stream-json', '--verbose',
            '--dangerously-skip-permissions', '--json-schema', $script:schema,
            '--session-id', $script:sid, '-n', 'posse-20260101-120000-abc')
    }

    It 'resumes with --resume and neither --session-id nor a name' {
        $arguments = @(Get-MemberArguments -SessionId $script:sid -Name 'posse-20260101-120000-abc' -Resume)
        $arguments | Should -Be @('-p', '--output-format', 'stream-json', '--verbose',
            '--dangerously-skip-permissions', '--json-schema', $script:schema, '--resume', $script:sid)
    }

    It 'passes model, effort and budget when they are set' {
        $arguments = @(Get-MemberArguments -SessionId $script:sid -Model 'test-model' -Effort 'xhigh' -MaxBudgetUsd 7.25)
        Get-FlagValue $arguments '--model' | Should -Be 'test-model'
        Get-FlagValue $arguments '--effort' | Should -Be 'xhigh'
        Get-FlagValue $arguments '--max-budget-usd' | Should -Be '7.25'
    }

    It 'leaves --effort and --max-budget-usd off when they are null' {
        $arguments = @(Get-MemberArguments -SessionId $script:sid -Effort $null -MaxBudgetUsd $null)
        $arguments | Should -Not -Contain '--effort'
        $arguments | Should -Not -Contain '--max-budget-usd'
    }

    It 'writes the budget with a decimal point whatever the culture' {
        $previous = [cultureinfo]::CurrentCulture
        try {
            [cultureinfo]::CurrentCulture = [cultureinfo]'de-DE'
            Get-FlagValue @(Get-MemberArguments -SessionId $script:sid -MaxBudgetUsd 1.5) '--max-budget-usd' | Should -Be '1.5'
        }
        finally { [cultureinfo]::CurrentCulture = $previous }
    }

    It 'uses a permission mode and its grants instead of the bypass flag' {
        $arguments = @(Get-MemberArguments -SessionId $script:sid -PermissionMode 'acceptEdits' -AllowedTools 'Bash(git *)', 'Bash(npm *)')
        $arguments | Should -Not -Contain '--dangerously-skip-permissions'
        Get-FlagValue $arguments '--permission-mode' | Should -Be 'acceptEdits'
        Get-FlagValue $arguments '--allowedTools' | Should -Be 'Bash(git *),Bash(npm *)'
    }

    It 'has nobody answer permission prompts in every mode but bypassPermissions' {
        # A headless member cannot answer one: whatever would prompt is denied.
        foreach ($mode in 'acceptEdits', 'auto', 'dontAsk', 'manual', 'plan') {
            Get-FlagValue @(Get-MemberArguments -SessionId $script:sid -PermissionMode $mode) '--permission-prompts' |
                Should -Be 'none' -Because "mode $mode"
        }
        @(Get-MemberArguments -SessionId $script:sid) | Should -Not -Contain '--permission-prompts'
    }

    It 'isolates the member from MCP servers, skills and commands only when asked' {
        $isolated = @(Get-MemberArguments -SessionId $script:sid -Isolation)
        $isolated | Should -Contain '--strict-mcp-config'
        $isolated | Should -Contain '--disable-slash-commands'
        $isolated | Should -Not -Contain '--mcp-config'
        $plain = @(Get-MemberArguments -SessionId $script:sid)
        $plain | Should -Not -Contain '--strict-mcp-config'
        $plain | Should -Not -Contain '--disable-slash-commands'
    }

    It 'resumes a task with the isolation it was spawned with, and an older task without it' {
        $isolated = [pscustomobject]@{ id = 'posse-20260101-120000-abc'; kind = 'ship'; sessionId = $script:sid; memberIsolation = $true }
        @(Get-TaskMemberArguments $isolated -Resume) | Should -Contain '--strict-mcp-config'
        @(Get-TaskMemberArguments $isolated -Resume) | Should -Contain '--disable-slash-commands'
        $older = [pscustomobject]@{ id = 'posse-20260101-120000-abc'; kind = 'ship'; sessionId = $script:sid }
        @(Get-TaskMemberArguments $older -Resume) | Should -Not -Contain '--strict-mcp-config'
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'an unknown effort level'; Extra = @{ Effort = 'extreme' }; Message = 'not one of' }
        @{ Name = 'a zero budget'; Extra = @{ MaxBudgetUsd = 0 }; Message = 'not a positive amount' }
        @{ Name = 'a negative budget'; Extra = @{ MaxBudgetUsd = -1 }; Message = 'not a positive amount' }
        @{ Name = 'a budget that is not a number'; Extra = @{ MaxBudgetUsd = 'lots' }; Message = 'not a positive amount' }
    ) {
        { Get-MemberArguments -SessionId $script:sid @Extra } | Should -Throw "*$Message*"
    }

    It 'refuses a session id that is not a UUID' {
        { Get-MemberArguments -SessionId 'not-a-uuid' } | Should -Throw '*not a UUID*'
    }

    It 'gives a scout access to the state directory, and a resumed scout too' {
        $scout = [pscustomobject]@{ id = 'posse-20260101-120000-abc'; kind = 'scout'; sessionId = $script:sid }
        $stateDir = (Get-DeputyPaths).State
        Get-FlagValue @(Get-TaskMemberArguments $scout) '--add-dir' | Should -Be $stateDir
        Get-FlagValue @(Get-TaskMemberArguments $scout -Resume) '--add-dir' | Should -Be $stateDir
    }
}

Describe 'ConvertTo-ProcessArgument' {
    It 'quotes <Value> as <Expected>' -ForEach @(
        @{ Value = 'plain'; Expected = 'plain' }
        @{ Value = 'C:\no\spaces\'; Expected = 'C:\no\spaces\' }
        @{ Value = ''; Expected = '""' }
        @{ Value = 'two words'; Expected = '"two words"' }
        @{ Value = 'C:\with space\'; Expected = '"C:\with space\\"' }
        @{ Value = '{"a":"b"}'; Expected = '"{\"a\":\"b\"}"' }
        @{ Value = 'tail\"'; Expected = '"tail\\\""' }
    ) {
        ConvertTo-ProcessArgument $Value | Should -BeExactly $Expected
    }
}

Describe 'Get-MemberCommandLine' {
    It 'starts an executable directly' {
        $command = Get-MemberCommandLine 'C:\tools\claude.exe' @('-p', 'two words')
        $command.FilePath | Should -Be 'C:\tools\claude.exe'
        $command.CommandLine | Should -BeExactly 'C:\tools\claude.exe -p "two words"'
    }

    It 'runs a .cmd shim under cmd.exe, with the whole line in one outer pair of quotes' {
        $command = Get-MemberCommandLine 'C:\my tools\claude.cmd' @('-p', 'two words')
        $command.FilePath | Should -Be $env:ComSpec
        $command.CommandLine | Should -BeLike '* /d /s /c ""C:\my tools\claude.cmd" -p "two words""'
    }
}

Describe 'dep-send.ps1' {
    Context 'a member that asked for a decision and has exited' {
        BeforeAll {
            $script:asked = New-SendScenario
            $script:message = 'Use the v2 endpoint, and keep "v1" working.'
            $script:sendRun = Invoke-Send $script:asked $script:message
            Wait-ResumedRun $script:asked
            $script:call = (Get-MemberShimCalls -Path $script:asked.Shims)[0]
            $script:sentState = Get-TestTaskState -InstallRoot $script:asked.Install -Id $script:asked.Id
        }

        It 'reports the follow-up it sent' {
            $script:sendRun.ExitCode | Should -Be 0
            $script:sendRun.Output | Should -Match 'sent follow-up #1 to posse-20260101-120000-abc \(was needs-decision\)'
        }

        It 'resumes the recorded session with the same flags as the first run' {
            @($script:call.args) | Should -Be @('-p', '--output-format', 'stream-json', '--verbose',
                '--model', 'test-model', '--dangerously-skip-permissions', '--effort', 'high',
                '--max-budget-usd', '2.5', '--json-schema', $script:schema,
                '--resume', '0f8fad5b-d9cb-469f-a165-70867728950e')
        }

        It 'gives the member the message on stdin, in its worktree, marked as a posse member' {
            $script:call.stdin.Trim() | Should -BeExactly $script:message
            $script:call.cwd | Should -Be $script:asked.Worktree
            $script:call.marker | Should -Be $script:asked.Id
        }

        It 'appends to the same log: the first run, a follow-up marker, then the resumed run' {
            $lines = @(Get-Content $script:asked.Log | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
            $lines[0].session_id | Should -Be 'first'
            $lines[1].result | Should -Be 'First run: should I use the v2 endpoint?'
            $lines[2].type | Should -Be 'deputy'
            $lines[2].subtype | Should -Be 'follow_up'
            $lines[2].message | Should -BeExactly $script:message
            $lines[3].session_id | Should -Be 'fake'
            $lines[4].result | Should -Be 'Fake member finished.'
            $lines.Count | Should -Be 5
        }

        It 'sets the task back to running on the new process' {
            $script:sentState.status | Should -Be 'running'
            $script:sentState.endedAt | Should -BeNullOrEmpty
            $script:sentState.pid | Should -Not -Be $script:asked.Member.Id
            $script:sentState.pidStartedAt | Should -Not -BeNullOrEmpty
            $script:sentState.stallNotified | Should -BeFalse
        }

        It 'records the follow-up in task state' {
            $followUps = @($script:sentState.followUps)
            $followUps.Count | Should -Be 1
            $followUps[0].number | Should -Be 1
            $followUps[0].afterStatus | Should -Be 'needs-decision'
            $followUps[0].message | Should -BeExactly $script:message
            $followUps[0].pid | Should -Be $script:sentState.pid
        }

        It 'starts the current run after the first run and its marker' {
            $script:sentState.logOffset | Should -BeGreaterThan $script:asked.FirstRunBytes
            $script:sentState.lastLogBytes | Should -Be $script:sentState.logOffset
        }

        It 'clears the gate verdict of the earlier run and says so' {
            $script:sentState.validation | Should -BeNullOrEmpty
            $script:sentState.validationNote | Should -BeNullOrEmpty
            $script:sendRun.Output | Should -Match 'gate verdict was cleared'
        }

        Context 'once the watcher scans' {
            BeforeAll {
                $script:watchRun = Invoke-DeputyScript -InstallRoot $script:asked.Install -Script 'dep-watch.ps1'
                $script:watchedState = Get-TestTaskState -InstallRoot $script:asked.Install -Id $script:asked.Id
            }

            It 'reports the resumed run, not the first one again' {
                $script:watchRun.Output | Should -Match ': completed \(ship\)'
                $script:watchRun.Output | Should -Match 'Fake member finished\.'
                $script:watchRun.Output | Should -Not -Match 'First run'
                $script:watchedState.status | Should -Be 'completed'
                $script:watchedState.result | Should -Be 'Fake member finished.'
            }

            It 'takes a second follow-up as number two' {
                $run = Invoke-Send $script:asked 'One more thing.'
                $run.ExitCode | Should -Be 0
                $run.Output | Should -Match 'sent follow-up #2 .*\(was completed\)'
                Wait-ResumedRun $script:asked -Count 2
                $state = Get-TestTaskState -InstallRoot $script:asked.Install -Id $script:asked.Id
                @($state.followUps | ForEach-Object number) | Should -Be @(1, 2)
                (Get-MemberShimCalls -Path $script:asked.Shims)[1].stdin.Trim() | Should -Be 'One more thing.'
            }
        }
    }

    Context 'a task it must refuse' {
        It 'refuses <Name>' -ForEach @(
            @{ Name = 'a member that is still running'; Options = @{ Alive = $true; Status = 'running' }; Message = 'still has a live process' }
            @{ Name = 'a finished status whose process is somehow alive'; Options = @{ Alive = $true }; Message = 'still has a live process' }
            @{ Name = 'a task with no session id'; Options = @{ Remove = @('sessionId') }; Message = 'no recorded session id' }
            @{ Name = 'a task whose worktree is gone'; Options = @{ State = @{ worktree = 'Z:\no\such\worktree' } }; Message = 'worktree of .* is gone' }
            @{ Name = 'a task the watcher has not reported yet'; Options = @{ Status = 'running' }; Message = 'has not reported its outcome yet' }
        ) {
            $scenario = New-SendScenario @Options
            $before = Get-Content (Join-Path $scenario.Install 'state' "$($scenario.Id).json") -Raw
            $run = Invoke-Send $scenario 'Continue where you left off.'
            $run.ExitCode | Should -Not -Be 0
            $run.Output | Should -Match $Message
            # Nothing was started and nothing was recorded.
            (Get-MemberShimCalls -Path $scenario.Shims).Count | Should -Be 0
            Get-Content (Join-Path $scenario.Install 'state' "$($scenario.Id).json") -Raw | Should -BeExactly $before
            (Get-Item $scenario.Log).Length | Should -Be $scenario.FirstRunBytes
        }

        It 'refuses an empty message' {
            $scenario = New-SendScenario
            $run = Invoke-Send $scenario '   '
            $run.ExitCode | Should -Not -Be 0
            $run.Output | Should -Match 'message is empty'
            (Get-MemberShimCalls -Path $scenario.Shims).Count | Should -Be 0
        }

        It 'refuses a task that was returned' {
            $scenario = New-SendScenario
            Remove-Item (Join-Path $scenario.Install 'state' "$($scenario.Id).json")
            $run = Invoke-Send $scenario 'Continue where you left off.'
            $run.ExitCode | Should -Not -Be 0
            $run.Output | Should -Match 'No active task state'
        }
    }

    Context 'a task that is returned afterwards' {
        It 'archives the follow-up messages with the task' {
            $scenario = New-SendScenario
            (Invoke-Send $scenario 'Continue where you left off.').ExitCode | Should -Be 0
            Wait-ResumedRun $scenario
            $stateDir = Join-Path $scenario.Install 'state'
            Join-Path $stateDir "$($scenario.Id)-followup-1.md" | Should -Exist

            # With its worktree gone there is no lease to give back, so
            # dep-return.ps1 needs no treehouse here.
            Remove-Item -Recurse -Force $scenario.Worktree
            $run = Invoke-DeputyScript -InstallRoot $scenario.Install -Script 'dep-return.ps1' -Arguments @($scenario.Id)
            $run.ExitCode | Should -Be 0
            Join-Path $stateDir "$($scenario.Id)-followup-1.md" | Should -Not -Exist
            Join-Path $stateDir 'archive' "$($scenario.Id)-followup-1.md" | Should -Exist

            # And a returned task can no longer be sent to.
            (Invoke-Send $scenario 'Too late.').Output | Should -Match 'No active task state'
        }
    }

    Context 'an interrupted member' {
        It 'is continued, and the next wake counts the follow-up' {
            $scenario = New-SendScenario -Status 'interrupted' -State @{ validation = $null }
            # The resumed run is cut off again.
            Set-Content -Path (Join-Path $scenario.Shims 'claude-result.json') -Encoding utf8 -Value (
                '{"type":"result","subtype":"success","is_error":true,"api_error_status":529,' +
                '"result":"API Error: 529 Overloaded. This is a server-side issue, usually temporary."}')
            $run = Invoke-Send $scenario 'Continue where you left off.'
            $run.ExitCode | Should -Be 0
            $run.Output | Should -Not -Match 'gate verdict'
            Wait-ResumedRun $scenario

            $watch = Invoke-DeputyScript -InstallRoot $scenario.Install -Script 'dep-watch.ps1'
            $watch.Output | Should -Match ': interrupted \(ship\)'
            $watch.Output | Should -Match 'follow-ups sent so far: 1\.'
            (Get-TestTaskState -InstallRoot $scenario.Install -Id $scenario.Id).status | Should -Be 'interrupted'
        }
    }
}

Describe 'dep-spawn.ps1' {
    BeforeAll {
        $script:spawnDir = Join-Path $script:root 'spawn'
        $script:spawnInstall = New-DeputyInstall -Path (Join-Path $script:spawnDir 'deputy') -SourceRoot $script:sourceRoot
        $script:spawnRepo = New-TestRepo -Path (Join-Path $script:spawnDir 'repo')
        # A linked worktree of the repo, as a treehouse slot is: dep-spawn.ps1
        # refuses a lease that is not a worktree of its own.
        $script:spawnLease = Join-Path $script:spawnDir 'leased'
        Invoke-Git @('-C', $script:spawnRepo, 'worktree', 'add', '-q', '--detach', $script:spawnLease)
        $script:spawnLease = (Resolve-Path $script:spawnLease).Path
        $script:spawnShims = New-MemberShims -Path (Join-Path $script:spawnDir 'shims') -LeasePath $script:spawnLease
        $script:spawnConfig = Join-Path $script:spawnInstall 'config' 'deputy.json'
        $script:spawnCalls = 0

        function Invoke-Spawn([string[]]$Arguments) {
            # Run dep-spawn.ps1 and return what the member process was given.
            $env:PATH = $script:spawnShims + [System.IO.Path]::PathSeparator + $script:savedPath
            $run = Invoke-DeputyScript -InstallRoot $script:spawnInstall -Script 'dep-spawn.ps1' `
                -Arguments (@('-Repo', $script:spawnRepo) + $Arguments)
            $id = if ($run.Output -match 'spawned (posse-\d{8}-\d{6}-[a-z]{3})') { $Matches[1] } else { $null }
            $call = $null
            $state = $null
            if ($run.ExitCode -eq 0 -and $id) {
                $script:spawnCalls++
                Wait-MemberShimCall -Path $script:spawnShims -Count $script:spawnCalls | Should -BeTrue
                $call = (Get-MemberShimCalls -Path $script:spawnShims)[$script:spawnCalls - 1]
                $state = Get-TestTaskState -InstallRoot $script:spawnInstall -Id $id
            }
            [pscustomobject]@{ Run = $run; Id = $id; Call = $call; State = $state }
        }

        function Get-LeaseCount {
            $log = Join-Path $script:spawnShims 'treehouse-calls.log'
            if (-not (Test-Path $log)) { return 0 }
            @(Get-Content $log | Where-Object { $_ -match '^get --lease' }).Count
        }
    }

    Context 'a ship task with an effort level and a budget' {
        BeforeAll {
            Remove-Item $script:spawnConfig -ErrorAction SilentlyContinue
            $script:shipSpawn = Invoke-Spawn @('-Task', 'Fix the "flaky" auth test', '-Model', 'test-model',
                '-Effort', 'high', '-MaxBudgetUsd', '3')
        }

        It 'spawns' {
            $script:shipSpawn.Run.ExitCode | Should -Be 0
            $script:shipSpawn.Id | Should -Not -BeNullOrEmpty
        }

        It 'gives the session an id of its own choosing, and the task id as its name' {
            $arguments = @($script:shipSpawn.Call.args)
            $sessionId = Get-FlagValue $arguments '--session-id'
            $parsed = [guid]::Empty
            [guid]::TryParse($sessionId, [ref]$parsed) | Should -BeTrue
            Get-FlagValue $arguments '-n' | Should -Be $script:shipSpawn.Id
            $arguments | Should -Not -Contain '--resume'
        }

        It 'records that session id in task state and prints it' {
            $script:shipSpawn.State.sessionId | Should -Be (Get-FlagValue @($script:shipSpawn.Call.args) '--session-id')
            $script:shipSpawn.Run.Output | Should -Match ([regex]::Escape($script:shipSpawn.State.sessionId))
        }

        It 'passes the whole argument list a member needs' {
            @($script:shipSpawn.Call.args) | Should -Be @('-p', '--output-format', 'stream-json', '--verbose',
                '--model', 'test-model', '--dangerously-skip-permissions',
                '--strict-mcp-config', '--disable-slash-commands', '--effort', 'high',
                '--max-budget-usd', '3', '--json-schema', $script:schema,
                '--session-id', $script:shipSpawn.State.sessionId, '-n', $script:shipSpawn.Id)
        }

        It 'records what a resumed run has to be started with' {
            $script:shipSpawn.State.effort | Should -Be 'high'
            $script:shipSpawn.State.maxBudgetUsd | Should -Be 3
            $script:shipSpawn.State.model | Should -Be 'test-model'
            $script:shipSpawn.State.memberIsolation | Should -BeTrue
            $script:shipSpawn.State.logOffset | Should -Be 0
            @($script:shipSpawn.State.followUps).Count | Should -Be 0
        }

        It 'briefs the member on stdin, in the leased worktree, with the structured report explained' {
            $script:shipSpawn.Call.cwd | Should -Be $script:spawnLease
            $script:shipSpawn.Call.marker | Should -Be $script:shipSpawn.Id
            $script:shipSpawn.Call.stdin | Should -Match 'Fix the "flaky" auth test'
            $script:shipSpawn.Call.stdin | Should -Match 'status: "done"'
            $script:shipSpawn.Call.stdin | Should -Match '"needs-decision"'
            $script:shipSpawn.Call.stdin | Should -Match 'can be resumed'
            # no-mistakes delivery: the member opens no PR, so it is not asked for one
            $script:shipSpawn.Call.stdin | Should -Not -Match 'prUrl'
        }

        It 'writes the member''s output to the task log' {
            Wait-TestProcessGone -ProcessId $script:shipSpawn.State.pid | Should -BeTrue
            $lines = @(Get-Content $script:shipSpawn.State.stdoutLog | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
            $lines[-1].result | Should -Be 'Fake member finished.'
        }
    }

    Context 'defaults from config\deputy.json' {
        It 'leaves --effort and --max-budget-usd off when the config does not set them' {
            Remove-Item $script:spawnConfig -ErrorAction SilentlyContinue
            $spawn = Invoke-Spawn @('-Task', 'No effort, no budget')
            $spawn.Run.ExitCode | Should -Be 0
            @($spawn.Call.args) | Should -Not -Contain '--effort'
            @($spawn.Call.args) | Should -Not -Contain '--max-budget-usd'
            $spawn.State.effort | Should -BeNullOrEmpty
            $spawn.State.maxBudgetUsd | Should -BeNullOrEmpty
        }

        It 'leaves them off when the config sets them to null' {
            Set-Content -Path $script:spawnConfig -Encoding utf8 -Value '{ "effort": null, "maxBudgetUsd": null }'
            $spawn = Invoke-Spawn @('-Task', 'Null effort, null budget')
            @($spawn.Call.args) | Should -Not -Contain '--effort'
            @($spawn.Call.args) | Should -Not -Contain '--max-budget-usd'
        }

        It 'takes both from the config, and lets the command line override them' {
            Set-Content -Path $script:spawnConfig -Encoding utf8 -Value '{ "effort": "low", "maxBudgetUsd": 1.5 }'
            $fromConfig = Invoke-Spawn @('-Task', 'Config effort and budget')
            Get-FlagValue @($fromConfig.Call.args) '--effort' | Should -Be 'low'
            Get-FlagValue @($fromConfig.Call.args) '--max-budget-usd' | Should -Be '1.5'

            $overridden = Invoke-Spawn @('-Task', 'Overridden effort and budget', '-Effort', 'max', '-MaxBudgetUsd', '20')
            Get-FlagValue @($overridden.Call.args) '--effort' | Should -Be 'max'
            Get-FlagValue @($overridden.Call.args) '--max-budget-usd' | Should -Be '20'
        }
    }

    Context 'a scout and a direct-pr ship task' {
        It 'gives a scout the state directory and a report path' {
            Remove-Item $script:spawnConfig -ErrorAction SilentlyContinue
            $spawn = Invoke-Spawn @('-Task', 'Why is startup slow?', '-Kind', 'scout')
            Get-FlagValue @($spawn.Call.args) '--add-dir' | Should -Be (Join-Path $script:spawnInstall 'state')
            $spawn.Call.stdin | Should -Match ([regex]::Escape("$($spawn.Id)-report.md"))
            $spawn.Call.stdin | Should -Match 'status: "done"'
        }

        It 'asks a direct-pr member for the PR URL in its report' {
            $projects = Join-Path $script:spawnInstall 'config' 'projects.json'
            $saved = Get-Content $projects -Raw
            try {
                Set-Content -Path $projects -Encoding utf8 -Value '{ "default": { "delivery": "direct-pr", "validate": [] }, "projects": [] }'
                $spawn = Invoke-Spawn @('-Task', 'Ship it directly')
                $spawn.Call.stdin | Should -Match 'prUrl: the URL of the pull request'
            }
            finally { Set-Content -Path $projects -Encoding utf8 -Value $saved -NoNewline }
        }
    }

    Context 'values it must refuse before leasing anything' {
        It 'refuses <Name>' -ForEach @(
            @{ Name = 'an unknown effort level'; Extra = @('-Effort', 'extreme') }
            @{ Name = 'a zero budget'; Extra = @('-MaxBudgetUsd', '0') }
            @{ Name = 'a budget that is not a number'; Extra = @('-MaxBudgetUsd', 'lots') }
        ) {
            Remove-Item $script:spawnConfig -ErrorAction SilentlyContinue
            $leases = Get-LeaseCount
            $calls = (Get-MemberShimCalls -Path $script:spawnShims).Count
            $spawn = Invoke-Spawn (@('-Task', 'Never starts') + $Extra)
            $spawn.Run.ExitCode | Should -Not -Be 0
            Get-LeaseCount | Should -Be $leases
            (Get-MemberShimCalls -Path $script:spawnShims).Count | Should -Be $calls
        }

        It 'refuses an effort level in the config that claude does not have' {
            Set-Content -Path $script:spawnConfig -Encoding utf8 -Value '{ "effort": "extreme" }'
            $leases = Get-LeaseCount
            $spawn = Invoke-Spawn @('-Task', 'Never starts')
            $spawn.Run.ExitCode | Should -Not -Be 0
            $spawn.Run.Output | Should -Match 'not one of: low, medium, high, xhigh, max'
            Get-LeaseCount | Should -Be $leases
            Remove-Item $script:spawnConfig -ErrorAction SilentlyContinue
        }
    }
}
