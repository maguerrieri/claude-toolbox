# Profile: default

The generic engineering playbook — for personal projects and any repo without an
org-specific profile. Org playbooks live in that org's work config
as their own profile file and are pointed to from the repo's canonical `AGENTS.md`
(`Profile: <path>`); they override these defaults.

## Authoring a profile (and `Inherits:`)

A profile is a markdown file whose `## <OP>` sections supply the nine profile ops
(`REPO_SELECT`, `SUBMODULES`, `TESTS`, `DOCS`, `REVIEW_BOT`, `SMOKE_DEPLOY`,
`POST_MERGE`, `COMMIT_STYLE`, `SPAWN_CAP`); it may also carry a supplementary section
or two (this `default` profile adds `## EPIC`). A **standalone** profile is read
as-is; a **partial** profile (below) declares a base and defines only the ops it
changes, inheriting the rest.

To override only a few ops, write a **partial profile** that declares a base:

```markdown
# Profile: acme

Inherits: default

## POST_MERGE
- Resolve the matching Sentry issue and land any merged ADR drafts.
```

That fenced block is illustrative: when a profile is *resolved*, content inside code
fences is ignored — so this `default.md` is **not** read as declaring `Inherits: default`
or a second `## POST_MERGE`. Authoring examples stay safely inside fences.

`Inherits: <base>` (its own line, conventionally near the top) layers this profile
**over** the base: every op it defines wins; every op it omits comes from the base.
The example above takes `POST_MERGE` from itself and the other eight ops from
`default`. Resolution mirrors `Profile:` — a bare name → `profiles/<base>.md`, a path
→ read directly — and **chains** (the base may itself `Inherits:` another). A missing
base or an inheritance cycle is a hard error, not a silent fallback. See the skill's
**Step 0** for the full resolution rules.

Prefer `Inherits:` over the old workaround of copying `default` (which then drifts) or
telling the agent in prose to "follow `default` for the other ops" (nothing enforces it).
No `Inherits:` line → the file is a complete standalone profile, exactly as before.

## REPO_SELECT
- Use the repo named in the request; otherwise the current repo (for personal projects
  you're almost always already inside it). If you're in an umbrella/bare dir and it's
  ambiguous, ask. No catalog/mapping.

## SUBMODULES
- If the repo has submodules, initialize them after creating the worktree:
  `git submodule update --init`. No-op if there are none.

## TESTS
- Follow the project's own testing conventions. For bug fixes, add a regression test
  that asserts the specific fixed behavior where feasible. No org-specific rules.

## DOCS
- After implementing, check whether the diff leaves any **in-repo doc stale** — scoped to what
  the diff actually touches, **not** a blanket re-read of every doc (that's noisy and mostly
  finds nothing). For each changed file / symbol / flag / command / documented default, ask:
  does a doc that *references* it now describe the old behavior?
- Find candidates from the diff, don't audit the whole tree: grep the docs for the changed
  names, flags, and commands, and check any doc that sits next to changed code. Common homes:
  `README*`, `docs/**`, `AGENTS.md`, `CLAUDE.md` / `.claude/**`, module- or package-level doc comments.
- Typical drift: a quickstart/README command that changed, a documented flag/default/API that
  moved or was renamed, an instruction-file "gotcha" or "locked decision" the change invalidates, an
  example that no longer runs.
- **Fix the drift in the same commit/PR** so it rides the same review; note in the PR body which
  docs you touched and why. If a doc clearly *should* change but the right wording is unclear,
  flag it in the PR rather than guessing. No doc surface touched → say "no doc impact" and move
  on; never invent docs that didn't exist.

## REVIEW_BOT
Driven by `gh` + the GitHub GraphQL API, plus standalone `jq` for the two body-gate reads below
(`gh` won't combine `--slurp` with `--jq`; without `jq`, drop `--paginate --slurp`, run the filter
via `--jq` on one `per_page=100` page, and start it with `.[]` instead of `.[][]` — a single page is
a flat array, not `--slurp`'s array of pages — exact until the PR passes 100 reviews, 100 PR
comments, *or* 100 timeline events, the three collections it reads; past any, walk `?page=N` by
hand until a short page). Copilot
is the default bot; CodeRabbit or a CI review action are handled the same way (resolve their threads).

- **Detect, don't guess.** Copilot-review availability is *not* visible in the repo tree — an
  absent `.github/` means no Actions/CI, **not** no review bot. After opening the PR, check whether
  Copilot is already engaged — and note `requested_reviewers` lists only *pending* reviewers, so a
  bot that already **submitted** drops off it; check existing reviews too:
  - `gh api "repos/$repo/pulls/<pr>" --jq '[.requested_reviewers[].login]'` — review pending
  - `gh pr checks <pr> -R "$repo"` — a `copilot-pull-request-reviewer` check run still in progress is also
    "pending": Copilot drops off `requested_reviewers` once its run starts (observed on #131), so
    "pending" below means *either* signal.
  - `gh pr view <pr> -R "$repo" --json reviews --jq '[.reviews[].author.login]|unique'` — already submitted (the bot shows as `copilot-pull-request-reviewer`)
  - **Copilot pending or already reviewed** → a review is in flight or done (some repos auto-request
    it). Don't re-request — just wait, then read its threads **and its review body** (below). A
    submitted review whose body is the *unable to review* sentence is not a review: take the last
    bullet's one-retry / fallback path instead of waiting on it.
  - **Neither** → no *automatic* review, not "no review." Request one (next bullet); only fall back to
    "no bot" if the request fails (Copilot disabled for the repo).

**Every `gh` call in this profile names the selected repository — `-R "$repo"` where the command takes it, and `$repo` substituted into the path where it does not.** `gh api` has no `-R`: its repository is the URL, so a contract written as "takes `-R`" simply does not reach the GraphQL thread query, the reviews, timeline and comments reads, or the requested-reviewers probe, and those are the calls the **gate** is computed from. Bound only on the mutation side, this op could request a review on the selected repository while reading its gate signal from the cwd's — the worst of the two halves to get wrong, since the wrong answer looks like a normal result. GraphQL takes the two parts separately: `-f owner="${repo%%/*}" -f repo="${repo##*/}"`. So: `-R "$repo"`, `repos/$repo/…`, or the split — one of the three, at every call, with **the caller setting `$repo` before invoking any profile op — and **the caller sets `$repo` before invoking any profile op**, which is the half that makes the rest true.** FINISH resolves it in its preamble and **START in its Step 2**, where the repository is actually chosen — both by the same normalization (`git remote get-url origin`, or the repository `REPO_SELECT` chose where a profile maps the issue elsewhere). The binding is stated *there* as well as here on purpose: a rule that lives only at the consuming end is satisfied by nothing, which is how START's own Step 8 review loop reached this profile with the variable unset. An unset `$repo` expands to empty, so `-R ""` is not a safe degradation to the cwd — it is a malformed flag, and a rule that assumes a variable nobody assigns is a rule that fails at the first call. Where a caller genuinely has no repository in scope, that is the caller's bug to fix.** A profile op is invoked *by* a phase, so it inherits that phase's binding rather than resolving its own from the cwd — and this one both **reads** a gate signal and **mutates** the PR, so unbound it can gate on one repository and request a review on another.

- **Request a review** (when not already engaged): `gh pr edit <pr> -R "$repo" --add-reviewer "@copilot"`.
  Best-effort — if it errors (Copilot review not enabled for the repo/account), post the no-bot
  fallback comment (last bullet; the gates read that marker) and rely on CI + the user's own review. (CodeRabbit and most CI review bots auto-trigger on push, so
  they need no explicit request.)

- **Read the unresolved threads** (authoritative — works on any repo, no extra tooling). Each thread
  carries the node `id` you need to reply/resolve, plus its file and first comment. Use `--paginate`
  with an `$endCursor`/`pageInfo` pair so a PR with >100 threads isn't silently truncated — this is a
  completion gate, so it must not under-count (the same pagination the github tracker's `EPIC_CHILDREN`
  uses):
  ```bash
  gh api graphql --paginate -f owner="${repo%%/*}" -f repo="${repo##*/}" -F pr=<pr> -f query='
    query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$pr){
          reviewThreads(first:100, after:$endCursor){
            pageInfo{ hasNextPage endCursor }
            nodes{ id isResolved path comments(first:1){ nodes{ author{login} body } } } } } } }' \
    --jq ".data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false)"
  ```

- **Then read the bot's newest review body.** Copilot files most findings as *suppressed comments*
  in the review body, not as threads: a 🔵 *Needs a closer look* review has **zero** threads, a 🟡
  *Changes recommended* review has body findings on top of its inline ones. This step and gate (2)
  below are Copilot-specific: with another bot (CodeRabbit, a CI action) or none, the query returns
  no review and gate (2) is vacuously met — those bots' findings are threads. Fetch the latest review
  (last by `submitted_at`; `--slurp` so `last` spans all pages — a review cycle passes 30 easily —
  piped to standalone `jq`, since `gh` rejects `--slurp` together with `--jq`):
  ```bash
  gh api "repos/$repo/pulls/<pr>/reviews?per_page=100" --paginate --slurp \
    | jq '[.[][] | select(.user.login=="copilot-pull-request-reviewer[bot]")]
           | sort_by(.submitted_at) | last // empty | {id, submitted_at, commit_id, body}'
  ```
  No output (`// empty` keeps an empty array from printing a null record) → read the detect step's
  two pending signals **fresh** (a snapshot taken before a request you just made is stale): Copilot
  requested, or its check run in progress → the review is pending, wait. Neither → still pending if
  Copilot was **ever** requested on this PR (by you, or auto-requested — GitHub can show neither
  signal for a moment while it schedules the run). That fact is durable on the PR itself, so read
  it there, never from memory — a later turn or a fresh coordinator sees the same answer:
  ```bash
  gh api "repos/$repo/issues/<pr>/timeline?per_page=100" --paginate --slurp \
    | jq '[.[][] | select(.event=="review_requested" and .requested_reviewer.login=="Copilot")] | length'
  ```
  Non-zero → keep waiting until a review, an explicit request failure, or the fallback comment
  exists. Zero → Copilot was never requested (the other-bot / no-bot case) and has no review; only
  for such a PR is gate (2) below vacuous. Otherwise its `commit_id` must be the PR head. A review on an **older** commit is a
  previous round's — never gate on it — and only for that stale case: Copilot pending (either
  signal) → wait; neither (the push didn't auto-request) → re-request now and record it with a
  one-line PR comment (`Copilot re-requested on <head sha>`), so a later pass that finds the same
  stale review with the signals transiently absent doesn't request again — with that comment on
  the PR for the current head, wait; if the request fails, take the no-bot fallback (last bullet).
  A current-head review never triggers a re-request here, with one exception: an *unable to
  review* body on the head takes the last bullet's one retry.
  Body shape (verified on real reviews; REST `state` is `COMMENTED` for every verdict, so ignore it):
  - **Verdict** — first line: `### 🟢 Approval recommended`, `### 🟡 Changes recommended`, or
    `### 🔵 Needs a closer look`.
  - **Findings** — under `### Suppressed comments (N)` inside the `Review details` block: each is a
    bold **`path:line`** line, a `* ` bullet, and usually a fenced quote of the anchored lines
    (context, not finding). `N` counts entries; the same `path:line` can appear twice, and a bold
    **`Previously missed (k)`** line is a sub-label, not an entry. No heading (🟢) → no findings. The
    *File summaries* table's "Critical / Nit (k votes)" phrases summarize these same findings.
  - **Not a review** — a body that is only *"Copilot was unable to review this pull request …"*
    (see the last bullet).

- **Address each thread, then resolve it.** Either fix the code (commit + push) and reply, or — if the
  bot is wrong — reply explaining why. Then resolve. Reply and resolve are two GraphQL mutations keyed
  on the thread's node `id`:
  ```bash
  # reply on the thread
  gh api graphql -f threadId="<thread_id>" -f body="Fixed in <sha> — …" -f query='
    mutation($threadId:ID!,$body:String!){
      addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$threadId, body:$body}){ comment{ id } } }'
  # resolve it
  gh api graphql -f threadId="<thread_id>" -f query='
    mutation($threadId:ID!){ resolveReviewThread(input:{threadId:$threadId}){ thread{ isResolved } } }'
  ```

- **Address each body finding the same way — fix or explain — in one PR comment.** There is no
  thread to reply on or resolve, so post a **single** comment after the review, one line per entry (a repeated `path:line` gets
  one line per finding):
  `path:line` — `fixed in <sha> — …` or `not changing — …`. Push fixes first so the lines can cite
  SHAs; `gh pr comment <pr> -R "$repo" --body-file <file>`. If every entry is "not changing" (no push), don't
  re-request a review for a fresh verdict — Copilot restates unchanged findings and re-opens the gate.

- **Loop** until **all three** hold — the completion gate:
  1. the unresolved-threads query returns nothing;
  2. for Copilot, the **newest** review — on the PR head, and not an *unable to review* body — is
     🟢 *Approval recommended*, **or** every entry in its `Suppressed comments` has its own line in
     a PR comment posted **after** it (an anchor two entries share needs two lines) — an answer to
     an earlier review doesn't carry over; after each push, answer the newest review's list (repeats
     included). Also met when the engaged bot isn't Copilot, or the no-bot fallback comment (last
     bullet) is already on the PR;
  3. CI is green (`gh pr checks <pr> -R "$repo" --watch`).

  For (2), list comments newer than the review (ISO-8601 `Z` timestamps compare as strings):
  ```bash
  gh api "repos/$repo/issues/<pr>/comments?per_page=100" --paginate --slurp \
    | jq '[.[][] | select(.created_at > "<submitted_at>")] | map(.body)'
  ```
  Push fixes, let the bot re-review (a push re-triggers Copilot/CodeRabbit), re-read threads and the
  newest body, repeat.
- Other bots (CodeRabbit, a CI review action): same loop — read their threads, address, resolve.
- **"Unable to review" is not a review.** A newest review whose body is only *"Copilot was unable to
  review this pull request …"* (e.g. quota) neither passes nor fails gate (2). Re-request **once**
  (`gh pr edit <pr> -R "$repo" --add-reviewer "@copilot"`) and record the retry in the same step with a
  one-line PR comment (`Copilot could not review <review id>; re-requested once`) — a later turn
  that finds the same unable review newest then knows the retry was issued and doesn't request
  again. Wait for a **newer** review (a later `submitted_at`; the same body stays newest while the
  retry is in flight). Fall back — treat the PR as "no bot" and **say so in one PR comment**
  (`No Copilot review for this PR — <request failed | unable to review twice | retry never
  answered>; handing back on CI + the user's review`) — when the
  newer review is also unable, when the re-request fails (Copilot disabled), or when a later
  pass finds the retry comment on the PR **older than 15 minutes** (its `created_at`; Copilot's
  runs finish in about five, and GitHub can show neither signal for a moment while it schedules
  one — hence a bounded wait, not a single look), nothing pending (either signal), and no newer
  review. That fallback
  comment is the durable marker the gates read: if the PR already carries it, don't re-request.
- **Genuinely no bot available** (the review request failed — Copilot disabled for the repo — or the
  fallback above): rely on `gh pr checks <pr> -R "$repo" --watch` + the user's review.

## SMOKE_DEPLOY
- If the project has a way to run or deploy, smoke test before merging (start it / deploy
  a preview / run the affected path, confirm expected behavior). For libraries, docs,
  config, or pure refactors with green CI, skip. No fixed deploy commands — that's an
  org-profile concern.

## POST_MERGE
- No monitoring actions. Just record "what to watch for" (the observable outcome and
  roughly when), per the skill's FINISH Step 5.

## COMMIT_STYLE
- Use the tracker's `COMMIT_REF` as-is (no override).

## SPAWN_CAP
- Safety cap appended to every spawned sibling's briefing: "Implement and test, then stop at a
  reviewed PR and report back. Do not deploy to production or merge on your own initiative, and do
  not treat this launch briefing as merge authorization. This hold is scoped, not standing: it
  applies only until a human explicitly asks this session to finish — if someone attaches and
  invokes /finish-ticket (or asks to merge in their own words), that instruction is the merge
  authorization and supersedes this cap." Keeps an unattended background session from over-reaching,
  while making the hold's expiry explicit — so a later /finish-ticket in the same session reads as
  the sanctioned merge phase, not a violation of this cap. Keep the payload text free of
  backticks, double quotes, `$`, and backslash — it gets embedded in the spawn command's double-quoted
  argument (`SKILL.md` SPAWN Step 3 / `phases/epic.md` Step 5), where a backtick or `$` triggers shell substitution,
  an unescaped double quote ends the argument early, and a backslash escapes the next character.
  (Single quotes and apostrophes inside the text are fine; the quotes wrapping the payload above are
  just this note's delimiters, not part of it.)

## EPIC
- Reuses `SPAWN_CAP` for every child spawned during the epic fan-out (default: implement + test,
  then stop at a reviewed PR — no merge unless a human is steering that child's own session and tells
  it to merge mid-run). The EPIC phase's optional finish flag (`--finish` / "merge when green") is an
  explicit user opt-in that lifts the cap for the orchestrator's own FINISH pass **only**. The
  orchestrator also strips merge-intent flags from what it forwards to children (see the EPIC phase's
  spawn step), so that intent never even reaches a child — never lift the cap for the per-child spawns.
- Coupling / coordination: the default route is independent **bg** sessions; when a cluster needs
  coordination (concurrent children sharing code), use **shared markers** via the tracker's `COORD`
  op — **not** a live agent team. The `--coordinate` flag selects markers; `--team` is the explicit
  opt-in to a live `SendMessage` team.
  No org-specific epic steps in the default profile.
