# Tracker adapter: GitHub Issues

Use the `gh` CLI. In worktrees, cwd detection usually works, but pass `-R OWNER/REPO` if `gh` ever picks the wrong repo — derive `OWNER/REPO` from the worktree's own remote (`git -C <worktree> remote get-url origin`, e.g. `git@github.com:OWNER/REPO.git` → `OWNER/REPO`), not from `gh` itself (it uses the same cwd detection and would just repeat the error).

## ID format
- An issue ID is a number, written `42` or `#42`. Strip any leading `#`.

## BRANCH(id)
- `issue-<n>` by default, or `<n>-<kebab-slug>` where the slug is derived from the issue title (lowercased; non-alphanumerics → `-`; collapse repeated `-`; strip leading/trailing `-`; ~6 words max). Prefer the slug form when the title is meaningful.
- Example: issue `42` "Fix flaky upload retry" → `42-fix-flaky-upload-retry`.

## FETCH(id)
```bash
gh issue view <n> --json number,title,body,labels,assignees,url
```
Read `title` and `body`. Look in `body` for a base-branch directive (e.g. "Base branch: `dev`").

## SEARCH(query)  — find existing open issues (FILE phase dup check)
```bash
gh issue list --search "<query>" --state open --json number,title,url -L 50
```
- Set `-L`/`--limit` explicitly — `gh issue list` silently defaults to **30** (the same footgun `EPIC_CHILDREN` calls out); 50 is plenty for a keyword dup check.
- `<query>` is plain keywords (GitHub search syntax is accepted but not required). Keep it to the 2–4 distinctive terms FILE Step 2 derived — an over-specific query returns nothing and under-checks.
- Returns `(number, title, url)` per hit. The *judgment* — is a hit the same work? — belongs to FILE Step 2, not this op.
- Errors (network, auth) are **non-fatal** for FILE: report the failure and let Step 2's degrade-to-filing path handle it.

## CREATE(title, body, labels?, required_labels)  — file a new issue (FILE phase)
```bash
# 1. preflight: every required label must already exist in the repo (fully paginated — no -L cap).
#    Capture the listing FIRST and check gh's own status; only then match. Both failure modes carry
#    an explicit branch, so the snippet itself stops before CREATE without relying on the caller's
#    `set -e` / `pipefail`. A failed listing is a hard error in its own right, never a miss — and
#    never a pass.
labels=$(gh api --paginate repos/OWNER/REPO/labels --jq '.[].name') || { echo "label listing failed for OWNER/REPO"; exit 1; }
# once per required label:
printf '%s\n' "$labels" | grep -Fxq -- "<required label>" || { echo "OWNER/REPO is missing required label <required label> -- provision it (see Labels below), then retry"; exit 1; }
# 2. create, with the required label(s) and any best-effort ones — the same OWNER/REPO, via -R
gh issue create -R OWNER/REPO --title "<title>" --body-file <path> --label "<required label>" [--label "<label>"]
```
`OWNER/REPO` is the repo FILE is filing into (the profile's `REPO_SELECT`), spelled out in **both** commands so the preflight and the create can't resolve to different repos from cwd detection — in the endpoint path for `gh api` (which takes no `-R`/`--repo` flag; passing one is an `unknown shorthand flag` error), and as `-R` for `gh issue create`/`view`.
- Write the body to a temp file and pass `--body-file` — issue bodies are multi-line, quote- and backtick-heavy markdown, and a file sidesteps the brittle shell escaping an inline `--body "…"` would need.
- **`required_labels` is a hard requirement** (FILE Step 3 passes the issue's `risk:<class>` label here — exactly one, always). `gh` never creates labels on the fly, so **preflight** each required name against the repo's full label list (`gh api --paginate` walks every page — `gh label list` caps at its `-L`, 30 by default, and a repo with more labels than the cap would report a false miss — and the exact `grep -Fx` on `name` means a partial match on a description can't pass). **Capture the listing and check `gh`'s exit status before matching**, as the block above does, rather than piping `gh api` straight into `grep`: a pipeline's status is `grep`'s, so a paginated listing that succeeds on page 1 and then fails would still "find" the label and pass the preflight on a partial list. A listing that fails is its own hard error — report the failure and stop before CREATE; never treat it as a miss, and never as a pass. **Give the miss its own branch too**, as the block does: assume nothing about the caller's shell options, since with neither `set -e` nor `pipefail` a bare `grep -Fxq` whose match fails returns 1 into a void and execution simply falls through to `gh issue create` — a comment saying "stop" stops nothing. Each of the two outcomes that must block CREATE needs a branch that actually exits. A required label the repo genuinely lacks is a **hard error surfaced to the user** too — report the missing name and the fix (`${CLAUDE_PLUGIN_ROOT}/scripts/provision-risk-labels OWNER/REPO`, below), and **do not** create the issue without it, retry without it, or `gh label create` it yourself. If `gh issue create` still fails on a label after the preflight passed, treat it the same way: fail, don't strip. Don't accept a `required_labels` entry that isn't in the repo's known set of risk classes either (`risk:critical` is a hard error, not a new class).
- `labels` (the optional ones) stay best-effort: `gh issue create` errors if any label doesn't exist — retry with the required labels only, dropping the optional ones, rather than failing the CREATE. Never drop a required label on that retry.
- On success `gh issue create` prints the new issue's URL; the trailing path segment is the number (`…/issues/57` → `57`). Return that number — it's the `<n>` every other op consumes. Verify the result carries exactly one `risk:*` label **and** that it is exactly the `required_labels` entry FILE passed in — `gh issue view <n> -R OWNER/REPO --json labels --jq '[.labels[].name | select(startswith("risk:"))]'` must print exactly one name, and that name must equal the required `risk:<class>` (so `--risk docs` verified as `risk:normal` fails, as does a sole `risk:critical`) — and report if it doesn't, rather than returning success.

## Labels  — repo provisioning the CREATE preflight depends on
Five labels are expected in every repo the workflow files into: the four risk classes `risk:docs`, `risk:low`, `risk:normal`, `risk:high` (FILE Step 1) and `auto-merge: requested` (the opt-in a `risk:docs` PR carries for unattended merge). Provision them once per repo — and backfill `risk:normal` onto open issues filed before the flag existed — with the plugin's script (idempotent; `--dry-run` to preview, and a second `--dry-run` afterwards is the verification: `remediated 0, flagged 0`):
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/provision-risk-labels" [--dry-run] OWNER/REPO [OWNER/REPO ...]   # from the installed plugin
plugins/ticket-workflow/scripts/provision-risk-labels [--dry-run] OWNER/REPO [OWNER/REPO ...]     # from a claude-toolbox checkout
```
The script isn't on PATH — run it by one of those paths. It uses `gh api` when `gh` is on PATH and falls back to `GH_TOKEN`/`GITHUB_TOKEN` over HTTPS (cloud sessions without `gh`). The backfill enumerates open issues with explicit full pagination, adds `risk:normal` **only** to issues with no `risk:*` label at all, leaves exactly-one-known-class issues untouched, never touches closed issues, and *prints* (never edits) any issue with two risk labels or an unknown `risk:` name for manual remediation (exit 1 while any remain). "Exactly one known `risk:*` label per issue" is the invariant the FINISH gate and the merge workflows enforce — an accidental second label is a *stop* there, never a downgrade — so keep label edits to that shape. With `gh` but without the script, the equivalent by hand is `gh label create -R OWNER/REPO "<name>"` for each of the five and `gh issue edit <n> -R OWNER/REPO --add-label risk:normal` per unlabelled open issue; with neither, the script's token transport or the repo's Labels page in the GitHub UI are the routes.

## START(id)  — mark in-progress (optional, light)
```bash
gh issue edit <n> --add-assignee @me
# optional, only if the repo uses such a label:
gh issue edit <n> --add-label "in progress"
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
- If the PR body had `Closes #<n>`, merging already closed it — verify with `gh issue view <n> --json state -q .state` (expect `CLOSED`).
- If it's still open:
```bash
gh issue close <n> --comment "Resolved by #<pr> (merged)."
```

## EPIC_CHILDREN(id)  — list an epic's child tickets (EPIC phase)
GitHub has no native "epic", so an epic is one of these — try in order:
- **Native sub-issues** (GitHub's sub-issue feature). List via GraphQL — `{owner}`/`{repo}` auto-populate from the current repo (verified on gh 2.88.1), so no manual substitution; replace only `<n>`:
```bash
gh api graphql --paginate -f query='query($owner:String!,$repo:String!,$num:Int!,$endCursor:String){repository(owner:$owner,name:$repo){issue(number:$num){subIssues(first:100, after:$endCursor){totalCount pageInfo{hasNextPage endCursor} nodes{number title state labels(first:20){nodes{name}}}}}}}' -F owner='{owner}' -F repo='{repo}' -F num=<n>
```
  `--paginate` auto-follows pages via the `$endCursor`/`pageInfo` pairing (verified on gh 2.88.1), so an epic with **>100** children isn't silently truncated — keep the `$endCursor` var, the `after:$endCursor` arg, and `pageInfo` intact.
- **Task-list / tracking issue:** the epic's body has a checklist that references child issues (`- [ ] #123`). Parse `#<n>` refs from the body — use `-q .body` so you get raw text, not a JSON object with escaped newlines: `gh issue view <n> --json body -q .body`.
- **Shared label or milestone:** `gh issue list --label "epic:<name>" --json number,title,state,labels -L 500` (or `--milestone "<name>"`) — set `-L`/`--limit` explicitly; `gh issue list` defaults to **30**, which would silently cap a large epic.

Return `(number, title, labels)` for each child — the labels feed the EPIC coupling router (`phases/epic.md` Step 3). If none of these apply, ask the user for the child IDs.

## DEPS(id)  — intra-epic dependencies for a child (EPIC phase)
GitHub has no first-class issue dependencies, so derive them:
- **Body directives:** `Depends on #<n>` / `Blocked by #<n>` / `After #<n>` in the child's body (`gh issue view <n> --json body -q .body` — `-q .body` for raw text). Parse the `#<n>` references.
- **Ordered task list:** only if the user says the epic's checklist is ordered (each item depends on the one above) — order is *not* dependency by default.

Return the set of child numbers this child is blocked by, **keeping only those that are themselves children of this epic**. Empty set → it's a root.

## DEPENDENCY_PR(id)  — find the open PR for a dependency (START phase)
GitHub PRs created by this workflow close their issue from the body, so search for an exact closing reference (not merely `#<n>` appearing in discussion):
```bash
gh pr list --state open -L 500 --search "#<n> in:body" --json number,headRefName,body --jq '.[] | select((.body // "") | test("(?i)(closes|fixes|resolves):?\\s+#<n>\\b")) | {number,headRefName}'
```
Return the match only when there is **exactly one**; zero or multiple is ambiguous and START falls back rather than guessing.

## COORD(epic_id)  — coordination channel for EPIC runs (EPIC phase)
The shared, durable channel sibling sessions use for file **claims** and **"branch pushed" / "done"** markers when EPIC Step 3 routes a cluster to *coordinated* mode — **and**, for *any* EPIC run with a registered native stack, the `stack:` record EPIC Step 6 writes (that write happens regardless of routing mode). On GitHub the epic is itself an issue, so `<epic_id>` here is its **number** (the same numeric `<n>` form as any issue, `#` stripped). Use the **epic issue's comments**:
```bash
gh issue comment <epic_id> --body "claim: <session> -> <files>"   # post a marker
gh issue view <epic_id> --json comments -q '.comments[].body'      # read existing markers
```
Markers are plain prefixed lines (`claim:`, `pushed:`, `done:`, `stack: <s> <bottom-pr>..<top-pr>` — a registered native stack's bare number plus its PR range, EPIC Step 6) so siblings can grep them. Keeps coordination tracker-native and inspectable; no live agent team required.

## Review bot
- The review bot is a **profile** concern, not tracker-specific — see the selected profile's `REVIEW_BOT` (the `default` profile drives Copilot via `gh`).
