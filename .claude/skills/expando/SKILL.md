---
name: expando
description: Expand a short or adhdified answer back into full detail - the reasoning, the evidence, the exact output. Use when the user says "expando", "expand that", "more detail", "why?", "show me the full thing", or asks for the long version of a summary you just gave. Invocable as /expando, optionally with a topic to expand only one part.
---

# expando

The counterpart to `adhdify`. The user read the short version and now wants the substance.

## Scope

- `/expando` - expand the whole of your previous answer.
- `/expando <topic>` - expand only that bullet or thread (`/expando the failing test`, `/expando the anchor warning`). Everything else stays collapsed; do not re-summarise it.

## Go back to the source, don't embroider

The short version dropped detail. Recover it from the actual artifacts, not from memory of what you wrote:

- Re-read the files, logs, and command output the summary was based on.
- In Deputy, that means `dep-posse.ps1 logs <id>`, `state\<id>-report.md`, `dep-pr.ps1 diff <id>`, `dep-pr.ps1 checks <id>`, the recorded `validationError` / `validationNote` / `anchorWarning`.
- Quote real output rather than paraphrasing it. If it is long, quote the load-bearing lines and say how many you skipped.

If a detail was never captured, say "I don't have that - I can go get it by <command>" and offer to run it. **Never invent detail to fill out the expansion.** A fabricated expansion is worse than a short answer.

## Output shape

Plain prose and headings, no rigid template - the point of expanding is that the structure follows the content. But:

1. **Open with a one-line pointer** to what you are expanding, so the user knows which summary this attaches to.
2. **Order by what the user most likely wanted**: the failure or the decision first, the happy path last.
3. **Show evidence** - commands run, exact output, file:line references.
4. **Explain the reasoning**, including what you ruled out and why. This is the part the summary always loses.
5. **End with the same next action** as the summary, restated. Expanding must not silently change your recommendation. If reading the detail back *did* change it, say that explicitly.

Length is whatever the content needs. Do not pad, do not re-compress.

## While expanded

`adhdify` stays suspended for follow-up questions on this same thread until the user changes topic or asks for the short form again - having asked for detail, they should not have to re-ask each turn.
