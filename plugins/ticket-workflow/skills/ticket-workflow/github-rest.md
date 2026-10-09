# GitHub over REST (cloud sessions)

Claude Code's cloud proxy rejects every GitHub GraphQL request with HTTP 403 and the message
*"GitHub GraphQL is not available from Claude Code sessions; use the REST API …"*. That covers
`gh api graphql` and also every `gh` subcommand built on GraphQL: `gh issue view/list/create/edit/close/comment`,
`gh pr view/list/create/edit/merge/checks/comment`, `gh repo view` and `gh search`. The REST API
still works: `gh api repos/{owner}/{repo}/...`, `gh pr diff`, `gh run list/view`. (Reproduced
2026-10-09 on gh 2.89.0; #134.)

**When to use this file.** Step 0 sends you here in a cloud session (`CLAUDE_CODE_REMOTE_SESSION_ID`
is set, the same test the `spawn` skill uses to pick its backend), or as soon as any `gh` call
returns that 403. From then on, use the spelling below for every GitHub call the tracker, the
profile and the phases name, for the rest of the session. Everything
else about each op (what to read off the result, what counts as success, the fallbacks) stays as
its own file says. Local sessions keep the `gh` spellings in those files.

**Conventions for every command here.**

- `{owner}` and `{repo}` in the **path** are filled in by `gh api` from the current directory's
  remote, with no GraphQL call. Outside the repo, or where a step passes `-R OWNER/REPO`, write
  the real `OWNER/REPO` in the path instead, derived from that repo's remote as the github tracker
  says: `git -C <dir> remote get-url origin | sed -E 's#\.git$##; s#.*[:/]([^/]+)/([^/]+)$#\1/\2#'`.
- **Query parameters never go in the URL.** Pass them as `-X GET -f key=value`, which URL-encodes
  each value. `gh api` expands `{owner}`, `{repo}` and `{branch}`, and `:owner`, `:repo` and
  `:branch` ending at a word boundary, anywhere in the endpoint string. So in the URL a label like
  `epic:repo-split` or a head like `<owner>:branch-x` gets mangled, and a space or `&` breaks the
  query.
- Multi-line bodies go on stdin with `-F body=@-` and a quoted heredoc, under the same rules as the
  github tracker's `CREATE` (quoted delimiter, no file, no pipe into the same command). Short
  one-line values use `-f key=value`; arrays use `-f 'key[]=value'`.
- **Lists go through `scripts/gh-rest-list.sh`, never `gh api --paginate`.** `--paginate` follows
  GitHub's next-page link, which points at `repositories/<id>/…`, a path the proxy refuses with
  403. gh still exits 0 with page 1 printed, so a list past 100 items is silently cut. The script
  asks for `page=1, 2, …` itself and prints every item as one JSON array (`--key check_runs` for an
  endpoint that wraps its list in an object). Run it as
  `bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh"`, found as SKILL.md says for
  `role-marker.sh`, and filter its output with standalone `jq`. The same goes for the REST reads
  `REVIEW_BOT` already makes with `--paginate --slurp` (reviews, PR comments, the timeline):
  run `gh-rest-list.sh '<endpoint>' --pages | jq '<the same filter>'`, without the URL's
  `?per_page=100`. `--pages` keeps the array-of-pages shape `--slurp` gives, so the filter is
  unchanged.
- The search API is blocked too (*"sessions are bound to their configured repositories"*), so
  searches become a full list filtered with `jq`.

**Field names.** REST spells the fields the skill reads differently from `gh … --json`:

| `gh --json` field | REST |
|---|---|
| `url` | `.html_url` |
| `headRefName`, `headRefOid`, `baseRefName` | `.head.ref`, `.head.sha`, `.base.ref` |
| `isDraft` | `.draft` |
| `labels` | `[.labels[].name]` |
| an author's `.login` | `.user.login`; bots carry a `[bot]` suffix |
| `state` | lowercase `open`/`closed`; a merged PR is `closed` with a non-null `merged_at` |
| `mergeCommit.oid` | `.merge_commit_sha` |
| `mergeable` | `true` / `false` / `null` for `MERGEABLE` / `CONFLICTING` / `UNKNOWN` |
| `mergeStateStatus` | `.mergeable_state`, lowercase (`clean`, `behind`, `dirty`, `blocked`, `unstable`, `unknown`, …) |

The single-PR read below normalizes `state`, `mergeable` and `mergeStateStatus` to the uppercase
values the skill compares against, so the steps' tests work unchanged.

## Tracker ops (`trackers/github.md`)

The issues list endpoints also return pull requests, which is what `select(.pull_request | not)`
drops below.

**`FETCH`**
```bash
gh api 'repos/{owner}/{repo}/issues/<n>' --jq '{number, title, body, labels: [.labels[].name], assignees: [.assignees[].login], url: .html_url}'
```

**`SEARCH`** — lowercase the 2–4 terms; every term must appear in the title or body. If nothing
matches, drop the least distinctive term and run it once more.
```bash
bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" 'repos/{owner}/{repo}/issues' -f state=open | jq -c '.[] | select(.pull_request | not)
  | select(((.title + "\n" + (.body // "")) | ascii_downcase) as $t | ["<term1>", "<term2>"] | all(. as $w | $t | contains($w)))
  | {number, title, url: .html_url}'
```

**`CREATE`** — prints the new number itself. Only pass a label that exists (the check under
`START`); REST may create a missing label rather than fail, so `CREATE`'s retry-without-it
never triggers.
```bash
gh api 'repos/{owner}/{repo}/issues' -f title="<title>" [-f 'labels[]=<label>'] -F body=@- --jq .number <<'ISSUE_BODY_EOF'
<body>
ISSUE_BODY_EOF
```

**`START`**
```bash
gh api -X POST 'repos/{owner}/{repo}/issues/<n>/assignees' -f "assignees[]=$(gh api user --jq .login)"
# optional, only if the repo uses such a label:
gh api -X POST 'repos/{owner}/{repo}/issues/<n>/labels' -f 'labels[]=in progress'
```
Check a label exists before adding it, since REST may create a missing one instead of failing
(prints the name if it exists, nothing if not):
```bash
bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" 'repos/{owner}/{repo}/labels' | jq -r --arg l '<label>' '.[] | select(.name == $l) | .name'
```

**`DONE`** — the state reads `closed` (lowercase) once the merge closed it. If it's still open,
comment, then close:
```bash
gh api 'repos/{owner}/{repo}/issues/<n>' --jq .state
gh api 'repos/{owner}/{repo}/issues/<n>/comments' -f body="Resolved by #<pr> (merged)."
gh api -X PATCH 'repos/{owner}/{repo}/issues/<n>' -f state=closed -f state_reason=completed
```

**`EPIC_CHILDREN`** — sub-issues, then the task-list body (also `DEPS`' body read), then a label:
```bash
bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" 'repos/{owner}/{repo}/issues/<n>/sub_issues' | jq -c '.[] | {number, title, state, labels: [.labels[].name]}'
gh api 'repos/{owner}/{repo}/issues/<n>' --jq .body
bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" 'repos/{owner}/{repo}/issues' -f labels='epic:<name>' -f state=all | jq -c '.[] | select(.pull_request | not) | {number, title, state, labels: [.labels[].name]}'
```
A milestone filter takes the milestone's number, `-f milestone=<num>` in place of `labels`:
```bash
bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" 'repos/{owner}/{repo}/milestones' -f state=all | jq -r '.[] | select(.title == "<name>") | .number'
```

**`DEPENDENCY_PR`**
```bash
bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" 'repos/{owner}/{repo}/pulls' -f state=open | jq -c '.[] | select((.body // "") | test("(?i)(closes|fixes|resolves):?\\s+#<n>\\b")) | {number, headRefName: .head.ref}'
```
The Jira adapter's `DEPENDENCY_PR` matches the ticket key in the title or body instead:
```bash
bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" 'repos/{owner}/{repo}/pulls' -f state=open | jq -c '.[] | select((((.title // "") + "\n" + (.body // "")) | test("(^|[^A-Z0-9])<ID>([^A-Z0-9]|$)"; "i"))) | {number, headRefName: .head.ref}'
```

**`COORD`**
```bash
gh api 'repos/{owner}/{repo}/issues/<epic_id>/comments' -f body="claim: <session> -> <files>"                 # post a marker
bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" 'repos/{owner}/{repo}/issues/<epic_id>/comments' | jq -r '.[].body'   # read existing markers
```

## Pull requests (`SKILL.md`, `phases/epic.md`, `profiles/default.md`)

**Create** (`gh pr create`). Add `-F draft=true` for a draft.
```bash
gh api 'repos/{owner}/{repo}/pulls' -f base=<base_branch> -f head=<branch> -f title="<title>" -F body=@- --jq '{number, url: .html_url}' <<'PR_BODY_EOF'
<body>
PR_BODY_EOF
```

**Read one PR** (`gh pr view <pr> --json …`, every field set the skill asks for except the
lists below). The body alone is `--jq .body`.
```bash
gh api 'repos/{owner}/{repo}/pulls/<pr>' --jq '{number, title, body, url: .html_url,
  state: (if .merged_at then "MERGED" else (.state | ascii_upcase) end),
  baseRefName: .base.ref, headRefName: .head.ref, headRefOid: .head.sha, isDraft: .draft,
  mergeCommit: {oid: .merge_commit_sha},
  mergeable: (if .mergeable == true then "MERGEABLE" elif .mergeable == false then "CONFLICTING" else "UNKNOWN" end),
  mergeStateStatus: ((.mergeable_state // "unknown") | ascii_upcase)}'
```
GitHub computes `mergeable` in the background, so the first read after a push can say
`UNKNOWN`; read it again a few seconds later before acting on it, as you would locally.

**Commits, comments and reviews** (the list fields of FINISH Step 1's
`--json commits,title,body,isDraft,comments,reviews`). Read all three, along with the single-PR
read above for the title, body and draft flag. Each commit's full message is `.commit.message`;
its first line is the subject.
```bash
bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" 'repos/{owner}/{repo}/pulls/<pr>/commits' | jq -c '.[] | {oid: .sha, message: .commit.message}'
bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" 'repos/{owner}/{repo}/issues/<pr>/comments' | jq -c '.[] | {author: .user.login, body}'
bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" 'repos/{owner}/{repo}/pulls/<pr>/reviews' | jq -c '.[] | {author: .user.login, state, body, commit_id}'
```

**Edit** (`gh pr edit`): the base with `-f base=<new_base>`, the body from stdin as at create.
```bash
gh api -X PATCH 'repos/{owner}/{repo}/pulls/<pr>' -f base=<new_base>
gh api -X PATCH 'repos/{owner}/{repo}/pulls/<pr>' -F body=@- <<'PR_BODY_EOF'
<body>
PR_BODY_EOF
```

**List by base** (`gh pr list --state open --base <branch>`):
```bash
bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" 'repos/{owner}/{repo}/pulls' -f state=open -f base=<branch> | jq -c '.[] | {number, headRefName: .head.ref, isDraft: .draft}'
```

**List by head** (`gh pr list --head <branch>`: EPIC Step 6, *Resume before spawning* with
`state=all`, and FINISH's stacked-parent check). `head` must be `<owner>:<branch>`, where
`<owner>` is the owner of the repo the PR lives in, written out, never `{owner}`. GitHub ignores a
bare branch name and returns every PR. When a step passes `-R <owner>/<repo>`, that same repo goes
in the path and its owner in `head`.
```bash
bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" 'repos/<owner>/<repo>/pulls' -f head='<owner>:<branch>' -f state=open | jq -c '.[] | {number, url: .html_url, state: (if .merged_at then "MERGED" else (.state | ascii_upcase) end), isDraft: .draft, baseRefName: .base.ref, body, createdAt: .created_at, headRefOid: .head.sha}'
```
`reviewDecision` has no REST equivalent, and EPIC Step 6 doesn't need it: it reads the threads
and the review body. For `statusCheckRollup`, read CI on `headRefOid` as below.

**Comment** (`gh pr comment <pr> --body-file -`):
```bash
gh api 'repos/{owner}/{repo}/issues/<pr>/comments' -F body=@- <<'COMMENT_EOF'
<comment>
COMMENT_EOF
```

**Reviewers so far** (`gh pr view <pr> --json reviews`). Copilot shows as
`copilot-pull-request-reviewer[bot]`.
```bash
bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" 'repos/{owner}/{repo}/pulls/<pr>/reviews' | jq -c '[.[].user.login] | unique'
```

**Request Copilot** (`gh pr edit <pr> --add-reviewer "@copilot"`). A success response doesn't
mean the request registered. On #222 (2026-10-09) this call and the GitHub MCP tool
`request_copilot_review` both returned success and left no `review_requested` event on the PR. So
a minute after requesting, run `REVIEW_BOT`'s timeline count. If it is still zero, use the MCP tool when
it's loaded, and if the count stays zero after that too, the request failed. Take `REVIEW_BOT`'s
no-bot fallback as for any failed request.
```bash
gh api -X POST 'repos/{owner}/{repo}/pulls/<pr>/requested_reviewers' -f 'reviewers[]=copilot-pull-request-reviewer[bot]'
```

**Merge** (`gh pr merge <pr> --rebase`). FINISH's merge rules apply unchanged, including what it
says about permission rules: a rule written for `gh pr merge`, allow or deny, does not match this
command, so in a cloud session the rule has to name it.
```bash
gh api -X PUT 'repos/{owner}/{repo}/pulls/<pr>/merge' -f merge_method=rebase
```

**Merge permission rules.** A deny or ask rule written for `gh pr merge` is the project saying
merges are the human's. Treat it as covering this command too: when the project's settings have
one, don't run the REST merge; hand the merge to the user as FINISH's blocked-merge fallbacks say.

**Other PR and repo calls.**
```bash
gh api 'repos/{owner}/{repo}' --jq .default_branch                 # gh repo view --json defaultBranchRef
gh api -X PATCH 'repos/{owner}/{repo}/pulls/<pr>' -f state=open    # gh pr reopen
```
`gh stack` is a gh extension and isn't installed in cloud containers (checked 2026-10-09), so a
cloud session takes the skill's "no `gh stack`" paths.

**Draft, ready, auto-merge** go through the proxy's own routes:
`POST …/pulls/<pr>/ccr/ready_for_review`, `POST …/pulls/<pr>/ccr/convert_to_draft`, and `PUT`
or `DELETE …/pulls/<pr>/ccr/auto_merge`.

### CI (`gh pr checks`, `statusCheckRollup`)

CI lives on the head commit. Get the sha from the PR (`headRefOid` above), then read both check
runs and legacy commit statuses:

```bash
bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" 'repos/{owner}/{repo}/commits/<sha>/check-runs' --key check_runs \
  | jq -c '.[] | {name, status, conclusion}'
gh api 'repos/{owner}/{repo}/commits/<sha>/status' --jq '.statuses[] | {context, state}'
```

Classify the result:

- **No check runs and no statuses at all**: pending while the repo has CI that would run on the
  PR (a workflow under `.github/workflows/`), since Actions can take a moment to create the runs
  after a push. With no workflows, there is no CI to wait for, which is where `gh pr checks`'s
  "no checks reported" leaves a local session too.
- **Pending:** a check run whose `status` isn't `completed`, one whose `conclusion` is `stale`
  (as `gh pr checks` counts it), or a status whose `state` is `pending`.
- **Failed:** a completed run whose `conclusion` is `failure`, `cancelled`, `timed_out`,
  `action_required` or `startup_failure`, or a status of `failure` or `error`.
  `--fail-fast` stops at the first of these.
- **Green:** at least one run or status, nothing pending, nothing failed. The remaining
  conclusions (`success`, `neutral`, `skipped`) pass.

Copilot's in-flight review shows here as a `copilot-pull-request-reviewer` check run that isn't
`completed`, which is `REVIEW_BOT`'s "pending" signal. There is no `--watch`: re-run the read until
nothing is pending, from a background command or the Monitor tool, never a foreground `sleep`.

## Review threads (`REVIEW_BOT`)

GraphQL thread node ids (`PRRT_…`) don't exist on this path. The proxy's CCR routes key every
thread on the REST id of its comments instead.

**Read the threads.** `GET …/ccr/review_threads` returns every thread in one response, as
`{resolved, outdated, path, line, comment_ids: [...]}` with the thread's first comment first. It
isn't paged: it ignores `per_page` (checked on #204, 11 threads with `per_page=1`). Join it to
the PR's review comments for the fields the GraphQL query returned (needs standalone `jq`, like
the round count):

```bash
threads=$(gh api 'repos/{owner}/{repo}/pulls/<pr>/ccr/review_threads')
bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" 'repos/{owner}/{repo}/pulls/<pr>/comments' \
  | jq --argjson t "$threads" 'INDEX(.id) as $c
      | $t[] | select(.resolved == false)
      | $c[(.comment_ids[0] | tostring)] as $f
      | {comment_id: $f.id, path, outdated, url: $f.html_url, author: $f.user.login,
         body: $f.body, review_id: $f.pull_request_review_id}'
```

`comment_id` stands in for the thread's node `id` in the reply and resolve steps. `url` ends in
the same `#discussion_r<id>` anchor as the GraphQL first comment's `url`, and `review_id` is the
id the GraphQL `pullRequestReview.url` fragment carried, so the valid cap marker's coverage check
works as written: drop the `resolved` filter and keep the threads whose `review_id` is the newest
bot review's `id`. Copilot's review comments carry the author login `Copilot` in REST.

**Reply, then resolve.**

```bash
# reply on the thread
gh api 'repos/{owner}/{repo}/pulls/<pr>/comments/<comment_id>/replies' -f body="Fixed in <sha> — …"
# resolve it
gh api -X POST 'repos/{owner}/{repo}/pulls/<pr>/ccr/comments/<comment_id>/resolve'
```

The resolve call answers `{"comment_ids": [...], "resolved": true}`. `…/unresolve` reopens a
thread the same way.

## No `gh` at all

Some cloud containers have no `gh` installed. There, use the GitHub MCP tools for the same reads
and writes: `issue_read` / `issue_write` / `add_issue_comment` / `sub_issue_write` for the
tracker ops, `list_pull_requests`, `pull_request_read` (`get`, `get_check_runs`, `get_reviews`,
`get_comments`, `get_review_comments`, which returns thread node ids), `create_pull_request`,
`update_pull_request`, `merge_pull_request`, `add_reply_to_pull_request_comment`,
`resolve_review_thread` and `request_copilot_review` for the PR ones. `phases/epic.md` Step 6
spells out the MCP version of the coordinator's poll, including its pagination.
