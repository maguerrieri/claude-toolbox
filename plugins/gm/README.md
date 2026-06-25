# gm — solo RPG game master

A system-agnostic, persona-driven solo tabletop-RPG game master for Claude Code. Bring a system (or none); `gm` runs the world, the oracle, and true dice, narrates in the voice you pick, and keeps a durable, git-versioned campaign in *your* space.

## Install

Enable the plugin from the `maguerrieri-toolbox` marketplace, then allowlist the bundled CLIs so play never prompts — add to your Claude Code settings:

```json
{ "permissions": { "allow": ["Bash(roll:*)", "Bash(campaign:*)"] } }
```

(The plugin puts its `bin/` on `PATH` when enabled. The allowlist is required — a plugin can't grant its own Bash permissions.)

## Play

- `/gm:new-campaign` — pick a **system** and a **persona**, choose a saves folder, set up the world + a character; starts a git repo for the saves.
- `/gm:play` — start or continue a session.
- `/gm:wrap` — end a session (writes the log + recap, checkpoints the save).
- `/gm:oracle` — a quick yes/no or inspiration pull.
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
roll oracle --table <adapter>/oracles/yes-no.json
```

## How it's built

- **Core** (`skills/gm/`) — the play loop + Rule 0 ("never improvise numbers"); system-agnostic.
- **Adapters** (`adapters/`) — a game's rules as data, composing via `extends:`.
- **Personas** (`personas/`) — the GM's voice, orthogonal to the system.
- **Dice** (`bin/roll`) + **campaign git** (`bin/campaign`) — the things an LLM can't fake: true randomness and durable, versioned state.
- **Your saves** — git-versioned markdown in your own directory, never in the plugin. Ready-to-play example: `examples/embervale/`.

Full design spec lives in the repo's `docs/superpowers/specs/`.
