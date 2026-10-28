// What the mod draws, read from the ledger files: pure functions, so the
// plugin's tests reach them without a session. The order and the session
// labels match scripts/ledger.sh's `list --all`.
import type { LedgerDecision, LedgerNeed, LedgerView } from '../types'

/** One line of a ledger file, as scripts/ledger.sh writes it. */
export type Entry = {
  kind: 'decision' | 'need'
  id: string
  text: string
  ref?: string
  at: string
  cwd?: string
  resolved_at?: string
}

export const EMPTY_VIEW: LedgerView = { needs: [], decisions: [] }

const isOptionalString = (value: unknown): boolean => value === undefined || value === null || typeof value === 'string'

// An entry as scripts/ledger.sh counts one: a string kind, id, text and at,
// and a ref, cwd and resolved_at that are strings or absent (null counts as
// absent). Anything else a hand edit left is skipped, as the script skips it.
const isEntry = (value: unknown): value is Record<string, unknown> => {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return false
  }
  const entry = value as Record<string, unknown>

  return (
    (entry.kind === 'decision' || entry.kind === 'need') &&
    typeof entry.id === 'string' &&
    typeof entry.text === 'string' &&
    typeof entry.at === 'string' &&
    isOptionalString(entry.ref) &&
    isOptionalString(entry.cwd) &&
    isOptionalString(entry.resolved_at)
  )
}

const stringOrAbsent = (value: unknown): string | undefined => (typeof value === 'string' ? value : undefined)

/** A ledger file's entries, skipping any line that isn't one. */
export const parseLedger = (text: string): Entry[] =>
  text.split('\n').flatMap((line): Entry[] => {
    let value: unknown
    try {
      value = JSON.parse(line)
    } catch {
      return []
    }
    if (!isEntry(value)) {
      return []
    }
    const [ref, cwd, resolvedAt] = [stringOrAbsent(value.ref), stringOrAbsent(value.cwd), stringOrAbsent(value.resolved_at)]

    return [
      {
        kind: value.kind as Entry['kind'],
        id: value.id as string,
        text: value.text as string,
        ...(ref === undefined ? {} : { ref }),
        at: value.at as string,
        ...(cwd === undefined ? {} : { cwd }),
        ...(resolvedAt === undefined ? {} : { resolved_at: resolvedAt }),
      },
    ]
  })

/**
 * The session a ledger file belongs to, or undefined for a file that isn't
 * one: a plain token, as the script names them, less `.jsonl`.
 */
export const sessionOf = (fileName: string): string | undefined => {
  if (!fileName.endsWith('.jsonl')) {
    return undefined
  }
  const session = fileName.slice(0, -'.jsonl'.length)
  const isToken = /^[A-Za-z0-9._-]+$/.test(session) && session !== '.' && !session.includes('..')

  return isToken ? session : undefined
}

/** Session names by session id, from `claude agents --json --all`. */
export const namesOf = (stdout: string): Record<string, string> => {
  try {
    const listed: unknown = JSON.parse(stdout)
    if (!Array.isArray(listed)) {
      return {}
    }
    const names: Record<string, string> = {}
    for (const agent of listed as unknown[]) {
      const { sessionId, name } = (agent ?? {}) as Record<string, unknown>
      if (typeof sessionId === 'string' && typeof name === 'string' && name !== '') {
        names[sessionId] = name
      }
    }

    return names
  } catch {
    return {}
  }
}

/** Control characters (C0 but tab and newline, DEL, C1) shown as `?`, as the script lists them. */
export const clean = (text: string): string =>
  text.replace(/[\x01-\x08\x0b-\x1f\x7f-\x9f]/g, '?')

const labelOf = (
  session: string,
  me: string,
  names: Readonly<Record<string, string>>,
  cwd: string | undefined,
): string => {
  if (session === me) {
    return 'this session'
  }
  // The short id is `claude attach`'s handle and a `resolve --session` prefix.
  const name = names[session] ?? (cwd ?? '').split('/').filter(part => part !== '').at(-1) ?? '?'

  return `${clean(name)} (${session.slice(0, 8)})`
}

const numberOf = (id: string): number => Number(id.slice(1)) || 0

// Newest first: by time, then session, then id, all descending, comparing
// strings by code unit as jq's sort does.
const byNewest = (
  a: { at: string; id: string; session?: string },
  b: { at: string; id: string; session?: string },
): number => {
  if (a.at !== b.at) {
    return a.at < b.at ? 1 : -1
  }
  const [left, right] = [a.session ?? '', b.session ?? '']
  if (left !== right) {
    return left < right ? 1 : -1
  }

  return numberOf(b.id) - numberOf(a.id)
}

type OpenNeed = Omit<LedgerNeed, 'also'>

// Groups of open needs, each oldest first, newest first: by the newest time
// in the group, then by its first need's session and id.
const byNewestGroup = (a: readonly OpenNeed[], b: readonly OpenNeed[]): number => {
  const latest = (group: readonly OpenNeed[]): string => group.reduce((at, need) => (need.at > at ? need.at : at), '')
  if (latest(a) !== latest(b)) {
    return latest(a) < latest(b) ? 1 : -1
  }

  return byNewest({ ...(a[0] as OpenNeed), at: '' }, { ...(b[0] as OpenNeed), at: '' })
}

/**
 * The view the pane and band draw: every ledger's open needs, and this
 * session's latest ten decisions. Open needs that share a ref are one need
 * recorded on its way up the spawn tree, so they're one row: the first
 * recorded, naming the rest, ordered by the newest of them.
 */
export const viewOf = (
  ledgers: Readonly<Record<string, readonly Entry[]>>,
  me: string,
  names: Readonly<Record<string, string>>,
): LedgerView => {
  const groups = new Map<string, OpenNeed[]>()
  for (const [session, entries] of Object.entries(ledgers)) {
    for (const entry of entries) {
      if (entry.kind !== 'need' || entry.resolved_at !== undefined) {
        continue
      }
      const need: OpenNeed = {
        session,
        label: labelOf(session, me, names, entry.cwd),
        id: entry.id,
        text: clean(entry.text),
        ...(entry.ref === undefined ? {} : { ref: clean(entry.ref) }),
        at: entry.at,
      }
      // A need without a ref is a group of its own.
      const key = entry.ref === undefined ? `\0${session}\0${entry.id}` : `ref\0${entry.ref}`
      groups.set(key, [...(groups.get(key) ?? []), need])
    }
  }
  const needs = [...groups.values()]
    // Oldest first within a group, so the first recorded leads it.
    .map(group => [...group].sort(byNewest).reverse())
    .sort(byNewestGroup)
    .map(([first, ...rest]): LedgerNeed => ({
      ...(first as OpenNeed),
      also: rest.map(({ session, label, id }) => ({ session, label, id })),
    }))
  const decisions: LedgerDecision[] = (ledgers[me] ?? [])
    .filter(entry => entry.kind === 'decision')
    .map(entry => ({
      id: entry.id,
      text: clean(entry.text),
      ...(entry.ref === undefined ? {} : { ref: clean(entry.ref) }),
      at: entry.at,
    }))

  return { needs, decisions: decisions.sort(byNewest).slice(0, 10) }
}

/** The key the band's Hide remembers: the open needs it was hidden for. */
export const needsKey = (view: LedgerView): string =>
  view.needs
    .flatMap(need => [need, ...need.also])
    .map(copy => `${copy.session}:${copy.id}`)
    .join(',')

/** How long ago <at> was, from <nowMs>: `now`, `5m`, `3h`, `2d`. */
export const ageOf = (at: string, nowMs: number): string => {
  const thenMs = Date.parse(at)
  if (Number.isNaN(thenMs)) {
    return '?'
  }
  const minutes = Math.floor((nowMs - thenMs) / 60_000)
  if (minutes < 1) {
    return 'now'
  }
  if (minutes < 60) {
    return `${minutes}m`
  }
  const hours = Math.floor(minutes / 60)

  return hours < 48 ? `${hours}h` : `${Math.floor(hours / 24)}d`
}

/** A text's first line, for the band's one row. */
export const firstLine = (text: string): string => text.split('\n')[0] ?? ''
