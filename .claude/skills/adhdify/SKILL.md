---
name: adhdify
description: Re-render a long or dense answer as a short, scannable, ADHD-friendly summary - TL;DR, a few bullets, one next action. Use when the user says "adhdify", "tl;dr that", "too long", "summarise that", "shorter", or when you are about to emit a wall of text (long status reports, validation results, multi-task posse updates, diff walkthroughs, research findings). Invocable as /adhdify.
---

# adhdify

Turn a wall of text into something a distracted reader can absorb in one glance.

Two ways this runs:

- **Retroactively** - the user says `/adhdify` (or "tl;dr that"). Compress the answer you just gave.
- **Pre-emptively** - you are about to produce a long answer and adhdify is on by default (see "Default on"). Write the short version *instead of* the long one, and keep the detail in your head for `/expando`.

## Output shape

Use exactly this skeleton. Nothing before it, nothing after it.

```
**<TL;DR in one sentence - the answer, not a description of the answer>**

- <point>
- <point>
- <point>

**Next:** <the single next action, or "Your call: <the decision you need>">

_More detail: /expando_
```

Rules:

- **150 words hard ceiling.** Aim for 80.
- **3-6 bullets.** Never more. Each one line, ~12 words, no sub-bullets, no nesting.
- **Lead each bullet with the load-bearing word**, bolded if it is a status: `**Passed** - 41 tests, 0 failures.`
- **One next action.** If the next move is the user's, say so plainly under `Your call:`.
- Drop the `_More detail_` line only if there genuinely is no detail behind it.

## What must survive compression

Brevity never costs the reader something they need. Always keep, verbatim:

- Exact outcomes and counts: `3 passed, 1 failed`, not "mostly passing".
- Task ids, branch names, PR URLs, file paths, error messages the user would search for.
- Every blocker and every failure. **Never drop a bad result to make the summary tidy.**
- The distinction between passed / failed / unverified. In Deputy, "unverified" is not a pass - if a gate ran nothing, the bullet says so.

If something important will not fit in 6 bullets, that is a signal the answer needs `Your call:` - not that you should quietly cut it.

## What to cut

Preamble, restating the question, narration of what you did, caveats that change no decision, options you are not recommending, and anything the user already knows.

## Examples

Long version:

> I ran the validation gate on task `t-7f2a` and it came back with exit code 0. The gate executed `npm run lint` and `npm test`, which produced 41 passing tests across 6 suites with no failures... [12 more lines]

Adhdified:

```
**Task t-7f2a passed the gate - ready to publish.**

- **Passed** - lint clean, 41 tests, 0 failures.
- Branch `deputy/fix-token-refresh`, 3 files changed.
- No anchor warning.

**Next:** publishing now, then I'll hand you the PR link.

_More detail: /expando_
```

Long version:

> The gate came back with exit code 2... [paragraph explaining unverified]

Adhdified:

```
**Task t-91bc is UNVERIFIED - nothing about the code is proven.**

- Gate found no commands to run in that repo.
- Not a failure, but not a pass either. Respawning won't fix it.
- Fix for good: pin gate commands in `config\projects.json`.

**Your call:** pin the commands and re-run, or publish with `-AllowUnverified` (PR gets labelled unvalidated).

_More detail: /expando_
```

## Default on

To make this the default for every answer in a repo, add one line to a `CLAUDE.local.md` at that repo's root (git-ignored, personal):

```markdown
Default to the `adhdify` skill's output shape for every substantive reply.
```

Without that line the skill stays opt-in via `/adhdify`.
