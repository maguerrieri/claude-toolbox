---
description: 'Use when asked to run, work through, or knock out an epic and its child issues in this task or work item ("handle the auth epic, all the children"), or when /start-epic appears anywhere in the message'
argument-hint: <epic-id> [briefing] [--finish] [--coordinate | --team | --independent]
---
Run the epic: **$ARGUMENTS**

**Invoke the `ticket-workflow` skill now via the Skill tool** and run its **EPIC** phase, following the skill's EPIC steps — the skill is authoritative; don't restate the steps here (that just lets the command and skill drift). The skill content loads when you invoke it; don't read its `SKILL.md` file directly. Parse "$ARGUMENTS" as:

- the **epic ID** (first token);
- shared **briefing** text;
- orchestrator **flags**: `--finish` (also "merge when green" / "and finish them"); and a routing override — `--independent` (force background work items), `--coordinate` (coordinated via shared markers / the tracker's `COORD` op), or `--team` (the active harness's live `MESSAGE` channel when available, otherwise `--coordinate` semantics). The three routing flags are **distinct, not synonyms**.

**Strip those flags — and any `Role:` directive — from the briefing** before it's forwarded to any child work item, so children never receive merge-intent (e.g. "merge when green") that contradicts the per-child `SPAWN_CAP`, nor the orchestrator's own `Role: epic-coordinator` (each child gets its own `Role: implementer` from EPIC Step 5).

Then do the skill's **Step 0** in its authoritative order: select and read the active harness adapter first, then select and read the tracker + profile. This resolves the active `MESSAGE`, `INSPECT`, and `ATTRIBUTION` operations before the phase uses them. Run the EPIC cycle exactly as written in SKILL.md (Steps 1–7) — that's the authoritative flow.
