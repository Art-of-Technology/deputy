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
exit ($result.FailedCount -gt 0 ? 1 : 0)
