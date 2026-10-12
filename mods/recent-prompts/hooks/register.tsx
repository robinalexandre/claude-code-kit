import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { RecentPrompt } from '../types'

const PANE = 'my-messages'
const TITLE = 'My messages'
const COMMAND = 'prompts'
const BAND_COUNT = 2
const KEPT = 1000
const WAITING_KEPT = 20
const HISTORY_BUTTON_WIDTH = 12

const prompts = atom({ plugin: 'recent-prompts', key: 'prompts' } as const, [])
const query = atom({ plugin: 'recent-prompts', key: 'query' } as const, '')
const waiting = atom({ plugin: 'recent-prompts', key: 'waiting' } as const, [])

type Block = { type: string; [field: string]: unknown }
type Shown = { before: string; match: string; after: string }

const isPerson = (kind: string) => kind === 'composer' || kind === 'bridge'

const flatten = (text: string) => text.replace(/\s+/g, ' ').trim()

const textOf = (blocks: Block[]) => blocks.flatMap(block => (typeof block.text === 'string' ? [block.text] : [])).join('\n')

const clockTime = (milliseconds: number) => {
  const date = new Date(milliseconds)

  return [date.getHours(), date.getMinutes()].map(part => String(part).padStart(2, '0')).join(':')
}

const remember = async ($: EngineInterface, id: string, text: string) => {
  const prompt: RecentPrompt = { id, text, time: clockTime(await $.clock.now()) }
  await update($, prompts, list => [...list, prompt].slice(-KEPT))
}

const withoutFirst = (list: string[], text: string) => {
  const at = list.indexOf(text)

  return at < 0 ? list : [...list.slice(0, at), ...list.slice(at + 1)]
}

// Folds one UTF-16 unit at a time so indexes in the folded text match the original.
const fold = (text: string) =>
  text
    .split('')
    .map(unit => unit.normalize('NFD').charAt(0).toLowerCase())
    .join('')

const truncate = (text: string, width: number) =>
  text.length > width ? `${text.slice(0, Math.max(0, width - 1))}…` : text

const shownLine = (text: string, search: string, width: number): Shown | null => {
  const flat = flatten(text)
  const needle = fold(search.trim())

  if (needle === '') {
    return { before: truncate(flat, width), match: '', after: '' }
  }

  const at = fold(flat).indexOf(needle)

  if (at < 0) {
    return null
  }

  const start = at + needle.length < width ? 0 : Math.min(at, Math.max(1, at - Math.floor((width - needle.length) / 3)))
  const prefix = start > 0 ? '…' : ''
  const room = width - prefix.length
  const isCut = flat.length - start > room
  const end = isCut ? start + room - 1 : flat.length
  const matchEnd = Math.min(end, at + needle.length)

  return {
    before: prefix + flat.slice(start, at),
    match: flat.slice(at, matchEnd),
    after: flat.slice(matchEnd, end) + (isCut ? '…' : ''),
  }
}

const jump = async ($: EngineInterface, id: string) => {
  const { deny } = await $.ui.scroll({ to: { requestId: id }, block: 'start' })

  if (deny !== undefined) {
    $.ui.toast(`Can't jump to that message: ${deny}`)
  }
}

const toggleHistory = async ($: EngineInterface) => {
  const isOpen = (await $.ui.panes()).some(pane => pane.id === PANE)

  if (isOpen) {
    await $.ui.close({ id: PANE })

    return 'closed'
  }

  await $.ui.open({ id: PANE, title: TITLE, focus: true, columns: 56 })
  await $.ui.scroll({ in: PANE, to: 'end' })

  return 'opened'
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: COMMAND, description: 'Open or close the searchable list of your messages' })

    return next(e)
  })

  on('command.run', { command: COMMAND }, async $ => ({ text: `My messages pane ${await toggleHistory($)}.` }))

  // A message typed while a turn runs is stored later, wrapped in the engine's framing, as a queued_command
  // attachment; its text is kept at Enter so that row can be told apart and listed as typed.
  on('prompt.submit', async ($, e, next) => {
    if (e.turnId !== undefined && isPerson(e.origin.kind) && e.text.trim() !== '') {
      await update($, waiting, list => [...list, e.text].slice(-WAITING_KEPT))
    }

    return next(e)
  }).catch(($, e, next) => next(e))

  on('session.append', { door: 'prompt' }, async ($, e, next) => {
    const stored = await next(e)

    if (!isPerson(e.origin.kind) || e.agentId !== undefined || stored.uuid === undefined) {
      return stored
    }

    const blocks: Block[] = stored.message.content
    const first = blocks.find(block => block.type === 'text')
    const text = typeof first?.text === 'string' ? first.text : ''

    if (text.trim() !== '') {
      await update($, waiting, list => withoutFirst(list, text))
      await remember($, stored.uuid, text)
    }

    return stored
  }).catch(($, e, next) => next(e))

  on('session.append', { door: 'attachment' }, async ($, e, next) => {
    const stored = await next(e)

    if (stored.uuid === undefined || stored.message.name !== 'queued_command' || e.agentId !== undefined) {
      return stored
    }

    const shown = flatten(textOf(stored.message.content))
    const typed = (await read($, waiting)).find(text => shown.includes(flatten(text)))

    if (typed !== undefined) {
      await update($, waiting, list => withoutFirst(list, typed))
      await remember($, stored.uuid, typed)
    }

    return stored
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const beneath = await next(e)

    if (e.props.hasSurvey || e.props.view.agentId !== undefined) {
      return beneath
    }

    const recent = (await read($, prompts)).slice(-BAND_COUNT)

    if (recent.length === 0) {
      return beneath
    }

    const { Box, Button, Text } = $.ui.resolve(e)
    const width = Math.max(10, e.props.bodyColumns - 2 - HISTORY_BUTTON_WIDTH)

    return (
      <Box flexDirection="column">
        {recent.map((prompt, index) => (
          <Box key={`band-${index}`} flexDirection="row" justifyContent="space-between">
            <Box flexDirection="row">
              <Text color="cyan">❯ </Text>
              <Button
                key={`prompt-${index}`}
                label={truncate(flatten(prompt.text), width)}
                plain
                dimColor
                onPress={() => void jump($, prompt.id)}
              />
            </Box>
            {index === recent.length - 1 && (
              <Button key="history" label="history" dimColor onPress={() => void toggleHistory($)} />
            )}
          </Box>
        ))}
        {beneath}
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    if (e.surface !== 'terminal') {
      return next(e)
    }

    const { Box, Button, Input, Text } = $.ui.resolve(e)
    const list = await read($, prompts)
    const search = await read($, query)
    const width = Math.max(10, e.props.bodyColumns - 6)
    const rows = list.flatMap(prompt => {
      const shown = shownLine(prompt.text, search, width)

      return shown === null ? [] : [{ prompt, shown }]
    })
    const setQuery = (value: string) => void update($, query, () => value)
    const summary = search.trim() === '' ? `${list.length} messages` : `${rows.length} of ${list.length} match`

    return (
      <Box flexDirection="column">
        <Input
          key="search"
          label="Search "
          placeholder="words from your messages"
          value={search}
          submitLabel="filter"
          autoFocus
          onInput={setQuery}
          onSubmit={setQuery}
        />
        <Text dimColor>{summary}</Text>
        {rows.map(({ prompt, shown }) => (
          <Box key={`line-${prompt.id}`} flexDirection="row">
            <Text dimColor>{prompt.time ?? '--:--'} </Text>
            <Button
              key={`row-${prompt.id}`}
              label={shown.before + shown.match + shown.after}
              plain
              onPress={() => void jump($, prompt.id)}
            />
          </Box>
        ))}
      </Box>
    )
  })
}
