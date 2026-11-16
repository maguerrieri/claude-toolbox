// The mock's state contract: what its pane, band and status line draw from.

/** The four panel options this mock compares (#319). */
export type Variant = 'pane' | 'status' | 'band' | 'inline'

/** A need, as the panel shows it. */
export type MockNeed = {
  /** What it goes by across sessions: `<session>:<id>`, the id as the ledger holds it. */
  key: string
  /** The session whose ledger holds it (the file's name less `.jsonl`). */
  session: string
  /**
   * `this session`, else `<name> (<short id>)`: the name `claude agents` lists,
   * or the directory the session wrote from.
   */
  label: string
  id: string
  /** One short line of history and goal (absent in older entries). */
  why?: string
  text: string
  ref?: string
  /** ISO-8601 UTC, when it was recorded. */
  at: string
  /** ISO-8601 UTC, when it was resolved; absent while open. */
  resolvedAt?: string
}

/** A decision of this session's ledger. */
export type MockDecision = {
  id: string
  why?: string
  text: string
  ref?: string
  at: string
}

export type MockView = {
  /** The open needs in scope, newest first. */
  needs: MockNeed[]
  /** The resolved needs in scope, the latest resolved first, ten at most. */
  resolved: MockNeed[]
  /** This session's decisions, newest first, the latest ten. */
  decisions: MockDecision[]
}

declare module 'claude-code' {
  interface PluginState {
    'ledger-panel-mock': {
      view: Shaped<MockView>
      /** The open needs the band was hidden for (their keys joined), or ''. */
      hiddenFor: string
      /**
       * Needs a Resolve press marked resolved in this mock only, by key
       * (`<session>:<id>`), each with the ISO-8601 UTC time it was pressed.
       * Nothing is written to a ledger.
       */
      resolvedHere: Shaped<Record<string, string>>
      /** Whether the pane lists resolved needs too. */
      isShowingResolved: boolean
      /** Whether the inline band is expanded into its list. */
      isExpanded: boolean
      /** The minute the poll last saw, which redraws the ages a drawing shows. */
      minute: number
    }
  }
}
