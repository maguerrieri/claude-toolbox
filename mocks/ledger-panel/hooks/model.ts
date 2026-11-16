// What the mock draws, read from ledger files: pure functions, so the tests
// reach them without a session. Adapted from the mod PR #272 built and then
// split out (commit 5c8edb0, plugins/ledger/hooks/model.ts): the parsing, the
// order and the session labels are that mod's, which match scripts/ledger.sh.
import type { MockDecision, MockNeed, MockView } from '../types'

/** One line of a ledger file, as scripts/ledger.sh writes it. */
export type Entry = {
  kind: 'decision' | 'need'
  id: string
  /** Its Why line: one short line of history and goal (absent in older entries). */
  why?: string
  text: string
  ref?: string
  at: string
  cwd?: string
  resolved_at?: string
}

export const EMPTY_VIEW: MockView = { needs: [], resolved: [], decisions: [] }

// The fixtures' "this session": the session of the one real ledger on the
// machine the mock was built on (its n1 is that ledger's line, verbatim).
export const FIXTURE_ME = '064d2730-a02f-402d-a56b-b51e807c396e'

const isOptionalString = (value: unknown): boolean => value === undefined || value === null || typeof value === 'string'

// An entry as scripts/ledger.sh counts one: a string kind, id, text and at,
// and a why, ref, cwd and resolved_at that are strings or absent (null counts
// as absent). Anything else a hand edit left is skipped, as the script skips
// it.
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
    isOptionalString(entry.why) &&
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
    const [why, ref, cwd, resolvedAt] = [
      stringOrAbsent(value.why),
      stringOrAbsent(value.ref),
      stringOrAbsent(value.cwd),
      stringOrAbsent(value.resolved_at),
    ]

    return [
      {
        kind: value.kind as Entry['kind'],
        id: value.id as string,
        ...(why === undefined ? {} : { why }),
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

/** Session names by session id, from `claude agents --json --all` (or the fixture in its shape). */
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

/**
 * The characters scripts/ledger.sh's `clean` shows as `?`: control characters
 * (C0 but tab and newline, DEL, C1), zero-width and bidi-override ones, soft
 * hyphens, invisible separators and tag characters, so a ledger's text can't
 * reorder or hide what's drawn around it. Keep it in step with the script's.
 */
export const clean = (text: string): string =>
  text.replace(
    /[\u{1}-\u{8}\u{b}-\u{1f}\u{7f}-\u{9f}\u{200b}-\u{200f}\u{2028}-\u{202e}\u{2060}-\u{2064}\u{2066}-\u{2069}\u{feff}\u{ad}\u{61c}\u{180e}\u{fff9}-\u{fffb}\u{e0000}-\u{e007f}]/gu,
    '?',
  )

// A Why line as one line, as the script lists it: a hand edit could hold a
// newline.
const whyOf = (why: string | undefined): { why?: string } =>
  why === undefined ? {} : { why: clean(why.split('\n').join(' ')) }

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

/** The key a need goes by across sessions: its session and its id, never its ref. */
export const keyOf = (need: { session: string; id: string }): string => `${need.session}:${need.id}`

/** Whether any ledger but <me>'s has an open need, which only a session name labels. */
export const hasOthersNeed = (ledgers: Readonly<Record<string, readonly Entry[]>>, me: string): boolean =>
  Object.entries(ledgers).some(
    ([session, entries]) =>
      session !== me && entries.some(entry => entry.kind === 'need' && entry.resolved_at === undefined),
  )

/** Which ledgers a panel option reads: this session's alone, or every local session's. */
export type Scope = 'session' | 'all'

// The latest resolved first, then as byNewest.
const byResolved = (a: MockNeed, b: MockNeed): number => {
  const [left, right] = [a.resolvedAt ?? '', b.resolvedAt ?? '']
  if (left !== right) {
    return left < right ? 1 : -1
  }

  return byNewest(a, b)
}

/**
 * The view an option draws: the open needs in scope, each in the ledger of the
 * session that needs the owner and each its own row (two needs that share a
 * ref stay two rows, a lesson of PR #272's review); the latest resolved ones;
 * and this session's latest ten decisions. <resolvedHere> holds the needs a
 * Resolve press marked resolved in the mock alone, each with the time pressed.
 */
export const viewOf = (
  ledgers: Readonly<Record<string, readonly Entry[]>>,
  me: string,
  names: Readonly<Record<string, string>>,
  scope: Scope,
  resolvedHere: Readonly<Record<string, string>> = {},
): MockView => {
  const inScope = Object.entries(ledgers).filter(([session]) => scope === 'all' || session === me)
  const all: MockNeed[] = inScope.flatMap(([session, entries]) =>
    entries
      .filter(entry => entry.kind === 'need')
      .map((entry): MockNeed => {
        const key = keyOf({ session, id: entry.id })
        const resolvedAt = entry.resolved_at ?? resolvedHere[key]

        return {
          key,
          session,
          label: labelOf(session, me, names, entry.cwd),
          id: clean(entry.id),
          ...whyOf(entry.why),
          text: clean(entry.text),
          ...(entry.ref === undefined ? {} : { ref: clean(entry.ref) }),
          at: entry.at,
          ...(resolvedAt === undefined ? {} : { resolvedAt }),
        }
      }),
  )
  const decisions: MockDecision[] = (ledgers[me] ?? [])
    .filter(entry => entry.kind === 'decision')
    .map(entry => ({
      id: clean(entry.id),
      ...whyOf(entry.why),
      text: clean(entry.text),
      ...(entry.ref === undefined ? {} : { ref: clean(entry.ref) }),
      at: entry.at,
    }))

  return {
    needs: all.filter(need => need.resolvedAt === undefined).sort(byNewest),
    resolved: all
      .filter(need => need.resolvedAt !== undefined)
      .sort(byResolved)
      .slice(0, 10),
    decisions: decisions.sort(byNewest).slice(0, 10),
  }
}

/** The key Hide remembers: the open needs it was hidden for. */
export const needsKey = (view: MockView): string => view.needs.map(need => need.key).join(',')

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

/** A text's first line, for a one-row band or status line. */
export const firstLine = (text: string): string => text.split('\n')[0] ?? ''

/** `1 open need`, `3 open needs`. */
export const countOf = (count: number): string => `${count} open ${count === 1 ? 'need' : 'needs'}`
