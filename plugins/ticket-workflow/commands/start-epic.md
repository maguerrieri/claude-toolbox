---
description: Use when asked to run, work through, or knock out an epic and its child issues in this session ("handle the auth epic, all the children"), or when /start-epic appears anywhere in the message
argument-hint: <epic-id> [briefing] [--finish] [--coordinate | --team | --independent]
---
Run the epic: **$ARGUMENTS**

**Invoke the `ticket-workflow` skill now via the Skill tool** and run its **EPIC** phase, following the skill's EPIC steps — the skill is authoritative; don't restate the steps here (that just lets the command and skill drift). The skill content loads when you invoke it; don't read its `SKILL.md` file directly. Parse "$ARGUMENTS" as:

- the **epic ID** (first token);
- shared **briefing** text;
- orchestrator **flags**: `--finish` (also "merge when green" / "and finish them"); and a routing override — `--independent` (force bg), `--coordinate` (coordinated via shared markers / the tracker's `COORD` op), or `--team` (the live-`SendMessage`-team upgrade). The three routing flags are **distinct, not synonyms**.

**Strip those flags from the briefing** before it's forwarded to any child session, so children never receive merge-intent (e.g. "merge when green") that contradicts the per-child `SPAWN_CAP`.

Then do the skill's **Step 0** (select tracker + profile) and run the EPIC cycle exactly as written in SKILL.md (Steps 1–7) — that's the authoritative flow.
