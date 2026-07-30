#Requires -Version 7.0
<#
.SYNOPSIS
Open the Deputy posse dashboard in Windows Terminal: a live status tab plus
one live-tail tab per active posse member.

Reuses a named terminal window ("deputy"), so running it again after new
spawns just adds the new members' tabs to the same window. Purely a viewing
surface: closing it affects nothing.

.EXAMPLE
.\dep-dashboard.ps1              # status tab + a tab per active member
.\dep-dashboard.ps1 -Id <taskId> # add a tab for one specific (or archived) task
#>
[CmdletBinding()]
param(
    [string]$Id,
    [int]$Tail = 30
)

. "$PSScriptRoot\dep-lib.ps1"
Initialize-Deputy

$wt = Get-Command wt -ErrorAction SilentlyContinue
if (-not $wt) {
    throw 'Windows Terminal (wt.exe) is not on PATH. Install it from the Microsoft Store or winget install Microsoft.WindowsTerminal.'
}

$posse = Join-Path $PSScriptRoot 'dep-posse.ps1'

function Add-Tab([string]$Title, [string]$Command) {
    # wt separates subcommands with ';'; titles/commands are pre-quoted here
    "new-tab --title `"$Title`" pwsh -NoProfile -Command `"$Command`""
}

$tabs = @()
if ($Id) {
    $task = Read-TaskStateAny $Id
    $short = ($task.id -replace '^posse-\d{8}-\d{6}-', '')
    $tabs += Add-Tab "$short $(Split-Path -Leaf $task.repo)" "& '$posse' logs $($task.id) -Follow -Tail $Tail"
}
else {
    $tabs += Add-Tab 'deputy posse' "& '$posse' status -Watch"
    foreach ($task in @(Get-AllTasks | Where-Object { $_.status -in @('running', 'stalled') })) {
        $short = ($task.id -replace '^posse-\d{8}-\d{6}-', '')
        $tabs += Add-Tab "$short $(Split-Path -Leaf $task.repo)" "& '$posse' logs $($task.id) -Follow -Tail $Tail"
    }
}

# -w deputy: create or reuse the window named "deputy"
$argString = '-w deputy ' + ($tabs -join ' ; ')
Start-Process -FilePath $wt.Source -ArgumentList $argString
Write-Output ("dashboard: opened {0} tab(s) in terminal window 'deputy'" -f $tabs.Count)
