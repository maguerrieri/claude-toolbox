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

2. **Reservoir** — `generate` produces a pool of candidates at
   `<campaign>/docs/generation/<type>.md`. This file is **scratch**: it is throwaway
   input to the next step and may be deleted or overwritten at any time.

3. **Harvest** — `forge harvest <reservoir> <table>` extracts the `## Reservoir` block and
   writes a foundation `- ` list that `roll table` can read. Always run via Bash, not the
   Write tool — so a sealed table write collapses to a single shell-command line in the
   transcript instead of rendering the content inline.

## Soft-coupling / degradation

The forge is **soft-coupled** to `generate`. The gm plugin is fully usable without it:

- Announce the reduced diversity.
- Improvise ~6–10 entries into a scratch reservoir (format: a `## Reservoir` heading, then
  one `- ` entry per line); run `forge harvest` as usual.
- `roll table` works on the result.
- `--secret` routing still holds: sealed tables write to `<campaign>/.gm/tables/<type>.md`
  via the harvest Bash call, never via the Write tool.

Reforge with `generate` present when session pace allows; the table is simply overwritten.

## Promote → seal

When you want one entry to be *the* canonical answer — an NPC's true agenda, the mystery's
solution — point `generate`'s `Promotion:` adapter at
`${CLAUDE_PLUGIN_ROOT}/forge/promotion/campaign.md`. Its `OPEN` step picks the winner and
seals it:

```
campaign gm-seal <campaign-dir> <slot> "<chosen entry>"
```

The rivals stay in the reservoir / cold storage; nothing is deleted. The sealed slot lives
in `.gm/state.json` until the fiction earns a `campaign gm-reveal <campaign-dir> <slot>`.
The `BACKLINK` step records the decision in the reservoir's `## Cold storage` section for
the GM's own continuity.

## Reservoir-is-scratch / table-is-durable

| Path | Role | Lifetime |
|------|------|----------|
| `<campaign>/docs/generation/<type>.md` | Reservoir (scratch) | Ephemeral — safe to delete |
| `<campaign>/tables/<type>.md` | Rollable table (open) | Durable — grows with play |
| `<campaign>/.gm/tables/<type>.md` | Rollable table (sealed) | Durable — behind the GM screen |

The oracle library (`tables/` and `.gm/tables/`) accumulates durable tables across forges.
As play generates new types, the library grows — reducing future misses and narrowing the
on-demand forge pause to genuinely novel situations.
