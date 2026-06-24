# `gm` — System-Agnostic Solo RPG Game Master (Design Spec)

- **Date:** 2026-06-24
- **Status:** Approved design — pending implementation plan
- **Home:** `plugins/gm/` in the `maguerrieri-toolbox` marketplace
- **Source research:** an internal 2026 research brief, "Playing TTRPGs with an LLM: The 2026 Tooling Landscape"

---

## 1. Summary

A Claude Code **plugin** that turns Claude into a system-agnostic, persona-driven **solo RPG game master**. A thin **agnostic core** runs the play loop and campaign memory; pluggable **system adapters** (declarative data) supply each game's rules; pluggable **personas** (declarative data) supply the GM's voice; a **bundled dice CLI** provides the one thing an LLM genuinely cannot do — true randomness. Campaign saves live in the **user's own space** as git-versioned markdown, never in the plugin.

The design follows the research doc's single load-bearing lesson: **keep mechanics, dice, and state in tools and files; let the model only narrate.** Every serious project in the space converges on this to stop models from drifting, forgetting HP, and "improvising numbers."

## 2. Goals & Non-Goals

### Goals
- A **system-agnostic** GM engine that is never coupled to any one game (no single-maintainer / single-system dependency).
- **Pluggable systems** via declarative data adapters, with composition (`extends:`) so related games share an engine.
- **Pluggable personas** — an orthogonal "voice" dimension that composes with any adapter.
- **Reliable mechanics**: true dice via a bundled CLI; rules/oracles from data, never invented.
- **Durable, versioned campaigns**: markdown state in the user's space, with git checkpoint/rewind for a real solo save-state system.
- **Share-ready from day one**: a clean plugin installable from the marketplace.

### Non-Goals (v1) — deliberately deferred, all clean later additions
- A bundled **state/dice MCP server** (the anti-drift "enforced state" endgame). The boundary is designed so this drops in later without rework.
- Additional adapters beyond v1 (**Daggerheart**, **D&D 5e**, **Sundered Isles**).
- **VTT / Foundry** integration, **voice/TTS** narration, **display/Chromecast** companions.
- Git **branching** for parallel "what-if" timelines (the checkpoint substrate supports it; the UX is later).

## 3. Background & Motivation

The research doc surveys the 2026 AI-GM landscape and concludes:
- The **official Anthropic marketplace has zero TTRPG plugins**; all real activity is community GitHub. A personal, data-first plugin avoids dependence on any single community maintainer.
- **Dice and rules belong in tools**, not the model. This is the most important reliability upgrade.
- **Claude Code as a "GM harness"** (filesystem + skills + subagents for durable state) is the most exciting and Claude-specific category.
- **Solo play is the sweet spot**, and **Ironsworn/Starforged** (open Datasworn JSON) and **Daggerheart** (open SRD) are the best fits. Notably, **no Ironsworn MCP exists yet** — a flagged build gap.

This plugin targets exactly that sweet spot for a markdown-native, DIY engineer.

## 4. Architecture

Four pluggable layers over a user-owned state store:

| Layer | Owns | Form |
|---|---|---|
| **Core** (agnostic) | Play loop, scene framing, campaign memory/recaps, GM craft, "never improvise numbers" discipline, adapter + persona loading | A skill (`skills/gm/`) + focused reference docs |
| **Adapter** (per-system) | Resolution rules (roll → outcome), oracle tables, moves/content, character-sheet schema, tone/safety defaults | A **data folder** — manifest + data. No engine logic, ever. |
| **Persona** (per-voice) | Tone, refereeing temperament, descriptive density, humor, content sensibilities, chronicle identity | A **data file** — voice description. **Never changes numbers.** |
| **Dice** | True RNG + dice grammar incl. system modes | `bin/roll` — stdlib-Python CLI, allowlisted, transparent |
| **Campaign state** | The actual save: characters, NPCs, threads, clocks, locations, session logs | Git-versioned markdown in the **user's** dir/vault — scaffolded by the plugin, not stored in it |

**Orthogonality is the core idea.** Adapter = *what game*; persona = *who's running it*. The two are **fully independent: any persona runs any system — the entire cross-product**, never a fixed pairing. The examples deliberately cross the "obvious" lines: Grognard Claude (gruff, lethal, roll-for-everything) can run Daggerheart's hopeful fantasy as readily as Ironsworn; the Thirsty Sword Lesbians persona (romance-and-drama-forward) can run a grim D&D crawl; DSA Co-Chair Claude can run any of them by consensus. Which persona meets which system is always the player's free choice — the core loads one adapter and one persona independently and composes them only at narration time.

```
        ┌──────────────────────────── plugins/gm (the engine, shared) ───────────────────────────┐
        │                                                                                          │
        │   ┌─────────────┐     loads      ┌──────────────┐        ┌──────────────┐                │
        │   │  Core skill  │◀──────────────│   Adapter     │        │   Persona     │               │
        │   │ (play loop,  │   (rules)     │ (data folder) │        │ (data file)   │               │
        │   │  memory,     │◀──────────────│  + extends:   │        │ voice only    │               │
        │   │  GM craft)   │   (voice)     └──────────────┘        └──────────────┘                │
        │   └──────┬───────┘                                                                        │
        │          │ shells out to                                                                  │
        │   ┌──────▼───────┐                                                                        │
        │   │  bin/roll     │  true RNG, prints what it rolled                                       │
        │   └──────────────┘                                                                        │
        └──────────┬───────────────────────────────────────────────────────────────────────────────┘
                   │ reads/writes (git-versioned)
        ┌──────────▼─────────────── user's space (the save, personal) ──────────────┐
        │  campaign.md · characters/ · npcs.md · threads.md · clocks.md · log/       │
        └───────────────────────────────────────────────────────────────────────────┘
```

## 5. Components

### 5.1 Core GM skill — `skills/gm/`
- `SKILL.md` — the play loop and **Rule 0** (never improvise numbers).
- `references/gm-craft.md` — fail-forward, succeed-at-a-cost, NPC motivation, pacing (system-agnostic technique).
- `references/state-schema.md` — the markdown campaign-state convention.
- `references/adapter-contract.md` — what an adapter folder must provide and how `extends:` merges.
- `references/persona-contract.md` — what a persona file provides and its hard "voice, not numbers" boundary.

Split into focused docs so no single file does too much.

### 5.2 Adapter contract — `adapters/<system>/`
A directory containing:
- `adapter.md` — manifest (front-matter + prose). Fields:
  - `name`, `extends` (optional — parent adapter id), `dice` (modes used, e.g. `ironsworn-action`, `1d100`),
  - `tone` (genre/voice defaults), **resolution rules** (prose the core follows: which move/roll applies and how an outcome maps), `sheet` (path to schema), safety defaults.
- `oracles/` — oracle tables (JSON/markdown) the core rolls on.
- `rules/` — moves, assets, other content.
- `sheet-template.md` — the character-sheet schema / blank.

**Merge semantics (`extends:`):** the core resolves the chain parent→child; on key collisions the **child (variant) wins**; data files **union by id** (variant adds or overrides individual entries). Adapters contain **no engine logic** — only data and declarative resolution prose.

### 5.3 Persona contract — `personas/<name>/persona.md`
- Front-matter: `name`, `chronicle_identity` (commit author name + email + `avatar` asset path).
- Body: `voice` descriptors, `temperament` (how harsh a "cost" feels, lethality of *narration*), `pacing`, `humor`, `descriptive_density`, `content_sensibilities` (default lines/veils).
- **Hard boundary:** a persona shapes **voice and emphasis only**. It must never alter mechanics, difficulty, or any number — that stays with the adapter and Rule 0. A grognard *narrates* lethally but obeys the same dice and rules.
- **System-independence (guarantees orthogonality):** a persona is authored with **no reference to any system's mechanics, terms, or content** — voice only. This is exactly what makes every persona compose with every adapter (the full persona × system cross-product). A persona that named a system's mechanics would be a contract violation, caught by `bin/validate-adapter`.

### 5.4 Dice CLI — `bin/roll`
- Stdlib-Python (`secrets` for crypto RNG). Allowlisted in `plugin.json` so play never prompts.
- **Grammar:** standard `XdY+Z`, keep/drop (`4d6kh3`), advantage/disadvantage, exploding.
- **Named system modes** the adapters declare:
  - `roll ironsworn-action --stat N --adds N [--momentum N]` → action die (1d6+mods), two d10 challenge dice, classification **strong / weak / miss**, match flag.
  - `roll oracle --table <path> [--d 100]` → rolls and looks up the table entry.
  - (Future variant dice, e.g. Daggerheart duality, are added here, not in the model.)
- **Output:** a human-readable line (always shows the faces and the math — transparency makes a solo roll trustable) plus `--json` for the core to parse.
- **Testability:** `--seed` injects determinism for tests; production uses `secrets`.

### 5.5 Adapter/persona linter — `bin/validate-adapter`
- Checks an adapter folder has required manifest fields, a resolvable `extends:` chain, and well-formed data tables; checks a persona has required fields. Rejects malformed inputs **at author time** instead of at the table. Runs in CI over `adapters/*` and `personas/*`.

### 5.6 Commands — `commands/`
- `/gm:new-campaign` — scaffold a campaign dir; choose adapter + persona + saves location; set up git (§7); generate truths + starting character.
- `/gm:play` — load state + resolved adapter chain + persona; produce a "Previously…" recap; enter the loop.
- `/gm:wrap` — write a session-log entry + forward recap; persist state deltas; checkpoint commit (msg = recap).
- `/gm:oracle` — a quick oracle pull without a full session.
- `/gm:sheet` — view/edit a character sheet.
- `/gm:checkpoint [label]` — manual commit.
- `/gm:rewind` — browse checkpoints and restore one (stashing current state first, so the rewind is itself reversible).
- `/gm:backup` — push to a user-configured remote.

### 5.7 Campaign state convention — user's space (NOT in the plugin)
Markdown, Obsidian-friendly:
- `campaign.md` — premise, truths, tone, **active adapter**, **active persona**, saves metadata.
- `characters/<name>.md` — sheets (per adapter schema).
- `npcs.md`, `threads.md` (vows/quests + progress), `clocks.md`, `locations.md`.
- `log/NNNN-<title>.md` — session journals + recaps.

The core reads these at session start and at decision points, and writes deltas at wrap. The plugin ships an `examples/` campaign and scaffolds new ones; it never stores real saves.

## 6. The play loop (data flow)

**`/gm:play`** → read `campaign.md` → active adapter (e.g. `starforged`) → resolve chain `starforged extends ironsworn-core`, merging base + variant (variant wins) → load merged manifest + `oracles/` + `rules/` → load active persona → read state (characters, vows, clocks, NPCs, locations, last log) → generate recap → enter loop.

**One beat:**
1. Core frames the scene from state + tone, in the **persona's** voice.
2. "What do you do?" → player intent.
3. Core consults the adapter's resolution rules: does this need a roll? which move? (e.g. Starforged *Face Danger*).
4. `bin/roll ironsworn-action --stat 2 --adds 1` → faces + strong/weak/miss. (Oracles: `bin/roll oracle --table <path>`.)
5. Core applies the adapter's outcome guidance + GM craft (fail-forward on a miss, a cost on a weak hit), narrated in persona voice.
6. Core writes state deltas: tick a clock, mark vow progress, adjust momentum/health, log an NPC.
7. Loop.

**`/gm:wrap`** → write session log + forward recap; persist deltas; checkpoint commit; list open threads/clocks.

## 7. Git / versioning & commit identity

Opt-in, plugin-managed, with hard guardrails.

- **Auto-detect, never pollute.** On `/gm:new-campaign`, run `git rev-parse --show-toplevel`. If the campaign path is **already inside a repo** (e.g. an Obsidian vault under Obsidian Git), **defer** — write files, never run own commits, let existing git own history (note this in `campaign.md`). If **not** in a repo, offer to `git init` a **dedicated campaign repo** the plugin manages, marked (e.g. a `.gm/` marker) so the plugin only ever commits in repos it initialized.
- **Checkpoint cadence ("checkpoints, not a firehose"):**
  - auto-commit at `/gm:wrap` (message = the session recap),
  - auto-checkpoint **before irreversible beats** (character death, major state rewrite),
  - manual `/gm:checkpoint [label]` anytime.
- **Rewind:** `/gm:rewind` lists checkpoints and restores one, stashing current state first so the rewind is reversible.
- **Backup:** optional `/gm:backup` pushes to a user-configured remote (the doc's recommended backup for write-capable tooling).
- **Commit identity = the persona.** The campaign repo's local `user.name`/`user.email` are set from the active persona's `chronicle_identity`, so `git log` reads as that GM's chronicle and never masquerades as the user's dev identity. Git operations are allowlisted to avoid permission prompts during play.
- **Avatar.** Git has no avatar concept; avatars are a **host feature keyed off the commit email.** The plugin bundles a Claude glyph (and per-persona glyphs) in `assets/avatars/` and sets a stable GM email. Rendering is host-dependent: Gravatar-aware tools/forges (GitLab, Gitea, GitHub Desktop, many TUIs) show it once the glyph is on that email's Gravatar; GitHub shows it if the email maps to an account bearing it; a bare terminal stays text-only. The one-time Gravatar upload is documented (it cannot be set programmatically).

## 8. Reliability model

The research doc's hard-won lessons, baked in:
- **Rule 0 — never improvise numbers.** Every die through `bin/roll`; every stat/rule/oracle value from the sheet or adapter data. If the GM is about to state a number, it must have been rolled or looked up.
- **Disk is truth; context is a cache.** Markdown state files are authoritative and now **git-versioned**; the core re-reads them at session start and decision points, so context compaction can't corrupt a campaign — it recovers from disk + recap + checkpoint.
- **Player is referee.** A player correction wins over the model; the core reconciles to the file.
- **Gaps surface, never fabricate.** A missing move/oracle is reported, not invented.
- **Rolls are visible.** `bin/roll` prints the dice and the math — trust through transparency.
- **Hard-failure handling.** No `python3`/`bin/roll` → clear message + fallback; malformed adapter/persona → caught by `bin/validate-adapter`; missing campaign files → `/gm:new-campaign` scaffolds.

## 9. v1 scope

**Adapters:**
- `generic/` — Mythic-style yes/no + meaning-table oracle; works for any system the player brings rules to.
- `ironsworn-core/` — the shared base (action+challenge resolution, progress tracks, vows, momentum); not playable alone.
- `ironsworn/` — `extends: ironsworn-core`; the Ironlands (classic oracles/moves/assets).
- `starforged/` — `extends: ironsworn-core`; the Forge (sci-fi oracles/moves/assets, momentum refinements).

Two real users of the base prove the composition model; the generic adapter proves the core is truly agnostic; Ironsworn/Starforged exercise the full adapter surface and fill the doc's flagged Ironsworn gap.

**Personas:** the persona mechanism + a neutral **House GM** default + a small curated roster of flagship example personas (demos/marketing). The maintainer curates which colorful/political personas ship **publicly** vs. stay personal; the mechanism is the deliverable, the roster is a choice.

## 10. Testing strategy

- **`bin/roll`** (the only real *logic*, so the only thing with real unit tests): pytest over grammar (`XdYkhZ`, ±, exploding, adv/dis), system modes (action/challenge classification), distribution sanity, and seeded determinism.
- **`bin/validate-adapter`**: accepts the shipped adapters/personas; rejects fixtures with missing fields / broken `extends:` / malformed tables. CI over `adapters/*` and `personas/*`.
- **Reference integrity**: every move/oracle a resolution rule names must exist in the merged adapter data (through the `extends:` chain) — catches dangling references.
- **Engine/loop** (prose-driven, so eval-style): a few scripted "playtest transcripts" per adapter with assertions — *a roll preceded every stated outcome number*, *the state file changed after a wrap*, *the recap referenced prior threads*.
- **Example campaign**: `/gm:play` it end-to-end as a manual acceptance smoke before release.

## 11. Licensing

Ironsworn/Starforged content and the Datasworn data are **CC-BY**. Because the plugin is public, adapters bundling that data carry proper attribution: a top-level `NOTICE` plus per-adapter credit. Free to redistribute; attribution is mandatory and set up from the first commit.

## 12. Open / cosmetic TBDs (not blocking)
- **Plugin name.** Working name `gm` (matches `/gm:*` and the repo's plain-naming culture). A fancier title is bikeshed-able later.
- **Public persona roster.** Which flagship personas ship publicly vs. stay personal.
- **GM email** for the commit identity / Gravatar target.

## 13. Repo layout

```
plugins/gm/
  .claude-plugin/plugin.json        # manifest; declares bin/roll allowlist
  skills/gm/
    SKILL.md
    references/{gm-craft,state-schema,adapter-contract,persona-contract}.md
  commands/                         # new-campaign play wrap oracle sheet checkpoint rewind backup
  bin/{roll, validate-adapter}
  adapters/
    generic/
    ironsworn-core/                 # base; not playable alone
    ironsworn/                      # extends: ironsworn-core
    starforged/                     # extends: ironsworn-core
  personas/
    house/                          # default neutral GM
    <curated roster>/
  assets/avatars/                   # Claude glyph + per-persona icons
  examples/<demo-campaign>/
  tests/
  NOTICE                            # CC-BY attribution
  README.md
# marketplace.json gains a "gm" entry
# campaign saves live in the USER's space, git-versioned, never here
```

## 14. Suggested implementation phasing

One cohesive plugin, but several independently-shippable milestones. The implementation plan should decompose it roughly as:

1. **Engine MVP** — `bin/roll` (+ tests); core `skills/gm/` (loop + Rule 0 + state-schema); the `generic` adapter; a minimal command set (`new-campaign`, `play`, `wrap`, `oracle`). Playable solo end-to-end with the generic oracle.
2. **Ironsworn family** — `ironsworn-core` base + `ironsworn` + `starforged` variants (Datasworn-derived data); `bin/validate-adapter`; reference-integrity tests; `NOTICE`.
3. **Personas** — persona contract + loader; `house` default + curated roster; `/gm:sheet`.
4. **Versioned campaigns** — git auto-detect/init; checkpoint cadence; `/gm:checkpoint`, `/gm:rewind`, `/gm:backup`; persona commit identity + bundled avatars.
5. **Polish & release** — example-campaign smoke; README; `marketplace.json` entry; playtest-transcript evals.

Each milestone is independently demoable, and later milestones don't reshape earlier interfaces — the layer boundaries are stable by design.
