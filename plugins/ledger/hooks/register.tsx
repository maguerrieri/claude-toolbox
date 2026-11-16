// The ledger band (#330, option 4 of #319's mock): a row above the prompt
// while this session has an open need, its count and the newest one, that
// expands in place into every open need, each with its Why line and a Resolve
// button. /ledger-band expands and folds it, Show and Less do the same, and
// Hide quiets it until a need it didn't show opens.
//
// It reads this session's ledger alone, the file scripts/ledger.sh writes,
// every 15 seconds and at the end of each turn, and writes only through the
// script (Resolve), so the file keeps one writer's format. The one reader is
// readLedgers, which #316 can widen to every local session's ledger.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { LedgerNeed, LedgerView } from '../types'
import {
  EMPTY_VIEW,
  ageOf,
  countOf,
  firstLine,
  isHiddenBy,
  isResolvable,
  ledgerFileOf,
  parseLedger,
  viewOf,
} from './model'
import type { Entry, Ledgers } from './model'

const POLL_MS = 15_000

// Change a tag when its value's fields change: it declines what an earlier
// version stored, which outlives a reload. (PR #272's unreleased mod stored
// view-3 under the same key.)
const view = atom({ plugin: 'ledger', key: 'view' } as const, EMPTY_VIEW, { shape: 'view-4' })
const hiddenFor = atom({ plugin: 'ledger', key: 'hiddenFor' } as const, [] as string[], { shape: 'hidden-1' })
const isExpanded = atom({ plugin: 'ledger', key: 'isExpanded' } as const, false)
const minute = atom({ plugin: 'ledger', key: 'minute' } as const, 0)

// Caches, which a reload starts over: the ledger file as last read, kept while
// its size and mtime hold, and the view this module last wrote (unknown at
// first, since the atom keeps what an earlier load wrote, so the first refresh
// always writes).
let lastRead: { file: string; mtimeMs: number; size: number; entries: Entry[] } | undefined
let shown: string | undefined
// The number of the latest refresh begun: one a later refresh overtook (a poll
// still reading while Resolve's refresh ran) publishes nothing, so an older
// snapshot never overwrites a newer one.
let latest = 0
// The poll, one per module: a second session.start (a reload of the plugin,
// never a /clear) replaces it.
let poll: Timer | undefined
// The ledger directory, fixed for the process, so read once per load. The
// session id is read on every refresh instead, since a /clear changes it.
let dirRead: { dir: string | undefined } | undefined

async function ledgerDir($: EngineInterface): Promise<string | undefined> {
  if (dirRead === undefined) {
    const override = await $.env.get('CLAUDE_SESSION_LEDGER_DIR')
    const home = override ? undefined : await $.env.get('HOME')
    dirRead = { dir: override || (home ? `${home}/.claude/session-ledger` : undefined) }
  }

  return dirRead.dir
}

/**
 * The ledgers the band shows, by session id: this session's alone, as the
 * owner chose for #330. Undefined when a read failed, so the band keeps what
 * it last showed rather than show those needs as gone; a ledger that isn't
 * there yet is one with no entries.
 */
async function readLedgers($: EngineInterface): Promise<Ledgers | undefined> {
  const dir = await ledgerDir($)
  const me = await $.session.id()
  const file = dir === undefined ? undefined : ledgerFileOf(dir, me)
  if (file === undefined) {
    return undefined
  }
  // Only a stat that fails ENOENT means no ledger yet: `$.fs.exists` also says
  // false for a file in a directory it can't search, which the script refuses
  // ("the ledger directory could not be read") and the band must not read as
  // no needs. The engine's rejection ends in the error's code (checked on
  // 2.1.325: `failed: ENOENT`, `failed: EACCES`).
  const stat = await $.fs.stat(file).catch((error: unknown) => (/\bENOENT\b/.test(String(error)) ? null : undefined))
  if (stat === null) {
    return { [me]: [] }
  }
  // Something other than a file there is a ledger the script can't read
  // either ("the ledger path is not a regular file").
  if (stat === undefined || stat.kind !== 'file') {
    return undefined
  }
  if (lastRead?.file === file && lastRead.mtimeMs === stat.mtimeMs && lastRead.size === stat.size) {
    return { [me]: lastRead.entries }
  }
  const text = await $.fs.read(file).catch(() => undefined)
  if (text === undefined) {
    return undefined
  }
  const entries = parseLedger(text)
  lastRead = { file, mtimeMs: stat.mtimeMs, size: stat.size, entries }

  return { [me]: entries }
}

async function refresh($: EngineInterface): Promise<void> {
  latest += 1
  const turn = latest
  const ledgers = await readLedgers($)
  const now = await $.clock.now()
  // The last await before the writes: past here no later refresh can have
  // begun unseen, so this one's snapshot is the newest.
  if (turn !== latest) {
    return
  }
  if (ledgers !== undefined) {
    const next = viewOf(ledgers)
    const json = JSON.stringify(next)
    if (json !== shown) {
      await update($, view, () => next)
      // Marked only once written, so a write that fails is tried again next tick.
      shown = json
    }
    // With nothing open the band is gone: fold it, so the next need arrives
    // as the one-row summary rather than the whole list.
    if (next.needs.length === 0 && (await read($, isExpanded))) {
      await update($, isExpanded, () => false)
    }
  }
  // The ages the band shows come from the clock, not the view: a new minute
  // redraws them, which the unchanged view never would.
  const thisMinute = Math.floor(now / 60_000)
  if ((await read($, minute)) !== thisMinute) {
    await update($, minute, () => thisMinute)
  }
}

// A refresh that fails waits for the next tick.
async function refreshQuietly($: EngineInterface): Promise<void> {
  await refresh($).catch(() => undefined)
}

// The toggle: a band that shows its list folds; one that is folded or hidden
// shows its list. It reads a fresh view, so it never expands needs already
// resolved.
async function toggle($: EngineInterface): Promise<string | undefined> {
  await refreshQuietly($)
  const current: LedgerView = await read($, view)
  if (current.needs.length === 0) {
    return 'This session needs nothing from you.'
  }
  const isListShown = (await read($, isExpanded)) && !isHiddenBy(current, await read($, hiddenFor))
  await update($, hiddenFor, () => [])
  await update($, isExpanded, () => !isListShown)

  return undefined
}

// Hide: quiet the band until a need it didn't show opens, and fold it, so it
// comes back as the one-row summary rather than the whole list. <keys> are
// the needs the pressed band drew, not a fresh read: a need that opened since
// was never seen, so it still shows.
async function hideBand($: EngineInterface, keys: readonly string[]): Promise<void> {
  await update($, hiddenFor, () => [...keys])
  await update($, isExpanded, () => false)
}

// The owner marking a need answered, through the script like every other
// write, as this session: a need the band showed before a /clear belongs to
// the session before it, whose ledger this one never writes. A need the
// script couldn't resolve says why.
async function resolveNeed($: EngineInterface, need: LedgerNeed): Promise<void> {
  const me = await $.session.id()
  if (need.session !== me) {
    $.ui.toast(`Didn't resolve ${need.id}: it is an earlier session's need, not this one's.`)
    await refreshQuietly($)

    return
  }
  const ran = await $.process
    .run(['bash', `${$.plugin.root}/scripts/ledger.sh`, 'resolve', need.id], {
      // The plugin's own folder: the session's directory may be gone (a
      // worktree FINISH removed), and a child can't start in one.
      cwd: $.plugin.root,
      env: { CLAUDE_CODE_SESSION_ID: me },
      timeoutMs: 15_000,
    })
    .catch((error: unknown) => ({ exitCode: 1, stderr: String(error) }))
  if (ran.exitCode !== 0) {
    const why = firstLine(ran.stderr.trim()).replace(/^ledger resolve: /, '')
    $.ui.toast(`Couldn't resolve ${need.id}: ${why || 'ledger.sh failed'}`)
  }
  await refreshQuietly($)
}

const meta = (parts: (string | undefined)[]): string => parts.filter(part => part !== undefined).join(' · ')

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.command.register({
      name: 'ledger-band',
      description: "Expand or fold the band of this session's open needs above the prompt",
    })
    await refreshQuietly($)
    poll?.cancel()
    poll = $.clock.every(POLL_MS, () => refreshQuietly($))

    return started
  })

  // A turn is where this session records and resolves its needs, so the band
  // catches up as one ends rather than at the next tick.
  on('turn.complete', async ($, e, next) => {
    const completed = await next(e)
    if (e.agentId === undefined) {
      await refreshQuietly($)
    }

    return completed
  })

  // One command expands what is folded and folds what is expanded, so a
  // keybinding to `command:ledger-band` is a toggle key.
  on('command.run', { command: 'ledger-band' }, async $ => {
    const said = await toggle($)

    return said === undefined ? {} : { text: said }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const current: LedgerView = await read($, view)
    const keys = current.needs.map(need => need.key)
    const isQuiet = e.props.hasSurvey || current.needs.length === 0 || isHiddenBy(current, await read($, hiddenFor))
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
    const buttons = (first: 'show' | 'less') => (
      <Box flexShrink={0} columnGap={1} marginLeft={1}>
        {first === 'show' && <Button key="show" label="Show" onPress={() => update($, isExpanded, () => true)} />}
        {first === 'less' && <Button key="less" label="Less" onPress={() => update($, isExpanded, () => false)} />}
        <Button key="hide" label="Hide" dimColor onPress={() => hideBand($, keys)} />
      </Box>
    )

    if (!(await read($, isExpanded))) {
      return (
        <Box>
          {count}
          <Box flexGrow={1} flexShrink={1}>
            <Text dimColor wrap="truncate-end">
              {newest ? firstLine(newest.text) : ''}
            </Text>
          </Box>
          {buttons('show')}
        </Box>
      )
    }
    // Read so that a new minute redraws the ages.
    await read($, minute)
    const now = await $.clock.now()

    // No hotkeys on the Resolve buttons: a bare digit in an empty composer
    // presses a band Button, so one typed by mistake would resolve a need.
    return (
      <Box flexDirection="column">
        <Box>
          {count}
          {buttons('less')}
        </Box>
        {current.needs.map(need => (
          <Box key={`need:${need.key}`} flexDirection="column">
            <Box>
              <Box flexShrink={0} width={12}>
                {isResolvable(need.id) && (
                  <Button key={`resolve:${need.key}`} label="Resolve" dimColor onPress={() => resolveNeed($, need)} />
                )}
              </Box>
              <Text color="warning" wrap="truncate-end">
                {meta([need.id, need.ref, ageOf(need.at, now)])}
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
}
