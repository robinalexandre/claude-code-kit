import type { On, PromptEditInput, PromptEditResult } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

// The kit raises prompt.edit at run time; its typings do not list the call yet.
const edit = ($: Engine, input: PromptEditInput) =>
  ($.prompt as unknown as { edit: (input: PromptEditInput) => Promise<PromptEditResult> }).edit(input)

const CLIPBOARD = 'line one\r\nline two\n'
const PLACEHOLDER_ROW = 'see: [Pasted text #1 +2 lines]'
const SCROLL = { offset: 0, bodyRows: 20 }

const ran = (exitCode: number, stdout = '') => ({
  value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
})

const whiteBmp = (width: number, height: number) => {
  const stride = Math.ceil((width * 24) / 32) * 4
  const bytes = new Uint8Array(54 + stride * height)
  const view = new DataView(bytes.buffer)
  view.setUint16(0, 0x4d42, true)
  view.setUint32(2, bytes.length, true)
  view.setUint32(10, 54, true)
  view.setUint32(14, 40, true)
  view.setInt32(18, width, true)
  view.setInt32(22, height, true)
  view.setUint16(26, 1, true)
  view.setUint16(28, 24, true)
  bytes.fill(0xff, 54)

  return btoa(String.fromCharCode(...bytes))
}

const WINDOWS = { OS: 'Windows_NT', SystemRoot: 'C:\\WINDOWS', TEMP: 'C:\\Temp', TERM_PROGRAM: 'ghostty' }

const answerBeneath = (
  on: On,
  decoded: string[] = [],
  env: Record<string, string> = {},
  clipboard = CLIPBOARD,
  boxText = '',
) => {
  const clock = mock.clock(on)
  const filled: string[] = []
  on('env.get', ($, e) => ({ value: env[e.name] }))
  on('process.run', ($, e) => {
    const [program, ...rest] = e.argv

    if (program === 'C:/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe') {
      const script = rest.at(-1) ?? ''

      if (script.includes('GetText')) {
        return ran(0, btoa(clipboard))
      }

      return ran(0, script.includes('Width') ? '4 4' : '')
    }

    if (program === '/usr/bin/pbpaste') {
      return ran(0, CLIPBOARD)
    }

    if (program === '/usr/bin/base64') {
      decoded.push(rest.at(-1) ?? '')
    }

    if (program === '/usr/bin/sips' && rest.includes('pixelWidth')) {
      return ran(0, 'pixelWidth: 4\npixelHeight: 4\n')
    }

    return ran(['/bin/mkdir', '/usr/bin/osascript', '/usr/bin/sips', '/usr/bin/base64'].includes(program ?? '') ? 0 : 1)
  })
  on('fs.read', () => ({ value: { base64: whiteBmp(4, 4) } }))
  on('prompt.read', () => ({ value: { text: filled.at(-1) ?? boxText, cursor: 0 } }))
  on('prompt.fill', ($, e) => {
    filled.push(e.text)

    return { isFilled: true }
  })
  on('prompt.edit', ($, e) => ({
    text: e.text.slice(0, e.start) + e.inputText + e.text.slice(e.end),
    cursor: e.start + e.inputText.length,
  }))
  on('ui.render', { component: 'UserMessage' }, ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>{e.props.text}</Text>
  })
  on('ui.render', () => Fragment({}))
  on('session.start', ($, e) => ({ cwd: e.cwd }))

  return { clock, filled }
}

const band = ($: Engine) =>
  $.ui.mount({
    plugin: 'paste-preview',
    surface: 'terminal',
    component: 'AbovePrompt',
    props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 80, scroll: SCROLL, view: {} },
  })

const userRow = ($: Engine, requestId: string, text = PLACEHOLDER_ROW) =>
  $.ui.mount({
    plugin: 'paste-preview',
    surface: 'terminal',
    component: 'UserMessage',
    requestId,
    props: { text, origin: { kind: 'composer' }, isExpanded: false },
  })

const sendImage = ($: Engine, uuid: string) =>
  $.session.append({
    message: {
      type: 'user',
      role: 'user',
      content: [
        { type: 'text', text: 'look [Image #1]' },
        { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'iVBORw0KGgo=' } },
      ],
    },
    door: 'prompt',
    origin: { kind: 'composer' },
    uuid,
  })

test('a collapsed paste is put back in full from the clipboard', async ($, on) => {
  answerBeneath(on)

  const text = 'see: '
  const box = await edit($, {
    origin: { kind: 'composer' },
    text,
    cursor: text.length,
    start: text.length,
    end: text.length,
    inputText: '[Pasted text #1 +2 lines]',
  })

  expect(box.text).toBe('see: line one\nline two\n')
  expect(box.cursor).toBe(box.text.length)
})

test('on Windows a paste that reached the box collapsed is put back in full', async ($, on) => {
  const { clock, filled } = answerBeneath(on, [], WINDOWS, CLIPBOARD, 'see: [Pasted text #1 +2 lines] ok')

  await $.session.start({ cwd: 'C:/work', surface: 'terminal', isInteractive: true })
  await clock.advance(1000)

  expect(filled).toEqual(['see: line one\nline two\n ok'])
})

test('on Windows a clipboard that no longer matches the placeholder is not pasted', async ($, on) => {
  const { clock, filled } = answerBeneath(on, [], WINDOWS, 'something copied later', 'see: [Pasted text #1 +5 lines]')

  await $.session.start({ cwd: 'C:/work', surface: 'terminal', isInteractive: true })
  await clock.advance(3000)

  expect(filled).toEqual([])
})

test('on Windows an image is drawn as a raster, even in a terminal named like a kitty one', async ($, on) => {
  answerBeneath(on, [], WINDOWS)

  const text = 'look '
  await edit($, {
    origin: { kind: 'composer' },
    text,
    cursor: text.length,
    start: text.length,
    end: text.length,
    inputText: '[Image #1]',
  })
  const above = await band($)

  expect(await above.find({ type: 'Raster' })).toBeDefined()
  expect(await above.find({ type: 'Image' })).toBeUndefined()
})

test('a typed key is left alone', async ($, on) => {
  answerBeneath(on)

  const box = await edit($, {
    origin: { kind: 'composer' },
    key: { key: 'a' },
    text: 'h',
    cursor: 1,
    start: 1,
    end: 1,
    inputText: 'a',
  })

  expect(box.text).toBe('ha')
})

test('a sent message whose row shows a paste placeholder is drawn with its full text', async ($, on) => {
  answerBeneath(on)

  await $.session.append({
    message: { type: 'user', role: 'user', content: [{ type: 'text', text: 'see: line one\nline two' }] },
    door: 'prompt',
    origin: { kind: 'composer' },
    uuid: 'sent-1',
  })

  const sent = await userRow($, 'sent-1')

  expect(await sent.find({ text: /line two/ })).toBeDefined()
  expect(await sent.find({ text: /Pasted text/ })).toBeUndefined()

  const unknown = await userRow($, 'never-stored')

  expect(await unknown.find({ text: /Pasted text/ })).toBeDefined()
})

test('a pasted image shows above the prompt, then stays under its sent message', async ($, on) => {
  const decoded: string[] = []
  answerBeneath(on, decoded)

  const text = 'look '
  await edit($, {
    origin: { kind: 'composer' },
    text,
    cursor: text.length,
    start: text.length,
    end: text.length,
    inputText: '[Image #1]',
  })

  const band = await $.ui.mount({
    plugin: 'paste-preview',
    surface: 'terminal',
    component: 'AbovePrompt',
    props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 80, scroll: SCROLL, view: {} },
  })

  expect(await band.find({ type: 'Raster' })).toBeDefined()

  await sendImage($, 'sent-2')
  const row = await userRow($, 'sent-2', 'look [Image #1]')

  expect(await row.find({ type: 'Raster' })).toBeDefined()
  expect(await row.find({ text: 'Image #1' })).toBeDefined()
  expect(decoded).toEqual([])
})

test('an image in a message typed while a turn runs shows under its queued row', async ($, on) => {
  answerBeneath(on)

  await $.session.append({
    message: {
      type: 'attachment',
      name: 'queued_command',
      content: [
        { type: 'text', text: 'The user sent a new message while you were working:\nthis one [Image #2]' },
        { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'iVBORw0KGgo=' } },
      ],
    },
    door: 'attachment',
    origin: { kind: 'composer' },
    uuid: 'queued',
  })
  const row = await userRow($, 'queued', 'this one [Image #2]')

  expect(await row.find({ type: 'Raster' })).toBeDefined()
  expect(await row.find({ text: 'Image #2' })).toBeDefined()
})

test('an image sent with no preview is decoded from the message', async ($, on) => {
  const decoded: string[] = []
  answerBeneath(on, decoded)

  await sendImage($, 'sent-3')
  const row = await userRow($, 'sent-3', 'look [Image #1]')

  expect(await row.find({ type: 'Raster' })).toBeDefined()
  expect(decoded).toHaveLength(1)
})
