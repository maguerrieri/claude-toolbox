import type { On, ProcessRunResult } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine, MockClock } from 'claude-code/testing'

import { CHECK_MS, TTL_MS } from '../hooks/register'

const CURRENT_REMOTE = 'git@github.com:maguerrieri/claude-toolbox.git'
const issue = (repo: string, n: number) => `https://github.com/${repo}/issues/${n}`
const NOW = 1_800_000_000_000

type World = {
  /** Answers each `$.process.run`; null makes the command fail to start. */
  commands?: Record<string, string | null>
  remote?: string | null
  store?: Record<string, unknown>
}

/** The engine beneath the plugin: clock, store, repo, commands, and the drawn text. */
function world(on: On, { commands = {}, remote = CURRENT_REMOTE, store = {} }: World) {
  const clock: MockClock = mock.clock(on, { now: NOW })
  const stored: Record<string, unknown> = { ...store }
  const ran: string[] = []
  const drawn: string[] = []
  let repoRemote = remote

  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('classic.CwdChanged', () => ({}))
  on('store.get', ($, e) => ({ value: stored[e.key] }))
  on('store.set', ($, e) => {
    stored[e.key] = JSON.parse(JSON.stringify(e.value))
    return { value: undefined }
  })
  on('session.repo', () => ({
    value: repoRemote === null ? null : { root: '/repo', remote: repoRemote, internal: false, name: null },
  }))
  on('process.run', ($, e) => {
    const line = e.argv.join(' ')
    ran.push(line)
    const out = commands[line]
    if (out === null) return { deny: `${e.argv[0]}: not found` }
    const result: ProcessRunResult =
      out === undefined
        ? { exitCode: 1, stdout: '', stderr: 'unexpected', isStdoutTruncated: false, isStderrTruncated: false }
        : { exitCode: 0, stdout: out, stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
    return { value: result }
  })
  on('ui.render', { component: 'AssistantMessage' }, ($, e) => {
    drawn.push(e.props.text)
    return { type: 'engine', ref: 0 }
  })

  return {
    clock,
    ran,
    stored,
    setRemote: (url: string | null) => {
      repoRemote = url
    },
    /** What the engine is handed to draw for a reply block. */
    draw: async ($: Engine, text: string) => {
      await $.ui.render({ surface: 'terminal', component: 'AssistantMessage', requestId: `m${drawn.length}`, props: { text, isFirstOfReply: true } })
      return drawn[drawn.length - 1]
    },
  }
}

const start = ($: Engine) => $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })

const AGENTS = JSON.stringify([
  { cwd: '/dev/www' },
  { cwd: '/dev/claude-toolbox/.claude/worktrees/223-x' },
  { cwd: '/gone' },
  { cwd: '/dev/gitlab-thing' },
])
const SOURCES: Record<string, string | null> = {
  'claude agents --json --all': AGENTS,
  'git -C /dev/www remote get-url origin': 'git@github.com:maguerrieri/www.git\n',
  'git -C /dev/claude-toolbox remote get-url origin': `${CURRENT_REMOTE}\n`,
  'git -C /dev/gitlab-thing remote get-url origin': 'git@gitlab.com:me/thing.git\n',
  'gh api user --jq .login': 'maguerrieri\n',
  'gh api users/maguerrieri/events?per_page=100 --paginate --jq .[].repo.name': 'maguerrieri/provenance\nanthropics/claude-code\n',
  'gh api user/repos?sort=pushed&per_page=100 --jq .[].full_name': 'maguerrieri/www\nmaguerrieri/dotfiles\n',
}

describe('the render hook', () => {
  test('links the three forms once the cache is warm', async ($, on) => {
    const w = world(on, {
      store: { known: { repos: ['maguerrieri/www'], refreshedAt: NOW } },
    })
    await start($)
    expect(await w.draw($, '#219, www #8 and maguerrieri/provenance#3')).toBe(
      `[#219](${issue('maguerrieri/claude-toolbox', 219)}), [www #8](${issue('maguerrieri/www', 8)}) and ` +
        `[maguerrieri/provenance#3](${issue('maguerrieri/provenance', 3)})`,
    )
  })

  test('passes a reply with no references through unchanged', async ($, on) => {
    const w = world(on, { store: { known: { repos: [], refreshedAt: NOW } } })
    await start($)
    const text = 'Nothing here but `#12` in code.'
    expect(await w.draw($, text)).toBe(text)
  })

  test('with the cache empty and still refreshing, links only owner/repo and the current repo', async ($, on) => {
    // No answers yet: every source command fails, as if still running.
    const w = world(on, {})
    await start($)
    expect(await w.draw($, 'www #8, #9 and octo/widgets#1')).toBe(
      `www [#8](${issue('maguerrieri/claude-toolbox', 8)}), [#9](${issue('maguerrieri/claude-toolbox', 9)}) and ` +
        `[octo/widgets#1](${issue('octo/widgets', 1)})`,
    )
  })

  test('without a GitHub remote, a bare #N stays plain', async ($, on) => {
    const w = world(on, { remote: 'git@gitlab.com:me/thing.git', store: { known: { repos: [], refreshedAt: NOW } } })
    await start($)
    expect(await w.draw($, 'PR #219')).toBe('PR #219')
  })
})

describe('the refresh', () => {
  test('gathers repos from sessions, GitHub and the current repo, off the render path', async ($, on) => {
    const w = world(on, { commands: SOURCES })
    await start($)
    expect(w.ran).toEqual([])

    await w.clock.settle()
    expect(w.ran).toContain('claude agents --json --all')
    expect(w.ran).not.toContain('git -C /dev/claude-toolbox/.claude/worktrees/223-x remote get-url origin')

    expect(w.stored.known).toEqual({
      repos: [
        'anthropics/claude-code',
        'maguerrieri/claude-toolbox',
        'maguerrieri/dotfiles',
        'maguerrieri/provenance',
        'maguerrieri/www',
      ],
      refreshedAt: NOW,
    })
    expect(await w.draw($, 'www #8')).toBe(`[www #8](${issue('maguerrieri/www', 8)})`)
  })

  test('without gh, keeps the local sources and the last GitHub list', async ($, on) => {
    const commands = { ...SOURCES, 'gh api user --jq .login': null }
    const w = world(on, {
      commands,
      store: { known: { repos: ['maguerrieri/provenance'], refreshedAt: NOW - TTL_MS - 1 } },
    })
    await start($)
    await w.clock.settle()
    expect(w.stored.known).toHaveProperty('repos', ['maguerrieri/claude-toolbox', 'maguerrieri/provenance', 'maguerrieri/www'])
  })

  test('skips a fresh cache, and refreshes once it ages past the TTL', async ($, on) => {
    const w = world(on, { commands: SOURCES, store: { known: { repos: ['maguerrieri/www'], refreshedAt: NOW } } })
    await start($)
    await w.clock.settle()
    expect(w.ran).toEqual([])

    await w.clock.advance(TTL_MS - CHECK_MS)
    expect(w.ran).toEqual([])
    await w.clock.advance(CHECK_MS)
    expect(w.ran).toContain('claude agents --json --all')
  })
})

describe('the current repo', () => {
  test('follows a change of directory', async ($, on) => {
    const w = world(on, { store: { known: { repos: [], refreshedAt: NOW } } })
    await start($)
    expect(await w.draw($, '#1')).toBe(`[#1](${issue('maguerrieri/claude-toolbox', 1)})`)

    w.setRemote('https://github.com/maguerrieri/www.git')
    await $.classic.CwdChanged({ old_cwd: '/repo', new_cwd: '/www' })
    expect(await w.draw($, '#1')).toBe(`[#1](${issue('maguerrieri/www', 1)})`)
  })
})
