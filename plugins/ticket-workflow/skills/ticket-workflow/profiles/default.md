# Profile: default

The generic engineering playbook — for personal projects and any repo without an
org-specific profile. Org playbooks live in that org's work config
as their own profile file and are pointed to from the repo's CLAUDE.md
(`Profile: <path>`); they override these defaults.

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
  `README*`, `docs/**`, `CLAUDE.md` / `.claude/**`, module- or package-level doc comments.
- Typical drift: a quickstart/README command that changed, a documented flag/default/API that
  moved or was renamed, a `CLAUDE.md` "gotcha" or "locked decision" the change invalidates, an
  example that no longer runs.
- **Fix the drift in the same commit/PR** so it rides the same review; note in the PR body which
  docs you touched and why. If a doc clearly *should* change but the right wording is unclear,
  flag it in the PR rather than guessing. No doc surface touched → say "no doc impact" and move
  on; never invent docs that didn't exist.

## REVIEW_BOT
Driven entirely by `gh` + the GitHub GraphQL API — no external tooling required. Copilot is the
default bot; CodeRabbit or a CI review action are handled the same way (resolve their threads).

- **Detect, don't guess.** Copilot-review availability is *not* visible in the repo tree — an
  absent `.github/` means no Actions/CI, **not** no review bot. After opening the PR, check whether
  Copilot is already engaged — and note `requested_reviewers` lists only *pending* reviewers, so a
  bot that already **submitted** drops off it; check existing reviews too:
  - `gh api repos/OWNER/REPO/pulls/<pr> --jq '[.requested_reviewers[].login]'` — review pending
  - `gh pr view <pr> --json reviews --jq '[.reviews[].author.login]|unique'` — already submitted (the bot shows as `copilot-pull-request-reviewer`)
  - **Copilot pending or already reviewed** → a review is in flight or done (some repos auto-request
    it). Don't re-request — just wait, then read its threads (below).
  - **Neither** → no *automatic* review, not "no review." Request one (next bullet); only fall back to
    "no bot" if the request fails (Copilot disabled for the repo).

- **Request a review** (when not already engaged): `gh pr edit <pr> --add-reviewer "@copilot"`.
  Best-effort — if it errors (Copilot review not enabled for the repo/account), skip to "no bot" and
  rely on CI + the user's own review. (CodeRabbit and most CI review bots auto-trigger on push, so
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
            nodes{ id isResolved path comments(first:1){ nodes{ author{login} body } } } } } } }' \
    --jq ".data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false)"
  ```

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

- **Loop** until the unresolved-threads query returns nothing **and** CI is green (`gh pr checks <pr>
  --watch`). Push fixes, let the bot re-review (a new push re-triggers Copilot/CodeRabbit), re-read
  threads, repeat. If the bot is wrong, the reply-why-then-resolve above closes the thread.
- Other bots (CodeRabbit, a CI review action): same loop — read their threads, address, resolve.
- **Genuinely no bot available** (the review request failed — Copilot disabled for the repo): rely on
  `gh pr checks <pr> --watch` + the user's review.

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
- Safety cap appended to every spawned sibling's briefing: "Implement the change and run tests,
  but do NOT deploy to production and do NOT merge — stop and report back for review." Keeps
  background sessions from over-reaching.

## EPIC
- Reuses `SPAWN_CAP` for every child spawned during the epic fan-out (default: implement + test,
  don't merge). The EPIC phase's optional finish flag (`--finish` / "merge when green") is an
  explicit user opt-in that lifts the cap for the orchestrator's own FINISH pass **only** — never
  lift it for the per-child spawns.
- Coupling / coordination: the default route is independent **bg** sessions; when a cluster needs
  coordination (concurrent children sharing code), use **shared markers** via the tracker's `COORD`
  op — **not** a live agent team. The `--coordinate` flag selects markers; `--team` is the explicit
  opt-in to a live `SendMessage` team.
  No org-specific epic steps in the default profile.
