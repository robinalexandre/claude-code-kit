import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { PrRow, PrSnapshot } from '../types'

const PANE = 'tracked-prs'
const TITLE = 'Tracked PRs'
const COMMAND = 'prs'
const LIVE_TIMEOUT_MS = 180_000
const RELOAD_EVERY_MS = 5 * 60_000
const NEEDS_US = new Set(['a CI fix', 'changes from us', 'CI to be queued again'])

const snapshot = atom({ plugin: 'pr-pane', key: 'snapshot' } as const, null)
const isRefreshing = atom({ plugin: 'pr-pane', key: 'isRefreshing' } as const, false)
const problem = atom({ plugin: 'pr-pane', key: 'problem' } as const, '')

const truncate = (text: string, width: number) =>
  text.length > width ? `${text.slice(0, Math.max(0, width - 1))}…` : text

const clockTime = (milliseconds: number) => {
  const date = new Date(milliseconds)

  return [date.getHours(), date.getMinutes()].map(part => String(part).padStart(2, '0')).join(':')
}

const script = async ($: EngineInterface) => {
  const home = (await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE')) ?? '~'

  return `${home.replace(/\\/g, '/')}/.claude/skills/pr-watch/pr-watch.sh`
}

const prWatch = async ($: EngineInterface, args: string[], timeoutMs = 30_000) =>
  $.process.run(['bash', await script($), ...args], { timeoutMs })

const load = async ($: EngineInterface, isLive: boolean) => {
  if (isLive) {
    await update($, isRefreshing, () => true)
  }

  try {
    const ran = await prWatch($, isLive ? ['status', '--live'] : ['status'], isLive ? LIVE_TIMEOUT_MS : 30_000)

    if (ran.exitCode !== 0) {
      await update($, problem, () => (ran.stderr.trim() || `pr-watch exited with ${ran.exitCode}`).split('\n')[0])

      return
    }

    const parsed = JSON.parse(ran.stdout) as { prs: PrRow[]; errors: string[] }
    const loaded: PrSnapshot = { ...parsed, isLive, at: clockTime(await $.clock.now()) }
    await update($, snapshot, () => loaded)
    await update($, problem, () => '')
  } catch (error) {
    await update($, problem, () => `pr-watch did not run: ${String(error)}`)
  } finally {
    if (isLive) {
      await update($, isRefreshing, () => false)
    }
  }
}

const refresh = async ($: EngineInterface) => {
  if (!(await read($, isRefreshing))) {
    await load($, true)
  }
}

const openPr = async ($: EngineInterface, url: string) => {
  const ran = await prWatch($, ['open', url]).catch(error => ({ exitCode: 1, stderr: String(error) }))

  if (ran.exitCode !== 0) {
    $.ui.toast(`Could not open the PR: ${ran.stderr.trim().split('\n')[0]}`)
  }
}

const openPane = async ($: EngineInterface) => {
  await $.ui.open({ id: PANE, title: TITLE, columns: 64 })
  await load($, false)
  void refresh($)
}

const waitingColor = (waiting: string) => {
  if (waiting === 'the merge' || waiting === 'merged' || waiting === 'completed') {
    return 'green'
  }

  if (NEEDS_US.has(waiting)) {
    return 'red'
  }

  return 'yellow'
}

const votesText = (votes: Record<string, string>) =>
  Object.entries(votes)
    .map(([reviewer, vote]) => `${reviewer.split(' ')[0]} ${vote}`)
    .join(', ')

let loadedAt = 0

// The session-start check (pr-watch's session.sh) records what it finds a little later, so the
// band's count is read again from that record after a turn, at most every few minutes.
const reloadCached = async ($: EngineInterface) => {
  const now = await $.clock.now()

  if (now - loadedAt >= RELOAD_EVERY_MS) {
    loadedAt = now
    await load($, false)
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: COMMAND,
      description: 'Show the tracked PRs (pr-watch) and refresh them: status, CI, what each waits for',
    })
    void reloadCached($)

    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    void reloadCached($)

    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const beneath = await next(e)
    const prs = (await read($, snapshot))?.prs ?? []

    if (e.props.hasSurvey || e.props.view.agentId !== undefined || prs.length === 0) {
      return beneath
    }

    const { Box, Button } = $.ui.resolve(e)
    const needsUs = prs.some(pr => NEEDS_US.has(pr.waiting))

    return (
      <Box flexDirection="row" justifyContent="space-between" alignItems="flex-start">
        <Box flexDirection="column" flexShrink={1}>
          {beneath}
        </Box>
        <Button
          key="prs"
          label={`PRs ${prs.length}${needsUs ? ' !' : ''}`}
          variant={needsUs ? 'primary' : undefined}
          dimColor={!needsUs}
          onPress={() => void openPane($)}
        />
      </Box>
    )
  })

  on('command.run', { command: COMMAND }, async $ => {
    await openPane($)

    return { text: 'Tracked PRs pane opened.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Link, Text } = $.ui.resolve(e)
    const shown = await read($, snapshot)
    const busy = await read($, isRefreshing)
    const trouble = await read($, problem)
    const width = Math.max(20, e.props.bodyColumns - 2)
    const prs = shown?.prs ?? []
    const summary =
      shown === null
        ? 'Loading…'
        : `${prs.length} PR${prs.length === 1 ? '' : 's'} · ${shown.isLive ? 'live at' : 'last check, read at'} ${shown.at}`

    return (
      <Box flexDirection="column">
        <Box flexDirection="row" justifyContent="space-between">
          <Text dimColor>{summary}</Text>
          <Button
            key="refresh"
            label={busy ? 'refreshing…' : 'refresh'}
            hotkey="r"
            dimColor={busy}
            onPress={() => void refresh($)}
          />
        </Box>
        {trouble !== '' && <Text color="red">{truncate(trouble, width)}</Text>}
        {shown?.errors.map(line => (
          <Text color="red">{truncate(line, width)}</Text>
        ))}
        {shown !== null && prs.length === 0 && <Text dimColor>No PR tracked. Ask Claude to watch one.</Text>}
        {prs.map(pr => (
          <Box key={`pr-${pr.repo}-${pr.number}`} flexDirection="column" marginTop={1}>
            <Box flexDirection="row" justifyContent="space-between">
              <Text bold>
                <Link href={pr.url} label={truncate(`${pr.repo} #${pr.number}`, width - 8)} />
              </Text>
              <Button key={`open-${pr.repo}-${pr.number}`} label="open" dimColor onPress={() => void openPr($, pr.url)} />
            </Box>
            <Text>{truncate(pr.title, width)}</Text>
            <Text>
              <Text dimColor>waits for </Text>
              <Text color={waitingColor(pr.waiting)}>{pr.waiting}</Text>
            </Text>
            <Text dimColor>
              {truncate([pr.status, pr.ci, votesText(pr.votes), pr.note].filter(part => part !== '').join(' · '), width)}
            </Text>
            {pr.changes.map(change => (
              <Text color="cyan">{truncate(`• ${change}`, width)}</Text>
            ))}
          </Box>
        ))}
      </Box>
    )
  })
}
