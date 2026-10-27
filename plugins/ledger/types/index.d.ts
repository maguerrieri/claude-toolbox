// The ledger mod's state contract: what its pane and band draw from.

/** An open need of some session's ledger, as the pane and band show it. */
export type LedgerNeed = {
  /** The session whose ledger holds it (the file's name less `.jsonl`). */
  session: string
  /**
   * `this session`, else `<name> (<short id>)`: the name `claude agents` lists,
   * or the directory the session wrote from.
   */
  label: string
  id: string
  text: string
  ref?: string
  /** ISO-8601 UTC, when it was recorded. */
  at: string
}

/** A decision of this session's ledger. */
export type LedgerDecision = {
  id: string
  text: string
  ref?: string
  at: string
}

export type LedgerView = {
  /** Every session's open needs, newest first. */
  needs: LedgerNeed[]
  /** This session's decisions, newest first, the latest ten. */
  decisions: LedgerDecision[]
}

declare module 'claude-code' {
  interface PluginState {
    ledger: {
      view: Shaped<LedgerView>
      /** The open needs the band was hidden for (their keys joined), or ''. */
      hiddenFor: string
    }
  }
}
