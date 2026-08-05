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

if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Write-Output 'PSScriptAnalyzer is not installed. Install-Module PSScriptAnalyzer -Scope CurrentUser'
    exit 1
}
Import-Module PSScriptAnalyzer

$targets = @('bin', 'tools', 'tests') |
    ForEach-Object { Join-Path $root $_ } |
    Where-Object { Test-Path $_ }

$settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
# -Path takes one path at a time, so scan each directory in turn
$findings = @($targets | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings $settings })

$scanned = ($targets | ForEach-Object { Split-Path -Leaf $_ }) -join ', '
if ($findings.Count -eq 0) {
    Write-Output "PSScriptAnalyzer: clean ($scanned)"
    exit 0
}

# One line per finding: a table truncates the messages, and this output ends up
# in the PR-visible evidence document.
$findings | ForEach-Object {
    Write-Output ('{0}:{1} [{2}] {3} - {4}' -f $_.ScriptName, $_.Line, $_.Severity, $_.RuleName, $_.Message)
}
Write-Output "PSScriptAnalyzer: $($findings.Count) finding(s) in $scanned"
exit 1
