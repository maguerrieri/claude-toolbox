# gm — solo RPG game master

A system-agnostic, persona-driven solo tabletop-RPG game master for Claude Code. Bring a system (or none); `gm` runs the world, the oracle, and true dice, and keeps a durable markdown campaign in *your* space.

## Install

Enable the plugin from the `maguerrieri-toolbox` marketplace, then allowlist the bundled dice CLI so play never prompts — add to your Claude Code settings:

```json
{ "permissions": { "allow": ["Bash(roll:*)"] } }
```

(The plugin puts its `bin/` on `PATH` as `roll` when enabled.)

## Play

- `/gm:new-campaign` — pick a system adapter (default `generic`) and a saves folder, set up the world + a character.
- `/gm:play` — start or continue a session.
- `/gm:wrap` — end a session (writes the log + recap, persists state).
- `/gm:oracle` — a quick yes/no or inspiration pull.

## Dice

`bin/roll` is true-RNG (Python `secrets`), stdlib-only:

```
roll 2d6+1
roll 4d6kh3          # keep highest 3
roll 1d20 --adv      # advantage (2d20 keep high)
roll 3d6!            # exploding
roll oracle --table <adapter>/oracles/yes-no.json
```

## How it's built

- **Core** (`skills/gm/`) — the play loop + Rule 0 ("never improvise numbers"); system-agnostic.
- **Adapters** (`adapters/<name>/`) — a game's rules as declarative data (the `generic` Mythic-style oracle ships now; richer systems compose via `extends:`).
- **Dice** (`bin/roll`) — the one thing an LLM can't fake.
- **Your saves** — markdown in your own directory, never in the plugin. A ready-to-play example is in `examples/embervale/`.

The full design spec lives in the repo at `docs/superpowers/specs/`.
