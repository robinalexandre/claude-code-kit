import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

const SCROLL = { offset: 0, bodyRows: 40 }
const PANE_PROPS = { title: 'Configuration', isFocused: true, bodyColumns: 64, placement: 'dock' as const, scroll: SCROLL, view: {} }
const BAND_PROPS = { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 80, scroll: SCROLL, view: {} }
const START = { cwd: '/home/someone/dev/shop', surface: 'terminal' as const, isInteractive: true }
const RUN = { command: 'configuration', args: '', origin: { kind: 'composer' as const }, presentation: { isFullscreen: true, columns: 160 } }
const HOME = '/home/someone'

type Files = Record<string, string>

// Windows hands a path on in its own spelling, with its drive before the fake home: the files are
// named from the ~.
const at = (path: string) => path.replace(/\\/g, '/').replace(new RegExp(`^(?:[A-Za-z]:)?${HOME}/`), '~/')

const HISTORY_ROW = {
  key: 'recent-prompts.questions',
  label: 'Keep questions asked with the picker',
  kind: 'boolean',
  value: true,
  provider: { plugin: 'recent-prompts', tier: 'user' },
  isLocked: false,
}
const BUILTIN_ROW = { ...HISTORY_ROW, key: 'agents-md.instructionFiles', label: 'Instruction files', kind: 'text', value: 'both', provider: { plugin: 'agents-md', tier: 'builtin' } }

// `files`: what the mod reads and writes, by path; `opened`: the panes it opens.
const answer = (on: On, files: Files, opened: string[] = []) => {
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? HOME : undefined }))
  on('fs.read', ($, e) => {
    const text = files[at(e.path)]

    if (text === undefined) {
      throw new Error(`ENOENT: ${e.path}`)
    }

    return { value: text }
  })
  on('fs.exists', ($, e) => ({ value: at(e.path) in files }))
  on('fs.write', ($, e) => {
    files[at(e.path)] = e.text

    return { value: undefined }
  })
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('ui.render', () => Fragment({}))
  on('ui.open', ($, e) => {
    opened.push(e.id)

    return { value: { isPlaced: true as const } }
  })
  on('ui.toast', () => ({ value: undefined }))
}

// The /config rows the pane reads and writes; a set lands in settings.json as the engine would.
const answerRows = (on: On, files: Files, sets: unknown[]) => {
  const rows = [HISTORY_ROW, BUILTIN_ROW]
  on('config.list', () => ({ value: rows as never }))
  on('config.set', ($, e) => {
    sets.push([e.key, e.value])
    rows[0] = { ...HISTORY_ROW, value: e.value as boolean }
    files['~/.claude/settings.json'] = JSON.stringify({ pluginConfigs: { 'recent-prompts@inline': { options: { questions: e.value } } } })

    return { value: e.value }
  })
}

const openPane = async ($: Engine) => {
  await $.session.start(START)
  await $.command.run(RUN)

  return $.ui.mount({ plugin: 'configuration', surface: 'terminal', component: 'Pane', requestId: 'configuration', props: PANE_PROPS })
}

test('a Configuration button on the band and /configuration open the pane', async ($, on) => {
  const opened: string[] = []
  answer(on, {}, opened)
  answerRows(on, {}, [])

  await $.session.start(START)
  const band = await $.ui.mount({ plugin: 'configuration', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })

  expect(await band.find({ key: 'band-4-configuration' })).toBeDefined()

  await band.press({ key: 'configuration' })

  expect(opened).toEqual(['configuration'])
  expect((await $.command.run(RUN)).text).toBe('Configuration pane opened.')
})

test("the pane lists each mod's settings; a change for all computers is a /config change alone", async ($, on) => {
  const files: Files = { '~/.claude-sync/.machine': 'mac\n', '~/.claude-sync/machines/mac.json': '{ "settings": { "theme": "dark" } }' }
  const sets: unknown[] = []
  answer(on, files)
  answerRows(on, files, sets)

  const pane = await openPane($)

  expect(await pane.find({ key: 'fold-mod|recent-prompts', text: /recent-prompts \(1\)/ })).toBeDefined()
  expect(await pane.find({ text: /Instruction files/ })).toBeUndefined()
  expect(await pane.find({ key: 'scope-here', text: 'this computer only (mac)' })).toBeDefined()
  // Without dnd, no Do not disturb button.
  expect(await pane.find({ key: 'open-dnd' })).toBeUndefined()

  await pane.press({ key: 'set-recent-prompts.questions' })

  expect(sets).toEqual([['recent-prompts.questions', false]])
  expect(JSON.parse(files['~/.claude-sync/machines/mac.json'] ?? '')).toEqual({ settings: { theme: 'dark' } })
  expect(await pane.find({ key: 'set-recent-prompts.questions', text: /^\[ \] Keep questions/ })).toBeDefined()
})

test('a change for this computer only is kept in its machine file, says the shared value, and one for all computers takes it back out', async ($, on) => {
  const files: Files = {
    '~/.claude-sync/.machine': 'mac\n',
    '~/.claude-sync/machines/mac.json': '{ "settings": { "theme": "dark" } }',
    '~/.claude-sync/settings.shared.json': JSON.stringify({ pluginConfigs: { 'recent-prompts@inline': { options: { questions: true } } } }),
  }
  const sets: unknown[] = []
  answer(on, files)
  answerRows(on, files, sets)

  const pane = await openPane($)
  await pane.press({ key: 'scope-here' })
  await pane.press({ key: 'set-recent-prompts.questions' })

  expect(JSON.parse(files['~/.claude-sync/machines/mac.json'] ?? '')).toEqual({
    settings: { theme: 'dark', pluginConfigs: { 'recent-prompts@inline': { options: { questions: false } } } },
  })
  expect(await pane.find({ key: 'set-recent-prompts.questions', text: /\(this computer\)$/ })).toBeDefined()
  expect(await pane.find({ text: "  used here instead of all computers' value: on" })).toBeDefined()

  await pane.press({ key: 'scope-all' })
  await pane.press({ key: 'set-recent-prompts.questions' })

  expect(sets).toEqual([
    ['recent-prompts.questions', false],
    ['recent-prompts.questions', true],
  ])
  expect(JSON.parse(files['~/.claude-sync/machines/mac.json'] ?? '')).toEqual({ settings: { theme: 'dark' } })
  expect(await pane.find({ text: /used here instead/ })).toBeUndefined()
})

test('a number saved with Enter stays in its field, the same value again included; one that is not a number is not saved', async ($, on) => {
  const sets: unknown[] = []
  let days = 30
  answer(on, {})
  on('config.list', () => ({ value: [{ ...HISTORY_ROW, key: 'pr-pane.issueDays', label: 'Issues active in the last (days)', kind: 'number', value: days, provider: { plugin: 'pr-pane', tier: 'user' } }] as never }))
  on('config.set', ($, e) => {
    sets.push([e.key, e.value])
    days = e.value as number

    return { value: e.value }
  })

  const pane = await openPane($)
  const value = async (key: string) => ((await pane.find({ type: 'Input', key })) as { props?: { value?: string } } | undefined)?.props?.value

  expect(await value('set-pr-pane.issueDays-0')).toBe('30')

  await pane.input({ key: 'set-pr-pane.issueDays-0', text: '30', kind: 'submit' })

  expect(sets).toEqual([['pr-pane.issueDays', 30]])
  // Drawn anew, so what was typed gives way to the saved value.
  expect(await value('set-pr-pane.issueDays-0')).toBeUndefined()
  expect(await value('set-pr-pane.issueDays-1')).toBe('30')

  await pane.input({ key: 'set-pr-pane.issueDays-1', text: 'soon', kind: 'submit' })

  expect(sets).toHaveLength(1)
  expect(await value('set-pr-pane.issueDays-2')).toBe('30')
})

test('on battery, low power mode is on by default and written for the scripts; plugged in, it goes off', async ($, on) => {
  const clock = mock.clock(on)
  const files: Files = {}
  let source = "Now drawing from 'Battery Power'"
  answer(on, files)
  answerRows(on, files, [])
  on('process.run', ($, e) => {
    const out = e.argv.join(' ') === 'pmset -g batt' ? source : e.argv.join(' ') === 'pmset -g' ? 'lowpowermode 0' : ''

    return { value: { exitCode: 0, stdout: out, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })

  await $.session.start(START)
  await clock.advance(0)
  const written = () => JSON.parse(files['~/.claude/.low-power.json'] ?? '{}') as { setting?: string; lowPower?: boolean }

  expect(written()).toMatchObject({ setting: 'on battery', lowPower: true })

  source = "Now drawing from 'AC Power'"
  await clock.advance(60_000)

  expect(written()).toMatchObject({ setting: 'on battery', lowPower: false })
})

test('low power mode set off is never on, whatever powers the computer', { options: { lowPower: 'off' } }, async ($, on) => {
  const clock = mock.clock(on)
  const files: Files = {}
  answer(on, files)
  answerRows(on, files, [])
  on('process.run', () => ({ value: { exitCode: 0, stdout: "Now drawing from 'Battery Power'", stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))

  await $.session.start(START)
  await clock.advance(0)

  expect(JSON.parse(files['~/.claude/.low-power.json'] ?? '{}')).toMatchObject({ setting: 'off', lowPower: false })
})

test('without a private sync, the pane says changes stay on this computer', async ($, on) => {
  const files: Files = {}
  answer(on, files)
  answerRows(on, files, [])

  const pane = await openPane($)

  expect(await pane.find({ key: 'scope-here' })).toBeUndefined()
  expect(await pane.find({ text: /no private sync/ })).toBeDefined()
})
