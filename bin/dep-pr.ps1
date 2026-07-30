#Requires -Version 7.0
<#
.SYNOPSIS
PR operations for a posse task, via gh.

.EXAMPLE
.\dep-pr.ps1 view posse-...
.\dep-pr.ps1 checks posse-...
.\dep-pr.ps1 merge posse-...          # squash merge (branch cleanup happens in dep-return.ps1)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('view', 'checks', 'diff', 'merge')]
    [string]$Action,

    [Parameter(Mandatory, Position = 1)]
    [string]$Id,

    [ValidateSet('squash', 'merge', 'rebase')]
    [string]$Method = 'squash'
)

. "$PSScriptRoot\dep-lib.ps1"

$task = Read-TaskStateAny $Id

if (-not $task.prUrl) {
    throw "Task $Id has no recorded PR URL. Check its result with: dep-posse.ps1 result $Id"
}

switch ($Action) {
    'view'   { gh pr view $task.prUrl }
    'checks' { gh pr checks $task.prUrl }
    'diff'   { gh pr diff $task.prUrl }
    'merge'  { gh pr merge $task.prUrl "--$Method" }
}
exit $LASTEXITCODE
