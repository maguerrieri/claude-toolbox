---
name: gh-prs
description: 'Use when merging a GitHub pull request, especially a stacked or dependent one or anything run through gh stack; when gh pr merge or gh pr edit --base is refused because the PR is part of a stack; when working out which status checks a branch requires (branch protection, rulesets, a 404 from the protection API); when a required check never reports or blocks every PR; or when a CI check is red, cancelled, or green without proof the gate ran.'
---

# GitHub PR and CI mechanics

## Overview

A few GitHub behaviors look like something else: a stack lock reads as a
permissions error, a 404 reads as "unprotected", an outage reads as a failing
test. This is the reference for those moments. It covers the mechanics only.
When and in what order to merge a stack, restacking an unregistered chain, and
never passing `--delete-branch` belong to the `ticket-workflow` skill's FINISH
and EPIC phases. Use those for the procedure.

## Registered stacks (`gh stack`)

A **registered** stack is one GitHub itself tracks (the `github/gh-stack`
extension; public preview since 2026-07-30), not just PRs whose bases point at
each other. A chain can be registered without anyone asking, for example by
`gh stack link` or a teammate's `gh stack submit`. So check `gh stack view`, or
the stack panel on the PR page, before planning any base surgery. No `gh stack`
command? `gh extension install github/gh-stack`.

| Symptom | Cause | Do this |
|---|---|---|
| `gh pr merge` refused: *"This pull request is part of a stack and must be merged using the asynchronous merge REST API"* | stack members merge only through the stack API | `gh stack merge <pr> --rebase --yes` (below) |
| `422 Cannot change the base branch because the pull request is part of a stack` | the base is locked while the stack is registered; `gh pr edit --base` and a REST PATCH both hit it, and closing the layer below doesn't release it | *Base surgery*, below |
| a pile of staged changes right after `gh stack init`, though HEAD is correct | an init artifact | if the tree was clean before init, `git reset --hard HEAD`, then check `git log -1` is still the commit you expect |

**Merging a layer: `gh stack merge <pr> --rebase --yes`.**

- **Always pass the PR number.** With none, it merges the current branch's stack
  up to and including the current branch, so from a top branch it merges layers
  nobody approved. The CLI checks only that each PR is open and not a draft;
  approvals stop it only where branch protection requires them. In a
  non-interactive shell (any agent's) there is no wizard: it merges at once.
- **It takes numbers only**: a PR URL is rejected. And a bare number is tried
  as a stack number first, then as a PR number. Stacks have been seen taking
  their numbers from the same sequence as issues and PRs, so an existing PR's
  number shouldn't also name a stack, but the extension doesn't promise that.
  The PR page's stack panel shows only that PR's own stack, so it can't rule a
  clash out. Where it matters, `gh stack view --json` from the stack's checkout
  shows its number and layers.
- **Always pass the method.** `--yes` without one reuses your last-used method.
- It merges every layer up to and including `<pr>`, all or nothing: if any of
  them can't merge, none do (per its `--help`). Layers above `<pr>` stay open.
  A failure during a GitHub incident (*"Git service unavailable during
  rebase"*) has been seen to merge nothing, and a retry once the incident
  cleared worked. Before any retry, confirm what actually landed:
  `gh stack view` marks merged layers `✓`.

**After a merge, verify the layer above.** GitHub retargets it and rebases it
server-side, and that rebase is real. Still check it:
`gh pr view <child> --json baseRefName,changedFiles`. Note `changedFiles`
before you merge: while the child is based on the parent, it counts only the
child's own files. Afterwards `baseRefName` should be the base branch, and
`changedFiles` should be **unchanged**. A bare retarget raises it, because the
merged parent's files come back into the child's diff (its merge-base is still
the old base). So the file count, not the base name, tells a rebase from a
retarget.

**Base surgery on a registered PR.** The base is locked, so in order:

1. `gh stack unstack <stack-number>` removes the stack on GitHub (PRs queued
   for merge or with auto-merge enabled stay stacked). After that the base
   should be editable; re-`link` the chain you still want stacked. Unstack
   itself is exercised (ticket-workflow uses it to recover a stack), but that
   it releases the base lock is untested.
2. `gh stack modify` (an interactive TUI: drop, reorder, insert), then
   `gh stack submit`, might re-parent it. Also untested.
3. Close and recreate the PR. This loses the PR number and its review threads,
   so **ask a human first**. A closed member of a registered stack **wedges the
   whole stack**: every later `gh stack merge` fails with *"nothing to merge:
   pull request is closed"*. So unstack before closing (skip that if step 1
   already did), then `gh stack link <bottom> … <top>` again with the
   replacement PR.

`ticket-workflow`'s `phases/epic.md` Step 7 records the scratch-repo validation
of stack merges (retarget and rebase, draft and closed layers, number
ambiguity). When it and this skill disagree, re-check against
`gh stack <cmd> --help` and fix both.

## Which checks a branch requires, without admin

- **Classic protection:**
  `gh api repos/O/R/branches/<b> --jq '.protection.required_status_checks.contexts'`.
  Works with pull access.
- **Not** `gh api repos/O/R/branches/<b>/protection`. That documented endpoint
  returns **404 to non-admins**, which reads like "no protection". It is no
  evidence either way.
- **Rulesets:**
  `gh api --paginate 'repos/O/R/rules/branches/<b>?per_page=100' --jq '.[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context'`
  lists the ruleset-required checks in effect on that branch, one per line, org
  rulesets included. Keep `--paginate`: the endpoint pages, and a check rule on
  a later page would otherwise go missing. No output there (or `[]` from
  `gh api repos/O/R/rulesets`) means no ruleset requires anything, not that
  classic protection does.
- Both can apply at once. The branch requires the union of the two lists, and
  both empty means no required checks.

**Why it matters: required fan-in jobs.** A job whose `needs:` failed or was
skipped is skipped too, unless its `if:` uses a status function (`always()`,
`failure()`). So an `if:` on a job that a required fan-in job `needs:` skips the
fan-in on every PR where the condition is false. A skipped required check can't
be trusted in either direction. GitHub documents a skipped job as reporting
Success, "even if it is a required check", so the fan-in can pass a PR whose
real work never ran. This exact shape has also been seen to leave the required
check never reporting, which blocks every PR. Either way the fix is the same:
short-circuit **inside** the gated job, and keep the fan-in unconditional.

```yaml
jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      code: ${{ steps.filter.outputs.code }}
    steps:
      - id: filter       # replace with your real change detection
        run: echo "code=true" >> "$GITHUB_OUTPUT"
  test:
    needs: changes
    runs-on: ubuntu-latest
    steps:               # the job always runs; only its steps are gated
      - uses: actions/checkout@v5
        if: needs.changes.outputs.code == 'true'
      - if: needs.changes.outputs.code == 'true'
        run: make test
  ci-ok:                 # the required check
    if: always()
    needs: [changes, test]
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled') || contains(needs.*.result, 'skipped')
        run: exit 1
```

A required check from a **workflow** skipped by a `paths:` or `branches:` filter
never reports at all ("Expected — Waiting for status to be reported"). Don't
require a workflow that can be skipped.

## CI results that mislead

- **A red X that is an outage.** During a GitHub Actions incident a job can be
  cancelled after about 15 minutes in the queue with **zero steps executed**.
  `gh pr checks` shows it exactly like a real failure. Before touching code:
  `gh run view <run-id> --json jobs --jq '.jobs[] | {name, conclusion, steps: (.steps | length)}'`.
  `cancelled` with `0` steps is not your change. It is infrastructure unless a
  newer push superseded the run (a `concurrency:` group with
  `cancel-in-progress`) or someone cancelled it, so rule those out, then check
  https://www.githubstatus.com. Actions can be down while the API and webhooks
  are fine, so a working `gh` proves nothing. A re-run during the incident dies
  the same way, so wait for it to resolve, then `gh run rerun <run-id> --failed`.
- **A green check that isn't proof.** A job whose gating step was skipped
  still concludes `success`, and a skipped job still counts as passing for a
  required check. Before reporting that a gate passed, confirm its step
  actually ran:
  `gh run view <run-id> --json jobs --jq '.jobs[] | {name, conclusion, steps: [.steps[] | {name, conclusion}]}'`
  and look for `success`, not `skipped`, on the gating step. Then say which one
  you saw: "gate ran and passed", or "check green, gate step skipped".
