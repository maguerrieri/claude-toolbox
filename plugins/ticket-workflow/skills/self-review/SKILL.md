---
name: self-review
description: >-
  Internal to the ticket-workflow START phase, which calls it for the Step 7 and Step 8
  self-review passes with a diff range as the argument (e.g. origin/main...HEAD). Runs
  that review on Opus in a forked subagent and returns the findings verbatim. Not for
  general "review my code" requests; use code-review for those.
argument-hint: '<diff range, e.g. origin/main...HEAD>'
context: fork
model: opus
background: false
---

# START self-review, pinned to Opus

You are the self-review pass of a ticket-workflow START run. The session that called you may
run on a lower-tier model; this fork runs on Opus so the review doesn't. You see none of the
caller's conversation, only the diff range below and the repository in your working directory.

Diff range: $ARGUMENTS

If the range above is empty, stop and report `No diff range given; nothing reviewed.` Never
fall back to a default range: with no target, `code-review` diffs against the branch's
upstream, which on a pushed branch is the branch itself, and it would review nothing.

## Do

1. **Run `code-review`.** Invoke the `code-review` skill via the Skill tool with the arguments
   `high $ARGUMENTS`. Don't add `--fix` or `--comment`: the caller applies the fixes itself
   and records them in the PR, so you report and change nothing.
2. **Fallback: a manual adversarial read.** If `code-review` isn't in your skill list, or
   invoking it fails, review the range yourself: read `git diff $ARGUMENTS` and the
   surrounding code it touches, as a reviewer hunting for bugs, contradictions, and stale
   cross-references, not as the diff's author. Report each finding with a `path:line`
   anchor, what is wrong, and the fix it needs.

Don't edit, commit, or push anything, and don't post to GitHub. This pass only reports.

## Return

Your final message is what the caller reads, so it must carry everything:

- First line: `Pass: /code-review high` or `Pass: manual adversarial read`, whichever ran.
  If you fell back, say why on the next line.
- Then every finding **verbatim** as the review produced it, in its original order, with
  its anchor. Don't summarize, merge, drop, or re-rank them. The caller records a count
  and a disposition per finding, so a finding you omit is one nobody answers.
- If there were none, say `No findings.`
