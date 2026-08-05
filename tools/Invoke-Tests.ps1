#Requires -Version 7.0
<#
.SYNOPSIS
Deputy's test gate: the Pester suite under tests\.

Exits non-zero on any failure, and also when Pester 5+ is unavailable - a gate
that cannot run its tests must not report success.
#>
[CmdletBinding()]
param(
    # Run only the files whose names match this wildcard (e.g. dep-lib).
    [string]$Filter = '*'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$pester = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -ge 5 } |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $pester) {
    Write-Output 'Pester 5+ is required and not installed. Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck'
    exit 1
}
Import-Module $pester.Path -Force

$testDir = Join-Path $root 'tests'
$files = @(Get-ChildItem -Path $testDir -Filter "$Filter.Tests.ps1" -File -Recurse -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) {
    Write-Output "No test files matched '$Filter.Tests.ps1' under $testDir"
    exit 1
}

$config = New-PesterConfiguration
$config.Run.Path = $files.FullName
$config.Run.PassThru = $true
$config.Run.Throw = $false
$config.Output.Verbosity = 'Detailed'

$result = Invoke-Pester -Configuration $config
Write-Output ("Pester {0}: {1} passed, {2} failed, {3} skipped" -f
    $pester.Version, $result.PassedCount, $result.FailedCount, $result.SkippedCount)

# FailedCount alone is not enough. A run that dies before any test executes - a
# parse error in a .Tests.ps1 file, a throwing top-level BeforeAll, any failed
# container - leaves FailedCount at 0 while Result is 'Failed', and a run that
# discovers no tests at all reports 'Passed' with nothing behind it. Judge every
# condition, and name the one that tripped so the reason is in the gate output.
$reasons = @()
if ($result.FailedCount -gt 0) { $reasons += "$($result.FailedCount) test(s) failed" }
if ($result.FailedContainersCount -gt 0) {
    $reasons += "$($result.FailedContainersCount) container(s) failed (discovery or top-level setup error)"
}
if ($result.Result -ne 'Passed') { $reasons += "Pester run result is '$($result.Result)'" }
if ($result.TotalCount -eq 0) { $reasons += 'no tests ran, so nothing is verified' }
if ($reasons.Count -gt 0) {
    Write-Output ("Test gate FAILED: " + ($reasons -join '; '))
    exit 1
}
exit 0
