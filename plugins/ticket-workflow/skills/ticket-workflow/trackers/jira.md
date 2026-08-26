# Tracker adapter: Jira

Jira issue-tracking adapter — `CREATE`, `FETCH`, ID→branch, commit/PR refs, close. Pair it with
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
  - `text ~` runs Jira's full-text match over summary + description; `<query>` is the 2–4 distinctive keywords FILE Step 2 derived. The project **key** resolves the same way `CREATE`'s does (request → project memory → repo `CLAUDE.md`); with no key, search unscoped rather than guessing one.
  - Cap results explicitly (e.g. `maxResults=50`) — don't rely on a tool default.
- If MCP isn't available, use a configured Jira CLI with the same JQL; failing both, treat it as a search failure.
- Return `(key, summary, url)` per hit. The *judgment* — is a hit the same work? — belongs to FILE Step 2, not this op.
- Failures are **non-fatal** for FILE: report and let Step 2's degrade-to-filing path handle it.

## CREATE(title, body, labels?)  — file a new ticket (FILE phase)
- Preferred: the Jira MCP create-issue tool (e.g. `createJiraIssue`) with the project key, an issue type (default the project's standard task type), summary `<title>`, description `<body>`, and any labels. The **project key** comes from the request, project memory, or the repo's `CLAUDE.md` — if none names one, ask; don't guess a key.
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
- Return `(key, summary, labels, components)` for each child — labels/components feed the EPIC coupling router (SKILL.md EPIC Step 3).
- If MCP/CLI isn't wired, ask the user to paste the child keys.

## DEPS(id)  — intra-epic dependencies for a child (EPIC phase)
- **Issue links:** Jira's "is blocked by" / "depends on" links (read the child's `issuelinks`).
- **Body directive (fallback):** a `Depends on <KEY>` / `Blocked by <KEY>` line in the description.

Return the set of child keys this child is blocked by, **keeping only those that are themselves children of this epic**. Empty set → it's a root.

## COORD(epic_id)  — coordination channel for EPIC runs (EPIC phase)
The shared, durable channel sibling sessions use for file **claims** and **"branch pushed" / "done"** markers when EPIC Step 3 routes a cluster to *coordinated* mode — **and**, for *any* EPIC run with a registered native stack, the `stack:` record EPIC Step 6 writes (that write happens regardless of routing mode). On Jira, use **comments on the epic issue** via the Jira MCP/CLI (add-comment / read-comments on `<epic_id>`); markers are plain prefixed lines (`claim:`, `pushed:`, `done:`, `stack:` — a registered stack's number, EPIC Step 6). Unlike GitHub's `gh issue comment`, this goes through the MCP comment API, not a CLI flag — which is exactly why the channel is an adapter op rather than hard-coded in the skill body. If comments aren't agent-writable here, the coordinated route isn't available — **fall back to `--independent` bg routing and note the overlap risk**, rather than improvising an unspecified channel. For the `stack:` record specifically, an unwritable channel is not blocking: put the stack number in the EPIC Step 6 aggregate report instead, and Step 7 re-derives or re-links it just-in-time.

## Review bot
- The review bot is a **profile** concern — see the selected profile's `REVIEW_BOT` (e.g. an org profile may drive a Copilot or CodeRabbit cycle).
