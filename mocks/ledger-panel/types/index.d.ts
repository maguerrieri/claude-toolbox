// The mock's state contract: what its pane, band and status line draw from.

/** The four panel options this mock compares (#319). */
export type Variant = 'pane' | 'status' | 'band' | 'inline'

/** A need, as the panel shows it. */
export type MockNeed = {
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
  /** The resolved needs in scope, newest first, the latest ten. */
  resolved: MockNeed[]
  /** This session's decisions, newest first, the latest ten. */
  decisions: MockDecision[]
}

declare module 'claude-code' {
  interface PluginState {
    'ledger-panel-mock': {
      view: Shaped<MockView>
      /** The open needs the band or status line was hidden for (their keys joined), or ''. */
      hiddenFor: string
      /** Needs a Resolve press marked resolved in this mock only (`<session>:<id>`); nothing is written. */
      resolvedHere: string[]
      /** Whether the pane lists resolved needs too. */
      isShowingResolved: boolean
      /** Whether the inline band is expanded into its list. */
      isExpanded: boolean
    }
  }
}
