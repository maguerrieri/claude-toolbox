# Harness: Claude

The selected target is a Claude session. Harness selection is complete; now
select the Claude execution backend introduced by #57:

```bash
[ -n "$CLAUDE_CODE_REMOTE_SESSION_ID" ] && echo cloud || echo local
```

- **cloud** — read `../backends/cloud.md` now.
- **local** — read `../backends/local.md` now.

Read exactly one backend and use it for launch, stable identifiers, reporting,
and inspection controls. Do not duplicate those mechanics here.

The backend describes where the Claude sibling will live, not the subject of the
task. An explicit `--harness claude` from Codex selects the local Claude backend
unless the caller also actually has Claude's remote-session context. Choosing or
building a different Claude backend is outside harness selection.
