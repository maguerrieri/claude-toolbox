# ledger-panel-mock

A throwaway mod for #319: four ways a ledger panel could work, for the owner
to pick one for #316 to build. It isn't in the marketplace and never writes a
ledger.

```sh
claude --plugin-dir mocks/ledger-panel
```

Then type `/ledger-pane`, and pick another option in `/config`
(*Panel option*: `pane`, `status`, `band`, `inline`; *Ledger source*:
`fixtures` or `live`).

The options, what each looks like, what the mod API can do for toggling, and
the recommendation are in
[`docs/superpowers/specs/2026-11-15-ledger-panel-options.md`](../../docs/superpowers/specs/2026-11-15-ledger-panel-options.md).

Tests: `claude plugin test mocks/ledger-panel`.
