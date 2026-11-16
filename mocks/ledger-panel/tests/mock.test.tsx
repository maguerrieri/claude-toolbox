// The mock under `claude plugin test mocks/ledger-panel`: each option's
// toggle, what it draws from ledgers the test serves as fixtures, and that it
// writes nothing.
import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

import { FIXTURE_ME, parseLedger, viewOf } from '../hooks/model'

const NOW = Date.parse('2026-11-16T02:00:00Z')
const OTHER = 'b55d97c7-d2d7-4968-92fc-11bf386f1ac9'
const FIXTURE_DIR = '/fixtures/session-ledger'

const line = (entry: Record<string, string>): string => JSON.stringify(entry)

// This session's ledger (a decision, an open need, a resolved one) and one
// other session's, whose need shares this session's open need's ref: two
// rows, never one.
const FILES: Record<string, string> = {
  [`${FIXTURE_ME}.jsonl`]: [
    line({ kind: 'decision', id: 'd1', why: 'status answers get rebuilt', text: 'Ship the per-session ledger first', ref: 'o/r#208', at: '2026-11-16T01:00:00Z' }),
    line({ kind: 'need', id: 'n1', why: 'status answers get rebuilt', text: 'Do the manual check\nthen resolve it', ref: 'o/r#300', at: '2026-11-16T01:50:00Z' }),
    line({ kind: 'need', id: 'n2', text: 'Unlock 1Password', at: '2026-11-15T23:00:00Z', resolved_at: '2026-11-16T01:30:00Z' }),
  ].join('\n'),
  [`${OTHER}.jsonl`]: [
    line({ kind: 'need', id: 'n1', why: 'PRs wait unseen', text: 'Run the PR #300 checklist', ref: 'o/r#300', at: '2026-11-15T16:00:00Z' }),
    'not json',
  ].join('\n'),
  'notes.txt': 'ignored',
}
const AGENTS = JSON.stringify([{ sessionId: OTHER, id: 'b55d97c7', name: 'toolbox #295: notifier install' }])

const BAND = {
  plugin: 'ledger-panel-mock',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isCollapsed: false,
    isWorking: false,
    maxRows: 12,
    bodyColumns: 100,
    scroll: { offset: 0, bodyRows: 12 },
    view: {},
  },
} as const

const PANE = {
  plugin: 'ledger-panel-mock',
  component: 'Pane',
  requestId: 'ledger',
  props: {
    title: 'Ledger',
    isFocused: false,
    bodyColumns: 60,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

// What the engine beneath the mock saw.
type Seen = {
  opens: { id: string; closeOnEscape?: true }[]
  closes: string[]
  statuses: (string | undefined)[]
  toasts: string[]
  runs: string[][]
  writes: string[]
  lists: string[]
  clock: ReturnType<typeof mock.clock>
}

// The engine beneath the mock: the fixtures served by file name, a pane
// record that ui.open and ui.close keep, and a log of what it was asked.
// `isPlaced: false` makes every open wait undrawn; `isMissing` makes every
// directory but the fixtures' not exist.
function world(on: On, { isPlaced = true, isMissing = false } = {}): Seen {
  const clock = mock.clock(on, { now: NOW })
  const seen: Seen = { opens: [], closes: [], statuses: [], toasts: [], runs: [], writes: [], lists: [], clock }
  const open = new Set<string>()
  const isFixtures = (path: string): boolean => path.endsWith(FIXTURE_DIR)
  mock.env(on, { HOME: '/home/u' })
  on('session.id', () => ({ value: 'live-session' }))
  on('fs.exists', (_, e) => ({ value: !isMissing || isFixtures(e.path) }))
  on('fs.list', (_, e) => {
    seen.lists.push(e.path)
    if (isMissing && !isFixtures(e.path)) {
      throw new Error('the directory could not be listed')
    }
    const entries = Object.entries(FILES).map(([name, text]) => ({
      name,
      kind: 'file' as const,
      size: text.length,
      mtimeMs: 1,
      isLink: false,
    }))

    return { value: isFixtures(e.path) ? entries : [] }
  })
  on('fs.read', (_, e) => ({
    value: e.path.endsWith('/fixtures/agents.json') ? AGENTS : (FILES[e.path.split('/').at(-1) ?? ''] ?? ''),
  }))
  on('fs.write', (_, e) => {
    seen.writes.push(e.path)

    return { value: undefined }
  })
  on('process.run', (_, e) => {
    seen.runs.push([...e.argv])

    return { value: { exitCode: 0, stdout: '[]', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.open', (_, e) => {
    seen.opens.push({ id: e.id, ...(e.closeOnEscape ? { closeOnEscape: e.closeOnEscape } : {}) })
    open.add(e.id)

    return { value: isPlaced ? { isPlaced: true } : { isPlaced: false, reason: 'the terminal is 80 columns' } }
  })
  on('ui.close', (_, e) => {
    seen.closes.push(e.id)
    open.delete(e.id)

    return { value: undefined }
  })
  on('ui.panes', () => ({
    value: [...open].map(id => ({ id, title: id, isShown: true, isFocused: false, isPlaced })),
  }))
  on('ui.status', (_, e) => {
    seen.statuses.push(e.text)

    return { value: undefined }
  })
  on('ui.toast', (_, e) => {
    seen.toasts.push(e.text)

    return { value: undefined }
  })
  on('command.register', () => ({ value: { command: 'ledger-pane' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))

  return seen
}

const START = { cwd: '/', surface: 'terminal', isInteractive: true } as const
// The person typing /ledger-pane, or a keybinding to command:ledger-pane.
const RUN = {
  command: 'ledger-pane',
  args: '',
  origin: { kind: 'composer' },
  presentation: { isFullscreen: true, columns: 160 },
} as const

test('pane: /ledger-pane opens the pane, Escape-closable, and a second run closes it', async ($, on) => {
  const seen = world(on)
  await $.session.start(START)

  await $.command.run(RUN)
  expect(seen.opens).toEqual([{ id: 'ledger', closeOnEscape: true }])
  await $.command.run(RUN)
  expect(seen.closes).toEqual(['ledger'])
  await $.command.run(RUN)
  expect(seen.opens.length).toBe(2)
})

test('pane: a pane that waits undrawn says why', async ($, on) => {
  world(on, { isPlaced: false })
  await $.session.start(START)

  expect((await $.command.run(RUN)).text).toBe('The ledger pane waits: the terminal is 80 columns')
})

test('pane: it lists this session\'s needs and decisions alone, on each surface, and clears any status line', async ($, on) => {
  const seen = world(on)
  await $.session.start(START)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /^This session/ }))?.text).toBe('This session')
    expect((await ui.find({ type: 'Text', text: /^Open needs/ }))?.text).toBe('Open needs (1)')
    expect((await ui.find({ type: 'Text', text: /^n1 ·/ }))?.text).toBe('n1 · o/r#300 · 10m')
    expect((await ui.find({ type: 'Text', text: /^Why: status/ }))?.text).toBe('Why: status answers get rebuilt')
    expect(await ui.find({ type: 'Text', text: /checklist/ })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /1Password/ })).toBeUndefined()
    expect((await ui.find({ type: 'Text', text: /^Decisions/ }))?.text).toBe('Decisions in this session (1)')
    await ui.unmount()
  }

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await band.find({ type: 'Text', text: /open need/ })).toBeUndefined()
  await band.unmount()
  // A line the `status` option left before a reload into this one is cleared,
  // once.
  await seen.clock.advance(30_000)
  expect(seen.statuses).toEqual([undefined])
})

test('pane: Show resolved lists the resolved need, and Resolve marks one here only, writing nothing', async ($, on) => {
  const seen = world(on)
  await $.session.start(START)

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'resolved' })
  expect((await ui.find({ type: 'Text', text: /^Resolved/ }))?.text).toBe('Resolved (1)')
  expect((await ui.find({ type: 'Text', text: /1Password/ }))?.text).toBe('Unlock 1Password')

  await ui.press({ key: `resolve:${FIXTURE_ME}:n1` })
  expect((await ui.find({ type: 'Text', text: /^Open needs/ }))?.text).toBe('Open needs (0)')
  expect((await ui.find({ type: 'Text', text: /^Resolved/ }))?.text).toBe('Resolved (2)')
  expect(seen.toasts).toEqual([
    'Mock: n1 marked resolved here only. The panel would run ledger.sh resolve n1 --session 064d2730.',
  ])
  expect(seen.runs).toEqual([])
  expect(seen.writes).toEqual([])

  await ui.press({ key: 'close' })
  expect(seen.closes).toEqual(['ledger'])
  await ui.unmount()
})

test('pane: a need resolved here keeps the time it was pressed, and lists first', async ($, on) => {
  const seen = world(on)
  await $.session.start(START)

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'resolved' })
  await ui.press({ key: `resolve:${FIXTURE_ME}:n1` })
  await ui.unmount()
  await seen.clock.advance(120_000)

  const later = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const rows = await later.findAll({ type: 'Text', text: / · resolved / })
  // n1 was recorded after n2 but resolved later, so it lists first either way;
  // its age is the press's, two minutes back, not the latest tick's.
  expect(rows.map(row => row.text)).toEqual([
    'n1 · o/r#300 · 12m · resolved 2m ago',
    'n2 · 3h · resolved 32m ago',
  ])
  await later.unmount()
})

test('status: a status line names the open need while one is open, sent once while it holds', { options: { variant: 'status' } }, async ($, on) => {
  const seen = world(on)
  await $.session.start(START)
  await seen.clock.advance(30_000)

  expect(seen.statuses).toEqual(['1 open need (/ledger-pane), newest: Do the manual check'])
})

test('band: a row counts every session\'s open needs, Open shows the pane of all of them, and Hide quiets it', { options: { variant: 'band' } }, async ($, on) => {
  const seen = world(on)
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>engine</Text>
  })
  await $.session.start(START)

  for (const surface of ['terminal', 'desktop'] as const) {
    const band = await $.ui.mount({ ...BAND, surface })
    expect((await band.find({ type: 'Text', text: /open needs/ }))?.text).toBe('2 open needs ')
    expect((await band.find({ type: 'Text', text: /^this session/ }))?.text).toBe('this session: Do the manual check')
    await band.unmount()
  }

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'open' })
  // Not Escape-closable: this pane is a sidebar, kept up.
  expect(seen.opens).toEqual([{ id: 'ledger' }])
  expect(seen.toasts).toEqual([])

  const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await pane.find({ type: 'Text', text: /^Every session/ }))?.text).toBe('Every session')
  // The other session's need shares n1's ref and is still a row of its own.
  expect((await pane.find({ type: 'Text', text: /^toolbox/ }))?.text).toBe('toolbox #295: notifier install (b55d97c7) · n1 · o/r#300 · 10h')
  expect((await pane.find({ type: 'Text', text: /^this session ·/ }))?.text).toBe('this session · n1 · o/r#300 · 10m')
  await pane.unmount()

  await band.press({ key: 'hide' })
  expect((await band.find({ type: 'Text' }))?.text).toBe('engine')
  await band.unmount()
})

test('band: Open on a pane that waits undrawn says why', { options: { variant: 'band' } }, async ($, on) => {
  const seen = world(on, { isPlaced: false })
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'open' })
  expect(seen.toasts).toEqual(['The ledger pane waits: the terminal is 80 columns'])
  await band.unmount()
})

test('band: a live ledger directory that is missing is no needs, not a failure', { options: { variant: 'band', source: 'live' } }, async ($, on) => {
  const seen = world(on, { isMissing: true })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>engine</Text>
  })
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await band.find({ type: 'Text' }))?.text).toBe('engine')
  await band.unmount()
  // Not listed at all: `fs.exists` said it isn't there.
  expect(seen.lists).toEqual([])
})

test('inline: Show expands the row into every need, Less folds it, and /ledger-pane toggles it with no pane', { options: { variant: 'inline' } }, async ($, on) => {
  const seen = world(on)
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await band.find({ type: 'Text', text: /^toolbox/ })).toBeUndefined()
  await band.press({ key: 'show' })
  expect((await band.find({ type: 'Text', text: /^toolbox/ }))?.text).toBe('toolbox #295: notifier install (b55d97c7) · n1 · o/r#300 · 10h')
  expect((await band.find({ type: 'Text', text: /^Why: PRs/ }))?.text).toBe('Why: PRs wait unseen')
  await band.press({ key: 'less' })
  expect(await band.find({ type: 'Text', text: /^toolbox/ })).toBeUndefined()

  await $.command.run(RUN)
  expect(await band.find({ type: 'Button', key: 'less' })).toBeDefined()
  await $.command.run(RUN)
  expect(await band.find({ type: 'Button', key: 'less' })).toBeUndefined()
  expect(seen.opens).toEqual([])
  await band.unmount()
})

test('inline: /ledger-pane on a hidden band brings it back expanded, not folded', { options: { variant: 'inline' } }, async ($, on) => {
  world(on)
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'show' })
  await band.press({ key: 'hide' })
  expect(await band.find({ type: 'Button', key: 'less' })).toBeUndefined()

  await $.command.run(RUN)
  expect(await band.find({ type: 'Button', key: 'less' })).toBeDefined()
  await band.unmount()
})

test('the model scopes needs, keeps needs sharing a ref apart, and lists the latest resolved first', async () => {
  const ledgers = {
    me: parseLedger(FILES[`${FIXTURE_ME}.jsonl`] ?? ''),
    other: parseLedger(FILES[`${OTHER}.jsonl`] ?? ''),
  }
  expect(ledgers.other.length).toBe(1)

  const mine = viewOf(ledgers, 'me', {}, 'session')
  expect(mine.needs.map(need => need.id)).toEqual(['n1'])
  expect(mine.resolved.map(need => need.id)).toEqual(['n2'])

  // other's n1 was recorded first and resolved last: by its resolve, it leads.
  const all = viewOf(ledgers, 'me', { other: 'install' }, 'all', {
    'other:n1': '2026-11-16T01:59:00Z',
    'me:n1': '2026-11-16T01:55:00Z',
  })
  expect(all.needs).toEqual([])
  expect(all.resolved.map(need => `${need.label} ${need.id} ${need.resolvedAt}`)).toEqual([
    'install (other) n1 2026-11-16T01:59:00Z',
    'this session n1 2026-11-16T01:55:00Z',
    'this session n2 2026-11-16T01:30:00Z',
  ])
})
