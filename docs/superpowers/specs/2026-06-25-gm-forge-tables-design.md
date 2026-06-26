# gm — Deep oracle: forge, roll-on-tables, promote-to-seal

- **Issue:** #11
- **Status:** Design (brainstormed 2026-06-25)
- **Composes:** the dice CLI (`bin/roll`), campaign git + the GM screen (`bin/campaign gm-*`, `.gm/`), and the **`generate`** plugin (soft dependency).

## Problem

A solo GM mode-collapses. Asked for "five NPCs in the tavern" or "what weird thing grows here," an LLM tends to produce near-duplicates of one archetype. The `generate` plugin exists precisely to beat this (frame → diverse lens-varied passes → axis-tagged reservoir), but the GM has no path to *use* it: nowhere to store a pool as a campaign table, no way to roll on it under Rule 0, and no bridge from generate's divergent reservoir to the GM's occasional need to converge on one canonical secret.

This feature gives the GM a **deep oracle**: bulk-ideate diverse pools at the right moments, persist them as rollable campaign tables, draw from them mechanically in play, and — when one canonical answer is needed — promote-and-seal it behind the GM screen.

## Non-goals

- **Not** a replacement for a bespoke set-piece (generate is a *breadth* tool; a crafted villain still beats a pool). The forge is for variety, not the one hero NPC.
- **Not** a hard dependency on `generate`. gm degrades gracefully (improvise a smaller list) when it's absent.
- **Not** mid-beat by default. The forge is prep-weight; the *pull* mode is an explicit, opt-in pause.
- **No** modification to `generate`'s core loop — we *harvest* its output and add a Promotion adapter; we don't fork it.

## Decided (from brainstorming)

- **Both modes:** prep-time forge (default) + opt-in mid-play pull.
- **All three subsystems in v1.**
- **Soft coupling** to `generate`.
- Tables persist in the campaign; secret pools seal behind the GM screen.

## Architecture — three subsystems

Mirrors gm's existing clean layering (agnostic core · adapters · personas · `bin/roll` · `bin/campaign`). Each subsystem is independently usable and testable.

### ① Tables — storage + mechanical draw

The load-bearing core; **independent of `generate`** (tables can be hand-written).

**Storage.** A *table* is a markdown list file, one entry per list item:
- `<campaign>/tables/<type>.md` — player-facing.
- `<campaign>/.gm/tables/<type>.md` — sealed (rides the GM screen; written/read via the CLI so it stays collapsed in the transcript).

The file is thin: an optional one-line header (type + frame axes, for provenance) and a markdown list (`- ` items). Each item is a full, flavorful entry, so a draw returns something usable, not just a title.

**Draw.** Extend `bin/roll` with a `pick` mode:

```
roll pick <file> [--n K] [--seed S] [--json]
```

- Reads list items from `<file>` (lines starting with `- `, marker trimmed).
- Draws **K distinct** items uniformly at random (default K=1), true-RNG via `secrets`.
- Human output: `🎯 pick 1/23 -> <entry>` (the draw was 1 of N, then the entry). `--json` emits `{"file","n","total","picks":[...]}`.
- Empty/missing file → clear message + non-zero exit (matches `roll`'s existing error style).

Rule 0 holds: the draw is a real roll through `bin/roll`, shown. For a sealed table the GM runs `roll pick <campaign>/.gm/tables/<type>.md` via Bash — the command collapses to "Ran 1 shell command," so the *result* surfaces in narration while the *table* stays behind the screen.

*Depends on:* `bin/roll`, the campaign dir. **Not** `generate`.

### ② Forge — build/expand a table via `generate`

Turns "I want a diverse pool of `<type>`" into a populated ① table.

**Invocation** — a skill step plus a `/gm:forge` command:
1. Resolve the **frame** for `<type>`: a bundled *starter frame* if one exists, else the GM frames it on the fly per generate's `frame` mode (4–6 orthogonal axes).
2. Run the `generate` skill in `generate` mode against that frame (frame → 3–4 lens-varied passes → axis-tagged reservoir).
3. **Harvest** the reservoir entries into ①'s table file (`tables/<type>.md`, or `.gm/tables/<type>.md` with `--secret`) as a markdown list — keeping the entries and their tags. The table *is* the harvested reservoir.

**Modes.**
- **Prep forge** (default): at session zero, entering a new region/faction, or `/gm:wrap` — build/expand the tables the campaign will draw on. No beat is blocked.
- **Pull** (escape hatch): mid-play, when the GM hits genuine novelty and wants variety now. This *pauses* the table (generate is minutes of subagents), so it's explicit, not reflexive. SKILL guidance: "occasionally worth the pause; default to prepping ahead."

**Soft coupling / graceful degradation.** If `generate` is present (detect via its skill / `${...}/plugins/generate`), use it. If absent, the forge **degrades**: the GM improvises a smaller (~6–10) list into the same table file, noting the reduced diversity. ① still works either way.

**Starter frames** — ready frames for common RPG content types so the forge is reliable out of the box, at `${CLAUDE_PLUGIN_ROOT}/forge/frames/<type>.md` (generate's frame format): **npc, rumor, hook, location, faction, oddity** (the "weird thing that grows/lurks here"). Anything else is framed on the fly.

**Reservoir reconciliation.** `generate` writes reservoirs to `docs/generation/<type>.md` (its convention, relative to cwd). The forge does **not** change that — it runs generate in a scratch cwd, then *harvests* the new `## Reservoir` entries into the durable campaign table. The generate reservoir is ephemeral scratch; the campaign table is the versioned artifact.

*Depends on:* `generate` (soft) + ①.

### ③ Promotion → seal — the convergent case

`generate` is judgment-OFF (divergent). Sometimes the GM needs **one** canonical answer (who the villain is, the secret behind the mystery). That convergence routes through generate's **Promotion adapter** seam — composed here with the GM screen.

**The `campaign` Promotion adapter** — gm ships a Promotion adapter at `${CLAUDE_PLUGIN_ROOT}/forge/promotion/campaign.md` and points generate's `Promotion:` directive at that **path** when forging-to-converge (generate's contract allows a path-based adapter). Per generate's op contract:
- **`OPEN(type, slot, rivals)`** — the contested canonical `slot` (e.g. `the-lanternwright`) is decided: the GM picks, or `roll pick`s among `rivals`, and the chosen value is **sealed** with `campaign gm-seal <campaign> <slot> "<chosen entry>"` into `.gm/`. Returns the seal ref.
- **`BACKLINK(ref)`** — note in the campaign (a `tables/<type>.md` cold-storage line, or `.gm/`) that `<slot>` sealed to `<ref>`, preserving the rejected rivals.

**Flow:** forge candidates for a slot → the convergence request fires generate's promotion → the `campaign` adapter seals the winner behind the screen → reveal when the fiction earns it (existing `campaign gm-reveal`). The losers stay (table/cold storage), reusable later.

*Depends on:* generate's promotion seam + the GM screen (`campaign gm-seal`) + ①.

## Data flow

| Situation | Path |
|---|---|
| Prep variety | `/gm:forge <type>` (②) → `<campaign>/tables/` → `roll pick` in play (①) |
| Mid-play novelty | pull-forge (②, explicit pause) → `roll pick` (①) |
| Need a canon secret | forge candidates (②) → promote → seal (③) → reveal when earned |
| No `generate` installed | ② degrades to a GM-improvised list → ① still rolls |

## Components / files

- `plugins/gm/bin/roll` — add the `pick` subcommand (+ tests).
- `plugins/gm/forge/frames/{npc,rumor,hook,location,faction,oddity}.md` — starter frames (generate `frame` format).
- `plugins/gm/forge/promotion/campaign.md` — the `OPEN`/`BACKLINK` adapter that seals via `campaign gm-seal`.
- `plugins/gm/commands/forge.md` — `/gm:forge <type> [--secret] [--n N]` slash command.
- `plugins/gm/skills/gm/SKILL.md` — a "Deep oracle (forge + tables)" section: when to forge (prep vs pull), rolling on a table, soft-coupling/degradation, promote-to-seal.
- `plugins/gm/skills/gm/references/forge.md` (new) — the forge/harvest/frame + promotion contract; plus `state-schema.md` (`tables/`, `.gm/tables/`) and `gm-craft.md` (when variety matters vs a bespoke thing) touch-ups.
- `plugins/gm/.claude-plugin/plugin.json` — **version bump 0.2.0 → 0.3.0** (new feature; per CLAUDE.md → Releasing).
- Tests: `roll pick` (uniformity smoke, `--n` distinctness, `--seed` determinism, `--json`, empty/missing-file errors); table harvest round-trip; promotion seal round-trip (forge a tiny pool → promote → assert `.gm/` sealed).

## Error handling / edge cases

- `roll pick` on empty/missing table → clear error, non-zero exit; GM falls back to improvising.
- `generate` absent → forge degrades to a smaller improvised list, surfaced to the player ("forging a quick set — install `generate` for a deeper pool").
- A sealed table is drawn via Bash so it stays behind the screen; `roll pick` stdout shows only the *drawn* entry, never the whole table.
- generate's reservoir is scratch; only the harvested campaign table is durable + versioned (`campaign checkpoint` commits `tables/` and `.gm/`).

## Testing strategy

- **Unit** (pytest, repo convention): `roll pick` modes + errors; harvest format; promotion seal round-trip.
- **Smoke:** forge a tiny table (generate present) → `roll pick`; forge with generate "absent" (degraded path); promote → seal → `gm-reveal`.
- **CI:** existing gm-ci (pytest + adapter/persona validators) covers it. Starter frames + the promotion adapter are markdown (no validator yet — an optional `validate` extension is a follow-on).

## Open questions for spec review

1. **Entry granularity:** one list item = one entry. Multi-line entries deferred (single `- ` line, optional trailing tag). OK?
2. **Command surface:** ship both `/gm:forge` *and* SKILL guidance (explicit + emergent). Or skill-only?
3. **Starter frame set:** npc, rumor, hook, location, faction, oddity — add/cut any?
4. **Pull-mode guardrail:** should the pull mode require explicit player opt-in each time ("forge now? ~minutes"), or may the GM decide? Proposal: GM may decide but must announce the pause.
