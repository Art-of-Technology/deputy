#Requires -Version 7.0
<#
.SYNOPSIS
Tests for the gate's trust anchor (Resolve-DefaultRef / Get-DefaultBranch), its
command detection (Get-AutoValidateCommands), and the PR title dep-publish
derives from a finished branch (Format-PrTitle / Get-PrTitle).

The regression these pin down: in a repo with no remote, the anchor used to
fall back to the checked-out branch, so every origin/<branch> read failed,
detection returned nothing, and the gate silently ran nothing.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'bin' 'dep-lib.ps1')
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:root = New-TempRoot
    $script:n = 0
    function New-Case {
        param([hashtable]$Options = @{})
        $script:n++
        $path = Join-Path $script:root "repo$($script:n)"
        New-TestRepo -Path $path @Options
    }

    $script:SLN = "Microsoft Visual Studio Solution File, Format Version 12.00`n"
    $script:CSPROJ = "<Project Sdk=`"Microsoft.NET.Sdk`"></Project>`n"
    $script:PKG_TEST_LINT = '{ "name": "app", "scripts": { "test": "jest", "lint": "eslint ." } }'
    $script:TASK_BRANCH = 'deputy/implement-slice-3-of-the-backoffice-v2-r'
}

AfterAll {
    if ($script:root) { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }
}

Describe 'Resolve-DefaultRef' {
    It 'uses origin/HEAD when the repo has a remote' {
        $repo = New-Case @{ WithRemote = $true; TaskBranch = $script:TASK_BRANCH }
        $anchor = Resolve-DefaultRef $repo
        $anchor.Branch | Should -Be 'main'
        $anchor.Ref | Should -Be 'refs/remotes/origin/main'
        $anchor.Source | Should -Be 'origin/HEAD'
    }

    It 'falls back to a remote-tracking branch when origin/HEAD is missing' {
        $repo = New-Case @{ DefaultBranch = 'master'; WithRemote = $true; NoOriginHead = $true
            TaskBranch = $script:TASK_BRANCH
        }
        $anchor = Resolve-DefaultRef $repo
        $anchor.Branch | Should -Be 'master'
        $anchor.Ref | Should -Be 'refs/remotes/origin/master'
    }

    It 'falls through to a ref that exists when origin/HEAD is dangling' {
        # A stale origin/HEAD (default branch renamed or deleted upstream) named
        # a missing ref, and the gate then denied good work with "no commits
        # ahead of refs/remotes/origin/<gone>".
        $repo = New-Case @{ WithRemote = $true; DanglingOriginHead = $true
            TaskBranch = $script:TASK_BRANCH
        }
        (git -C $repo symbolic-ref --short refs/remotes/origin/HEAD).Trim() | Should -Be 'origin/renamed-away'
        $anchor = Resolve-DefaultRef $repo
        $anchor.Ref | Should -Be 'refs/remotes/origin/main'
        $anchor.Branch | Should -Be 'main'
        Test-GitRef $repo $anchor.Ref | Should -BeTrue
    }

    It 'reports the stale origin/HEAD in the anchor source rather than hiding it' {
        $repo = New-Case @{ WithRemote = $true; DanglingOriginHead = $true
            TaskBranch = $script:TASK_BRANCH
        }
        (Resolve-DefaultRef $repo).Source | Should -Match 'stale origin/HEAD \(origin/renamed-away is missing\)'
    }

    It 'labels the anchor health so callers need not parse the source prose' {
        $ok = New-Case @{ WithRemote = $true; TaskBranch = $script:TASK_BRANCH }
        (Resolve-DefaultRef $ok).Health | Should -Be 'ok'

        $local = New-Case @{ TaskBranch = $script:TASK_BRANCH }
        (Resolve-DefaultRef $local).Health | Should -Be 'ok'

        $stale = New-Case @{ WithRemote = $true; DanglingOriginHead = $true
            TaskBranch = $script:TASK_BRANCH
        }
        (Resolve-DefaultRef $stale).Health | Should -Be 'stale'

        $none = New-Case @{ DefaultBranch = 'trunk'; TaskBranch = $script:TASK_BRANCH }
        (Resolve-DefaultRef $none).Health | Should -Be 'unresolved'
    }

    It 'calls a stale origin/HEAD with no usable fallback unresolved, and still says it was stale' {
        $repo = New-Case @{ DefaultBranch = 'trunk'; WithRemote = $true; DanglingOriginHead = $true
            TaskBranch = $script:TASK_BRANCH
        }
        $anchor = Resolve-DefaultRef $repo
        $anchor.Health | Should -Be 'unresolved'
        $anchor.Source | Should -Match 'stale origin/HEAD'
    }

    It 'never returns a ref that does not exist' {
        foreach ($opts in @(
                @{ TaskBranch = $script:TASK_BRANCH; WithRemote = $true },
                @{ TaskBranch = $script:TASK_BRANCH; WithRemote = $true; DanglingOriginHead = $true },
                @{ TaskBranch = $script:TASK_BRANCH; WithRemote = $true; NoOriginHead = $true },
                @{ TaskBranch = $script:TASK_BRANCH; DefaultBranch = 'master'
                    WithRemote = $true; DanglingOriginHead = $true
                },
                @{ TaskBranch = $script:TASK_BRANCH; DefaultBranch = 'trunk'
                    WithRemote = $true; DanglingOriginHead = $true
                },
                @{ TaskBranch = $script:TASK_BRANCH }
            )) {
            $repo = New-Case $opts
            $anchor = Resolve-DefaultRef $repo
            if ($anchor.Ref) { Test-GitRef $repo $anchor.Ref | Should -BeTrue }
        }
    }

    It 'falls back to the local default branch when there is no remote' {
        $repo = New-Case @{ TaskBranch = $script:TASK_BRANCH }
        (git -C $repo remote) | Should -BeNullOrEmpty
        $anchor = Resolve-DefaultRef $repo
        $anchor.Branch | Should -Be 'main'
        $anchor.Ref | Should -Be 'refs/heads/main'
        $anchor.Source | Should -Be 'local branch main'
    }

    It 'falls back to a local master when there is no remote and no main' {
        $repo = New-Case @{ DefaultBranch = 'master'; TaskBranch = $script:TASK_BRANCH }
        $anchor = Resolve-DefaultRef $repo
        $anchor.Branch | Should -Be 'master'
        $anchor.Ref | Should -Be 'refs/heads/master'
    }

    It 'never resolves to the checked-out task branch' {
        foreach ($opts in @(
                @{ TaskBranch = $script:TASK_BRANCH },
                @{ WithRemote = $true; TaskBranch = $script:TASK_BRANCH },
                @{ DefaultBranch = 'trunk'; TaskBranch = $script:TASK_BRANCH }
            )) {
            $repo = New-Case $opts
            (git -C $repo rev-parse --abbrev-ref HEAD).Trim() | Should -Be $script:TASK_BRANCH
            $anchor = Resolve-DefaultRef $repo
            if ($anchor.Ref) { $anchor.Ref | Should -Not -BeLike "*$($script:TASK_BRANCH)*" }
            $anchor.Branch | Should -Not -Be $script:TASK_BRANCH
        }
    }

    It 'reports unresolved rather than guessing when no conventional default exists' {
        # No remote and an unconventional default branch: the honest answer is
        # "no trust anchor", which callers must surface as unverified.
        $repo = New-Case @{ DefaultBranch = 'trunk'; TaskBranch = $script:TASK_BRANCH }
        $anchor = Resolve-DefaultRef $repo
        $anchor.Ref | Should -BeNullOrEmpty
        $anchor.Branch | Should -BeNullOrEmpty
        $anchor.Source | Should -Be 'unresolved'
    }
}

Describe 'Get-DefaultBranch' {
    It 'returns the short branch name' {
        $repo = New-Case @{ WithRemote = $true; TaskBranch = $script:TASK_BRANCH }
        Get-DefaultBranch $repo | Should -Be 'main'
    }

    It 'returns the local default branch name in a repo with no remote' {
        $repo = New-Case @{ TaskBranch = $script:TASK_BRANCH }
        Get-DefaultBranch $repo | Should -Be 'main'
    }

    It 'returns null when the default branch cannot be resolved' {
        $repo = New-Case @{ DefaultBranch = 'trunk'; TaskBranch = $script:TASK_BRANCH }
        Get-DefaultBranch $repo | Should -BeNullOrEmpty
    }
}

Describe 'Format-PrTitle' {
    # The regression: the title was a blunt 70-character substring of the
    # briefing's first sentence, which shipped "into a vacuous p..." on a real
    # PR and had to be corrected by hand.
    BeforeAll {
        $script:REAL_BRIEFING = 'Fix the validation gate so it cannot silently degrade into a vacuous ' +
            "pass. This is the Deputy tool's own repo. Read AGENTS.md first."
    }

    It 'leaves a title that fits alone, minus its sentence punctuation' {
        Format-PrTitle 'Redact secrets from validation evidence output.' |
            Should -Be 'Redact secrets from validation evidence output'
        Format-PrTitle 'Harden task id handling, pid liveness checks and branch slugs,' |
            Should -Be 'Harden task id handling, pid liveness checks and branch slugs'
    }

    It 'no longer cuts the real PR title mid-word' {
        $sentence = Get-FirstSentence $script:REAL_BRIEFING
        # what shipped before this change
        Limit-Text $sentence 70 | Should -Be 'Fix the validation gate so it cannot silently degrade into a vacuous p...'
        Format-PrTitle $sentence |
            Should -Be 'Fix the validation gate so it cannot silently degrade into a vacuous pass'
    }

    It 'breaks on a word boundary when it has to truncate' {
        $long = 'Fix the validation gate so it cannot silently degrade into a vacuous pass that nobody ever notices.'
        $title = Format-PrTitle $long
        $title | Should -Be 'Fix the validation gate so it cannot silently degrade into a vacuous pass...'
        $title.Length | Should -BeLessOrEqual 80
        $long.StartsWith(($title -replace '\.\.\.$', '')) | Should -BeTrue
    }

    It 'sheds punctuation the break left dangling' {
        Format-PrTitle 'Verify the test gate own exit code and the default-branch anchor it trusts, end to end, in Pester.' |
            Should -Be 'Verify the test gate own exit code and the default-branch anchor it trusts...'
    }

    It 'sheds a connective the break left dangling' {
        $title = Format-PrTitle 'Redact secrets from the validation evidence, the recorded state, and the logs before publishing.'
        $title | Should -Be 'Redact secrets from the validation evidence, the recorded state...'
        $title | Should -Not -Match '\b(and|the|of|to|were)\.\.\.$'
    }

    It 'still returns something for one word wider than the whole limit' {
        # No word boundary to break on: cut it, but never loop and never
        # return nothing.
        $title = Format-PrTitle ('Supercalifragilisticexpialidocious' * 3)
        $title | Should -Not -BeNullOrEmpty
        $title.Length | Should -Be 80
        $title | Should -BeLike '*...'
        $title.TrimEnd('.') | Should -Not -Match '\s'
    }

    It 'returns an empty string for no text at all' {
        Format-PrTitle '' | Should -Be ''
        Format-PrTitle $null | Should -Be ''
    }

    Context 'sanitising a title that came from untrusted text' {
        # The title can now be a posse member's commit subject, and the Deputy
        # and Sheriff read it in a terminal. None of this is reachable through
        # the briefing path, but Format-PrTitle guards both.
        BeforeAll {
            $script:ESC = [char]0x1B
        }

        It 'removes an ANSI colour sequence whole, leaving no bracketed residue' {
            $title = Format-PrTitle "Fix login$($script:ESC)[31m bug$($script:ESC)[0m"
            $title | Should -Be 'Fix login bug'
            $title | Should -Not -Match '\[3?1?m'
        }

        It 'removes a cursor-control sequence that would overwrite what was printed' {
            Format-PrTitle "Harmless title$($script:ESC)[2K$($script:ESC)[1A gate passed" |
                Should -Be 'Harmless title gate passed'
        }

        It 'removes an OSC sequence along with its payload' {
            Format-PrTitle "Fix bug$($script:ESC)]0;window title$([char]0x07) done" |
                Should -Be 'Fix bug done'
        }

        It 'removes control characters and invisible format characters' {
            # A bidi override makes a title read as something other than what it
            # says; a zero-width space and a soft hyphen hide a word boundary
            # that is not really there. All are deleted rather than spaced out,
            # because none of them was ever a space.
            $title = Format-PrTitle ("Fix bug$([char]0x07) with$([char]0x202E)reversed$([char]0x202C) " +
                "and$([char]0x200B)hidden$([char]0x00AD)text")
            $title | Should -Be 'Fix bug withreversed andhiddentext'
            $title | Should -Not -Match '[\p{Cc}\p{Cf}]'
        }

        It 'keeps a newline in the source from splitting the headline' {
            Format-PrTitle "Fix the bug`r`n`r`nBody text pretending to be a title" |
                Should -Be 'Fix the bug Body text pretending to be a title'
        }

        It 'sanitises before the length cut, so escapes cannot eat the budget' {
            $noisy = "Fix the validation gate so it cannot$($script:ESC)[31m silently degrade into a " +
                "vacuous pass$($script:ESC)[0m that nobody ever notices"
            Format-PrTitle $noisy |
                Should -Be 'Fix the validation gate so it cannot silently degrade into a vacuous pass...'
        }

        It 'leaves ordinary punctuation and markup characters alone' {
            # GitHub renders a PR title as plain text, so backticks are literal
            # and a legitimate title needs them.
            Format-PrTitle 'Fix `Get-PrTitle` so it handles a $var and 100% of *cases*' |
                Should -Be 'Fix `Get-PrTitle` so it handles a $var and 100% of *cases*'
        }

        It 'returns an empty string for text that is nothing but escapes' {
            Format-PrTitle "$($script:ESC)[31m$([char]0x202E)$([char]0x200B)" | Should -Be ''
        }
    }
}

Describe 'Get-PrTitle' {
    BeforeAll {
        $script:BRIEFING = 'Surface the anchor provenance regardless of how the gate commands were ' +
            'resolved, and make a stale anchor visible. Then add tests.'
        function Add-Commit([string]$Repo, [string]$Subject) {
            Invoke-Git @('-C', $Repo, 'commit', '-q', '--allow-empty', '-m', $Subject)
        }
    }

    It 'uses the commit subject when the branch carries exactly one commit' {
        # A commit subject is already a headline; a briefing's first sentence is
        # a specification.
        $repo = New-Case @{ TaskBranch = $script:TASK_BRANCH }
        Get-PrTitle -Worktree $repo -DefaultRef 'refs/heads/main' -Briefing $script:BRIEFING |
            Should -Be 'task work'
    }

    It 'ignores the deputy evidence commit when counting the branch commits' {
        # Built with the same one definition dep-validate.ps1 commits with, so
        # the exclusion cannot drift away from the subject it has to match.
        $repo = New-Case @{ TaskBranch = $script:TASK_BRANCH }
        Add-Commit $repo (New-EvidenceCommitMessage 'posse-20260101-120000-abc')
        Get-PrTitle -Worktree $repo -DefaultRef 'refs/heads/main' -Briefing $script:BRIEFING |
            Should -Be 'task work'
    }

    It 'falls back to the briefing when the branch carries several commits' {
        $repo = New-Case @{ TaskBranch = $script:TASK_BRANCH }
        Add-Commit $repo 'Second commit of two'
        Get-PrTitle -Worktree $repo -DefaultRef 'refs/heads/main' -Briefing $script:BRIEFING |
            Should -Be 'Surface the anchor provenance regardless of how the gate commands...'
    }

    It 'falls back to the briefing when there is no trusted anchor to count against' {
        $repo = New-Case @{ DefaultBranch = 'trunk'; TaskBranch = $script:TASK_BRANCH }
        $anchor = Resolve-DefaultRef $repo
        $anchor.Ref | Should -BeNullOrEmpty
        Get-PrTitle -Worktree $repo -DefaultRef $anchor.Ref -Briefing $script:BRIEFING |
            Should -Be 'Surface the anchor provenance regardless of how the gate commands...'
    }

    # These go through git's stdout, so they stay in the ASCII range: a
    # non-ASCII character's UTF-8 bytes decode by the console encoding, which
    # varies by machine. The full character classes are covered in the
    # Format-PrTitle tests above, where no encoding boundary is crossed.
    It 'sanitises a member commit subject before it becomes the title' {
        # The trust shift this guards: the subject is the member's text, and the
        # derived title is read in the Sheriff's terminal.
        $repo = New-Case @{ TaskBranch = $script:TASK_BRANCH }
        Invoke-Git @('-C', $repo, 'reset', '-q', '--soft', 'main')
        Add-Commit $repo ("Fix the login bug$([char]0x1B)[2K$([char]0x1B)[32m validated by the " +
            "Sheriff$([char]0x1B)[0m$([char]0x07)")
        $title = Get-PrTitle -Worktree $repo -DefaultRef 'refs/heads/main' -Briefing $script:BRIEFING
        $title | Should -Be 'Fix the login bug validated by the Sheriff'
        $title | Should -Not -Match '[\p{Cc}\p{Cf}]'
    }

    It 'falls back to the briefing when the subject sanitises away to nothing' {
        $repo = New-Case @{ TaskBranch = $script:TASK_BRANCH }
        Invoke-Git @('-C', $repo, 'reset', '-q', '--soft', 'main')
        Add-Commit $repo "$([char]0x1B)[31m$([char]0x1B)[0m$([char]0x07)"
        Get-PrTitle -Worktree $repo -DefaultRef 'refs/heads/main' -Briefing $script:BRIEFING |
            Should -Be 'Surface the anchor provenance regardless of how the gate commands...'
    }

    It 'truncates a long single commit subject on a word boundary too' {
        $repo = New-Case @{ TaskBranch = $script:TASK_BRANCH }
        Invoke-Git @('-C', $repo, 'reset', '-q', '--soft', 'main')
        Add-Commit $repo ('Fix the validation gate so it cannot silently degrade into a vacuous pass ' +
            'that nobody ever notices')
        Get-PrTitle -Worktree $repo -DefaultRef 'refs/heads/main' -Briefing $script:BRIEFING |
            Should -Be 'Fix the validation gate so it cannot silently degrade into a vacuous pass...'
    }
}

Describe 'Get-AutoValidateCommands' {
    Context 'the reported failure: a .NET repo with no remote' {
        It 'detects dotnet test from a solution and csproj on the local default branch' {
            $repo = New-Case @{
                Files      = @{ 'BackOffice.sln' = $script:SLN
                    'BackOffice.Tests/BackOffice.Tests.csproj'  = $script:CSPROJ
                }
                TaskBranch = $script:TASK_BRANCH
            }
            @(Get-AutoValidateCommands $repo) | Should -Be @('dotnet test')
        }
    }

    Context 'repo with a remote' {
        It 'detects dotnet test' {
            $repo = New-Case @{
                Files      = @{ 'BackOffice.sln' = $script:SLN }
                WithRemote = $true; TaskBranch = $script:TASK_BRANCH
            }
            @(Get-AutoValidateCommands $repo) | Should -Be @('dotnet test')
        }

        It 'detects npm test and npm run lint from package.json scripts' {
            $repo = New-Case @{
                Files      = @{ 'package.json' = $script:PKG_TEST_LINT }
                WithRemote = $true; TaskBranch = $script:TASK_BRANCH
            }
            @(Get-AutoValidateCommands $repo) | Should -Be @('npm test', 'npm run lint')
        }
    }

    Context 'runner and ecosystem detection' {
        It 'uses pnpm when a pnpm lockfile is on the default branch' {
            $repo = New-Case @{ Files = @{ 'package.json' = $script:PKG_TEST_LINT; 'pnpm-lock.yaml' = "lockfileVersion: 9`n" } }
            @(Get-AutoValidateCommands $repo) | Should -Be @('pnpm test', 'pnpm run lint')
        }

        It 'uses yarn when a yarn lockfile is on the default branch' {
            $repo = New-Case @{ Files = @{ 'package.json' = $script:PKG_TEST_LINT; 'yarn.lock' = "# yarn`n" } }
            @(Get-AutoValidateCommands $repo) | Should -Be @('yarn test', 'yarn run lint')
        }

        It 'detects cargo, go and pytest projects' {
            $cargo = New-Case @{ Files = @{ 'Cargo.toml' = "[package]`nname = `"x`"`n" } }
            @(Get-AutoValidateCommands $cargo) | Should -Be @('cargo test')

            $go = New-Case @{ Files = @{ 'go.mod' = "module x`n" } }
            @(Get-AutoValidateCommands $go) | Should -Be @('go test ./...')

            $pytestIni = New-Case @{ Files = @{ 'pytest.ini' = "[pytest]`n" } }
            @(Get-AutoValidateCommands $pytestIni) | Should -Be @('pytest')

            $pyproject = New-Case @{ Files = @{ 'pyproject.toml' = "[tool.pytest.ini_options]`n" } }
            @(Get-AutoValidateCommands $pyproject) | Should -Be @('pytest')
        }
    }

    Context 'nothing to detect' {
        It 'returns an empty list for a repo with no recognised manifest' {
            $repo = New-Case @{ TaskBranch = $script:TASK_BRANCH }
            @(Get-AutoValidateCommands $repo).Count | Should -Be 0
        }

        It 'returns an empty list when no trust anchor can be resolved' {
            $repo = New-Case @{
                DefaultBranch = 'trunk'
                Files         = @{ 'BackOffice.sln' = $script:SLN }
                TaskBranch    = $script:TASK_BRANCH
            }
            @(Get-AutoValidateCommands $repo).Count | Should -Be 0
        }
    }

    Context 'the task branch cannot reconfigure its own gate' {
        # The security property: manifests are read from the default branch, so
        # a posse member cannot weaken or disable the gate that judges it.
        It 'ignores manifests added on the task branch (with a remote)' {
            $repo = New-Case @{
                WithRemote = $true
                TaskBranch = $script:TASK_BRANCH
                TaskFiles  = @{
                    'package.json' = '{ "name": "app", "scripts": { "test": "exit 0", "lint": "exit 0" } }'
                    'Sneaky.csproj' = $script:CSPROJ
                    'Cargo.toml'   = "[package]`nname = `"x`"`n"
                }
            }
            @(Get-AutoValidateCommands $repo).Count | Should -Be 0
        }

        It 'ignores manifests added on the task branch (no remote)' {
            $repo = New-Case @{
                TaskBranch = $script:TASK_BRANCH
                TaskFiles  = @{
                    'package.json' = '{ "name": "app", "scripts": { "test": "exit 0" } }'
                    'Sneaky.csproj' = $script:CSPROJ
                }
            }
            @(Get-AutoValidateCommands $repo).Count | Should -Be 0
        }

        It 'still gates when the task branch deletes the manifest (with a remote)' {
            $repo = New-Case @{
                Files       = @{ 'package.json' = $script:PKG_TEST_LINT; 'App.csproj' = $script:CSPROJ }
                WithRemote  = $true
                TaskBranch  = $script:TASK_BRANCH
                TaskDeletes = @('package.json', 'App.csproj')
            }
            @(Get-AutoValidateCommands $repo) | Should -Be @('npm test', 'npm run lint', 'dotnet test')
        }

        It 'still gates when the task branch deletes the manifest (no remote)' {
            $repo = New-Case @{
                Files       = @{ 'package.json' = $script:PKG_TEST_LINT; 'App.csproj' = $script:CSPROJ }
                TaskBranch  = $script:TASK_BRANCH
                TaskDeletes = @('package.json', 'App.csproj')
            }
            @(Get-AutoValidateCommands $repo) | Should -Be @('npm test', 'npm run lint', 'dotnet test')
        }

        It 'ignores a manifest rewritten on the task branch to a weaker script' {
            $repo = New-Case @{
                Files      = @{ 'package.json' = $script:PKG_TEST_LINT }
                WithRemote = $true
                TaskBranch = $script:TASK_BRANCH
                TaskFiles  = @{ 'package.json' = '{ "name": "app", "scripts": {} }' }
            }
            @(Get-AutoValidateCommands $repo) | Should -Be @('npm test', 'npm run lint')
        }
    }
}
