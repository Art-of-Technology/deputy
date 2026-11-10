<#
.SYNOPSIS
Toolchain doctor: check that everything Deputy stands on is present and new
enough. Prints one line per problem, each naming its exact fix, and nothing
when healthy. Exit 0 healthy, 1 on any problem.

Checks: PowerShell 7+; git, gh, claude and treehouse on PATH; gh authenticated;
treehouse at or above the minimum version and offering `get --lease`; the
Deputy clone on its default branch and not behind origin.

Report only. The doctor never installs, updates, pulls or switches anything.

This script deliberately has no #Requires line and sticks to syntax Windows
PowerShell 5.1 can parse: an old shell is one of the problems it reports, so
it has to be able to start in one.

.EXAMPLE
pwsh -NoProfile -File bin\dep-doctor.ps1
#>
[CmdletBinding()]
param()

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Output ("PowerShell {0} is too old: Deputy needs 7 or later, and nothing else can be checked until it is. Fix: winget install --id Microsoft.PowerShell -e (then run Deputy with pwsh)" -f $PSVersionTable.PSVersion)
    exit 1
}

. (Join-Path $PSScriptRoot 'dep-lib.ps1')

$problems = @(Get-DoctorProblems)
foreach ($problem in $problems) { Write-Output $problem }
if ($problems.Count -gt 0) { exit 1 }
exit 0
