// What ref-links keeps in `$.state` for the session. The render hook reads
// both while it draws a reply, so a refresh that changes either redraws the
// replies with the new links.

/** A GitHub repository as `owner/repo`, spelled as GitHub returned it. */
export type Repo = string

declare module 'claude-code' {
  interface PluginState {
    'ref-links': {
      /** The known repos a `<word> #N` reference resolves against. */
      repos: Repo[]
      /** The session's own repo, from its `origin` remote; null when not on GitHub. */
      current: Repo | null
    }
  }
}
