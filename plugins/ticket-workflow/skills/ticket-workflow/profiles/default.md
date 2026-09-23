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

**Overriding `REVIEW_BOT` replaces the review-round cap with it.** The cap's mechanics — the
round count, the cap and its default, the spiral check, *At the cap*, the **valid cap marker**
the START and EPIC gates point to, and *Raising the cap* — live in this profile's `REVIEW_BOT`,
and an op override replaces the whole section. A profile that overrides `REVIEW_BOT` and wants
a cap carries those bullets over; one that doesn't has no cap, and the gates' cap alternative
never applies (START Step 8). Either way it also overrides `SPAWN_CAP`, whose inherited
`Budget: rounds=15` would otherwise win as the larger value: its own `Budget:` line matches its
own default cap, or is dropped when it has none.

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
Driven by `gh` + the GitHub GraphQL API, plus standalone `jq` for the body-gate and round-count reads below
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
  - `gh api repos/OWNER/REPO/pulls/<pr> --jq '[.requested_reviewers[].login]'` — review pending
  - `gh pr checks <pr>` — a `copilot-pull-request-reviewer` check run still in progress is also
    "pending": Copilot drops off `requested_reviewers` once its run starts (observed on #131), so
    "pending" below means *either* signal.
  - `gh pr view <pr> --json reviews --jq '[.reviews[].author.login]|unique'` — already submitted (the bot shows as `copilot-pull-request-reviewer`)
  - **Copilot pending or already reviewed** → a review is in flight or done (some repos auto-request
    it). Don't re-request — just wait, then read its threads **and its review body** (below). A
    submitted review whose body is the *unable to review* sentence is not a review: take the
    *Unable to review* bullet's one-retry / fallback path instead of waiting on it.
  - **Neither** → no *automatic* review, not "no review." Request one (next bullet); only fall back to
    "no bot" if the request fails (Copilot disabled for the repo).

- **Request a review** (when not already engaged): `gh pr edit <pr> --add-reviewer "@copilot"`.
  Best-effort — if it errors (Copilot review not enabled for the repo/account), post the no-bot
  fallback comment (the *Unable to review* bullet; the gates read that marker) and rely on CI + the user's own review. (CodeRabbit and most CI review bots auto-trigger on push, so
  they need no explicit request.)

- **Read the unresolved threads** (authoritative — works on any repo, no extra tooling). Each thread
  carries the node `id` you need to reply/resolve, plus its file and first comment. Use `--paginate`
  with an `$endCursor`/`pageInfo` pair so a PR with >100 threads isn't silently truncated — this is a
  completion gate, so it must not under-count (the same pagination the github tracker's `EPIC_CHILDREN`
  uses):
  ```bash
  gh api graphql --paginate -f owner=OWNER -f repo=REPO -F pr=<pr> -f query='
    query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$pr){
          reviewThreads(first:100, after:$endCursor){
            pageInfo{ hasNextPage endCursor }
            nodes{ id isResolved path comments(first:1){ nodes{ url author{login} body pullRequestReview{ url } } } } } } } }' \
    --jq ".data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false)"
  ```
  Match threads by the URLs' fragments, not by GraphQL `databaseId`: that field is a 32-bit `Int`,
  and real review and comment ids are already past 2^31 (review 5285530608, comment 4077469440).
  `pullRequestReview.url` ends in `#pullrequestreview-<id>`, where `<id>` is the REST review `id`
  of the review that opened the thread. The first comment's `url` ends in `#discussion_r<id>`,
  which is the anchor a v2 Copilot body's `Open` entry links to (body shape, below).
  The valid cap marker's coverage check below runs this query **without** the `isResolved`
  filter and keeps the threads whose `pullRequestReview.url` ends in the newest bot review's `id`.

- **Then read the bot's newest review body.** Copilot lists findings in the review body that have
  no thread (legacy *suppressed comments*; v2 *Previously missed* entries): a 🔵 *Needs a closer
  look* review can have **zero** threads and still carry findings, and a 🟡 *Changes recommended*
  review can have body findings on top of its inline ones. This step and gate (2)
  below are Copilot-specific: with another bot (CodeRabbit, a CI action) or none, the query returns
  no review and gate (2) is vacuously met — those bots' findings are threads. Fetch the latest review
  (last by `submitted_at`; `--slurp` so `last` spans all pages — a review cycle passes 30 easily —
  piped to standalone `jq`, since `gh` rejects `--slurp` together with `--jq`). The `gsub` rewrites
  each v2 severity badge (a `<picture>` element) to its `alt` text in brackets, e.g.
  `[High severity]`, so the body reads as plain text:
  ```bash
  gh api "repos/OWNER/REPO/pulls/<pr>/reviews?per_page=100" --paginate --slurp \
    | jq '[.[][] | select(.user.login=="copilot-pull-request-reviewer[bot]")]
           | sort_by(.submitted_at) | last // empty
           | {id, submitted_at, commit_id,
              body: ((.body // "")
                     | gsub("<picture>(?:.|\n)*?alt=\"(?<a>[^\"]*)\"(?:.|\n)*?</picture>"; "[\(.a)]"))}'
  ```
  No output (`// empty` keeps an empty array from printing a null record) → read the detect step's
  two pending signals **fresh** (a snapshot taken before a request you just made is stale): Copilot
  requested, or its check run in progress → the review is pending, wait. Neither → still pending if
  Copilot was **ever** requested on this PR (by you, or auto-requested — GitHub can show neither
  signal for a moment while it schedules the run). That fact is durable on the PR itself, so read
  it there, never from memory — a later turn or a fresh coordinator sees the same answer:
  ```bash
  gh api "repos/OWNER/REPO/issues/<pr>/timeline?per_page=100" --paginate --slurp \
    | jq '[.[][] | select(.event=="review_requested" and .requested_reviewer.login=="Copilot")] | length'
  ```
  Non-zero → keep waiting until a review, an explicit request failure, or the fallback comment
  exists. Zero → Copilot was never requested (the other-bot / no-bot case) and has no review; only
  for such a PR is gate (2) below vacuous. Otherwise its `commit_id` must be the PR head. A review on an **older** commit is a
  previous round's — never gate on it — and only for that stale case: Copilot pending (either
  signal) → wait; neither (the push didn't auto-request) → re-request now and record it with a
  one-line PR comment (`Copilot re-requested on <head sha>`), so a later pass that finds the same
  stale review with the signals transiently absent doesn't request again — with that comment on
  the PR for the current head, wait; if the request fails, take the no-bot fallback (the *Unable to review* bullet).
  A current-head review never triggers a re-request here, with one exception: an *unable to
  review* body on the head takes the *Unable to review* bullet's one retry.
  Body shape (verified on real reviews; REST `state` is `COMMENTED` for every verdict, so ignore it).
  Copilot has posted two formats, and one PR's history can mix them: **legacy**, and **v2**, which
  opens with `<!-- ccr-overview-v2 -->` (seen from 2026-09-22). Don't branch on that marker. Read
  every body for every section below, since each section name belongs to one format and a
  future format may reuse either:
  - **Verdict** — the **first** `### 🟢 …`, `### 🟡 …`, or `### 🔵 …` heading in the body, **not**
    the first line (v2 opens with the HTML comment and a `## Copilot review overview` heading, so
    its verdict is on line 5): `### 🟢 Approval recommended`, `### 🟡 Changes recommended`, or
    `### 🔵 Needs a closer look`.
  - **Summary sentence** — the prose line under the verdict. It is not a count: one review said
    "Five moderate findings" and listed two. But it can carry a finding that no section lists
    (below).
  - **`Suppressed comments (N)`** (legacy) — a `### ` heading inside the `Review details` block.
    Each entry is a bold **`path:line`** line, a `* ` bullet, and usually a fenced quote of the
    anchored lines (context, not finding). `N` counts entries. The same `path:line` can appear
    twice, and a bold **`Previously missed (k)`** line is a sub-label, not an entry. The *File
    summaries* table's "Critical / Nit (k votes)" phrases summarize these same findings.
  - **v2 sections** are `<details>` blocks titled `<summary><strong><name> (N)</strong></summary>`:
    - `Open (N)` — one `- ` bullet per entry: severity badge, `[<title>](#discussion_r<id>)`,
      `· New`. Each **links an inline thread**. On every v2 review checked, every entry was
      `· New`, and the anchors were exactly the first comments of the threads that review opened.
      So answer it **on its thread** (the thread bullet below), not a second time in the body
      comment. Match `<id>` against **every** thread's first-comment `url`, resolved ones included
      (the threads query without its `isResolved` filter). An entry that matches no thread is a
      body entry.
    - `Previously missed (N)` — a line of prose ("In code that hasn't changed since last review"),
      then one nested `<details>` per entry. Its `<summary>` is a severity badge plus a title, and
      its body is a backticked `` `path:line` `` and the finding. These have **no thread**, so the
      body comment is their only answer.
    - `Resolved since last review (N)` and `What changed in this PR` — informational, not findings.
  - **`**Findings:** N` is not the count to answer, and neither is `**Findings:** None`.** It counts
    only the `Open` entries: one review said `2` and carried three `Previously missed` entries
    besides, and another said `None` and carried two. Count the entries in each section. If a
    heading's `N` disagrees with its entries, answer every entry and note the mismatch.
  - **Body entries** — the term the rest of this profile uses (the body comment, gate (2), the valid
    cap marker's coverage): `Suppressed comments` entries, `Previously missed` entries, `Open`
    entries whose anchor matches no thread, and the summary-sentence finding below.
  - **A 🟡 or 🔵 verdict with nothing else to answer — its summary sentence is the finding.** When a
    non-🟢 review has no entry in any section above and no unresolved thread on the PR, treat the
    summary sentence as one body entry, anchored `summary`. This happened on #138: review
    5285530608 was 🔵 with `**Findings:** None`, no sections, and no threads, and its sentence
    ("Match open entries against unfiltered threads, including resolved threads, …") was the
    whole finding. Answer it like any other entry, and never read such a review as clean. When
    unresolved threads remain on the PR, the verdict can simply reflect them: v2 summaries
    describe outstanding state across rounds.
  - **Severity** — a v2 entry's badge carries it in the `<img alt="…">` text (`High severity` and
    `Medium severity` so far). The fetch above prints it as `[High severity]`. Carry it into the
    entry's disposition line and use it in the spiral check. **Never filter on it**: every finding
    gets an answer, whatever its severity. Legacy entries have no badge.
  - **Not a review** — a body whose only content, after any v2 marker and overview heading, is
    *"Copilot was unable to review this pull request …"* (see the *Unable to review* bullet).

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

- **Address each body entry the same way — fix or explain — in one PR comment.** There is no
  thread to reply on or resolve, so post a **single** comment after the review, one line per body
  entry (a repeated `path:line` gets one line per finding; a v2 `Open` entry answered on its thread
  gets none here). Every disposition line, here and *At the cap*, has one shape:
  `<anchor>[ (<severity>: <title>)] — <disposition>`. `<anchor>` is the entry's `path:line`, or
  its title when it has none, or `summary` for the summary-sentence finding. The parenthetical is
  there when the entry has a severity badge. `<disposition>` is `fixed in <sha> — …` or
  `not changing — …` (at the cap, also `agree, held at the round cap — …`). Push fixes first so
  the lines can cite SHAs; `gh pr comment <pr> --body-file <file>`. If every entry is "not changing" (no push), don't
  re-request a review for a fresh verdict — Copilot restates unchanged findings and re-opens the gate.

- **Count the rounds.** A round is one review by the **engaged bot** on a **new head** — a review
  whose `commit_id` no earlier counted review carried. A re-request without a push (a fresh review
  on the same head) is not a round, and neither is an *unable to review* body. Read the count off
  the PR each time, never from memory, so a later turn or a fresh coordinator gets the same answer:
  ```bash
  gh api "repos/OWNER/REPO/pulls/<pr>/reviews?per_page=100" --paginate --slurp \
    | jq --arg bot "<bot login>" '($bot | sub("\\[bot\\]$"; "")) as $b
           | [.[][] | select((.user.login | sub("\\[bot\\]$"; "")) == $b)
                    | select($b != "copilot-pull-request-reviewer"
                             or ((.body // "") | test("^\\s*(<!--[^>]*-->\\s*)?(## Copilot review overview\\s*)?Copilot was unable to review") | not))
                    | .commit_id] | unique | length'
  ```
  `<bot login>` is the engaged bot as the detect step found it among the PR's reviews
  (`copilot-pull-request-reviewer`, `coderabbitai`, a CI action's app login), with or without the
  `[bot]` suffix: the detect step's `gh pr view` prints the bare login while REST adds `[bot]`, so
  the query strips the suffix from both sides before comparing. Keying on it matters: the
  implementer's own thread replies post as reviews on the head too, and must never
  count or stand in for the bot's. The unable-body filter applies only when the engaged bot is Copilot
  (as on the MCP path) and anchors on the opening of Copilot's sentence, so it drops nothing else.

- **The cap.** It is the one START Step 8 resolves: the **larger** valid value of the PR line's
  `(cap <cap>)` and the briefing's `Budget: rounds=<n>`, else — when neither is present — this
  profile's default of **15** (`SPAWN_CAP`). A cap only goes up, so a raise recorded on the line
  wins and nothing lowers it. The cap is a **cost ceiling, not the
  usual way a review ends**:
  below it, stay thorough on correctness and loop as written (fix or explain, push, let the bot
  re-review). It applies to every PR, whatever the diff contains. After every round, rewrite the
  PR body's `Review rounds: <n> (cap <cap>); <m> findings open by disposition` line (START Step 7
  seeds it; add it after the test plan if it's missing) with the current count and the cap in
  force, so the body never under-reports.

- **Spiral check — every round, alongside fix-or-explain.** If you are making repeated small
  changes to the same section across rounds, and especially if a round's findings are mostly about
  text you added or changed for earlier rounds, **stop patching that section**. Re-read it together
  with every finding raised against it so far (threads, body entries, and your earlier
  dispositions), and rewrite it once so it answers the whole set coherently, or say in the
  disposition why the rest don't apply. Then carry on with the loop as normal. This targets fixes
  that each breed the next finding, not review depth. Where the body gives a severity, weigh it
  here: a section still drawing `High severity` findings after two patches is the clearest case
  for the rewrite. Severity only orders the work; lower-severity findings still get answered.

- **At the cap.** Once the count reaches the cap and the engaged bot's newest review on the head
  still has findings, a fix push would be one round too many (on a repo with auto-review a push
  *is* a re-request), so **stop pushing and stop re-requesting**. Answer that review by
  **disposition** instead:
  - every thread gets a reply and is resolved;
  - **one PR comment** posted after the review lists every finding of the round, threads and body
    entries alike (a v2 `Open` entry is its thread, listed once), one line each in the shape the
    body-entry bullet above defines: `<anchor>[ (<severity>: <title>)] — not changing — <why>` or
    `<anchor>[ (<severity>: <title>)] — agree, held at the round cap — <the fix it would take>`. Post it even for a
    thread-only round: the gates date the round's answer by a comment newer than the review, and
    thread replies alone don't show up there;
  - rewrite the PR line with the count and `<m>`, the number of `agree, held` lines in that comment,
    then hand back at the usual reviewed-PR stopping point.

  That line is the durable marker the completion gates read, like the no-bot fallback comment: a
  reached cap with dispositions posted **is** review-clean, not a stall. This is the one
  definition of a **valid cap marker**; START's completion checklist and EPIC's gates point here
  rather than restating it. The line is valid only when all of these hold, and is no marker
  otherwise:
  - its `<cap>` is the cap in force (START Step 8's resolution; for an EPIC coordinator, the larger
    of the cap it briefed — the child's latest `budget:` marker, else the default — and the line's
    own `<cap>`, so the line can record a raise but never lower the cap), and its `<n>` equals the
    count read now and is at least `<cap>` — so a line a later push left behind, a raised cap, or a
    seeded low count never passes;
  - **the engaged bot's** newest review on the head is not an *unable to review* body, and one
    disposition comment was posted after it;
  - that comment **covers the whole review**: every thread the review opened (the threads query
    above, unfiltered, matched on the review `id` in `pullRequestReview.url`) and every body entry (as the
    body shape defines it; a repeated anchor counts once per entry) has its own disposition
    line — a comment that omits a finding is not an answer, whatever its `<m>`;
  - its `<m>` equals that comment's `agree, held` lines.

  A pending or unable bot review on the head keeps the gate open (the unable path below runs first).

- **Raising the cap.** A human can raise it (`Budget: rounds=<n>` on a re-brief, or "one more
  round" to an attached session). **Persist the new cap before resuming**: rewrite the PR
  line's `(cap <new>)` — the line is the cap's one durable record (before the PR exists, carry the
  raise into START Step 7's seed). That is enough everywhere: Step 8 and an EPIC coordinator both
  take the larger cap they can see, and the line is on the PR, so a child raised directly
  needs no marker on an epic it may not know (a coordinator that raises a child by re-brief posts
  its own `budget:` marker, EPIC Step 5). An unpersisted raise is lost at the next compaction.
  Then the loop resumes, pushes included, until the new cap is reached or the review is clean.

- **Pushes the cap never blocks.** A **CI fix**, a **restack** a coordinator redirects (rebase onto
  a new base), and a merge of the base that clears a **conflict** always push, since a red,
  mis-based, or unmergeable PR isn't a reviewed PR:
  count the review it triggers, answer it by disposition, and rewrite the line. If that push doesn't
  auto-request a review (neither pending signal after it), request once for the new head and record
  it, per the stale-review rule above; the round the push costs still needs its review. An *unable
  to review* body on that head takes the *Unable to review* bullet's single retry as written: the retry is on the
  **same** head, so it adds no round, and its fallback applies unchanged.

- **Loop** until **all three** hold — the completion gate:
  1. the unresolved-threads query returns nothing;
  2. for Copilot, the **newest** review — on the PR head, and not an *unable to review* body — has
     every **body entry**, as the body shape above defines it, answered by its own line in a PR
     comment posted **after** it (an anchor two entries share needs two lines). A review with no
     body entries meets this vacuously. That is the normal 🟢 *Approval recommended* case. A 🟡/🔵
     review with no section entries and no unresolved thread still has one: its summary sentence.
     `**Findings:** None` never stands in for counting. An answer to an earlier review doesn't
     carry over; after each push, answer the newest review's list (repeats included). Also met
     when the engaged bot isn't Copilot, or the no-bot fallback comment (the *Unable to review* bullet) is already
     on the PR. **A reached round cap meets it the same way** — the newest
     round's disposition lines *are* that PR comment, and the `Review rounds:` line in the PR
     body says why no fix push followed;
  3. CI is green (`gh pr checks <pr> --watch`).

  For (2), list comments newer than the review (ISO-8601 `Z` timestamps compare as strings):
  ```bash
  gh api "repos/OWNER/REPO/issues/<pr>/comments?per_page=100" --paginate --slurp \
    | jq '[.[][] | select(.created_at > "<submitted_at>")] | map(.body)'
  ```
  Push fixes, let the bot re-review (a push re-triggers Copilot/CodeRabbit), re-read threads and the
  newest body, repeat — while the round count is below the cap (the bullet above); at the cap the
  round's dispositions and the `Review rounds:` line close the loop instead of a push.
- Other bots (CodeRabbit, a CI review action): same loop — read their threads, address, resolve.
- **"Unable to review" is not a review.** A newest review whose body, after any v2 marker and
  overview heading, is only *"Copilot was unable to review this pull request …"* (e.g. quota)
  neither passes nor fails gate (2). Re-request **once**
  (`gh pr edit <pr> --add-reviewer "@copilot"`) and record the retry in the same step with a
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
  fallback above): rely on `gh pr checks <pr> --watch` + the user's review.

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
  authorization and supersedes this cap. Budget: rounds=15" Keeps an unattended background session
  from over-reaching, while making the hold's expiry explicit — so a later /finish-ticket in the
  same session reads as the sanctioned merge phase, not a violation of this cap.
- The trailing `Budget: rounds=15` is the **review-round cap** (`REVIEW_BOT`), carried as a briefing
  directive — a sibling of `Base branch:` / `Worktree:` / `Role:` — so START Step 1 reads it like
  the others. A spawner that knows a change is risky raises it per issue with its own
  `Budget: rounds=<n>`; SPAWN Step 2 keeps exactly one `Budget:` line per briefing, the most
  specific (per-issue over shared over this cap's). **15 is also this profile's default when no directive arrives** — an
  interactive `/start-ticket` — since the human is right there to say "one more round". An org
  profile overriding this op keeps a `Budget: rounds=<n>` line or inherits 15. 15 is a cost ceiling that should rarely be hit, not the usual way a review ends.
- Keep the payload text free of
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
  spawn step), so that intent never even reaches a child — never lift the merge hold for the per-child spawns. The
  cap's trailing `Budget: rounds=<n>` line is the one part a coordinator adjusts per child (a higher
  review-round budget for a risky change — EPIC Step 5); that raises a budget, it lifts no hold.
- Coupling / coordination: the default route is independent **bg** sessions; when a cluster needs
  coordination (concurrent children sharing code), use **shared markers** via the tracker's `COORD`
  op — **not** a live agent team. The `--coordinate` flag selects markers; `--team` is the explicit
  opt-in to a live `SendMessage` team.
  No org-specific epic steps in the default profile.
