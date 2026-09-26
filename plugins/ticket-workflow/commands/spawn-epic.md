---
description: Use when asked to run a whole epic hands-off in the background ("kick off the auth epic while I'm away"), or when /spawn-epic appears anywhere in the message
argument-hint: <epic-id> [briefing] [--finish] [--coordinate | --team | --independent]
---
Spawn a background epic run for: **$ARGUMENTS**

Thin launcher over `/start-epic`: spawn ONE background session that runs the full EPIC cycle, then hand back immediately. Don't run any EPIC step yourself — no fetching the epic, no enumerating children, no Step 0; the spawned session does all of it.

0. **Implementer spawn guard** (the `ticket-workflow` skill's Session roles section). Read this session's role marker first:

```bash
roles_dir="${CLAUDE_SESSION_ROLES_DIR:-$HOME/.claude/session-roles}"
sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
[ -n "$sid" ] && head -n 1 "$roles_dir/$sid" 2>/dev/null
```

   If it prints `implementer`, or a charter you hold in context makes you one, **launch nothing**. Epics are the planner's to spawn and yours to flag. Ping your `Notify:` spawner `filed: <epic-id> (already open), suggest spawning` per the skill's `messaging.md`, or note it on your issue/PR when no `Notify:` is wired, then return to your own issue. Say so in one line. A human steering this session can override (`/role none` drops the pin).

1. Take the first token of "$ARGUMENTS" as the epic ID (used only for the session name). Pass the **full** "$ARGUMENTS" through to the child **verbatim** — briefing and flags (`--finish`, `--coordinate`, `--team`, `--independent`) are parsed by the `/start-epic` orchestrator, not here. Do **not** append a `SPAWN_CAP`: the epic orchestrator caps each child itself, and an explicit `--finish` must reach it intact. **Do** append a `Role: epic-coordinator` directive so the spawned orchestrator adopts its charter (EPIC Step 1 reads `roles/epic-coordinator.md`) — this is the one role you set at the epic boundary; the children get `Role: implementer` from the EPIC phase itself.
2. Determine `<repo>` for the session name — basename of the repo the work targets (the current repo unless the briefing names another).
3. **Select the backend**, as the `spawn` skill's step 3 does: `[ -n "${CLAUDE_CODE_REMOTE_SESSION_ID:-}" ] && echo cloud || echo local`. The orchestrator this launches runs the EPIC phase on the same backend (it inherits your environment), so launch it the way that backend launches anything — the mechanics live in the `spawn` skill's `backends/local.md` / `backends/cloud.md`; the EPIC-specific parts are below. One refusal applies up front on **cloud**: if "$ARGUMENTS" carries `--team`, **stop and say so** — SendMessage doesn't span cloud sessions, so the live team that flag names can't form there (the EPIC phase's Step 3 refuses for the same reason); suggest `--coordinate` or no routing flag instead of launching an orchestrator that will only refuse later.

   **Local** — spawn **from a durable launch directory** (the repo's main checkout, first entry of `git worktree list`; never from inside a disposable worktree — the bg job records its launch cwd, and a later-deleted worktree breaks attach/resume). Feed the prompt through a single-quoted heredoc into a variable so the arguments can't be mangled by the shell — plain double-quoting would **expand** any `$`, backticks, or `$(...)` in `$ARGUMENTS` and corrupt the prompt (the same mitigation `/spawn` documents). `env -u CLAUDE_SESSION_ID` keeps your session identity out of the orchestrator, so its self-pin can never land in your marker (the skill's Session roles: *Session identity*):

```bash
read -r -d '' p <<'PROMPT'
/start-epic $ARGUMENTS
Role: epic-coordinator
PROMPT
launch_dir=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //'); launch_dir=${launch_dir:-$PWD}
( cd "$launch_dir" && env -u CLAUDE_SESSION_ID claude --bg --name "<repo> <epic-id>: epic — <quick description>" "$p" )
```

   **Cloud** — one `create_session` call; the prompt travels as JSON, so no shell quoting applies (`$ARGUMENTS` below is this command's argument placeholder, substituted into the text before you see it — the same token the local heredoc carries — not a shell variable; what you pass is the user's actual arguments). `outcome_branch: epic-<epic-id-lower>-orchestrator` — the orchestrator pushes no branch of its own (its children get theirs from the EPIC phase's Step 5), but without `outcome_branch` the session has no resolved repo and files under "Other" in the sidebar (`backends/cloud.md`); the name is for attribution and never reaches origin unless the orchestrator pushes, which it doesn't. No `Notify:` (no cross-session channel on cloud). `source_revision` only when the briefing pins a base branch (the directive also travels in the prompt, and EPIC Step 4 gives a briefing `Base branch:` first precedence, so the orchestrator's checkout and its roots' bases agree); `source_url` always — the clone URL of the repo the work targets (`git remote get-url origin` when that's the current checkout; the named repo's URL when the briefing names another):

```
create_session({
  "prompt": "/start-epic $ARGUMENTS\nRole: epic-coordinator",
  "title": "<repo> <epic-id>: epic — <quick description>",
  "source_url": "<repo clone URL>",
  "outcome_branch": "epic-<epic-id-lower>-orchestrator",
  "source_revision": "<base branch — include this line only when the briefing pins one; omit it otherwise>"
})
```

   Mind `backends/cloud.md`'s slash-command caveat: a prompt that *begins* with `/start-epic` is dispatched as a command before the model runs, and an environment where the plugin isn't installed rejects the launch ("Unknown command"). The child inherits your environment, so if *you* reached this command as a slash command the prompt above is right; if you are following this file because the command wasn't there, open the prompt with prose instead — `Run the epic <epic-id>. Read <path>/plugins/ticket-workflow/skills/ticket-workflow/SKILL.md and its phases/epic.md and follow the EPIC phase for: $ARGUMENTS` — then the `Role: epic-coordinator` line.

   `<quick description>`: an under-5-word summary of the epic, recognizable in the session list. The `epic —` marker distinguishes this orchestrator session from the `<epic-id-lower>-<id-lower>` child sessions it will spawn.

4. Report the handle for your backend and hand back without blocking — locally the session name plus `claude agents` to list, `claude attach "<name>"` to open, `claude logs "<name>"` read-only (quote the name; it contains spaces); on cloud the returned `session_…` id plus `get_session(<id>)` for its status (the orchestrator re-wakes itself between polls via `send_later`, so an idle status between wakes is normal — its `post_turn_summary` says where it is).
