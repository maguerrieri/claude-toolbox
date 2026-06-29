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

## START(id)  — mark in-progress (optional, light)
```bash
gh issue edit <n> --add-assignee @me
# optional, only if the repo uses such a label:
gh issue edit <n> --add-label "in progress"
```
Skip silently if it errors (e.g. label doesn't exist) — START is best-effort.

## COMMIT_REF(id)  — commit message format
- No bracket prefix. Reference the issue in the subject's trailing parens, conventional-commit style:
  - `<scope>: <description> (#42)`
  - e.g. `upload: retry transient 5xx with backoff (#42)`
- When AI-assisted, follow the user's usual attribution in the body, not the subject.

## PR_REF(id)  — PR title + issue link
- **Title:** `<description> (#42)` (no `[TICKET]` brackets — that's the Jira convention).
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

Return `(number, title, labels)` for each child — the labels feed the EPIC coupling router (SKILL.md EPIC Step 3). If none of these apply, ask the user for the child IDs.

## DEPS(id)  — intra-epic dependencies for a child (EPIC phase)
GitHub has no first-class issue dependencies, so derive them:
- **Body directives:** `Depends on #<n>` / `Blocked by #<n>` / `After #<n>` in the child's body (`gh issue view <n> --json body -q .body` — `-q .body` for raw text). Parse the `#<n>` references.
- **Ordered task list:** only if the user says the epic's checklist is ordered (each item depends on the one above) — order is *not* dependency by default.

Return the set of child numbers this child is blocked by, **keeping only those that are themselves children of this epic**. Empty set → it's a root.

## COORD(epic_id)  — coordination channel for a coordinated EPIC run (EPIC phase)
The shared, durable channel sibling sessions use for file **claims** and **"branch pushed" / "done"** markers when EPIC Step 3 routes a cluster to *coordinated* mode. On GitHub, use the **epic issue's comments**:
```bash
gh issue comment <epic_id> --body "claim: <session> -> <files>"   # post a marker
gh issue view <epic_id> --json comments -q '.comments[].body'      # read existing markers
```
Markers are plain prefixed lines (`claim:`, `pushed:`, `done:`) so siblings can grep them. Keeps coordination tracker-native and inspectable; no live agent team required.

## Review bot
- The review bot is a **profile** concern, not tracker-specific — see the selected profile's `REVIEW_BOT` (the `default` profile drives Copilot via `gh`).
