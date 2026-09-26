# Forge contract

The **forge** turns a `generate` reservoir into a **rollable table** the oracle library can
use. Two modes: **prep** (scheduled, richer pools) and **on-demand** (mid-session on a
genuine table miss). The pipeline is the same in both modes; only the timing differs.

## Prep vs on-demand

- **Prep** — at session zero, when entering a new region, or after `/gm:wrap`. The player
  expects a pause; prefer larger pools (default N ≈ 20). Prefer prep: a forged table
  waiting in `tables/` means the oracle never misses that type again.
- **On-demand** — when a live oracle consult has no suitable entry in any existing table.
  Announce the pause (*"Forging a [type] table — one moment."*), run `/gm:forge <type>`,
  then continue. Use a smaller N (≈ 6–10) to keep it fast. The table persists after — you
  will not forge this type again unless the fiction outgrows it.

## The harvest pipeline

```
frame → generate reservoir → forge harvest → rollable table
```

1. **Frame** (`${CLAUDE_PLUGIN_ROOT}/adapters/<adapter>/frames/<type>.md`, or the generic
   fallback at `${CLAUDE_PLUGIN_ROOT}/adapters/generic/frames/<type>.md`, or on-the-fly
   from the campaign's truths and tone). Axes, shape, and tagging focus diversity.

2. **Reservoir** — run `generate` from the `<campaign>` directory (cwd); it writes its pool
   to `docs/generation/<type>.md` relative to cwd, landing at
   `<campaign>/docs/generation/<type>.md`. This file is **scratch**: it is throwaway input
   to the next step and may be deleted or overwritten at any time.

3. **Harvest** — `forge harvest <reservoir> <table>` extracts the `## Reservoir` block and
   writes a foundation `- ` list that `roll table` can read. A table under `.gm/` is written
   sealed (see below); `--consume` deletes the reservoir once the table is written.

## Sealed forges run behind the screen

A `--secret` forge's pool *is* the secret, and the GM's transcript shows every tool call's
input plus a diff of every file a Bash command changes, so no step of a sealed forge runs
in the GM's own session. The GM hands the whole pipeline to the **`gm:screen` subagent**
(`${CLAUDE_PLUGIN_ROOT}/agents/screen.md`), passing only the type, N and the frame. The
subagent:

1. runs `campaign gm-init <campaign>` (so `.gm/.gitignore` keeps the draft out of git),
   then drafts the reservoir at `<campaign>/.gm/forge/<type>.md` with the Write tool (following
   `generate`'s method but writing the pool itself, since `generate`'s own convention
   would put it at `docs/generation/`; or improvising the pool when `generate` is absent);
2. runs `forge harvest --sealed --consume <campaign>/.gm/forge/<type>.md <campaign>/.gm/tables/<type>.md`,
   which writes the table sealed and deletes the draft (`--sealed` refuses a table path
   outside the screen rather than writing it in plaintext);
3. replies with the count only: `sealed <n> entries → .gm/tables/<type>.md`.

Everything under `.gm/` is sealed on disk (zlib + base64), so a diff or a `cat` of the
table shows noise; `roll table` reads it all the same. A draft a crashed subagent leaves
behind stays out of git (`.gm/.gitignore`), and the plugin's hooks delete it, unsealed and
unrecoverable, once it is an hour stale: it was scratch.

## Soft-coupling / degradation

The forge is **soft-coupled** to `generate`. The gm plugin is fully usable without it:

- Announce the reduced diversity.
- Improvise ~6–10 entries into a scratch reservoir (format: a `## Reservoir` heading, then
  one `- ` entry per line); run `forge harvest` as usual.
- `roll table` works on the result.
- A `--secret` forge improvises inside `gm:screen` like everything else about it (above):
  never a hand-written pool in the GM's own session, heredoc or otherwise.

Reforge with `generate` present when session pace allows; the table is simply overwritten.

## Promote → seal

When you want one entry to be *the* canonical answer — an NPC's true agenda, the mystery's
solution — point `generate`'s `Promotion:` adapter at
`${CLAUDE_PLUGIN_ROOT}/forge/promotion/campaign.md`. Its `OPEN` step has `gm:screen` pick
the winner and seal it, drafting it under `.gm/inbox/` and consuming the draft:

```
campaign gm-seal <campaign-dir> <slot> --from <campaign-dir>/.gm/inbox/<slot>.md
```

The winner never appears in a command or in the GM's transcript. The rivals stay in cold
storage; nothing is deleted. The sealed slot lives in `.gm/state.json` (sealed on disk)
until the fiction earns a `campaign gm-reveal <campaign-dir> <slot>`. The
`BACKLINK` step records the decision in the **durable** open table's `## Cold storage`
section (`<campaign>/tables/<type>.md`; a sealed table skips it, since `gm-list` already
shows the slot) — not the scratch reservoir, which is overwritten on the next forge.

## Reservoir-is-scratch / table-is-durable

| Path | Role | Lifetime |
|------|------|----------|
| `<campaign>/docs/generation/<type>.md` | Reservoir (scratch, open forge) | Ephemeral — safe to delete |
| `<campaign>/.gm/forge/<type>.md` | Reservoir (scratch, sealed forge) | Deleted by `forge harvest --consume` |
| `<campaign>/tables/<type>.md` | Rollable table (open) | Durable — grows with play |
| `<campaign>/.gm/tables/<type>.md` | Rollable table (sealed on disk) | Durable — behind the GM screen |

The oracle library (`tables/` and `.gm/tables/`) accumulates durable tables across forges.
As play generates new types, the library grows — reducing future misses and narrowing the
on-demand forge pause to genuinely novel situations.
