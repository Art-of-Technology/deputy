#Requires -Version 7.0
<#
.SYNOPSIS
Fleet operations over posse tasks.

.EXAMPLE
.\dep-posse.ps1                       # status table
.\dep-posse.ps1 logs posse-...        # readable log tail (-Raw for raw jsonl)
.\dep-posse.ps1 result posse-...      # full final report of a finished task
.\dep-posse.ps1 kill posse-...        # stop a runaway task (lease kept; use dep-return to release)
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'logs', 'result', 'kill')]
    [string]$Action = 'status',

    [Parameter(Position = 1)]
    [string]$Id,

    [int]$Tail = 40,
    [switch]$Raw
)

. "$PSScriptRoot\dep-lib.ps1"
Initialize-Deputy

function Format-Age([string]$Start, [string]$End) {
    $from = [datetime]$Start
    $to = if ($End) { [datetime]$End } else { Get-Date }
    $span = $to - $from
    if ($span.TotalHours -ge 1) { '{0:n1}h' -f $span.TotalHours }
    elseif ($span.TotalMinutes -ge 1) { '{0:n0}m' -f $span.TotalMinutes }
    else { '{0:n0}s' -f $span.TotalSeconds }
}

function Format-StreamLine($obj) {
    switch ($obj.type) {
        'system' {
            if ($obj.PSObject.Properties['subtype'] -and $obj.subtype -eq 'init') {
                "[init] model=$($obj.model)"
            }
        }
        'assistant' {
            foreach ($block in $obj.message.content) {
                if ($block.type -eq 'text' -and $block.text.Trim()) {
                    '[say]  ' + (Limit-Text $block.text 220)
                }
                elseif ($block.type -eq 'tool_use') {
                    $inputJson = try { $block.input | ConvertTo-Json -Compress -Depth 4 } catch { '' }
                    '[tool] {0} {1}' -f $block.name, (Limit-Text $inputJson 160)
                }
            }
        }
        'result' {
            '[result] {0} turns={1}' -f $obj.subtype, $obj.num_turns
        }
    }
}

switch ($Action) {
    'status' {
        $tasks = @(Get-AllTasks)
        if ($tasks.Count -eq 0) {
            Write-Output 'No active posse tasks. (Archived tasks live in state\archive.)'
            break
        }
        $tasks | ForEach-Object {
            [pscustomobject]@{
                Id     = $_.id
                Kind   = $_.kind
                Status = $_.status
                Alive  = Test-TaskProcessAlive $_
                Age    = Format-Age $_.spawnedAt $_.endedAt
                Repo   = Split-Path -Leaf $_.repo
                Pr     = $_.prUrl
                Task   = Limit-Text $_.task 60
            }
        } | Format-Table -AutoSize
    }
    'logs' {
        if (-not $Id) { throw 'Usage: dep-posse.ps1 logs <taskId>' }
        $task = Read-TaskState $Id
        if (-not (Test-Path $task.stdoutLog)) { throw "No log yet at $($task.stdoutLog)" }
        $lines = Get-Content $task.stdoutLog -Tail $Tail
        if ($Raw) {
            $lines
        }
        else {
            foreach ($line in $lines) {
                if (-not $line) { continue }
                $obj = try { $line | ConvertFrom-Json } catch { $null }
                if ($obj) { Format-StreamLine $obj }
            }
        }
        if ((Test-Path $task.stderrLog) -and (Get-Item $task.stderrLog).Length -gt 0) {
            Write-Output '--- stderr (last 5) ---'
            Get-Content $task.stderrLog -Tail 5
        }
    }
    'result' {
        if (-not $Id) { throw 'Usage: dep-posse.ps1 result <taskId>' }
        $task = Read-TaskState $Id
        if ($task.result) {
            Write-Output $task.result
        }
        else {
            Write-Output "No result recorded yet (status: $($task.status))."
        }
        $report = Join-Path (Get-DeputyPaths).State "$Id-report.md"
        if (Test-Path $report) { Write-Output ''; Write-Output "Full scout report: $report" }
        if ($task.prUrl) { Write-Output "PR: $($task.prUrl)" }
    }
    'kill' {
        if (-not $Id) { throw 'Usage: dep-posse.ps1 kill <taskId>' }
        $task = Read-TaskState $Id
        if (Test-TaskProcessAlive $task) {
            Stop-TaskProcessTree $task.pid
            Write-Output "killed process tree for $Id (pid $($task.pid))"
        }
        else {
            Write-Output "$Id has no live process"
        }
        Set-TaskField $task 'status' 'killed'
        Set-TaskField $task 'endedAt' (Get-Date -Format o)
        Write-TaskState $task
        Write-Output "Worktree lease is still held. Inspect it, then release with: dep-return.ps1 $Id"
    }
}
