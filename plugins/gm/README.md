# gm — solo RPG game master

A system-agnostic, persona-driven solo tabletop-RPG game master for Claude Code. Bring a system (or none); `gm` runs the world, the oracle, and true dice, narrates in the voice you pick, and keeps a durable, git-versioned campaign in *your* space.

## Install

Enable the plugin from the `maguerrieri-toolbox` marketplace, then allowlist the bundled CLIs so play never prompts — add this to **your own** Claude Code settings (`~/.claude/settings.json`, or the project's `.claude/settings.json`):

```json
{ "permissions": { "allow": ["Bash(roll:*)", "Bash(campaign:*)", "Bash(forge:*)"] } }
```

(The plugin puts its `bin/` on `PATH` when enabled. The allowlist is required — a plugin can't grant its own Bash permissions.)

If you play in a permission mode that asks before file writes, also allow the `gm:screen` subagent's drafts, or the approval prompt previews the very secret it's sealing. For campaigns under `~/rpg/`: `"Edit(~/rpg/*/.gm/**)"` (an `Edit` rule covers the Write tool too; adjust the path to your saves).

**Optional: turn off the Bash edit-diff view for game sessions.** Claude Code shows a diff of every file a Bash command changes. The GM screen doesn't rely on hiding it (everything under `.gm/` is sealed on disk, so the diff shows noise), but if you'd rather not see it: `"bashEditDiffEnabled": false` in your user settings (`~/.claude/settings.json`), or `claude --settings '{"bashEditDiffEnabled": false}'` for just the game session. The plugin can't set it for you: a plugin's own settings only apply `agent` and `subagentStatusLine`, and the key is user- or managed-scope only, so a project's `.claude/settings.json` can't either.

## Play

- `/gm:new-campaign` — pick a **system** and a **persona**, choose a saves folder, set up the world + a character; starts a git repo for the saves.
- `/gm:play` — start or continue a session. It turns on **autosave**: after every turn, the plugin's Stop hook appends your prompt and the GM's narration to the campaign's `log/raw/` and checkpoints it — no `/gm:wrap` needed to keep the play record.
- `/gm:wrap` — end a session (summarizes the raw log into the session log + recap, checkpoints the save).
- `/gm:oracle` — a quick yes/no or inspiration pull.
- `/gm:forge` — bulk-ideate a diverse pool via `generate` into a rollable table; converge-and-seal a canonical secret behind the screen.
- `/gm:checkpoint` · `/gm:rewind` · `/gm:backup` — save-state the campaign (and undo a bad turn).

## Systems (adapters)

Declarative data that composes via `extends:`. Shipped:
- **generic** — a Mythic-style yes/no + meaning oracle; bring any rules.
- **ironsworn** / **starforged** — the Ironsworn family (action roll, vows, progress, momentum) over a shared **ironsworn-core** base. (Content derived from the SRDs by Shawn Tomkin, CC BY 4.0 — see `NOTICE`.)

Add your own: an adapter is a folder (`adapter.md` + `oracles/` + a sheet) — see `skills/gm/references/adapter-contract.md`; `bin/validate-adapter` lints them.

## Personas (voice)

Orthogonal to systems — any persona runs any game. Shipped: **house** (default), **grognard**, **thirsty-sword-lesbians**, **chronicler**. A persona shapes voice only, never numbers (`skills/gm/references/persona-contract.md`). Per-persona commit avatars are wired via `identity/` (follow-on infra).

## Dice

`bin/roll` is true-RNG (Python `secrets`), stdlib-only:

```
roll 2d6+1
roll 4d6kh3                 # keep highest 3
roll 1d20 --adv             # advantage
roll 3d6!                   # exploding
roll ironsworn-action --stat 2 --adds 1
roll ironsworn-progress --boxes 7
roll table <adapter>/oracles/yes-no.md
roll table <campaign>/tables/rumors.md   # campaign table (hand-authored or forged)
```

## How it's built

- **Core** (`skills/gm/`) — the play loop + Rule 0 ("never improvise numbers"); system-agnostic.
- **Adapters** (`adapters/`) — a game's rules as data, composing via `extends:`.
- **Personas** (`personas/`) — the GM's voice, orthogonal to the system.
- **Dice** (`bin/roll`) + **campaign git** (`bin/campaign`) — the things an LLM can't fake: true randomness and durable, versioned state. `lib/gm_screen.py` is their shared seal/unseal for `.gm/`.
- **Your saves** — git-versioned markdown in your own directory, never in the plugin. Ready-to-play example: `examples/embervale/`.
- **Autosave** (`hooks/hooks.json`) — a session bound to a campaign (`campaign bind`, run by `/gm:play` and `/gm:new-campaign`) gets each turn's dialogue appended to `log/raw/<date>-<session>.md` and committed, so the play history lives in the campaign rather than in Claude Code's transcripts (deleted after 30 days by default). Text only — tool calls and their output never reach it, so the GM screen holds. Unbound sessions are untouched; hook failures go to the plugin's data dir (`autosave.log`), never to the turn.
- **Forge** — bulk-ideate a diverse pool via `generate` into a rollable table; converge-and-seal a canonical secret behind the screen.
- **The GM screen** — for systems that want one (`visibility: gm`, e.g. generic), hidden state lives in a `.gm/` dir that is sealed on disk (zlib + base64: noise to a glance, not encryption), so Claude Code's diff of a changed file shows nothing a solo player could read. Anything whose text is a secret (a sealed forge's table, a mystery's answer) is composed and sealed by the **`gm:screen` subagent** (`agents/screen.md`), never in the GM's own transcript; hidden clocks tick through `bin/campaign gm-clock`. Player-facing systems (Ironsworn) keep everything in the open.

Full design spec lives in the repo's `docs/superpowers/specs/`.
