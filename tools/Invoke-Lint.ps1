#Requires -Version 7.0
<#
.SYNOPSIS
Deputy's lint gate: PSScriptAnalyzer over every script in the repo.

Exits 1 on any finding at the severities configured in
PSScriptAnalyzerSettings.psd1, so it is usable as a gate command.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# The gate runs on one pinned version (tools\gate-modules.psd1): analyzer rules
# change between releases, and a finding must not depend on whose machine ran it.
$pinned = [version](Import-PowerShellDataFile (Join-Path $PSScriptRoot 'gate-modules.psd1')).PSScriptAnalyzer
$analyzer = Get-Module -ListAvailable PSScriptAnalyzer |
    Where-Object { $_.Version -eq $pinned } |
    Select-Object -First 1
if (-not $analyzer) {
    Write-Output "PSScriptAnalyzer $pinned is required and not installed. Run: pwsh -NoProfile -File tools\Install-GateModules.ps1"
    exit 1
}
Import-Module $analyzer.Path -Force

$targets = @('bin', 'tools', 'tests') |
    ForEach-Object { Join-Path $root $_ } |
    Where-Object { Test-Path $_ }

$settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
# -Path takes one path at a time, so scan each directory in turn
$findings = @($targets | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings $settings })

$scanned = ($targets | ForEach-Object { Split-Path -Leaf $_ }) -join ', '
if ($findings.Count -eq 0) {
    Write-Output "PSScriptAnalyzer ${pinned}: clean ($scanned)"
    exit 0
}

# One line per finding: a table truncates the messages, and this output ends up
# in the PR-visible evidence document.
$findings | ForEach-Object {
    Write-Output ('{0}:{1} [{2}] {3} - {4}' -f $_.ScriptName, $_.Line, $_.Severity, $_.RuleName, $_.Message)
}
Write-Output "PSScriptAnalyzer ${pinned}: $($findings.Count) finding(s) in $scanned"
exit 1
