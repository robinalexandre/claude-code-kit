import { atom, read, update } from 'claude-code'
import type { EngineInterface, PluginOptions, Register, SessionMessage } from 'claude-code'

import type { Answer, AnswerKind, RecentPrompt } from '../types'

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

// The hover group a fold-all control lights, named after its key.
const foldScope = (key: string) => `fold:${key}`.replace(/[\x00-\x1f\x7f]/g, ' ').slice(0, 64)

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
// The do-not-disturb profile on now, when the dnd mod is installed: one can hide the history. Read
// under dnd's shape: another one (an older or newer dnd) reads as nothing on.
const dndActive = atom({ plugin: 'dnd', key: 'active' } as const, null, { shape: 'dnd-active/1' })

const dndHiding = async ($: EngineInterface) => {
  const on = await read($, dndActive)

  return on?.profile && on.parts?.history?.mode === 'hide' ? on.profile : ''
}

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

const remember = async ($: EngineInterface, id: string, text: string, kind?: RecentPrompt['kind']) => {
  const prompt: RecentPrompt = { id, text, time: clockTime(await $.clock.now()), ...(kind ? { kind } : {}) }
  await update($, prompts, list => [...list, prompt].slice(-KEPT))
}

// What follows the "💡 Learn:" heading Claude ends a reply with when the learn mod asks it to.
const LEARN = /💡\s*\**\s*Learn\b\s*:?\**\s*([\s\S]+)$/

const isMessage = (prompt: RecentPrompt) => prompt.kind !== 'learn'

const answerTo = (list: RecentPrompt[], answer: Answer) => {
  const at = list.map(isMessage).lastIndexOf(true)
  const prompt = list[at]

  if (prompt === undefined) {
    return list
  }

  const answers = [...(prompt.answers ?? []), { ...answer, text: answer.text.slice(0, ANSWER_CHARS) }].slice(-ANSWERS_KEPT)

  return [...list.slice(0, at), { ...prompt, answers }, ...list.slice(at + 1)]
}

// A reply goes under the person's last message: the replies of a turn all answer it.
const keepAnswer = async ($: EngineInterface, id: string, text: string, kind?: AnswerKind) => {
  const time = clockTime(await $.clock.now())
  await update($, prompts, list => answerTo(list, { id, text, time, ...(kind ? { kind } : {}) }))
}

// Which replies besides plain text the person chose to keep (the manifest's userConfig).
type Keep = { questions: boolean; plans: boolean; files: boolean; notifications: boolean; commands: boolean }

const keepOf = (options: PluginOptions): Keep => ({
  questions: options.questions !== false,
  plans: options.plans !== false,
  files: options.files === true,
  notifications: options.notifications === true,
  commands: options.commands !== false,
})

const stringOf = (value: unknown) => (typeof value === 'string' ? value : '')

const listOf = (value: unknown): unknown[] => (Array.isArray(value) ? value : [])

// A tool call that speaks to the person, as the reply it stands for; undefined for any other.
const toolAnswer = (tool: string, input: Record<string, unknown>, keep: Keep): { kind: AnswerKind; text: string } | undefined => {
  if (tool === 'AskUserQuestion' && keep.questions) {
    const questions = listOf(input.questions).map(question => {
      const asked = (question ?? {}) as Record<string, unknown>
      const options = listOf(asked.options).map(option => `  · ${stringOf((option as Record<string, unknown>)?.label)}`)

      return [stringOf(asked.question), ...options].join('\n')
    })

    return { kind: 'question', text: questions.join('\n\n') }
  }

  if (tool === 'ExitPlanMode' && keep.plans && stringOf(input.plan) !== '') {
    return { kind: 'plan', text: stringOf(input.plan) }
  }

  if (tool === 'SendUserFile' && keep.files) {
    return { kind: 'file', text: [stringOf(input.caption), ...listOf(input.files).map(stringOf)].filter(Boolean).join('\n') }
  }

  if (tool === 'PushNotification' && keep.notifications && stringOf(input.message) !== '') {
    return { kind: 'notification', text: stringOf(input.message) }
  }

  return undefined
}

// The picker's result reads `The user answered: "question"="pick", ...`: each pick under its question.
const pickText = (result: string) => {
  const picks = [...result.matchAll(/"((?:[^"\\]|\\.)*)"="((?:[^"\\]|\\.)*)"/g)].map(([, question, pick]) => `${question}\n→ ${pick}`)

  return picks.length > 0 ? picks.join('\n\n') : result.trim()
}

const resultText = (block: Block) =>
  typeof block.content === 'string' ? block.content : textOf(listOf(block.content) as Block[])

const PICK = '#pick'

const ANSWER_WORDS: Record<AnswerKind, string> = {
  question: 'asked',
  pick: 'you picked',
  plan: 'plan',
  file: 'sent you',
  notification: 'notified',
  output: 'output',
}

const tagged = (text: string, tag: string) => text.match(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`))?.[1]?.trim()

// A slash command's record (`<command-name>/x</command-name>…<command-args>a</command-args>`) as typed: `/x a`.
const commandLine = (text: string) => {
  const name = tagged(text, 'command-name')

  return name === undefined ? undefined : [name, tagged(text, 'command-args') ?? ''].join(' ').trim()
}

// What a command printed, its terminal colors taken out; "(no content)" is nothing.
const commandOutput = (text: string) => {
  const printed = [tagged(text, 'local-command-stdout'), tagged(text, 'local-command-stderr')]
    .filter((part): part is string => part !== undefined)
    .join('\n')
    .replace(/\x1b\[[0-9;]*m/g, '')
    .trim()

  return printed === '(no content)' ? '' : printed
}

const REBUILT = 'rebuilt-'

// What a transcript row of the person's side is, read back without the flags its row had: a
// message, a command, a command's output, or engine framing to leave out.
type ReadBack = { message: string; kind?: 'command' } | { output: string } | undefined

const readUser = (text: string, keep: Keep): ReadBack => {
  const trimmed = text.trim()
  const command = commandLine(trimmed)

  if (command !== undefined) {
    return keep.commands ? { message: command, kind: 'command' } : undefined
  }

  if (/<local-command-(stdout|stderr)>/.test(trimmed)) {
    const output = commandOutput(trimmed)

    return keep.commands && output !== '' ? { output } : undefined
  }

  const queued = trimmed.match(/The user sent a new message while you were working:\n([\s\S]*?)\n\n(?:Address|IMPORTANT)/)?.[1]
  const sent = trimmed.match(/^The \S+ plugin sent a message:\n([\s\S]*?)\n\nAddress the message above/)?.[1]

  if (queued !== undefined || sent !== undefined) {
    return { message: (queued ?? sent ?? '').trim() }
  }

  const isFraming =
    trimmed === '' ||
    /^<(system-reminder|task-notification|local-command-caveat|user-prompt-submit-hook)\b/.test(trimmed) ||
    /^(Base directory for this skill:|This session is being continued from a previous conversation|\[Request interrupted)/.test(trimmed)

  return isFraming ? undefined : { message: trimmed }
}

// The history as the transcript holds it, for a session whose stored history missed some of it:
// one resumed, or one whose replies came before this mod kept them. The rows carry no ids, so
// what comes from a plain row cannot be jumped to; a tool call's reply keeps its call's id.
const readBack = (rows: SessionMessage[], keep: Keep) =>
  rows.reduce<RecentPrompt[]>((list, row, index) => {
    const id = `${REBUILT}${index}`

    if (row.role === 'user') {
      const found = readUser(row.text, keep)

      if (found === undefined) {
        return list
      }

      return 'output' in found
        ? answerTo(list, { id, text: found.output, kind: 'output' })
        : [...list, { id, text: found.message, ...(found.kind ? { kind: found.kind } : {}) }]
    }

    const text = row.text.trim()
    const lesson = text.match(LEARN)?.[1]?.trim() ?? ''
    const answered = text === '' ? list : answerTo(list, { id, text })
    const withTools = row.toolUses.reduce((all, use) => {
      const answer = toolAnswer(use.tool, use.input, keep)

      if (answer === undefined) {
        return all
      }

      const asked = answerTo(all, { id: use.tool_use_id, ...answer })

      return use.tool === 'AskUserQuestion' && use.text !== undefined
        ? answerTo(asked, { id: `${use.tool_use_id}${PICK}`, text: pickText(use.text), kind: 'pick' })
        : asked
    }, answered)

    return lesson === '' ? withTools : [...withTools, { id: `${id}-learn`, text: lesson, kind: 'learn' }]
  }, [])

// Two replies are one when either's text holds the other's: the transcript may join a response's
// text blocks the session stored one by one.
const isSameAnswer = (one: Answer, other: Answer) => {
  const [a, b] = [flatten(one.text), flatten(other.text)]

  return a !== '' && b !== '' && (a.includes(b) || b.includes(a))
}

const mergeAnswers = (stored: Answer[], found: Answer[]) => {
  const used = new Set<Answer>()
  const merged = found.map(answer => {
    const same = stored.find(one => !used.has(one) && isSameAnswer(one, answer))

    if (same === undefined) {
      return answer
    }

    used.add(same)

    return same
  })

  return [...merged, ...stored.filter(one => !used.has(one))].slice(-ANSWERS_KEPT)
}

// What was read back joins what is stored: an empty history takes it whole; otherwise each stored
// message, matched in order by its text, gains the replies it missed, and nothing stored is lost.
const merge = (stored: RecentPrompt[], found: RecentPrompt[]) => {
  if (!stored.some(isMessage)) {
    return [...found, ...stored].slice(-KEPT)
  }

  let from = 0

  return stored.map(prompt => {
    if (!isMessage(prompt)) {
      return prompt
    }

    const at = found.findIndex((one, index) => index >= from && isMessage(one) && flatten(one.text) === flatten(prompt.text))

    if (at < 0) {
      return prompt
    }

    from = at + 1
    const answers = mergeAnswers(prompt.answers ?? [], found[at]?.answers ?? [])

    return answers.length > 0 ? { ...prompt, answers } : prompt
  })
}

const rebuild = async ($: EngineInterface, keep: Keep) => {
  const found = readBack(await $.session.messages(), keep)

  if (found.length > 0) {
    await update($, prompts, list => merge(list, found))
  }
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
  if (id.startsWith(REBUILT)) {
    $.ui.toast("Can't jump to that message: it was read back from the transcript, which keeps no place for it.")

    return
  }

  const { deny } = await $.ui.scroll({ to: { requestId: id.replace(PICK, '') }, block: 'start' })

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

export const register: Register = (on, options) => {
  const keep = keepOf(options)

  // A start runs again on a resume and on each reload of this module: what the history missed
  // meanwhile is read back from the transcript.
  on('session.start', async ($, e, next) => {
    styledFound = undefined
    await registerCommand($)
    $.clock.after(0, () => void rebuild($, keep).catch(() => undefined))

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
    const command = commandLine(text)

    if (command !== undefined) {
      if (keep.commands) {
        await remember($, stored.uuid, command, 'command')
      }
    } else if (text.trim() !== '') {
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

    // Only what Claude said to the person: the text, and the tool calls that speak to the person
    // when kept; the other calls, their results and thinking are left out.
    const blocks: Block[] = stored.message.content
    const text = textOf(blocks.filter(block => block.type === 'text')).trim()

    if (text !== '') {
      await keepAnswer($, stored.uuid, text)
    }

    for (const block of blocks.filter(one => one.type === 'tool_use')) {
      const answer = toolAnswer(stringOf(block.name), (block.input ?? {}) as Record<string, unknown>, keep)

      if (answer !== undefined && typeof block.id === 'string') {
        await keepAnswer($, block.id, answer.text, answer.kind)
      }
    }

    const lesson = text.match(LEARN)?.[1]?.trim() ?? ''

    if (lesson !== '') {
      await remember($, stored.uuid, lesson, 'learn')
    }

    return stored
  }).catch(($, e, next) => next(e))

  on('session.append', { door: 'tool-result' }, async ($, e, next) => {
    const stored = await next(e)

    if (!keep.questions || stored.message === undefined || e.agentId !== undefined || e.origin.kind !== 'tool' || e.origin.tool !== 'AskUserQuestion') {
      return stored
    }

    for (const block of (stored.message.content as Block[]).filter(one => one.type === 'tool_result')) {
      const result = resultText(block)

      if (typeof block.tool_use_id === 'string' && result.trim() !== '') {
        await keepAnswer($, `${block.tool_use_id}${PICK}`, pickText(result), 'pick')
      }
    }

    return stored
  }).catch(($, e, next) => next(e))

  // A slash command's record and what it printed: some are stored as notices, some as the person's rows.
  for (const door of ['command', 'notice'] as const) {
    on('session.append', { door }, async ($, e, next) => {
      const stored = await next(e)

      if (!keep.commands || stored.uuid === undefined || e.agentId !== undefined || stored.message.isMeta) {
        return stored
      }

      const text = textOf(stored.message.content)
      const command = commandLine(text)
      const output = commandOutput(text)

      if (command !== undefined) {
        await remember($, stored.uuid, command, 'command')
      } else if (output !== '') {
        await keepAnswer($, stored.uuid, output, 'output')
      }

      return stored
    }).catch(($, e, next) => next(e))
  }

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

    if (e.props.hasSurvey || e.props.view.agentId !== undefined || (await dndHiding($)) !== '') {
      return beneath
    }

    const recent = (await read($, prompts)).filter(prompt => isMessage(prompt) && prompt.kind !== 'command').slice(-BAND_COUNT)
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
    const hiding = await dndHiding($)

    if (hiding !== '') {
      return <Text dimColor>{`Hidden by the do-not-disturb profile ${hiding}.`}</Text>
    }

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

    // A bar down the left edge of a block, shown only while the pointer is on the control that would
    // fold the block back; hidden, it is never under the pointer itself.
    const closingBar = (controlKey: string) => (
      <Box
        position="absolute"
        top={0}
        bottom={0}
        left={0}
        width={1}
        display="none"
        backgroundColor="suggestion"
        hover={{ scope: foldScope(controlKey), display: 'flex' }}
      />
    )

    // Drawn in the accent color where the build styles a button's text, named in words for a reader.
    // Under the pointer it lights the bar beside each block it would fold back (closingBar).
    const foldAllControl = (key: string, isOpen: boolean, drawn: string, onPress: () => void) =>
      styled ? (
        <Button key={key} label={isOpen ? 'collapse all' : 'expand all'} hover={{ scope: foldScope(key) }} onPress={onPress}>
          <Text color="suggestion">{drawn}</Text>
        </Button>
      ) : (
        <Button key={key} label={drawn} hover={{ scope: foldScope(key) }} onPress={onPress} />
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
          const by = answer.kind === 'pick' ? 'You' : answer.kind === 'output' ? 'Output' : 'Claude'
          const said = `${answer.kind === undefined ? '' : `${ANSWER_WORDS[answer.kind]}: `}${flatten(answer.text)}`
          const label = `${answer.time ?? '--:--'} ${isAnswerOpen ? by : truncate(said, width - 6)}`

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
              {isAnswerOpen && (
                <Box flexDirection="column">
                  {paragraphs(answer.text, width - 6).map((line, index) => (
                    <Box key={`reply-${answer.id}-${index}`} paddingLeft={2}>
                      <Text>{line || ' '}</Text>
                    </Box>
                  ))}
                  {closingBar(`all-${prompt.id}`)}
                </Box>
              )}
            </Box>
          )
        })}
        {closingBar('fold-all')}
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
