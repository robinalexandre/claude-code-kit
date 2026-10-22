import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Answer, RecentPrompt } from '../types'

const PANE = 'my-messages'
const TITLE = 'My messages'
const COMMAND = 'prompts'
const BAND_COUNT = 2
const KEPT = 1000
const WAITING_KEPT = 20
const ANSWERS_KEPT = 40
const ANSWER_CHARS = 20_000
const JUMP_ICON = '↗'
// Under the pointer, what folds turns to the theme's suggestion color with the text drawn on it in
// the theme's inverse text color: readable in a light and a dark theme alike.
const LIT_BOX = { backgroundColor: 'suggestion' }
const LIT_TEXT = { color: 'inverseText', dimColor: false }
// At the end of a line that folds others: unfold everything under it, or fold it all back.
const UNFOLD_ALL = '▾ all'
const FOLD_ALL = '▴ all'

// The band's buttons share one row under everything above the prompt, whatever order the mods
// draw in: each takes that row out of what the mods beneath drew, adds its own button, and sorts
// them by key (band-1-history, band-2-prs, band-3-reminders).
const BAND_ROW = 'band-buttons'

type Drawn = { type?: string; props?: { key?: string }; children?: unknown[] }

const keyOf = (node: unknown) => (node !== null && typeof node === 'object' ? ((node as Drawn).props?.key ?? '') : '')

const byBandKey = (one: unknown, other: unknown) => keyOf(one).localeCompare(keyOf(other))

const takeBandRow = (tree: unknown): { rest: unknown; buttons: unknown[] } => {
  if (Array.isArray(tree)) {
    let buttons: unknown[] = []
    const rest = tree.map(child => {
      if (buttons.length > 0) {
        return child
      }

      const taken = takeBandRow(child)
      buttons = taken.buttons

      return taken.rest
    })

    // The engine reads every child of a drawn tree: the row taken out leaves no hole.
    return { rest: rest.filter(child => child !== null && child !== undefined), buttons }
  }

  const node = tree as Drawn | null

  if (node === null || typeof node !== 'object' || !Array.isArray(node.children)) {
    return { rest: tree, buttons: [] }
  }

  if (node.props?.key === BAND_ROW) {
    return { rest: null, buttons: node.children.flat(Infinity) }
  }

  const taken = takeBandRow(node.children)

  return taken.buttons.length > 0 ? { rest: { ...node, children: taken.rest }, buttons: taken.buttons } : { rest: tree, buttons: [] }
}

const prompts = atom({ plugin: 'recent-prompts', key: 'prompts' } as const, [])
const query = atom({ plugin: 'recent-prompts', key: 'query' } as const, '')
const waiting = atom({ plugin: 'recent-prompts', key: 'waiting' } as const, [])
const unfolded = atom({ plugin: 'recent-prompts', key: 'unfolded' } as const, {})

type Block = { type: string; [field: string]: unknown }
type Shown = { before: string; match: string; after: string }

// A plugin's prompt is sent for the person: a button they pressed in a pane, such as a reminder's pick.
const isPerson = (kind: string) => kind === 'composer' || kind === 'bridge' || kind === 'plugin'

const flatten = (text: string) => text.replace(/\s+/g, ' ').trim()

const textOf = (blocks: Block[]) => blocks.flatMap(block => (typeof block.text === 'string' ? [block.text] : [])).join('\n')

const clockTime = (milliseconds: number) => {
  const date = new Date(milliseconds)

  return [date.getHours(), date.getMinutes()].map(part => String(part).padStart(2, '0')).join(':')
}

const remember = async ($: EngineInterface, id: string, text: string, kind?: 'learn') => {
  const prompt: RecentPrompt = { id, text, time: clockTime(await $.clock.now()), ...(kind ? { kind } : {}) }
  await update($, prompts, list => [...list, prompt].slice(-KEPT))
}

// What follows the "💡 Learn:" heading Claude ends a reply with when the learn mod asks it to.
const LEARN = /💡\s*\**\s*Learn\b\s*:?\**\s*([\s\S]+)$/

const isMessage = (prompt: RecentPrompt) => prompt.kind !== 'learn'

// A reply goes under the person's last message: the replies of a turn all answer it.
const keepAnswer = async ($: EngineInterface, id: string, text: string) => {
  const answer: Answer = { id, text: text.slice(0, ANSWER_CHARS), time: clockTime(await $.clock.now()) }
  await update($, prompts, list => {
    const at = list.map(isMessage).lastIndexOf(true)
    const prompt = list[at]

    if (prompt === undefined) {
      return list
    }

    const answers = [...(prompt.answers ?? []), answer].slice(-ANSWERS_KEPT)

    return [...list.slice(0, at), { ...prompt, answers }, ...list.slice(at + 1)]
  })
}

// A line cut into lines of at most WIDTH columns, at a space when one is near the end.
const wrap = (line: string, width: number): string[] => {
  const lines: string[] = []
  let rest = line
  while (width > 0 && rest.length > width) {
    const space = rest.lastIndexOf(' ', width)
    const cut = space > width / 2 ? space : width
    lines.push(rest.slice(0, cut).trimEnd())
    rest = rest.slice(cut).trimStart()
  }
  return [...lines, rest]
}

// A text as the pane's lines: its own line breaks kept, runs of blank lines made one, long lines wrapped.
const paragraphs = (text: string, width: number) =>
  text
    .split(/\r?\n/)
    .map(line => line.replace(/[\x00-\x1f\x7f]/g, ' ').trimEnd())
    .filter((line, index, all) => line !== '' || (index > 0 && all[index - 1] !== ''))
    .flatMap(line => wrap(line, width))

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

// Buttons holding styled Text draw from 2.1.306 on; an older build, or a version that cannot be
// read, gets plain labels.
const STYLED_SINCE = [2, 1, 306]

let styledFound: boolean | undefined

const isStyled = async ($: EngineInterface) => {
  if (styledFound === undefined) {
    try {
      const parts = ((await $.session.version()).base ?? '').replace(/-.*$/, '').split('.').map(Number)
      const at = parts.findIndex((part, index) => part !== STYLED_SINCE[index])

      styledFound = parts.length === 3 && parts.every(Number.isInteger) && (at === -1 || (parts[at] ?? 0) > (STYLED_SINCE[at] ?? 0))
    } catch {
      styledFound = false
    }
  }

  return styledFound
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

const registerCommand = ($: EngineInterface) =>
  $.command.register({ name: COMMAND, description: 'Open or close the searchable list of your messages' }).catch(() => undefined)

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    styledFound = undefined
    await registerCommand($)

    return next(e)
  })

  // A /clear starts a fresh session without a session.start: its history starts empty.
  on('session.end', async ($, e, next) => {
    const ended = await next(e)

    if (e.reason === 'clear') {
      $.clock.after(0, () => {
        void update($, prompts, () => [])
        void update($, waiting, () => [])
        void update($, unfolded, () => ({}))
        void registerCommand($)
      })
    }

    return ended
  })

  on('command.run', { command: COMMAND }, async $ => ({ text: `My messages pane ${await toggleHistory($)}.` }))

  // A message typed while a turn runs is stored later, wrapped in the engine's framing, as a queued_command
  // attachment (through the delivery door when absorbed mid-turn); a plugin's prompt is stored wrapped
  // too, even between turns. Its text is kept at submit so that row can be told apart and listed as sent.
  on('prompt.submit', async ($, e, next) => {
    if ((e.turnId !== undefined || e.origin.kind === 'plugin') && isPerson(e.origin.kind) && e.text.trim() !== '') {
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
    const sent =
      e.origin.kind === 'plugin' ? (await read($, waiting)).find(one => flatten(textOf(blocks)).includes(flatten(one))) : undefined
    const text = sent ?? (typeof first?.text === 'string' ? first.text : '')

    if (text.trim() !== '') {
      await update($, waiting, list => withoutFirst(list, text))
      await remember($, stored.uuid, text)
    }

    return stored
  }).catch(($, e, next) => next(e))

  // A lesson is kept between the messages, where it was given, so the history can find it again.
  on('session.append', { door: 'response' }, async ($, e, next) => {
    const stored = await next(e)

    if (stored.uuid === undefined || e.agentId !== undefined) {
      return stored
    }

    // Only the text Claude wrote to the person: tool calls, their results and thinking are left out.
    const text = textOf(stored.message.content.filter((block: Block) => block.type === 'text')).trim()

    if (text !== '') {
      await keepAnswer($, stored.uuid, text)
    }

    const lesson = text.match(LEARN)?.[1]?.trim() ?? ''

    if (lesson !== '') {
      await remember($, stored.uuid, lesson, 'learn')
    }

    return stored
  }).catch(($, e, next) => next(e))

  for (const door of ['attachment', 'delivery'] as const) {
    on('session.append', { door }, async ($, e, next) => {
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
  }

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const beneath = await next(e)

    if (e.props.hasSurvey || e.props.view.agentId !== undefined) {
      return beneath
    }

    const recent = (await read($, prompts)).filter(isMessage).slice(-BAND_COUNT)
    const { Box, Button, Text } = $.ui.resolve(e)
    const width = Math.max(10, e.props.bodyColumns - 4)

    const { rest, buttons } = takeBandRow(beneath)
    const mine = (
      <Box key="band-1-history" flexDirection="row">
        <Button key="history" label="history" dimColor onPress={() => void toggleHistory($)} />
      </Box>
    )

    return (
      <Box flexDirection="column">
        {recent.map((prompt, index) => (
          <Box key={`band-${index}`} flexDirection="row">
            <Text color="cyan">❯ </Text>
            <Button
              key={`prompt-${index}`}
              label={truncate(flatten(prompt.text), width)}
              plain
              dimColor
              onPress={() => void jump($, prompt.id)}
            />
          </Box>
        ))}
        {rest as never}
        <Box key={BAND_ROW} flexDirection="row" gap={2}>
          {[...buttons, mine].sort(byBandKey) as never}
        </Box>
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
    const open = await read($, unfolded)
    const toggle = (id: string) => void update($, unfolded, all => ({ ...all, [id]: !(all[id] ?? false) }))
    const styled = await isStyled($)
    // What folds lights up under the pointer, the jump arrow left out as it does something else.
    // What a line leaves for its text: the jump arrow, the fold arrow and the time take 10 columns,
    // the control that unfolds its replies six more, a lesson's 💡 three more.
    const width = Math.max(10, e.props.bodyColumns - 12)
    const rows = list.flatMap(prompt => {
      const shown = shownLine(prompt.text, search, width - 6 - (isMessage(prompt) ? 0 : 3))

      return shown === null ? [] : [{ prompt, shown }]
    })
    const setQuery = (value: string) => void update($, query, () => value)
    const messages = list.filter(isMessage).length
    const lessons = list.length - messages
    const counted = `${messages} messages${lessons > 0 ? `, ${lessons} 💡` : ''}`
    const summary = search.trim() === '' ? counted : `${rows.length} of ${list.length} match`

    // A message's line and its replies fold together: a reply open folds them back, all folded
    // unfolds them all. The button beside the count does it for every line listed, the lines too.
    const foldsOf = (prompt: RecentPrompt) => [prompt.id, ...(prompt.answers ?? []).map(answer => answer.id)]
    const isOpenId = (id: string) => open[id] ?? false
    const setFolds = (ids: string[], isOpen: boolean) =>
      void update($, unfolded, all => ({ ...all, ...Object.fromEntries(ids.map(id => [id, isOpen])) }))
    const listed = rows.flatMap(({ prompt }) => foldsOf(prompt))
    const isListOpen = rows.some(({ prompt }) => isOpenId(prompt.id))

    // Drawn in the accent color where the build styles a button's text, named in words for a reader.
    const foldAllControl = (key: string, isOpen: boolean, drawn: string, onPress: () => void) =>
      styled ? (
        <Button key={key} label={isOpen ? 'collapse all' : 'expand all'} onPress={onPress}>
          <Text color="suggestion">{drawn}</Text>
        </Button>
      ) : (
        <Button key={key} label={drawn} onPress={onPress} />
      )

    // A line's text folds and unfolds it, as its arrow does; a build that draws no styled button
    // gets the plain label.
    const foldText = (key: string, plainLabel: string, styledText: unknown, onPress: () => void, dimColor = false) =>
      styled ? (
        <Button key={key} plain hover={LIT_TEXT} onPress={onPress}>
          <Text dimColor={dimColor} hover={LIT_TEXT}>
            {styledText as never}
          </Text>
        </Button>
      ) : (
        <Button key={key} label={plainLabel} plain dimColor={dimColor} hover={LIT_TEXT} onPress={onPress} />
      )

    // An unfolded line: the full message (or lesson), then each reply, folded to its first line
    // until opened.
    const details = (prompt: RecentPrompt) => (
      <Box key={`details-${prompt.id}`} flexDirection="column" paddingLeft={4}>
        {paragraphs(prompt.text, width - 2).map((line, index) => (
          <Text key={`text-${prompt.id}-${index}`} color={isMessage(prompt) ? 'cyan' : 'yellow'}>
            {line || ' '}
          </Text>
        ))}
        {isMessage(prompt) && (prompt.answers ?? []).length === 0 && <Text dimColor>No reply yet.</Text>}
        {(prompt.answers ?? []).map(answer => {
          const isAnswerOpen = open[answer.id] ?? false
          const label = `${answer.time ?? '--:--'} ${isAnswerOpen ? 'Claude' : truncate(flatten(answer.text), width - 6)}`

          return (
            <Box key={`answer-${answer.id}`} flexDirection="column">
              <Box flexDirection="row">
                <Button key={`answer-jump-${answer.id}`} label={JUMP_ICON} plain dimColor onPress={() => void jump($, answer.id)} />
                <Text> </Text>
                <Box key={`answer-line-${answer.id}`} flexDirection="row" hover={LIT_BOX}>
                  <Button key={`answer-toggle-${answer.id}`} label={isAnswerOpen ? '▾' : '▸'} plain hover={LIT_TEXT} onPress={() => toggle(answer.id)} />
                  <Text hover={LIT_TEXT}> </Text>
                  {foldText(`answer-text-${answer.id}`, label, label, () => toggle(answer.id), true)}
                </Box>
              </Box>
              {isAnswerOpen &&
                paragraphs(answer.text, width - 6).map((line, index) => (
                  <Box key={`reply-${answer.id}-${index}`} paddingLeft={2}>
                    <Text>{line || ' '}</Text>
                  </Box>
                ))}
            </Box>
          )
        })}
      </Box>
    )

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
        <Box flexDirection="row" justifyContent="space-between">
          <Text dimColor>{summary}</Text>
          {listed.length > 0 &&
            foldAllControl('fold-all', isListOpen, isListOpen ? '▴ collapse all' : '▾ expand all', () => setFolds(listed, !isListOpen))}
        </Box>
        {rows.map(({ prompt, shown }) => {
          const isOpen = open[prompt.id] ?? false
          const isLesson = prompt.kind === 'learn'
          const folds = foldsOf(prompt)
          const hasOpenReply = isOpen && folds.slice(1).some(isOpenId)

          return (
            <Box key={`entry-${prompt.id}`} flexDirection="column">
              <Box flexDirection="row" justifyContent="space-between">
                <Box flexDirection="row">
                  <Button key={`row-${prompt.id}`} label={JUMP_ICON} plain dimColor onPress={() => void jump($, prompt.id)} />
                  <Text> </Text>
                  <Box key={`line-${prompt.id}`} flexDirection="row" hover={LIT_BOX}>
                    <Button key={`toggle-${prompt.id}`} label={isOpen ? '▾' : '▸'} plain hover={LIT_TEXT} onPress={() => toggle(prompt.id)} />
                    <Text dimColor hover={LIT_TEXT}>
                      {' '}
                      {prompt.time ?? '--:--'}{' '}
                    </Text>
                    {foldText(
                      `text-${prompt.id}`,
                      `${isLesson ? '💡 ' : ''}${shown.before}${shown.match}${shown.after}`,
                      [
                        isLesson && (
                          <Text color="yellow" hover={LIT_TEXT}>
                            💡{' '}
                          </Text>
                        ),
                        <Text color={isLesson ? 'yellow' : undefined} dimColor={isLesson} hover={LIT_TEXT}>
                          {shown.before}
                        </Text>,
                        shown.match !== '' && (
                          <Text color="yellow" bold hover={LIT_TEXT}>
                            {shown.match}
                          </Text>
                        ),
                        <Text color={isLesson ? 'yellow' : undefined} dimColor={isLesson} hover={LIT_TEXT}>
                          {shown.after}
                        </Text>,
                      ],
                      () => toggle(prompt.id)
                    )}
                  </Box>
                </Box>
                {folds.length > 1 &&
                  foldAllControl(`all-${prompt.id}`, hasOpenReply, hasOpenReply ? FOLD_ALL : UNFOLD_ALL, () =>
                    setFolds(hasOpenReply ? folds.slice(1) : folds, !hasOpenReply)
                  )}
              </Box>
              {isOpen && details(prompt)}
            </Box>
          )
        })}
      </Box>
    )
  })
}
