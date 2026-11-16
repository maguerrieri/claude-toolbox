import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

import { alreadyOn } from '../hooks/register'

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

// What the aliases resolve to in this stand-in engine.
const IDS: Record<string, string> = {
  default: 'claude-opus-5-5',
  fable: 'claude-fable-5-2',
  opus: 'claude-opus-5-5',
  'opus[1m]': 'claude-opus-5-5',
  sonnet: 'claude-sonnet-5-5',
}

type World = {
  model: string
  // The model setting, as /model saves it: undefined for `default`.
  setting: string | undefined
  runs: { command: string; args: string }[]
  logs: string[]
}

type Behavior = {
  // The model setting the session starts with.
  setting?: string
  // Whether the engine's /model takes a name; a refused one changes nothing.
  accepts?: (model: string) => boolean
  // A command whose run fails before it runs, as past a Stop.
  fails?: string
}

// The engine beneath the plugin: /model and /effort as the session runs them
// (/model saves what it takes; a real switch raises PostModelSwitch, a no-op
// or a refusal none), the session's model, its settings, and the transcript's
// log lines.
function engine($: Engine, on: On, start: string, behavior: Behavior = {}) {
  const world: World = { model: start, setting: behavior.setting, runs: [], logs: [] }
  const accepts = behavior.accepts ?? (() => true)
  on('command.register', (_, e) => ({ value: { command: e.name } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.model', () => ({ value: world.model }))
  on('settings.read', () => ({ value: world.setting === undefined ? {} : { model: world.setting } }))
  on('command.run', async (_, e) => {
    if (e.command === behavior.fails) throw new Error(`/${e.command} could not run`)
    world.runs.push({ command: e.command, args: e.args })
    if (e.command === 'model' && accepts(e.args)) {
      world.setting = e.args.toLowerCase() === 'default' ? undefined : e.args
      const to = IDS[e.args.toLowerCase()] ?? e.args
      if (to !== world.model) {
        const from = world.model
        world.model = to
        await $.classic.PostModelSwitch({
          from_model: from,
          to_model: to,
          requested_model: e.args.toLowerCase() === 'default' ? null : e.args,
          source: 'command',
          context_tokens: 0,
          prompt_cache_warm: false,
          cache_ttl: '5m',
          estimated_cache_write_usd: 0,
          pricing: 'catalog',
        })
      }
    }

    return {}
  })
  on('ui.log', (_, e) => {
    world.logs.push(e.text)
    return { value: undefined }
  })
  on('classic.PostModelSwitch', () => ({}))

  return world
}

async function start($: Engine) {
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
}

// A command as the person types it at the prompt: a bare /mdl reaches the hook
// as "".
function typed($: Engine, command: string, args: string) {
  return $.command.run({
    command,
    args,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 80 },
  })
}

function mdl($: Engine, args: string) {
  return typed($, 'mdl', args)
}

test('/mdl big answers, then runs /model and /effort', { options: CONFIGURED }, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine($, on, 'claude-opus-5-5')
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
  const world = engine($, on, 'claude-haiku-5-5')
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

test('two /mdl in a row each run their own pair, in order', { options: CONFIGURED }, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine($, on, 'claude-opus-5-5')
  await start($)

  await mdl($, 'small')
  await mdl($, 'big')
  await clock.settle()
  expect(world.runs).toEqual([
    { command: 'model', args: 'sonnet' },
    { command: 'effort', args: 'max' },
    { command: 'model', args: 'fable' },
    { command: 'effort', args: 'medium' },
  ])
  expect(world.model).toBe('claude-fable-5-2')
})

test('the size is read in any case, and the effort goes in lower case', {
  options: { ...CONFIGURED, smallEffort: 'XHigh' },
}, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine($, on, 'claude-opus-5-5')
  await start($)

  await mdl($, '  Small ')
  await clock.settle()
  expect(world.runs).toEqual([
    { command: 'model', args: 'sonnet' },
    { command: 'effort', args: 'xhigh' },
  ])
})

test('no size lists the three and the current model, and changes nothing', {
  options: { bigModel: 'fable', bigEffort: 'medium', smallModel: 'sonnet', smallEffort: 'turbo' },
}, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine($, on, 'claude-opus-5-5')
  await start($)

  const { text } = await mdl($, '')
  expect(text).toContain('Usage: /mdl big|medium|small')
  expect(text).toContain('claude-opus-5-5')
  expect(text).toContain('fable at medium effort')
  expect(text).toMatch(/medium\s+not set/)
  expect(text).toMatch(/small\s+its effort is not a level/)

  await clock.settle()
  expect(world.runs).toEqual([])
})

test('an unknown size says so, lists the sizes, and changes nothing', { options: CONFIGURED }, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine($, on, 'claude-opus-5-5')
  await start($)

  const { text } = await mdl($, 'huge')
  expect(text).toContain(`"huge" isn't a size`)
  expect(text).toContain('Usage: /mdl big|medium|small')

  await clock.settle()
  expect(world.runs).toEqual([])
})

test('an unset size says what to set, and changes nothing', async ($, on) => {
  const clock = mock.clock(on)
  const world = engine($, on, 'claude-opus-5-5')
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
  const world = engine($, on, 'claude-opus-5-5')
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
  const world = engine($, on, 'claude-opus-5-5')
  await start($)

  const { text } = await mdl($, 'big')
  expect(text).toContain(`"turbo" isn't an effort level`)
  expect(text).toContain('mdl.bigEffort')

  await clock.settle()
  expect(world.runs).toEqual([])
})

test('a model /model refuses holds the effort back', {
  options: { ...CONFIGURED, bigModel: 'fabel' },
}, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine($, on, 'claude-opus-5-5', { accepts: model => model !== 'fabel' })
  await start($)

  await mdl($, 'big')
  await clock.settle()
  expect(world.runs).toEqual([{ command: 'model', args: 'fabel' }])
  expect(world.model).toBe('claude-opus-5-5')
  expect(world.logs).toEqual([
    `/mdl big: the model didn't switch to fabel, so the effort was left as it was.`,
  ])
})

test('a refused model holds the effort back even when it is the saved default', {
  options: CONFIGURED,
}, async ($, on) => {
  const clock = mock.clock(on)
  // On Sonnet (say, started with --model sonnet), and /model opus is refused.
  const world = engine($, on, 'claude-sonnet-5-5', {
    setting: 'opus',
    accepts: model => model !== 'opus',
  })
  await start($)

  await mdl($, 'medium')
  await clock.settle()
  expect(world.runs).toEqual([{ command: 'model', args: 'opus' }])
  expect(world.model).toBe('claude-sonnet-5-5')
  expect(world.logs).toHaveLength(1)
})

test('a preset whose model is already in use still sets the effort', { options: CONFIGURED }, async ($, on) => {
  const clock = mock.clock(on)
  // Already on Opus: /model opus changes nothing and raises no switch.
  const world = engine($, on, 'claude-opus-5-5')
  await start($)

  await mdl($, 'medium')
  await clock.settle()
  expect(world.runs).toEqual([
    { command: 'model', args: 'opus' },
    { command: 'effort', args: 'xhigh' },
  ])
})

test('a preset of the default model sets the effort once /model switches', {
  options: { ...CONFIGURED, smallModel: 'default', smallEffort: 'low' },
}, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine($, on, 'claude-sonnet-5-5')
  await start($)

  await mdl($, 'small')
  await clock.settle()
  expect(world.runs).toEqual([
    { command: 'model', args: 'default' },
    { command: 'effort', args: 'low' },
  ])
  expect(world.model).toBe('claude-opus-5-5')
})

test('a run that fails says so in the transcript', {
  options: CONFIGURED,
}, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine($, on, 'claude-opus-5-5', { fails: 'model' })
  await start($)

  await mdl($, 'small')
  await clock.settle()
  expect(world.logs).toHaveLength(1)
  expect(world.logs[0]).toContain('/mdl small stopped:')
  expect(world.model).toBe('claude-opus-5-5')
})

test('a preset of the default model already in use still sets the effort', {
  options: { ...CONFIGURED, smallModel: 'default', smallEffort: 'low' },
}, async ($, on) => {
  const clock = mock.clock(on)
  // On the default model with no model setting: /model default changes nothing.
  const world = engine($, on, 'claude-opus-5-5')
  await start($)

  await mdl($, 'small')
  await clock.settle()
  expect(world.runs).toEqual([
    { command: 'model', args: 'default' },
    { command: 'effort', args: 'low' },
  ])
  expect(world.logs).toEqual([])
})

test('a refused [1m] variant holds the effort back, though the family matches', {
  options: { ...CONFIGURED, bigModel: 'opus[1m]' },
}, async ($, on) => {
  const clock = mock.clock(on)
  const world = engine($, on, 'claude-opus-5-5', {
    setting: 'opus',
    accepts: model => model !== 'opus[1m]',
  })
  await start($)

  await mdl($, 'big')
  await clock.settle()
  expect(world.runs).toEqual([{ command: 'model', args: 'opus[1m]' }])
  expect(world.logs).toHaveLength(1)
})

test('a [1m] variant /model takes sets the effort, with no switch to see', {
  options: { ...CONFIGURED, bigModel: 'opus[1m]' },
}, async ($, on) => {
  const clock = mock.clock(on)
  // The session's model reads the same with and without [1m], so no switch
  // fires; the saved setting shows /model took it.
  const world = engine($, on, 'claude-opus-5-5', { setting: 'opus' })
  await start($)

  await mdl($, 'big')
  await clock.settle()
  expect(world.runs).toEqual([
    { command: 'model', args: 'opus[1m]' },
    { command: 'effort', args: 'medium' },
  ])
  expect(world.logs).toEqual([])
})

test('alreadyOn: a family alias goes by the session model, whatever the setting', () => {
  expect(alreadyOn('opus', 'claude-opus-5-5', 'sonnet')).toBe(true)
  expect(alreadyOn('Opus', 'us.anthropic.claude-opus-5-5-v1:0', undefined)).toBe(true)
  expect(alreadyOn('opus', 'claude-opus-5-5@20261001', undefined)).toBe(true)
  // Refused, though the setting already names it.
  expect(alreadyOn('opus', 'claude-sonnet-5-5', 'opus')).toBe(false)
})

test('alreadyOn: anything else goes by the model ID, then the setting', () => {
  expect(alreadyOn('claude-opus-5-5', 'claude-opus-5-5', 'sonnet')).toBe(true)
  expect(alreadyOn('opus[1m]', 'claude-opus-5-5', 'opus[1m]')).toBe(true)
  expect(alreadyOn('opus[1m]', 'claude-opus-5-5', 'opus')).toBe(false)
  expect(alreadyOn('opusplan', 'claude-opus-5-5', 'opusplan')).toBe(true)
  expect(alreadyOn('default', 'claude-opus-5-5', undefined)).toBe(true)
  expect(alreadyOn('default', 'claude-opus-5-5', 'sonnet')).toBe(false)
  expect(alreadyOn('fabel', 'claude-opus-5-5', 'opus')).toBe(false)
})
