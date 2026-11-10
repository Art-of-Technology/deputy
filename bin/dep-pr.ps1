#Requires -Version 7.0
<#
.SYNOPSIS
PR operations for a posse task: view, checks, diff and a guarded merge.

Everything is read over GitHub's REST API (`gh api`), and the merge is a REST
call too, so none of it needs the read:org token scope that gh's own `pr view`,
`pr checks` and `pr merge` ask for.

view    the pull request: state, branches, head commit, mergeability, body.
checks  every check run and commit status at the PR's current head.
        Exit 0 when none is failing or pending, 1 when one is failing, 8 when
        none is failing but one is still pending.
diff    the PR's diff.
merge   merge it - but only after proving it is fit to merge. It refuses, and
        lists EVERY condition that fails, when the PR:
        - is not open (closed without merging);
        - is a draft;
        - has conflicts with its base branch;
        - has any check that is not successful at its current head commit;
        - has no checks at all while the base branch requires some. Whether it
          does is read from the branch protection; when that cannot be read
          (GitHub answers 403 or 404 to a token without admin rights) the merge
          is refused too, unless -AllowNoChecks is passed;
        - has a head commit other than the one recorded when Deputy published
          it (`prHead`): somebody pushed to the PR after the gate judged it.
        The merge names the head commit it expects, so GitHub refuses it if the
        head moves in between (the REST form of `--match-head-commit <sha>`).
        Afterwards the PR is read again, and `mergedAt` and `mergeSha` are
        recorded in task state only when that read shows it merged. Only those
        two fields are written, under the state lock, onto the record as it is
        on disk then: the reads and the merge take seconds, and the watcher
        may have recorded something in the meantime.
        Exit 0 merged (or already merged), 1 refused or not proven.

.EXAMPLE
.\dep-pr.ps1 view posse-...
.\dep-pr.ps1 checks posse-...
.\dep-pr.ps1 merge posse-...                 # squash merge (branch cleanup happens in dep-return.ps1)
.\dep-pr.ps1 merge posse-... -AllowNoChecks  # a repo with no CI whose branch protection cannot be read
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('view', 'checks', 'diff', 'merge')]
    [string]$Action,

    [Parameter(Mandatory, Position = 1)]
    [string]$Id,

    [ValidateSet('squash', 'merge', 'rebase')]
    [string]$Method = 'squash',

    # merge: accept a PR with no checks when the base branch's protection
    # cannot be read. Never overrides a protection that was read and requires
    # checks.
    [switch]$AllowNoChecks,

    # merge: seconds between re-reads while GitHub has not finished computing
    # mergeability, or has not yet shown the merge.
    [int]$RetrySeconds = 2
)

. "$PSScriptRoot\dep-lib.ps1"

$task = Read-TaskStateAny $Id

if (-not $task.prUrl) {
    throw "Task $Id has no recorded PR URL. Check its result with: dep-posse.ps1 result $Id"
}
$ref = Get-TaskPrRef $task
if (-not $ref) { throw "Task $Id records '$($task.prUrl)' as its PR, which is not a GitHub pull request URL." }

function Read-PullRequest {
    $read = Get-PullRequest $ref
    if (-not $read.Ok) { throw "Pull request #$($ref.Number) of $($ref.Owner)/$($ref.Repo) could not be read: $($read.Error)" }
    $read
}

function Get-ExpectedHead {
    # The commit the PR is supposed to be at: what dep-publish.ps1 recorded. A
    # PR the member opened itself (direct-pr delivery) has no such record, and
    # there the task worktree, which the member pushed from, is the reference.
    $recorded = [string](Get-EventField $task 'prHead')
    if ($recorded) { return [pscustomobject]@{ Sha = $recorded; Source = 'the head Deputy recorded at publish' } }
    if ($task.worktree -and (Test-Path -LiteralPath $task.worktree -PathType Container)) {
        $local = (git -C $task.worktree rev-parse --verify --quiet 'HEAD^{commit}' 2>$null | Out-String).Trim()
        if ($local) { return [pscustomobject]@{ Sha = $local; Source = "the HEAD of the task worktree (no head was recorded at publish)" } }
    }
    [pscustomobject]@{ Sha = ''; Source = '' }
}

function Save-Merge($PullRequest) {
    # Record a proven merge. Never the whole record this script read at the
    # start: that copy is seconds old by now. A returned task's record is
    # updated where it lies in the archive.
    $written = Update-TaskState $Id ([ordered]@{ mergedAt = $PullRequest.MergedAt; mergeSha = $PullRequest.MergeSha }) -IncludeArchived
    if (-not $written) { throw "The merge of #$($PullRequest.Number) is proven, but task $Id has no record left to write it to." }
}

function Format-Check($Check) {
    $label = switch ($Check.State) { 'success' { 'PASS' } 'pending' { 'WAIT' } default { 'FAIL' } }
    $line = '  {0}  {1}' -f $label, $Check.Name
    if ($Check.State -ne 'success' -and $Check.Detail) { $line += " ($($Check.Detail))" }
    if ($Check.State -eq 'failure' -and $Check.Url) { $line += "  $($Check.Url)" }
    $line
}

switch ($Action) {
    'view' {
        $pr = Read-PullRequest
        $raw = $pr.Raw
        $state = $pr.State + $(if ($pr.Draft -and -not $pr.Merged) { ' (draft)' })
        Write-Output "#$($pr.Number) $($pr.Title)"
        Write-Output "state:     $state"
        Write-Output "url:       $($pr.Url)"
        Write-Output "author:    $(Get-EventField (Get-EventField $raw 'user') 'login')"
        Write-Output "branch:    $($pr.HeadRef) -> $($pr.BaseRef)"
        $expected = Get-ExpectedHead
        $headNote = if (-not $expected.Sha) { '' }
        elseif ($expected.Sha -eq $pr.HeadSha) { "  (is $($expected.Source))" }
        else { "  (DIFFERS from $($expected.Source): $($expected.Sha))" }
        Write-Output "head:      $($pr.HeadSha)$headNote"
        if ($pr.Merged) {
            Write-Output "merged:    $(ConvertTo-UtcDateTime $pr.MergedAt) UTC as $($pr.MergeSha)"
        }
        else {
            $mergeable = if ($null -eq $pr.Mergeable) { 'not computed yet' } elseif ($pr.Mergeable) { 'yes' } else { 'no (conflicts)' }
            Write-Output "mergeable: $mergeable$(if ($pr.MergeableState) { " [$($pr.MergeableState)]" })"
        }
        Write-Output ('changes:   +{0} -{1} in {2} file(s), {3} commit(s)' -f (Get-EventField $raw 'additions'),
            (Get-EventField $raw 'deletions'), (Get-EventField $raw 'changed_files'), (Get-EventField $raw 'commits'))
        $body = [string](Get-EventField $raw 'body')
        if ($body.Trim()) {
            Write-Output ''
            Write-Output $body
        }
        exit 0
    }
    'checks' {
        $pr = Read-PullRequest
        $checks = Get-PrChecks $ref $pr.HeadSha
        if (-not $checks.Ok) { throw "The checks of pull request #$($ref.Number) at $($pr.HeadSha) could not be read: $($checks.Error)" }
        Write-Output "checks of #$($pr.Number) at $($pr.HeadSha):"
        if ($checks.Checks.Count -eq 0) {
            Write-Output '  no checks are reported at this commit'
            exit 0
        }
        $checks.Checks | Sort-Object State, Name | ForEach-Object { Format-Check $_ }
        $passed = $checks.Checks.Count - $checks.Failing.Count - $checks.Pending.Count
        Write-Output "$passed successful, $($checks.Failing.Count) failing, $($checks.Pending.Count) pending"
        if ($checks.Failing.Count -gt 0) { exit 1 }
        if ($checks.Pending.Count -gt 0) { exit 8 }
        exit 0
    }
    'diff' {
        $diff = Invoke-GhApi "$($ref.Api)/pulls/$($ref.Number)" -Accept 'application/vnd.github.diff' -Raw
        if (-not $diff.Ok) { throw "The diff of pull request #$($ref.Number) could not be read: $($diff.Error)" }
        Write-Output $diff.Text
        exit 0
    }
    'merge' {
        $pr = Read-PullRequest
        # GitHub computes mergeability in the background; null means "ask again".
        for ($try = 1; $try -lt 5 -and $pr.State -eq 'open' -and $null -eq $pr.Mergeable; $try++) {
            Start-Sleep -Seconds $RetrySeconds
            $pr = Read-PullRequest
        }

        if ($pr.Merged) {
            # Nothing to merge, and the read is the proof.
            Save-Merge $pr
            Write-Output "#$($pr.Number) is already merged as $($pr.MergeSha). Recorded; nothing to do."
            exit 0
        }

        # Every failing condition is collected, so one run says all of it.
        $problems = @()
        if ($pr.State -ne 'open') { $problems += "it is not open (state: $($pr.State))" }
        if ($pr.Draft) { $problems += 'it is a draft' }
        if ($pr.Mergeable -eq $false -or $pr.MergeableState -eq 'dirty') {
            $problems += "it has conflicts with $($pr.BaseRef)"
        }
        elseif ($null -eq $pr.Mergeable -and $pr.State -eq 'open') {
            $problems += 'GitHub has not finished computing whether it can be merged, so conflicts cannot be ruled out (try again in a moment)'
        }

        $expected = Get-ExpectedHead
        if (-not $expected.Sha) {
            $problems += "no head commit was recorded for this task and its worktree is gone, so the PR's head $(Format-Sha $pr.HeadSha) cannot be checked against anything"
        }
        elseif ($expected.Sha -ne $pr.HeadSha) {
            $problems += "its head is $(Format-Sha $pr.HeadSha), not $(Format-Sha $expected.Sha), $($expected.Source): the PR changed after that"
        }

        $checks = Get-PrChecks $ref $pr.HeadSha
        if (-not $checks.Ok) {
            $problems += "its checks at $(Format-Sha $pr.HeadSha) could not be read: $($checks.Error)"
        }
        else {
            foreach ($check in @($checks.Failing) + @($checks.Pending)) {
                $problems += "check '$($check.Name)' is not successful at $(Format-Sha $pr.HeadSha): $($check.Detail)"
            }
            if ($checks.Checks.Count -eq 0) {
                $required = Get-RequiredChecks $ref $pr.BaseRef
                if ($required.Readable -and $required.Required.Count -gt 0) {
                    $problems += "no checks are reported at $(Format-Sha $pr.HeadSha), and $($pr.BaseRef) requires: $($required.Required -join ', ')"
                }
                elseif (-not $required.Readable -and -not $AllowNoChecks) {
                    $problems += "no checks are reported at $(Format-Sha $pr.HeadSha), and the branch protection of $($pr.BaseRef) " +
                        "could not be read ($($required.Error)), so it is unknown whether checks are required. " +
                        'If this repository has no CI, pass -AllowNoChecks'
                }
                elseif (-not $required.Readable) {
                    Write-Output "WARNING: no checks are reported, and the branch protection of $($pr.BaseRef) could not be read ($($required.Error)). Merging anyway (-AllowNoChecks)."
                }
            }
        }

        if ($problems.Count -gt 0) {
            Write-Output "REFUSED to merge #$($pr.Number) ($($pr.Url)): $($problems.Count) condition(s) failed."
            $problems | ForEach-Object { Write-Output "  - $_" }
            Write-Output 'Nothing was merged.'
            exit 1
        }

        # sha is the REST form of --match-head-commit: GitHub refuses the merge
        # when the head is no longer this commit.
        $merge = Invoke-GhApi "$($ref.Api)/pulls/$($ref.Number)/merge" -Method PUT `
            -Body ([ordered]@{ merge_method = $Method; sha = $pr.HeadSha })

        # The call's own answer is not the proof. The PR is.
        $after = Get-PullRequest $ref
        for ($try = 1; $try -lt 5 -and -not ($after.Ok -and $after.Merged); $try++) {
            Start-Sleep -Seconds $RetrySeconds
            $after = Get-PullRequest $ref
        }
        if ($after.Ok -and $after.Merged) {
            Save-Merge $after
            Write-Output "merged #$($pr.Number) ($Method) as $($after.MergeSha)"
            Write-Output "  head: $($pr.HeadSha)"
            Write-Output "Tear the task down with: $(Get-ReturnCommand $Id)"
            exit 0
        }
        $answer = if ($merge.Ok) { 'the merge call reported success' } else { "the merge call failed ($($merge.Error))" }
        $now = if ($after.Ok) { "the PR is still '$($after.State)'" } else { "the PR could not be read afterwards ($($after.Error))" }
        Write-Output "MERGE NOT PROVEN for #$($pr.Number): $answer, and $now. Nothing was recorded."
        exit 1
    }
}
