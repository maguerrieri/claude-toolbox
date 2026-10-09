// The pure half of ref-links: find the #N references in a reply's markdown,
// decide which repo each one means, and write them back as GitHub links.
// No `$` here, so the tests exercise it directly.

import type { Repo } from '../types'

/** What a reference resolves against: the session's repo and the known ones. */
export type LinkContext = {
  current: Repo | null
  known: readonly Repo[]
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
export function linkify(text: string, context: LinkContext): string {
  if (!/#[1-9]/.test(text)) return text

  const isProtected = protectedRanges(text)
  const byName = indexByName(context)
  let out = ''
  let copied = 0

  for (const m of text.matchAll(REF)) {
    const hash = m.index
    const end = hash + m[0].length
    if (isProtected(hash, end)) continue

    const link = resolve(text, hash, Number(m[1]), context, byName, isProtected)
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
  context: LinkContext,
  byName: Map<string, Repo[]>,
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
    if (named) return { start, url: issueUrl(`${named[1]}/${named[2]}`, n) }

    const repos = REPO_NAME.test(token) ? byName.get(token.toLowerCase()) : undefined
    if (repos !== undefined) {
      const repo = pick(repos, context.current)
      return repo === null ? null : { start, url: issueUrl(repo, n) }
    }
  }

  // A bare #N, or one after a word that names no known repo: the current repo.
  const before = text[hash - 1]
  if (context.current === null || (before !== undefined && !LEFT.test(before))) return null
  return { start: hash, url: issueUrl(context.current, n) }
}

/** The one repo a name means, preferring the current repo's owner; else null. */
function pick(repos: readonly Repo[], current: Repo | null): Repo | null {
  if (repos.length === 1) return repos[0] ?? null
  const owner = current?.split('/')[0]?.toLowerCase()
  const mine = repos.filter(repo => repo.split('/')[0]?.toLowerCase() === owner)
  return mine.length === 1 ? (mine[0] ?? null) : null
}

function indexByName(context: LinkContext): Map<string, Repo[]> {
  const all = mergeRepos(context.current === null ? context.known : [...context.known, context.current])
  const byName = new Map<string, Repo[]>()
  for (const repo of all) {
    const name = repo.slice(repo.indexOf('/') + 1).toLowerCase()
    byName.set(name, [...(byName.get(name) ?? []), repo])
  }
  return byName
}

function issueUrl(repo: Repo, n: number): string {
  return `https://github.com/${repo}/issues/${n}`
}

// ---------------------------------------------------------------------------
// The parts of the markdown no reference is looked for in: fenced code
// blocks, headings, code spans, links, autolinks and HTML tags, bare URLs,
// and backslash escapes.

const FENCE = /^[ \t>]*(`{3,}|~{3,})(.*)$/
const HEADING = /^ {0,3}(?:>[ \t]*)*#{1,6}(?:[ \t]|$)/
const AUTOLINK_OR_TAG = /<(?:[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*|\/?[A-Za-z][^<>]*)>/y
const BARE_URL = /(?:(?:https?|ftp|file):\/\/|www\.)[^\s<>]*/iy

function protectedRanges(text: string): (start: number, end: number) => boolean {
  const ranges: Range[] = []
  const prose: Range[] = []

  // Lines first: fences and headings are whole lines.
  let fence: { char: string; length: number } | null = null
  let fenceStart = 0
  let proseStart = 0
  let offset = 0
  for (const line of text.split('\n')) {
    const lineEnd = offset + line.length
    const opener = FENCE.exec(line)
    if (fence !== null) {
      const marker = opener?.[1]
      if (marker !== undefined && marker[0] === fence.char && marker.length >= fence.length && opener?.[2]?.trim() === '') {
        ranges.push([fenceStart, lineEnd])
        fence = null
        proseStart = lineEnd + 1
      }
    } else if (opener?.[1] !== undefined && !(opener[1][0] === '`' && opener[2]?.includes('`'))) {
      prose.push([proseStart, offset])
      fence = { char: opener[1][0] ?? '`', length: opener[1].length }
      fenceStart = offset
    } else if (HEADING.test(line)) {
      prose.push([proseStart, offset])
      ranges.push([offset, lineEnd])
      proseStart = lineEnd + 1
    }
    offset = lineEnd + 1
  }
  if (fence !== null) ranges.push([fenceStart, text.length])
  else prose.push([proseStart, text.length])

  // Then the inline constructs, inside each stretch of prose, a paragraph at
  // a time so a stray backtick can't pair across a blank line.
  for (const [from, to] of prose) {
    let paragraphStart = from
    for (const blank of text.slice(from, to).matchAll(/\n[ \t]*\n/g)) {
      inlineRanges(text, paragraphStart, from + blank.index, ranges)
      paragraphStart = from + blank.index + blank[0].length
    }
    inlineRanges(text, paragraphStart, to, ranges)
  }

  return (start, end) => ranges.some(([a, b]) => start < b && a < end)
}

function inlineRanges(text: string, from: number, to: number, ranges: Range[]): void {
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
      const linkEnd = matchLink(text, c === '!' ? i + 1 : i, to)
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
 * `[text][ref]`, or -1 when the brackets aren't followed by either.
 */
function matchLink(text: string, open: number, to: number): number {
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
  return -1
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
