// /mdl big|medium|small: one command that sets the session's model and effort
// level together, from three presets the person sets in /config (mdl.<field>).
//
// The plugin ships no preset of its own: every field is unset until the person
// sets it, and /mdl <size> then says what to set.
//
// It switches the way a person does, by running /model and then /effort. A
// command.run hook can't run another command itself (the engine refuses: the
// run would wait on the command the hook is holding), so the hook answers
// first and a timer queues the commands. /mdl is `immediate`, so typed during
// a turn it queues /model at once, ahead of anything typed after it.
//
// /effort runs only once /model took. /model's own result carries no text, so
// the plugin reads the switch off PostModelSwitch, which fires for a real
// change only; with no switch, the session either was already on the model or
// /model refused it (alreadyOn tells them apart). That decision has to wait
// for /model to run, so /effort is queued after it rather than beside it. (A
// plugin's own command.run hooks don't see its own $.command.run, so it can't
// queue both and hold /effort back from a hook.)

import type { EngineInterface, PluginOptions, Register } from 'claude-code'

const SIZES = ['big', 'medium', 'small'] as const
type Size = (typeof SIZES)[number]

// What /effort takes, less its `ultracode` switch, which isn't a level.
const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max', 'auto'] as const

// The aliases /model takes that name a model family. A session on a model of
// that family (an ID holding `claude-opus-`, first-party or a cloud
// provider's) is on the alias.
const FAMILIES = ['opus', 'sonnet', 'haiku', 'fable'] as const

// The aliases whose model the session's model ID can't show: `default` and
// `best` name whichever model the account resolves them to.
const OPAQUE = ['default', 'best'] as const

type Preset = { model: string; effort: string }

// A switch in flight: what it asked for, and whether /model has switched to
// it. One at a time: a second /mdl waits for the first to finish.
type Switch = Preset & { size: Size; switched: boolean }

function text(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined
}

// A size's preset as /mdl can run it, or what's wrong with it: `missing` when
// a field is unset, as opposed to set to something that isn't a level.
function presetOf(
  options: PluginOptions,
  size: Size,
): { preset: Preset } | { refusal: string; missing: boolean } {
  const model = text(options[`${size}Model`])
  const effort = text(options[`${size}Effort`])
  if (model === undefined || effort === undefined) {
    const fields = [
      model === undefined ? `mdl.${size}Model` : undefined,
      effort === undefined ? `mdl.${size}Effort` : undefined,
    ].filter(field => field !== undefined)

    return {
      missing: true,
      refusal:
        `/mdl ${size} isn't configured: set ${fields.join(' and ')} in /config ` +
        `(or under pluginConfigs in your settings.json). Nothing changed.`,
    }
  }
  if (!(EFFORTS as readonly string[]).includes(effort.toLowerCase())) {
    return {
      missing: false,
      refusal:
        `/mdl ${size}: "${effort}" isn't an effort level (${EFFORTS.join(', ')}). ` +
        `Fix mdl.${size}Effort in /config. Nothing changed.`,
    }
  }

  return { preset: { model, effort: effort.toLowerCase() } }
}

function usage(options: PluginOptions, model: string): string {
  const rows = SIZES.map(size => {
    const read = presetOf(options, size)
    const shown =
      'preset' in read
        ? `${read.preset.model} at ${read.preset.effort} effort`
        : read.missing
          ? 'not set'
          : 'its effort is not a level'

    return `  ${size.padEnd(6)}  ${shown}`
  })

  return [`Usage: /mdl big|medium|small. The session is on ${model}.`, ...rows].join('\n')
}

// Whether PostModelSwitch's `requested_model` is what /mdl asked /model for:
// the name as typed, or null for `default`.
function requested(asked: string, requestedModel: string | null): boolean {
  if (requestedModel === null) return asked.toLowerCase() === 'default'

  return requestedModel.toLowerCase() === asked.toLowerCase()
}

// What the session's model shows of the name /mdl asked for: whether the
// session is on that model ID, or on the family an alias names (`opusplan`
// runs on Opus, and a `[1m]` variant on its plain model); undefined for a name
// it can't show at all.
function shows(asked: string, current: string): boolean | undefined {
  const base = asked.replace(/\[1m\]$/, '')
  const family = base === 'opusplan' ? 'opus' : base
  if ((FAMILIES as readonly string[]).includes(family)) return current.includes(`claude-${family}-`)
  if ((OPAQUE as readonly string[]).includes(base)) return undefined

  return base === current
}

// Whether a /model that fired no switch found the session already on the
// model /mdl asked for, rather than refusing it. The session's model is the
// evidence wherever it shows anything, so a session on another model is never
// on it, whatever the setting says. A plain family alias or model ID needs
// nothing more. What the session's model can't tell apart (a `[1m]` variant
// from its plain model, `opusplan` from Opus, `default` and `best`) also needs
// the model setting, read after /model, to hold the name as asked: /model
// saves what it takes, and `default` is no setting at all.
export function alreadyOn(asked: string, current: string, setting: unknown): boolean {
  const want = asked.toLowerCase()
  const active = shows(want, current.toLowerCase())
  if (active === false) return false
  const plain = active === true && !want.endsWith('[1m]') && want !== 'opusplan'
  if (plain) return true
  const saved = typeof setting === 'string' && setting.trim() !== '' ? setting.trim() : 'default'

  return saved.toLowerCase() === want
}

// Runs /model, then /effort if the model took. Each prints its own line, as
// typed ones do. Called from a timer, so the session can run them.
async function apply($: EngineInterface, change: Switch) {
  try {
    await $.command.run({ command: 'model', args: change.model })
    const took =
      change.switched ||
      alreadyOn(change.model, await $.session.model(), await $.settings.read({ key: 'model' }))
    if (!took) {
      $.ui.log(
        `/mdl ${change.size}: the model didn't switch to ${change.model}, ` +
          `so the effort was left as it was.`,
      )
      return
    }
    await $.command.run({ command: 'effort', args: change.effort })
  } catch (err) {
    $.ui.log(`/mdl ${change.size} stopped: ${err instanceof Error ? err.message : String(err)}`)
  }
}

export const register: Register = (on, options) => {
  // The switch whose /model is running, for PostModelSwitch to mark.
  let current: Switch | undefined
  // The switches queued so far, one after another, so two /mdl in a row run
  // model, effort, model, effort. apply catches its own errors, so a link
  // never rejects.
  let last: Promise<void> = Promise.resolve()

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'mdl',
      description: 'Switch the model and effort together, to a preset set in /config',
      argumentHint: 'big|medium|small',
      immediate: true,
    })

    return next(e)
  })

  on('command.run', { command: 'mdl' }, async ($, e) => {
    const typed = e.args.trim()
    const size = SIZES.find(one => one === typed.toLowerCase())
    if (size === undefined) {
      const lead = typed === '' ? '' : `"${typed}" isn't a size. Nothing changed.\n`

      return { text: lead + usage(options, await $.session.model()) }
    }

    const read = presetOf(options, size)
    if (!('preset' in read)) return { text: read.refusal }

    const { model, effort } = read.preset
    const change: Switch = { size, model, effort, switched: false }
    $.clock.after(0, () => {
      last = last.then(async () => {
        current = change
        await apply($, change)
        current = undefined
      })
    })

    return {
      text:
        `Switching to ${model} at ${effort} effort: /model and /effort follow this reply, ` +
        `and apply from the next message after them.`,
    }
  })

  // Marks the switch in flight as taken when /model really switches to it.
  on('classic.PostModelSwitch', ($, e, next) => {
    if (current !== undefined && e.source === 'command' && requested(current.model, e.requested_model)) {
      current.switched = true
    }

    return next(e)
  }).catch(($, e, next) => next(e))
}
