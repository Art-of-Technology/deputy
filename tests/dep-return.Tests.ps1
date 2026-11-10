#Requires -Version 7.0
<#
.SYNOPSIS
Tests for the guarded teardown: the landed test (Test-TaskLanded in
dep-lib.ps1) and dep-return.ps1 run as a real process.

The regression these pin down: dep-return.ps1 used to force-reset the worktree
and delete the remote branch whatever state the work was in, and relied on the
supervising model getting the order right every time. It now proves the work
landed first, and refuses otherwise.

Every repository is a throwaway with a local bare origin, the pull requests are
answered by a fake gh that goes first on PATH, and treehouse is a shim: nothing
here reaches GitHub or a real worktree pool.
#>

BeforeAll {
    $script:sourceRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $script:sourceRoot 'bin' 'dep-lib.ps1')
    $script:root = New-TempRoot
    $script:n = 0
    $script:savedPath = $env:PATH
    $script:prUrl = 'https://github.com/acme/widgets/pull/7'

    function New-ReturnScenario {
        <#
        .SYNOPSIS
        A finished ship task the way treehouse leaves it: a repository on its
        default branch with a bare origin, a linked worktree on the task branch
        with one commit of work, a throwaway install holding the task record,
        and the gh and treehouse shims first on PATH.
        #>
        param(
            # Push the task branch to origin, as dep-publish.ps1 does.
            [switch]$Pushed,
            # Record this pull request on the task.
            [string]$PrUrl,
            [string]$Kind = 'ship'
        )
        $script:n++
        $dir = Join-Path $script:root "case$($script:n)"
        $repo = New-TestRepo -Path (Join-Path $dir 'repo') -WithRemote -TaskBranch 'deputy/task'
        Invoke-Git @('-C', $repo, 'checkout', '-q', 'main')
        $worktree = Join-Path $dir 'worktree'
        Invoke-Git @('-C', $repo, 'worktree', 'add', '-q', $worktree, 'deputy/task')
        $worktree = (Resolve-Path $worktree).Path
        if ($Pushed) { Invoke-Git @('-C', $worktree, 'push', '-q', 'origin', 'deputy/task') }

        $install = New-DeputyInstall -Path (Join-Path $dir 'deputy') -SourceRoot $script:sourceRoot
        $id = New-TestTaskState -InstallRoot $install -Repo $repo -Worktree $worktree -Branch 'deputy/task'
        $statePath = Join-Path $install 'state' "$id.json"
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        $state.kind = $Kind
        $state | Add-Member -NotePropertyName 'leaseId' -NotePropertyValue 'lease-test'
        $state | Add-Member -NotePropertyName 'prUrl' -NotePropertyValue ($PrUrl ? $PrUrl : $null)
        ($state | ConvertTo-Json -Depth 6) | Set-Content -Path $statePath -Encoding utf8

        $shims = New-MemberShims -Path (Join-Path $dir 'shims')
        $null = New-GhShim -Path $shims
        $env:PATH = $shims + [System.IO.Path]::PathSeparator + $script:savedPath

        [pscustomobject]@{
            Install = $install; Id = $id; Repo = $repo; Worktree = $worktree; Shims = $shims
            Bare = "$repo.origin.git"
            Tip = (git -C $worktree rev-parse HEAD).Trim()
        }
    }

    function Get-ScenarioState($Scenario) {
        Get-TestTaskState -InstallRoot $Scenario.Install -Id $Scenario.Id
    }

    function Set-PullRequest($Scenario, $PullRequest) {
        Set-GhRoutes -Path $Scenario.Shims -Routes (New-PrRoutes -PullRequest $PullRequest)
    }

    function Invoke-Return($Scenario, [string[]]$Arguments = @()) {
        Invoke-DeputyScript -InstallRoot $Scenario.Install -Script 'dep-return.ps1' -Arguments (@($Scenario.Id) + $Arguments)
    }

    function Test-RemoteBranch($Scenario, [string]$Branch = 'deputy/task') {
        & git -C $Scenario.Bare rev-parse --verify --quiet "refs/heads/$Branch" 2>&1 | Out-Null
        $LASTEXITCODE -eq 0
    }

    function Test-TreehouseReturned($Scenario) {
        $log = Join-Path $Scenario.Shims 'treehouse-calls.log'
        (Test-Path $log) -and [bool](Get-Content $log | Where-Object { $_ -match '^return ' })
    }

    function Merge-OnOrigin($Scenario, [switch]$Squash) {
        # Land the pushed task branch on origin's default branch from a second
        # clone, the way GitHub does it: a squash commit, or the commits
        # themselves. GitHub then deletes the branch.
        $clone = Join-Path (Split-Path -Parent $Scenario.Repo) 'merger'
        Invoke-Git @('clone', '-q', $Scenario.Bare, $clone)
        Invoke-Git @('-C', $clone, 'config', 'user.email', 'merger@example.invalid')
        Invoke-Git @('-C', $clone, 'config', 'user.name', 'Merger')
        Invoke-Git @('-C', $clone, 'config', 'commit.gpgsign', 'false')
        if ($Squash) {
            Invoke-Git @('-C', $clone, 'merge', '-q', '--squash', 'origin/deputy/task')
            Invoke-Git @('-C', $clone, 'commit', '-q', '-m', 'task work (#7)')
        }
        else {
            Invoke-Git @('-C', $clone, 'merge', '-q', '--ff-only', 'origin/deputy/task')
        }
        Invoke-Git @('-C', $clone, 'push', '-q', 'origin', 'main')
        Invoke-Git @('-C', $clone, 'push', '-q', 'origin', '--delete', 'deputy/task')
    }

    function Add-LocalCommit($Scenario, [string]$File = 'more.txt') {
        Set-RepoFile -Repo $Scenario.Worktree -Path $File -Content "more work`n"
        Invoke-Git @('-C', $Scenario.Worktree, 'add', '-A')
        Invoke-Git @('-C', $Scenario.Worktree, 'commit', '-q', '-m', 'more work')
    }
}

AfterAll {
    $env:PATH = $script:savedPath
    if ($script:root) { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }
}

Describe 'Test-TaskLanded' {
    Context 'work that has not landed' {
        It 'refuses commits that were never pushed' {
            $s = New-ReturnScenario
            $verdict = Test-TaskLanded (Get-ScenarioState $s)
            $verdict.Landed | Should -BeFalse
            $verdict.Reason | Should -Match '1 commit\(s\) ahead of refs/remotes/origin/main are on no remote-tracking branch'
            $verdict.Reason | Should -Match 'task work'
            $verdict.Reason | Should -Match 'The task has no pull request'
            $verdict.PrState | Should -Be 'none'
        }

        It 'refuses a dirty tree: <Name>' -ForEach @(
            @{ Name = 'an untracked file'; File = 'scratch.txt' }
            @{ Name = 'a modified tracked file'; File = 'work.txt' }
        ) {
            # Pushed, so the commits are safe - and the tree alone decides.
            $s = New-ReturnScenario -Pushed
            Set-RepoFile -Repo $s.Worktree -Path $File -Content "not committed`n"
            $verdict = Test-TaskLanded (Get-ScenarioState $s)
            $verdict.Landed | Should -BeFalse
            $verdict.Reason | Should -Match 'the worktree has 1 uncommitted or untracked path\(s\)'
            $verdict.Reason | Should -Match ([regex]::Escape($File))
        }

        It 'refuses a commit made after the branch was pushed' {
            $s = New-ReturnScenario -Pushed
            Add-LocalCommit $s
            $verdict = Test-TaskLanded (Get-ScenarioState $s)
            $verdict.Landed | Should -BeFalse
            $verdict.Reason | Should -Match '1 commit\(s\) .* are on no remote-tracking branch \(oldest: \w+ more work\)'
        }

        It 'does not take a remote branch that was deleted since as proof' {
            # The local remote-tracking ref is stale: only a fetch shows it.
            $s = New-ReturnScenario -Pushed
            Invoke-Git @('-C', $s.Bare, 'update-ref', '-d', 'refs/heads/deputy/task')
            (Test-TaskLanded (Get-ScenarioState $s)).Landed | Should -BeFalse
        }

        It 'refuses when origin cannot be fetched' {
            $s = New-ReturnScenario -Pushed
            Invoke-Git @('-C', $s.Repo, 'remote', 'set-url', 'origin', (Join-Path $script:root 'no-such-remote.git'))
            $verdict = Test-TaskLanded (Get-ScenarioState $s)
            $verdict.Landed | Should -BeFalse
            $verdict.Reason | Should -Match 'origin could not be fetched'
        }

        It 'does not read an unreadable pull request as merged' {
            $s = New-ReturnScenario -PrUrl $script:prUrl
            Set-GhRoutes -Path $s.Shims -Routes @{}   # every read is a 404
            $verdict = Test-TaskLanded (Get-ScenarioState $s)
            $verdict.Landed | Should -BeFalse
            $verdict.PrState | Should -Be 'unknown'
            $verdict.Reason | Should -Match 'Pull request #7 could not be read \(HTTP 404'
        }

        It 'does not take a pull request that was closed without merging as proof' {
            $s = New-ReturnScenario -PrUrl $script:prUrl
            Set-PullRequest $s (New-PullRequestJson -State closed -HeadSha $s.Tip)
            $verdict = Test-TaskLanded (Get-ScenarioState $s)
            $verdict.Landed | Should -BeFalse
            $verdict.PrState | Should -Be 'closed'
            $verdict.Reason | Should -Match 'closed without merging'
        }
    }

    Context 'work that has landed' {
        It 'accepts a branch that was pushed, and says its remote branch is the only copy' {
            $s = New-ReturnScenario -Pushed
            $verdict = Test-TaskLanded (Get-ScenarioState $s)
            $verdict.Landed | Should -BeTrue
            $verdict.Reason | Should -Match 'every commit ahead of refs/remotes/origin/main is on a remote-tracking branch'
            $verdict.KeepRemoteBranch | Should -BeTrue
            $verdict.KeepRemoteReason | Should -Match 'only place its commits exist'
        }

        It 'accepts a fast-forward merge without asking GitHub anything' {
            # The commits themselves are on origin's default branch, and the
            # task branch is gone from the remote.
            $s = New-ReturnScenario -Pushed
            Merge-OnOrigin $s
            $verdict = Test-TaskLanded (Get-ScenarioState $s)
            $verdict.Landed | Should -BeTrue
            $verdict.KeepRemoteBranch | Should -BeFalse
            @(Get-GhCalls -Path $s.Shims).Count | Should -Be 0
        }

        It 'accepts a squash merge whose pull request head is the local HEAD' {
            # No commit of the branch is on the remote any more: only the
            # merged pull request vouches for them.
            $s = New-ReturnScenario -Pushed -PrUrl $script:prUrl
            Merge-OnOrigin $s -Squash
            Set-PullRequest $s (New-PullRequestJson -Merged -HeadSha $s.Tip)
            $verdict = Test-TaskLanded (Get-ScenarioState $s)
            $verdict.Landed | Should -BeTrue
            $verdict.PrState | Should -Be 'merged'
            $verdict.Reason | Should -Match 'pull request #7 is merged and its head \w+ contains the local HEAD'
            $verdict.KeepRemoteBranch | Should -BeFalse
        }

        It 'accepts a squash merge by tree content when the pull request head is unknown here' {
            $s = New-ReturnScenario -Pushed -PrUrl $script:prUrl
            Merge-OnOrigin $s -Squash
            Set-PullRequest $s (New-PullRequestJson -Merged -HeadSha ('1' * 40))
            $verdict = Test-TaskLanded (Get-ScenarioState $s)
            $verdict.Landed | Should -BeTrue
            $verdict.Reason | Should -Match 'is merged and the local tree is identical to refs/remotes/origin/main'
        }

        It 'refuses a squash-merged task that has local work the merge never saw' {
            $s = New-ReturnScenario -Pushed -PrUrl $script:prUrl
            $publishedTip = $s.Tip
            Merge-OnOrigin $s -Squash
            Add-LocalCommit $s
            Set-PullRequest $s (New-PullRequestJson -Merged -HeadSha $publishedTip)
            $verdict = Test-TaskLanded (Get-ScenarioState $s)
            $verdict.Landed | Should -BeFalse
            $verdict.Reason | Should -Match 'is merged, but its head \w+ does not contain the local HEAD'
        }

        It 'accepts a branch with no commits ahead of the default branch' {
            $s = New-ReturnScenario
            Invoke-Git @('-C', $s.Worktree, 'reset', '-q', '--hard', 'main')
            $verdict = Test-TaskLanded (Get-ScenarioState $s)
            $verdict.Landed | Should -BeTrue
            $verdict.Reason | Should -Match 'no commits ahead'
        }

        It 'accepts a task with nothing local left to lose' {
            $state = [pscustomobject]@{
                id = 'posse-20260101-120000-abc'; kind = 'ship'; branch = 'deputy/task'; prUrl = $null
                repo = (Join-Path $script:root 'gone-repo'); worktree = (Join-Path $script:root 'gone-worktree')
            }
            (Test-TaskLanded $state).Landed | Should -BeTrue
        }
    }

    Context 'the pull request and the remote branch' {
        It 'keeps the remote branch while the pull request is open' {
            $s = New-ReturnScenario -Pushed -PrUrl $script:prUrl
            Set-PullRequest $s (New-PullRequestJson -HeadSha $s.Tip)
            $verdict = Test-TaskLanded (Get-ScenarioState $s)
            $verdict.Landed | Should -BeTrue
            $verdict.PrState | Should -Be 'open'
            $verdict.KeepRemoteBranch | Should -BeTrue
            $verdict.KeepRemoteReason | Should -Match 'pull request #7 is still open'
        }

        It 'keeps the remote branch when the pull request cannot be read' {
            $s = New-ReturnScenario -Pushed -PrUrl $script:prUrl
            Set-GhRoutes -Path $s.Shims -Routes @{ 'GET repos/acme/widgets/pulls/7' = @{ fail = 'error connecting to api.github.com' } }
            $verdict = Test-TaskLanded (Get-ScenarioState $s)
            $verdict.Landed | Should -BeTrue
            $verdict.PrState | Should -Be 'unknown'
            $verdict.KeepRemoteBranch | Should -BeTrue
            $verdict.KeepRemoteReason | Should -Match 'may still be open'
        }
    }
}

Describe 'dep-return.ps1' {
    Context 'a ship task whose work has not landed' {
        BeforeAll {
            $script:unlanded = New-ReturnScenario
            $script:before = Get-Content (Join-Path $script:unlanded.Install 'state' "$($script:unlanded.Id).json") -Raw
            $script:unlandedRun = Invoke-Return $script:unlanded
        }

        It 'refuses with the reason and exits 1' {
            $script:unlandedRun.ExitCode | Should -Be 1
            $script:unlandedRun.Output | Should -Match 'REFUSED to return'
            $script:unlandedRun.Output | Should -Match 'on no remote-tracking branch'
            $script:unlandedRun.Output | Should -Match '-Discard'
        }

        It 'changes nothing' {
            Get-Content (Join-Path $script:unlanded.Install 'state' "$($script:unlanded.Id).json") -Raw |
                Should -BeExactly $script:before
            Test-TreehouseReturned $script:unlanded | Should -BeFalse
            (git -C $script:unlanded.Repo rev-parse --verify --quiet 'refs/heads/deputy/task') |
                Should -Be $script:unlanded.Tip
            (git -C $script:unlanded.Worktree log -1 --format=%s) | Should -Be 'task work'
        }

        It 'returns it with -Discard, and records that the work was discarded' {
            $run = Invoke-Return $script:unlanded @('-Discard')
            $run.ExitCode | Should -Be 0
            $run.Output | Should -Match 'DISCARDING unlanded work'
            Test-TreehouseReturned $script:unlanded | Should -BeTrue
            Join-Path $script:unlanded.Install 'state' "$($script:unlanded.Id).json" | Should -Not -Exist
            $archived = Get-Content (Join-Path $script:unlanded.Install 'state' 'archive' "$($script:unlanded.Id).json") -Raw |
                ConvertFrom-Json
            $archived.status | Should -Be 'returned'
            $archived.landed | Should -BeFalse
            $archived.discarded | Should -BeTrue
            $archived.landedReason | Should -Match 'on no remote-tracking branch'
        }
    }

    It 'refuses a dirty worktree' {
        $s = New-ReturnScenario -Pushed
        Set-RepoFile -Repo $s.Worktree -Path 'scratch.txt' -Content "loose`n"
        $run = Invoke-Return $s
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'REFUSED to return .* uncommitted or untracked'
        Test-TreehouseReturned $s | Should -BeFalse
    }

    Context 'a published task whose pull request is open' {
        BeforeAll {
            $script:open = New-ReturnScenario -Pushed -PrUrl $script:prUrl
            Set-PullRequest $script:open (New-PullRequestJson -HeadSha $script:open.Tip)
            $script:openRun = Invoke-Return $script:open
        }

        It 'returns the task: the commits are on the remote' {
            $script:openRun.ExitCode | Should -Be 0
            $script:openRun.Output | Should -Match 'landed: every commit ahead of'
            Test-TreehouseReturned $script:open | Should -BeTrue
            Join-Path $script:open.Install 'state' 'archive' "$($script:open.Id).json" | Should -Exist
        }

        It 'never deletes the remote branch of an open pull request' {
            $script:openRun.Output | Should -Match 'kept remote branch origin/deputy/task: pull request #7 is still open'
            Test-RemoteBranch $script:open | Should -BeTrue
        }

        It 'does not delete it with -Discard either' {
            $s = New-ReturnScenario -Pushed -PrUrl $script:prUrl
            Add-LocalCommit $s
            Set-PullRequest $s (New-PullRequestJson -HeadSha $s.Tip)
            (Invoke-Return $s).ExitCode | Should -Be 1
            $run = Invoke-Return $s @('-Discard')
            $run.ExitCode | Should -Be 0
            $run.Output | Should -Match 'kept remote branch origin/deputy/task: pull request #7 is still open'
            Test-RemoteBranch $s | Should -BeTrue
        }
    }

    It 'keeps the remote branch when it is the only copy of the commits' {
        $s = New-ReturnScenario -Pushed
        $run = Invoke-Return $s
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'kept remote branch origin/deputy/task: origin/deputy/task is the only place its commits exist'
        Test-RemoteBranch $s | Should -BeTrue
    }

    It 'deletes the remote branch of a merged pull request' {
        # Squash-merged, and the repository does not delete head branches itself.
        $s = New-ReturnScenario -Pushed -PrUrl $script:prUrl
        Merge-OnOrigin $s -Squash
        Invoke-Git @('-C', $s.Worktree, 'push', '-q', 'origin', 'deputy/task')
        Set-PullRequest $s (New-PullRequestJson -Merged -HeadSha $s.Tip)
        $run = Invoke-Return $s
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'deleted remote branch: origin/deputy/task'
        Test-RemoteBranch $s | Should -BeFalse
        $archived = Get-Content (Join-Path $s.Install 'state' 'archive' "$($s.Id).json") -Raw | ConvertFrom-Json
        $archived.landed | Should -BeTrue
        $archived.PSObject.Properties['discarded'] | Should -BeNullOrEmpty
    }

    Context 'a scout task' {
        It 'refuses when the report file does not exist' {
            $s = New-ReturnScenario -Kind scout
            $run = Invoke-Return $s
            $run.ExitCode | Should -Be 1
            $run.Output | Should -Match 'REFUSED to return .* the scout wrote no report'
            Test-TreehouseReturned $s | Should -BeFalse
        }

        It 'returns it once the report exists' {
            $s = New-ReturnScenario -Kind scout
            Set-Content -Path (Join-Path $s.Install 'state' "$($s.Id)-report.md") -Value '# findings' -Encoding utf8
            $run = Invoke-Return $s
            $run.ExitCode | Should -Be 0
            $run.Output | Should -Match 'landed: the scout report exists'
            Test-TreehouseReturned $s | Should -BeTrue
        }

        It 'returns one without a report with -Discard' {
            $s = New-ReturnScenario -Kind scout
            (Invoke-Return $s @('-Discard')).ExitCode | Should -Be 0
        }
    }
}
