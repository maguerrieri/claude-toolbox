# Budgets (`Budget:` directive)

A stop condition for an unattended run that isn't "until it works" — wall-clock
minutes and review rounds, from the software-factory design's item 2e. The
profile's `SPAWN_CAP` appends one to every spawned child; a spawner may override
it. **Read this file when a `Budget:` directive is present** (START Step 1, EPIC
Step 1, SPAWN Step 2); a run with no directive is unbudgeted and none of this
applies.

## Grammar

```
Budget: wall_clock_min=<N> review_rounds=<M>
```

Both keys, in that order, non-negative integers with **no leading zero** (`0`
itself is fine — bash reads `08` as octal, so the grammar excludes it), nothing
else on the line. `<N>` is the most whole minutes a START run may spend from its
Step 1 clock note to hand-back; `<M>` the most fix-pushes its Step 8 may make.

A line that doesn't match exactly is a **briefing error: stop and report it**,
never "no budget" — a malformed directive must fail closed, since the alternative
is an unattended session running unbounded.

**An override** (in a spawn request, shared or per-issue) is `Budget:` plus one
*or both* keys, same value rules. It merges over the cap **key-wise, in the order
cap → shared → per-issue**: for each key, the last source naming it wins (cap
180/5, shared `review_rounds=3`, per-issue `wall_clock_min=60` →
`wall_clock_min=60 review_rounds=3`). Validate every override against this
grammar **before launching anything** — forwarding `wall_clock_min=abc` either
stops each child at its own Step 1 or, if dropped, unbounds it.

Exactly one `Budget:` line reaches a child whenever the cap or an override
supplies a budget, and **none** when a profile's `SPAWN_CAP` omits the line and
no override was given — adding one there would invent a budget the profile
deliberately declined. A cap with no line has nothing to merge into: forward a
full override as-is, and treat a *partial* one as an error rather than inventing
the missing key. Never forward two lines; START defines precedence for
directives, not for duplicates.

## The marker

A directive held only in context survives `/clear`, resume, and compaction no
better than `Role:` does, and a budget that evaporates is no budget. So persist
it beside the role marker, as `<session-id>.budget`:

```
run: <issue id> <branch>
clock: <epoch seconds, captured at the Step 1 clock note>
Budget: wall_clock_min=180 review_rounds=5
round: 1
round: 2
```

- **`run:`** is the run identity — the issue ID and branch this budget belongs
  to. The file is keyed only by session, so without it a session that finishes
  one ticket and starts another before cleanup would read the first ticket's
  spent clock as authoritative. A marker whose `run:` doesn't match the current
  ticket belongs to a finished run: **replace it**, don't resume from it.
- **`clock:`** is epoch seconds (`date +%s` — portable, and what the deadline
  arithmetic below needs), captured at the **same moment** as Step 1's clock
  note, not later. Writing it after issue-reading and setup would start the
  deadline late and grant more than the requested budget.
- **`Budget:`** carries the **validated numbers**, never the `<N>`/`<M>`
  placeholders this file writes them as — the enforcement below reads this line
  as authoritative, so a literal placeholder makes the budget unenforceable.
- **`round:`** lines are appended by the enforcement loop, one per fix push.

Write it once per run, and only when the existing file is absent, invalid, or
another run's:

```bash
roles_dir="${CLAUDE_SESSION_ROLES_DIR:-$HOME/.claude/session-roles}"
budget_file="$roles_dir/$CLAUDE_SESSION_ID.budget"
clock_epoch=$(date +%s)        # the Step 1 clock note's own moment
wall_clock_min=180             # substitute the validated numbers from the directive
review_rounds=5
run_id='#42 42-fix-flaky-upload'

usable() {   # a marker is usable only if it is this run's and well-formed
	[ -f "$budget_file" ] &&
		grep -qxF "run: $run_id" "$budget_file" &&
		grep -qxE 'Budget: wall_clock_min=(0|[1-9][0-9]*) review_rounds=(0|[1-9][0-9]*)' "$budget_file" &&
		grep -qxE 'clock: [0-9]+' "$budget_file"
}

if [ -n "$CLAUDE_SESSION_ID" ]; then
	mkdir -p "$roles_dir"
	usable || printf 'run: %s\nclock: %s\nBudget: wall_clock_min=%s review_rounds=%s\n' \
		"$run_id" "$clock_epoch" "$wall_clock_min" "$review_rounds" >"$budget_file"
fi
```

The guard is `usable`, not merely "does the file exist". A **valid marker for
this run is authoritative** — Step 1 re-runs on every resume and after each
compaction, and rewriting it would restart the clock and discard the `round:`
lines, handing a spent budget a fresh one on each context loss. An **invalid or
foreign** marker is replaced instead, so a truncated or interrupted write can't
make the budget permanently unrecoverable.

`$CLAUDE_SESSION_ID` unset (this plugin's SessionStart hook didn't run) → no
marker; keep the directive in context and say in the hand-back that a compaction
would lose it. That's the same degradation `/role` documents.

**Lifecycle.** The SessionStart hook refreshes this file alongside the role
marker so its own 30-day reaper can't delete a live run's state, and `/role none`
removes it with the marker.

## Recovery after a context loss

In order:

1. **The marker**, when `usable` above holds — it is the provenance, the clock,
   and the rounds already spent.
2. **The briefing's directive**, if still in context. Measure the clock from the
   branch's first commit (START Step 7's fallback) and count rounds as the
   branch's commits dated after the PR opened (`gh pr view <pr> --json
   createdAt`), rounding **up** when unsure — an over-count stops sooner, which
   is the safe direction.
3. **Neither → the budget is unrecoverable.** Never infer one from the role
   marker: `/role implementer` and a generic `/spawn` write the same marker with
   no cap, so it proves nothing about a budget. Never substitute the profile
   default either. Record `budget: unrecoverable after context loss` in the
   Evidence `tests` string and in the hand-back, and continue.

## Enforcement

A **review round** is one push made in START Step 8 to address review-bot threads
or a CI failure, together with the re-review or CI run it triggers.

**Append `round: <k>` before each fix push, never after.** A session interrupted
between a successful `git push` and a later append would leave recovery reading a
stale count and granting an extra round. Counting a push that then fails is the
safe direction: it can only stop sooner.

A budget is **spent** when the next push would be round `<M>+1`, or when elapsed
whole minutes are at or past `<N>` (`>=`, so `wall_clock_min=0` is spent at the
first check). Check before each fix push and at every step boundary from Step 5
on.

**Never wait unbounded while a budget is set.** This poll replaces *every*
`--watch` and open-ended wait — START Step 8's CI watch and every one the
profile's `REVIEW_BOT` loop shows, the `default` profile's own `gh pr checks
<pr> --watch --fail-fast` included. Don't reach for GNU `timeout`; a stock macOS
lacks it.

```bash
deadline=$(( <clock epoch from the marker> + 10#<N> * 60 ))
until [ "$(date +%s)" -ge "$deadline" ]; do
	poll_status=0; gh pr checks <pr> >/dev/null 2>&1 || poll_status=$?
	[ "$poll_status" -ne 8 ] && break
	sleep 60
done
```

`gh pr checks` exits 8 while checks are pending; the same loop shape re-reads the
review bot's threads. Two details that are not cosmetic: capture the status with
`|| poll_status=$?` rather than testing a bare `$?`, which under `set -e` aborts
on the expected pending exit before it can be inspected; and don't name that
variable `status` — tool commands run under **zsh**, where `status` is a
read-only alias for `?`, the same hazard the repo instructions record for `path`.
The `10#` keeps the arithmetic base-10. A deadline reached mid-wait is itself the
overrun.

## Stopping

Once a budget is spent, **stop instead of looping** — no further fix pushes.
Finish only what is safe to finish, then hand back:

- The commit in progress; and START Step 7's push and PR if the clock ran out
  before it, opened as a **draft** (the hold signal FINISH's gate already
  honors).
- Reply on each still-open review thread that the budget is exhausted, but leave
  it **unresolved** — resolving without addressing would misreport.
- Update the Evidence block **in place**: a trailing `; budget_exceeded:
  <wall_clock_min|review_rounds> <used> of <limit>` clause inside `tests`, and
  `wall_clock_min` re-measured to the stop. The schema has no key for the
  overrun, and this keeps the block to exactly one per body.
- Ping `blocked: budget exceeded (<which>)` if a `Notify:` directive is wired.

**Nothing committed yet** — the clock ran out before the first commit, so there
is no diff to open a PR on and no Evidence block to carry the record. Skip the
push and record the stop **durably on the ticket** with the tracker's
`COMMENT(id, body)` op, body `blocked: budget exceeded (<which>), nothing
committed`; a cloud child has no `Notify:` channel and no PR for a coordinator's
poll to read, so without this the row is an unexplained no-PR stuck.

Where a PR exists it is handed back as it stands — red CI or open threads
included — and the report names the spent budget. **Re-briefing with a larger
budget is the spawner's call, never this session's.**

## Cleanup

Clear the marker on **every** hand-back: START Step 9, both early opt-outs (which
return from Steps 4 and 6 without passing Step 9), a budget stop itself, and both
EPIC hand-back paths (EPIC never reaches START Step 9, so that is its only
cleanup). Otherwise a later, differently-budgeted or unbudgeted run in the same
session reads this one's spent clock and round count as authoritative.

Recompute the path rather than relying on a variable from an earlier snippet —
each step runs in its own shell — and guard the session id, or the expansion
becomes `$roles_dir/.budget` and removes a file that isn't this session's:

```bash
roles_dir="${CLAUDE_SESSION_ROLES_DIR:-$HOME/.claude/session-roles}"
[ -n "$CLAUDE_SESSION_ID" ] && rm -f "$roles_dir/$CLAUDE_SESSION_ID.budget"
```

The role marker stays; only the budget sidecar is per-run.
