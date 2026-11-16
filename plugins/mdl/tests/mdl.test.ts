import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

// Test-only presets. They stand for whatever a person puts in /config; none of
// them is a default the plugin ships.
const CONFIGURED = {
  bigModel: 'fable',
  bigEffort: 'medium',
  mediumModel: 'opus',
  mediumEffort: 'xhigh',
  smallModel: 'sonnet',
  smallEffort: 'max',
}

type World = {
  model: string
  // What the engine's /model does with an argument: switch, or refuse.
  accepts: (model: string) => boolean
  runs: { command: string; args: string }[]
  logs: string[]
}

// The engine beneath the plugin: /model and /effort as the session runs them,
// the session's model, the /config model row, and the transcript's log lines.
function engine(on: On, start: string, accepts: (model: string) => boolean = () => true) {
  const world: World = { model: start, accepts, runs: [], logs: [] }
  const ids: Record<string, string> = {
    fable: 'claude-fable-5-2',
    opus: 'claude-opus-5-5',
    sonnet: 'claude-sonnet-5-5',
  }
  let row = start
  on('command.register', (_, e) => ({ value: { command: e.name } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.model', () => ({ value: world.model }))
  on('config.list', () => ({
    value: [
      {
        key: 'model',
        label: 'Model',
        kind: 'choice',
        value: row,
        provider: { plugin: 'engine', tier: 'core' },
        isLocked: false,
      },
    ],
  }))
  on('command.run', (_, e) => {
    world.runs.push({ command: e.command, args: e.args })
    if (e.command === 'model' && world.accepts(e.args)) {
      world.model = ids[e.args] ?? e.args
      row = e.args
    }
    return {}
  })
  on('ui.log', (_, e) => {
    world.logs.push(e.text)
    return { value: undefined }
  })

  return world
}

async function start($: Engine) {
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
}

// /mdl as the person types it at the prompt: a bare /mdl reaches the hook as "".
function mdl($: Engine, args: string) {
  return $.command.run({
    command: 'mdl',
    args,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 80 },
  })
}

test('/mdl big runs /model, then /effort, after answering', { options: CONFIGURED }, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine(on, 'claude-opus-5-5')
  await start($)

  const { text } = await mdl($, 'big')
  expect(text).toContain('fable at medium effort')
  // Nothing has run yet: the hook can't run a command while it holds /mdl.
  expect(world.runs).toEqual([])

  await clock.settle()
  expect(world.runs).toEqual([
    { command: 'model', args: 'fable' },
    { command: 'effort', args: 'medium' },
  ])
  expect(world.model).toBe('claude-fable-5-2')
  expect(world.logs).toEqual([])
})

test('each size runs its own preset', { options: CONFIGURED }, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine(on, 'claude-haiku-5-5')
  await start($)

  for (const [size, model, effort] of [
    ['big', 'fable', 'medium'],
    ['medium', 'opus', 'xhigh'],
    ['small', 'sonnet', 'max'],
  ] as const) {
    world.runs.length = 0
    await mdl($, size)
    await clock.settle()
    expect(world.runs).toEqual([
      { command: 'model', args: model },
      { command: 'effort', args: effort },
    ])
  }
})

test('the size is read in any case, and the effort goes in lower case', {
  options: { ...CONFIGURED, smallEffort: 'XHigh' },
}, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine(on, 'claude-opus-5-5')
  await start($)

  await mdl($, '  Small ')
  await clock.settle()
  expect(world.runs).toEqual([
    { command: 'model', args: 'sonnet' },
    { command: 'effort', args: 'xhigh' },
  ])
})

test('no size lists the three and the current model, and changes nothing', {
  options: { bigModel: 'fable', bigEffort: 'medium' },
}, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine(on, 'claude-opus-5-5')
  await start($)

  const { text } = await mdl($, '')
  expect(text).toContain('Usage: /mdl big|medium|small')
  expect(text).toContain('claude-opus-5-5')
  expect(text).toContain('fable at medium effort')
  expect(text).toMatch(/medium\s+not set/)
  expect(text).toMatch(/small\s+not set/)

  await clock.settle()
  expect(world.runs).toEqual([])
})

test('an unknown size says so, lists the sizes, and changes nothing', { options: CONFIGURED }, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine(on, 'claude-opus-5-5')
  await start($)

  const { text } = await mdl($, 'huge')
  expect(text).toContain(`"huge" isn't a size`)
  expect(text).toContain('Usage: /mdl big|medium|small')

  await clock.settle()
  expect(world.runs).toEqual([])
})

test('an unset size says what to set, and changes nothing', async ($, on) => {
  const clock = mock.clock(on)
  const world = engine(on, 'claude-opus-5-5')
  await start($)

  const { text } = await mdl($, 'medium')
  expect(text).toContain(`/mdl medium isn't configured`)
  expect(text).toContain('mdl.mediumModel and mdl.mediumEffort')

  await clock.settle()
  expect(world.runs).toEqual([])
})

test('a size with only its model set names the missing effort', {
  options: { smallModel: 'sonnet' },
}, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine(on, 'claude-opus-5-5')
  await start($)

  const { text } = await mdl($, 'small')
  expect(text).toContain('set mdl.smallEffort in /config')

  await clock.settle()
  expect(world.runs).toEqual([])
})

test('an unknown effort level is reported, and nothing changes', {
  options: { ...CONFIGURED, bigEffort: 'turbo' },
}, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine(on, 'claude-opus-5-5')
  await start($)

  const { text } = await mdl($, 'big')
  expect(text).toContain(`"turbo" isn't an effort level`)
  expect(text).toContain('mdl.bigEffort')

  await clock.settle()
  expect(world.runs).toEqual([])
})

test('a model /model refuses leaves the effort alone, and says so', {
  options: { ...CONFIGURED, bigModel: 'fabel' },
}, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine(on, 'claude-opus-5-5', model => model !== 'fabel')
  await start($)

  await mdl($, 'big')
  await clock.settle()
  expect(world.runs).toEqual([{ command: 'model', args: 'fabel' }])
  expect(world.model).toBe('claude-opus-5-5')
  expect(world.logs).toEqual([
    `/mdl big: /model didn't switch to fabel (its message is above), so the effort was left as it was.`,
  ])
})

test('a preset whose model is already in use still sets the effort', { options: CONFIGURED }, async ($, on) => {
  const clock = mock.clock(on)
  // Already on Opus, by its /config alias: /model opus changes nothing.
  const world = engine(on, 'claude-opus-5-5')
  await start($)

  await mdl($, 'medium')
  await clock.settle()
  expect(world.runs).toEqual([
    { command: 'model', args: 'opus' },
    { command: 'effort', args: 'xhigh' },
  ])
  expect(world.logs).toEqual([])
})
