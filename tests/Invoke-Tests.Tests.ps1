#Requires -Version 7.0
<#
.SYNOPSIS
Tests for Deputy's own test gate, tools\Invoke-Tests.ps1.

The regression these pin down: the gate exited on FailedCount alone, so a run
that died before any test executed - a parse error, a throwing top-level
BeforeAll, any failed container - exited 0 and let dep-validate.ps1 record
validation=passed for a run in which nothing was verified.

The fixtures live in a throwaway root holding a copy of the gate script next to
its own tests\ directory, so the deliberately broken files are never discovered
by the real suite or the real lint gate.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:root = New-TempRoot

    $fixtures = @{
        # A file that cannot be parsed: discovery fails the container while
        # FailedCount stays 0.
        'parse-error'  = 'Describe "x" {'
        # A container-level setup error: nothing inside the Describe can run.
        'setup-error'  = @'
BeforeAll { throw 'setup exploded' }
Describe 'unreachable' { It 'never runs' { $true | Should -BeTrue } }
'@
        # Parses and runs cleanly, but contains no tests at all.
        'no-tests'     = '# deliberately empty of tests'
        'healthy'      = "Describe 'healthy' { It 'passes' { 1 | Should -Be 1 } }"
    }

    $gateRoot = Join-Path $script:root 'gate'
    New-Item -ItemType Directory -Force (Join-Path $gateRoot 'tools') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $gateRoot 'tests') | Out-Null
    # A byte-for-byte copy, so the script under test is the real gate; it
    # resolves tests\ relative to itself, which is the throwaway root here.
    Copy-Item -Force (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'Invoke-Tests.ps1') `
        (Join-Path $gateRoot 'tools' 'Invoke-Tests.ps1')
    foreach ($name in $fixtures.Keys) {
        Set-Content -Path (Join-Path $gateRoot 'tests' "$name.Tests.ps1") `
            -Value $fixtures[$name] -Encoding utf8
    }

    $script:runs = @{}
    foreach ($name in $fixtures.Keys) {
        $out = & pwsh -NoProfile -File (Join-Path $gateRoot 'tools' 'Invoke-Tests.ps1') `
            -Filter $name 2>&1 | Out-String
        $script:runs[$name] = [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    }
}

AfterAll {
    if ($script:root) { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }
}

Describe 'tools\Invoke-Tests.ps1 when the run fails without a failed test' {
    It 'exits non-zero on a test file that fails to parse' {
        # The reported hole: 0 passed, 0 failed, and the old gate exited 0.
        $run = $script:runs['parse-error']
        $run.Output | Should -Match '0 passed, 0 failed'
        $run.ExitCode | Should -Not -Be 0
    }

    It 'exits non-zero when a top-level BeforeAll throws' {
        $script:runs['setup-error'].ExitCode | Should -Not -Be 0
    }

    It 'exits non-zero when the run discovered no tests at all' {
        $script:runs['no-tests'].ExitCode | Should -Not -Be 0
    }

    It 'says which condition tripped, rather than only failing' {
        $script:runs['parse-error'].Output | Should -Match 'Test gate FAILED:.*container\(s\) failed'
        $script:runs['no-tests'].Output | Should -Match 'Test gate FAILED:.*no tests ran'
    }
}

Describe 'tools\Invoke-Tests.ps1 on a healthy run' {
    It 'still exits 0 when every discovered test passes' {
        $run = $script:runs['healthy']
        $run.Output | Should -Match '1 passed, 0 failed'
        $run.Output | Should -Not -Match 'Test gate FAILED'
        $run.ExitCode | Should -Be 0
    }
}
