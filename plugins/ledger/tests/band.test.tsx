// The band under `claude plugin test plugins/ledger`: what it draws from this
// session's ledger, its toggle, Resolve through the script, and that it never
// reads or writes another session's ledger.
import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

import { isResolvable, parseLedger, viewOf } from '../hooks/model'

const NOW = Date.parse('2026-11-16T02:00:00Z')
const ME = '064d2730-a02f-402d-a56b-b51e807c396e'
const OTHER = 'b55d97c7-d2d7-4968-92fc-11bf386f1ac9'
const DIR = '/home/u/.claude/session-ledger'
const MINE = `${DIR}/${ME}.jsonl`
const THEIRS = `${DIR}/${OTHER}.jsonl`

const line = (entry: Record<string, string>): string => JSON.stringify(entry)

// This session's ledger: a decision, two open needs that share a ref (two
// rows, never one), a resolved need and a line that isn't an entry. Another
// session's ledger beside it has an open need the band must never show.
const LEDGER = [
  line({ kind: 'decision', id: 'd1', why: 'status answers get rebuilt', text: 'Ship the per-session ledger first', ref: 'o/r#208', at: '2026-11-16T01:00:00Z' }),
  line({ kind: 'need', id: 'n1', why: 'status answers get rebuilt', text: 'Do the manual check\nthen resolve it', ref: 'o/r#300', at: '2026-11-16T01:50:00Z' }),
  line({ kind: 'need', id: 'n2', text: 'Unlock 1Password', at: '2026-11-15T23:00:00Z', resolved_at: '2026-11-16T01:30:00Z' }),
  line({ kind: 'need', id: 'n3', text: 'Review PR #300', ref: 'o/r#300', at: '2026-11-16T00:30:00Z' }),
  'not json',
].join('\n')
// The same ledger once the session has resolved n1.
const RESOLVED_N1 = LEDGER.replace(
  '"at":"2026-11-16T01:50:00Z"}',
  '"at":"2026-11-16T01:50:00Z","resolved_at":"2026-11-16T01:55:00Z"}',
)
const FILES: Record<string, string> = {
  [MINE]: LEDGER,
  [THEIRS]: line({ kind: 'need', id: 'n1', why: 'PRs wait unseen', text: 'Run the PR #300 checklist', ref: 'o/r#300', at: '2026-11-15T16:00:00Z' }),
}

const BAND = {
  plugin: 'ledger',
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

// What the engine beneath the band saw, and the knobs a test turns.
type World = {
  /** This session's id, which a test changes to stand for a /clear. */
  session: { id: string }
  /** The ledger files by path; `write` changes one as the script would. */
  files: Record<string, string>
  write: (path: string, text: string) => void
  /**
   * Set to make every read fail, or the directory unsearchable (as the engine
   * answers one: `exists` false, `stat` failing EACCES), or Resolve fail.
   */
  fault: { isReadFailing: boolean; isDirLocked: boolean; resolveError?: string }
  stats: string[]
  reads: string[]
  lists: string[]
  writes: string[]
  runs: { argv: string[]; cwd?: string; env?: Record<string, string> }[]
  toasts: string[]
  opens: string[]
  clock: ReturnType<typeof mock.clock>
}

// The engine beneath the band: the ledger files served by path, each with an
// mtime that moves when `write` changes it, directories by the path where
// each lands (<dirs>), and a `ledger.sh resolve` that stamps the need in the
// ledger of the session its environment names.
function world(
  on: On,
  {
    files = FILES,
    env = { HOME: '/home/u' } as Record<string, string>,
    dirs = {} as Record<string, string>,
  } = {},
): World {
  const clock = mock.clock(on, { now: NOW })
  const mtimes: Record<string, number> = {}
  const seen: World = {
    session: { id: ME },
    files: { ...files },
    write: (path, text) => {
      seen.files[path] = text
      mtimes[path] = (mtimes[path] ?? 1) + 1
    },
    fault: { isReadFailing: false, isDirLocked: false },
    stats: [],
    reads: [],
    lists: [],
    writes: [],
    runs: [],
    toasts: [],
    opens: [],
    clock,
  }
  // A hook gets a relative path made absolute, against the working directory
  // (the plugin's folder under `claude plugin test`), so a relative key
  // matches the path it ends.
  const at = (map: Record<string, unknown>, path: string): string =>
    Object.keys(map).find(key => key === path || (!key.startsWith('/') && path.endsWith(`/${key}`))) ?? path
  mock.env(on, env)
  on('session.id', () => ({ value: seen.session.id }))
  on('fs.exists', (_, e) => ({ value: !seen.fault.isDirLocked && at(seen.files, e.path) in seen.files }))
  // Refused with the OS's code, as the engine's rejection carries it
  // (checked on 2.1.325: `$.fs.stat(<path>) failed: ENOENT`).
  on('fs.stat', (_, e) => {
    seen.stats.push(e.path)
    const file = at(seen.files, e.path)
    const text = seen.files[file]
    if (seen.fault.isDirLocked) {
      return { deny: 'EACCES' }
    }
    const realPath = dirs[at(dirs, e.path)]
    if (realPath !== undefined) {
      return { value: { kind: 'dir' as const, size: 0, mtimeMs: 1, isLink: false, ...(e.resolve ? { realPath } : {}) } }
    }
    if (text === undefined) {
      return { deny: 'ENOENT' }
    }

    return { value: { kind: 'file' as const, size: text.length, mtimeMs: mtimes[file] ?? 1, isLink: false } }
  })
  on('fs.read', (_, e) => {
    seen.reads.push(e.path)
    if (seen.fault.isReadFailing) {
      return { deny: 'EACCES' }
    }

    return { value: seen.files[at(seen.files, e.path)] ?? '' }
  })
  on('fs.list', (_, e) => {
    seen.lists.push(e.path ?? '.')

    return { value: [] }
  })
  on('fs.write', (_, e) => {
    seen.writes.push(e.path)

    return { value: undefined }
  })
  on('process.run', (_, e) => {
    const { cwd, env } = e.init ?? {}
    seen.runs.push({
      argv: [...e.argv],
      ...(cwd === undefined ? {} : { cwd }),
      ...(env === undefined ? {} : { env: { ...env } }),
    })
    if (seen.fault.resolveError !== undefined) {
      return { value: { exitCode: 1, stdout: '', stderr: seen.fault.resolveError, isStdoutTruncated: false, isStderrTruncated: false } }
    }
    const [, , subcommand, id] = e.argv
    const path = `${env?.CLAUDE_SESSION_LEDGER_DIR ?? DIR}/${env?.CLAUDE_CODE_SESSION_ID ?? ''}.jsonl`
    if (subcommand === 'resolve' && path in seen.files) {
      seen.write(
        path,
        (seen.files[path] ?? '')
          .split('\n')
          .map(text => {
            const entry = parseLedger(text)[0]
            return entry?.kind === 'need' && entry.id === id && entry.resolved_at === undefined
              ? JSON.stringify({ ...JSON.parse(text), resolved_at: new Date(NOW).toISOString() })
              : text
          })
          .join('\n'),
      )
    }

    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.toast', (_, e) => {
    seen.toasts.push(e.text)

    return { value: undefined }
  })
  on('ui.open', (_, e) => {
    seen.opens.push(e.id)

    return { value: { isPlaced: true } }
  })
  on('command.register', () => ({ value: { command: 'ledger-band' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
  // What the engine draws in the band's place when the band draws nothing.
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>engine</Text>
  })

  return seen
}

const START = { cwd: '/', surface: 'terminal', isInteractive: true } as const
// The person typing /ledger-band, or a keybinding to command:ledger-band.
const RUN = {
  command: 'ledger-band',
  args: '',
  origin: { kind: 'composer' },
  presentation: { isFullscreen: true, columns: 160 },
} as const

test('the band counts this session\'s open needs and shows the newest, reading no other ledger, on each surface', async ($, on) => {
  const seen = world(on)
  await $.session.start(START)

  for (const surface of ['terminal', 'desktop'] as const) {
    const band = await $.ui.mount({ ...BAND, surface })
    expect((await band.find({ type: 'Text', text: /open need/ }))?.text).toBe('2 open needs ')
    expect((await band.find({ type: 'Text', text: /^Do the/ }))?.text).toBe('Do the manual check')
    expect(await band.find({ type: 'Text', text: /checklist/ })).toBeUndefined()
    await band.unmount()
  }

  await seen.clock.advance(30_000)
  expect([...new Set(seen.stats)]).toEqual([MINE])
  expect([...new Set(seen.reads)]).toEqual([MINE])
  expect(seen.lists).toEqual([])
  expect(seen.writes).toEqual([])
})

test('Show expands it in place into each open need, Less folds it, and /ledger-band toggles it with no pane', async ($, on) => {
  const seen = world(on)
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await band.find({ type: 'Text', text: /^n1 ·/ })).toBeUndefined()
  await band.press({ key: 'show' })
  const rows = await band.findAll({ type: 'Text', text: /^n\d ·/ })
  // Newest first, and the two needs that share a ref are two rows.
  expect(rows.map(row => row.text)).toEqual(['n1 · o/r#300 · 10m', 'n3 · o/r#300 · 1h'])
  expect((await band.find({ type: 'Text', text: /^Why:/ }))?.text).toBe('Why: status answers get rebuilt')
  expect((await band.find({ type: 'Text', text: /^Review/ }))?.text).toBe('Review PR #300')
  expect(await band.find({ type: 'Text', text: /1Password/ })).toBeUndefined()
  expect(await band.find({ type: 'Text', text: /Ship the/ })).toBeUndefined()
  await band.press({ key: 'less' })
  expect(await band.find({ type: 'Text', text: /^n1 ·/ })).toBeUndefined()

  expect(await $.command.run(RUN)).toEqual({})
  expect(await band.find({ type: 'Button', key: 'less' })).toBeDefined()
  await $.command.run(RUN)
  expect(await band.find({ type: 'Button', key: 'less' })).toBeUndefined()
  expect(seen.opens).toEqual([])
  await band.unmount()
})

test('with no ledger yet the band stays out of the way, and /ledger-band says so', async ($, on) => {
  world(on, { files: {} })
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await band.find({ type: 'Text' }))?.text).toBe('engine')
  expect((await $.command.run(RUN)).text).toBe('This session needs nothing from you.')
  expect((await band.find({ type: 'Text' }))?.text).toBe('engine')
  await band.unmount()
})

test('the band yields to a survey', async ($, on) => {
  world(on)
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, props: { ...BAND.props, hasSurvey: true }, surface: 'terminal' })
  expect((await band.find({ type: 'Text' }))?.text).toBe('engine')
  await band.unmount()
})

test('Hide quiets the band until a need it didn\'t show opens, a resolve included, and it comes back folded', async ($, on) => {
  const seen = world(on)
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'show' })
  await band.press({ key: 'hide' })
  expect((await band.find({ type: 'Text' }))?.text).toBe('engine')
  await seen.clock.advance(15_000)
  expect((await band.find({ type: 'Text' }))?.text).toBe('engine')

  // The session resolves n1: still nothing the owner hasn't seen.
  seen.write(MINE, RESOLVED_N1)
  await seen.clock.advance(15_000)
  expect((await band.find({ type: 'Text' }))?.text).toBe('engine')

  seen.write(MINE, `${RESOLVED_N1}\n${line({ kind: 'need', id: 'n4', text: 'A new need', at: '2026-11-16T01:59:00Z' })}`)
  await seen.clock.advance(15_000)
  expect((await band.find({ type: 'Text', text: /open need/ }))?.text).toBe('2 open needs ')
  expect(await band.find({ type: 'Button', key: 'show' })).toBeDefined()
  expect(await band.find({ type: 'Button', key: 'less' })).toBeUndefined()
  await band.unmount()
})

test('a band expanded when its last need goes comes back folded with the next one', async ($, on) => {
  const seen = world(on)
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'show' })
  await band.press({ key: `resolve:${ME}:n1` })
  await band.press({ key: `resolve:${ME}:n3` })
  expect((await band.find({ type: 'Text' }))?.text).toBe('engine')

  seen.write(MINE, `${seen.files[MINE] ?? ''}\n${line({ kind: 'need', id: 'n4', text: 'A new need', at: '2026-11-16T01:59:00Z' })}`)
  await seen.clock.advance(15_000)
  expect((await band.find({ type: 'Text', text: /open need/ }))?.text).toBe('1 open need ')
  expect(await band.find({ type: 'Button', key: 'show' })).toBeDefined()
  expect(await band.find({ type: 'Button', key: 'less' })).toBeUndefined()
  await band.unmount()
})

test('/ledger-band on a hidden band brings it back expanded, not folded', async ($, on) => {
  world(on)
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'hide' })
  await $.command.run(RUN)
  expect(await band.find({ type: 'Button', key: 'less' })).toBeDefined()
  await band.unmount()
})

test('Resolve runs ledger.sh resolve as this session, and the need leaves the band', async ($, on) => {
  const seen = world(on)
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'show' })
  await band.press({ key: `resolve:${ME}:n1` })
  expect(seen.runs.length).toBe(1)
  const [run] = seen.runs
  expect(run?.argv.slice(0, 1)).toEqual(['bash'])
  expect(run?.argv[1]).toEndWith('/scripts/ledger.sh')
  expect(run?.argv.slice(2)).toEqual(['resolve', 'n1'])
  // As this session, in the directory the band read.
  expect(run?.env).toEqual({ CLAUDE_CODE_SESSION_ID: ME, CLAUDE_SESSION_LEDGER_DIR: DIR })
  // In the plugin's folder, which is there even when the session's isn't.
  expect(run?.cwd).toBe(run?.argv[1]?.slice(0, -'/scripts/ledger.sh'.length))
  expect(seen.toasts).toEqual([])
  expect((await band.find({ type: 'Text', text: /open need/ }))?.text).toBe('1 open need ')
  expect((await band.findAll({ type: 'Text', text: /^n\d ·/ })).map(row => row.text)).toEqual(['n3 · o/r#300 · 1h'])
  // Nothing but the script wrote, and nothing read the other session's ledger.
  expect(seen.writes).toEqual([])
  expect(seen.reads.filter(path => path !== MINE)).toEqual([])
  await band.unmount()
})

test('a Resolve the script refuses says why, and the need stays', async ($, on) => {
  const seen = world(on)
  seen.fault.resolveError = 'ledger resolve: another write held the ledger for 10 seconds; nothing written\n'
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'show' })
  await band.press({ key: `resolve:${ME}:n1` })
  expect(seen.toasts).toEqual(["Couldn't resolve n1: another write held the ledger for 10 seconds; nothing written"])
  expect((await band.find({ type: 'Text', text: /open need/ }))?.text).toBe('2 open needs ')
  await band.unmount()
})

test('after a /clear, a need the band still shows is not resolved as the new session', async ($, on) => {
  const seen = world(on)
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'show' })
  seen.session.id = 'f00dcafe-0000-4000-8000-000000000000'
  await band.press({ key: `resolve:${ME}:n1` })
  expect(seen.runs).toEqual([])
  expect(seen.toasts).toEqual(["Didn't resolve n1: it is an earlier session's need, not this one's."])
  // The new session has no ledger yet, so the band has nothing to show.
  expect((await band.find({ type: 'Text' }))?.text).toBe('engine')
  await band.unmount()
})

test('a need recorded during a turn shows as the turn ends, before the next tick', async ($, on) => {
  const seen = world(on)
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  seen.write(MINE, `${LEDGER}\n${line({ kind: 'need', id: 'n4', text: 'Review PR #301', at: '2026-11-16T02:00:00Z' })}`)
  await $.turn.complete({ answer: 'Done.', durationMs: 1_000, isAborted: false, turnId: 't1', reason: 'answer' })
  expect((await band.find({ type: 'Text', text: /open need/ }))?.text).toBe('3 open needs ')
  expect((await band.find({ type: 'Text', text: /^Review/ }))?.text).toBe('Review PR #301')
  await band.unmount()
})

test('a read that fails keeps what the band last showed', async ($, on) => {
  const seen = world(on)
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  seen.fault.isReadFailing = true
  seen.write(MINE, '')
  await seen.clock.advance(15_000)
  expect((await band.find({ type: 'Text', text: /open need/ }))?.text).toBe('2 open needs ')
  await band.unmount()
})

test('a ledger directory it can\'t search is a failed read, not a missing ledger', async ($, on) => {
  const seen = world(on)
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  seen.fault.isDirLocked = true
  await seen.clock.advance(15_000)
  expect((await band.find({ type: 'Text', text: /open need/ }))?.text).toBe('2 open needs ')
  expect(await $.command.run(RUN)).toEqual({})
  await band.unmount()
})

test('the ages it shows move on with the clock while it stays expanded', async ($, on) => {
  const seen = world(on)
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'show' })
  expect((await band.find({ type: 'Text', text: /^n1 ·/ }))?.text).toBe('n1 · o/r#300 · 10m')
  await seen.clock.advance(120_000)
  expect((await band.find({ type: 'Text', text: /^n1 ·/ }))?.text).toBe('n1 · o/r#300 · 12m')
  await band.unmount()
})

test('CLAUDE_SESSION_LEDGER_DIR names the directory it reads', async ($, on) => {
  const elsewhere = `/tmp/ledgers/${ME}.jsonl`
  const seen = world(on, { files: { [elsewhere]: LEDGER }, env: { HOME: '/home/u', CLAUDE_SESSION_LEDGER_DIR: '/tmp/ledgers' } })
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await band.find({ type: 'Text', text: /open need/ }))?.text).toBe('2 open needs ')
  expect([...new Set(seen.reads)]).toEqual([elsewhere])
  await band.unmount()
})

test('a relative CLAUDE_SESSION_LEDGER_DIR reaches the script as the absolute directory the band read', async ($, on) => {
  // The script runs in the plugin's folder, not the session's, so it gets
  // the directory where the band's relative one lands.
  const seen = world(on, {
    files: { [`ledgers/${ME}.jsonl`]: LEDGER },
    env: { HOME: '/home/u', CLAUDE_SESSION_LEDGER_DIR: 'ledgers' },
    dirs: { ledgers: '/work/repo/ledgers' },
  })
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'show' })
  await band.press({ key: `resolve:${ME}:n1` })
  expect(seen.runs.map(run => run.env)).toEqual([
    { CLAUDE_CODE_SESSION_ID: ME, CLAUDE_SESSION_LEDGER_DIR: '/work/repo/ledgers' },
  ])
  await band.unmount()
})

test('each row hands the engine no more than the band\'s width of a long need', async ($, on) => {
  world(on, {
    files: { [MINE]: line({ kind: 'need', id: 'n1', why: 'w'.repeat(200), text: 'x'.repeat(4000), at: '2026-11-16T01:00:00Z' }) },
  })
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await band.find({ type: 'Text', text: /^x+$/ }))?.text.length).toBe(BAND.props.bodyColumns)
  await band.press({ key: 'show' })
  expect((await band.find({ type: 'Text', text: /^x+$/ }))?.text.length).toBe(BAND.props.bodyColumns)
  expect((await band.find({ type: 'Text', text: /^Why: w+$/ }))?.text.length).toBe(BAND.props.bodyColumns)
  await band.unmount()
})

test('a need whose id the script would refuse has no Resolve button', async ($, on) => {
  world(on, { files: { [MINE]: line({ kind: 'need', id: 'n1.5', text: 'Hand-edited', at: '2026-11-16T01:00:00Z' }) } })
  await $.session.start(START)

  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'show' })
  expect((await band.find({ type: 'Text', text: /^n1\.5 ·/ }))?.text).toBe('n1.5 · 1h')
  expect(await band.find({ type: 'Button', key: `resolve:${ME}:n1.5` })).toBeUndefined()
  await band.unmount()
})

test('the model shows as ? the characters the script does, ids included', async () => {
  const ledgers = {
    me: parseLedger(
      line({ kind: 'need', id: 'n1\u0007', why: 'a‮goal', text: 'Read​ this\u{e0041}', at: '2026-11-16T01:00:00Z' }),
    ),
  }
  const [need] = viewOf(ledgers).needs
  expect([need?.id, need?.why, need?.text, need?.key]).toEqual(['n1?', 'a?goal', 'Read? this?', 'me:n1\u0007'])
})

test('the model keeps a hand-edited id or ref to one line, and gives two needs of one id their own keys', async () => {
  const { needs } = viewOf({
    me: parseLedger(
      [
        line({ kind: 'need', id: 'n1', text: 'First', ref: 'o/r#1\nINJECTED', at: '2026-11-16T01:00:00Z' }),
        line({ kind: 'need', id: 'n1', text: 'Second', at: '2026-11-16T00:00:00Z' }),
        line({ kind: 'need', id: 'n\n2', text: 'Third', at: '2026-11-15T00:00:00Z' }),
      ].join('\n'),
    ),
  })
  expect(needs.map(need => [need.key, need.id, need.ref])).toEqual([
    ['me:n1', 'n1', 'o/r#1 INJECTED'],
    ['me:n1#2', 'n1', undefined],
    ['me:n\n2', 'n 2', undefined],
  ])
})

test('the model lists open needs alone, newest first, and takes only the ids the script does', async () => {
  const { needs } = viewOf({ me: parseLedger(LEDGER) })
  expect(needs.map(need => need.key)).toEqual(['me:n1', 'me:n3'])
  expect(['n1', 'n12', 'n0', 'n01', 'd1', 'n1.5', 'n1234567890'].map(isResolvable)).toEqual([
    true,
    true,
    false,
    false,
    false,
    false,
    false,
  ])
})
