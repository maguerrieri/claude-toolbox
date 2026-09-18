# Tracker adapter: GitHub Issues

Use the `gh` CLI. In worktrees, cwd detection usually works, but pass `-R OWNER/REPO` if `gh` ever picks the wrong repo — derive `OWNER/REPO` from the worktree's own remote (`git -C <worktree> remote get-url origin`, e.g. `git@github.com:OWNER/REPO.git` → `OWNER/REPO`), not from `gh` itself (it uses the same cwd detection and would just repeat the error).

## ID format
- An issue ID is a number, written `42` or `#42`. Strip any leading `#`.

## BRANCH(id)
- `issue-<n>` by default, or `<n>-<kebab-slug>` where the slug is derived from the issue title (lowercased; non-alphanumerics → `-`; collapse repeated `-`; strip leading/trailing `-`; ~6 words max). Prefer the slug form when the title is meaningful.
- Example: issue `42` "Fix flaky upload retry" → `42-fix-flaky-upload-retry`.

## FETCH(id)
```bash
gh issue view <n> -R <owner>/<repo> --json number,title,body,labels,assignees,url
```
Read `title` and `body`. Look in `body` for a base-branch directive (e.g. "Base branch: `dev`").

## SEARCH(query)  — find existing open issues (FILE phase dup check)
```bash
gh issue list -R <owner>/<repo> --search "<query>" --state open --json number,title,url -L 50
```
- Set `-L`/`--limit` explicitly — `gh issue list` silently defaults to **30** (the same footgun `EPIC_CHILDREN` calls out); 50 is plenty for a keyword dup check.
- `<query>` is plain keywords (GitHub search syntax is accepted but not required). Keep it to the 2–4 distinctive terms FILE Step 2 derived — an over-specific query returns nothing and under-checks.
- Returns `(number, title, url)` per hit. The *judgment* — is a hit the same work? — belongs to FILE Step 2, not this op.
- Errors (network, auth) are **non-fatal** for FILE: report the failure and let Step 2's degrade-to-filing path handle it.

## CREATE(title, body, labels?)  — file a new issue (FILE phase)
```bash
gh issue create -R <owner>/<repo> --title "<title>" --body-file <path>  [--label "<label>"]
```
- Write the body to a temp file and pass `--body-file` — issue bodies are multi-line, quote- and backtick-heavy markdown, and a file sidesteps the brittle shell escaping an inline `--body "…"` would need.
- `--label` is best-effort: it errors if the label doesn't exist in the repo (`gh` doesn't create labels on the fly) — retry without it rather than failing the CREATE.
- On success `gh issue create` prints the new issue's URL; the trailing path segment is the number (`…/issues/57` → `57`). Return that number — it's the `<n>` every other op consumes.

## START(id)  — mark in-progress (optional, light)
```bash
gh issue edit <n> -R <owner>/<repo> --add-assignee @me
# optional, only if the repo uses such a label:
gh issue edit <n> -R <owner>/<repo> --add-label "in progress"
```
Skip silently if it errors (e.g. label doesn't exist) — START is best-effort.

## COMMIT_REF(id)  — commit message format
- Follow the repo's commit convention. In this marketplace that's the `conventions` plugin's
  format: `[#<n>] (<flags>) <scope>: <description>` — the GitHub issue in brackets, AI-assistance
  flags in the subject parens.
  - e.g. `[#42] (Claude Code + Opus 4.8) upload: retry transient 5xx with backoff`
- If the repo documents no convention, a plain conventional-commit subject that references the
  issue in trailing parens is fine: `<scope>: <description> (#42)`.

## PR_REF(id)  — PR title + issue link
- **Title:** `<scope>: <description> (#42)` — reference the issue in trailing parens. (Commit
  *subjects* follow the `conventions` bracket form above; PR titles conventionally don't carry the
  bracket — follow the repo's own PR-title style if it differs.)
- **Body footer:** include a closing keyword so the merge auto-closes the issue:
  - `Closes #42`  (use `Fixes #42` for bugs if you prefer)
- Because of the closing keyword, FINISH's `DONE` is usually automatic.

## DONE(id)  — close the issue
- If the PR body had `Closes #<n>`, merging already closed it — verify with `gh issue view <n> -R <owner>/<repo> --json state -q .state` (expect `CLOSED`).
- If it's still open:
```bash
gh issue close <n> -R <owner>/<repo> --comment "Resolved by #<pr> (merged)."
```

## EPIC_CHILDREN(id)  — list an epic's child tickets (EPIC phase)
GitHub has no native "epic", so an epic is one of these — try in order:
- **Native sub-issues** (GitHub's sub-issue feature). List via GraphQL — `{owner}`/`{repo}` auto-populate from the current repo (verified on gh 2.88.1), so no manual substitution; replace only `<n>`:
```bash
gh api graphql --paginate -f query='query($owner:String!,$repo:String!,$num:Int!,$endCursor:String){repository(owner:$owner,name:$repo){issue(number:$num){subIssues(first:100, after:$endCursor){totalCount pageInfo{hasNextPage endCursor} nodes{number title state labels(first:20){nodes{name}}}}}}}' -F owner='{owner}' -F repo='{repo}' -F num=<n>
```
  `--paginate` auto-follows pages via the `$endCursor`/`pageInfo` pairing (verified on gh 2.88.1), so an epic with **>100** children isn't silently truncated — keep the `$endCursor` var, the `after:$endCursor` arg, and `pageInfo` intact.
- **Task-list / tracking issue:** the epic's body has a checklist that references child issues (`- [ ] #123`). Parse `#<n>` refs from the body — use `-q .body` so you get raw text, not a JSON object with escaped newlines: `gh issue view <n> -R <owner>/<repo> --json body -q .body`.
- **Shared label or milestone:** `gh issue list -R <owner>/<repo> --label "epic:<name>" --json number,title,state,labels -L 500` (or `--milestone "<name>"`) — set `-L`/`--limit` explicitly; `gh issue list` defaults to **30**, which would silently cap a large epic.

Return `(number, title, labels)` for each child — the labels feed the EPIC coupling router (`phases/epic.md` Step 3). If none of these apply, ask the user for the child IDs.

## DEPS(id)  — intra-epic dependencies for a child (EPIC phase)
GitHub has no first-class issue dependencies, so derive them:
**A fork PR is never a base.** `gh pr list -R <owner>/<repo>` includes PRs whose *head* lives in a fork, so a dependency lookup that returns `headRefName` alone can hand START a branch name that exists only in someone else's repository — which START then treats as a local base to cut from and, later, to push to. Worse, that name can collide with a real local branch and silently select the wrong one. So `DEPENDENCY_PR` filters `isCrossRepository == false` (the head-repository fields are in the query for that reason) before returning a branch, and a fork PR that would otherwise have been the unique match is reported as *not stackable* rather than used. This is the same ownership test Step 6 applies before rewriting a branch, applied one step earlier — at the point the name is chosen rather than the point it is written to.

- **Body directives:** `Depends on #<n>` / `Blocked by #<n>` / `After #<n>` in the child's body (`gh issue view <n> -R <owner>/<repo> --json body -q .body` — `-q .body` for raw text). Parse the `#<n>` references.
- **Ordered task list:** only if the user says the epic's checklist is ordered (each item depends on the one above) — order is *not* dependency by default.

Return the set of child numbers this child is blocked by, **keeping only those that are themselves children of this epic**. Empty set → it's a root.

## DEPENDENCY_PR(id)  — find the open PR for a dependency (START phase)
GitHub PRs created by this workflow close their issue from the body, so search for an exact closing reference (not merely `#<n>` appearing in discussion):
```bash
gh pr list --state open -R <owner>/<repo> -L 500 --search "#<n> in:body" --json number,headRefName,isCrossRepository,headRepositoryOwner,headRepository,body --jq '.[] | select((.body // "") | test("(?i)(closes|fixes|resolves):?\\s+#<n>\\b")) | select(.isCrossRepository == false) | {number,headRefName}'
```
Return the match only when there is **exactly one**; zero or multiple is ambiguous and START falls back rather than guessing.

## COORD(epic_id)  — coordination channel for EPIC runs (EPIC phase)
The shared, durable channel sibling sessions use for file **claims** and **"branch pushed" / "done"** markers when EPIC Step 3 routes a cluster to *coordinated* mode — **and**, regardless of routing mode, the three records EPIC writes on *any* run: the `lock:` record (**`lock: <key> ref=<ref> token=<object id> session=<session id>`**, written as each lock is taken — it is what lets a coordinator whose container is replaced between turns prove the lock it still holds is its own, by object id, instead of stranding the epic or reclaiming it; amended with the in-flight operation where one spans a turn), the `stack:` record (Step 6, when a native stack is registered) and every `restacked:` record (Steps 4, 6 and 7 — whenever the orchestrator rewrites a child branch, the finish pass included, **and when a *child* rewrites its own**: START Step 7's pre-push rebase pings `rebased: <branch> onto <base> @ <sha>`, and the coordinator verifies that SHA and publishes the `restacked:` record for it, since the ping is a transient message and the fork point has to outlive it). Those two are not scoped to coordinated runs: an ordinary bg chain gets restacked too, and its fork points survive nowhere else. On GitHub the epic is itself an issue, so `<epic_id>` here is its **number** (the same numeric `<n>` form as any issue, `#` stripped). Use the **epic issue's comments**:
```bash
body=$(mktemp)                                         # NEVER build the marker inline in the
printf 'claim: %s -> %s\n' "$session" "$files" > "$body"   # command itself — see below
gh issue comment <epic_id> -R <owner>/<repo> --body-file "$body"; rc=$?
rm -f "$body"; [ $rc -eq 0 ] || { echo "file claim write failed — do not start editing these files"; exit $rc; }

# TWO claim shapes, same channel and same write discipline — don't overload one for the other:
#   file claim   (coordinated runs, EPIC Step 3): claim: <session> -> <files>          — above
#   branch claim (every run, EPIC Step 5):        claim: <branch> -> <session> for <child id> (epic <epic_id>) base=<base>
# The branch claim is the RECORD of a reservation the lock ref already took (EPIC Step 5); its
# branch and child fields are what a later reader matches on, so a file-claim-shaped body posted
# in its place records nothing a second coordinator can use.
# `base=` is not decoration: between launch and the child's first push there is no branch and no PR
# on the server, so this field is the ONLY thing telling a second coordinator's chain-top walk that
# this child occupies that base (EPIC Step 4). Omit it and that walk assigns another child there.
body=$(mktemp)
printf 'claim: %s -> %s for %s (epic %s) base=%s\n' "$branch" "$session" "$child_id" "$epic_id" "$base" > "$body"
gh issue comment <epic_id> -R <owner>/<repo> --body-file "$body"; rc=$?
rm -f "$body"
# NOT launch-blocking, and this `exit` used to be. The phase is explicit: where COORD is unwritable
# the RECORD is unavailable but the RESERVATION is not — the lock ref is the reservation — so a
# failed pre-launch claim is reported, not obeyed. Blocking here strands a name this run already
# holds a lock on, every time comments are temporarily unwritable. (Cloud is the exception, and it
# is a precondition rather than a retry: a cloud reservation crosses a turn boundary and needs the
# `lock:` record to be adoptable, so on cloud an unwritable channel means do not launch at all —
# checked BEFORE taking the ref, not discovered here.)
[ $rc -eq 0 ] || { echo "pre-launch claim write failed — reservation stands; launch and report the missing claim"; }
# …and AFTER the child launches, a SECOND record naming it — EPIC Step 5's takeover rule decides on
# the CHILD's liveness (a child outlives the coordinator that spawned it), so a claim posted before
# launch cannot answer the question a later run asks. Run this the moment the backend returns an id:
body=$(mktemp)
printf 'claim: %s -> %s for %s (epic %s) base=%s child=%s\n' \
  "$branch" "$session" "$child_id" "$epic_id" "$base" "$child_session_id" > "$body"
gh issue comment <epic_id> -R <owner>/<repo> --body-file "$body"; rc=$?
rm -f "$body"
# NOT the pre-launch handling, and not a copy of it: the child is already running, so "do not launch
# on this name" would be advice about a decision already taken. Retry the write once; if it still
# will not land, do NOT exit quietly and do NOT release or sweep this child's reservation. A live
# child with no `child=` record is precisely the state a later run reads as reclaimable — the
# takeover rule decides on the CHILD's liveness, and the only record that would name that child is
# the one that just failed — so freeing the name here is how a SECOND child gets launched on the
# same branch. Hold the lock (its release point is "the name stops being this run's to hold", which
# has not happened — EPIC's lock protocol, step 5) and report an unresolved handoff for a human.
# NOT `blocked-unrecordable`, and NOT a stop. The phase reserves that state for a fork point whose
# SHA is unrecoverable, and it is TERMINAL — it would mark a healthy, running child dead and
# propagate `blocked-by-…` to its dependents, while its reservation is deliberately being kept.
# The child is fine; it is the coordinator's record that is missing. So leave the child's row
# alone, keep the reservation, carry on with the rest of the wave, and report the gap (branch +
# child session id) with the epic flagged as needing a human before a second coordinator runs it.
# The retry the comment above promises — one, and actually written out. A single transient 5xx
# otherwise loses the only record naming this child, which is the whole failure being guarded.
if [ $rc -ne 0 ]; then
  body=$(mktemp)
  printf 'claim: %s -> %s for %s (epic %s) base=%s child=%s\n' \
    "$branch" "$session" "$child_id" "$epic_id" "$base" "$child_session_id" > "$body"
  gh issue comment <epic_id> -R <owner>/<repo> --body-file "$body"; rc=$?
  rm -f "$body"
fi
[ $rc -eq 0 ] || { echo "post-launch claim write failed twice — child $child_session_id is LIVE on $branch:" \
                        "keep its row, hold the reservation, report the gap, do not relaunch"; }
# ONE ordering rule, stated identically in EPIC Step 5: group the records by (session, branch)
# — NOT by session alone, or a coordinator holding one claim per child keeps a single newest record
# and discards the child= liveness evidence for every other branch it reserved — then within each
# group collapse that session's records for that branch to its
# NEWEST (so this post-launch record supersedes that session's own pre-launch one), then among the
# survivors, still unspent, the EARLIEST by record id holds the name. "Newest" resolves a session's
# own history; "earliest" resolves who won the race — either half alone lets two coordinators pick
# different holders.
# Read markers WITH their id, author and timestamp — all three are load-bearing (EPIC's fork-point
# rules authenticate a `restacked:` marker by author and take the newest; Step 5 arbitrates two
# claims on one branch by ID, because `created_at` is second-granular and can tie), and this
# endpoint paginates:
gh api --paginate repos/<owner>/<repo>/issues/<epic_id>/comments \
  -q '.[] | {id, created_at, author: .user.login, body} | @json'   # ONE JSON object per line, body escaped
```
`<owner>/<repo>` is the repository `REPO_SELECT` chose, spelled out rather than left to cwd detection — the note at the top of this adapter applies here as much as anywhere, and an unbound read silently returns another repository's comments (or none), which for fork-point markers means a cascade that cannot find the SHA it needs. **Emit one JSON object per comment, never a delimited text line.** Parse each line as JSON; if a line parses to a *string* rather than an object, parse it once more (`fromjson`) — `@json` renders the object as a JSON string, and whether the surface prints that string raw (a JSON object per line, which is what `jq -r` does — verified here) or quoted depends on the client, so handle both rather than assuming one. A body is arbitrary user text: with a `"\(.created_at)\t\(.user.login)\t\(.body)"` format, a comment containing a newline and tabs splits into *two* apparent records, and the second carries whatever author and timestamp its author typed. Demonstrated 2026-09-16: one comment by `attacker` yielded a second line reading `maguerrieri` with a `restacked:` marker and an attacker-chosen SHA — which is exactly the author check that the fork-point rules rest on, defeated by the *reader's* formatting. JSON keeps the body a single escaped string, so the boundary survives and the author stays whoever posted it; parse markers **within** one comment's body. `gh issue view --json comments` is fine for a quick human read, but don't use it where the author or ordering matters: it does not page, so on a long-running epic the newest markers are exactly the ones it drops.
**Write every marker through `--body-file`, never `--body "…"`.** A marker carries a session name and file paths, and those are arbitrary text. The hazard is not that a quoted `"$session"` expands — it doesn't; the shell does not re-parse a variable's value (measured 2026-09-18: with `session='mari$(touch pwned)'`, `printf '%s\n' "claim: $session"` prints the text and runs nothing). It is that `--body "claim: <session> -> <files>"` is a *template to fill in*, and filling it in means pasting those values into the **command text** — where `$(…)`, a backtick or a quote is parsed as syntax, not data (same measurement, same values, pasted instead of expanded: the substitution ran and the marker landed without it). `--body-file` removes the temptation: `printf` the values through quoted variables into a file, and nothing that reaches `gh` was ever part of a command line. This is the same rule the EPIC launch follows for its briefing (`phases/epic.md` Step 5): build the text in a file, hand `gh` the file. **A `restacked:` marker is trusted only when it is the comment's *whole body*** — one marker, first line, nothing else around it. Markers are grepped out of arbitrary bodies, and a body is arbitrary text from a session that shares the coordinator's login, so a `claim:` or `done:` payload carrying a newline and a `restacked: … @ <sha>` line would pass the author check on the strength of the comment it was smuggled inside. Ignore a marker-looking line that shares a body with anything else, for the fork-point rules' purposes; `claim:`/`pushed:`/`done:` are not SHAs anyone rebases from, so they keep the loose form. Markers are plain prefixed lines (`claim:`, `pushed:`, `done:`, `restacked: <branch> onto <base> @ <sha>` — the orchestrator rewrote a child's branch to linearize a chain, or a merge below it did, EPIC Step 4/6/7; `<sha>` is the base tip the branch now forks from, which a force-pushed base makes unrecomputable from the refs, so a session holding that branch must fetch before it pushes and must rebase from this SHA rather than a merge-base, `stack: <s> <bottom-pr>..<top-pr>` — a registered native stack's bare number plus its PR range, EPIC Step 6) so siblings can grep them. Keeps coordination tracker-native and inspectable; no live agent team required.

## Review bot
- The review bot is a **profile** concern, not tracker-specific — see the selected profile's `REVIEW_BOT` (the `default` profile drives Copilot via `gh`).
