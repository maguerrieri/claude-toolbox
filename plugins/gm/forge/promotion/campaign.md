# Promotion adapter: campaign

Seals the GM's chosen winner behind the screen. The winner is never shown to the
player — the whole point is that the decision collapses into the `.gm/` hidden
state, out of the transcript, until the fiction earns the reveal.

## OPEN(type, slot, rivals)

Hand the choice to the **`gm:screen` subagent** (its *Seal an answer* task): pass
the campaign dir, `slot` as the id, and where the rivals live (the reservoir or
table they came from) — never the winner, and never a rival you've marked as the
favorite. It picks the canonical winner (or rolls among the rivals when the GM
asks for chance), drafts it under `.gm/inbox/` and seals it, consuming the
draft:

```
campaign gm-seal <campaign-dir> <slot> --from <campaign-dir>/.gm/inbox/<slot>.md
```

The winner's text never appears in a command or a reply: the subagent answers
`sealed '<slot>'`. Return `(sealed: <slot> in .gm/)`.

## BACKLINK(ref)

For an open table, add one line to the **durable** table's `## Cold storage` section
(`<campaign>/tables/<type>.md`) recording the decision for the GM's own continuity:

```
promoted <date>: <slot> — sealed in .gm/ (rivals kept)
```

For a sealed table (`<campaign>/.gm/tables/<type>.md`, sealed on disk) skip it:
`campaign gm-list` already shows the slot, and the line would only name it.

The rivals stay in cold storage; nothing is deleted (kill ≠ delete). Not the reservoir,
which is scratch and overwritten on the next forge.
