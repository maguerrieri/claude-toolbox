// The ledger mod's state contract: what its pane and band draw from.

/** Where an open need is recorded: a session's ledger, and the need's id. */
export type LedgerCopy = {
  /** The session whose ledger holds it (the file's name less `.jsonl`). */
  session: string
  /**
   * `this session`, else `<name> (<short id>)`: the name `claude agents` lists,
   * or the directory the session wrote from.
   */
  label: string
  id: string
}

/**
 * An open need, as the pane and band show it: the first recorded, and any
 * other open need with the same ref (its copies up the spawn tree).
 */
export type LedgerNeed = LedgerCopy & {
  text: string
  ref?: string
  /** ISO-8601 UTC, when it was recorded. */
  at: string
  also: LedgerCopy[]
}

/** A decision of this session's ledger. */
export type LedgerDecision = {
  id: string
  text: string
  ref?: string
  at: string
}

export type LedgerView = {
  /** Every session's open needs, a shared ref's once, newest first. */
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
