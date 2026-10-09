// The pure half of ref-links: find the #N references in a reply's markdown,
// decide which repo each one means, and write them back as GitHub links.
// No `$` here, so the tests exercise it directly.

import type { Repo } from '../types'

/** What a reference resolves against: the session's repo and the known ones. */
export type LinkContext = {
  current: Repo | null
  known: readonly Repo[]
}

/** A LinkContext indexed for lookups; build it once per change, not per reply. */
export type RepoIndex = {
  current: Repo | null
  /** Every known repo and the current one, lowercased. */
  repos: ReadonlySet<string>
  /** The repos under each lowercased repo name. */
  byName: ReadonlyMap<string, readonly Repo[]>
}

const OWNER = '[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})'
const NAME = '[A-Za-z0-9._-]{1,100}'
const OWNER_REPO = new RegExp(`^(${OWNER})/(${NAME})$`)
const REPO_NAME = new RegExp(`^${NAME}$`)

// A remote on github.com: scp-style `git@github.com:o/r`, or a URL over
// https, ssh (port 443's ssh.github.com too) or git. Any other host, or an
// ssh alias that hides the host, isn't GitHub as far as we can tell.
const GITHUB_REMOTE = new RegExp(
  '^(?:(?:https?|ssh|git|git\\+ssh)://(?:[^@/\\s]+@)?(?:www\\.|ssh\\.)?github\\.com(?::\\d+)?/' +
    '|(?:[^@/\\s:]+@)?github\\.com:)' +
    `(${OWNER})/(${NAME}?)(?:\\.git)?/?$`,
  'i',
)

/** `owner/repo` for a GitHub remote URL, or null for anything else. */
export function parseGitHubRemote(url: string): Repo | null {
  const m = GITHUB_REMOTE.exec(url.trim())
  return m ? `${m[1]}/${m[2]}` : null
}

/** One list of repos: valid `owner/repo` only, case-insensitively unique, sorted. */
export function mergeRepos(repos: Iterable<string>): Repo[] {
  const byKey = new Map<string, Repo>()
  for (const raw of repos) {
    const repo = raw.trim()
    if (OWNER_REPO.test(repo) && !byKey.has(repo.toLowerCase())) byKey.set(repo.toLowerCase(), repo)
  }
  return [...byKey.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([, repo]) => repo)
}

/** The context indexed for linkify; the current repo counts as known. */
export function repoIndex(context: LinkContext): RepoIndex {
  const all = mergeRepos(context.current === null ? context.known : [...context.known, context.current])
  const byName = new Map<string, Repo[]>()
  for (const repo of all) {
    const name = repo.slice(repo.indexOf('/') + 1).toLowerCase()
    byName.set(name, [...(byName.get(name) ?? []), repo])
  }
  return { current: context.current, repos: new Set(all.map(repo => repo.toLowerCase())), byName }
}

// What may stand right before a reference (or before the repo word that
// leads one): the start, whitespace, or punctuation that opens or separates.
// Anything else (a letter, `/`, `&`, `-`, `.`) means the # is part of a word,
// a path or an entity.
const LEFT = /[\s([{<>"'*_~,;:!?|—–“‘]/
const TOKEN_CHAR = /[A-Za-z0-9._/-]/
const REF = /#([1-9][0-9]{0,6})(?![A-Za-z0-9_])/g

type Range = readonly [start: number, end: number]

/**
 * The reply's markdown with every #N reference drawn as a link to its issue
 * or PR. What the rules can't place, or would place ambiguously, is left as
 * written: a wrong link is worse than none.
 */
export function linkify(text: string, index: RepoIndex): string {
  if (!/#[1-9]/.test(text)) return text

  const isProtected = protectedRanges(text)
  let out = ''
  let copied = 0

  for (const m of text.matchAll(REF)) {
    const hash = m.index
    const end = hash + m[0].length
    if (isProtected(hash, end)) continue

    const link = resolve(text, hash, Number(m[1]), index, isProtected)
    if (link === null) continue

    out += text.slice(copied, link.start) + `[${text.slice(link.start, end)}](${link.url})`
    copied = end
  }

  return copied === 0 ? text : out + text.slice(copied)
}

type Link = { start: number; url: string }

function resolve(
  text: string,
  hash: number,
  n: number,
  index: RepoIndex,
  isProtected: (start: number, end: number) => boolean,
): Link | null {
  // The word before the #, directly attached or one space back.
  const tokenEnd = text[hash - 1] === ' ' ? hash - 1 : hash
  let start = tokenEnd
  while (start > 0 && TOKEN_CHAR.test(text[start - 1] ?? '')) start--
  const token = text.slice(start, tokenEnd)
  const isWord =
    token !== '' &&
    !token.endsWith('.') &&
    (start === 0 || LEFT.test(text[start - 1] ?? '')) &&
    !isProtected(start, tokenEnd)

  if (isWord) {
    const named = OWNER_REPO.exec(token)
    if (named) {
      // `owner/repo#N` is GitHub's own spelling: always that repo. With a
      // space, an a/b word is as often a branch or a path (`origin/main
      // #219`), so only a repo we know of counts; any other is just a word.
      const repo = `${named[1]}/${named[2]}`
      if (tokenEnd === hash || index.repos.has(repo.toLowerCase())) return { start, url: issueUrl(repo, n) }
    } else {
      const repos = REPO_NAME.test(token) ? index.byName.get(token.toLowerCase()) : undefined
      if (repos !== undefined) {
        const repo = pick(repos, index.current)
        return repo === null ? null : { start, url: issueUrl(repo, n) }
      }
    }
  }

  // A bare #N, or one after a word that names no known repo: the current repo.
  const before = text[hash - 1]
  if (index.current === null || (before !== undefined && !LEFT.test(before))) return null
  return { start: hash, url: issueUrl(index.current, n) }
}

/** The one repo a name means, preferring the current repo's owner; else null. */
function pick(repos: readonly Repo[], current: Repo | null): Repo | null {
  if (repos.length === 1) return repos[0] ?? null
  const owner = current?.split('/')[0]?.toLowerCase()
  const mine = repos.filter(repo => repo.split('/')[0]?.toLowerCase() === owner)
  return mine.length === 1 ? (mine[0] ?? null) : null
}

function issueUrl(repo: Repo, n: number): string {
  return `https://github.com/${repo}/issues/${n}`
}

// ---------------------------------------------------------------------------
// The parts of the markdown no reference is looked for in: fenced and
// indented code blocks, headings, link reference definitions, code spans,
// links, autolinks and HTML tags, bare URLs, and backslash escapes.

const FENCE = /^[ \t>]*(`{3,}|~{3,})(.*)$/
const HEADING = /^ {0,3}(?:>[ \t]*)*#{1,6}(?:\s|$)/
// Four columns in, after a blank line, a heading or the start, is code; a
// list item that deep is a nested list. A list's own paragraph that deep is
// taken for code too: a missed link is the safe way to be wrong.
const INDENTED = /^(?: {4}| {0,3}\t)/
const LIST_ITEM = /^[ \t]*(?:[-*+]|\d{1,9}[.)])(?:\s|$)/
const DEFINITION = /^ {0,3}\[((?:[^[\]\\]|\\.)+)\]:/
const AUTOLINK_OR_TAG = /<(?:[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*|\/?[A-Za-z][^<>]*)>/y
const BARE_URL = /(?:(?:https?|ftp|file):\/\/|www\.)[^\s<>]*/iy

function protectedRanges(text: string): (start: number, end: number) => boolean {
  const ranges: Range[] = []
  const prose: Range[] = []
  const definitions = new Set<string>()

  // Lines first: code blocks, headings and definitions are whole lines.
  let fence: { char: string; length: number; start: number } | null = null
  let indented: number | null = null
  let codeMayStart = true
  let proseStart = 0
  let offset = 0
  for (const line of text.split('\n')) {
    const lineEnd = offset + line.length
    const isBlank = line.trim() === ''
    let endsBlock = false

    if (indented !== null && !isBlank && !INDENTED.test(line)) {
      ranges.push([indented, offset])
      indented = null
      proseStart = offset
    }

    if (fence !== null) {
      const closer = FENCE.exec(line)
      const marker = closer?.[1]
      if (marker !== undefined && marker[0] === fence.char && marker.length >= fence.length && closer?.[2]?.trim() === '') {
        ranges.push([fence.start, lineEnd])
        fence = null
        proseStart = lineEnd + 1
        endsBlock = true
      }
    } else if (indented === null) {
      const opener = FENCE.exec(line)
      const marker = opener?.[1]
      if (marker !== undefined && !(marker[0] === '`' && opener?.[2]?.includes('`'))) {
        prose.push([proseStart, offset])
        fence = { char: marker[0] ?? '`', length: marker.length, start: offset }
      } else if (codeMayStart && !isBlank && INDENTED.test(line) && !LIST_ITEM.test(line)) {
        prose.push([proseStart, offset])
        indented = offset
      } else if (HEADING.test(line) || DEFINITION.test(line)) {
        const label = DEFINITION.exec(line)?.[1]
        if (label !== undefined) definitions.add(normalizeLabel(label))
        prose.push([proseStart, offset])
        ranges.push([offset, lineEnd])
        proseStart = lineEnd + 1
        endsBlock = HEADING.test(line)
      }
    }

    codeMayStart = isBlank || endsBlock
    offset = lineEnd + 1
  }
  if (fence !== null) ranges.push([fence.start, text.length])
  else if (indented !== null) ranges.push([indented, text.length])
  else prose.push([proseStart, text.length])

  // Then the inline constructs, inside each stretch of prose, a paragraph at
  // a time so a stray backtick can't pair across a blank line.
  for (const [from, to] of prose) {
    let paragraphStart = from
    for (const blank of text.slice(from, to).matchAll(/\n[ \t]*\n/g)) {
      inlineRanges(text, paragraphStart, from + blank.index, definitions, ranges)
      paragraphStart = from + blank.index + blank[0].length
    }
    inlineRanges(text, paragraphStart, to, definitions, ranges)
  }

  return (start, end) => ranges.some(([a, b]) => start < b && a < end)
}

function inlineRanges(text: string, from: number, to: number, definitions: ReadonlySet<string>, ranges: Range[]): void {
  let i = from
  while (i < to) {
    const c = text[i]
    if (c === '\\') {
      ranges.push([i, i + 2])
      i += 2
    } else if (c === '`') {
      let run = i
      while (run < to && text[run] === '`') run++
      const width = run - i
      const close = findBacktickRun(text, run, to, width)
      if (close === -1) {
        i = run
      } else {
        ranges.push([i, close + width])
        i = close + width
      }
    } else if (c === '[' || (c === '!' && text[i + 1] === '[')) {
      const linkEnd = matchLink(text, c === '!' ? i + 1 : i, to, definitions)
      if (linkEnd === -1) {
        i++
      } else {
        ranges.push([i, linkEnd])
        i = linkEnd
      }
    } else if (c === '<') {
      i = skipMatch(AUTOLINK_OR_TAG, text, i, to, ranges)
    } else if (/[hHfFwW]/.test(c ?? '') && !/[A-Za-z0-9]/.test(text[i - 1] ?? '')) {
      i = skipMatch(BARE_URL, text, i, to, ranges)
    } else {
      i++
    }
  }
}

/** Protects a sticky pattern's match at `i` (within `to`); where to go on. */
function skipMatch(pattern: RegExp, text: string, i: number, to: number, ranges: Range[]): number {
  pattern.lastIndex = i
  const m = pattern.exec(text)
  if (m === null || pattern.lastIndex > to) return i + 1
  ranges.push([i, pattern.lastIndex])
  return pattern.lastIndex
}

/** Where the next run of exactly `width` backticks starts, or -1. */
function findBacktickRun(text: string, from: number, to: number, width: number): number {
  let i = from
  while (i < to) {
    if (text[i] !== '`') {
      i++
      continue
    }
    let run = i
    while (run < to && text[run] === '`') run++
    if (run - i === width) return i
    i = run
  }
  return -1
}

/**
 * The end of a link starting at the `[` at `open`: `[text](dest)`,
 * `[text][ref]`, or `[ref]` alone when the text defines `ref`; else -1.
 */
function matchLink(text: string, open: number, to: number, definitions: ReadonlySet<string>): number {
  const close = matchBracket(text, open, to, '[', ']')
  if (close === -1) return -1
  const next = text[close + 1]
  if (next === '(') {
    const end = matchBracket(text, close + 1, to, '(', ')')
    return end === -1 ? -1 : end + 1
  }
  if (next === '[') {
    const end = matchBracket(text, close + 1, to, '[', ']')
    return end === -1 ? -1 : end + 1
  }
  return definitions.has(normalizeLabel(text.slice(open + 1, close))) ? close + 1 : -1
}

function matchBracket(text: string, open: number, to: number, left: string, right: string): number {
  let depth = 0
  for (let i = open; i < to; i++) {
    const c = text[i]
    if (c === '\\') i++
    else if (c === left) depth++
    else if (c === right && --depth === 0) return i
  }
  return -1
}

/** A reference label as CommonMark matches it: trimmed, spaces collapsed, any case. */
function normalizeLabel(label: string): string {
  return label.trim().replace(/\s+/g, ' ').toLowerCase()
}
