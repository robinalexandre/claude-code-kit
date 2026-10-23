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

const isScript = (argv: string[]) => (argv[1] ?? '').replace(/\\/g, '/').endsWith('/skills/dnd/dnd.sh')

const answer = (on: On, world: World, calls: string[][]) => {
  const clock = mock.clock(on)
  on('env.get', () => ({ value: undefined }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('session.cwd', () => ({ value: '/home/someone/dev/shop' }))
  on('session.id', () => ({ value: SESSION }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('process.run', ($, e) => {
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
      return ran(0, JSON.stringify({ ...world, known: { prs: ['owner/app'] }, wifi: 'OfficeNet', file: '/home/someone/.claude-sync/dnd/profiles.json' }))
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

test('a Configuration button on the band says which profile is on, read at session start', async ($, on) => {
  const calls: string[][] = []
  const world: World = { active: OFF, profiles: { work: WORK }, rules: [] }
  answer(on, world, calls)

  await $.session.start(START)
  const band = await mountBand($)

  expect(calls).toContainEqual(['active', '/home/someone/dev/shop', '--session', SESSION])
  expect(await band.find({ key: 'configuration', text: 'Configuration' })).toBeDefined()
  expect(await band.find({ key: 'band-4-configuration' })).toBeDefined()

  world.active = { ...OFF, profile: 'work', why: 'on Wi-Fi OfficeNet', scope: 'rule', parts: WORK }
  await $.command.run(command(''))

  expect(await band.find({ key: 'configuration', text: 'Configuration · dnd work' })).toBeDefined()
})

test('the pane opens on its Do not disturb tab: a press per profile turns one on, a name creates one', async ($, on) => {
  const calls: string[][] = []
  answer(on, { active: OFF, profiles: { work: WORK }, rules: [] }, calls)

  await $.session.start(START)
  await $.command.run({ ...command(''), command: 'configuration' })
  const pane = await mountPane($)

  expect(await pane.find({ key: 'tab-dnd', text: 'Do not disturb' })).toBeDefined()

  await pane.press({ key: 'turn-on-work' })

  expect(await pane.find({ text: 'Turn on work:' })).toBeDefined()

  await pane.press({ key: 'on-computer-open' })

  expect(calls).toContainEqual(['on', 'work'])
  expect(await pane.find({ text: 'work (on)' })).toBeDefined()

  await pane.input({ key: 'new-profile', text: 'at the office', kind: 'submit' })

  expect(calls).toContainEqual(['set', 'at-the-office', 'history', 'show'])
})

test('/dnd PROFILE without where asks: this session or the whole computer', async ($, on) => {
  const calls: string[][] = []
  answer(on, { active: OFF, profiles: { work: WORK, meeting: { history: { mode: 'hide' } } }, rules: [] }, calls)

  await $.session.start(START)
  const said = await $.command.run(command('meeting 1h'))

  expect(said.text).toMatch(/this session or the whole computer/)
  expect(calls.some(argv => argv[0] === 'on')).toBe(false)

  const pane = await mountPane($)

  expect(await pane.find({ text: 'Turn on meeting for 1h:' })).toBeDefined()

  await pane.press({ key: 'on-session-1h' })

  expect(calls).toContainEqual(['on', 'meeting', '1h', '--session', SESSION])
  expect(await pane.find({ text: 'Turn on meeting for 1h:' })).toBeUndefined()
  expect(await pane.find({ text: /On: meeting \(turned on by hand\) until 15:00/ })).toBeDefined()
})

test('/dnd PROFILE all turns it on for the computer at once, /dnd off takes both switches off', async ($, on) => {
  const calls: string[][] = []
  answer(on, { active: OFF, profiles: { work: WORK }, rules: [] }, calls)

  await $.session.start(START)
  const said = await $.command.run(command('work all'))

  expect(calls).toContainEqual(['on', 'work'])
  expect(said.text).toBe('DnD work on.')

  const off = await $.command.run(command('off'))

  expect(calls).toContainEqual(['off', '--session', SESSION])
  expect(calls).toContainEqual(['off'])
  expect(off.text).toBe('DnD off: everything shows.')
})

test('a profile unfolds to what it shows; a press changes a part, a check keeps a name', async ($, on) => {
  const calls: string[][] = []
  answer(on, { active: OFF, profiles: { work: WORK }, rules: [{ profile: 'work', wifi: 'OfficeNet' }] }, calls)

  await $.session.start(START)
  await $.command.run(command(''))
  const pane = await mountPane($)

  // Folded by default: the section, its group, the profile.
  expect(await pane.find({ text: '▸ Profiles (1)' })).toBeDefined()
  expect(await pane.find({ text: /Turned on by a rule/ })).toBeUndefined()

  await pane.press({ key: 'fold-profiles' })
  await pane.press({ key: 'fold-group|Turned on by a rule' })

  expect(await pane.find({ text: /▸ work · no history · prs & ci: this folder/ })).toBeDefined()

  await pane.press({ key: 'fold-profile|work' })

  expect(await pane.find({ text: 'History: hidden' })).toBeDefined()
  expect(await pane.find({ text: '[x] this folder (shop)' })).toBeDefined()
  expect(await pane.find({ text: '[ ] owner/app' })).toBeDefined()
  expect(await pane.find({ text: 'Wi-Fi OfficeNet' })).toBeDefined()

  await pane.press({ key: 'check-work-prs-owner/app' })

  expect(calls).toContainEqual(['set', 'work', 'prs', 'only', '@here', 'owner/app'])

  await pane.press({ key: 'mode-work-history' })

  expect(calls).toContainEqual(['set', 'work', 'history', 'show'])

  await pane.press({ key: 'add-work-+ in shop' })

  expect(calls).toContainEqual(['rule', 'work', 'folder=/home/someone/dev/shop'])
})

test('deleting a profile asks for a second press', async ($, on) => {
  const calls: string[][] = []
  answer(on, { active: OFF, profiles: { work: WORK }, rules: [] }, calls)

  await $.session.start(START)
  await $.command.run(command(''))
  const pane = await mountPane($)

  await pane.press({ key: 'fold-profiles' })
  await pane.press({ key: 'fold-group|By hand only' })
  await pane.press({ key: 'arm-delete|work' })

  expect(calls.some(argv => argv[0] === 'delete')).toBe(false)

  await pane.press({ key: 'confirm-delete|work' })

  expect(calls).toContainEqual(['delete', 'work'])
})
