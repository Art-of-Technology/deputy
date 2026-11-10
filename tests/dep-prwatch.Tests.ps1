#Requires -Version 7.0
<#
.SYNOPSIS
End-to-end tests for PR watching: dep-watch.ps1 run as a real process against
a throwaway Deputy install holding a published task, with a fake gh first on
PATH answering for its pull request.

The regression these pin down: once a pull request was open Deputy went blind.
A merge or a red check arrived and nothing happened until the Sheriff asked.
The watcher now polls each published, unmerged task's PR and raises `merged`
once, and `degraded` once per head commit - through the same durable queue as
every other wake - and a lookup that fails raises nothing at all.

A pull request closed without merging raises `closed` once and then stops
counting as something to wait for. It used to be polled for ever, which held
the watcher, the stop hooks and a one-shot Deputy indefinitely, and the Deputy
was never told.
#>

BeforeAll {
    $script:sourceRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:root = New-TempRoot
    $script:n = 0
    $script:savedPath = $env:PATH
    # A posse member running this suite carries the marker; the stop guard
    # under test must see what a Deputy session would see.
    $script:savedMarker = $env:DEPUTY_POSSE_TASK
    $env:DEPUTY_POSSE_TASK = $null
    $script:watchers = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    $script:prUrl = 'https://github.com/acme/widgets/pull/7'
    $script:api = 'repos/acme/widgets'
    $script:head = 'a' * 40
    $script:green = @(@{ name = 'lint'; conclusion = 'success' }, @{ name = 'test'; conclusion = 'success' })
    $script:red = @(@{ name = 'lint'; conclusion = 'success' }, @{ name = 'test'; conclusion = 'failure' })

    function New-PrWatchScenario {
        <#
        .SYNOPSIS
        A published ship task whose member has long finished, in a throwaway
        install, and a fake gh holding its pull request. The PR is due for a
        poll unless -CheckedNow says it was just read.
        #>
        param(
            $PullRequest = (New-PullRequestJson -HeadSha $script:head),
            [hashtable[]]$Runs = $script:green,
            [hashtable]$Extra = @{},
            [switch]$CheckedNow,
            [hashtable]$Config
        )
        $script:n++
        $dir = Join-Path $script:root "case$($script:n)"
        $install = New-DeputyInstall -Path (Join-Path $dir 'deputy') -SourceRoot $script:sourceRoot
        if ($Config) {
            ($Config | ConvertTo-Json) | Set-Content -Path (Join-Path $install 'config' 'deputy.json') -Encoding utf8
        }
        $gone = Join-Path $dir 'no-such-worktree'
        $id = New-TestTaskState -InstallRoot $install -Repo $gone -Worktree $gone -Branch 'deputy/task'
        $shim = New-GhShim -Path (Join-Path $dir 'shims')
        $env:PATH = $shim + [System.IO.Path]::PathSeparator + $script:savedPath
        $scenario = [pscustomobject]@{ Install = $install; Id = $id; Shim = $shim }

        $fields = @{ prUrl = $script:prUrl; prNumber = 7; prHead = $script:head }
        if ($CheckedNow) { $fields.prCheckedAt = (Get-Date -Format o) }
        foreach ($key in $Extra.Keys) { $fields[$key] = $Extra[$key] }
        Set-StateField $scenario $fields
        Set-PullRequest $scenario $PullRequest $Runs
        $scenario
    }

    function Set-StateField($Scenario, [hashtable]$Fields) {
        $path = Join-Path $Scenario.Install 'state' "$($Scenario.Id).json"
        $state = Get-Content $path -Raw | ConvertFrom-Json
        foreach ($key in $Fields.Keys) {
            $state | Add-Member -NotePropertyName $key -NotePropertyValue $Fields[$key] -Force
        }
        ($state | ConvertTo-Json -Depth 6) | Set-Content -Path $path -Encoding utf8
    }

    function Set-PullRequest($Scenario, $PullRequest, [hashtable[]]$Runs = $script:green) {
        Set-GhRoutes -Path $Scenario.Shim -Routes (New-PrRoutes -PullRequest $PullRequest -Runs $Runs)
    }

    function Set-PollDue($Scenario) {
        # Pretend the last read of the PR was long ago.
        Set-StateField $Scenario @{ prCheckedAt = (Get-Date).AddHours(-1).ToString('o') }
    }

    function Invoke-Watch($Scenario, [string[]]$Arguments = @()) {
        Invoke-DeputyScript -InstallRoot $Scenario.Install -Script 'dep-watch.ps1' -Arguments $Arguments
    }

    function Get-State($Scenario) {
        Get-TestTaskState -InstallRoot $Scenario.Install -Id $Scenario.Id
    }

    function Get-WakeQueue($Scenario) {
        $path = Join-Path $Scenario.Install 'state' 'wake-queue.jsonl'
        if (-not (Test-Path $path)) { return , @() }
        , @(Get-Content $path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }
}

AfterAll {
    $env:PATH = $script:savedPath
    $env:DEPUTY_POSSE_TASK = $script:savedMarker
    foreach ($watcher in $script:watchers) {
        if (-not $watcher.HasExited) { $watcher.Kill() }
    }
    if ($script:root) { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }
}

Describe 'dep-watch.ps1 and a merged pull request' {
    BeforeAll {
        $script:merged = New-PrWatchScenario -PullRequest (New-PullRequestJson -Merged -HeadSha $script:head -MergeSha ('c' * 40))
        $script:mergedRun = Invoke-Watch $script:merged
        $script:mergedWakes = Get-WakeQueue $script:merged
    }

    It 'raises a merged wake through the queue' {
        $script:mergedRun.ExitCode | Should -Be 0
        $script:mergedRun.Output | Should -Match "\[wake\] $($script:merged.Id): merged \(ship\) seq=1"
        $script:mergedWakes.Count | Should -Be 1
        $script:mergedWakes[0].event | Should -Be 'merged'
        $script:mergedWakes[0].seq | Should -Be 1
        $script:mergedWakes[0].prUrl | Should -Be $script:prUrl
        $script:mergedWakes[0].summary | Should -Match 'Pull request #7 was merged as c{10}\.'
    }

    It 'tells the Deputy to tear the task down' {
        $script:mergedRun.Output | Should -Match 'The work has landed\. Tear the task down with: pwsh .*dep-return\.ps1" posse-'
        $drain = Invoke-DeputyScript -InstallRoot $script:merged.Install -Script 'dep-wake.ps1' -Arguments @('drain')
        $drain.Output | Should -Match ': merged \(ship\) seq=1'
        $drain.Output | Should -Match 'Tear the task down with: pwsh .*dep-return\.ps1'
        $drain.Output | Should -Match 'ack -Through 1'
    }

    It 'records mergedAt and mergeSha' {
        $state = Get-State $script:merged
        $state.mergeSha | Should -Be ('c' * 40)
        ([datetime]$state.mergedAt).ToUniversalTime() | Should -Be ([datetime]::new(2026, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc))
        $state.status | Should -Be 'completed'
    }

    It 'raises it once: a merged task is not polled again' {
        Set-PollDue $script:merged
        $callsBefore = @(Get-GhCalls -Path $script:merged.Shim).Count
        $run = Invoke-Watch $script:merged
        $run.Output | Should -Match 'no new events'
        (Get-WakeQueue $script:merged).Count | Should -Be 1
        @(Get-GhCalls -Path $script:merged.Shim).Count | Should -Be $callsBefore
    }

    It 'raises no wake for a merge dep-pr.ps1 merge already recorded' {
        $s = New-PrWatchScenario -PullRequest (New-PullRequestJson -Merged -HeadSha $script:head) `
            -Extra @{ mergedAt = '2026-01-02T03:04:05Z'; mergeSha = ('c' * 40) }
        (Invoke-Watch $s).Output | Should -Match 'no new events'
        (Get-WakeQueue $s).Count | Should -Be 0
        @(Get-GhCalls -Path $s.Shim).Count | Should -Be 0
    }
}

Describe 'dep-watch.ps1 and a pull request whose checks fail' {
    BeforeAll {
        $script:deg = New-PrWatchScenario -Runs $script:red
        $script:degRun = Invoke-Watch $script:deg
        $script:degWakes = Get-WakeQueue $script:deg
    }

    It 'raises a degraded wake that names the failing check' {
        $script:degRun.Output | Should -Match ': degraded \(ship\) seq=1'
        $script:degWakes.Count | Should -Be 1
        $script:degWakes[0].event | Should -Be 'degraded'
        $script:degWakes[0].summary | Should -Match 'Pull request #7 has 1 failing check\(s\) at a{10}: test \(failure\)\.'
        (Get-State $script:deg).prDegradedHead | Should -Be $script:head
    }

    It 'leaves the task unmerged and still watched' {
        $state = Get-State $script:deg
        $state.PSObject.Properties['mergedAt'] | Should -BeNullOrEmpty
        $state.status | Should -Be 'completed'
    }

    It 'raises it once per head: the same failing head says nothing more' {
        Set-PollDue $script:deg
        (Invoke-Watch $script:deg).Output | Should -Match 'no new events'
        (Get-WakeQueue $script:deg).Count | Should -Be 1
    }

    It 'raises it again when a new head has a failing check, and says the head is not the published one' {
        $newHead = 'b' * 40
        Set-PullRequest $script:deg (New-PullRequestJson -HeadSha $newHead) $script:red
        Set-PollDue $script:deg
        (Invoke-Watch $script:deg).Output | Should -Match ': degraded \(ship\) seq=2'
        $wakes = Get-WakeQueue $script:deg
        $wakes.Count | Should -Be 2
        $wakes[1].summary | Should -Match 'failing check\(s\) at b{10}'
        $wakes[1].summary | Should -Match 'not the commit Deputy published \(a{10}\)'
        (Get-State $script:deg).prDegradedHead | Should -Be $newHead
    }

    It 'still raises merged afterwards' {
        Set-PullRequest $script:deg (New-PullRequestJson -Merged -HeadSha ('b' * 40))
        Set-PollDue $script:deg
        (Invoke-Watch $script:deg).Output | Should -Match ': merged \(ship\) seq=3'
    }
}

Describe 'dep-watch.ps1 and a pull request closed without merging' {
    BeforeAll {
        function Invoke-StopGuard($Scenario) {
            Invoke-DeputyHook -InstallRoot $Scenario.Install -Script 'dep-hook-guard.ps1' -Arguments @('-GraceSeconds', '0')
        }

        # Failing checks too: a closed PR is `closed`, never `degraded`.
        $script:closed = New-PrWatchScenario -PullRequest (New-PullRequestJson -State closed -HeadSha $script:head) -Runs $script:red
        $script:guardBefore = Invoke-StopGuard $script:closed
        $script:closedRun = Invoke-Watch $script:closed
        $script:closedWakes = Get-WakeQueue $script:closed
    }

    It 'counts as work for the watcher until it is seen closed' {
        $script:guardBefore.ExitCode | Should -Be 2
        $script:guardBefore.ErrorOutput | Should -Match '1 published pull request\(s\) are waiting to be merged'
    }

    It 'raises a closed wake through the queue, and says the work has not landed' {
        $script:closedRun.ExitCode | Should -Be 0
        $script:closedRun.Output | Should -Match "\[wake\] $($script:closed.Id): closed \(ship\) seq=1"
        $script:closedRun.Output | Should -Match "The work has NOT landed\. Tell the Sheriff, and do not return the worktree without the Sheriff's word\."
        $script:closedWakes.Count | Should -Be 1
        $script:closedWakes[0].event | Should -Be 'closed'
        $script:closedWakes[0].summary | Should -Be 'Pull request #7 was closed without merging.'
        $script:closedWakes[0].prUrl | Should -Be $script:prUrl
    }

    It 'records prClosedAt, and does not read the closing as a merge' {
        $state = Get-State $script:closed
        $state.prClosedAt | Should -Not -BeNullOrEmpty
        $state.PSObject.Properties['mergedAt'] | Should -BeNullOrEmpty
        $state.PSObject.Properties['prDegradedHead'] | Should -BeNullOrEmpty
        $state.status | Should -Be 'completed'
    }

    It 'lets the stop through once the pull request is closed' {
        $run = Invoke-StopGuard $script:closed
        $run.ExitCode | Should -Be 0
        $run.Output.Trim() | Should -BeNullOrEmpty
        $run.ErrorOutput.Trim() | Should -BeNullOrEmpty
    }

    It 'no longer keeps a waiting watcher or the session-start report waiting for it' {
        $run = Invoke-Watch $script:closed @('-Wait')
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'no active posse tasks and no published pull request waiting to be merged'
        $start = Invoke-DeputyScript -InstallRoot $script:closed.Install -Script 'dep-session-start.ps1'
        $start.Output | Should -Match 'Watcher: not running \(no active tasks\)\.'
    }

    It 'raises the wake exactly once across several polls' {
        foreach ($poll in 1..3) {
            Set-PollDue $script:closed
            $run = Invoke-Watch $script:closed
            $run.Output | Should -Match 'no new events'
            $run.Output | Should -Not -Match '\[wake\]'
        }
        (Get-WakeQueue $script:closed).Count | Should -Be 1
        # It is still being read, which is how a reopening is noticed.
        @(Get-GhCalls -Path $script:closed.Shim).Count | Should -BeGreaterThan 3
    }

    It 'watches a reopened pull request again' {
        Set-PullRequest $script:closed (New-PullRequestJson -HeadSha $script:head) $script:green
        Set-PollDue $script:closed
        (Invoke-Watch $script:closed).Output | Should -Match 'no new events'
        (Get-State $script:closed).prClosedAt | Should -BeNullOrEmpty
        # It counts as work for the watcher again.
        $guard = Invoke-StopGuard $script:closed
        $guard.ExitCode | Should -Be 2
        $guard.ErrorOutput | Should -Match '1 published pull request\(s\) are waiting to be merged'
    }

    It 'still raises degraded and merged for the reopened pull request, and closed again if it is closed again' {
        Set-PullRequest $script:closed (New-PullRequestJson -HeadSha $script:head) $script:red
        Set-PollDue $script:closed
        (Invoke-Watch $script:closed).Output | Should -Match ': degraded \(ship\) seq=2'

        Set-PullRequest $script:closed (New-PullRequestJson -State closed -HeadSha $script:head)
        Set-PollDue $script:closed
        (Invoke-Watch $script:closed).Output | Should -Match ': closed \(ship\) seq=3'

        Set-PullRequest $script:closed (New-PullRequestJson -Merged -HeadSha $script:head)
        Set-PollDue $script:closed
        (Invoke-Watch $script:closed).Output | Should -Match ': merged \(ship\) seq=4'
        (Get-WakeQueue $script:closed).Count | Should -Be 4
    }

    It 'does not hold a watcher that was waiting on it: -Wait wakes with closed and exits' {
        $s = New-PrWatchScenario
        $watcher = Start-TestWatcher -InstallRoot $s.Install -Arguments @('-IntervalSeconds', '1', '-PrPollSeconds', '1')
        $script:watchers.Add($watcher.Process)
        Set-PullRequest $s (New-PullRequestJson -State closed -HeadSha $script:head)
        Wait-TestProcessExit -Process $watcher.Process -TimeoutSeconds 60 | Should -BeTrue
        Get-Content $watcher.OutFile -Raw | Should -Match ': closed \(ship\)'
        # And the next one has nothing to wait for.
        (Invoke-Watch $s @('-Wait')).Output | Should -Match 'no active posse tasks and no published pull request'
    }
}

Describe 'dep-watch.ps1 and a pull request with nothing to report' {
    It 'raises nothing for <Name>' -ForEach @(
        @{ Name = 'an open pull request whose checks are green'; Pr = @{}; Runs = @(@{ name = 'test'; conclusion = 'success' }) }
        @{ Name = 'an open pull request whose checks are still running'; Pr = @{}; Runs = @(@{ name = 'test'; status = 'in_progress' }) }
        @{ Name = 'an open pull request with no checks at all'; Pr = @{}; Runs = @() }
    ) {
        $s = New-PrWatchScenario -PullRequest (New-PullRequestJson @Pr -HeadSha $script:head) -Runs $Runs
        $run = Invoke-Watch $s
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'no new events'
        (Get-WakeQueue $s).Count | Should -Be 0
        $state = Get-State $s
        $state.PSObject.Properties['mergedAt'] | Should -BeNullOrEmpty
        # The read happened, and the next one is an interval away.
        $state.prCheckedAt | Should -Not -BeNullOrEmpty
        @(Get-GhCalls -Path $s.Shim).Count | Should -BeGreaterThan 0
    }

    It 'is silent when the lookup fails: <Name>' -ForEach @(
        @{ Name = 'the pull request answers 404'; Route = @{ status = 404; body = @{ message = 'Not Found' } } }
        @{ Name = 'GitHub answers 500'; Route = @{ status = 500; body = @{ message = 'Server Error' } } }
        @{ Name = 'gh gets no answer at all'; Route = @{ fail = 'error connecting to api.github.com' } }
        @{ Name = 'the answer is not a pull request'; Route = @{ body = @{ message = 'something else entirely' } } }
    ) {
        $s = New-PrWatchScenario
        Set-GhRoutes -Path $s.Shim -Routes @{ "GET $script:api/pulls/7" = $Route }
        $run = Invoke-Watch $s
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'no new events'
        $run.Output | Should -Not -Match '\[wake\]'
        (Get-WakeQueue $s).Count | Should -Be 0
        # Never read as a merge.
        $state = Get-State $s
        $state.PSObject.Properties['mergedAt'] | Should -BeNullOrEmpty
        $state.PSObject.Properties['mergeSha'] | Should -BeNullOrEmpty
    }

    It 'is silent when the checks cannot be read' {
        $s = New-PrWatchScenario -Runs $script:red
        Set-GhRoutes -Path $s.Shim -Routes @{ "GET $script:api/pulls/7" = @{ body = (New-PullRequestJson -HeadSha $script:head) } }
        (Invoke-Watch $s).Output | Should -Match 'no new events'
        (Get-WakeQueue $s).Count | Should -Be 0
        (Get-State $s).PSObject.Properties['prDegradedHead'] | Should -BeNullOrEmpty
    }
}

Describe 'dep-watch.ps1 poll cadence' {
    It 'does not read a pull request that was read within the interval' {
        $s = New-PrWatchScenario -CheckedNow -PullRequest (New-PullRequestJson -Merged -HeadSha $script:head)
        (Invoke-Watch $s).Output | Should -Match 'no new events'
        @(Get-GhCalls -Path $s.Shim).Count | Should -Be 0
        (Get-WakeQueue $s).Count | Should -Be 0
    }

    It 'reads it again once the interval has passed' {
        $s = New-PrWatchScenario -CheckedNow -PullRequest (New-PullRequestJson -Merged -HeadSha $script:head)
        Start-Sleep -Seconds 2
        (Invoke-Watch $s @('-PrPollSeconds', '1')).Output | Should -Match ': merged \(ship\)'
    }

    It 'takes the interval from prPollMinutes in the config' {
        $s = New-PrWatchScenario -Config @{ prPollMinutes = 120 } -PullRequest (New-PullRequestJson -Merged -HeadSha $script:head) `
            -Extra @{ prCheckedAt = (Get-Date).AddHours(-1).ToString('o') }
        (Invoke-Watch $s).Output | Should -Match 'no new events'
        Set-StateField $s @{ prCheckedAt = (Get-Date).AddHours(-3).ToString('o') }
        (Invoke-Watch $s).Output | Should -Match ': merged \(ship\)'
    }

    It 'does not poll at all when prPollMinutes is 0' {
        $s = New-PrWatchScenario -Config @{ prPollMinutes = 0 } -PullRequest (New-PullRequestJson -Merged -HeadSha $script:head)
        (Invoke-Watch $s).Output | Should -Match 'no new events'
        @(Get-GhCalls -Path $s.Shim).Count | Should -Be 0
        # And with nothing to watch, a waiting watcher goes home.
        (Invoke-Watch $s @('-Wait')).Output | Should -Match 'no active posse tasks and no published pull request'
    }
}

Describe 'dep-watch.ps1 -Wait with an open pull request' {
    It 'keeps watching until the pull request is merged, then wakes' {
        $s = New-PrWatchScenario
        $watcher = Start-TestWatcher -InstallRoot $s.Install -Arguments @('-IntervalSeconds', '1', '-PrPollSeconds', '1')
        $script:watchers.Add($watcher.Process)

        # Open and green: nothing to say, and nothing to go home for.
        Start-Sleep -Seconds 4
        $watcher.Process.HasExited | Should -BeFalse
        (Get-WakeQueue $s).Count | Should -Be 0

        Set-PullRequest $s (New-PullRequestJson -Merged -HeadSha $script:head)
        Wait-TestProcessExit -Process $watcher.Process -TimeoutSeconds 60 | Should -BeTrue
        $watcher.Process.ExitCode | Should -Be 0
        Get-Content $watcher.OutFile -Raw | Should -Match ': merged \(ship\)'
        (Get-WakeQueue $s)[0].event | Should -Be 'merged'
    }

    It 'exits at once when no task is active and no pull request is waiting' {
        $s = New-PrWatchScenario -Extra @{ mergedAt = '2026-01-02T03:04:05Z' }
        $run = Invoke-Watch $s @('-Wait')
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'no active posse tasks and no published pull request waiting to be merged'
    }
}

Describe 'the stop guard and an open pull request' {
    It 'blocks the stop when a published pull request is waiting and nothing watches' {
        $s = New-PrWatchScenario
        $run = Invoke-DeputyHook -InstallRoot $s.Install -Script 'dep-hook-guard.ps1' -Arguments @('-GraceSeconds', '0')
        $run.ExitCode | Should -Be 2
        $run.ErrorOutput | Should -Match '^Deputy stop guard \(1/3\): 1 published pull request\(s\) are waiting to be merged and no watcher is running\.'
    }

    It 'lets the stop through once the pull request is merged' {
        $s = New-PrWatchScenario -Extra @{ mergedAt = '2026-01-02T03:04:05Z' }
        $run = Invoke-DeputyHook -InstallRoot $s.Install -Script 'dep-hook-guard.ps1' -Arguments @('-GraceSeconds', '0')
        $run.ExitCode | Should -Be 0
        $run.ErrorOutput.Trim() | Should -BeNullOrEmpty
    }

    It 'says so in the session-start report' {
        $s = New-PrWatchScenario
        $run = Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-session-start.ps1'
        $run.Output | Should -Match 'Watcher: no watcher is running, and 1 published pull request\(s\) are waiting to be merged\.'
    }
}
