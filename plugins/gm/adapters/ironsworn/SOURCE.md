# Source Attribution

The content in this adapter — moves, oracles, assets, and game mechanics — is derived from the **Ironsworn System Reference Document** by Shawn Tomkin.

**Ironsworn** is © 2018 Shawn Tomkin. The Ironsworn SRD is released under the **Creative Commons Attribution 4.0 International License (CC BY 4.0)**.

License text: https://creativecommons.org/licenses/by/4.0/

Source: https://www.ironswornrpg.com/

---

The move names, oracle tables, and mechanical structure in this adapter are curated and adapted from the SRD. Some entries (oracle rows, example assets) have been authoritatively rephrased or reorganised to fit this toolbox's data format, but the underlying game design remains Shawn Tomkin's. This adapter is not a complete reproduction of the Ironsworn rulebook — it is a mechanical reference for use with the GM plugin.

## Ask the Oracle

The five odds tables in `oracles/moves/ask-the-oracle/` (Almost Certain, Likely, 50/50, Unlikely, Small Chance) are the SRD's own, taken row for row from the machine-readable edition published by **Datasworn** (https://github.com/rsek/datasworn), at the same pin the `starforged` adapter uses:

- repo `rsek/datasworn`, tag `v0.1.0-prerelease`, commit `e643a75263c1cb3e845a0c0789879ff4e8b49532`
- file `datasworn/classic/classic.json`, sha256 `7c669d602cf05576d74a966d3eac0657bc55ddbdab2829507362f00004ef52fc`
- objects `move.oracle_rollable:classic/fate/ask_the_oracle.<odds>`

Each table's golden ranges are in `plugins/gm/tests/fixtures/oracles/ironsworn/moves/ask-the-oracle/`. CI checks them against the pinned file; to do it locally, run the gm tests with `DATASWORN_CLASSIC_JSON` set to a copy of it.
