#Requires -Version 7.0
<#
.SYNOPSIS
Tests for the gate's trust anchor (Resolve-DefaultRef / Get-DefaultBranch) and
its command detection (Get-AutoValidateCommands).

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
