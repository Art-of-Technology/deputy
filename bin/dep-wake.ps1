#Requires -Version 7.0
<#
.SYNOPSIS
The durable wake queue: read the wakes nobody has acknowledged yet, and
acknowledge the ones that have been handled.

drain   Print every unacknowledged wake, oldest first. The last line of the
        output is the exact `ack -Through <seq>` command that acknowledges
        what was printed - and nothing that arrives afterwards. Draining
        changes nothing: an unacknowledged wake is printed again next time.
ack     Remove every wake at or below -Through from the queue.

The loop is: drain, handle each wake, run the printed ack. A wake that was
drained but never acknowledged (the session ended mid-handling) is still in
the queue for the next drain.

.EXAMPLE
pwsh -NoProfile -File bin\dep-wake.ps1 drain
pwsh -NoProfile -File bin\dep-wake.ps1 ack -Through 12
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('drain', 'ack')]
    [string]$Action = 'drain',

    # ack: the highest wake sequence that has been handled.
    [long]$Through = 0
)

. "$PSScriptRoot\dep-lib.ps1"
Initialize-Deputy

switch ($Action) {
    'drain' {
        $drained = Receive-Wakes
        $retired = @($drained.Retired)
        if ($retired.Count -gt 0) {
            # Rows with no usable sequence number (written before the queue was
            # sequenced, or torn by a killed writer) can never be acknowledged.
            # They are removed here and shown once, since the queue was their
            # only record.
            Write-Output "wake queue: retired $($retired.Count) row(s) that carry no sequence number and so can never be acknowledged:"
            $retired | Select-Object -First 20 | ForEach-Object { Write-Output ('  ' + (Limit-Text $_ 300)) }
            if ($retired.Count -gt 20) { Write-Output "  ... and $($retired.Count - 20) more" }
        }
        $wakes = @($drained.Wakes)
        if ($wakes.Count -eq 0) {
            Write-Output 'wake queue: no unacknowledged wakes.'
            break
        }
        Format-WakeReport $wakes | Write-Output
    }
    'ack' {
        if ($Through -le 0) { throw 'Usage: dep-wake.ps1 ack -Through <seq>  (the command dep-wake.ps1 drain prints)' }
        $result = Complete-Wakes $Through
        Write-Output "wake queue: acknowledged $($result.Removed) wake(s) through seq $Through."
        if ($result.Remaining -gt 0) {
            Write-Output "$($result.Remaining) newer wake(s) are still unacknowledged. Drain again: $(Get-WakeCommand 'drain')"
        }
    }
}
