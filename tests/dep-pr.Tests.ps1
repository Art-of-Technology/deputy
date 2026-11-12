#Requires -Version 7.0
<#
.SYNOPSIS
Tests for the pull request side of the toolbelt, run as real processes against
a throwaway Deputy install and a fake gh that goes first on PATH:

- dep-pr.ps1 view, checks and diff read over REST (`gh api`) only;
- dep-pr.ps1 merge refuses a pull request that is not fit to merge, names every
  failing condition, and records a merge only when it is proven;
- dep-publish.ps1 records the PR's number and head, and pushes a follow-up's
  new validated commits to the PR that is already open.

The regressions these pin down: `dep-pr.ps1 merge` used to merge whatever state
CI was in, the reads needed a token scope the supervisor often lacks, and a
follow-up sent after publishing never reached the pull request.
#>

BeforeAll {
    $script:sourceRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:root = New-TempRoot
    $script:n = 0
    $script:savedPath = $env:PATH
    $script:prUrl = 'https://github.com/acme/widgets/pull/7'
    $script:api = 'repos/acme/widgets'
    $script:head = 'a' * 40
    $script:green = @(@{ name = 'lint'; conclusion = 'success' }, @{ name = 'test'; conclusion = 'success' })

    function New-PrScenario {
        <#
        .SYNOPSIS
        A published ship task in a throwaway install - its worktree already
        gone, as after a return - and a fake gh holding its pull request.
        #>
        param(
            $PullRequest = (New-PullRequestJson -HeadSha $script:head),
            [hashtable[]]$Runs = $script:green,
            [hashtable[]]$Statuses = @(),
            $Protection,
            # The head recorded at publish; '' for a task that has none.
            [string]$PrHead = $script:head,
            # Register the task as returned (archived).
            [switch]$Archived
        )
        $script:n++
        $dir = Join-Path $script:root "case$($script:n)"
        $install = New-DeputyInstall -Path (Join-Path $dir 'deputy') -SourceRoot $script:sourceRoot
        $gone = Join-Path $dir 'no-such-worktree'
        $id = New-TestTaskState -InstallRoot $install -Repo $gone -Worktree $gone -Branch 'deputy/task'
        $statePath = Join-Path $install 'state' "$id.json"
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        $state | Add-Member -NotePropertyName 'prUrl' -NotePropertyValue $script:prUrl
        $state | Add-Member -NotePropertyName 'prNumber' -NotePropertyValue 7
        if ($PrHead) { $state | Add-Member -NotePropertyName 'prHead' -NotePropertyValue $PrHead }
        ($state | ConvertTo-Json -Depth 6) | Set-Content -Path $statePath -Encoding utf8
        if ($Archived) {
            $archive = Join-Path $install 'state' 'archive'
            New-Item -ItemType Directory -Force $archive | Out-Null
            Move-Item $statePath (Join-Path $archive "$id.json")
            $statePath = Join-Path $archive "$id.json"
        }

        $shim = New-GhShim -Path (Join-Path $dir 'shims')
        $routes = New-PrRoutes -PullRequest $PullRequest -Runs $Runs -Statuses $Statuses -Protection $Protection
        Set-GhRoutes -Path $shim -Routes $routes
        $env:PATH = $shim + [System.IO.Path]::PathSeparator + $script:savedPath

        [pscustomobject]@{ Install = $install; Id = $id; Shim = $shim; Routes = $routes; StatePath = $statePath }
    }

    function Invoke-Pr($Scenario, [string]$Action, [string[]]$Arguments = @()) {
        Invoke-DeputyScript -InstallRoot $Scenario.Install -Script 'dep-pr.ps1' `
            -Arguments (@($Action, $Scenario.Id) + $Arguments)
    }

    function Get-RecordedState($Scenario) {
        Get-Content $Scenario.StatePath -Raw | ConvertFrom-Json
    }

    function Get-MergeCalls($Scenario) {
        , @(Get-GhCalls -Path $Scenario.Shim | Where-Object { $_.method -eq 'PUT' })
    }

    function Add-MergeRoute($Scenario, [switch]$WithoutEffect, [int]$Status = 200) {
        # The merge endpoint. By default the merge takes: the next read of the
        # pull request shows it merged.
        $route = @{ status = $Status; body = @{ merged = ($Status -eq 200); message = 'Pull Request successfully merged' } }
        if ($Status -ne 200) { $route.body = @{ message = 'Head branch was modified. Review and try the merge again.' } }
        elseif (-not $WithoutEffect) {
            $route.then = @{
                "GET $script:api/pulls/7" = @{ body = (New-PullRequestJson -Merged -HeadSha $script:head -MergeSha ('c' * 40)) }
            }
        }
        $Scenario.Routes["PUT $script:api/pulls/7/merge"] = $route
        Set-GhRoutes -Path $Scenario.Shim -Routes $Scenario.Routes
    }
}

AfterAll {
    $env:PATH = $script:savedPath
    if ($script:root) { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }
}

Describe 'dep-pr.ps1 reads over REST' {
    It 'view shows the pull request, and says whether its head is the published one' {
        $s = New-PrScenario
        $run = Invoke-Pr $s 'view'
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match '#7 Fixture pull request'
        $run.Output | Should -Match 'state:\s+open'
        $run.Output | Should -Match 'branch:\s+deputy/task -> main'
        $run.Output | Should -Match "head:\s+$script:head\s+\(is the head Deputy recorded at publish\)"
        $run.Output | Should -Match 'mergeable:\s+yes'
        $run.Output | Should -Match 'Fixture body\.'
    }

    It 'view flags a head that is not the published one' {
        $s = New-PrScenario -PrHead ('b' * 40)
        (Invoke-Pr $s 'view').Output | Should -Match 'DIFFERS from the head Deputy recorded at publish'
    }

    It 'view, checks and diff use nothing but gh api' {
        $s = New-PrScenario
        foreach ($action in 'view', 'checks', 'diff') { $null = Invoke-Pr $s $action }
        $calls = @(Get-GhCalls -Path $s.Shim)
        $calls.Count | Should -BeGreaterThan 3
        @($calls | Where-Object { $_.kind -ne 'api' }).Count | Should -Be 0
        @($calls | Where-Object { $_.method -ne 'GET' }).Count | Should -Be 0
    }

    It 'checks lists check runs and commit statuses at the head and exits 0 when all are successful' {
        $s = New-PrScenario -Statuses @(@{ context = 'ci/external'; state = 'success' })
        $run = Invoke-Pr $s 'checks'
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match "checks of #7 at $script:head"
        $run.Output | Should -Match 'PASS\s+lint'
        $run.Output | Should -Match 'PASS\s+ci/external'
        $run.Output | Should -Match '3 successful, 0 failing, 0 pending'
    }

    It 'checks exits 1 when a check is failing' {
        $s = New-PrScenario -Runs @(@{ name = 'lint'; conclusion = 'success' }, @{ name = 'test'; conclusion = 'failure' })
        $run = Invoke-Pr $s 'checks'
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'FAIL\s+test \(failure\)'
        $run.Output | Should -Match '1 successful, 1 failing, 0 pending'
    }

    It 'checks exits 8 when nothing is failing but a check is pending' {
        $s = New-PrScenario -Runs @(@{ name = 'lint'; conclusion = 'success' }, @{ name = 'test'; status = 'in_progress' })
        $run = Invoke-Pr $s 'checks'
        $run.ExitCode | Should -Be 8
        $run.Output | Should -Match 'WAIT\s+test \(in_progress\)'
    }

    It 'checks counts a skipped or neutral run as successful' {
        $s = New-PrScenario -Runs @(@{ name = 'docs'; conclusion = 'skipped' }, @{ name = 'advice'; conclusion = 'neutral' })
        $run = Invoke-Pr $s 'checks'
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match '2 successful, 0 failing, 0 pending'
    }

    It 'checks says so when no checks are reported' {
        $s = New-PrScenario -Runs @()
        $run = Invoke-Pr $s 'checks'
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'no checks are reported at this commit'
    }

    It 'diff prints the diff GitHub returns' {
        $s = New-PrScenario
        $s.Routes["GET $script:api/pulls/7"].text = "diff --git a/work.txt b/work.txt`n+task work"
        Set-GhRoutes -Path $s.Shim -Routes $s.Routes
        $run = Invoke-Pr $s 'diff'
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'diff --git a/work\.txt b/work\.txt'
        $last = @(Get-GhCalls -Path $s.Shim)[-1]
        $last.headers | Should -Contain 'Accept: application/vnd.github.diff'
    }

    It 'fails, and says why, when the pull request cannot be read' {
        $s = New-PrScenario
        Set-GhRoutes -Path $s.Shim -Routes @{}
        $run = Invoke-Pr $s 'view'
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match 'Pull request #7 of acme/widgets could not be read: HTTP 404'
    }
}

Describe 'dep-pr.ps1 merge refuses' {
    It 'refuses <Name>' -ForEach @(
        @{
            Name = 'a pull request that was closed'; Problem = 'it is not open \(state: closed\)'
            Pr = @{ State = 'closed' }
        }
        @{
            Name = 'a draft'; Problem = 'it is a draft'
            Pr = @{ Draft = $true }
        }
        @{
            Name = 'a pull request with conflicts'; Problem = 'it has conflicts with main'
            Pr = @{ Mergeable = 'false'; MergeableState = 'dirty' }
        }
        @{
            Name = 'a pull request whose mergeability GitHub has not computed'; Problem = 'has not finished computing'
            Pr = @{ Mergeable = 'null'; MergeableState = 'unknown' }
        }
        @{
            Name = 'a failing check'; Problem = "check 'test' is not successful at a{10}: failure"
            Options = @{ Runs = @(@{ name = 'lint'; conclusion = 'success' }, @{ name = 'test'; conclusion = 'failure' }) }
        }
        @{
            Name = 'a check that is still running'; Problem = "check 'test' is not successful at a{10}: in_progress"
            Options = @{ Runs = @(@{ name = 'test'; status = 'in_progress' }) }
        }
        @{
            Name = 'a commit status that is not successful'; Problem = "check 'ci/external' is not successful at a{10}: error"
            Options = @{ Statuses = @(@{ context = 'ci/external'; state = 'error' }) }
        }
        @{
            Name = 'no checks when the base branch requires some'; Problem = 'no checks are reported at a{10}, and main requires: test, lint'
            Options = @{
                Runs       = @()
                Protection = @{ required_status_checks = @{ contexts = @('test'); checks = @(@{ context = 'test' }, @{ context = 'lint' }) } }
            }
        }
        @{
            Name = 'no checks when the branch protection answers 404'; Problem = 'branch protection of main could not be read \(HTTP 404.*pass -AllowNoChecks'
            Options = @{ Runs = @(); Protection = 404 }
        }
        @{
            Name = 'no checks when the branch protection answers 403'; Problem = 'branch protection of main could not be read \(HTTP 403.*pass -AllowNoChecks'
            Options = @{ Runs = @(); Protection = 403 }
        }
        @{
            Name = 'a head that differs from the one recorded at publish'; Problem = 'its head is a{10}, not b{10}, the head Deputy recorded at publish'
            Options = @{ PrHead = ('b' * 40) }
        }
        @{
            Name = 'a task with no recorded head and no worktree'; Problem = 'no head commit was recorded for this task'
            Options = @{ PrHead = '' }
        }
    ) {
        # Fixtures are built here, not in the case list: the helpers do not
        # exist yet when Pester discovers the cases.
        $scenarioOptions = @{}
        if ($Options) { $scenarioOptions += $Options }
        if ($Pr) { $scenarioOptions.PullRequest = New-PullRequestJson @Pr -HeadSha $script:head }
        $s = New-PrScenario @scenarioOptions
        Add-MergeRoute $s
        $run = Invoke-Pr $s 'merge' @('-RetrySeconds', '0')
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'REFUSED to merge #7'
        $run.Output | Should -Match $Problem
        $run.Output | Should -Match 'Nothing was merged'
        # The merge was never attempted, and nothing was recorded.
        (Get-MergeCalls $s).Count | Should -Be 0
        (Get-RecordedState $s).PSObject.Properties['mergedAt'] | Should -BeNullOrEmpty
    }

    It 'reports every failing condition, not just the first' {
        $s = New-PrScenario -PrHead ('b' * 40) `
            -PullRequest (New-PullRequestJson -Draft -Mergeable false -MergeableState dirty -HeadSha $script:head) `
            -Runs @(@{ name = 'lint'; conclusion = 'failure' }, @{ name = 'test'; status = 'queued' })
        Add-MergeRoute $s
        $run = Invoke-Pr $s 'merge'
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'REFUSED to merge #7 .*: 5 condition\(s\) failed'
        $run.Output | Should -Match 'it is a draft'
        $run.Output | Should -Match 'it has conflicts with main'
        $run.Output | Should -Match 'its head is a{10}, not b{10}'
        $run.Output | Should -Match "check 'lint' is not successful"
        $run.Output | Should -Match "check 'test' is not successful"
        (Get-MergeCalls $s).Count | Should -Be 0
    }

    It 'refuses when the checks cannot be read at all' {
        $s = New-PrScenario
        $s.Routes.Remove("GET $script:api/commits/$script:head/check-runs")
        Add-MergeRoute $s
        $run = Invoke-Pr $s 'merge'
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'its checks at a{10} could not be read'
        (Get-MergeCalls $s).Count | Should -Be 0
    }

    It 'does not let -AllowNoChecks override a protection that was read and requires checks' {
        $s = New-PrScenario -Runs @() -Protection @{ required_status_checks = @{ contexts = @('test') } }
        Add-MergeRoute $s
        $run = Invoke-Pr $s 'merge' @('-AllowNoChecks')
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'main requires: test'
        (Get-MergeCalls $s).Count | Should -Be 0
    }
}

Describe 'dep-pr.ps1 merge' {
    Context 'a green pull request at the published head' {
        BeforeAll {
            $script:ok = New-PrScenario
            Add-MergeRoute $script:ok
            $script:okRun = Invoke-Pr $script:ok 'merge'
        }

        It 'merges it' {
            $script:okRun.ExitCode | Should -Be 0
            $script:okRun.Output | Should -Match ('merged #7 \(squash\) as ' + ('c' * 40))
            $script:okRun.Output | Should -Match 'dep-return\.ps1'
        }

        It 'merges over REST and names the head commit it expects' {
            $merges = Get-MergeCalls $script:ok
            $merges.Count | Should -Be 1
            $merges[0].endpoint | Should -Be "$script:api/pulls/7/merge"
            $merges[0].input.sha | Should -Be $script:head
            $merges[0].input.merge_method | Should -Be 'squash'
            @(Get-GhCalls -Path $script:ok.Shim | Where-Object { $_.kind -ne 'api' }).Count | Should -Be 0
        }

        It 'records mergedAt and mergeSha from the pull request it read back' {
            $state = Get-RecordedState $script:ok
            $state.mergeSha | Should -Be ('c' * 40)
            ([datetime]$state.mergedAt).ToUniversalTime() | Should -Be ([datetime]::new(2026, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc))
        }
    }

    It 'passes the chosen merge method on' {
        $s = New-PrScenario
        Add-MergeRoute $s
        (Invoke-Pr $s 'merge' @('-Method', 'rebase')).ExitCode | Should -Be 0
        (Get-MergeCalls $s)[0].input.merge_method | Should -Be 'rebase'
    }

    It 'records nothing when the merge call reports success but the pull request is not merged' {
        $s = New-PrScenario
        Add-MergeRoute $s -WithoutEffect
        $run = Invoke-Pr $s 'merge' @('-RetrySeconds', '0')
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match "MERGE NOT PROVEN for #7: the merge call reported success, and the PR is still 'open'"
        (Get-RecordedState $s).PSObject.Properties['mergedAt'] | Should -BeNullOrEmpty
        (Get-RecordedState $s).PSObject.Properties['mergeSha'] | Should -BeNullOrEmpty
    }

    It 'records nothing when GitHub refuses the merge because the head moved' {
        $s = New-PrScenario
        Add-MergeRoute $s -Status 409
        $run = Invoke-Pr $s 'merge' @('-RetrySeconds', '0')
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'MERGE NOT PROVEN for #7: the merge call failed \(HTTP 409: Head branch was modified'
        (Get-RecordedState $s).PSObject.Properties['mergedAt'] | Should -BeNullOrEmpty
    }

    It 'merges a pull request with no checks when the protection was read and requires none' {
        $s = New-PrScenario -Runs @() -Protection @{ required_pull_request_reviews = @{ required_approving_review_count = 0 } }
        Add-MergeRoute $s
        $run = Invoke-Pr $s 'merge'
        $run.ExitCode | Should -Be 0
        (Get-MergeCalls $s).Count | Should -Be 1
    }

    It 'merges a pull request with no checks and unreadable protection only with -AllowNoChecks' {
        $s = New-PrScenario -Runs @() -Protection 404
        Add-MergeRoute $s
        $run = Invoke-Pr $s 'merge' @('-AllowNoChecks')
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'WARNING: no checks are reported, and the branch protection of main could not be read'
        (Get-RecordedState $s).mergeSha | Should -Be ('c' * 40)
    }

    It 'records a pull request that is already merged, without merging again' {
        $s = New-PrScenario -PullRequest (New-PullRequestJson -Merged -HeadSha $script:head -MergeSha ('d' * 40))
        Add-MergeRoute $s
        $run = Invoke-Pr $s 'merge'
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match '#7 is already merged'
        (Get-MergeCalls $s).Count | Should -Be 0
        (Get-RecordedState $s).mergeSha | Should -Be ('d' * 40)
    }

    It 'keeps what another process wrote to the record while the merge was in flight' {
        # The regression: merge wrote back the whole record it had read at the
        # start, so anything the watcher recorded during the reads and the
        # merge call was silently undone. Here the "watcher" writes while
        # GitHub answers the merge call - after the read, before the write.
        $s = New-PrScenario
        Add-MergeRoute $s
        $s.Routes["PUT $script:api/pulls/7/merge"].patchFile = @{
            path   = $s.StatePath
            fields = @{ prDegradedHead = ('e' * 40); prCheckedAt = '2026-03-04T05:06:07Z'; status = 'running' }
        }
        Set-GhRoutes -Path $s.Shim -Routes $s.Routes
        (Invoke-Pr $s 'merge').ExitCode | Should -Be 0
        $state = Get-RecordedState $s
        $state.mergeSha | Should -Be ('c' * 40)
        $state.mergedAt | Should -Not -BeNullOrEmpty
        $state.prDegradedHead | Should -Be ('e' * 40)
        $state.prCheckedAt | Should -Not -BeNullOrEmpty
        $state.status | Should -Be 'running'
        # And nothing else of the record was dropped on the way.
        $state.prHead | Should -Be $script:head
        $state.branch | Should -Be 'deputy/task'
    }

    It 'writes the record of a returned task back to the archive' {
        $s = New-PrScenario -Archived
        Add-MergeRoute $s
        (Invoke-Pr $s 'merge').ExitCode | Should -Be 0
        (Get-RecordedState $s).mergeSha | Should -Be ('c' * 40)
        Join-Path $s.Install 'state' "$($s.Id).json" | Should -Not -Exist
    }
}

Describe 'dep-publish.ps1 and the pull request' {
    BeforeAll {
        function New-PublishScenario {
            # A finished, validated ship task with a real (local, bare) origin,
            # and a fake gh that "opens" pull request #7. -Delivery is the
            # delivery mode its record says.
            param([string]$Delivery = 'gated')
            $script:n++
            $dir = Join-Path $script:root "case$($script:n)"
            $repo = New-TestRepo -Path (Join-Path $dir 'repo') -WithRemote -TaskBranch 'deputy/task'
            $install = New-DeputyInstall -Path (Join-Path $dir 'deputy') -SourceRoot $script:sourceRoot `
                -Match (Split-Path -Leaf $repo) -Validate @('exit 0')
            $id = New-TestTaskState -InstallRoot $install -Repo $repo -Worktree $repo -Branch 'deputy/task' -Delivery $Delivery
            $shim = New-GhShim -Path (Join-Path $dir 'shims')
            Set-GhRoutes -Path $shim -Routes @{ 'pr create' = @{ url = $script:prUrl } }
            $env:PATH = $shim + [System.IO.Path]::PathSeparator + $script:savedPath
            $scenario = [pscustomobject]@{ Install = $install; Id = $id; Repo = $repo; Shim = $shim; Bare = "$repo.origin.git" }
            (Invoke-Step $scenario 'dep-validate.ps1').ExitCode | Should -Be 0
            $scenario
        }

        function Invoke-Step($Scenario, [string]$Script, [string[]]$Arguments = @()) {
            Invoke-DeputyScript -InstallRoot $Scenario.Install -Script $Script -Arguments (@($Scenario.Id) + $Arguments)
        }

        function Get-Head($Scenario) { (git -C $Scenario.Repo rev-parse HEAD).Trim() }

        function Get-RemoteHead($Scenario) {
            (& git -C $Scenario.Bare rev-parse --verify --quiet 'refs/heads/deputy/task' 2>$null | Out-String).Trim()
        }

        function Add-FollowUpWork($Scenario) {
            # What dep-send.ps1 and the member leave behind: a new commit, and
            # a gate verdict that was cleared.
            Set-RepoFile -Repo $Scenario.Repo -Path 'followup.txt' -Content "follow-up work`n"
            Invoke-Git @('-C', $Scenario.Repo, 'add', '-A')
            Invoke-Git @('-C', $Scenario.Repo, 'commit', '-q', '-m', 'follow-up work')
            $path = Join-Path $Scenario.Install 'state' "$($Scenario.Id).json"
            $state = Get-Content $path -Raw | ConvertFrom-Json
            foreach ($name in 'validation', 'validatedHead', 'validationEvidence') { $state.$name = $null }
            ($state | ConvertTo-Json -Depth 6) | Set-Content -Path $path -Encoding utf8
        }

        function Set-OpenPullRequest($Scenario, [string]$HeadSha, [string]$State = 'open') {
            Set-GhRoutes -Path $Scenario.Shim -Routes @{
                'pr create'               = @{ url = $script:prUrl }
                "GET $script:api/pulls/7"   = @{ body = (New-PullRequestJson -State $State -HeadSha $HeadSha) }
                "PATCH $script:api/pulls/7" = @{ body = (New-PullRequestJson -HeadSha $HeadSha) }
            }
        }
    }

    Context 'the first publish' {
        BeforeAll {
            $script:first = New-PublishScenario
            $script:firstRun = Invoke-Step $script:first 'dep-publish.ps1'
            $script:firstState = Get-TestTaskState -InstallRoot $script:first.Install -Id $script:first.Id
        }

        It 'pushes the branch and opens the pull request' {
            $script:firstRun.ExitCode | Should -Be 0
            $script:firstRun.Output | Should -Match "published $($script:first.Id)"
            Get-RemoteHead $script:first | Should -Be (Get-Head $script:first)
            $script:firstState.prUrl | Should -Be $script:prUrl
        }

        It 'records the pull request number and the head it was opened at' {
            $script:firstState.prNumber | Should -Be 7
            $script:firstState.prHead | Should -Be (Get-Head $script:first)
            $script:firstState.prCheckedAt | Should -Not -BeNullOrEmpty
        }
    }

    Context 'a task recorded before the rename, as delivery no-mistakes' {
        BeforeAll {
            # New-PublishScenario has already validated it, and insists the
            # gate passed.
            $script:old = New-PublishScenario -Delivery 'no-mistakes'
            $script:oldRun = Invoke-Step $script:old 'dep-publish.ps1'
        }

        It 'still publishes, and says nothing about the old name' {
            $script:oldRun.ExitCode | Should -Be 0 -Because $script:oldRun.Output
            $script:oldRun.Output | Should -Match "published $($script:old.Id)"
            $script:oldRun.Output | Should -Not -Match 'WARNING'
            Get-RemoteHead $script:old | Should -Be (Get-Head $script:old)
            @(Get-GhCalls -Path $script:old.Shim | Where-Object { $_.kind -eq 'pr create' }) | Should -HaveCount 1
        }
    }

    Context 'a follow-up after publishing' {
        BeforeAll {
            $script:again = New-PublishScenario
            (Invoke-Step $script:again 'dep-publish.ps1').ExitCode | Should -Be 0
            $script:publishedHead = Get-Head $script:again
            Add-FollowUpWork $script:again
            Set-OpenPullRequest $script:again $script:publishedHead
        }

        It 'refuses to push commits the gate has not judged' {
            $run = Invoke-Step $script:again 'dep-publish.ps1'
            $run.ExitCode | Should -Not -Be 0
            $run.Output | Should -Match "validation state ''"
            Get-RemoteHead $script:again | Should -Be $script:publishedHead
        }

        It 'pushes the new validated commits to the same pull request' {
            (Invoke-Step $script:again 'dep-validate.ps1').ExitCode | Should -Be 0
            $run = Invoke-Step $script:again 'dep-publish.ps1'
            $run.ExitCode | Should -Be 0
            $run.Output | Should -Match 'updated PR #7'
            $script:newHead = Get-Head $script:again
            $script:newHead | Should -Not -Be $script:publishedHead
            Get-RemoteHead $script:again | Should -Be $script:newHead
        }

        It 'moves the recorded head to the new commit' {
            $state = Get-TestTaskState -InstallRoot $script:again.Install -Id $script:again.Id
            $state.prHead | Should -Be $script:newHead
            $state.prUrl | Should -Be $script:prUrl
            $state.prNumber | Should -Be 7
        }

        It 'opens no second pull request, and rewrites the description of the first' {
            $calls = @(Get-GhCalls -Path $script:again.Shim)
            @($calls | Where-Object { $_.kind -eq 'pr create' }).Count | Should -Be 1
            $patch = @($calls | Where-Object { $_.method -eq 'PATCH' })
            $patch.Count | Should -Be 1
            $patch[0].endpoint | Should -Be "$script:api/pulls/7"
            # Deputy's own gate, by what it ran: never the old name, which read
            # as if the no-mistakes tool had run.
            $patch[0].input.body | Should -Match ([regex]::Escape("Validated by the Deputy's gate (the repo's test and lint commands)"))
            $patch[0].input.body | Should -Not -Match 'no-mistakes'
            $patch[0].input.body | Should -Match "Posse task: $($script:again.Id)"
        }

        It 'does nothing when the pull request is already at the head' {
            Set-OpenPullRequest $script:again $script:newHead
            $run = Invoke-Step $script:again 'dep-publish.ps1'
            $run.ExitCode | Should -Be 0
            $run.Output | Should -Match 'nothing to push: PR #7 is already at'
        }
    }

    It 'keeps what another process wrote to the record while the publish was in flight' {
        # Same hazard as the merge: the record is read, then comes a push and a
        # GitHub call. The "watcher" writes while GitHub answers the PATCH.
        $s = New-PublishScenario
        (Invoke-Step $s 'dep-publish.ps1').ExitCode | Should -Be 0
        $published = Get-Head $s
        Add-FollowUpWork $s
        (Invoke-Step $s 'dep-validate.ps1').ExitCode | Should -Be 0
        Set-GhRoutes -Path $s.Shim -Routes @{
            "GET $script:api/pulls/7"   = @{
                body      = (New-PullRequestJson -HeadSha $published)
                patchFile = @{
                    path   = (Join-Path $s.Install 'state' "$($s.Id).json")
                    fields = @{ prDegradedHead = ('e' * 40) }
                }
            }
            "PATCH $script:api/pulls/7" = @{ body = (New-PullRequestJson -HeadSha $published) }
        }
        (Invoke-Step $s 'dep-publish.ps1').ExitCode | Should -Be 0
        $state = Get-TestTaskState -InstallRoot $s.Install -Id $s.Id
        $state.prHead | Should -Be (Get-Head $s)
        $state.prDegradedHead | Should -Be ('e' * 40)
        $state.validation | Should -Be 'passed'
    }

    It 'refuses a branch that moved after the gate judged it' {
        $s = New-PublishScenario
        Set-RepoFile -Repo $s.Repo -Path 'late.txt' -Content "after the gate`n"
        Invoke-Git @('-C', $s.Repo, 'add', '-A')
        Invoke-Git @('-C', $s.Repo, 'commit', '-q', '-m', 'after the gate')
        $run = Invoke-Step $s 'dep-publish.ps1'
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match 'Refusing to publish: the branch is at \w+, but the gate judged \w+'
        Get-RemoteHead $s | Should -BeNullOrEmpty
    }

    It 'refuses to push to a pull request that is <State>' -ForEach @(
        @{ State = 'closed'; Message = 'Pull request #7 is closed, not open' }
        @{ State = 'unreadable'; Message = 'Pull request #7 could not be read \(HTTP 404' }
    ) {
        $s = New-PublishScenario
        (Invoke-Step $s 'dep-publish.ps1').ExitCode | Should -Be 0
        $published = Get-Head $s
        Add-FollowUpWork $s
        (Invoke-Step $s 'dep-validate.ps1').ExitCode | Should -Be 0
        if ($State -eq 'closed') { Set-OpenPullRequest $s $published -State closed }
        else { Set-GhRoutes -Path $s.Shim -Routes @{} }
        $run = Invoke-Step $s 'dep-publish.ps1'
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match $Message
        Get-RemoteHead $s | Should -Be $published
        (Get-TestTaskState -InstallRoot $s.Install -Id $s.Id).prHead | Should -Be $published
    }
}
