# Tracker adapter: Jira

Jira issue-tracking adapter — `CREATE`, `FETCH`, ID→branch, dependency→PR, commit/PR refs, close. Pair it with
whatever **profile** fits the repo: a personal Jira repo with the `default` profile, or
an org repo with an org-specific profile (which adds that org's engineering steps — its
review-bot cycle, tagged deploys, error-tracking resolution, and so on), kept in the org's
own work config, not here.

## ID format
- `<PROJECT>-<number>`, e.g. `ABC-12`, `WEB-1024` (`[A-Z][A-Z0-9]+-\d+` — any number of digits).

## BRANCH(id)
- Lowercase the ID: `ABC-12` → `abc-12`.

## FETCH(id)
- Preferred: the `getJiraIssue` MCP tool with the ID (requires the Jira MCP server to be connected — it may not be, on a personal machine).
- If MCP isn't available, ask the user to paste the summary/description, or use a Jira CLI if one is configured.
- Read the summary and description; look for a base-branch directive.

## SEARCH(query)  — find existing open tickets (FILE phase dup check)
- Preferred: the Jira MCP search tool (e.g. `searchJiraIssuesUsingJql`) with JQL over the target project, restricted to unresolved issues:
  - `project = <KEY> AND resolution = Unresolved AND text ~ "<query>" ORDER BY updated DESC`
  - `text ~` runs Jira's full-text match over summary + description; `<query>` is the 2–4 distinctive keywords FILE Step 2 derived. The project **key** resolves the same way `CREATE`'s does (request → project memory → repo `AGENTS.md` → compatibility root `CLAUDE.md` / `.claude/CLAUDE.md`); with no key, search unscoped rather than guessing one.
  - Cap results explicitly (e.g. `maxResults=50`) — don't rely on a tool default.
- If MCP isn't available, use a configured Jira CLI with the same JQL; failing both, treat it as a search failure.
- Return `(key, summary, url)` per hit. The *judgment* — is a hit the same work? — belongs to FILE Step 2, not this op.
- Failures are **non-fatal** for FILE: report and let Step 2's degrade-to-filing path handle it.

## CREATE(title, body, labels?)  — file a new ticket (FILE phase)
- Preferred: the Jira MCP create-issue tool (e.g. `createJiraIssue`) with the project key, an issue type (default the project's standard task type), summary `<title>`, description `<body>`, and any labels. The **project key** comes from the request, project memory, canonical repo `AGENTS.md`, or compatibility root `CLAUDE.md` / `.claude/CLAUDE.md` fallbacks — if none names one, ask; don't guess a key.
- If MCP isn't available, use a configured Jira CLI; failing that, ask the user to create the ticket and paste the new key back.
- Return the new issue **key** (`ABC-57`) — it's the ID every other op consumes.

## START(id)  — mark in-progress (optional)
- Transition the issue to "In Progress" and assign to the user, via the Jira MCP/CLI if available. Best-effort; skip if not wired.

## COMMIT_REF(id)  — commit message format
- Follow the repo's commit convention. In this marketplace that's the `conventions` plugin's
  format: `[<ID>] (<flags>) <scope>: <description>` — the Jira key in brackets, AI-assistance
  flags in the subject parens.
  - e.g. `[ABC-123] (Claude Code + Opus 4.8) upload: retry transient 5xx with backoff`
- If the repo documents no convention, the bare Jira form `[<ID>] <description>` is the fallback.

## PR_REF(id)  — PR title + issue link
- **Title:** `[<ID>] <short description>`.
- **Body:** reference the ticket (link or `<ID>`). Jira doesn't auto-close from PR keywords, so closing happens in `DONE`.

## DONE(id)  — resolve the ticket
- Transition the issue to its resolved/done state via the Jira MCP/CLI. Add fix version / resolution per the project's conventions if required.
- If a Jira automation already closes on merge, just verify the state.

## EPIC_CHILDREN(id)  — list an epic's child tickets (EPIC phase)
Jira epics are first-class. `<EPIC-ID>` is the **key** (e.g. `ABC-40`), not a numeric id.
- Via the Jira MCP/CLI, list issues whose Epic Link / parent is `<EPIC-ID>`:
  - company-managed: JQL `"Epic Link" = <EPIC-ID>`
  - team-managed / next-gen: JQL `parent = <EPIC-ID>`
  - The field name `"Epic Link"` contains a space, so it **must stay double-quoted inside the JQL**. Through the MCP tool that's just the param value; through a shell CLI, escape the inner quotes (e.g. `--jql '"Epic Link" = ABC-40'` with single-quotes, or `\"Epic Link\"`) or the field collapses to an invalid unquoted token.
- Return `(key, summary, labels, components)` for each child — labels/components feed the EPIC coupling router (`phases/epic.md` Step 3).
- If MCP/CLI isn't wired, ask the user to paste the child keys.

## DEPS(id)  — intra-epic dependencies for a child (EPIC phase)
- **Issue links:** Jira's "is blocked by" / "depends on" links (read the child's `issuelinks`).
- **Body directive (fallback):** a `Depends on <KEY>` / `Blocked by <KEY>` line in the description.

Return the set of child keys this child is blocked by, **keeping only those that are themselves children of this epic**. Empty set → it's a root.

## DEPENDENCY_PR(id)  — find the open PR for a dependency (START phase)
Jira PRs reference the ticket key rather than using GitHub closing keywords. Search open PR titles and bodies for the key, then require an exact token match (so `ABC-12` doesn't match `ABC-123`):
```bash
gh pr list --state open -R <owner>/<repo> -L 500 --search "<ID> in:title,body" --json number,headRefName,isCrossRepository,headRepositoryOwner,headRepository,title,body --jq '.[] | select((((.title // "") + "\n" + (.body // "")) | test("(^|[^A-Z0-9])<ID>([^A-Z0-9]|$)"; "i"))) | select(.isCrossRepository == false) | {number,headRefName}'
```
Return the match only when there is **exactly one**; zero or multiple is ambiguous and START falls back rather than guessing.

## COORD(epic_id)  — coordination channel for EPIC runs (EPIC phase)
The shared, durable channel sibling sessions use for file **claims** and **"branch pushed" / "done"** markers when EPIC Step 3 routes a cluster to *coordinated* mode — **and**, regardless of routing mode, the three records EPIC writes on *any* run: the `lock:` record (**`lock: <key> ref=<ref> token=<object id> session=<session id> nonce=<per-invocation nonce>`**, written **before** the CAS that takes each lock, never after it — the two are separate writes, and a ref landed with no record behind it is a lock its own holder cannot prove or release. It is what lets a coordinator whose container is replaced between turns prove the lock it still holds is its own — by object id AND by the nonce, since two invocations can share a session id — instead of stranding the epic or reclaiming it; amended with the in-flight operation **before** the call that starts one, not after it returns, since that amendment is what a resumed wake reads to tell "the ref is gone and an operation may still be running" — report and stop — from "the ref is gone and nothing was ever held" — acquire normally), the `stack:` record (Step 6, when a native stack is registered) and every `restacked:` record (Steps 4, 6 and 7 — whenever the orchestrator rewrites a child branch, the finish pass included, **and when a *child* rewrites its own**: START Step 7's pre-push rebase pings `rebased: <branch> onto <base> @ <sha>`, and the coordinator verifies that SHA and publishes the `restacked:` record for it, since the ping is a transient message and the fork point has to outlive it). Those two are not scoped to coordinated runs: an ordinary bg chain gets restacked too, and its fork points survive nowhere else. On Jira, use **comments on the epic issue** via the Jira MCP/CLI (add-comment / read-comments on `<epic_id>`) — and read them with their **id, author and creation time**, paging to the end — and keep each comment a **separate structured record**, never flattened into a delimited text line. The **id** is as load-bearing as the other two: Step 5 arbitrates two claims on one branch by the channel's own record id, because a creation timestamp can tie, so a read that drops it leaves that rule unsatisfiable on this tracker. The grouping that rule collapses over is **`(session, branch)`**, never the session alone: one coordinator holds a claim per child, so a session-wide collapse keeps one record and drops the `child=` liveness evidence for every other branch it reserved. **A branch claim carries every field the GitHub adapter's does, `base=` included** — the assigned base, the child id, the epic, and (after launch) `child=`. Between a child's launch and its first push there is no branch and no PR anywhere, so `base=` is the only record that a second coordinator's chain-top walk can see; a Jira comment that carries the branch and session but drops it leaves that walk free to assign another child to the same base. **And a claim that could not be *written* has the same consequence as one that dropped the field** — the two failure paths match the GitHub adapter's exactly. **First, the prerequisite this fallback does not escape.** `--independent` when comments are unwritable is a documented mode only where the locks never outlive their container — a local, long-lived orchestrator. On cloud, the phase's record-before-CAS rule makes a writable channel a prerequisite for taking a lock at all, so an unwritable Jira is a **stop-and-report for a cloud EPIC**, not a fallback into independent mode; running coupled children unlocked is the thing the mode was never offering. Then, for the intermittent case (the channel worked for the lock records and a claim write later failed): a failed **pre-launch** write leaves `base=` unrecorded, so this run must not share the epic with another coordinator until a human reconciles it — and because a line in a report enforces nothing, the run **keeps the epic graph lock past the pass**, carrying that retention as a named outcome the sweep reads rather than as a printed warning (excluded from the end-of-run sweep, released when the claim is repaired or by a human) rather than merely saying so. A failed **post-launch** write leaves the child live with no `child=`: retry once, then keep the child's row, keep the reservation, carry on with the wave, and report the gap with the same one-coordinator condition. Neither is `blocked-unrecordable`, which the phase reserves for an unrecoverable fork point and which is terminal. A body is arbitrary user text, and **must not be flattened into a delimited line**. In the unsafe shape — `<time>\t<author>\t<body>`, shown here only to be ruled out — a comment carrying a newline and tabs splits into two apparent records, the second with whatever author its writer typed (demonstrated on the GitHub adapter, 2026-09-16). That forges exactly the author check these rules rest on. **And a `restacked:` marker counts only as a comment's whole body** — one marker, nothing else around it — for the same reason the GitHub adapter states: a body is arbitrary text from a session that shares the coordinator's login, so a `claim:` or `done:` comment carrying an embedded `restacked: … @ <sha>` line would inherit that comment's author and hand an unverified fork point to `git rebase --onto`. Ignore embedded marker-looking lines for the fork-point rules; the non-SHA markers keep the loose form. Parse markers *within* one comment: EPIC's fork-point rules authenticate a `restacked:` marker by its author and take the newest, so a read that returns bodies alone cannot satisfy them; markers are plain prefixed lines (`claim:`, `pushed:`, `done:`, `restacked: <branch> onto <base> @ <sha>` — the orchestrator rewrote a child's branch to linearize a chain, or a merge below it did, EPIC Step 4/6/7; `<sha>` is the base tip the branch now forks from, which a force-pushed base makes unrecomputable from the refs, so a session holding that branch must fetch before it pushes and must rebase from this SHA rather than a merge-base, `stack: <s> <bottom-pr>..<top-pr>` — a registered native stack's bare number plus its PR range, EPIC Step 6). Unlike GitHub's `gh issue comment`, this goes through the MCP comment API, not a CLI flag — which is exactly why the channel is an adapter op rather than hard-coded in the skill body. If comments aren't agent-writable here, the coordinated route isn't available — **fall back to `--independent` bg routing and note the overlap risk**, rather than improvising an unspecified channel. **That fallback does not skip the branch reservation**, and never blocked it: EPIC Step 5 reserves each child's assigned branch with an atomic **git ref** (`--force-with-lease` against a ref that must not exist), which needs no comment channel at all — what an unwritable `COORD` costs here is the human-readable claim *record*, which is traceability rather than correctness. For the `stack:` record specifically, an unwritable channel is not blocking: put the stack number in the EPIC Step 6 aggregate report instead, and Step 7 re-derives or re-links it just-in-time. **The `restacked:` record is different — it is blocking.** Its SHA is a fork point that cannot be recovered from the refs once the base is force-pushed, and an aggregate report is not durable for a later session or a re-woken orchestrator. So when comments can't be written here, do **not** restack: report that a linearization is needed but unrecordable, and leave the branches alone (EPIC Step 4's fail-closed rule).

## Review bot
- The review bot is a **profile** concern — see the selected profile's `REVIEW_BOT` (e.g. an org profile may drive a Copilot or CodeRabbit cycle).
