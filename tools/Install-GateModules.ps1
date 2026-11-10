#Requires -Version 7.0
<#
.SYNOPSIS
Install the module versions Deputy's own gate is pinned to.

Reads tools\gate-modules.psd1 and installs each module at exactly that version
for the current user. A version that is already installed is left alone, so
this is safe to re-run and is a no-op on a warm CI module cache.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$pins = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'gate-modules.psd1')

foreach ($name in ($pins.Keys | Sort-Object)) {
    $version = [version]$pins[$name]
    $installed = Get-Module -ListAvailable $name | Where-Object { $_.Version -eq $version }
    if ($installed) {
        Write-Output "$name $version is already installed"
        continue
    }
    Write-Output "Installing $name $version"
    # -SkipPublisherCheck: Windows ships a Microsoft-signed Pester 3, and
    # without this the differently signed Pester 5 is refused.
    Install-Module -Name $name -RequiredVersion $version -Scope CurrentUser `
        -Repository PSGallery -Force -SkipPublisherCheck
}
