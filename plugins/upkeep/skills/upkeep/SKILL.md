---
name: upkeep
description: "Use when the owner asks to survey a repo for cleanup or upkeep (stale or abandoned PRs, leftover branches and worktrees, an issue backlog to prune, docs naming files that no longer exist, files that keep drawing review fixes, dead scripts and tests) or for a ranked list of what to close, fix or refactor, or when /upkeep appears in the message."
argument-hint: "[--days <n>]"
---

# Upkeep

Survey this repo for stale work and worn spots, then reply with a short ranked
list of proposals for the owner to pick from. Arguments: `$ARGUMENTS`
(`--days <n>` sets the survey window; anything else, say so and stop).

## The run only reads

A survey closes, files, comments on, labels, edits, commits, pushes, spawns and
messages nothing, and starts no Routine. What it may run:

- the scripts below, which only read;
- `gh` reads (`gh pr view`, `gh issue view`, `gh api` GETs and GraphQL
  queries, and the like) and `git` reads (`log`, `show`, `grep`, `diff`,
  `merge-base`, `for-each-ref`, `worktree list`, and the like);
- `git fetch origin <default branch>`, only when `git ls-remote origin
  <default branch>` shows the remote ahead of `origin/<default branch>`. It
  moves only that remote-tracking ref.

Acting on a proposal is a separate request the owner makes after the report,
handled like any other change ask (in a planner session, a pick becomes a
filed issue and a spawn in the usual way). A survey that finds something
urgent still only reports it, at the top.

## 1. Settings

Read the `## Upkeep` section of the repo's instructions: project memory first,
then the root `AGENTS.md`, then `CLAUDE.md` and `.claude/CLAUDE.md`. For each
setting the first source that has it wins:

- `Window: <days>`, default 90. A `--days` argument wins over it.
- `Review fixes: <extended regex>`: commit subjects that mark a review fix.
  None: `hotspots.sh` counts commits made after their PR opened instead.
- `Declined: <path>`, default `.claude/upkeep/declined.md`.
- A bullet list of extra checks for this repo. A bullet that names a command
  is run as written when it's a script in the repo or a `gh` or `git` read;
  one written in prose is done by hand, with reads. A check that would write
  is skipped, and the report says so.

No section: use the defaults, and say so on the report's coverage line.

## 2. Gather the numbers

From any checkout of the repo (the git scripts read the default branch at
`origin`, never the working tree), find the default branch
(`gh repo view --json defaultBranchRef -q .defaultBranchRef.name`), bring
`origin/<default>` up to date as above, then run these, in parallel, since
none depends on another:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/work.sh"
bash "${CLAUDE_SKILL_DIR}/scripts/backlog.sh"
bash "${CLAUDE_SKILL_DIR}/scripts/docs.sh" --ref origin/<default> --days <window>
bash "${CLAUDE_SKILL_DIR}/scripts/hotspots.sh" --ref origin/<default> --days <window> --fix-pattern '<Review fixes regex>'
bash "${CLAUDE_SKILL_DIR}/scripts/dead.sh" --ref origin/<default>
```

Drop `--fix-pattern` when no `Review fixes:` line is set. Then run the extra
checks. Each script's header says what every column means.

The scripts print `## <section>` blocks of tab-separated rows. A `skipped:` or
`note:` line goes on the report's coverage line (a cloud session's proxy
refuses GraphQL, so the branch, backlog and PR-column reads skip there). A
script that exits 2 hit a setup error, such as a missing tool or the wrong
repo: report it rather than estimate what it would have counted.

**Every number in the report comes from a script or a check you ran.** Never
estimate a count. A fact you checked by hand (a grep, a file you read) is cited
as that check.

## 3. Find the candidates

A candidate is one item: a PR, an issue, a branch, a worktree, a file or a
check's finding.

| Proposal | Source | Make it when |
|---|---|---|
| Close PRs | `open-prs` | idle 30 days or more and no `running` session. Conflicting, a draft, or its issue closed by other work makes the case stronger. |
| Delete branches, remove worktrees | `branches`, `local-branches`, `worktrees` | the branch's PR merged or closed. A worktree with `dirty` above 0 holds uncommitted work: say so, don't count it as clean. |
| Close or decline issues | `open-issues`, `possible-duplicates` | `merged-but-open`; `mentioned-by-merged` where reading both shows the merged PR did the work; a duplicate pair, after reading both; `catch-all` idle 30 days or more (split it into issues, or close it); `no-pr` and 60 days old or more. |
| Fix doc drift | `missing-paths`, checks | a skill, instructions or README names a path that's gone. Specs and plans under `docs/` are records: leave them unless they mislead. |
| Refactor or split | `files`, `instruction-sizes`, `skill-totals` | a file in the top five of `files` whose fixes came from 3 PRs or more (`fix_prs`), or an instruction or skill file among the ten largest that at least doubled in the window. |
| Delete files | `unreferenced-files`, `unreferenced-dirs` | one search shows nothing runs it (a glob, a runner script). |
| Fix what a check found | extra checks | as the check says. |

Closing counts as much as fixing: "close these eight PRs" and "delete this
script" are proposals in their own right, listed alongside refactors. Group
like items into one proposal ("Close these 12 PRs"), with each item's numbers.

- **Evidence, or no proposal.** A refactor cites its churn (fix commits and
  the PRs they came from, threads, restacks, growth), with numbers. A proposal
  that rests only on how the code reads to you is dropped: asked to find
  refactors, a model always finds some.
- **Read before proposing a close.** Read the item's latest comments, review
  comments included. A row is not enough to close someone's work. Where the
  owner chose to keep it (a `deferred` label, a comment saying to wait),
  quote that in the evidence.
- **Never propose closing an issue or PR labeled `upkeep:keep`**: the owner
  declined closing it before.

## 4. Drop the declines

The declines file holds one line per declined proposal:

```text
- <key> — declined <YYYY-MM-DD> until <YYYY-MM-DD> — <why>
```

A key is a verb and one item: `close #<n>`, `delete <path>`, `delete-branch
<name>`, `refactor <path>`, `split <path>`, `fix-docs <path>`, `check <check
name>`. Drop a candidate whose key matches a line whose until-date hasn't
passed, and drop just the matching items from a grouped proposal.

## 5. Rank and cut

Rank by what a proposal buys against what it costs, in this order:

1. Breaking now or about to: a check that will fail CI (two open PRs bumping a
   plugin to the same version), open PRs that will conflict on the same lines,
   instructions that send sessions to files that are gone.
2. Cheap closes and deletes with clear evidence. They shrink what every later
   session and survey reads.
3. Refactors and splits, the strongest evidence first.
4. The rest.

Keep at most ten, and aim for five to ten. Fewer is fine when fewer meet the
bar; never pad the list.

## 6. Report

Reply in this session, in this shape:

```text
Upkeep: <owner/repo> at <short sha>, last <n> days (since <YYYY-MM-DD>)
Coverage: <what ran; what was skipped and why; notes>

1. <What to do, in one line>
   Evidence: <the numbers, with links>
   Cost: <a command | a close per item | a one-file edit | an issue's worth | an epic>
   Buys: <what it frees or prevents>
   Key: <the decline key of each item>

2. …

Considered <N> candidates (items): <k> in the <p> proposals above, dropped <d>
(<a> declined or kept, <b> without enough evidence, <c> below the cut).
Say which to act on. To decline one, say so and why, and it won't come back.
```

## When the owner declines a proposal

Recording a decline is the owner's separate request, never part of a survey:

- An issue or PR they want kept open gets the `upkeep:keep` label:
  `gh issue edit <n> --add-label upkeep:keep` (`gh pr edit` for a PR). Where
  the repo hasn't got the label yet, create it first:
  `gh label create upkeep:keep --description "Declined in an upkeep survey: keep open"`.
- Anything else is a line in the declines file, with an until-date six months
  out unless the owner names one. It lands the way the repo lands any change.
