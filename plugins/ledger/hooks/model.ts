// What the band draws, read from ledger files: pure functions, so the tests
// reach them without a session. From the #319 mock (mocks/ledger-panel), whose
// parsing and order are the mod PR #272 built (commit 5c8edb0) and match
// scripts/ledger.sh.
import type { LedgerNeed, LedgerView } from '../types'

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

/** Each session's ledger entries, by session id, as the reader found them. */
export type Ledgers = Readonly<Record<string, readonly Entry[]>>

export const EMPTY_VIEW: LedgerView = { needs: [] }

const isOptionalString = (value: unknown): boolean => value === undefined || value === null || typeof value === 'string'

// An entry as scripts/is-entry.jq counts one: a string kind, id, text and at,
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
 * The ledger file of <session> in <dir>, or undefined for a session id that
 * can't name one: a plain token, as scripts/ledger.sh requires of it.
 */
export const ledgerFileOf = (dir: string, session: string): string | undefined => {
  const isToken = /^[A-Za-z0-9._-]+$/.test(session) && session !== '.' && !session.includes('..')

  return isToken ? `${dir}/${session}.jsonl` : undefined
}

/** Whether `ledger.sh resolve` takes <id> as a need id: `n`, then a number. */
export const isResolvable = (id: string): boolean => /^n[1-9][0-9]{0,8}$/.test(id)

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

const numberOf = (id: string): number => Number(id.slice(1)) || 0

// Newest first: by time, then session, then id, all descending, comparing
// strings by code unit as jq's sort does.
const byNewest = (a: LedgerNeed, b: LedgerNeed): number => {
  if (a.at !== b.at) {
    return a.at < b.at ? 1 : -1
  }
  if (a.session !== b.session) {
    return a.session < b.session ? 1 : -1
  }

  return numberOf(b.id) - numberOf(a.id)
}

/** The key a need goes by: its session and its id, never its ref. */
export const keyOf = (need: { session: string; id: string }): string => `${need.session}:${need.id}`

/**
 * The view the band draws: the open needs of every ledger it is given, newest
 * first, each its own row (two needs that share a ref stay two rows, a lesson
 * of PR #272's review). Which ledgers it is given is the reader's call.
 */
export const viewOf = (ledgers: Ledgers): LedgerView => ({
  needs: Object.entries(ledgers)
    .flatMap(([session, entries]) =>
      entries
        .filter(entry => entry.kind === 'need' && entry.resolved_at === undefined)
        .map(
          (entry): LedgerNeed => ({
            key: keyOf({ session, id: entry.id }),
            session,
            id: clean(entry.id),
            ...whyOf(entry.why),
            text: clean(entry.text),
            ...(entry.ref === undefined ? {} : { ref: clean(entry.ref) }),
            at: entry.at,
          }),
        ),
    )
    .sort(byNewest),
})

/** The key Hide remembers: the open needs it was hidden for. */
export const needsKey = (view: LedgerView): string => view.needs.map(need => need.key).join(',')

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

/** A text's first line, for a one-row band. */
export const firstLine = (text: string): string => text.split('\n')[0] ?? ''

/** `1 open need`, `3 open needs`. */
export const countOf = (count: number): string => `${count} open ${count === 1 ? 'need' : 'needs'}`
