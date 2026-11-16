// /mdl big|medium|small: one command that sets the session's model and effort
// level together, from three presets the person sets in /config (mdl.<field>).
//
// The plugin ships no preset of its own: every field is unset until the person
// sets it, and /mdl <size> then says what to set.
//
// It switches the way a person does, by running /model and then /effort. A
// command.run hook can't run another command itself (the engine refuses: the
// run would wait on the command the hook is holding), so the hook answers
// first and a timer runs the two commands once the session is idle.

import type { EngineInterface, PluginOptions, Register } from 'claude-code'

export const SIZES = ['big', 'medium', 'small'] as const
export type Size = (typeof SIZES)[number]

// What /effort takes, less its `ultracode` switch, which isn't a level.
export const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max', 'auto'] as const

export type Preset = { model?: string; effort?: string }

function text(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined
}

export function presetOf(options: PluginOptions, size: Size): Preset {
  return { model: text(options[`${size}Model`]), effort: text(options[`${size}Effort`]) }
}

function describe(preset: Preset): string {
  if (preset.model === undefined || preset.effort === undefined) return 'not set'
  return `${preset.model} at ${preset.effort} effort`
}

export function usage(options: PluginOptions, model: string): string {
  const rows = SIZES.map(size => `  ${size.padEnd(6)}  ${describe(presetOf(options, size))}`)
  return [`Usage: /mdl big|medium|small. The session is on ${model}.`, ...rows].join('\n')
}

// The answer to /mdl <size> when the size can't run: what's missing or wrong,
// and nothing changed. Undefined when the preset can run.
export function problem(size: Size, preset: Preset): string | undefined {
  const missing = [
    preset.model === undefined ? `mdl.${size}Model` : undefined,
    preset.effort === undefined ? `mdl.${size}Effort` : undefined,
  ].filter(field => field !== undefined)
  if (missing.length > 0) {
    return (
      `/mdl ${size} isn't configured: set ${missing.join(' and ')} in /config ` +
      `(or under pluginConfigs in your settings.json). Nothing changed.`
    )
  }
  const effort = preset.effort ?? ''
  if (!(EFFORTS as readonly string[]).includes(effort.toLowerCase())) {
    return (
      `/mdl ${size}: "${effort}" isn't an effort level (${EFFORTS.join(', ')}). ` +
      `Fix mdl.${size}Effort in /config. Nothing changed.`
    )
  }
  return undefined
}

// Whether /model took: the /config model row now holds what was asked for, or
// the session's model changed. /model prints its own line either way (a model
// it doesn't know, one the account can't use yet); this only decides whether
// /effort follows.
async function modelTook($: EngineInterface, wanted: string, before: string): Promise<boolean> {
  const after = await $.session.model()
  if (after !== before || after.toLowerCase() === wanted.toLowerCase()) return true
  const row = (await $.config.list()).find(one => one.key === 'model')

  return typeof row?.value === 'string' && row.value.toLowerCase() === wanted.toLowerCase()
}

// Runs /model, then /effort if the model took. Called from a timer, so the
// session is free to run them.
async function apply($: EngineInterface, size: Size, model: string, effort: string) {
  try {
    const before = await $.session.model()
    await $.command.run({ command: 'model', args: model })
    if (!(await modelTook($, model, before))) {
      $.ui.log(
        `/mdl ${size}: /model didn't switch to ${model} (its message is above), ` +
          `so the effort was left as it was.`,
      )
      return
    }
    await $.command.run({ command: 'effort', args: effort.toLowerCase() })
  } catch (err) {
    $.ui.log(`/mdl ${size} stopped: ${err instanceof Error ? err.message : String(err)}`)
  }
}

export const register: Register = (on, options) => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'mdl',
      description: 'Switch the model and effort together, to a preset set in /config',
      argumentHint: 'big|medium|small',
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

    const preset = presetOf(options, size)
    const refusal = problem(size, preset)
    if (refusal !== undefined) return { text: refusal }

    const model = preset.model ?? ''
    const effort = preset.effort ?? ''
    $.clock.after(0, () => {
      void apply($, size, model, effort)
    })

    return {
      text:
        `Switching to ${model} at ${effort} effort: /model and /effort run next, ` +
        `and the new model and effort apply from your next message.`,
    }
  })
}
