#Requires -Version 7.0
<#
.SYNOPSIS
Tests for private configuration: config\deputy.local.json and
config\projects.local.json, read over the tracked config\deputy.json and
config\projects.json.

What these pin down: per-repo settings used to live only in tracked files, so
every user's clone drifted from main the moment it pinned a gate or chose a
model. The local files are gitignored and win over the tracked defaults - per
key for the Deputy config and the projects default, and by matching the local
project entries first.

Every case reads the config through dep-lib.ps1 in a separate process, from a
throwaway Deputy install, so the real install's config is never read.
#>

BeforeAll {
    $script:sourceRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:root = New-TempRoot
    $script:n = 0

    function New-ConfigInstall {
        # A throwaway install with exactly the config files given (JSON text),
        # and none of the others.
        param([string]$Deputy, [string]$DeputyLocal, [string]$Projects, [string]$ProjectsLocal)
        $script:n++
        $install = New-DeputyInstall -Path (Join-Path $script:root "case$($script:n)") -SourceRoot $script:sourceRoot
        $config = Join-Path $install 'config'
        Remove-Item (Join-Path $config '*.json') -Force
        $files = [ordered]@{
            'deputy.json' = $Deputy; 'deputy.local.json' = $DeputyLocal
            'projects.json' = $Projects; 'projects.local.json' = $ProjectsLocal
        }
        foreach ($name in $files.Keys) {
            if ($null -ne $files[$name]) { Set-Content -Path (Join-Path $config $name) -Value $files[$name] -Encoding utf8 }
        }
        $install
    }

    function Get-Config($Install) { Invoke-DeputyLib -InstallRoot $Install -Command 'Get-DeputyConfig' }

    function Get-Profile($Install, [string]$Repo) {
        Invoke-DeputyLib -InstallRoot $Install -Command "Get-ProjectProfile '$Repo'"
    }
}

AfterAll {
    if ($script:root) { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }
}

Describe 'Get-DeputyConfig' {
    It 'uses the built-in defaults when there is no config file at all' {
        $config = Get-Config (New-ConfigInstall)
        $config.permissionMode | Should -Be 'bypassPermissions'
        $config.branchPrefix | Should -Be 'deputy/'
        $config.memberIsolation | Should -BeTrue
        $config.model | Should -BeNullOrEmpty
        $config.watchIntervalSeconds | Should -Be 15
    }

    It 'takes the tracked file over the built-in defaults' {
        $config = Get-Config (New-ConfigInstall -Deputy '{ "model": "tracked-model", "stallMinutes": 20 }')
        $config.model | Should -Be 'tracked-model'
        $config.stallMinutes | Should -Be 20
        $config.watchIntervalSeconds | Should -Be 15
    }

    It 'takes the local file over the tracked one, key by key' {
        $install = New-ConfigInstall -Deputy '{ "model": "tracked-model", "stallMinutes": 20, "effort": "low" }' `
            -DeputyLocal '{ "model": "my-model", "maxBudgetUsd": 4 }'
        $config = Get-Config $install
        $config.model | Should -Be 'my-model'
        $config.maxBudgetUsd | Should -Be 4
        # Keys the local file does not name keep the tracked value.
        $config.stallMinutes | Should -Be 20
        $config.effort | Should -Be 'low'
    }

    It 'reads null in the local file as the built-in default, even over a tracked value' {
        $install = New-ConfigInstall -Deputy '{ "effort": "high", "watchIntervalSeconds": 30, "memberIsolation": false }' `
            -DeputyLocal '{ "effort": null, "watchIntervalSeconds": null, "memberIsolation": null }'
        $config = Get-Config $install
        $config.effort | Should -BeNullOrEmpty
        $config.watchIntervalSeconds | Should -Be 15
        $config.memberIsolation | Should -BeTrue
    }

    It 'lets the local file switch member isolation off' {
        (Get-Config (New-ConfigInstall -DeputyLocal '{ "memberIsolation": false }')).memberIsolation | Should -BeFalse
    }

    It 'refuses a local file that is not JSON, and names it' {
        $install = New-ConfigInstall -DeputyLocal '{ "model": '
        { Get-Config $install } | Should -Throw '*deputy.local.json*'
    }

    It 'refuses a local file that is not a JSON object' {
        $install = New-ConfigInstall -DeputyLocal '[ "model" ]'
        { Get-Config $install } | Should -Throw '*deputy.local.json must hold a JSON object*'
    }
}

Describe 'Get-ProjectProfile' {
    BeforeAll {
        $script:tracked = @'
{
  "default": { "delivery": "no-mistakes", "validate": [] },
  "projects": [
    { "match": "myapp", "delivery": "no-mistakes", "validate": ["tracked test"] },
    { "match": "legacy", "delivery": "direct-pr", "validate": [] }
  ]
}
'@
    }

    It 'falls back to no-mistakes with an empty gate when there is no config' {
        $projectProfile = Get-Profile (New-ConfigInstall) 'C:\src\anything'
        $projectProfile.delivery | Should -Be 'no-mistakes'
        @($projectProfile.validate).Count | Should -Be 0
        $projectProfile.match | Should -BeNullOrEmpty
    }

    It 'matches a tracked entry by folder name' {
        $projectProfile = Get-Profile (New-ConfigInstall -Projects $script:tracked) 'C:\src\myapp'
        @($projectProfile.validate) | Should -Be @('tracked test')
        $projectProfile.source | Should -Match 'config\\projects\.json'
    }

    It 'matches a local entry before a tracked entry for the same repo' {
        $local = '{ "projects": [ { "match": "myapp", "validate": ["my test", "my lint"] } ] }'
        $projectProfile = Get-Profile (New-ConfigInstall -Projects $script:tracked -ProjectsLocal $local) 'C:\src\myapp'
        @($projectProfile.validate) | Should -Be @('my test', 'my lint')
        $projectProfile.source | Should -Match 'config\\projects\.local\.json'
        $projectProfile.validateSource | Should -Match 'config\\projects\.local\.json'
    }

    It 'still matches tracked entries the local file does not name' {
        $local = '{ "projects": [ { "match": "myapp", "validate": ["my test"] } ] }'
        (Get-Profile (New-ConfigInstall -Projects $script:tracked -ProjectsLocal $local) 'C:\src\legacy').delivery |
            Should -Be 'direct-pr'
    }

    It 'lays a matched entry over the default, so an entry may name only what it changes' {
        $local = '{ "default": { "delivery": "direct-pr" }, "projects": [ { "match": "pinned", "validate": ["pinned test"] } ] }'
        $projectProfile = Get-Profile (New-ConfigInstall -Projects $script:tracked -ProjectsLocal $local) 'C:\src\pinned'
        @($projectProfile.validate) | Should -Be @('pinned test')
        $projectProfile.delivery | Should -Be 'direct-pr'
    }

    It 'merges the default per key: local keys win, the others stay tracked' {
        $tracked = '{ "default": { "delivery": "no-mistakes", "validate": ["tracked default test"] }, "projects": [] }'
        $local = '{ "default": { "delivery": "direct-pr" } }'
        $projectProfile = Get-Profile (New-ConfigInstall -Projects $tracked -ProjectsLocal $local) 'C:\src\unlisted'
        $projectProfile.delivery | Should -Be 'direct-pr'
        @($projectProfile.validate) | Should -Be @('tracked default test')
        $projectProfile.validateSource | Should -Match 'config\\projects\.json'
    }

    It 'lets an entry''s empty validate list (auto-detect) override a pinned default' {
        $tracked = '{ "default": { "validate": ["pinned default test"] }, "projects": [] }'
        $local = '{ "projects": [ { "match": "detected", "validate": [] } ] }'
        $projectProfile = Get-Profile (New-ConfigInstall -Projects $tracked -ProjectsLocal $local) 'C:\src\detected'
        @($projectProfile.validate).Count | Should -Be 0
        $projectProfile.validateSource | Should -Match 'config\\projects\.local\.json'
    }

    It 'matches a path entry however its separators and trailing slash are written' {
        $repo = Join-Path $script:root 'repos' 'pathapp'
        $written = ($repo -replace '\\', '/') + '/'
        $local = (@{ projects = @(@{ match = $written; validate = @('path test') }) } | ConvertTo-Json -Depth 4)
        @((Get-Profile (New-ConfigInstall -ProjectsLocal $local) $repo).validate) | Should -Be @('path test')
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'an unknown delivery mode'; Local = '{ "projects": [ { "match": "myapp", "delivery": "yolo" } ] }'; Message = '*delivery*yolo*' }
        @{ Name = 'a validate list that is not a list'; Local = '{ "projects": [ { "match": "myapp", "validate": "npm test" } ] }'; Message = '*validate*list*' }
        @{ Name = 'an entry with no match'; Local = '{ "projects": [ { "validate": ["x"] } ] }'; Message = '*match*' }
        @{ Name = 'a file that is not JSON'; Local = '{ "projects": [ '; Message = '*projects.local.json*' }
    ) {
        $install = New-ConfigInstall -Projects $script:tracked -ProjectsLocal $Local
        { Get-Profile $install 'C:\src\myapp' } | Should -Throw $Message
    }
}

Describe 'the tracked configuration' {
    It 'keeps the local files out of git' {
        foreach ($name in 'deputy.local.json', 'projects.local.json') {
            & git -C $script:sourceRoot check-ignore -q "config/$name"
            $LASTEXITCODE | Should -Be 0 -Because "config/$name holds one user's private pins"
        }
        & git -C $script:sourceRoot check-ignore -q 'config/projects.json'
        $LASTEXITCODE | Should -Be 1 -Because 'the tracked defaults stay tracked'
    }

    It 'keeps the tracked deputy pin: Deputy gates itself with its own lint and tests' {
        $tracked = Get-Content (Join-Path $script:sourceRoot 'config' 'projects.json') -Raw | ConvertFrom-Json
        $pin = @($tracked.projects | Where-Object { $_.match -eq 'deputy' })
        $pin.Count | Should -Be 1
        $pin[0].delivery | Should -Be 'no-mistakes'
        @($pin[0].validate) | Should -Be @(
            'pwsh -NoProfile -File tools/Invoke-Lint.ps1'
            'pwsh -NoProfile -File tools/Invoke-Tests.ps1'
        )
    }
}
