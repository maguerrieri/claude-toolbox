---
name: pr-conventions
description: 'Mario''s pull request title and issue-link format. Use whenever writing, editing, or reviewing a PR title or body in any of Mario''s repos.'
---

# Pull request conventions

A repo's own PR-title style or PR template wins where it differs; this is the
default when the repo documents none.

## Title

PR titles never carry the AI flags that commit subjects do
(`conventions:commit-conventions`); the commits record that. The ticket's
place depends on the tracker:

- **GitHub Issues:** `<scope>: <Description> (#<n>)`, the issue in trailing
  parens and no leading bracket.
  - e.g. `upload: Retry transient 5xx with backoff (#42)`
- **Jira:** `[<KEY>] <Description>`, the key in a leading bracket and no
  scope.
  - e.g. `[ABC-123] Retry transient 5xx with backoff`
- **No tracker:** `<scope>: <Description>`.

`<scope>` is the subsystem touched, as in a commit subject, and
`<Description>` is an imperative summary of the whole PR.

## Issue link in the body

- **GitHub Issues:** end the body with a closing keyword so the merge closes
  the issue: `Closes #<n>` (`Fixes #<n>` for a bug, if preferred). With it,
  closing the issue after merge is automatic.
- **Jira:** reference the ticket (its key or a link). Jira doesn't close from
  PR keywords, so the ticket is resolved separately after merge.

## Adjacent rules

- A harness that writes its own PR body (Before/After, attribution lines)
  still gets the issue link added at the end.
- A harness that forbids model identifiers in PR titles and bodies is already
  satisfied: nothing here puts one there.
