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
  expect(await pane.find({ type: 'Text', text: 'crème' })).toBeDefined()
  expect(await pane.find({ key: 'row-second' })).toBeDefined()
  expect(await pane.find({ key: 'row-third' })).toBeUndefined()
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
  const keys = (await pane.findAll({ type: 'Button' })).map(button => button.key ?? '')
  expect(keys.indexOf('row-answer')).toBeGreaterThan(keys.indexOf('row-first'))
  expect(keys.indexOf('row-answer')).toBeLessThan(keys.indexOf('row-second'))
})
