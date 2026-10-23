import type { PromptSubmitInput, PromptSubmitResult } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

// The kit raises prompt.submit with the engine's own input; the typings only list the plugin call.
const submit = ($: Engine, input: PromptSubmitInput) =>
  ($.prompt as unknown as { submit: (input: PromptSubmitInput) => Promise<PromptSubmitResult> }).submit(input)

const SCROLL = { offset: 0, bodyRows: 20 }
const BAND_PROPS = { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 80, scroll: SCROLL, view: {} }

const say = ($: Engine, uuid: string, text: string) =>
  $.session.append({
    message: { type: 'user', role: 'user', content: [{ type: 'text', text }] },
    door: 'prompt',
    origin: { kind: 'composer' },
    uuid,
  })

test('the band shows the last two messages and the pane finds one by an accent-free word', async ($, on) => {
  mock.clock(on)
  on('ui.render', () => Fragment({}))

  await say($, 'first', 'Why is my sound so low?')
  await say($, 'second', 'Une recette de café crème')
  await say($, 'third', 'Back to the mods please')

  const band = await $.ui.mount({ plugin: 'recent-prompts', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })

  expect(await band.find({ text: /sound so low/ })).toBeUndefined()
  expect(await band.find({ key: 'prompt-0', text: /café crème/ })).toBeDefined()
  expect(await band.find({ key: 'prompt-1', text: /Back to the mods/ })).toBeDefined()
  expect(await band.find({ key: 'history' })).toBeDefined()

  const pane = await $.ui.mount({
    plugin: 'recent-prompts',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'my-messages',
    props: { title: 'My messages', isFocused: true, bodyColumns: 50, placement: 'dock', scroll: SCROLL, view: {} },
  })

  expect(await pane.find({ text: '3 messages' })).toBeDefined()

  await pane.input({ key: 'search', text: 'creme', kind: 'change' })

  expect(await pane.find({ text: '1 of 3 match' })).toBeDefined()
  expect(await pane.find({ key: 'text-second', text: /café crème/ })).toBeDefined()
  expect(await pane.find({ key: 'row-second' })).toBeDefined()
  expect(await pane.find({ key: 'row-third' })).toBeUndefined()
})

test('a /clear empties the history, and the band keeps its history button', async ($, on) => {
  const clock = mock.clock(on)
  on('ui.render', () => Fragment({}))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))

  const empty = await $.ui.mount({ plugin: 'recent-prompts', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })

  expect(await empty.find({ key: 'history' })).toBeDefined()

  await say($, 'first', 'Why is my sound so low?')
  await $.session.end({ reason: 'clear', sessionId: 'old', resume: { id: 'old' } })
  await clock.advance(0)
  const band = await $.ui.mount({ plugin: 'recent-prompts', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })

  expect(await band.find({ text: /sound so low/ })).toBeUndefined()
  expect(await band.find({ key: 'history' })).toBeDefined()
})

test('a do-not-disturb profile hiding the history leaves the band and the pane empty', async ($, on) => {
  mock.clock(on)
  on('ui.render', () => Fragment({}))
  on('state.get', { plugin: 'dnd' }, () => ({
    value: { value: { shape: 'dnd-active/1', value: { profile: 'meeting', parts: { history: { mode: 'hide' } } } }, version: 1 },
  }))

  await say($, 'first', 'Why is my sound so low?')
  const band = await $.ui.mount({ plugin: 'recent-prompts', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })

  expect(await band.find({ text: /sound so low/ })).toBeUndefined()
  expect(await band.find({ key: 'history' })).toBeUndefined()

  const pane = await $.ui.mount({
    plugin: 'recent-prompts',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'my-messages',
    props: { title: 'My messages', isFocused: true, bodyColumns: 50, placement: 'dock', scroll: SCROLL, view: {} },
  })

  expect(await pane.find({ text: 'Hidden by the do-not-disturb profile meeting.' })).toBeDefined()
  expect(await pane.find({ key: 'search' })).toBeUndefined()
})

test('a message typed while a turn runs is listed as typed once its queued row is stored', async ($, on) => {
  mock.clock(on)
  on('prompt.submit', ($, e) => ({ text: e.text }))
  on('ui.render', () => Fragment({}))

  await say($, 'first', 'Fix the image preview')
  await submit($, { text: 'Also keep it on Windows', origin: { kind: 'composer' }, turnId: 'turn-1', wait: false })
  await $.session.append({
    message: {
      type: 'attachment',
      name: 'queued_command',
      content: [{ type: 'text', text: 'The user sent a new message while you were working:\nAlso keep it on Windows\n\nAddress it.' }],
    },
    door: 'attachment',
    origin: { kind: 'composer' },
    uuid: 'queued',
  })

  const band = await $.ui.mount({ plugin: 'recent-prompts', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })

  expect(await band.find({ key: 'prompt-1', text: /^Also keep it on Windows$/ })).toBeDefined()
})

test('a message absorbed into the running turn is listed as typed once its delivered row is stored', async ($, on) => {
  mock.clock(on)
  on('prompt.submit', ($, e) => ({ text: e.text }))
  on('ui.render', () => Fragment({}))

  await say($, 'first', 'Check the sync')
  await submit($, { text: 'And the code-kit ?', origin: { kind: 'composer' }, turnId: 'turn-1', wait: false })
  await $.session.append({
    message: {
      type: 'attachment',
      name: 'queued_command',
      content: [
        {
          type: 'text',
          text: '<system-reminder>\nThe user sent a new message while you were working:\nAnd the code-kit ?\n\nAddress the message above as you continue this turn.\n</system-reminder>',
        },
      ],
    },
    door: 'delivery',
    origin: { kind: 'composer' },
    uuid: 'delivered',
  })

  const band = await $.ui.mount({ plugin: 'recent-prompts', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })

  expect(await band.find({ key: 'prompt-1', text: /^And the code-kit \?$/ })).toBeDefined()
})

test("a prompt a plugin sends for the person, such as a reminder's pick, is listed without the engine's framing", async ($, on) => {
  mock.clock(on)
  on('prompt.submit', ($, e) => ({ text: e.text }))
  on('ui.render', () => Fragment({}))

  const origin = { kind: 'plugin', name: 'reminders-handoffs' } as const
  const sent = `Let's do the reminder water-the-plants now: "Water the plants".`

  await say($, 'first', 'Check the sync')
  await submit($, { text: sent, origin, wait: false })
  await $.session.append({
    message: {
      type: 'user',
      role: 'user',
      content: [{ type: 'text', text: `The reminders-handoffs plugin sent a message:\n  ${sent}\n\nAddress the message above.` }],
    },
    door: 'prompt',
    origin,
    uuid: 'picked',
  })

  const band = await $.ui.mount({ plugin: 'recent-prompts', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })

  expect(await band.find({ key: 'prompt-1', text: /^Let's do the reminder water-the-plants now/ })).toBeDefined()
})

test('an unfolded message shows it whole, then each reply folded until opened, tool calls left out', async ($, on) => {
  mock.clock(on)
  on('ui.render', () => Fragment({}))
  const reply = (uuid: string, content: { type: string; [field: string]: unknown }[]) =>
    $.session.append({ message: { type: 'assistant', role: 'assistant', content: content as never }, door: 'response', origin: { kind: 'composer' }, uuid })
  const long = `${Array.from({ length: 30 }, (_, i) => `word${i}`).join(' ')} the end of my message.`

  await say($, 'ask', long)
  await reply('look', [{ type: 'text', text: 'Looking at the sync first.' }, { type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'git status' } }])
  await reply('tool-only', [{ type: 'tool_use', id: 't2', name: 'Read', input: { file_path: '/x' } }])
  await reply('done', [{ type: 'text', text: 'It works.\n\nThe sync pushed every change, and nothing was left behind on this computer.' }])
  await say($, 'next', 'Thanks')

  const pane = await $.ui.mount({
    plugin: 'recent-prompts',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'my-messages',
    props: { title: 'My messages', isFocused: true, bodyColumns: 50, placement: 'dock', scroll: SCROLL, view: {} },
  })

  const details = async () => (await pane.find({ key: 'details-ask' }))?.text ?? ''

  expect(await details()).toBe('')

  // The line's own text unfolds it, as its arrow does.
  await pane.press({ key: 'text-ask' })

  // Wrapped to the pane, every word there.
  expect(await details()).toContain('word29 the end')
  expect(await details()).toContain('my message.↗')
  // Each reply has its own way to its place in the conversation.
  expect(await pane.find({ key: 'answer-jump-look', text: '↗' })).toBeDefined()
  expect(await pane.find({ key: 'answer-toggle-look' })).toBeDefined()
  expect(await pane.find({ key: 'answer-toggle-tool-only' })).toBeUndefined()
  expect(await details()).not.toContain('git status')
  expect(await details()).not.toContain('left behind')

  await pane.press({ key: 'answer-text-done' })

  expect(await details()).toContain('left behind')
  expect(await pane.find({ type: 'Text', text: 'computer.' })).toBeDefined()
  expect(await pane.find({ key: 'toggle-next' })).toBeDefined()
  expect(await pane.find({ text: 'No reply yet.' })).toBeUndefined()
})

test("the arrow at the end of a message unfolds it with all its replies; the one beside the count, every message listed", async ($, on) => {
  mock.clock(on)
  on('ui.render', () => Fragment({}))
  const reply = (uuid: string, text: string) =>
    $.session.append({ message: { type: 'assistant', role: 'assistant', content: [{ type: 'text', text }] }, door: 'response', origin: { kind: 'composer' }, uuid })

  await say($, 'ask', 'Check the sync')
  await reply('look', 'Looking at the sync first.\n\nThe remote is reachable.')
  await reply('done', 'It works.\n\nNothing was left behind.')
  await say($, 'next', 'Thanks')

  const pane = await $.ui.mount({
    plugin: 'recent-prompts',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'my-messages',
    props: { title: 'My messages', isFocused: true, bodyColumns: 60, placement: 'dock', scroll: SCROLL, view: {} },
  })

  // A message with no reply has nothing to unfold under it.
  expect(await pane.find({ key: 'all-next' })).toBeUndefined()

  await pane.press({ key: 'all-ask' })

  expect(await pane.find({ type: 'Text', text: 'The remote is reachable.' })).toBeDefined()
  expect(await pane.find({ type: 'Text', text: 'Nothing was left behind.' })).toBeDefined()
  expect(await pane.find({ key: 'all-ask', text: '▴ all' })).toBeDefined()
  // A hidden bar beside each open block, for the control that would fold it back: the message for
  // the one beside the count, each reply for the message's.
  const closingBars = async () =>
    (await pane.findAll({ type: 'Box' })).filter(box => box.props?.display === 'none' && box.props?.backgroundColor === 'suggestion').length

  expect(await closingBars()).toBe(3)

  // Folding back leaves the message open, its replies folded.
  await pane.press({ key: 'all-ask' })

  expect(await pane.find({ key: 'details-ask' })).toBeDefined()
  expect(await pane.find({ type: 'Text', text: 'Nothing was left behind.' })).toBeUndefined()

  // One reply opened by hand: the arrow folds it back at the first press.
  await pane.press({ key: 'answer-text-done' })

  expect(await pane.find({ key: 'all-ask', text: '▴ all' })).toBeDefined()

  await pane.press({ key: 'all-ask' })

  expect(await pane.find({ type: 'Text', text: 'Nothing was left behind.' })).toBeUndefined()

  // A message open: the one beside the count folds every line.
  expect(await pane.find({ text: '▴ collapse all' })).toBeDefined()

  await pane.press({ key: 'fold-all' })

  expect(await pane.find({ key: 'details-ask' })).toBeUndefined()
  expect(await pane.find({ text: '▾ expand all' })).toBeDefined()

  await pane.press({ key: 'fold-all' })

  expect(await pane.find({ type: 'Text', text: 'Nothing was left behind.' })).toBeDefined()
  expect(await pane.find({ key: 'details-next' })).toBeDefined()
})

const PANE_PROPS = { title: 'My messages', isFocused: true, bodyColumns: 80, placement: 'dock', scroll: SCROLL, view: {} } as const

const mountPane = ($: Engine) =>
  $.ui.mount({ plugin: 'recent-prompts', surface: 'terminal', component: 'Pane', requestId: 'my-messages', props: PANE_PROPS })

const ask = ($: Engine) =>
  $.session.append({
    message: {
      type: 'assistant',
      role: 'assistant',
      content: [
        {
          type: 'tool_use',
          id: 'toolu_ask',
          name: 'AskUserQuestion',
          input: { questions: [{ question: 'Where should the profiles live?', header: 'Storage', options: [{ label: 'Synced' }, { label: 'Local' }] }] },
        },
      ],
    },
    door: 'response',
    origin: { kind: 'model', model: 'claude-opus-5-5' },
    uuid: 'asking',
  })

const answerAsk = ($: Engine) =>
  $.session.append({
    message: {
      type: 'user',
      role: 'user',
      content: [
        {
          type: 'tool_result',
          tool_use_id: 'toolu_ask',
          content: 'The user answered: "Where should the profiles live?"="Synced". You can now continue with the user\'s answers in mind.',
        },
      ],
    },
    door: 'tool-result',
    origin: { kind: 'tool', tool: 'AskUserQuestion' },
    uuid: 'picked',
  })

test('a question asked with the picker and the pick are kept as replies', async ($, on) => {
  mock.clock(on)
  on('ui.render', () => Fragment({}))

  await say($, 'ask', 'Set up the profiles')
  await ask($)
  await answerAsk($)

  const pane = await mountPane($)
  await pane.press({ key: 'text-ask' })

  expect(await pane.find({ key: 'answer-text-toolu_ask', text: /asked: Where should the profiles live\? · Synced · Local/ })).toBeDefined()
  expect(await pane.find({ key: 'answer-text-toolu_ask#pick', text: /you picked: Where should the profiles live\? → Synced/ })).toBeDefined()
})

test('with questions turned off, the picker is left out', { options: { questions: false } }, async ($, on) => {
  mock.clock(on)
  on('ui.render', () => Fragment({}))

  await say($, 'ask', 'Set up the profiles')
  await ask($)
  await answerAsk($)

  const pane = await mountPane($)
  await pane.press({ key: 'text-ask' })

  expect(await pane.find({ text: 'No reply yet.' })).toBeDefined()
})

test('a slash command is listed as typed with what it printed, and stays out of the band', async ($, on) => {
  mock.clock(on)
  on('ui.render', () => Fragment({}))
  const row = (uuid: string, text: string) =>
    $.session.append({ message: { type: 'user', role: 'user', content: [{ type: 'text', text }] }, door: 'command', origin: { kind: 'composer' }, uuid })

  await say($, 'first', 'Check the sync')
  await row('cmd', '<command-name>/rename</command-name>\n<command-message>rename</command-message>\n<command-args>MAIN</command-args>')
  await row('out', '<local-command-stdout>Session renamed to: MAIN</local-command-stdout>')

  const band = await $.ui.mount({ plugin: 'recent-prompts', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })

  expect(await band.find({ text: /rename/ })).toBeUndefined()

  const pane = await mountPane($)

  expect(await pane.find({ key: 'text-cmd', text: /^\/rename MAIN$/ })).toBeDefined()

  await pane.press({ key: 'text-cmd' })

  expect(await pane.find({ key: 'answer-text-out', text: /output: Session renamed to: MAIN/ })).toBeDefined()
})

const TRANSCRIPT = [
  { role: 'user', text: 'Set up the profiles', toolUses: [] },
  { role: 'assistant', text: 'Looking at the sync first.', toolUses: [] },
  {
    role: 'assistant',
    text: '',
    toolUses: [
      {
        tool_use_id: 'toolu_ask',
        tool: 'AskUserQuestion',
        input: { questions: [{ question: 'Where should the profiles live?', options: [{ label: 'Synced' }] }] },
        text: 'The user answered: "Where should the profiles live?"="Synced".',
      },
      { tool_use_id: 'toolu_read', tool: 'Read', input: { file_path: '/x' }, text: 'secret file body' },
    ],
  },
  { role: 'user', text: '<system-reminder>\nSome engine framing\n</system-reminder>', toolUses: [] },
  { role: 'assistant', text: 'Done, they are synced.', toolUses: [] },
  { role: 'user', text: '<command-name>/rename</command-name>\n<command-args>MAIN</command-args>', toolUses: [] },
  { role: 'user', text: 'Thanks', toolUses: [] },
]

test('a resumed session reads its history back from the transcript, framing and tool work left out', async ($, on) => {
  const clock = mock.clock(on)
  on('ui.render', () => Fragment({}))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('session.messages', () => ({ value: TRANSCRIPT as never }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
  await clock.advance(0)

  const pane = await mountPane($)

  expect(await pane.find({ text: '3 messages' })).toBeDefined()
  expect(await pane.find({ text: /Some engine framing/ })).toBeUndefined()

  await pane.press({ key: 'fold-all' })

  expect(await pane.find({ type: 'Text', text: 'Done, they are synced.' })).toBeDefined()
  expect(await pane.find({ key: 'answer-text-toolu_ask#pick' })).toBeDefined()
  expect(await pane.find({ text: /secret file body/ })).toBeUndefined()
  expect(await pane.find({ key: 'text-rebuilt-5', text: /^\/rename MAIN$/ })).toBeDefined()
})

test('a reload fills in the replies a stored message missed, keeping what was stored', async ($, on) => {
  const clock = mock.clock(on)
  on('ui.render', () => Fragment({}))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('session.messages', () => ({ value: TRANSCRIPT as never }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))

  await say($, 'ask', 'Set up the profiles')
  await $.session.append({
    message: { type: 'assistant', role: 'assistant', content: [{ type: 'text', text: 'Done, they are synced.' }] },
    door: 'response',
    origin: { kind: 'model', model: 'claude-opus-5-5' },
    uuid: 'done',
  })
  await say($, 'thanks', 'Thanks')
  await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
  await clock.advance(0)

  const pane = await mountPane($)

  // The command typed before is not added: a stored history only gains replies.
  expect(await pane.find({ text: '2 messages' })).toBeDefined()

  await pane.press({ key: 'all-ask' })

  const keys = (await pane.findAll({ type: 'Button' })).map(button => button.key ?? '')
  const replies = keys.filter(key => key.startsWith('answer-text-'))

  expect(replies).toEqual(['answer-text-rebuilt-1', 'answer-text-toolu_ask', 'answer-text-toolu_ask#pick', 'answer-text-done'])
})

test('a 💡 Learn block Claude ended a reply with is listed in the history between the messages, never in the band', async ($, on) => {
  mock.clock(on)
  on('ui.render', () => Fragment({}))

  await say($, 'first', 'Fix the login query')
  await $.session.append({
    message: { type: 'assistant', role: 'assistant', content: [{ type: 'text', text: 'Done.\n\n💡 Learn: a parameterized query keeps user input out of the SQL text.' }] },
    door: 'response',
    origin: { kind: 'composer' },
    uuid: 'answer',
  })
  await say($, 'second', 'Thanks')

  const band = await $.ui.mount({ plugin: 'recent-prompts', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })

  expect(await band.find({ key: 'prompt-0', text: /login query/ })).toBeDefined()
  expect(await band.find({ text: /parameterized/ })).toBeUndefined()

  const pane = await $.ui.mount({
    plugin: 'recent-prompts',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'my-messages',
    props: { title: 'My messages', isFocused: true, bodyColumns: 80, placement: 'dock', scroll: SCROLL, view: {} },
  })

  expect(await pane.find({ text: '2 messages, 1 💡' })).toBeDefined()
  expect(await pane.find({ text: /parameterized query keeps user input/ })).toBeDefined()

  await pane.press({ key: 'text-answer' })

  expect(await pane.find({ key: 'details-answer', text: /keeps user input out of the SQL text\./ })).toBeDefined()
  const keys = (await pane.findAll({ type: 'Button' })).map(button => button.key ?? '')
  expect(keys.indexOf('row-answer')).toBeGreaterThan(keys.indexOf('row-first'))
  expect(keys.indexOf('row-answer')).toBeLessThan(keys.indexOf('row-second'))
})
