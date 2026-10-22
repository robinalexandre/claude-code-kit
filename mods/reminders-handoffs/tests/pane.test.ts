import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

const REMINDERS = '/home/someone/.claude/skills/reminders/reminders.sh'
const HANDOFF = '/home/someone/.claude/skills/handoff/handoff.sh'
const SCROLL = { offset: 0, bodyRows: 30 }
const PANE_PROPS = { title: 'Reminders & Handoffs', isFocused: true, bodyColumns: 64, placement: 'dock' as const, scroll: SCROLL, view: {} }
const BAND_PROPS = { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 80, scroll: SCROLL, view: {} }
const START = { cwd: '/home/someone/dev/shop', surface: 'terminal' as const, isInteractive: true }
const command = (name: string) => ({ command: name, args: '', origin: { kind: 'composer' as const }, presentation: { isFullscreen: true, columns: 160 } })
const ran = (exitCode: number, stdout: string, stderr = '') => ({
  value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false },
})

const WEEKLY = {
  id: 'timesheet',
  state: 'due',
  title: 'Fill the timesheet',
  on: '2026-10-23',
  every: 'friday',
  next: '2026-10-23 09:00',
  body: 'Propose the week from the sessions.',
}
const LATER = { id: 'dentist', state: 'later', title: 'Dentist', on: '2026-11-02', body: 'At 10:00.' }
const PAST = { id: 'old', state: 'past', title: 'Old one', on: '2026-10-01', closed: '2026-10-02 09:00' }
const NOTE = {
  id: 'migration',
  state: 'open',
  title: 'Speed up the migration',
  from: 'mac',
  date: '2026-10-20 23:30',
  repo: 'owner/app',
  branch: 'perf/migration',
  isMine: false,
  body: '## Next steps\nRun the job.',
}

type World = { reminders: object[]; handoffs: object[]; installed: string[] }

const answerBeneath = (on: On, world: World, calls: string[][], submitted: string[] = []) => {
  mock.clock(on)
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? '/home/someone' : undefined }))
  // The engine hands the path on as the system writes it (C:\home\... on Windows).
  on('fs.exists', ($, e) => ({ value: world.installed.some(path => e.path.replace(/\\/g, '/').endsWith(path)) }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('session.cwd', () => ({ value: '/home/someone/dev/shop' }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('process.run', ($, e) => {
    calls.push([...e.argv])
    const [, path, action] = e.argv

    if (action !== 'json') {
      return ran(0, '')
    }

    return ran(0, JSON.stringify(path === HANDOFF ? world.handoffs : world.reminders))
  })
  on('prompt.submit', ($, e) => {
    submitted.push(e.text)

    return { text: e.text }
  })
  on('ui.render', () => Fragment({}))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
}

const mountPane = ($: Engine) =>
  $.ui.mount({ plugin: 'reminders-handoffs', surface: 'terminal', component: 'Pane', requestId: 'reminders-handoffs', props: PANE_PROPS })

const mountBand = ($: Engine) => $.ui.mount({ plugin: 'reminders-handoffs', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })

test('/reminders lists them by section, done closes a repeating one for today', async ($, on) => {
  const calls: string[][] = []
  const world: World = { reminders: [WEEKLY, LATER, PAST], handoffs: [], installed: [REMINDERS] }
  answerBeneath(on, world, calls)

  await $.session.start(START)
  await $.command.run(command('reminders'))
  const pane = await mountPane($)

  expect(calls).toContainEqual(['bash', REMINDERS, 'json', '/home/someone/dev/shop'])
  // Only the reminders skill is installed: no tabs.
  expect(await pane.find({ key: 'tab-reminders' })).toBeUndefined()
  expect(await pane.find({ text: '▾ Now (1)' })).toBeDefined()
  expect(await pane.find({ text: /now · every friday/ })).toBeDefined()
  expect(await pane.find({ text: '▾ Upcoming (1)' })).toBeDefined()
  expect(await pane.find({ text: /02\/11/ })).toBeDefined()
  expect(await pane.find({ text: '▸ Past (1)' })).toBeDefined()
  expect(await pane.find({ text: /Old one/ })).toBeUndefined()

  await pane.press({ key: 'toggle-timesheet' })

  expect(await pane.find({ text: /Repeats: every friday/ })).toBeDefined()
  expect(await pane.find({ text: 'Propose the week from the sessions.' })).toBeDefined()

  world.reminders = [{ ...WEEKLY, state: 'later', done: '2026-10-23', next: '2026-10-30 09:00' }, LATER, PAST]
  await pane.press({ key: 'done-timesheet' })

  expect(calls).toContainEqual(['bash', REMINDERS, 'done', 'timesheet'])
  expect(await pane.find({ text: '▾ Now (0)' })).toBeDefined()
  expect(await pane.find({ text: /30\/10 09:00 · every friday/ })).toBeDefined()
})

test('stop and delete ask for a second press', async ($, on) => {
  const calls: string[][] = []
  answerBeneath(on, { reminders: [WEEKLY, PAST], handoffs: [], installed: [REMINDERS] }, calls)

  await $.session.start(START)
  await $.command.run(command('reminders'))
  const pane = await mountPane($)

  await pane.press({ key: 'stop-timesheet' })

  expect(calls.some(argv => argv[2] === 'stop')).toBe(false)
  expect(await pane.find({ text: 'stop? press again' })).toBeDefined()

  await pane.press({ key: 'stop-timesheet' })

  expect(calls).toContainEqual(['bash', REMINDERS, 'stop', 'timesheet'])

  await pane.press({ key: 'past' })
  await pane.press({ key: 'delete-old' })
  await pane.press({ key: 'delete-old' })

  expect(calls).toContainEqual(['bash', REMINDERS, 'delete', 'old'])
})

test('several groups in a section each get a title that folds them', async ($, on) => {
  const work = { ...LATER, id: 'review', title: 'Review the plan', group: 'Covea' }
  const shop = { ...LATER, id: 'deploy', title: 'Deploy the shop', state: 'elsewhere', where: 'dev/shop', machine: 'mac' }
  answerBeneath(on, { reminders: [LATER, work, shop], handoffs: [], installed: [REMINDERS] }, [])

  await $.session.start(START)
  await $.command.run(command('reminders'))
  const pane = await mountPane($)

  expect(await pane.find({ text: '▾ Upcoming (3)' })).toBeDefined()
  expect(await pane.find({ text: '▾ Covea (1)' })).toBeDefined()
  expect(await pane.find({ text: '▾ shop (1)' })).toBeDefined()
  expect(await pane.find({ text: '▾ General (1)' })).toBeDefined()
  expect(await pane.find({ text: /only in shop on mac/ })).toBeDefined()

  await pane.press({ key: 'group-upcoming-Covea' })

  expect(await pane.find({ text: '▸ Covea (1)' })).toBeDefined()
  expect(await pane.find({ text: /Review the plan/ })).toBeUndefined()
})

test('with both skills, a tab each; pick hands the note to the session, cancel asks twice', async ($, on) => {
  const calls: string[][] = []
  const submitted: string[] = []
  answerBeneath(on, { reminders: [LATER], handoffs: [NOTE], installed: [REMINDERS, HANDOFF] }, calls, submitted)

  await $.session.start(START)
  await $.command.run(command('handoffs'))
  const pane = await mountPane($)

  const found = [
    await pane.find({ key: 'tab-reminders', text: 'Reminders (1)' }),
    await pane.find({ key: 'tab-handoffs', text: 'Handoffs (1 open)' }),
    await pane.find({ text: '▾ Open (1)' }),
    // Cut to what the pane leaves beside the buttons.
    await pane.find({ text: /^Speed up the/ }),
    await pane.find({ text: /from mac · 20\/10 23:30/ }),
  ].map(one => one !== undefined)

  expect(found).toEqual([true, true, true, true, true])

  await pane.press({ key: 'pick-migration' })

  expect(submitted).toEqual(['Pick up the handoff migration: "Speed up the migration".'])

  await pane.press({ key: 'cancel-migration' })

  expect(calls.some(argv => argv[2] === 'cancel')).toBe(false)

  await pane.press({ key: 'cancel-migration' })

  expect(calls).toContainEqual(['bash', HANDOFF, 'cancel', 'migration'])

  await pane.press({ key: 'tab-reminders' })

  expect(await pane.find({ text: /Dentist/ })).toBeDefined()
})

test('the band is named after the skills installed, and absent with nothing in them', async ($, on) => {
  const world: World = { reminders: [WEEKLY, LATER], handoffs: [NOTE], installed: [REMINDERS, HANDOFF] }
  answerBeneath(on, world, [])

  await $.session.start(START)
  await $.command.run(command('reminders'))

  expect(await (await mountBand($)).find({ key: 'reminders-handoffs', text: 'Reminders 1 now · Handoffs 1' })).toBeDefined()

  world.reminders = []
  world.handoffs = []
  await $.command.run(command('reminders'))

  expect(await (await mountBand($)).find({ key: 'reminders-handoffs' })).toBeUndefined()
})

test('with only the handoff skill, the band says Handoffs', async ($, on) => {
  answerBeneath(on, { reminders: [], handoffs: [NOTE], installed: [HANDOFF] }, [])

  await $.session.start(START)
  await $.command.run(command('handoffs'))

  expect(await (await mountBand($)).find({ key: 'reminders-handoffs', text: 'Handoffs 1' })).toBeDefined()
})
