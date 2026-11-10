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

And the model a member runs on: it used to default to null, so every member
ran on whatever the account default was when it was spawned. The models and
effort keys now hold one value per kind of task, merged kind by kind; a project
entry can override them; the old flat keys are still read, for one release,
with a warning; and Resolve-MemberSettings applies one precedence order.

Every case that reads config files does so through dep-lib.ps1 in a separate
process, from a throwaway Deputy install, so the real install's config is never
read. Resolve-MemberSettings takes the config as an argument, so its cases run
in this process.
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
        $config.watchIntervalSeconds | Should -Be 15
        # Built in, no kind has a model or an effort: the account default.
        foreach ($kind in 'ship', 'scout') {
            $config.models.$kind | Should -BeNullOrEmpty
            $config.effort.$kind | Should -BeNullOrEmpty
        }
        @($config.legacyKeys).Count | Should -Be 0
    }

    It 'takes the tracked file over the built-in defaults' {
        $config = Get-Config (New-ConfigInstall -Deputy '{ "models": { "ship": "tracked-model" }, "stallMinutes": 20 }')
        $config.models.ship | Should -Be 'tracked-model'
        $config.sources.'models.ship' | Should -Be 'config\deputy.json models.ship'
        $config.models.scout | Should -BeNullOrEmpty
        $config.stallMinutes | Should -Be 20
        $config.watchIntervalSeconds | Should -Be 15
    }

    It 'takes the local file over the tracked one, key by key' {
        $install = New-ConfigInstall -Deputy '{ "stallMinutes": 20, "maxBudgetUsd": 2 }' `
            -DeputyLocal '{ "maxBudgetUsd": 4 }'
        $config = Get-Config $install
        $config.maxBudgetUsd | Should -Be 4
        # Keys the local file does not name keep the tracked value.
        $config.stallMinutes | Should -Be 20
    }

    It 'reads null in the local file as the built-in default, even over a tracked value' {
        $install = New-ConfigInstall -Deputy '{ "effort": { "ship": "high" }, "watchIntervalSeconds": 30, "memberIsolation": false }' `
            -DeputyLocal '{ "effort": null, "watchIntervalSeconds": null, "memberIsolation": null }'
        $config = Get-Config $install
        $config.effort.ship | Should -BeNullOrEmpty
        $config.sources.'effort.ship' | Should -BeNullOrEmpty
        $config.watchIntervalSeconds | Should -Be 15
        $config.memberIsolation | Should -BeTrue
    }

    It 'lets the local file switch member isolation off' {
        (Get-Config (New-ConfigInstall -DeputyLocal '{ "memberIsolation": false }')).memberIsolation | Should -BeFalse
    }

    It 'refuses a local file that is not JSON, and names it' {
        $install = New-ConfigInstall -DeputyLocal '{ "models": '
        { Get-Config $install } | Should -Throw '*deputy.local.json*'
    }

    It 'refuses a local file that is not a JSON object' {
        $install = New-ConfigInstall -DeputyLocal '[ "models" ]'
        { Get-Config $install } | Should -Throw '*deputy.local.json must hold a JSON object*'
    }
}

Describe 'Get-DeputyConfig per-kind models and effort' {
    It 'merges models and effort kind by kind: a local kind wins, the other stays tracked' {
        $install = New-ConfigInstall `
            -Deputy '{ "models": { "ship": "tracked-ship", "scout": "tracked-scout" }, "effort": { "ship": "high" } }' `
            -DeputyLocal '{ "models": { "scout": "my-scout" }, "effort": { "scout": "low" } }'
        $config = Get-Config $install
        $config.models.ship | Should -Be 'tracked-ship'
        $config.models.scout | Should -Be 'my-scout'
        $config.effort.ship | Should -Be 'high'
        $config.effort.scout | Should -Be 'low'
        $config.sources.'models.ship' | Should -Be 'config\deputy.json models.ship'
        $config.sources.'models.scout' | Should -Be 'config\deputy.local.json models.scout'
        $config.sources.'effort.scout' | Should -Be 'config\deputy.local.json effort.scout'
    }

    It 'lets a local null unpin one kind, back to the account default' {
        $install = New-ConfigInstall -Deputy '{ "models": { "ship": "tracked-ship", "scout": "tracked-scout" } }' `
            -DeputyLocal '{ "models": { "scout": null } }'
        $config = Get-Config $install
        $config.models.ship | Should -Be 'tracked-ship'
        $config.models.scout | Should -BeNullOrEmpty
        $config.sources.'models.scout' | Should -BeNullOrEmpty
    }

    It 'refuses <Name>, and names the file' -ForEach @(
        @{ Name = 'a kind that does not exist'; Local = '{ "models": { "shipp": "x" } }'; Message = '*deputy.local.json*models.shipp*kinds are: ship, scout*' }
        @{ Name = 'models as a single string'; Local = '{ "models": "claude-opus-5-5" }'; Message = '*deputy.local.json*models*one entry per kind*' }
        @{ Name = 'a model that is not a string'; Local = '{ "models": { "ship": 5 } }'; Message = '*deputy.local.json (models.ship)*not a model name*' }
        @{ Name = 'an empty model name'; Local = '{ "models": { "ship": " " } }'; Message = '*not a model name*' }
        @{ Name = 'a model a command line would read as an option'; Local = '{ "models": { "ship": "--dangerously-skip-permissions" } }'; Message = '*not a model name*' }
        @{ Name = 'an effort level claude does not have'; Local = '{ "effort": { "scout": "extreme" } }'; Message = '*deputy.local.json (effort.scout)*not one of: low, medium, high, xhigh, max*' }
    ) {
        $install = New-ConfigInstall -DeputyLocal $Local
        { Get-Config $install } | Should -Throw $Message
    }
}

Describe 'Get-DeputyConfig with the old flat model and effort keys' {
    It 'reads a flat model as the model of every kind, and lists where it was found' {
        $config = Get-Config (New-ConfigInstall -DeputyLocal '{ "model": "flat-model", "effort": "medium" }')
        foreach ($kind in 'ship', 'scout') {
            $config.models.$kind | Should -Be 'flat-model'
            $config.effort.$kind | Should -Be 'medium'
            $config.sources."models.$kind" | Should -Be 'config\deputy.local.json model (old flat key)'
        }
        @($config.legacyKeys) | Should -Be @('config\deputy.local.json "model"', 'config\deputy.local.json "effort"')
    }

    It 'lets a local flat model win over the tracked per-kind models, so a personal pin stays in force' {
        $install = New-ConfigInstall -Deputy '{ "models": { "ship": "tracked-ship", "scout": "tracked-scout" } }' `
            -DeputyLocal '{ "model": "my-pin" }'
        $config = Get-Config $install
        $config.models.ship | Should -Be 'my-pin'
        $config.models.scout | Should -Be 'my-pin'
    }

    It 'lets the same file''s per-kind value win over its own flat key' {
        $config = Get-Config (New-ConfigInstall -DeputyLocal '{ "model": "flat-model", "models": { "ship": "ship-model" } }')
        $config.models.ship | Should -Be 'ship-model'
        $config.models.scout | Should -Be 'flat-model'
    }

    It 'ignores a flat key set to null: it carries no choice, so it neither unpins nor warns' {
        # The shape of the old tracked config\deputy.json, copied whole into a
        # local file.
        $install = New-ConfigInstall -Deputy '{ "models": { "ship": "tracked-ship" } }' -DeputyLocal '{ "model": null }'
        $config = Get-Config $install
        $config.models.ship | Should -Be 'tracked-ship'
        @($config.legacyKeys).Count | Should -Be 0
        Invoke-DeputyLib -InstallRoot $install -Command 'Get-LegacyConfigWarning (Get-DeputyConfig)' | Should -BeNullOrEmpty
    }

    It 'has one warning that names the file and the per-kind shape to move to' {
        $install = New-ConfigInstall -DeputyLocal '{ "model": "flat-model" }'
        $warning = Invoke-DeputyLib -InstallRoot $install -Command 'Get-LegacyConfigWarning (Get-DeputyConfig)'
        $warning | Should -Match ([regex]::Escape('config\deputy.local.json "model" still uses the old flat'))
        $warning | Should -Match ([regex]::Escape('"models": { "ship": "...", "scout": "..." }'))
    }

    It 'refuses a flat effort level claude does not have' {
        $install = New-ConfigInstall -Deputy '{ "effort": "extreme" }'
        { Get-Config $install } | Should -Throw '*config\deputy.json has effort*not one of: low, medium, high, xhigh, max*'
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

    It 'has no model or effort of its own unless the projects config names one' {
        $projectProfile = Get-Profile (New-ConfigInstall -Projects $script:tracked) 'C:\src\myapp'
        $projectProfile.model | Should -BeNullOrEmpty
        $projectProfile.effort | Should -BeNullOrEmpty
    }

    It 'takes a model and an effort from the matched entry over the default, and says where from' {
        $local = '{ "default": { "model": "default-model", "effort": "low" }, "projects": [ { "match": "myapp", "model": "app-model" } ] }'
        $install = New-ConfigInstall -Projects $script:tracked -ProjectsLocal $local
        $projectProfile = Get-Profile $install 'C:\src\myapp'
        $projectProfile.model | Should -Be 'app-model'
        $projectProfile.modelSource | Should -Be "config\projects.local.json (match 'myapp')"
        # The entry names no effort, so the default's stays.
        $projectProfile.effort | Should -Be 'low'
        $projectProfile.effortSource | Should -Be 'config\projects.local.json (default)'
        (Get-Profile $install 'C:\src\unlisted').model | Should -Be 'default-model'
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'an unknown effort level on an entry'; Local = '{ "projects": [ { "match": "myapp", "effort": "turbo" } ] }'; Message = "*match 'myapp'*effort 'turbo'*not one of*" }
        @{ Name = 'a model that is not a string'; Local = '{ "default": { "model": ["a", "b"] } }'; Message = '*(default)*not a model name*' }
        @{ Name = 'an unknown delivery mode'; Local = '{ "projects": [ { "match": "myapp", "delivery": "yolo" } ] }'; Message = '*delivery*yolo*' }
        @{ Name = 'a validate list that is not a list'; Local = '{ "projects": [ { "match": "myapp", "validate": "npm test" } ] }'; Message = '*validate*list*' }
        @{ Name = 'an entry with no match'; Local = '{ "projects": [ { "validate": ["x"] } ] }'; Message = '*match*' }
        @{ Name = 'a file that is not JSON'; Local = '{ "projects": [ '; Message = '*projects.local.json*' }
    ) {
        $install = New-ConfigInstall -Projects $script:tracked -ProjectsLocal $Local
        { Get-Profile $install 'C:\src\myapp' } | Should -Throw $Message
    }
}

Describe 'Resolve-MemberSettings' {
    BeforeAll {
        . (Join-Path $script:sourceRoot 'bin' 'dep-lib.ps1')

        function New-TestConfig([string]$Ship, [string]$Scout, [string]$ShipEffort) {
            # A config as Get-DeputyConfig returns one, cut down to what the
            # resolver reads.
            [pscustomobject]@{
                models  = [pscustomobject]@{ ship = $Ship ? $Ship : $null; scout = $Scout ? $Scout : $null }
                effort  = [pscustomobject]@{ ship = $ShipEffort ? $ShipEffort : $null; scout = $null }
                sources = [pscustomobject]@{
                    'models.ship'  = $Ship ? 'config\deputy.json models.ship' : $null
                    'models.scout' = $Scout ? 'config\deputy.json models.scout' : $null
                    'effort.ship'  = $ShipEffort ? 'config\deputy.json effort.ship' : $null
                    'effort.scout' = $null
                }
            }
        }

        function New-TestProject([string]$Model, [string]$Effort) {
            # A project profile as Get-ProjectProfile returns one.
            [pscustomobject]@{
                model        = $Model ? $Model : $null
                modelSource  = $Model ? "config\projects.json (match 'myapp')" : $null
                effort       = $Effort ? $Effort : $null
                effortSource = $Effort ? "config\projects.json (match 'myapp')" : $null
            }
        }
    }

    It 'takes <Name>' -ForEach @(
        @{ Name = 'the spawn''s own -Model over everything'; Explicit = 'flag-model'; ProjectModel = 'project-model'; Kind = 'ship'; Expected = 'flag-model'; Source = '-Model' }
        @{ Name = 'the project entry over the per-kind default'; Explicit = ''; ProjectModel = 'project-model'; Kind = 'ship'; Expected = 'project-model'; Source = "config\projects.json (match 'myapp')" }
        @{ Name = 'the per-kind default of a ship task'; Explicit = ''; ProjectModel = ''; Kind = 'ship'; Expected = 'ship-model'; Source = 'config\deputy.json models.ship' }
        @{ Name = 'the per-kind default of a scout'; Explicit = ''; ProjectModel = ''; Kind = 'scout'; Expected = 'scout-model'; Source = 'config\deputy.json models.scout' }
    ) {
        $config = New-TestConfig -Ship 'ship-model' -Scout 'scout-model'
        $chosen = Resolve-MemberSettings -Kind $Kind -Model $Explicit -Config $config -Project (New-TestProject -Model $ProjectModel)
        $chosen.model | Should -Be $Expected
        $chosen.modelSource | Should -Be $Source
    }

    It 'leaves the model to the account default when nothing names one' {
        $chosen = Resolve-MemberSettings -Kind scout -Config (New-TestConfig -Ship 'ship-model') -Project (New-TestProject)
        $chosen.model | Should -BeNullOrEmpty
        $chosen.modelSource | Should -Be 'account default'
    }

    It 'resolves the effort by the same rule, and spells a flag''s level the way claude does' {
        $config = New-TestConfig -ShipEffort 'medium'
        (Resolve-MemberSettings -Kind ship -Config $config -Project (New-TestProject)).effort | Should -Be 'medium'
        $fromProject = Resolve-MemberSettings -Kind ship -Config $config -Project (New-TestProject -Effort 'max')
        $fromProject.effort | Should -Be 'max'
        $fromProject.effortSource | Should -Be "config\projects.json (match 'myapp')"
        $fromFlag = Resolve-MemberSettings -Kind ship -Effort 'HIGH' -Config $config -Project (New-TestProject -Effort 'max')
        $fromFlag.effort | Should -Be 'high'
        $fromFlag.effortSource | Should -Be '-Effort'
        (Resolve-MemberSettings -Kind scout -Config $config -Project (New-TestProject)).effort | Should -BeNullOrEmpty
    }

    It 'treats a blank -Model as not given' {
        $chosen = Resolve-MemberSettings -Kind ship -Model '  ' -Config (New-TestConfig -Ship 'ship-model') -Project (New-TestProject)
        $chosen.model | Should -Be 'ship-model'
    }
}

Describe 'the tracked configuration' {
    It 'pins a model for every kind, so no member follows the account default' {
        $tracked = Get-Content (Join-Path $script:sourceRoot 'config' 'deputy.json') -Raw | ConvertFrom-Json
        # Ship work runs on Opus: the Sheriff's decision (issue #37).
        $tracked.models.ship | Should -Be 'claude-opus-5-5'
        $tracked.models.scout | Should -Not -BeNullOrEmpty
        $tracked.PSObject.Properties.Name | Should -Not -Contain 'model' -Because 'the flat key is the old shape'
        $tracked.effort | Should -Not -BeOfType [string]
    }

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
