#Requires -Version 7.0
<#
.SYNOPSIS
Tests for the spawn contract: what dep-spawn.ps1 establishes before a member
starts, and the briefing it gives the member.

What these pin down, one weakness each:
- branch names derived from the briefing's prose collided; a ship task's branch
  is now <branchPrefix><taskId>, and the lease creates it (treehouse get -b),
  so the member is no longer trusted to;
- a per-task base branch (-BaseBranch) is passed to treehouse as --base and
  kept in task state;
- a lease that is not an isolated worktree of its own is refused, and given
  back, before any member runs in it;
- a member working on a repository whose own instructions describe a Deputy
  (Deputy itself) was told it was the Deputy; every briefing now says it is not;
- members can be launched without the operator's personal MCP servers, skills
  and commands (memberIsolation), on the first run and on every resumed run;
- the three briefing templates are one function with a definition of done per
  delivery mode.

dep-spawn.ps1 runs as a real process against a throwaway install, with fake
claude and treehouse first on PATH. The treehouse shim leases a real linked
worktree of a throwaway repository and creates the branch it is asked for, as
treehouse does, so what the tests read back is real git state.
#>

BeforeAll {
    $script:sourceRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:sourceRoot 'bin' 'dep-lib.ps1')
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:root = New-TempRoot
    $script:n = 0
    $script:savedPath = $env:PATH

    function New-SpawnScenario {
        <#
        .SYNOPSIS
        A throwaway repository with a 'release' branch one commit ahead of
        main, a linked worktree of it standing in for the leased pool slot, a
        throwaway install, and the shims first on PATH. -LeasePath leases that
        directory instead of the worktree; -LeaseRepo leases the repository's
        own checkout, -LeaseSubdir a directory inside the worktree.
        #>
        param([string]$LeasePath, [string]$LeaseBase, [switch]$LeaseRepo, [switch]$LeaseSubdir)
        $script:n++
        $dir = Join-Path $script:root "case$($script:n)"
        $repo = New-TestRepo -Path (Join-Path $dir 'repo')
        Invoke-Git @('-C', $repo, 'checkout', '-q', '-b', 'release')
        Set-RepoFile -Repo $repo -Path 'release.txt' -Content "release work`n"
        Invoke-Git @('-C', $repo, 'add', '-A')
        Invoke-Git @('-C', $repo, 'commit', '-q', '-m', 'release work')
        Invoke-Git @('-C', $repo, 'checkout', '-q', 'main')
        $slot = Join-Path $dir 'pool-slot'
        Invoke-Git @('-C', $repo, 'worktree', 'add', '-q', '--detach', $slot, 'main')
        $slot = (Resolve-Path $slot).Path
        $lease = if ($LeasePath) { $LeasePath } elseif ($LeaseRepo) { $repo } else { $slot }
        if ($LeaseSubdir) {
            $lease = Join-Path $slot 'subdir'
            New-Item -ItemType Directory -Force $lease | Out-Null
        }
        $install = New-DeputyInstall -Path (Join-Path $dir 'deputy') -SourceRoot $script:sourceRoot
        $shims = New-MemberShims -Path (Join-Path $dir 'shims') -LeasePath $lease -LeaseBase $LeaseBase
        [pscustomobject]@{ Dir = $dir; Repo = $repo; Slot = $slot; Lease = $lease; Install = $install; Shims = $shims; Calls = 0 }
    }

    function Invoke-Spawn($Scenario, [string[]]$Arguments) {
        # Run dep-spawn.ps1; return the run, the task id, what the member was
        # given and the task record.
        $env:PATH = $Scenario.Shims + [System.IO.Path]::PathSeparator + $script:savedPath
        $run = Invoke-DeputyScript -InstallRoot $Scenario.Install -Script 'dep-spawn.ps1' `
            -Arguments (@('-Repo', $Scenario.Repo) + $Arguments)
        $id = if ($run.Output -match 'spawned (posse-\d{8}-\d{6}-[a-z]{3})') { $Matches[1] } else { $null }
        $call = $null
        $state = $null
        if ($run.ExitCode -eq 0 -and $id) {
            $Scenario.Calls++
            Wait-MemberShimCall -Path $Scenario.Shims -Count $Scenario.Calls | Should -BeTrue
            $call = (Get-MemberShimCalls -Path $Scenario.Shims)[$Scenario.Calls - 1]
            $state = Get-TestTaskState -InstallRoot $Scenario.Install -Id $id
            Wait-TestProcessGone -ProcessId $state.pid | Should -BeTrue
        }
        # Flat: the output on one line, for a long refusal. PowerShell's error
        # view wraps a thrown message at the console width, in lines that
        # start with a '|' gutter, so a phrase can be split anywhere.
        $flat = ($run.Output -replace '\r?\n\s*\|', ' ') -replace '\s+', ' '
        [pscustomobject]@{ Run = $run; Id = $id; Call = $call; State = $state; Flat = $flat }
    }

    # The treehouse shim's lease and return invocations, one line each (wrap
    # the call in @() to count or index).
    function Get-LeaseCalls($Scenario) {
        $log = Join-Path $Scenario.Shims 'treehouse-calls.log'
        if (Test-Path $log) { Get-Content $log | Where-Object { $_ -match '^get --lease' } }
    }

    function Get-ReturnCalls($Scenario) {
        $log = Join-Path $Scenario.Shims 'treehouse-calls.log'
        if (Test-Path $log) { Get-Content $log | Where-Object { $_ -match '^return ' } }
    }

    function Get-CurrentBranch([string]$Path) { (git -C $Path branch --show-current | Out-String).Trim() }
}

AfterAll {
    $env:PATH = $script:savedPath
    if ($script:root) { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }
}

Describe 'Get-TaskBranchName' {
    It 'is the branch prefix and the task id' {
        Get-TaskBranchName 'deputy/' 'posse-20261110-120000-abc' | Should -Be 'deputy/posse-20261110-120000-abc'
        Get-TaskBranchName 'team/me-' 'posse-20261110-120000-abc' | Should -Be 'team/me-posse-20261110-120000-abc'
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'a prefix git cannot use in a branch name'; Prefix = 'my prefix/'; Id = 'posse-20261110-120000-abc'; Message = '*not a valid branch name*' }
        @{ Name = 'a prefix with a double dot'; Prefix = 'a..b/'; Id = 'posse-20261110-120000-abc'; Message = '*not a valid branch name*' }
        @{ Name = 'a task id of the wrong shape'; Prefix = 'deputy/'; Id = 'fix the auth test'; Message = '*Invalid task id*' }
    ) {
        { Get-TaskBranchName $Prefix $Id } | Should -Throw $Message
    }
}

Describe 'Test-BranchName' {
    It 'accepts <Name>' -ForEach @(
        @{ Name = 'main' }
        @{ Name = 'release/2026.11' }
        @{ Name = 'deputy/posse-20261110-120000-abc' }
    ) {
        Test-BranchName $Name | Should -BeTrue
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = '' }
        @{ Name = '-b' }
        @{ Name = '--force' }
        @{ Name = 'two words' }
        @{ Name = 'a..b' }
        @{ Name = 'ends.lock' }
        @{ Name = 'trailing/' }
    ) {
        Test-BranchName $Name | Should -BeFalse
    }
}

Describe 'Get-LeaseProblems' {
    BeforeAll {
        $script:leaseRepo = New-TestRepo -Path (Join-Path $script:root 'lease-repo')
        $script:leaseSlot = Join-Path $script:root 'lease-slot'
        Invoke-Git @('-C', $script:leaseRepo, 'worktree', 'add', '-q', '-b', 'deputy/posse-20261110-120000-abc', $script:leaseSlot)
        $script:leaseSlot = (Resolve-Path $script:leaseSlot).Path
        $script:inside = Join-Path $script:leaseRepo 'subdir'
        New-Item -ItemType Directory -Force $script:inside | Out-Null
        $script:outside = Join-Path $script:root 'not-a-repo'
        New-Item -ItemType Directory -Force $script:outside | Out-Null
    }

    It 'finds nothing wrong with a linked worktree of its own on the task branch' {
        @(Get-LeaseProblems -LeasePath $script:leaseSlot -RepoPath $script:leaseRepo -Branch 'deputy/posse-20261110-120000-abc') |
            Should -HaveCount 0
    }

    It 'finds nothing wrong with a scout lease, which has no branch to be on' {
        @(Get-LeaseProblems -LeasePath $script:leaseSlot -RepoPath $script:leaseRepo) | Should -HaveCount 0
    }

    It 'accepts the lease path however its separators are written' {
        $written = ($script:leaseSlot -replace '\\', '/') + '/'
        @(Get-LeaseProblems -LeasePath $written -RepoPath $script:leaseRepo) | Should -HaveCount 0
    }

    It 'accepts a lease given as an 8.3 short path, which git prints in full' {
        # CI runners have a short %TEMP% (C:\Users\RUNNER~1\...).
        $slot = Join-Path $script:root 'pool slot with a long name'
        Invoke-Git @('-C', $script:leaseRepo, 'worktree', 'add', '-q', '--detach', $slot)
        $short = (cmd /c "for %I in (""$slot"") do @echo %~sI" | Out-String).Trim()
        if ($short -notmatch '~') { Set-ItResult -Skipped -Because 'this volume does not generate 8.3 names' }
        @(Get-LeaseProblems -LeasePath $short -RepoPath $script:leaseRepo) | Should -HaveCount 0
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'the repository''s own checkout'; Lease = 'repo'; Message = 'own checkout' }
        @{ Name = 'a directory inside the repository''s checkout'; Lease = 'inside'; Message = 'resolves .* to the worktree' }
        @{ Name = 'a directory that is in no git worktree'; Lease = 'outside'; Message = 'not inside a git worktree' }
        @{ Name = 'a path that does not exist'; Lease = 'missing'; Message = 'not a directory' }
    ) {
        $path = switch ($Lease) {
            'repo' { $script:leaseRepo }
            'inside' { $script:inside }
            'outside' { $script:outside }
            'missing' { Join-Path $script:root 'no-such-slot' }
        }
        $problems = @(Get-LeaseProblems -LeasePath $path -RepoPath $script:leaseRepo)
        $problems | Should -HaveCount 1
        $problems[0] | Should -Match $Message
    }

    It 'refuses a worktree that is not on the task branch' {
        $problems = @(Get-LeaseProblems -LeasePath $script:leaseSlot -RepoPath $script:leaseRepo -Branch 'deputy/posse-20261110-120000-xyz')
        $problems | Should -HaveCount 1
        $problems[0] | Should -Match "not on the task branch 'deputy/posse-20261110-120000-xyz'"
    }
}

Describe 'Get-MemberBriefing' {
    BeforeAll {
        $common = @{ Task = 'Fix the flaky auth test'; Worktree = 'C:\pool\1\app' }
        $script:common = $common
        $script:noMistakes = Get-MemberBriefing -Kind ship -Delivery 'no-mistakes' -Branch 'deputy/posse-20261110-120000-abc' -BaseBranch 'main' @common
        $script:directPr = Get-MemberBriefing -Kind ship -Delivery 'direct-pr' -Branch 'deputy/posse-20261110-120000-abc' -BaseBranch 'release/2' @common
        $script:scout = Get-MemberBriefing -Kind scout -ReportPath 'C:\deputy\state\posse-20261110-120000-abc-report.md' -BaseBranch 'main' @common
        $script:all = @($script:noMistakes, $script:directPr, $script:scout)
    }

    It 'opens every briefing with who the member reports to, and its task' {
        foreach ($briefing in $script:all) {
            $briefing | Should -Match '^You are a posse member reporting to the Deputy\.'
            $briefing | Should -Match 'Task:\r?\nFix the flaky auth test'
            $briefing | Should -Match ([regex]::Escape('C:\pool\1\app'))
        }
    }

    It 'tells every member that it is not the Deputy, in the sentence AGENTS.md opens with' {
        $sentence = $script:MemberRoleSentence
        $sentence | Should -Match 'is not the Deputy'
        foreach ($briefing in $script:all) { $briefing | Should -Match ([regex]::Escape($sentence)) }
        Get-Content (Join-Path $script:sourceRoot 'AGENTS.md') -Raw | Should -Match ([regex]::Escape($sentence))
    }

    It 'puts a ship member on the branch it is already on, and never asks it to create one' {
        foreach ($briefing in $script:noMistakes, $script:directPr) {
            $briefing | Should -Match 'already on your own branch deputy/posse-20261110-120000-abc'
            $briefing | Should -Match 'do not switch branches'
            $briefing | Should -Not -Match '(?i)create and switch|first create'
        }
        $script:noMistakes | Should -Match 'cut from main'
        $script:directPr | Should -Match 'cut from release/2'
    }

    It 'gives a no-mistakes member its definition of done: committed and clean, not pushed' {
        $script:noMistakes | Should -Match 'Definition of done \(no-mistakes delivery\)'
        $script:noMistakes | Should -Match 'git status is clean'
        $script:noMistakes | Should -Match 'Do NOT push and do NOT open a pull request'
        $script:noMistakes | Should -Not -Match 'prUrl'
    }

    It 'gives a direct-pr member its definition of done: a pull request against its base branch' {
        $script:directPr | Should -Match 'Definition of done \(direct-pr delivery\)'
        $script:directPr | Should -Match ([regex]::Escape('gh pr create --base release/2'))
        $script:directPr | Should -Match 'prUrl: the URL of the pull request'
        $script:directPr | Should -Not -Match 'Do NOT push'
    }

    It 'gives a scout its report path and tells it to change nothing' {
        $script:scout | Should -Match 'Assignment kind: scout'
        $script:scout | Should -Match 'Definition of done \(scout\)'
        $script:scout | Should -Match ([regex]::Escape('C:\deputy\state\posse-20261110-120000-abc-report.md'))
        $script:scout | Should -Match 'do not commit'
        $script:scout | Should -Match 'detached HEAD of main'
        $script:scout | Should -Not -Match 'deputy/posse'
    }

    It 'ends every briefing with the structured report instructions' {
        foreach ($briefing in $script:all) {
            $briefing | Should -Match 'status: "done"'
            $briefing | Should -Match 'can be resumed'
        }
    }

    It 'names the default branch generically when the base is not known' {
        $common = $script:common
        Get-MemberBriefing -Kind ship -Delivery 'no-mistakes' -Branch 'deputy/x' @common |
            Should -Match 'cut from the default branch'
    }

    It 'refuses a ship briefing with no branch or an unknown delivery mode' {
        $common = $script:common
        { Get-MemberBriefing -Kind ship -Delivery 'no-mistakes' @common } | Should -Throw '*branch*'
        { Get-MemberBriefing -Kind ship -Delivery 'yolo' -Branch 'deputy/x' @common } | Should -Throw '*yolo*'
        { Get-MemberBriefing -Kind scout @common } | Should -Throw '*report path*'
    }
}

Describe 'dep-spawn.ps1' {
    Context 'a ship task' {
        BeforeAll {
            $script:ship = New-SpawnScenario
            $script:shipSpawn = Invoke-Spawn $script:ship @('-Task', 'Fix the flaky auth test')
            $script:shipBranch = "deputy/$($script:shipSpawn.Id)"
        }

        It 'spawns' {
            $script:shipSpawn.Run.ExitCode | Should -Be 0 -Because $script:shipSpawn.Run.Output
        }

        It 'names the branch after the task id and has the lease create it' {
            $lease = @(Get-LeaseCalls $script:ship)
            $lease | Should -HaveCount 1
            $lease[0] | Should -Match ([regex]::Escape("-b $script:shipBranch"))
            $lease[0] | Should -Not -Match '--base'
            Get-CurrentBranch $script:ship.Slot | Should -Be $script:shipBranch
            $script:shipSpawn.State.branch | Should -Be $script:shipBranch
            $script:shipSpawn.Run.Output | Should -Match ([regex]::Escape("branch:   $script:shipBranch"))
        }

        It 'records no base branch for a task cut from the default branch' {
            $script:shipSpawn.State.PSObject.Properties.Name | Should -Contain 'baseBranch'
            $script:shipSpawn.State.baseBranch | Should -BeNullOrEmpty
        }

        It 'tells the member it is already on that branch, and that it is not the Deputy' {
            $stdin = $script:shipSpawn.Call.stdin
            $stdin | Should -Match ([regex]::Escape("already on your own branch $script:shipBranch"))
            $stdin | Should -Match ([regex]::Escape($script:MemberRoleSentence))
            $stdin | Should -Not -Match '(?i)first create'
        }

        It 'launches the member isolated from the operator''s MCP servers, skills and commands, and records it' {
            @($script:shipSpawn.Call.args) | Should -Contain '--strict-mcp-config'
            @($script:shipSpawn.Call.args) | Should -Contain '--disable-slash-commands'
            $script:shipSpawn.State.memberIsolation | Should -BeTrue
        }

        It 'gives a second task with the same briefing a branch of its own' {
            # The old prose-derived name was the same for both, and the second
            # member's "create a branch" then failed or landed on the first one's.
            Invoke-Git @('-C', $script:ship.Slot, 'switch', '-q', '--detach')
            $second = Invoke-Spawn $script:ship @('-Task', 'Fix the flaky auth test')
            $second.Run.ExitCode | Should -Be 0
            $second.State.branch | Should -Be "deputy/$($second.Id)"
            $second.State.branch | Should -Not -Be $script:shipBranch
            Get-CurrentBranch $script:ship.Slot | Should -Be $second.State.branch
        }
    }

    Context 'a ship task with a base branch' {
        BeforeAll {
            $script:based = New-SpawnScenario
            $script:basedSpawn = Invoke-Spawn $script:based @('-Task', 'Backport the fix', '-BaseBranch', 'release')
        }

        It 'passes the base to treehouse and cuts the branch from it' {
            $script:basedSpawn.Run.ExitCode | Should -Be 0 -Because $script:basedSpawn.Run.Output
            $lease = @(Get-LeaseCalls $script:based)
            $lease[0] | Should -Match '--base release'
            $lease[0] | Should -Match ([regex]::Escape("-b deputy/$($script:basedSpawn.Id)"))
            (git -C $script:based.Slot rev-parse HEAD).Trim() | Should -Be (git -C $script:based.Repo rev-parse release).Trim()
        }

        It 'records the base branch in task state, prints it and briefs the member with it' {
            $script:basedSpawn.State.baseBranch | Should -Be 'release'
            $script:basedSpawn.Run.Output | Should -Match 'base:     release'
            $script:basedSpawn.Call.stdin | Should -Match 'cut from release'
        }
    }

    Context 'a lease whose reported base is not the default branch' {
        It 'adopts the base treehouse cut the worktree from, and says so' {
            $s = New-SpawnScenario -LeaseBase 'release'
            $spawn = Invoke-Spawn $s @('-Task', 'Work where the pool says')
            $spawn.Run.ExitCode | Should -Be 0 -Because $spawn.Run.Output
            $spawn.State.baseBranch | Should -Be 'release'
            $spawn.Run.Output | Should -Match "base:     release \(treehouse cut the worktree from it; the default branch is main\)"
        }

        It 'records nothing when the reported base is the default branch' {
            $s = New-SpawnScenario -LeaseBase 'main'
            $spawn = Invoke-Spawn $s @('-Task', 'Work on main')
            $spawn.State.baseBranch | Should -BeNullOrEmpty
        }
    }

    Context 'a scout' {
        It 'gets a detached worktree, no branch, and the base when one is given' {
            $s = New-SpawnScenario
            $spawn = Invoke-Spawn $s @('-Task', 'Why is the release build slow?', '-Kind', 'scout', '-BaseBranch', 'release')
            $spawn.Run.ExitCode | Should -Be 0 -Because $spawn.Run.Output
            $lease = @(Get-LeaseCalls $s)
            $lease[0] | Should -Not -Match ' -b '
            $lease[0] | Should -Match '--base release'
            Get-CurrentBranch $s.Slot | Should -BeNullOrEmpty
            $spawn.State.branch | Should -BeNullOrEmpty
            $spawn.State.baseBranch | Should -Be 'release'
            $spawn.Call.stdin | Should -Match ([regex]::Escape($script:MemberRoleSentence))
        }
    }

    Context 'member isolation switched off' {
        It 'launches without the isolation flags and records that, so a resumed run matches' {
            $s = New-SpawnScenario
            Set-Content -Path (Join-Path $s.Install 'config' 'deputy.local.json') -Value '{ "memberIsolation": false }' -Encoding utf8
            $spawn = Invoke-Spawn $s @('-Task', 'Use my tools')
            @($spawn.Call.args) | Should -Not -Contain '--strict-mcp-config'
            @($spawn.Call.args) | Should -Not -Contain '--disable-slash-commands'
            $spawn.State.memberIsolation | Should -BeFalse
        }
    }

    Context 'values it must refuse before leasing anything' {
        It 'refuses <Name>' -ForEach @(
            @{ Name = 'a base branch that looks like an option'; Extra = @('-BaseBranch', '--force'); Message = 'not a valid branch name' }
            @{ Name = 'a base branch git cannot name'; Extra = @('-BaseBranch', 'a..b'); Message = 'not a valid branch name' }
        ) {
            $s = New-SpawnScenario
            $spawn = Invoke-Spawn $s (@('-Task', 'Never starts') + $Extra)
            $spawn.Run.ExitCode | Should -Not -Be 0
            $spawn.Run.Output | Should -Match $Message
            @(Get-LeaseCalls $s) | Should -HaveCount 0
            (Get-MemberShimCalls -Path $s.Shims).Count | Should -Be 0
        }

        It 'refuses a branch prefix in the config that git cannot use' {
            $s = New-SpawnScenario
            Set-Content -Path (Join-Path $s.Install 'config' 'deputy.local.json') -Value '{ "branchPrefix": "my work/" }' -Encoding utf8
            $spawn = Invoke-Spawn $s @('-Task', 'Never starts')
            $spawn.Run.ExitCode | Should -Not -Be 0
            $spawn.Run.Output | Should -Match 'not a valid branch name'
            @(Get-LeaseCalls $s) | Should -HaveCount 0
        }
    }

    Context 'a lease that is not an isolated worktree' {
        BeforeAll {
            $script:bad = New-SpawnScenario -LeasePath (Join-Path $script:root 'plain-dir')
            New-Item -ItemType Directory -Force $script:bad.Lease | Out-Null
            $script:badSpawn = Invoke-Spawn $script:bad @('-Task', 'Never starts')
        }

        It 'refuses, and says why' {
            $script:badSpawn.Run.ExitCode | Should -Not -Be 0
            $script:badSpawn.Run.Output | Should -Match 'Refusing to launch a member'
            $script:badSpawn.Run.Output | Should -Match 'not inside a git worktree'
        }

        It 'gives the lease back, guarded by its lease id and without forcing a reset' {
            $returns = @(Get-ReturnCalls $script:bad)
            $returns | Should -HaveCount 1
            $returns[0] | Should -Match ([regex]::Escape($script:bad.Lease))
            $returns[0] | Should -Match '--if-lease-id lease-test'
            $returns[0] | Should -Not -Match '--force'
            $script:badSpawn.Run.Output | Should -Match 'The lease was returned'
        }

        It 'starts no member and records no task' {
            (Get-MemberShimCalls -Path $script:bad.Shims).Count | Should -Be 0
            @(Get-ChildItem (Join-Path $script:bad.Install 'state') -Filter 'posse-*.json' -ErrorAction SilentlyContinue) |
                Should -HaveCount 0
        }

        It 'says nothing about a branch the lease never created' {
            $script:badSpawn.Run.Output | Should -Not -Match 'task branch'
        }
    }

    Context 'the branch of a lease it gives back' {
        It 'deletes the branch, and says nothing about it, when the return frees it' {
            # Refused: the lease is a directory inside the worktree. The return
            # resets the slot, as treehouse does, so the branch can go.
            $s = New-SpawnScenario -LeaseSubdir
            Set-Content -Path (Join-Path $s.Shims 'return-detaches') -Value '' -Encoding ascii
            $spawn = Invoke-Spawn $s @('-Task', 'Never starts')
            $spawn.Run.ExitCode | Should -Not -Be 0
            $spawn.Flat | Should -Match 'not to the lease itself'
            $spawn.Flat | Should -Match 'The lease was returned'
            @(Get-LeaseCalls $s)[0] | Should -Match ' -b deputy/posse-'
            (git -C $s.Repo branch --list 'deputy/*' | Out-String).Trim() | Should -BeNullOrEmpty
            $spawn.Flat | Should -Not -Match 'task branch'
        }

        It 'says when the branch is still there, names it, and gives the command that removes it' {
            # Octopus's review of #38: the cleanup used to fail without a word.
            # Here the lease is the repository's own checkout, which the lease
            # put on the new branch: refused and given back, and git cannot
            # delete a branch that is checked out.
            $s = New-SpawnScenario -LeaseRepo
            $spawn = Invoke-Spawn $s @('-Task', 'Never starts')
            $spawn.Run.ExitCode | Should -Not -Be 0
            $spawn.Flat | Should -Match 'own checkout'
            $branch = (git -C $s.Repo branch --list 'deputy/*' --format '%(refname:short)' | Out-String).Trim()
            $branch | Should -Match '^deputy/posse-\d{8}-\d{6}-[a-z]{3}$'
            $spawn.Flat | Should -Match ([regex]::Escape("The task branch $branch was NOT deleted (git said: "))
            $spawn.Flat | Should -Match ([regex]::Escape("git -C ""$($s.Repo)"" branch -D $branch"))
        }
    }

    Context 'the model and effort it starts a member with' {
        BeforeAll {
            $script:pick = New-SpawnScenario
            $script:pickConfig = Join-Path $script:pick.Install 'config'
            $script:pickModels = '{ "models": { "ship": "config-ship-model", "scout": "config-scout-model" }, "effort": { "ship": "medium" } }'

            function Invoke-PickSpawn([string[]]$Extra = @()) {
                # Every spawn leases the same slot: take it off the last
                # task's branch first.
                Invoke-Git @('-C', $script:pick.Slot, 'switch', '-q', '--detach')
                Invoke-Spawn $script:pick (@('-Task', 'Pick a model') + $Extra)
            }

            function Get-Flag($Spawn, [string]$Flag) {
                $arguments = @($Spawn.Call.args)
                $index = [array]::IndexOf($arguments, $Flag)
                if ($index -lt 0) { return $null }
                $arguments[$index + 1]
            }
        }

        BeforeEach {
            foreach ($name in 'deputy.json', 'deputy.local.json', 'projects.local.json') {
                Remove-Item (Join-Path $script:pickConfig $name) -ErrorAction SilentlyContinue
            }
        }

        It 'takes the per-kind default from the config, records where it came from, and says so' {
            Set-Content -Path (Join-Path $script:pickConfig 'deputy.json') -Value $script:pickModels -Encoding utf8
            $spawn = Invoke-PickSpawn
            $spawn.Run.ExitCode | Should -Be 0 -Because $spawn.Run.Output
            Get-Flag $spawn '--model' | Should -Be 'config-ship-model'
            Get-Flag $spawn '--effort' | Should -Be 'medium'
            $spawn.State.model | Should -Be 'config-ship-model'
            $spawn.State.modelSource | Should -Be 'config\deputy.json models.ship'
            $spawn.State.effort | Should -Be 'medium'
            $spawn.State.effortSource | Should -Be 'config\deputy.json effort.ship'
            $spawn.State.PSObject.Properties.Name | Should -Contain 'reportedModel'
            $spawn.Run.Output | Should -Match ([regex]::Escape('model:    config-ship-model (config\deputy.json models.ship)'))
            $spawn.Run.Output | Should -Match ([regex]::Escape('effort:   medium (config\deputy.json effort.ship)'))

            $scout = Invoke-PickSpawn @('-Kind', 'scout')
            Get-Flag $scout '--model' | Should -Be 'config-scout-model'
            @($scout.Call.args) | Should -Not -Contain '--effort'
        }

        It 'lets the repo''s project entry win over the per-kind default, and -Model / -Effort over both' {
            Set-Content -Path (Join-Path $script:pickConfig 'deputy.json') -Value $script:pickModels -Encoding utf8
            Set-Content -Path (Join-Path $script:pickConfig 'projects.local.json') -Encoding utf8 `
                -Value '{ "projects": [ { "match": "repo", "model": "project-model" } ] }'
            $fromProject = Invoke-PickSpawn
            Get-Flag $fromProject '--model' | Should -Be 'project-model'
            $fromProject.State.modelSource | Should -Be "config\projects.local.json (match 'repo')"
            # The entry names no effort: the per-kind default stays.
            Get-Flag $fromProject '--effort' | Should -Be 'medium'

            $fromFlags = Invoke-PickSpawn @('-Model', 'flag-model', '-Effort', 'max')
            Get-Flag $fromFlags '--model' | Should -Be 'flag-model'
            Get-Flag $fromFlags '--effort' | Should -Be 'max'
            $fromFlags.State.modelSource | Should -Be '-Model'
        }

        It 'leaves --model off when nothing names a model, and says the member runs on the account default' {
            $spawn = Invoke-PickSpawn
            $spawn.Run.ExitCode | Should -Be 0 -Because $spawn.Run.Output
            @($spawn.Call.args) | Should -Not -Contain '--model'
            $spawn.State.model | Should -BeNullOrEmpty
            $spawn.State.modelSource | Should -Be 'account default'
            $spawn.Run.Output | Should -Match 'model:    account default \(no -Model, no project model and no models\.ship in the config\)'
        }

        It 'still reads the old flat model key, and warns about it' {
            Set-Content -Path (Join-Path $script:pickConfig 'deputy.json') -Value $script:pickModels -Encoding utf8
            Set-Content -Path (Join-Path $script:pickConfig 'deputy.local.json') -Value '{ "model": "legacy-model" }' -Encoding utf8
            $spawn = Invoke-PickSpawn
            $spawn.Run.ExitCode | Should -Be 0 -Because $spawn.Run.Output
            Get-Flag $spawn '--model' | Should -Be 'legacy-model'
            $spawn.State.modelSource | Should -Be 'config\deputy.local.json model (old flat key)'
            $spawn.Run.Output | Should -Match ([regex]::Escape('WARNING: config\deputy.local.json "model" still uses the old flat'))
        }

        It 'refuses a model name a command line would read as an option, before leasing anything' {
            $leases = @(Get-LeaseCalls $script:pick).Count
            $spawn = Invoke-Spawn $script:pick @('-Task', 'Never starts', '-Model', '--dangerously-skip-permissions')
            $spawn.Run.ExitCode | Should -Not -Be 0
            $spawn.Flat | Should -Match 'not a model name'
            @(Get-LeaseCalls $script:pick).Count | Should -Be $leases
        }
    }
}
