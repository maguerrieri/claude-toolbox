// The ledger mod under `claude plugin test plugins/ledger`: the band and the
// pane drawn from ledger files the test serves, on each surface, and the
// model's parsing and order.
import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

import { ageOf, parseLedger, viewOf } from '../hooks/model'

const HOME = '/home/u'
const DIR = `${HOME}/.claude/session-ledger`
const NOW = Date.parse('2026-10-27T12:00:00Z')

const line = (entry: Record<string, string>): string => JSON.stringify(entry)

// Three sessions' ledgers: this one ("me"), one `claude agents` names, and one
// it doesn't, plus a file that isn't a ledger.
const FILES: Record<string, string> = {
  'me.jsonl': [
    line({ kind: 'decision', id: 'd1', text: 'Ship it as its own plugin', ref: '#208', at: '2026-10-27T11:00:00Z', cwd: '/r/toolbox' }),
    line({ kind: 'need', id: 'n1', text: 'Unlock 1Password', at: '2026-10-27T11:10:00Z', cwd: '/r/toolbox', resolved_at: '2026-10-27T11:20:00Z' }),
  ].join('\n'),
  'other.jsonl': [
    line({ kind: 'need', id: 'n1', text: 'PR #212 needs review\nthen say finish', ref: '#212', at: '2026-10-27T11:50:00Z', cwd: '/r/toolbox' }),
    'not json',
  ].join('\n'),
  'third.jsonl': line({ kind: 'need', id: 'n2', text: 'Pick a design', at: '2026-10-27T09:00:00Z', cwd: '/r/www' }),
  'notes.txt': 'ignored',
}
const AGENTS = JSON.stringify([{ id: 'other', sessionId: 'other', name: 'toolbox #212: merge it', state: 'done' }])

const BAND = {
  plugin: 'ledger',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 10,
    bodyColumns: 100,
    scroll: { offset: 0, bodyRows: 10 },
    view: {},
  },
} as const

const PANE = {
  plugin: 'ledger',
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

// The engine beneath the plugin: the files above, the session "me", and a
// process runner that records each command and answers `claude agents`.
function world(on: On, runs: string[][]): void {
  mock.env(on, { HOME })
  mock.clock(on, { now: NOW })
  on('session.id', () => ({ value: 'me' }))
  on('fs.list', () => ({
    value: Object.entries(FILES).map(([name, text]) => ({
      name,
      kind: 'file' as const,
      size: text.length,
      mtimeMs: 1,
      isLink: false,
    })),
  }))
  on('fs.read', (_, e) => ({ value: FILES[e.path.slice(DIR.length + 1)] ?? '' }))
  on('process.run', (_, e) => {
    runs.push([...e.argv])

    const stdout = e.argv[0] === 'claude' ? AGENTS : ''

    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('command.register', () => ({ value: { command: 'ledger-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
}

test('the band counts the open needs and shows the newest, on each surface', async ($, on) => {
  world(on, [])
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...BAND, surface })
    expect((await ui.find({ type: 'Text', text: /open needs/ }))?.text).toBe('2 open needs ')
    expect((await ui.find({ type: 'Text', text: /212/ }))?.text).toBe('toolbox #212: merge it: PR #212 needs review ')
    await ui.unmount()
  }
})

test('Hide quiets the band until the open needs change', async ($, on) => {
  world(on, [])
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>engine</Text>
  })
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await ui.press({ key: 'hide' })
  expect((await ui.find({ type: 'Text' }))?.text).toBe('engine')
  await ui.unmount()
})

test('the pane lists every open need and this session\'s decisions, and Resolve runs the script', async ($, on) => {
  const runs: string[][] = []
  world(on, runs)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /^Open needs/ }))?.text).toBe('Open needs (2)')
    expect((await ui.find({ type: 'Text', text: /^toolbox/ }))?.text).toBe('toolbox #212: merge it · n1 · #212 · 10m')
    expect((await ui.find({ type: 'Text', text: /^www/ }))?.text).toBe('www (third) · n2 · 3h')
    expect((await ui.find({ type: 'Text', text: /^Decisions/ }))?.text).toBe('Decisions in this session (1)')
    expect((await ui.find({ type: 'Text', text: /^d1/ }))?.text).toBe('d1 · #208 · 1h')
    expect(await ui.find({ type: 'Text', text: /1Password/ })).toBeUndefined()
    await ui.unmount()
  }

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'resolve:other:n1' })
  const resolve = runs.find(argv => argv[0] === 'bash')
  expect(resolve?.slice(2)).toEqual(['resolve', 'n1', '--session', 'other'])
  expect(resolve?.[1]?.endsWith('/scripts/ledger.sh')).toBe(true)
  await ui.unmount()
})

test('the model skips lines that are not entries and orders newest first', async () => {
  const ledgers = Object.fromEntries(
    Object.entries(FILES)
      .filter(([name]) => name.endsWith('.jsonl'))
      .map(([name, text]) => [name.slice(0, -'.jsonl'.length), parseLedger(text)]),
  )
  expect(ledgers.other?.length).toBe(1)

  const view = viewOf(ledgers, 'me', { other: 'toolbox #212: merge it' })
  expect(view.needs.map(need => `${need.label} ${need.id}`)).toEqual([
    'toolbox #212: merge it n1',
    'www (third) n2',
  ])
  expect(view.decisions.map(decision => decision.id)).toEqual(['d1'])
  expect(viewOf(ledgers, 'other', {}).needs[0]?.label).toBe('this session')
  expect(parseLedger('{"kind":"need","id":"n1","text":"x\\u001b[31m","at":"t"}')[0]?.text).toBe('x\u001b[31m')
  expect(viewOf({ s: parseLedger('{"kind":"need","id":"n1","text":"x\\u001b[31m","at":"t"}') }, 'me', {}).needs[0]?.text).toBe('x?[31m')
  expect(ageOf('2026-10-27T11:59:30Z', NOW)).toBe('now')
  expect(ageOf('2026-10-24T12:00:00Z', NOW)).toBe('3d')
  expect(ageOf('garbage', NOW)).toBe('?')
})
