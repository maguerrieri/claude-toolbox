// A throwaway mock for #319: four ways a ledger panel could work, picked with
// the `variant` option (/config, or pluginConfigs in settings), drawn from
// real ledger files or from the fixtures beside it (`source`). It never
// writes a ledger: Resolve marks a need resolved in this mock's state only.
//
//   pane    /ledger-pane toggles a pane of this session's ledger; Esc closes it
//   status  the same pane, plus a status line under the prompt while a need is open
//   band    a band row above the prompt while any session has an open need,
//           whose Open shows the pane of every session's needs
//   inline  no pane: the band row expands in place into every session's needs
//
// See docs/superpowers/specs/2026-11-15-ledger-panel-options.md.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { MockNeed, MockView, Variant } from '../types'
import {
  EMPTY_VIEW,
  FIXTURE_ME,
  ageOf,
  countOf,
  firstLine,
  hasOthersNeed,
  keyOf,
  namesOf,
  needsKey,
  parseLedger,
  sessionOf,
  viewOf,
} from './model'
import type { Entry, Scope } from './model'

const PANE = 'ledger'
const COMMAND = 'ledger-pane'
const POLL_MS = 15_000
// `claude agents` costs a process; names change rarely.
const NAMES_MS = 60_000

const VARIANTS: readonly Variant[] = ['pane', 'status', 'band', 'inline']


// Change a tag when its value's fields change: it declines what an earlier
// version stored, which outlives a reload.
const view = atom({ plugin: 'ledger-panel-mock', key: 'view' } as const, EMPTY_VIEW, { shape: 'view-1' })
const hiddenFor = atom({ plugin: 'ledger-panel-mock', key: 'hiddenFor' } as const, '')
const resolvedHere = atom({ plugin: 'ledger-panel-mock', key: 'resolvedHere' } as const, {} as Record<string, string>, {
  shape: 'resolved-1',
})
const isShowingResolved = atom({ plugin: 'ledger-panel-mock', key: 'isShowingResolved' } as const, false)
const isExpanded = atom({ plugin: 'ledger-panel-mock', key: 'isExpanded' } as const, false)

/** What each option is made of. */
type Shape = {
  /** Which ledgers it reads. */
  scope: Scope
  /** Whether Escape closes the pane (a pane opened on demand, not a sidebar). */
  isClosedByEscape: boolean
  /** Whether it shows a status line under the prompt while a need is open. */
  hasStatus: boolean
  /** The band row above the prompt: none, a one-row summary, or one that expands in place of a pane. */
  band: 'none' | 'row' | 'expanding'
}

const SHAPES: Readonly<Record<Variant, Shape>> = {
  pane: { scope: 'session', isClosedByEscape: true, hasStatus: false, band: 'none' },
  status: { scope: 'session', isClosedByEscape: true, hasStatus: true, band: 'none' },
  band: { scope: 'all', isClosedByEscape: false, hasStatus: false, band: 'row' },
  inline: { scope: 'all', isClosedByEscape: false, hasStatus: false, band: 'expanding' },
}

/** Whether an option has a pane: every one but the band that expands in its place. */
const hasPane = (of: Shape): boolean => of.band !== 'expanding'

const variantOf = (value: unknown): Variant =>
  VARIANTS.includes(value as Variant) ? (value as Variant) : 'pane'

const meta = (parts: (string | undefined)[]): string => parts.filter(part => part !== undefined).join(' · ')

// `just now`, `5m ago`.
const agoOf = (at: string, nowMs: number): string => {
  const age = ageOf(at, nowMs)

  return age === 'now' ? 'just now' : `${age} ago`
}

// The option in force and its source, set by `register` from the plugin's
// options; a change in /config reloads the module, which sets them again.
let variant: Variant = 'pane'
let shape: Shape = SHAPES.pane
let isFixtures = true

// Caches, which a reload starts over: each file's entries as last read, kept
// while its size and mtime hold; the session names; and the view and status
// line this module last wrote (unknown at first, since the atom and the line
// keep what an earlier load wrote, so the first refresh always writes).
const files = new Map<string, { mtimeMs: number; size: number; entries: Entry[] }>()
let names: Record<string, string> = {}
let namesAt = 0
let shown: string | undefined
let statusShown: { text: string | undefined } | undefined
// The number of the latest refresh begun: one a later refresh overtook
// publishes nothing, so an older snapshot never overwrites a newer one.
let latest = 0
// The poll, one per module: a second session.start (a /clear) replaces it.
let poll: Timer | undefined

async function ledgerDir($: EngineInterface): Promise<string | undefined> {
  if (isFixtures) {
    return `${$.plugin.root}/fixtures/session-ledger`
  }
  const override = await $.env.get('CLAUDE_SESSION_LEDGER_DIR')
  if (override) {
    return override
  }
  const home = await $.env.get('HOME')

  return home ? `${home}/.claude/session-ledger` : undefined
}

async function namesFor($: EngineInterface, ledgers: Record<string, Entry[]>, me: string): Promise<void> {
  const now = await $.clock.now()
  // Names label only another session's open need, so with none nothing is
  // run (a session per terminal would otherwise each run it every minute).
  if (shape.scope !== 'all' || now - namesAt < NAMES_MS || !hasOthersNeed(ledgers, me)) {
    return
  }
  namesAt = now
  if (isFixtures) {
    const text = await $.fs.read(`${$.plugin.root}/fixtures/agents.json`).catch(() => undefined)
    names = text === undefined ? names : namesOf(text)

    return
  }
  const agents = await $.process
    .run(['claude', 'agents', '--json', '--all'], { timeoutMs: 5_000 })
    .catch(() => undefined)
  if (agents?.exitCode === 0) {
    names = namesOf(agents.stdout)
  }
}

// The status line, set only when its text changes: `$.ui.status` keeps a line
// until the next call replaces it, so there is nothing to repeat.
function setStatus($: EngineInterface, text: string | undefined): void {
  if (statusShown !== undefined && statusShown.text === text) {
    return
  }
  $.ui.status(text)
  statusShown = { text }
}

// The ledger directory's files, or undefined when a listing failed. A missing
// directory is no ledgers yet; any other failure keeps what was last read
// rather than show its needs as gone.
async function listLedgers($: EngineInterface, dir: string) {
  const isThere = await $.fs.exists(dir).catch(() => true)
  if (!isThere) {
    return []
  }

  return $.fs.list(dir).catch(() => undefined)
}

async function refresh($: EngineInterface): Promise<void> {
  latest += 1
  const turn = latest
  const dir = await ledgerDir($)
  if (dir === undefined) {
    return
  }
  const listed = await listLedgers($, dir)
  if (listed === undefined) {
    return
  }
  const ledgers: Record<string, Entry[]> = {}
  for (const file of listed) {
    const session = file.kind === 'file' ? sessionOf(file.name) : undefined
    if (session === undefined) {
      continue
    }
    const known = files.get(session)
    if (known && known.mtimeMs === file.mtimeMs && known.size === file.size) {
      ledgers[session] = known.entries
      continue
    }
    const text = await $.fs.read(`${dir}/${file.name}`).catch(() => undefined)
    if (text === undefined) {
      if (known) {
        ledgers[session] = known.entries
      }
      continue
    }
    const entries = parseLedger(text)
    files.set(session, { mtimeMs: file.mtimeMs, size: file.size, entries })
    ledgers[session] = entries
  }
  for (const session of files.keys()) {
    if (!(session in ledgers)) {
      files.delete(session)
    }
  }

  const me = isFixtures ? FIXTURE_ME : await $.session.id()
  await namesFor($, ledgers, me)
  const marked = await read($, resolvedHere)
  // The last await before the write: past here no later refresh can have
  // begun unseen, so this one's snapshot is the newest.
  if (turn !== latest) {
    return
  }
  const next = viewOf(ledgers, me, names, shape.scope, marked)
  const json = JSON.stringify(next)
  if (json !== shown) {
    await update($, view, () => next)
    // Marked only once written, so a write that fails is tried again next tick.
    shown = json
  }
  if (shape.hasStatus) {
    // The engine draws it after the plugin's name and cuts its end at the
    // terminal's width, so the count and the command come first.
    const [newest] = next.needs
    setStatus(
      $,
      newest === undefined ? undefined : `${countOf(next.needs.length)} (/${COMMAND}), newest: ${firstLine(newest.text)}`,
    )
  }
}

// A refresh that fails waits for the next tick.
async function refreshQuietly($: EngineInterface): Promise<void> {
  await refresh($).catch(() => undefined)
}

async function isPaneOpen($: EngineInterface): Promise<boolean> {
  return (await $.ui.panes()).some(pane => pane.id === PANE)
}

// The pane, opened; or why it waits undrawn.
async function openPane($: EngineInterface): Promise<string | undefined> {
  await refreshQuietly($)
  const opened = await $.ui.open({
    id: PANE,
    title: shape.scope === 'all' ? 'Ledger: every session' : 'Ledger',
    ...(shape.isClosedByEscape ? { closeOnEscape: true as const } : {}),
  })

  return opened.isPlaced ? undefined : opened.reason
}

// The band's Open: a pane that waits undrawn says why, as the command does.
async function openFromBand($: EngineInterface): Promise<void> {
  const waits = await openPane($)
  if (waits !== undefined) {
    $.ui.toast(`The ledger pane waits: ${waits}`)
  }
}

async function closePane($: EngineInterface): Promise<void> {
  await $.ui.close({ id: PANE })
}

// The inline band's toggle: a band that shows its list folds; one that is
// folded or hidden shows its list.
async function toggleInline($: EngineInterface): Promise<string | undefined> {
  const current: MockView = await read($, view)
  if (current.needs.length === 0) {
    return 'No session needs you.'
  }
  const isListShown = (await read($, isExpanded)) && (await read($, hiddenFor)) !== needsKey(current)
  await update($, hiddenFor, () => '')
  await update($, isExpanded, () => !isListShown)

  return undefined
}

// Resolve in the mock: marked resolved here, written nowhere. The real panel
// would run the ledger plugin's `ledger.sh resolve <id> --session <session>`.
async function resolveHere($: EngineInterface, need: MockNeed): Promise<void> {
  const at = new Date(await $.clock.now()).toISOString()
  await update($, resolvedHere, marks => ({ [keyOf(need)]: at, ...marks }))
  $.ui.toast(
    `Mock: ${need.id} marked resolved here only. The panel would run ledger.sh resolve ${need.id} --session ${need.session.slice(0, 8)}.`,
  )
  // The marks are part of the view: draw them now, not at the next tick.
  await refreshQuietly($)
}

export const register: Register = (on, options) => {
  variant = variantOf(options.variant)
  shape = SHAPES[variant]
  isFixtures = options.source !== 'live'

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.command.register({
      name: COMMAND,
      description: hasPane(shape)
        ? `Open or close the ledger pane (mock of #319, option: ${variant})`
        : `Expand or fold the ledger band (mock of #319, option: ${variant})`,
    })
    // A line an earlier load set stays until replaced: an option without one
    // clears it, so switching options in /config leaves none behind.
    if (!shape.hasStatus) {
      setStatus($, undefined)
    }
    await refreshQuietly($)
    poll?.cancel()
    poll = $.clock.every(POLL_MS, () => refreshQuietly($))

    return started
  })

  // The toggle: one command opens what is closed and closes what is open, so a
  // keybinding to `command:ledger-pane` is a toggle key.
  on('command.run', { command: COMMAND }, async $ => {
    if (!hasPane(shape)) {
      const said = await toggleInline($)

      return said === undefined ? {} : { text: said }
    }
    if (await isPaneOpen($)) {
      await closePane($)

      return {}
    }
    const waits = await openPane($)

    return waits === undefined ? {} : { text: `The ledger pane waits: ${waits}` }
  })


  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (shape.band === 'none') {
      return next(e)
    }
    const current: MockView = await read($, view)
    const key = needsKey(current)
    const isQuiet = e.props.hasSurvey || current.needs.length === 0 || (await read($, hiddenFor)) === key
    if (isQuiet) {
      return next(e)
    }
    const { Box, Button, Text } = $.ui.resolve(e)
    const [newest] = current.needs
    // The count and the buttons keep their width; the summary between them
    // takes what is left and is cut at its end.
    const count = (
      <Box flexShrink={0}>
        <Text color="warning">{`${countOf(current.needs.length)} `}</Text>
      </Box>
    )
    const summary = (
      <Box flexGrow={1} flexShrink={1}>
        <Text dimColor wrap="truncate-end">
          {newest ? `${newest.label}: ${firstLine(newest.text)}` : ''}
        </Text>
      </Box>
    )
    const buttons = (first: 'open' | 'show' | 'less') => (
      <Box flexShrink={0} columnGap={1} marginLeft={1}>
        {first === 'open' && <Button key="open" label="Open" onPress={() => openFromBand($)} />}
        {first === 'show' && <Button key="show" label="Show" onPress={() => update($, isExpanded, () => true)} />}
        {first === 'less' && <Button key="less" label="Less" onPress={() => update($, isExpanded, () => false)} />}
        <Button key="hide" label="Hide" dimColor onPress={() => update($, hiddenFor, () => key)} />
      </Box>
    )

    if (shape.band === 'row' || !(await read($, isExpanded))) {
      return (
        <Box>
          {count}
          {summary}
          {buttons(shape.band === 'row' ? 'open' : 'show')}
        </Box>
      )
    }
    const now = await $.clock.now()

    // No hotkeys on these Resolve buttons: a bare digit in an empty composer
    // presses a band Button, so one typed by mistake would resolve a need.
    return (
      <Box flexDirection="column">
        <Box>
          {count}
          {buttons('less')}
        </Box>
        {current.needs.map(need => (
          <Box key={`need:${keyOf(need)}`} flexDirection="column">
            <Box>
              <Box flexShrink={0} marginRight={1}>
                <Button key={`resolve:${keyOf(need)}`} label="Resolve" dimColor onPress={() => resolveHere($, need)} />
              </Box>
              <Text color="warning" wrap="truncate-end">
                {meta([need.label, need.id, need.ref, ageOf(need.at, now)])}
              </Text>
            </Box>
            <Box marginLeft={12} flexDirection="column">
              <Text wrap="truncate-end">{firstLine(need.text)}</Text>
              {need.why !== undefined && <Text dimColor wrap="truncate-end">{`Why: ${need.why}`}</Text>}
            </Box>
          </Box>
        ))}
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const current: MockView = await read($, view)
    const isShowing = await read($, isShowingResolved)
    const now = await $.clock.now()
    const isEveryone = shape.scope === 'all'

    const needRow = (need: MockNeed, index: number, isOpen: boolean) => (
      <Box key={`need:${keyOf(need)}`} flexDirection="column" marginBottom={1}>
        <Text color={isOpen ? 'warning' : undefined} dimColor={!isOpen}>
          {meta([isEveryone ? need.label : undefined, need.id, need.ref, ageOf(need.at, now)])}
          {isOpen ? '' : ` · resolved ${agoOf(need.resolvedAt ?? '', now)}`}
        </Text>
        {need.why !== undefined && <Text dimColor>{`Why: ${need.why}`}</Text>}
        <Text dimColor={!isOpen}>{need.text}</Text>
        {isOpen && (
          <Button
            key={`resolve:${keyOf(need)}`}
            label="Resolve"
            {...(index < 9 ? { hotkey: String(index + 1) } : {})}
            onPress={() => resolveHere($, need)}
          />
        )}
      </Box>
    )

    return (
      <Box flexDirection="column">
        <Box columnGap={1}>
          <Text bold>{isEveryone ? 'Every session' : 'This session'}</Text>
          <Button
            key="resolved"
            label={isShowing ? 'Hide resolved' : 'Show resolved'}
            hotkey="r"
            dimColor
            onPress={() => update($, isShowingResolved, isOn => !isOn)}
          />
          <Button key="close" label="Close" role="dismiss" hotkey="x" dimColor onPress={() => closePane($)} />
        </Box>
        <Text bold>Open needs ({current.needs.length})</Text>
        {current.needs.length === 0 && (
          <Text dimColor>{isEveryone ? 'No session needs you.' : 'This session needs nothing from you.'}</Text>
        )}
        {current.needs.map((need, index) => needRow(need, index, true))}
        {isShowing && <Text bold>Resolved ({current.resolved.length})</Text>}
        {isShowing && current.resolved.length === 0 && <Text dimColor>None.</Text>}
        {isShowing && current.resolved.map((need, index) => needRow(need, index, false))}
        <Text bold>Decisions in this session ({current.decisions.length})</Text>
        {current.decisions.length === 0 && <Text dimColor>None recorded.</Text>}
        {current.decisions.map(decision => (
          <Box key={`decision:${decision.id}`} flexDirection="column" marginBottom={1}>
            <Text dimColor>{meta([decision.id, decision.ref, ageOf(decision.at, now)])}</Text>
            {decision.why !== undefined && <Text dimColor>{`Why: ${decision.why}`}</Text>}
            <Text>{decision.text}</Text>
          </Box>
        ))}
        <Text dimColor>
          {`Mock of #319 (option ${variant}${isFixtures ? ', fixtures' : ''}): Resolve writes nothing. ` +
            `Close: /${COMMAND}, ctrl+x x${shape.isClosedByEscape ? ', Esc' : ''}, or Close.`}
        </Text>
      </Box>
    )
  })
}
