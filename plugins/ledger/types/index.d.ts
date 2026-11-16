// The ledger band's state contract: what the band above the prompt draws from.

/** An open need, as the band shows it. */
export type LedgerNeed = {
  /**
   * What it goes by: `<session>:<id>`, the id as the ledger holds it, with
   * `#2`, `#3` after a second or later need of one id (a hand edit).
   */
  key: string
  /** The session whose ledger holds it (the file's name less `.jsonl`). */
  session: string
  /** Its id (`n1`), any character the script's listing hides shown as `?`. */
  id: string
  /** One short line of history and goal (absent in older entries). */
  why?: string
  text: string
  ref?: string
  /** ISO-8601 UTC, when it was recorded. */
  at: string
}

export type LedgerView = {
  /** The open needs the reader found, newest first. */
  needs: LedgerNeed[]
}

declare module 'claude-code' {
  interface PluginState {
    ledger: {
      view: Shaped<LedgerView>
      /** The keys of the open needs the band showed when Hide was pressed. */
      hiddenFor: Shaped<string[]>
      /** Whether the band is expanded into its list. */
      isExpanded: boolean
      /** The minute the poll last saw, which redraws the ages the band shows. */
      minute: number
    }
  }
}
