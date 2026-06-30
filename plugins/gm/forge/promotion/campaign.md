# Promotion adapter: campaign

Seals the GM's chosen winner behind the screen. The rivals are never shown to
the player — the whole point is that the decision collapses into the `.gm/`
hidden state, invisible in the transcript, until the fiction earns the reveal.

## OPEN(type, slot, rivals)

Pick the canonical winner for `slot` from `rivals` (or roll among them using
`roll table <table-file>` — the harvested table from `forge harvest` — if one
exists). Once chosen, seal it:

```
campaign gm-seal <campaign-dir> <slot> "<chosen entry>"
```

The value lands in `.gm/`, written through the CLI so the transcript collapses
the write to a single neutral shell-command line — the rivals are never surfaced
to the player. Return `(sealed: <slot> in .gm/)`.

## BACKLINK(ref)

Add one line to the **durable** table's `## Cold storage` section —
`<campaign>/tables/<type>.md` (or the sealed `<campaign>/.gm/tables/<type>.md`) — recording
the decision for the GM's own continuity:

```
promoted <date>: <slot> — sealed in .gm/ (rivals kept)
```

The rivals stay in cold storage; nothing is deleted (kill ≠ delete). Not the reservoir,
which is scratch and overwritten on the next forge.
