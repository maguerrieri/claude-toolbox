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
// it doesn't, plus a file that isn't a ledger. Third's n3 is its copy of
// other's n1 (the same ref), as a spawner records a child's need.
const FILES: Record<string, string> = {
  'me.jsonl': [
    line({ kind: 'decision', id: 'd1', text: 'Ship it as its own plugin', ref: '#208', at: '2026-10-27T11:00:00Z', cwd: '/r/toolbox' }),
    line({ kind: 'need', id: 'n1', text: 'Unlock 1Password', at: '2026-10-27T11:10:00Z', cwd: '/r/toolbox', resolved_at: '2026-10-27T11:20:00Z' }),
  ].join('\n'),
  'other.jsonl': [
    line({ kind: 'need', id: 'n1', text: 'PR #212 needs review\nthen say finish', ref: '#212', at: '2026-10-27T11:50:00Z', cwd: '/r/toolbox' }),
    'not json',
  ].join('\n'),
  'third.jsonl': [
    line({ kind: 'need', id: 'n2', text: 'Pick a design', at: '2026-10-27T09:00:00Z', cwd: '/r/www' }),
    line({ kind: 'need', id: 'n3', text: 'Child other: merge #212', ref: '#212', at: '2026-10-27T11:55:00Z', cwd: '/r/www' }),
  ].join('\n'),
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

// What the engine beneath the plugin saw: each command run, each toast, and
// how many times the ledger directory was listed.
type Seen = { runs: string[][]; toasts: string[]; lists: number }

// The engine beneath the plugin: the files above, the session "me", and a
// process runner that answers `claude agents`, and the script's resolve with
// a refusal when `isResolveRefused`.
function world(on: On, isResolveRefused = false): Seen & { clock: ReturnType<typeof mock.clock> } {
  const seen: Seen = { runs: [], toasts: [], lists: 0 }
  mock.env(on, { HOME })
  const clock = mock.clock(on, { now: NOW })
  on('session.id', () => ({ value: 'me' }))
  on('fs.list', () => {
    seen.lists += 1

    return {
      value: Object.entries(FILES).map(([name, text]) => ({
        name,
        kind: 'file' as const,
        size: text.length,
        mtimeMs: 1,
        isLink: false,
      })),
    }
  })
  on('fs.read', (_, e) => ({ value: FILES[e.path.slice(DIR.length + 1)] ?? '' }))
  on('process.run', (_, e) => {
    seen.runs.push([...e.argv])
    const isRefused = isResolveRefused && e.argv[0] === 'bash'
    const stdout = e.argv[0] === 'claude' ? AGENTS : ''
    const stderr = isRefused ? 'ledger resolve: the ledger has no need n1; nothing written\n' : ''

    return {
      value: { exitCode: isRefused ? 1 : 0, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false },
    }
  })
  on('ui.toast', (_, e) => {
    seen.toasts.push(e.text)

    return { value: undefined }
  })
  on('command.register', () => ({ value: { command: 'ledger-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))

  return Object.assign(seen, { clock })
}

test('the band counts the open needs and shows the newest, on each surface', async ($, on) => {
  world(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...BAND, surface })
    expect((await ui.find({ type: 'Text', text: /open needs/ }))?.text).toBe('2 open needs ')
    expect((await ui.find({ type: 'Text', text: /212/ }))?.text).toBe('toolbox #212: merge it (other): PR #212 needs review ')
    await ui.unmount()
  }
})

test('Hide quiets the band until the open needs change', async ($, on) => {
  world(on)
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

test('the pane lists every open need once and this session\'s decisions, and Resolve resolves every copy', async ($, on) => {
  const seen = world(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /^Open needs/ }))?.text).toBe('Open needs (2)')
    expect((await ui.find({ type: 'Text', text: /^toolbox/ }))?.text).toBe('toolbox #212: merge it (other) · n1 · #212 · 10m')
    expect((await ui.find({ type: 'Text', text: /^also/ }))?.text).toBe('also: www (third) n3')
    expect((await ui.find({ type: 'Text', text: /^www/ }))?.text).toBe('www (third) · n2 · 3h')
    expect((await ui.find({ type: 'Text', text: /^Decisions/ }))?.text).toBe('Decisions in this session (1)')
    expect((await ui.find({ type: 'Text', text: /^d1/ }))?.text).toBe('d1 · #208 · 1h')
    expect(await ui.find({ type: 'Text', text: /1Password/ })).toBeUndefined()
    await ui.unmount()
  }

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'resolve:other:n1' })
  const resolves = seen.runs.filter(argv => argv[0] === 'bash')
  expect(resolves.map(argv => argv.slice(2))).toEqual([
    ['resolve', 'n1', '--session', 'other'],
    ['resolve', 'n3', '--session', 'third'],
  ])
  expect(resolves[0]?.[1]?.endsWith('/scripts/ledger.sh')).toBe(true)
  expect(seen.toasts).toEqual([])
  await ui.unmount()
})

test('a Resolve the script refuses says why', async ($, on) => {
  const seen = world(on, true)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'resolve:third:n2' })
  expect(seen.toasts).toEqual([
    "Couldn't resolve www (third) n2: ledger resolve: the ledger has no need n1; nothing written",
  ])
  await ui.unmount()
})

test('a second session.start replaces the poll rather than adding one', async ($, on) => {
  const seen = world(on)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  seen.lists = 0

  await seen.clock.advance(15_000)
  expect(seen.lists).toBe(1)
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
    'toolbox #212: merge it (other) n1',
    'www (third) n2',
  ])
  expect(view.needs[0]?.also).toEqual([{ session: 'third', label: 'www (third)', id: 'n3' }])
  expect(view.decisions.map(decision => decision.id)).toEqual(['d1'])
  expect(viewOf(ledgers, 'other', {}).needs[0]?.label).toBe('this session')
  expect(parseLedger('{"kind":"need","id":"n1","text":"x\\u001b[31m","at":"t"}')[0]?.text).toBe('x\u001b[31m')
  expect(viewOf({ s: parseLedger('{"kind":"need","id":"n1","text":"x\\u001b[31m","at":"t"}') }, 'me', {}).needs[0]?.text).toBe('x?[31m')
  expect(viewOf({ s: parseLedger('{"kind":"need","id":"n1","text":"x\u009b2J","at":"t"}') }, 'me', {}).needs[0]?.text).toBe('x?2J')

  // As the script reads them: a non-string optional field skips the entry,
  // and null counts as absent (no ref; not resolved).
  const odd = parseLedger(
    [
      '{"kind":"need","id":"n1","text":"a number ref","ref":5,"at":"t"}',
      '{"kind":"need","text":"no id","at":"t"}',
      '["an", "array"]',
      '{"kind":"need","id":"n2","text":"null fields","ref":null,"cwd":null,"resolved_at":null,"at":"t"}',
    ].join('\n'),
  )
  expect(odd).toEqual([{ kind: 'need', id: 'n2', text: 'null fields', at: 't' }])
  expect(viewOf({ s: odd }, 'me', {}).needs.map(need => need.id)).toEqual(['n2'])
  expect(ageOf('2026-10-27T11:59:30Z', NOW)).toBe('now')
  expect(ageOf('2026-10-24T12:00:00Z', NOW)).toBe('3d')
  expect(ageOf('garbage', NOW)).toBe('?')
})
