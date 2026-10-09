import type { EngineInterface, Register, Timer } from 'claude-code'

import type { Repo } from '../types'
import { linkify, mergeRepos, parseGitHubRemote, repoIndex } from './linkify'
import type { RepoIndex } from './linkify'

// Drawing a reply reads these two values and nothing else, so it never waits
// on git or the network. The session refreshes them off the render path.
const REPOS = { plugin: 'ref-links', key: 'repos' } as const
const CURRENT = { plugin: 'ref-links', key: 'current' } as const

/** The known-repos cache in `$.store`, shared by every session. */
const STORE_KEY = 'known'
/** How old the cache may get before a session refreshes it. */
export const TTL_MS = 6 * 60 * 60 * 1000
/** How often a session checks the cache's age. */
export const CHECK_MS = 30 * 60 * 1000

/**
 * `repos` is every source merged. `local` and `github` are what each source
 * found, so a round where one fails can keep that source's last list.
 */
type Cache = { repos: Repo[]; local: Repo[]; github: Repo[]; refreshedAt: number }

/** What gh found, and whether both of its reads answered. */
type GitHubRepos = { repos: Repo[]; isComplete: boolean }

// Module state, which a reload starts over: whether a refresh is running (at
// worst a reload runs one twice), this load's timers, and the index built for
// the state versions it was built from.
let isRefreshing = false
let timers: Timer[] = []
let built: { versions: string; index: RepoIndex } | null = null

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    built = null
    try {
      const cache = readCache(await $.store.get(STORE_KEY))
      if (cache !== null) await setRepos($, cache.repos)
    } catch (error) {
      $.ui.log(`ref-links: reading the cache failed: ${String(error)}`, { to: 'debug' })
    }
    await refreshCurrent($)
    for (const timer of timers) timer.cancel()
    timers = [
      $.clock.after(0, () => void refreshIfStale($)),
      $.clock.every(CHECK_MS, () => void refreshIfStale($)),
    ]
    return started
  })

  // `/cd`, a worktree move or a host's directory change can put the session
  // in another repo. These hooks only observe or redraw, so on a failure the
  // event goes on as it came (a `next` already called replays its result).
  on('classic.CwdChanged', async ($, e, next) => {
    const result = await next(e)
    await refreshCurrent($)
    return result
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    const [repos, current] = await Promise.all([$.state.get(REPOS), $.state.get(CURRENT)])
    const versions = `${repos.version}:${current.version}`
    if (built?.versions !== versions) {
      built = { versions, index: repoIndex({ current: current.value ?? null, known: repos.value ?? [] }) }
    }
    const text = linkify(e.props.text, built.index)
    return text === e.props.text ? next(e) : next({ ...e, props: { ...e.props, text } })
  }).catch(($, e, next) => next(e))
}

async function refreshIfStale($: EngineInterface): Promise<void> {
  if (isRefreshing) return
  isRefreshing = true
  try {
    const now = await $.clock.now()
    const cache = readCache(await $.store.get(STORE_KEY))
    if (cache !== null && now - cache.refreshedAt < TTL_MS) {
      // Fresh, maybe from another session: take its list.
      await setRepos($, cache.repos)
      return
    }
    const current = (await $.state.get(CURRENT)).value ?? null
    const [found, fromGitHub] = await Promise.all([reposFromSessions($), reposFromGitHub($)])
    // A source that failed this round keeps its last list, and one of gh's
    // two reads failing adds to it rather than replacing it.
    const local = found === null ? (cache?.local ?? []) : mergeRepos(found)
    const github =
      fromGitHub === null
        ? (cache?.github ?? [])
        : mergeRepos(fromGitHub.isComplete ? fromGitHub.repos : [...fromGitHub.repos, ...(cache?.github ?? [])])
    const repos = mergeRepos([...local, ...github, ...(current === null ? [] : [current])])
    await $.store.set(STORE_KEY, { repos, local, github, refreshedAt: now } satisfies Cache)
    await setRepos($, repos)
  } catch (error) {
    $.ui.log(`ref-links: refreshing the known repos failed: ${String(error)}`, { to: 'debug' })
  } finally {
    isRefreshing = false
  }
}

function readCache(value: unknown): Cache | null {
  if (typeof value !== 'object' || value === null) return null
  const { repos, local, github, refreshedAt } = value as Partial<Record<keyof Cache, unknown>>
  if (!Array.isArray(repos) || typeof refreshedAt !== 'number') return null
  return { repos: repoList(repos), local: repoList(local), github: repoList(github), refreshedAt }
}

function repoList(values: unknown): Repo[] {
  if (!Array.isArray(values)) return []
  return mergeRepos(values.filter((value): value is string => typeof value === 'string'))
}

async function setRepos($: EngineInterface, repos: Repo[]): Promise<void> {
  const held = await $.state.get(REPOS)
  if (!sameList(held.value, repos)) await $.state.set(REPOS, repos)
}

/** Reads the session's repo into state; a failure leaves the state as it was. */
async function refreshCurrent($: EngineInterface): Promise<void> {
  try {
    const repo = await $.session.repo()
    const current = repo?.remote ? parseGitHubRemote(repo.remote) : null
    const held = await $.state.get(CURRENT)
    if (held.value !== current) await $.state.set(CURRENT, current)
  } catch (error) {
    $.ui.log(`ref-links: reading the session's repo failed: ${String(error)}`, { to: 'debug' })
  }
}

/**
 * The repos the owner's background sessions ran in, from each session's cwd;
 * null when `claude agents` fails or answers something else than a list.
 */
async function reposFromSessions($: EngineInterface): Promise<Repo[] | null> {
  const listed = await run($, ['claude', 'agents', '--json', '--all'])
  if (listed === null) return null
  let rows: unknown
  try {
    rows = JSON.parse(listed)
  } catch {
    return null
  }
  if (!Array.isArray(rows)) return null
  // A worktree under .claude/worktrees/ shares its main checkout's origin,
  // and the main checkout outlives it.
  const cwds = new Set<string>()
  for (const row of rows) {
    const cwd: unknown = (row as { cwd?: unknown } | null)?.cwd
    if (typeof cwd === 'string' && cwd !== '') cwds.add(cwd.replace(/\/\.claude\/worktrees\/.*$/, ''))
  }
  const remotes = await mapLimit([...cwds], 8, cwd => run($, ['git', '-C', cwd, 'remote', 'get-url', 'origin']))
  return remotes.flatMap(url => {
    const repo = url === null ? null : parseGitHubRemote(url)
    return repo === null ? [] : [repo]
  })
}

/**
 * The repos the owner touched on GitHub (their events, pushes to their own
 * repos); null when `gh` is missing, signed out, or both reads failed.
 */
async function reposFromGitHub($: EngineInterface): Promise<GitHubRepos | null> {
  const login = (await run($, ['gh', 'api', 'user', '--jq', '.login']))?.trim() ?? ''
  if (!/^[A-Za-z0-9-]{1,39}$/.test(login)) return null
  const [events, owned] = await Promise.all([
    run($, ['gh', 'api', `users/${login}/events?per_page=100`, '--paginate', '--jq', '.[].repo.name']),
    run($, ['gh', 'api', 'user/repos?sort=pushed&per_page=100', '--jq', '.[].full_name']),
  ])
  if (events === null && owned === null) return null
  const repos = `${events ?? ''}\n${owned ?? ''}`.split('\n').filter(line => line.trim() !== '')
  return { repos, isComplete: events !== null && owned !== null }
}

/** A command's stdout when it exits 0; null when it fails or can't start. */
async function run($: EngineInterface, argv: string[]): Promise<string | null> {
  try {
    const { exitCode, stdout } = await $.process.run(argv, { timeoutMs: 30_000 })
    return exitCode === 0 ? stdout : null
  } catch {
    return null
  }
}

async function mapLimit<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length)
  let next = 0
  const worker = async () => {
    while (next < items.length) {
      const i = next++
      results[i] = await fn(items[i] as T)
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker))
  return results
}

function sameList(a: readonly string[] | undefined, b: readonly string[]): boolean {
  return a !== undefined && a.length === b.length && a.every((x, i) => x === b[i])
}
