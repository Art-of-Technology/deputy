---
name: adhdify
description: Re-render a long or dense answer as a scannable, ADHD-friendly briefing - short emoji-headed sections, plain prose, and one decisive "if you only do one thing" close. Use when the user says "adhdify", "tl;dr that", "too long", "what's next", "tell me what to do like I have ADHD", or when you are about to emit a wall of text (status reports, validation results, multi-task posse updates, diff walkthroughs, research findings). Invocable as /adhdify.
---

# adhdify

Turn a wall of text into a briefing someone can scan, act on, and put down.

Two ways this runs:

- **Retroactively** - the user says `/adhdify` (or "tl;dr that"). Recast the answer you just gave.
- **Pre-emptively** - you are about to produce a long answer and adhdify is on by default (see "Default on"). Write this shape *instead of* the wall, and keep the detail in your head for `/expando`.

## Output shape

Short sections, each led by one emoji and a 2-5 word header. `---` between them. Prose where prose is clearer, bullets only for genuine lists.

```
✅ <2-5 word header>

<One or two short lines. Plain sentences, not telegram.>

<A tight list only if the content is actually a list.>

---

🔨 Do this next

<The one thing to do, named in the first line.>

- <why it's the one>
- <what's already in place>
- <blocked on nothing, or what it's blocked on>

---

👉 If you only do one thing

<The same one thing, one line. No hedging.>

_More detail: /expando_
```

Rules:

- **3-6 sections.** Every section earns its place or it merges into another.
- **One emoji per section header. Nowhere else** - never per bullet, never mid-sentence, never trailing a line.
- **Always close with `👉 If you only do one thing`** and name a single action. This is the section the reader remembers.
- **Short paragraphs beat dense bullets.** Two plain sentences are easier than five fragments.
- **Bullets are for lists**, max ~5, no nesting. One line each, except a numbered list of deferred items, where a **bold lead** plus one or two short sentences is right - see the 🐛 section of the example.
- **Blank line between everything.** White space is the point.
- **Strikethrough what's done**: `- ~~Black bar on riverbanks~~`. Resolved things should read as closed.
- **No word ceiling, but no padding either.** Typically 150-350 words. Past ~400 you are expanding, not summarising.
- **Close with `_More detail: /expando_`** whenever real detail sits behind the briefing, so the reader knows the long version is one word away. Drop the line only when there genuinely is nothing more to tell.

## Emoji

Section markers, so the eye can find the section it wants without reading. That only works if each means one thing:

| | Section |
| --- | --- |
| ✅ | what's working, what's settled, good news |
| 🔨 | do this next - the real work |
| 📤 | hand off to someone else |
| 🐛 | known issues worth leaving for now |
| ⚠️ | unverified, or a caveat that changes a decision |
| ❌ | broken, failed, refused |
| 🚧 | blocked, waiting on something |
| 🔍 | what was looked at, findings |
| 🤔 | a decision that is the user's to make |
| 👉 | if you only do one thing - fixed, always last |

- **Never reuse an emoji** inside one answer. Two ✅ headers means those are one section.
- **Never soften a status.** ❌ stays ❌ and ⚠️ never becomes 💡. The emoji layer must not undo what "never hide a failure" guarantees.
- Do not invent new ones for flavour. If a section fits nothing here, question whether it belongs.

## Ordering

**Good news first**, when there is any. Naming what is settled clears the reader's head before you ask them to do something.

Then the one action. Then handoffs. Then what you are deliberately leaving. Then 👉.

Exception: **if something is on fire, it leads.** A failed gate, a blocked merge, a broken build goes first and gets ❌ or ⚠️. Never open with good news to cushion a blocker - that is burying it.

## What must survive compression

Brevity never costs the reader something they need. Keep, verbatim:

- Exact outcomes and counts: `0 errors, 207 tests pass`, not "mostly green".
- Task ids, branch names, PR URLs, file paths, error messages the user would search for.
- Every blocker and every failure. **Never drop a bad result to make the briefing tidy.**
- The distinction between passed / failed / unverified. In Deputy, "unverified" is not a pass - if a gate ran nothing, say nothing was verified.

Say plainly when something is your guess rather than verified, and when a problem is invisible to users right now - both change how urgent it is.

## What to cut

Preamble, restating the question, narration of what you did, caveats that change no decision, options you are not recommending, and anything the user already knows.

## Have an opinion

The point is to spare the reader the deciding, not just the reading. So:

- Recommend, don't enumerate. One next action, not a menu.
- Say why it's the one, in a line: "it's the only item that adds something new rather than fixing or checking."
- Say what you would leave, and that you'd leave it.
- Where the call is genuinely the user's, make that its own line: `🤔 Your call: <the two options>`.

## Example

```
✅ Good news first

Nothing in the game looks broken right now.

The two defects a player could see are fixed and verified:
- ~~Graph paper grass~~
- ~~Black bar on riverbanks~~

Art gate: 0 errors. Build clean. 207 tests pass.

---

🔨 Do this next

Paint Guillotine Gorge.

- First real slice 3 content
- Mountain atlas is applied and QA'd
- `tools/mapgen/` already has a per-scene generator pattern to copy
- Blocked on nothing

It's the only item on the list that adds something new to the game rather than fixing or checking.

---

📤 Send codex one small thing

The mountain cliff still pulses - 12 identical lobe stacks in a row. They fixed the seam but not the "vary the lobe width" part.

Not urgent, no scene paints the mountain yet. But better fixed before you paint the gorge on top of it.

---

🐛 Two things I'd leave for now

1. **My E2E driver is flaky.** Needs the game to print player coordinates so it can walk into position instead of guessing durations. Small job, but it's tooling, not game.

2. **~350 collision marks are my guesses**, not the artist's, across 5 atlases. Invisible until someone walks into thin air. Mountain's are the artist's, so painting the gorge is safe.

---

👉 If you only do one thing

Paint Guillotine Gorge. Everything else is polish, checking, or tools.

_More detail: /expando_
```

## Default on

To make this the default for every answer in a repo, add one line to a `CLAUDE.local.md` at that repo's root (git-ignored, personal):

```markdown
Default to the `adhdify` skill's output shape for every substantive reply.
```

Without that line the skill stays opt-in via `/adhdify`.
