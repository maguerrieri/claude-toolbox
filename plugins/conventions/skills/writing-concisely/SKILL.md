---
name: writing-concisely
description: Use when writing any prose a human will read — chat replies, PR and issue bodies, docs, READMEs, commit bodies, code comments, error messages, review notes, status updates — and when asked to tighten, shorten, trim, or de-slop existing text. Also use when a reply is running long or restating things the reader already knows.
---

# Writing concisely

The length-reducing subset of ASD-STE100 Simplified Technical English, adapted
from [AminBlg/SimpleEnglish](https://github.com/AminBlg/SimpleEnglish) (MIT —
see the plugin's `NOTICE`).

**Goal: same voice, fewer words.** The full standard also enforces vocabulary
discipline, one-word-one-meaning, and no contractions — those change *how you
sound* rather than how long you are, so they're left out on purpose.

Unofficial and unaffiliated with ASD or STEMG. ASD-STE100 is a registered
trademark of ASD. The standard is a free download at asd-ste100.org.

## The shape of the output

1. **Answer first.** The first sentence carries the result, the verdict, or the
   number. No preamble, no restating the request back.
2. **One fact per sentence.** One instruction per sentence.
3. **Every sentence tells the reader something they don't have.** A sentence
   that carries no new fact gets deleted, not reworded.
4. **Stop when the facts run out.** No closing paragraph that re-summarizes
   what the reader just read.

## Sentence-level trims

| Pattern | Fix |
|---|---|
| Verb buried in a noun | "perform a comparison of" → "compare" |
| Passive with a known actor | "the file is read by the parser" → "the parser reads the file" |
| Compound tense | "has been updated" → "updated"; "is being rebuilt" → "rebuilds" |
| Trailing `-ing` clause | "…, making restarts unnecessary" → new sentence, or delete |
| Wordy hedge construction | Collapse to one modal, keeping the uncertainty intact: "it is possible that the cache could be stale" → "the cache may be stale" |
| Condition after the command | "Read the log if the build fails" → "If the build fails, read the log" |
| Sentence over ~25 words | Split at the conjunction. Backticked code and identifiers count as one word each. |

## Substitutions

Replace: leverage / utilize → use · in order to → to · prior to → before · due
to the fact that → because · in the event that → if · when it comes to → for ·
enables you to → you can · functionality → feature · plethora / myriad → many

Delete outright (they carry no fact): it's worth noting that · it's important
to note · needless to say · simply / just / easily / seamlessly / effortlessly ·
robust / powerful / comprehensive / performant (or give the measurement) · is
designed to / aims to (say what it does) · gracefully handles (say what it
does — "retries three times, then stops")

## Guardrails — what NOT to cut

Shorter, not clipped. Cut words, never facts.

- **Keep complete grammar** — articles, "that", full clauses. "Ensure file
  exists before running" is worse than "Make sure the file exists before you
  run the command." Terseness is a different failure, not a smaller one.
- **Keep contractions.** They're shorter and they sound human.
- **Keep hedges that carry real uncertainty** — "I think", "probably", "I
  didn't verify the deploy path". Deleting a true hedge is a false claim, not
  a trim.
- **Keep the unwelcome parts** — caveats, failures, what you skipped, what you
  couldn't check. These are the first things a length instinct reaches for and
  the last things that should go.
- **Never touch** code blocks, inline code, identifiers, commands, flags, file
  paths, quoted errors, or log lines.

**Not for** a requested walkthrough, a design doc, an explanation for someone
who is learning, or brand and marketing voice. When asked to teach or
elaborate, elaborate.

## Final pass

Two checks before you send:

1. Your three longest sentences — over ~25 words → split them.
2. Scan for `it's worth`, `important to note`, `has been`, `have been`,
   `it is possible that`, `in order to`, `simply`, `, making`, and `;` (write
   two sentences). Then: does any sentence add no new fact? Delete it.

## Example

**Before (68 words, 3 sentences, 1 fact — the opener alone is 43 words):**

> I've gone ahead and taken a look at the failing test, and it turns out that
> the issue is being caused by the fact that the fixture is shared between
> tests, which means state can leak from one test into the next one. I've made
> a change that should hopefully address this. Let me know if you'd like me to
> explain any part of this in more detail!

**After (25 words, 3 sentences, 3 facts):**

> `test_reorder` fails because the `db` fixture is module-scoped, so rows from
> `test_insert` leak into it. I scoped it per-function. That adds ~2s to the
> suite.
