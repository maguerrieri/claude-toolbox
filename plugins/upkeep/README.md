# upkeep

A read-only survey of a GitHub-hosted repo, for the owner to run now and then:
type `/upkeep` (or `/upkeep --days 30`), and the session replies with five to
ten ranked proposals, each with its evidence, what it costs and what it buys.
`/simplify` and `/code-review` look at a diff; this looks at the repo over time.

It surveys:

- **stale work**: open PRs by idle days, mergeability and whether a session
  still drives them (from `claude agents --json --all`, where that's there),
  branches with no open PR (and any open PR based on one, which deleting it
  would close), local branches whose upstream is gone, and linked worktrees
  with their PR's state;
- **the backlog**: issues a merged PR closes that are still open, issues a
  merged PR mentions, issues no PR touches, catch-all issues, and pairs with
  near-identical titles;
- **docs and instructions**: paths a doc names that the repo used to have and
  doesn't any more, and instruction and skill files by size and growth;
- **hot spots, by evidence**: per file, the review-fix commits and how many
  PRs they came from (a one-PR burst reads apart from fixes that keep coming),
  review threads, restacks (force-pushes) of the PRs that touched it, and open
  PRs touching it now, over the window;
- **dead weight**: scripts, code and fixtures nothing names, tests no CI
  workflow runs, and directories nothing names;
- **the repo's own checks**, listed under `## Upkeep` in its `AGENTS.md`.

The run closes, files, edits and spawns nothing. Acting on a proposal is a
separate request, made after the report.

## The scripts

Counting is done by scripts under `skills/upkeep/scripts/`, so the numbers in a
report are counted, not estimated. Each reads only, prints `## <section>`
blocks of tab-separated rows, and documents its columns in its header:

| Script | Reads | Sections |
|---|---|---|
| `work.sh` | `gh`, `git`, `claude agents` | `open-prs`, `branches`, `local-branches`, `worktrees` |
| `backlog.sh` | `gh` (GraphQL) | `open-issues`, `possible-duplicates` |
| `docs.sh` | `git` | `missing-paths`, `instruction-sizes`, `skill-totals` |
| `hotspots.sh` | `git`, `gh` (GraphQL) | `files`, `prs` |
| `dead.sh` | `git` | `unreferenced-files`, `unreferenced-dirs` |

They need `gh`, `git` and `jq`, and run under macOS's `/bin/bash` 3.2. The
git-only ones read the default branch as `origin` has it, never the working
tree, so a survey can run from any worktree. The GraphQL reads fail in a cloud
session, whose proxy refuses GraphQL; those sections print `skipped:` and the
report says so. The skill finds its scripts through `${CLAUDE_SKILL_DIR}`,
which Claude Code expands in a skill's text (checked on 2.1.329).

## Settings: `## Upkeep`

A repo tunes the survey with an `## Upkeep` section in its `AGENTS.md` (or
`CLAUDE.md`, or `.claude/CLAUDE.md`; project memory wins over all three):

```markdown
## Upkeep

Window: 90
Review fixes: \(CRC[;,)]
Declined: .claude/upkeep/declined.md

- Plugin versions that collide across open PRs: `bash .claude/upkeep/checks.sh`
```

- `Window:` is the survey window in days (default 90).
- `Review fixes:` is an extended regex for the subjects of commits that fix
  review findings. Without it, a review fix is a commit made after its PR
  opened, matched to the default branch by author date and subject.
- `Declined:` is where declines are recorded (default
  `.claude/upkeep/declined.md`).
- Each bullet is an extra check: a read-only command to run, or a check in
  prose for the session to make with reads.

## Declines

A proposal the owner declines shouldn't come back every month, so a decline
is recorded when the owner asks for it, two ways:

- An issue or PR the owner wants kept open gets the `upkeep:keep` label, and
  no survey proposes closing it again.
- Anything else (a refactor, a deleted script, a doc fix) is a line in the
  declines file, keyed by verb and target, with an until-date:

  ```text
  - refactor plugins/x/skills/x/SKILL.md — declined 2026-11-26 until 2027-05-26 — the split waits on #362
  ```

  A survey drops a candidate whose key matches a line that hasn't expired.

## Not yet

- Scheduling: a monthly run (a cloud routine that opens the report as an
  issue, say) waits until a few reports have proved useful. A cloud run would
  need REST spellings for the GraphQL reads first.
- `upkeep` isn't a dependency of `defaults`: install it on its own,
  `claude plugin install upkeep@maguerrieri-toolbox`.
