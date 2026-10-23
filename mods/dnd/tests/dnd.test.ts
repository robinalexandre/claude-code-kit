import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

const SCROLL = { offset: 0, bodyRows: 40 }
const PANE_PROPS = { title: 'Do not disturb', isFocused: true, bodyColumns: 64, placement: 'dock' as const, scroll: SCROLL, view: {} }
const BAND_PROPS = { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 80, scroll: SCROLL, view: {} }
const START = { cwd: '/home/someone/dev/shop', surface: 'terminal' as const, isInteractive: true }
const SESSION = 'session-1'
const command = (args: string) => ({ command: 'dnd', args, origin: { kind: 'composer' as const }, presentation: { isFullscreen: true, columns: 160 } })
const ran = (exitCode: number, stdout: string, stderr = '') => ({
  value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false },
})

const HERE = { path: '/home/someone/dev/shop', name: 'shop' }
const OFF = { profile: '', why: '', until: 0, untilText: '', scope: '', parts: {}, here: HERE, wifi: '' }
const WORK = { prs: { mode: 'only', only: ['@here'] }, history: { mode: 'hide' } }

type World = { active: object; profiles: Record<string, object>; rules: object[] }

type Files = Record<string, string>

const HOME = '/home/someone'

// Windows hands a path on in its own spelling, with its drive before the fake home, and the
// session's folder may come before one under the home: the files are named from the ~.
const at = (path: string) => path.replace(/\\/g, '/').replace(/^.*~\//, '~/').replace(new RegExp(`^(?:[A-Za-z]:)?${HOME}/`), '~/')

const ACTIVE_FILE = '~/.claude/.dnd/active.json'

const isScript = (argv: string[]) => (argv[1] ?? '').replace(/\\/g, '/').endsWith('/skills/dnd/dnd.sh')

// `held`: each `set` waits for it, then writes the profile as dnd.sh would. `files`: what the mod
// reads and writes, by path.
const answer = (on: On, world: World, calls: string[][], held?: Promise<void>, files: Files = {}) => {
  const clock = mock.clock(on)
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
  on('session.cwd', () => ({ value: '/home/someone/dev/shop' }))
  on('session.id', () => ({ value: SESSION }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('process.run', async ($, e) => {
    const argv = [...e.argv]

    if (!isScript(argv)) {
      return ran(0, '')
    }

    calls.push(argv.slice(2))
    const [action, ...rest] = argv.slice(2)

    if (action === 'active') {
      return ran(0, JSON.stringify(world.active))
    }

    if (action === 'json') {
      return ran(
        0,
        JSON.stringify({
          ...world,
          known: { prs: ['owner/app'] },
          workspaces: ['someone/garden', 'app'],
          wifi: 'OfficeNet',
          file: '/home/someone/.claude-sync/dnd/profiles.json',
        })
      )
    }

    if (action === 'on') {
      const [profile = '', length = ''] = rest
      world.active = { ...OFF, profile, why: 'turned on by hand', untilText: length === '1h' ? '15:00' : '', scope: rest.includes('--session') ? 'session' : 'computer', parts: world.profiles[profile] ?? {} }

      return ran(0, `On: ${profile}`)
    }

    if (action === 'off') {
      world.active = OFF

      return ran(0, 'Off: nothing is hidden.')
    }

    if (action === 'set' && held !== undefined) {
      const [profile = '', part = '', mode = '', ...names] = rest
      await held
      world.profiles = { ...world.profiles, [profile]: { ...world.profiles[profile], [part]: { mode, only: names } } }
    }

    return ran(0, '')
  })
  on('ui.render', () => Fragment({}))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('ui.toast', () => ({ value: undefined }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))

  return clock
}

const mountPane = ($: Engine) => $.ui.mount({ plugin: 'dnd', surface: 'terminal', component: 'Pane', requestId: 'configuration', props: PANE_PROPS })

const mountBand = ($: Engine) => $.ui.mount({ plugin: 'dnd', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })

test('a Configuration button on the band; the profile on, read at session start, is written for the status line', async ($, on) => {
  const calls: string[][] = []
  const world: World = { active: OFF, profiles: { work: WORK }, rules: [] }
  const files: Files = { [ACTIVE_FILE]: JSON.stringify({ 'session-0': { profile: 'meeting', untilText: '' } }) }
  answer(on, world, calls, undefined, files)
  const shown = () => JSON.parse(files[ACTIVE_FILE] ?? '{}') as Record<string, { profile: string; scope: string; untilText: string }>

  await $.session.start(START)
  const band = await mountBand($)

  expect(calls).toContainEqual(['active', '/home/someone/dev/shop', '--session', SESSION])
  expect(await band.find({ key: 'configuration', text: 'Configuration' })).toBeDefined()
  expect(await band.find({ key: 'band-4-configuration' })).toBeDefined()
  expect(shown()[SESSION]).toEqual({ profile: '', scope: '', untilText: '' })
  // The other sessions' entries stay.
  expect(shown()['session-0']).toEqual({ profile: 'meeting', untilText: '' })

  world.active = { ...OFF, profile: 'work', why: 'on Wi-Fi OfficeNet', scope: 'rule', parts: WORK, untilText: '15:00' }
  await $.command.run(command(''))

  // The band keeps its plain button: the status line says what is on.
  expect(await band.find({ key: 'configuration', text: 'Configuration' })).toBeDefined()
  expect(shown()[SESSION]).toEqual({ profile: 'work', scope: 'rule', untilText: '15:00' })
})

test('the pane opens on its Do not disturb tab: a profile pressed asks until when and where, then Activate; a name creates one', async ($, on) => {
  const calls: string[][] = []
  answer(on, { active: OFF, profiles: { work: WORK }, rules: [] }, calls)

  await $.session.start(START)
  await $.command.run({ ...command(''), command: 'configuration' })
  const pane = await mountPane($)

  expect(await pane.find({ key: 'tab-dnd', text: 'Do not disturb' })).toBeDefined()

  await pane.press({ key: 'turn-on-work' })

  expect(await pane.find({ text: 'Turn on work:' })).toBeDefined()
  expect(await pane.find({ key: 'until-off', props: { variant: 'primary' } })).toBeDefined()
  expect(await pane.find({ key: 'where-session', props: { variant: 'primary' } })).toBeDefined()

  await pane.press({ key: 'until-2h' })
  await pane.press({ key: 'where-everywhere' })

  expect(await pane.find({ key: 'until-2h', props: { variant: 'primary' } })).toBeDefined()
  expect(await pane.find({ key: 'where-everywhere', text: 'all computers', props: { variant: 'primary' } })).toBeDefined()
  expect(calls.some(argv => argv[0] === 'on')).toBe(false)

  await pane.press({ key: 'activate' })

  expect(calls).toContainEqual(['on', 'work', '2h', '--everywhere'])
  expect(await pane.find({ text: 'Turn on work:' })).toBeUndefined()
  expect(await pane.find({ text: 'work (on)' })).toBeDefined()

  await pane.input({ key: 'new-profile', text: 'at the office', kind: 'submit' })

  expect(calls).toContainEqual(['set', 'at-the-office', 'history', 'show'])
})

test('/dnd PROFILE without where asks in the pane, its length picked, this session first; a length of its own is offered', async ($, on) => {
  const calls: string[][] = []
  answer(on, { active: OFF, profiles: { work: WORK, meeting: { history: { mode: 'hide' } } }, rules: [] }, calls)

  await $.session.start(START)
  const said = await $.command.run(command('meeting 1h'))

  expect(said.text).toMatch(/this session, this computer or all computers/)
  expect(calls.some(argv => argv[0] === 'on')).toBe(false)

  const pane = await mountPane($)

  expect(await pane.find({ text: 'Turn on meeting:' })).toBeDefined()
  expect(await pane.find({ key: 'until-1h', props: { variant: 'primary' } })).toBeDefined()

  await pane.press({ key: 'activate' })

  expect(calls).toContainEqual(['on', 'meeting', '1h', '--session', SESSION])
  expect(await pane.find({ text: 'Turn on meeting:' })).toBeUndefined()
  expect(await pane.find({ text: /On: meeting \(turned on by hand\) until 15:00/ })).toBeDefined()

  await $.command.run(command('work 14:30'))

  expect(await pane.find({ key: 'until-14:30', text: '14:30', props: { variant: 'primary' } })).toBeDefined()
})

test('/dnd PROFILE pc or all turns it on at once for the computer or every one, /dnd off takes every switch off', async ($, on) => {
  const calls: string[][] = []
  answer(on, { active: OFF, profiles: { work: WORK }, rules: [] }, calls)

  await $.session.start(START)
  const said = await $.command.run(command('work pc'))

  expect(calls).toContainEqual(['on', 'work'])
  expect(said.text).toBe('DnD work on for this computer.')

  const everywhere = await $.command.run(command('work all'))

  expect(calls).toContainEqual(['on', 'work', '--everywhere'])
  expect(everywhere.text).toBe('DnD work on for all computers.')

  const off = await $.command.run(command('off'))

  expect(calls).toContainEqual(['off', '--session', SESSION])
  expect(calls).toContainEqual(['off'])
  expect(off.text).toBe('DnD off: everything shows.')
})

test('each profile is one line whose edit opens its parts, a button per mode; the checklist offers every repo', async ($, on) => {
  const calls: string[][] = []
  answer(on, { active: OFF, profiles: { work: WORK }, rules: [{ profile: 'work', wifi: 'OfficeNet' }] }, calls)

  await $.session.start(START)
  await $.command.run(command(''))
  const pane = await mountPane($)

  // Listed at once, folded to their line.
  expect(await pane.find({ text: 'Profiles (1)' })).toBeDefined()
  expect(await pane.find({ text: /▸ work \(rule\) · no history/ })).toBeDefined()
  expect(await pane.find({ key: 'mode-work-history-show' })).toBeUndefined()

  await pane.press({ key: 'edit-work' })

  expect(await pane.find({ key: 'mode-work-history-hide' })).toBeDefined()
  expect(await pane.find({ key: 'mode-work-prs-only', text: 'only…' })).toBeDefined()
  expect(await pane.find({ text: '[x] this folder (shop)' })).toBeDefined()
  expect(await pane.find({ text: '[ ] owner/app' })).toBeDefined()
  expect(await pane.find({ text: '[ ] someone/garden' })).toBeDefined()
  // A repo listed both ways is offered once.
  expect(await pane.findAll({ type: 'Button', text: /\[ \] (owner\/)?app$/ })).toHaveLength(1)
  expect(await pane.find({ text: 'Wi-Fi OfficeNet' })).toBeDefined()

  await pane.press({ key: 'check-work-prs-someone/garden' })

  expect(calls).toContainEqual(['set', 'work', 'prs', 'only', '@here', 'someone/garden'])

  await pane.press({ key: 'mode-work-history-show' })

  expect(calls).toContainEqual(['set', 'work', 'history', 'show'])

  await pane.press({ key: 'add-work-+ in shop' })

  expect(calls).toContainEqual(['rule', 'work', 'folder=/home/someone/dev/shop'])
})

test('a checklist press shows at once; the presses are written in turn and everything is read once after the last', async ($, on) => {
  const calls: string[][] = []
  let release = () => {}
  const held = new Promise<void>(resolve => {
    release = resolve
  })
  answer(on, { active: OFF, profiles: { work: WORK }, rules: [] }, calls, held)

  await $.session.start(START)
  await $.command.run(command(''))
  const pane = await mountPane($)
  await pane.press({ key: 'edit-work' })
  const reads = calls.filter(([action]) => action === 'json').length

  await pane.press({ key: 'check-work-prs-someone/garden' })
  await pane.press({ key: 'check-work-prs-owner/app' })

  expect(await pane.find({ text: '[x] someone/garden' })).toBeDefined()
  expect(await pane.find({ text: '[x] owner/app' })).toBeDefined()
  expect(calls.filter(([action]) => action === 'set')).toHaveLength(1)

  release()
  await held
  await pane.press({ key: 'tab-dnd' })

  expect(calls).toContainEqual(['set', 'work', 'prs', 'only', '@here', 'someone/garden'])
  expect(calls).toContainEqual(['set', 'work', 'prs', 'only', '@here', 'someone/garden', 'owner/app'])
  expect(calls.filter(([action]) => action === 'json').length).toBe(reads + 1)
  expect(await pane.find({ text: '[x] someone/garden' })).toBeDefined()
})

const HISTORY_ROW = {
  key: 'recent-prompts.questions',
  label: 'Keep questions asked with the picker',
  kind: 'boolean',
  value: true,
  provider: { plugin: 'recent-prompts', tier: 'user' },
  isLocked: false,
}
const BUILTIN_ROW = { ...HISTORY_ROW, key: 'agents-md.instructionFiles', label: 'Instruction files', kind: 'text', value: 'both', provider: { plugin: 'agents-md', tier: 'builtin' } }

// The /config rows the Mods tab reads and writes; a set lands in settings.json as the engine would.
const answerMods = (on: On, files: Files, sets: unknown[]) => {
  const rows = [HISTORY_ROW, BUILTIN_ROW]
  on('config.list', () => ({ value: rows as never }))
  on('config.set', ($, e) => {
    sets.push([e.key, e.value])
    rows[0] = { ...HISTORY_ROW, value: e.value as boolean }
    files['~/.claude/settings.json'] = JSON.stringify({ pluginConfigs: { 'recent-prompts@inline': { options: { questions: e.value } } } })

    return { value: e.value }
  })
}

const openMods = async ($: Engine) => {
  await $.session.start(START)
  await $.command.run({ ...command(''), command: 'configuration' })
  const pane = await mountPane($)
  await pane.press({ key: 'tab-mods' })

  return pane
}

test("the Mods tab lists each mod's settings; a change for all computers is a /config change alone", async ($, on) => {
  const files: Files = { '~/.claude-sync/.machine': 'mac\n', '~/.claude-sync/machines/mac.json': '{ "settings": { "theme": "dark" } }' }
  const sets: unknown[] = []
  answer(on, { active: OFF, profiles: {}, rules: [] }, [], undefined, files)
  answerMods(on, files, sets)

  const pane = await openMods($)

  expect(await pane.find({ key: 'fold-mod|recent-prompts', text: /recent-prompts \(1\)/ })).toBeDefined()
  expect(await pane.find({ text: /Instruction files/ })).toBeUndefined()
  expect(await pane.find({ key: 'scope-here', text: 'this computer only (mac)' })).toBeDefined()

  await pane.press({ key: 'set-recent-prompts.questions' })

  expect(sets).toEqual([['recent-prompts.questions', false]])
  expect(JSON.parse(files['~/.claude-sync/machines/mac.json'] ?? '')).toEqual({ settings: { theme: 'dark' } })
  expect(await pane.find({ key: 'set-recent-prompts.questions', text: /^\[ \] Keep questions/ })).toBeDefined()
})

test('a change for this computer only is kept in its machine file, and one for all computers takes it back out', async ($, on) => {
  const files: Files = { '~/.claude-sync/.machine': 'mac\n', '~/.claude-sync/machines/mac.json': '{ "settings": { "theme": "dark" } }' }
  const sets: unknown[] = []
  answer(on, { active: OFF, profiles: {}, rules: [] }, [], undefined, files)
  answerMods(on, files, sets)

  const pane = await openMods($)
  await pane.press({ key: 'scope-here' })
  await pane.press({ key: 'set-recent-prompts.questions' })

  expect(JSON.parse(files['~/.claude-sync/machines/mac.json'] ?? '')).toEqual({
    settings: { theme: 'dark', pluginConfigs: { 'recent-prompts@inline': { options: { questions: false } } } },
  })
  expect(await pane.find({ key: 'set-recent-prompts.questions', text: /\(this computer\)$/ })).toBeDefined()

  await pane.press({ key: 'scope-all' })
  await pane.press({ key: 'set-recent-prompts.questions' })

  expect(sets).toEqual([
    ['recent-prompts.questions', false],
    ['recent-prompts.questions', true],
  ])
  expect(JSON.parse(files['~/.claude-sync/machines/mac.json'] ?? '')).toEqual({ settings: { theme: 'dark' } })
})

test('without a private sync, the Mods tab says changes stay on this computer', async ($, on) => {
  const files: Files = {}
  answer(on, { active: OFF, profiles: {}, rules: [] }, [], undefined, files)
  answerMods(on, files, [])

  const pane = await openMods($)

  expect(await pane.find({ key: 'scope-here' })).toBeUndefined()
  expect(await pane.find({ text: /no private sync/ })).toBeDefined()
})

test('deleting a profile asks for a second press', async ($, on) => {
  const calls: string[][] = []
  answer(on, { active: OFF, profiles: { work: WORK }, rules: [] }, calls)

  await $.session.start(START)
  await $.command.run(command(''))
  const pane = await mountPane($)

  await pane.press({ key: 'arm-delete|work' })

  expect(calls.some(argv => argv[0] === 'delete')).toBe(false)

  await pane.press({ key: 'confirm-delete|work' })

  expect(calls).toContainEqual(['delete', 'work'])
})
