// The ledger mod: a band above the prompt while any local session has an open
// need, and a pane (/ledger-pane) listing every session's open needs, each
// with a Resolve button, and this session's latest decisions. It reads the
// ledger files scripts/ledger.sh writes, every 15 seconds, and names other
// sessions from `claude agents --json --all`. It writes only through the
// script (Resolve), so the files keep one writer's format.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { LedgerCopy, LedgerNeed, LedgerView } from '../types'
import { EMPTY_VIEW, ageOf, firstLine, namesOf, needsKey, parseLedger, sessionOf, viewOf } from './model'
import type { Entry } from './model'

const PANE = 'ledger'
const POLL_MS = 15_000
// `claude agents` costs a process; names change rarely.
const NAMES_MS = 60_000

// Change the tag when LedgerView's fields change: it declines what an earlier
// version stored, which outlives a reload.
const view = atom({ plugin: 'ledger', key: 'view' } as const, EMPTY_VIEW, { shape: 'view-2' })
const hiddenFor = atom({ plugin: 'ledger', key: 'hiddenFor' } as const, '')

// Caches, which a reload starts over: each file's entries as last read, kept
// while its size and mtime hold; the session names; and the view this module
// last wrote. That starts unknown, since the atom keeps what an earlier load
// wrote, so the first refresh always writes.
const files = new Map<string, { mtimeMs: number; size: number; entries: Entry[] }>()
let names: Record<string, string> = {}
let namesAt = 0
let shown: string | undefined
// The poll, one per module: a second session.start (a /clear) replaces it.
let poll: Timer | undefined

async function ledgerDir($: EngineInterface): Promise<string | undefined> {
  const override = await $.env.get('CLAUDE_SESSION_LEDGER_DIR')
  if (override) {
    return override
  }
  const home = await $.env.get('HOME')

  return home ? `${home}/.claude/session-ledger` : undefined
}

async function refresh($: EngineInterface): Promise<void> {
  const dir = await ledgerDir($)
  if (dir === undefined) {
    return
  }
  const listed = await $.fs.list(dir).catch(() => [])
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

  const me = await $.session.id()
  const now = await $.clock.now()
  if (now - namesAt >= NAMES_MS) {
    namesAt = now
    const agents = await $.process
      .run(['claude', 'agents', '--json', '--all'], { timeoutMs: 10_000 })
      .catch(() => undefined)
    if (agents?.exitCode === 0) {
      names = namesOf(agents.stdout)
    }
  }

  const next = viewOf(ledgers, me, names)
  const json = JSON.stringify(next)
  if (json !== shown) {
    shown = json
    await update($, view, () => next)
  }
}

// A refresh that fails waits for the next tick.
async function refreshQuietly($: EngineInterface): Promise<void> {
  await refresh($).catch(() => undefined)
}

async function openPane($: EngineInterface): Promise<void> {
  await refreshQuietly($)
  await $.ui.open({ id: PANE, title: 'Ledger' })
}

// The owner's dismissal of a need and every copy of it, through the script
// like every other write. A copy the script couldn't resolve says why.
async function resolveNeed($: EngineInterface, need: LedgerNeed): Promise<void> {
  const failures: string[] = []
  for (const copy of [need, ...need.also]) {
    const ran = await $.process
      .run(['bash', `${$.plugin.root}/scripts/ledger.sh`, 'resolve', copy.id, '--session', copy.session], {
        timeoutMs: 15_000,
      })
      .catch((error: unknown) => ({ exitCode: 1, stderr: String(error) }))
    if (ran.exitCode !== 0) {
      failures.push(`${copy.label} ${copy.id}: ${ran.stderr.trim().split('\n')[0] ?? 'failed'}`)
    }
  }
  if (failures.length > 0) {
    $.ui.toast(`Couldn't resolve ${failures.join('; ')}`)
  }
  await refreshQuietly($)
}

function meta(parts: (string | undefined)[]): string {
  return parts.filter(part => part !== undefined).join(' · ')
}

function copies(also: readonly LedgerCopy[]): string {
  return also.map(copy => `${copy.label} ${copy.id}`).join(', ')
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.command.register({
      name: 'ledger-pane',
      description: "Show every session's open needs and this session's decisions in a pane",
    })
    await refreshQuietly($)
    poll?.cancel()
    poll = $.clock.every(POLL_MS, () => refreshQuietly($))

    return started
  })

  on('command.run', { command: 'ledger-pane' }, async $ => {
    await openPane($)

    return { text: 'Ledger pane opened.' }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const current: LedgerView = await read($, view)
    const key = needsKey(current)
    const isQuiet = e.props.hasSurvey || current.needs.length === 0 || (await read($, hiddenFor)) === key
    if (isQuiet) {
      return next(e)
    }
    const { Box, Button, Text } = $.ui.resolve(e)
    const [newest] = current.needs
    const count = current.needs.length

    return (
      <Box>
        <Text color="warning">
          {count} open {count === 1 ? 'need' : 'needs'}{' '}
        </Text>
        <Text dimColor wrap="truncate-end">
          {newest ? `${newest.label}: ${firstLine(newest.text)} ` : ''}
        </Text>
        <Button key="open" label="Open" onPress={() => openPane($)} />
        <Button key="hide" label="Hide" onPress={() => update($, hiddenFor, () => key)} />
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const current: LedgerView = await read($, view)
    const now = await $.clock.now()

    return (
      <Box flexDirection="column">
        <Text bold>Open needs ({current.needs.length})</Text>
        {current.needs.length === 0 && <Text dimColor>No session needs you.</Text>}
        {current.needs.map(need => (
          <Box key={`need:${need.session}:${need.id}`} flexDirection="column" marginBottom={1}>
            <Text color="warning">{meta([need.label, need.id, need.ref, ageOf(need.at, now)])}</Text>
            <Text>{need.text}</Text>
            {need.also.length > 0 && <Text dimColor>also: {copies(need.also)}</Text>}
            <Button key={`resolve:${need.session}:${need.id}`} label="Resolve" onPress={() => resolveNeed($, need)} />
          </Box>
        ))}
        <Text bold>Decisions in this session ({current.decisions.length})</Text>
        {current.decisions.length === 0 && <Text dimColor>None recorded.</Text>}
        {current.decisions.map(decision => (
          <Box key={`decision:${decision.id}`} flexDirection="column" marginBottom={1}>
            <Text dimColor>{meta([decision.id, decision.ref, ageOf(decision.at, now)])}</Text>
            <Text>{decision.text}</Text>
          </Box>
        ))}
      </Box>
    )
  })
}
