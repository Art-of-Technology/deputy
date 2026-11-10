#Requires -Version 7.0
<#
.SYNOPSIS
Tests for a task cut from a base branch other than the default branch
(dep-spawn.ps1 -BaseBranch, kept as baseBranch in task state): the base has to
flow through every step that measures the work against "where it started".

- dep-validate.ps1 anchors on it: "ahead of" and the manifests it reads;
- dep-publish.ps1 opens the pull request against it, and titles the PR from
  the commits ahead of it;
- Test-TaskLanded (dep-return.ps1) proves the work landed relative to it.

The scripts run as real processes against throwaway repositories with a local
bare origin and a fake gh first on PATH. Nothing reaches GitHub.
#>

BeforeAll {
    $script:sourceRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $script:sourceRoot 'bin' 'dep-lib.ps1')
    $script:root = New-TempRoot
    $script:n = 0
    $script:savedPath = $env:PATH
    $script:prUrl = 'https://github.com/acme/widgets/pull/7'

    function New-BaseScenario {
        <#
        .SYNOPSIS
        A repository with a bare origin, a 'release' branch one commit ahead of
        main (pushed unless -LocalOnlyBase), and the task branch cut from it
        with -TaskCommits commits of its own. The repository is the worktree,
        as in the gate tests. The task record names 'release' as its base.
        #>
        param([int]$TaskCommits = 1, [switch]$LocalOnlyBase, [string]$BaseBranch = 'release')
        $script:n++
        $dir = Join-Path $script:root "case$($script:n)"
        $repo = New-TestRepo -Path (Join-Path $dir 'repo') -WithRemote
        Invoke-Git @('-C', $repo, 'checkout', '-q', '-b', 'release')
        Set-RepoFile -Repo $repo -Path 'release.txt' -Content "release work`n"
        Invoke-Git @('-C', $repo, 'add', '-A')
        Invoke-Git @('-C', $repo, 'commit', '-q', '-m', 'release work')
        if (-not $LocalOnlyBase) { Invoke-Git @('-C', $repo, 'push', '-q', '-u', 'origin', 'release') }
        Invoke-Git @('-C', $repo, 'checkout', '-q', '-b', 'deputy/task')
        for ($i = 1; $i -le $TaskCommits; $i++) {
            Set-RepoFile -Repo $repo -Path "task$i.txt" -Content "task work $i`n"
            Invoke-Git @('-C', $repo, 'add', '-A')
            Invoke-Git @('-C', $repo, 'commit', '-q', '-m', "Backport the session fix, part $i")
        }

        $install = New-DeputyInstall -Path (Join-Path $dir 'deputy') -SourceRoot $script:sourceRoot `
            -Match (Split-Path -Leaf $repo) -Validate @('exit 0')
        $id = New-TestTaskState -InstallRoot $install -Repo $repo -Worktree $repo -Branch 'deputy/task' -BaseBranch $BaseBranch
        $shim = New-GhShim -Path (Join-Path $dir 'shims')
        Set-GhRoutes -Path $shim -Routes @{ 'pr create' = @{ url = $script:prUrl } }
        $env:PATH = $shim + [System.IO.Path]::PathSeparator + $script:savedPath
        [pscustomobject]@{ Install = $install; Id = $id; Repo = $repo; Shim = $shim; Bare = "$repo.origin.git" }
    }

    function Invoke-Step($Scenario, [string]$Script, [string[]]$Arguments = @()) {
        Invoke-DeputyScript -InstallRoot $Scenario.Install -Script $Script -Arguments (@($Scenario.Id) + $Arguments)
    }

    function Get-State($Scenario) { Get-TestTaskState -InstallRoot $Scenario.Install -Id $Scenario.Id }
}

AfterAll {
    $env:PATH = $script:savedPath
    if ($script:root) { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }
}

Describe 'Resolve-BaseRef' {
    BeforeAll {
        $script:refRepo = New-TestRepo -Path (Join-Path $script:root 'refs') -WithRemote
        Invoke-Git @('-C', $script:refRepo, 'branch', 'pushed')
        Invoke-Git @('-C', $script:refRepo, 'push', '-q', 'origin', 'pushed')
        Invoke-Git @('-C', $script:refRepo, 'branch', 'local-only')
    }

    It 'is the default-branch anchor when the task has no base branch' {
        $anchor = Resolve-BaseRef $script:refRepo ''
        $anchor.Ref | Should -Be (Resolve-DefaultRef $script:refRepo).Ref
        $anchor.Source | Should -Be 'origin/HEAD'
    }

    It 'prefers the remote-tracking base, as treehouse cuts from it' {
        $anchor = Resolve-BaseRef $script:refRepo 'pushed'
        $anchor.Branch | Should -Be 'pushed'
        $anchor.Ref | Should -Be 'refs/remotes/origin/pushed'
        $anchor.Health | Should -Be 'ok'
        $anchor.Source | Should -Match 'base branch'
    }

    It 'falls back to the local base when origin has none' {
        $anchor = Resolve-BaseRef $script:refRepo 'local-only'
        $anchor.Ref | Should -Be 'refs/heads/local-only'
        $anchor.Health | Should -Be 'ok'
    }

    It 'is unresolved, never the default branch, when the base is gone' {
        $anchor = Resolve-BaseRef $script:refRepo 'deleted-since'
        $anchor.Ref | Should -BeNullOrEmpty
        $anchor.Branch | Should -BeNullOrEmpty
        $anchor.Health | Should -Be 'unresolved'
        $anchor.Source | Should -Match "base branch 'deleted-since'"
    }
}

Describe 'dep-validate.ps1 on a task with a base branch' {
    It 'anchors the gate on the base branch, and says so in the evidence' {
        $s = New-BaseScenario
        $run = Invoke-Step $s 'dep-validate.ps1'
        $run.ExitCode | Should -Be 0 -Because $run.Output
        $evidence = Get-Content (Join-Path $s.Repo '.deputy' 'evidence' "$($s.Id).md") -Raw
        $evidence | Should -Match 'base-branch anchor: refs/remotes/origin/release'
        $run.Output | Should -Not -Match 'ANCHOR WARNING'
    }

    It 'denies a branch with nothing ahead of its base, though it is ahead of the default branch' {
        # Measured against main, the base's own commit would pass for the
        # member's work.
        $s = New-BaseScenario -TaskCommits 0
        $run = Invoke-Step $s 'dep-validate.ps1'
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match "no commits on 'deputy/task' ahead of refs/remotes/origin/release"
    }

    It 'warns, and names the base, when the base branch can no longer be resolved' {
        $s = New-BaseScenario -BaseBranch 'deleted-since'
        $run = Invoke-Step $s 'dep-validate.ps1'
        $run.Output | Should -Match "ANCHOR WARNING: .*base branch 'deleted-since'"
        (Get-State $s).anchorWarning | Should -Match 'deleted-since'
    }
}

Describe 'dep-publish.ps1 on a task with a base branch' {
    BeforeAll {
        $script:pub = New-BaseScenario
        (Invoke-Step $script:pub 'dep-validate.ps1').ExitCode | Should -Be 0
        $script:pubRun = Invoke-Step $script:pub 'dep-publish.ps1'
        $script:create = @(Get-GhCalls -Path $script:pub.Shim | Where-Object { $_.kind -eq 'pr create' })
    }

    It 'opens the pull request against the base branch' {
        $script:pubRun.ExitCode | Should -Be 0 -Because $script:pubRun.Output
        $script:create | Should -HaveCount 1
        $arguments = @($script:create[0].args)
        $arguments[[array]::IndexOf($arguments, '--base') + 1] | Should -Be 'release'
        $script:pubRun.Output | Should -Match 'deputy/task -> release'
    }

    It 'titles it from the one commit ahead of the base, not the two ahead of main' {
        $arguments = @($script:create[0].args)
        $arguments[[array]::IndexOf($arguments, '--title') + 1] | Should -Be 'Backport the session fix, part 1'
    }

    It 'shows the base branch in dep-posse.ps1 result' {
        $run =Invoke-DeputyScript -InstallRoot $script:pub.Install -Script 'dep-posse.ps1' -Arguments @('result', $script:pub.Id)
        $run.Output | Should -Match 'Base branch: release'
    }

    It 'refuses a base branch that origin does not have, before pushing anything' {
        $s = New-BaseScenario -LocalOnlyBase
        (Invoke-Step $s 'dep-validate.ps1').ExitCode | Should -Be 0
        $run = Invoke-Step $s 'dep-publish.ps1'
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match "base branch 'release' is not on origin"
        & git -C $s.Bare rev-parse --verify --quiet 'refs/heads/deputy/task' 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
        @(Get-GhCalls -Path $s.Shim | Where-Object { $_.kind -eq 'pr create' }) | Should -HaveCount 0
    }
}

Describe 'Test-TaskLanded on a task with a base branch' {
    It 'counts the commits ahead of the base, not of the default branch' {
        $s = New-BaseScenario
        $verdict = Test-TaskLanded (Get-State $s)
        $verdict.Landed | Should -BeFalse
        $verdict.Reason | Should -Match '1 commit\(s\) ahead of refs/remotes/origin/release are on no remote-tracking branch'
    }

    It 'has nothing to prove for a branch the base already contains' {
        $s = New-BaseScenario
        Invoke-Git @('-C', $s.Repo, 'push', '-q', 'origin', 'deputy/task:release')
        $verdict = Test-TaskLanded (Get-State $s)
        $verdict.Landed | Should -BeTrue
        $verdict.Reason | Should -Match 'no commits ahead of refs/remotes/origin/release'
    }
}
