#Requires -Version 7.0
<#
.SYNOPSIS
End-to-end tests for the gate contract: dep-validate.ps1 and dep-publish.ps1
run as real processes against a throwaway Deputy install and a throwaway repo.

The regression these pin down: a gate with no commands used to record
validation=passed and exit 0, so "nothing ran" was indistinguishable from
"everything passed".
#>

BeforeAll {
    $script:sourceRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:root = New-TempRoot
    $script:n = 0

    function New-Scenario {
        <#
        .SYNOPSIS
        A finished ship task: throwaway install (optionally with pinned gate
        commands), throwaway repo on a task branch, and registered task state.
        #>
        param([string[]]$Validate = @(), [hashtable]$RepoOptions = @{})
        $script:n++
        $dir = Join-Path $script:root "case$($script:n)"
        $repo = New-TestRepo -Path (Join-Path $dir 'repo') -TaskBranch 'deputy/task' @RepoOptions
        $install = New-DeputyInstall -Path (Join-Path $dir 'deputy') -SourceRoot $script:sourceRoot `
            -Match (Split-Path -Leaf $repo) -Validate $Validate
        $id = New-TestTaskState -InstallRoot $install -Repo $repo -Worktree $repo -Branch 'deputy/task'
        [pscustomobject]@{ Install = $install; Repo = $repo; Id = $id }
    }
}

AfterAll {
    if ($script:root) { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }
}

Describe 'dep-validate.ps1 with an empty gate' {
    BeforeAll {
        $script:empty = New-Scenario
        $script:emptyRun = Invoke-DeputyScript -InstallRoot $script:empty.Install `
            -Script 'dep-validate.ps1' -Arguments @($script:empty.Id)
    }

    It 'does not exit 0, so it cannot be read as a pass' {
        $script:emptyRun.ExitCode | Should -Be 2
    }

    It 'says loudly that nothing was verified' {
        $script:emptyRun.Output | Should -Match 'VALIDATION UNVERIFIED'
        $script:emptyRun.Output | Should -Match 'This is NOT a pass'
    }

    It 'records validation=unverified in task state, not passed' {
        $state = Get-TestTaskState -InstallRoot $script:empty.Install -Id $script:empty.Id
        $state.validation | Should -Be 'unverified'
        $state.validationNote | Should -Match 'no gate commands are configured'
    }

    It 'commits no validation evidence to the branch' {
        (git -C $script:empty.Repo log --oneline -- '.deputy/evidence') | Should -BeNullOrEmpty
    }

    It 'surfaces the outcome in dep-posse.ps1 result' {
        $run = Invoke-DeputyScript -InstallRoot $script:empty.Install -Script 'dep-posse.ps1' `
            -Arguments @('result', $script:empty.Id)
        $run.Output | Should -Match 'Gate: unverified'
        $run.Output | Should -Match 'Not a pass'
    }
}

Describe 'dep-validate.ps1 with a configured gate' {
    It 'passes and commits evidence when every command succeeds' {
        $s = New-Scenario -Validate @('Write-Output ok; exit 0')
        $run = Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-validate.ps1' -Arguments @($s.Id)
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'VALIDATION PASSED'
        $state = Get-TestTaskState -InstallRoot $s.Install -Id $s.Id
        $state.validation | Should -Be 'passed'
        $state.validationEvidence | Should -Be ".deputy/evidence/$($s.Id).md"
        (git -C $s.Repo show "HEAD:.deputy/evidence/$($s.Id).md") -join "`n" | Should -Match 'verdict: PASSED'
    }

    It 'writes evidence with the subject Get-PrTitle excludes from the PR title' {
        # Two sites have to agree on the evidence-commit subject: the commit
        # dep-validate.ps1 writes here, and the exclusion Get-PrTitle applies in
        # dep-publish.ps1. Run the real script and derive a real title, so a
        # future edit that re-hardcodes either one fails here instead of quietly
        # making the evidence commit's subject the PR title.
        . (Join-Path $script:sourceRoot 'bin' 'dep-lib.ps1')
        $s = New-Scenario -Validate @('exit 0')
        $run = Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-validate.ps1' -Arguments @($s.Id)
        $run.ExitCode | Should -Be 0
        (git -C $s.Repo log -1 --format=%s) | Should -Be (New-EvidenceCommitMessage $s.Id)
        Get-PrTitle -Worktree $s.Repo -DefaultRef 'refs/heads/main' -Briefing 'A briefing sentence. And more.' |
            Should -Be 'task work'
    }

    It 'fails when a command exits non-zero' {
        $s = New-Scenario -Validate @('Write-Output boom; exit 7')
        $run = Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-validate.ps1' -Arguments @($s.Id)
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'VALIDATION FAILED'
        (Get-TestTaskState -InstallRoot $s.Install -Id $s.Id).validation | Should -Be 'failed'
    }

    It 'clears the note from an earlier unverified run once commands are pinned' {
        $s = New-Scenario
        $first = Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-validate.ps1' -Arguments @($s.Id)
        $first.ExitCode | Should -Be 2

        $cfg = Join-Path $s.Install 'config' 'projects.json'
        $json = Get-Content $cfg -Raw | ConvertFrom-Json
        $json.projects[0].validate = @('exit 0')
        ($json | ConvertTo-Json -Depth 6) | Set-Content $cfg -Encoding utf8

        $second = Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-validate.ps1' -Arguments @($s.Id)
        $second.ExitCode | Should -Be 0
        $state = Get-TestTaskState -InstallRoot $s.Install -Id $s.Id
        $state.validation | Should -Be 'passed'
        $state.validationNote | Should -BeNullOrEmpty
    }
}

Describe 'dep-validate.ps1 preconditions' {
    It 'fails a dirty worktree even when the gate has no commands' {
        # Preconditions are real failures, and must be judged before the gate's
        # contents - otherwise an empty gate hides uncommitted work.
        $s = New-Scenario
        Set-RepoFile -Repo $s.Repo -Path 'uncommitted.txt' -Content "dirty`n"
        $run = Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-validate.ps1' -Arguments @($s.Id)
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'working tree is dirty'
        (Get-TestTaskState -InstallRoot $s.Install -Id $s.Id).validation | Should -Be 'failed'
    }

    It 'does not deny real commits when origin/HEAD is dangling' {
        # A stale origin/HEAD used to become the anchor unchecked, so the
        # ahead-of-default check compared against a missing ref, found nothing,
        # and denied work that was perfectly fine.
        $s = New-Scenario -Validate @('exit 0') -RepoOptions @{ WithRemote = $true
            DanglingOriginHead = $true
        }
        $run = Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-validate.ps1' -Arguments @($s.Id)
        $run.Output | Should -Not -Match 'no commits on'
        $run.ExitCode | Should -Be 0
        (Get-TestTaskState -InstallRoot $s.Install -Id $s.Id).validation | Should -Be 'passed'
    }

    It 'fails a branch with no commits ahead of the default branch' {
        $s = New-Scenario -Validate @('exit 0')
        git -C $s.Repo reset -q --hard main
        $run = Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-validate.ps1' -Arguments @($s.Id)
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'no commits on .* ahead of refs/heads/main'
    }
}

Describe 'dep-validate.ps1 auto-detection in a repo with no remote' {
    It 'builds a real gate from manifests on the local default branch' {
        # The end-to-end shape of the reported failure: a .NET repo with no
        # remote configured now gates on dotnet test instead of nothing.
        $s = New-Scenario -RepoOptions @{
            Files = @{ 'BackOffice.sln' = "Microsoft Visual Studio Solution File, Format Version 12.00`n" }
        }
        $run = Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-validate.ps1' -Arguments @($s.Id)
        $run.Output | Should -Match 'gate \(auto-detected from manifests on refs/heads/main'
        $run.Output | Should -Match 'dotnet test'
        $run.Output | Should -Not -Match 'VALIDATION UNVERIFIED'
        (Get-TestTaskState -InstallRoot $s.Install -Id $s.Id).validation | Should -Not -Be 'unverified'
    }
}

Describe 'dep-validate.ps1 anchor provenance' {
    # The regression: the anchor's provenance was only printed on the branch
    # where gate commands were auto-detected, so a repo that pins its commands -
    # the well-configured case - never saw a stale origin/HEAD at all.
    BeforeAll {
        $script:stale = New-Scenario -Validate @('exit 0') -RepoOptions @{ WithRemote = $true
            DanglingOriginHead = $true
        }
        $script:staleRun = Invoke-DeputyScript -InstallRoot $script:stale.Install `
            -Script 'dep-validate.ps1' -Arguments @($script:stale.Id)
    }

    It 'reports a stale origin/HEAD even though the gate commands are pinned' {
        $script:staleRun.Output | Should -Match 'gate \(configured in deputy'
        $script:staleRun.Output | Should -Match 'ANCHOR WARNING'
        $script:staleRun.Output | Should -Match 'stale origin/HEAD \(origin/renamed-away is missing\)'
        $script:staleRun.Output | Should -Match 'git remote set-head origin -a'
    }

    It 'still passes the gate: a stale anchor is a repo problem, not a branch failure' {
        $script:staleRun.ExitCode | Should -Be 0
        (Get-TestTaskState -InstallRoot $script:stale.Install -Id $script:stale.Id).validation |
            Should -Be 'passed'
    }

    It 'keeps the warning in task state and in dep-posse.ps1 result' {
        $state = Get-TestTaskState -InstallRoot $script:stale.Install -Id $script:stale.Id
        $state.anchorWarning | Should -Match 'stale'
        $run = Invoke-DeputyScript -InstallRoot $script:stale.Install -Script 'dep-posse.ps1' `
            -Arguments @('result', $script:stale.Id)
        $run.Output | Should -Match 'Anchor: .*stale origin/HEAD'
    }

    It 'records the anchor in the PR-viewable evidence' {
        $evidence = (git -C $script:stale.Repo show "HEAD:.deputy/evidence/$($script:stale.Id).md") -join "`n"
        $evidence | Should -Match 'default-branch anchor: refs/remotes/origin/main \(stale origin/HEAD'
        $evidence | Should -Match 'anchor warning: .*git remote set-head origin -a'
    }

    It 'reports an unresolved anchor with pinned commands too' {
        $s = New-Scenario -Validate @('exit 0') -RepoOptions @{ DefaultBranch = 'trunk' }
        $run = Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-validate.ps1' -Arguments @($s.Id)
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'ANCHOR WARNING: could not resolve a trusted default branch'
        (Get-TestTaskState -InstallRoot $s.Install -Id $s.Id).anchorWarning |
            Should -Match 'could not resolve a trusted default branch'
    }

    It 'says nothing about an anchor that resolved normally, but records it as evidence' {
        # Proportionate: a healthy anchor must not turn every run into noise.
        $s = New-Scenario -Validate @('exit 0') -RepoOptions @{ WithRemote = $true }
        $run = Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-validate.ps1' -Arguments @($s.Id)
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Not -Match 'ANCHOR WARNING'
        (Get-TestTaskState -InstallRoot $s.Install -Id $s.Id).anchorWarning | Should -BeNullOrEmpty
        (git -C $s.Repo show "HEAD:.deputy/evidence/$($s.Id).md") -join "`n" |
            Should -Match 'default-branch anchor: refs/remotes/origin/main \(origin/HEAD\)'
    }

    It 'drops the warning on a re-run once the repo is fixed' {
        $s = New-Scenario -Validate @('exit 0') -RepoOptions @{ WithRemote = $true
            DanglingOriginHead = $true
        }
        $first = Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-validate.ps1' -Arguments @($s.Id)
        $first.Output | Should -Match 'ANCHOR WARNING'
        Invoke-Git @('-C', $s.Repo, 'remote', 'set-head', 'origin', '-a')
        $second = Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-validate.ps1' -Arguments @($s.Id)
        $second.ExitCode | Should -Be 0
        $second.Output | Should -Not -Match 'ANCHOR WARNING'
        (Get-TestTaskState -InstallRoot $s.Install -Id $s.Id).anchorWarning | Should -BeNullOrEmpty
    }
}

Describe 'dep-publish.ps1 on an unverified gate' {
    BeforeAll {
        $script:pub = New-Scenario -RepoOptions @{ WithRemote = $true }
        Invoke-DeputyScript -InstallRoot $script:pub.Install -Script 'dep-validate.ps1' `
            -Arguments @($script:pub.Id) | Out-Null
        $script:pubRun = Invoke-DeputyScript -InstallRoot $script:pub.Install `
            -Script 'dep-publish.ps1' -Arguments @($script:pub.Id)
    }

    It 'refuses to publish' {
        $script:pubRun.ExitCode | Should -Not -Be 0
        $script:pubRun.Output | Should -Match 'Refusing to publish'
        $script:pubRun.Output | Should -Match "ran nothing"
    }

    It 'points at both remedies: pin commands, or Sheriff-approved override' {
        $script:pubRun.Output | Should -Match 'projects\.json'
        $script:pubRun.Output | Should -Match '-AllowUnverified'
    }

    It 'does not push the branch' {
        $bare = "$($script:pub.Repo).origin.git"
        & git -C $bare rev-parse --verify --quiet 'refs/heads/deputy/task' 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'still refuses when validation never ran at all' {
        $s = New-Scenario -RepoOptions @{ WithRemote = $true }
        $run = Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-publish.ps1' -Arguments @($s.Id)
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match "validation state ''"
    }

    It 'gets past the gate check only with -AllowUnverified' {
        # gh cannot open a PR against a local bare remote, so this stops at the
        # gh step; the push proves the validation guard was the only blocker.
        $s = New-Scenario -RepoOptions @{ WithRemote = $true }
        Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-validate.ps1' -Arguments @($s.Id) | Out-Null
        $run = Invoke-DeputyScript -InstallRoot $s.Install -Script 'dep-publish.ps1' `
            -Arguments @($s.Id, '-AllowUnverified')
        $run.Output | Should -Match 'UNVERIFIED gate'
        $run.Output | Should -Not -Match 'Refusing to publish'
        & git -C "$($s.Repo).origin.git" rev-parse --verify --quiet 'refs/heads/deputy/task' 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}
