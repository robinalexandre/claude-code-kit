import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

const REMINDERS = '/home/someone/.claude/skills/reminders/reminders.sh'
const HANDOFF = '/home/someone/.claude/skills/handoff/handoff.sh'
const SCROLL = { offset: 0, bodyRows: 30 }
const PANE_PROPS = { title: 'Reminders & Handoffs', isFocused: true, bodyColumns: 72, placement: 'dock' as const, scroll: SCROLL, view: {} }
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

const answerBeneath = (on: On, world: World, calls: string[][], submitted: string[] = [], isNameTaken = false) => {
  const clock = mock.clock(on)
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? '/home/someone' : undefined }))
  // The engine hands the path on as the system writes it (C:\home\... on Windows).
  on('fs.exists', ($, e) => ({ value: world.installed.some(path => e.path.replace(/\\/g, '/').endsWith(path)) }))
  on('command.register', ($, e) => (isNameTaken ? { deny: `it is the user's /${e.name}` } : { value: { command: e.name } }))
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
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))

  return clock
}

const mountPane = ($: Engine) =>
  $.ui.mount({ plugin: 'reminders-handoffs', surface: 'terminal', component: 'Pane', requestId: 'reminders-handoffs', props: PANE_PROPS })

const mountBand = ($: Engine) => $.ui.mount({ plugin: 'reminders-handoffs', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })

test('/reminders lists them by section, done closes a repeating one for today', async ($, on) => {
  const calls: string[][] = []
  const world: World = { reminders: [WEEKLY, LATER, PAST], handoffs: [], installed: [REMINDERS] }
  answerBeneath(on, world, calls)

  await $.session.start(START)
  await $.command.run(command('reminders-pane'))
  const pane = await mountPane($)

  expect(calls).toContainEqual(['bash', REMINDERS, 'json', '/home/someone/dev/shop'])
  // Only the reminders skill is installed: no tabs.
  expect(await pane.find({ key: 'tab-reminders' })).toBeUndefined()
  // Every section starts folded.
  expect(await pane.find({ text: '▸ Now (1)' })).toBeDefined()
  expect(await pane.find({ text: '▸ Upcoming (1)' })).toBeDefined()
  expect(await pane.find({ text: '▸ Past (1)' })).toBeDefined()
  expect(await pane.find({ text: ' · now' })).toBeUndefined()

  await pane.press({ key: 'now' })
  await pane.press({ key: 'upcoming' })

  expect(await pane.find({ text: ' · now' })).toBeDefined()
  expect(await pane.find({ text: /02\/11/ })).toBeDefined()
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
  await $.command.run(command('reminders-pane'))
  const pane = await mountPane($)

  await pane.press({ key: 'now' })
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
  const work = { ...LATER, id: 'review', title: 'Review the plan', group: 'Work' }
  const shop = { ...LATER, id: 'deploy', title: 'Deploy the shop', state: 'elsewhere', where: 'dev/shop', machine: 'mac' }
  answerBeneath(on, { reminders: [LATER, work, shop], handoffs: [], installed: [REMINDERS] }, [])

  await $.session.start(START)
  await $.command.run(command('reminders-pane'))
  const pane = await mountPane($)

  await pane.press({ key: 'upcoming' })

  expect(await pane.find({ text: '▾ Upcoming (3)' })).toBeDefined()
  expect(await pane.find({ text: '▸ Work (1)' })).toBeDefined()
  expect(await pane.find({ text: '▸ shop (1)' })).toBeDefined()
  expect(await pane.find({ text: '▸ General (1)' })).toBeDefined()
  expect(await pane.find({ text: /Review the plan/ })).toBeUndefined()

  await pane.press({ key: 'group-upcoming-Work' })
  await pane.press({ key: 'group-upcoming-shop' })

  expect(await pane.find({ text: '▾ Work (1)' })).toBeDefined()
  expect(await pane.find({ text: /Review the plan/ })).toBeDefined()
  expect(await pane.find({ text: /only in shop on mac/ })).toBeDefined()
})

test('pick hands a reminder to the session; restore puts a past one back', async ($, on) => {
  const calls: string[][] = []
  const submitted: string[] = []
  const world: World = { reminders: [WEEKLY, PAST], handoffs: [], installed: [REMINDERS] }
  answerBeneath(on, world, calls, submitted)

  await $.session.start(START)
  await $.command.run(command('reminders-pane'))
  const pane = await mountPane($)

  await pane.press({ key: 'now' })
  await pane.press({ key: 'pick-timesheet' })

  expect(submitted).toEqual(['Let\'s do the reminder timesheet now: "Fill the timesheet".'])

  await pane.press({ key: 'past' })
  world.reminders = [WEEKLY, { ...PAST, state: 'due', closed: undefined }]
  await pane.press({ key: 'restore-old' })

  expect(calls).toContainEqual(['bash', REMINDERS, 'restore', 'old'])
  expect(await pane.find({ text: '▾ Now (2)' })).toBeDefined()
})

test('with both skills, a tab each; pick hands the note to the session, cancel asks twice', async ($, on) => {
  const calls: string[][] = []
  const submitted: string[] = []
  answerBeneath(on, { reminders: [LATER], handoffs: [NOTE], installed: [REMINDERS, HANDOFF] }, calls, submitted)

  await $.session.start(START)
  await $.command.run(command('handoffs-pane'))
  const pane = await mountPane($)

  expect(await pane.find({ text: '▸ Open (1)' })).toBeDefined()

  await pane.press({ key: 'open-notes' })

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
  await pane.press({ key: 'upcoming' })

  expect(await pane.find({ text: /Dentist/ })).toBeDefined()
})

test('the band is named after the skills installed, and stays with nothing in them', async ($, on) => {
  const world: World = { reminders: [WEEKLY, LATER], handoffs: [NOTE], installed: [REMINDERS, HANDOFF] }
  answerBeneath(on, world, [])

  await $.session.start(START)
  await $.command.run(command('reminders-pane'))

  expect(await (await mountBand($)).find({ key: 'reminders-handoffs', text: 'Reminders 1 now · Handoffs 1' })).toBeDefined()

  world.reminders = []
  world.handoffs = []
  await $.command.run(command('reminders-pane'))

  expect(await (await mountBand($)).find({ key: 'reminders-handoffs', text: 'Reminders · Handoffs' })).toBeDefined()
})

test('the band has no button when neither skill is installed', async ($, on) => {
  answerBeneath(on, { reminders: [WEEKLY], handoffs: [NOTE], installed: [] }, [])

  await $.session.start(START)

  expect(await (await mountBand($)).find({ key: 'reminders-handoffs' })).toBeUndefined()
})

test('after a /clear the band is set up again and reloaded, before any message', async ($, on) => {
  const calls: string[][] = []
  const clock = answerBeneath(on, { reminders: [WEEKLY], handoffs: [], installed: [REMINDERS] }, calls)

  await $.session.start(START)
  await clock.advance(0)
  const before = calls.length
  await $.session.end({ reason: 'clear', sessionId: 'old', resume: { id: 'old' } })
  await clock.advance(0)

  expect(calls.length).toBeGreaterThan(before)
  expect(await (await mountBand($)).find({ key: 'reminders-handoffs', text: 'Reminders 1 now' })).toBeDefined()
})

test('the band button joins the shared row of the mods beneath, in key order', async ($, on) => {
  // What two other mods drew beneath: a history line, then the shared row with their buttons.
  // Answered before answerBeneath's catch-all, which would draw nothing.
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)

    return Box({
      flexDirection: 'column',
      children: [
        Text({ children: '❯ last message' }),
        Box({
          key: 'band-buttons',
          flexDirection: 'row',
          children: [
            Box({ key: 'band-2-prs', children: Button({ key: 'prs', label: 'PRs & CI', onPress: () => undefined }) }),
            Box({ key: 'band-1-history', children: Button({ key: 'history', label: 'history', onPress: () => undefined }) }),
          ],
        }),
      ],
    })
  })
  answerBeneath(on, { reminders: [WEEKLY], handoffs: [], installed: [REMINDERS] }, [])

  await $.session.start(START)
  await $.command.run(command('reminders-pane'))
  const band = await mountBand($)
  const rows = await band.findAll({ key: 'band-buttons' })
  const drawn = JSON.stringify(rows[0] ?? {})
  const order = ['band-1-history', 'band-2-prs', 'band-3-reminders'].map(key => drawn.indexOf(key))

  expect(rows).toHaveLength(1)
  expect(order.every((at, index) => at >= 0 && (index === 0 || at > (order[index - 1] ?? 0)))).toBe(true)
  expect(await band.find({ text: '❯ last message' })).toBeDefined()
})

test('a command name already taken does not stop the session start', async ($, on) => {
  const calls: string[][] = []
  answerBeneath(on, { reminders: [WEEKLY], handoffs: [], installed: [REMINDERS] }, calls, [], true)

  await $.session.start(START)
  await $.command.run(command('reminders-pane'))

  expect(calls).toContainEqual(['bash', REMINDERS, 'json', '/home/someone/dev/shop'])
})

test('refresh reads the lists, syncs, reads them again, and says when', async ($, on) => {
  const calls: string[][] = []
  const world: World = { reminders: [LATER], handoffs: [], installed: [REMINDERS] }
  const clock = answerBeneath(on, world, calls)
  await clock.set(new Date(2026, 9, 22, 18, 7).getTime())

  await $.session.start(START)
  await $.command.run(command('reminders-pane'))
  const pane = await mountPane($)

  expect(await pane.find({ text: 'live at 18:07' })).toBeDefined()

  await clock.advance(5 * 60_000)
  world.reminders = [LATER, WEEKLY]
  const before = calls.length
  await pane.press({ key: 'refresh' })
  const after = calls.slice(before).map(argv => argv.join(' '))

  expect(after.filter(argv => argv.endsWith('json /home/someone/dev/shop'))).toHaveLength(2)
  expect(after.some(argv => argv.includes('.claude-sync/sync.sh" now'))).toBe(true)
  expect(await pane.find({ text: 'live at 18:12' })).toBeDefined()
  expect(await pane.find({ text: '▸ Now (1)' })).toBeDefined()
})

test('a skill found again later brings the band button back', async ($, on) => {
  const world: World = { reminders: [WEEKLY], handoffs: [], installed: [] }
  const clock = answerBeneath(on, world, [])

  await $.session.start(START)
  await clock.advance(0)

  expect(await (await mountBand($)).find({ key: 'reminders-handoffs' })).toBeUndefined()

  world.installed = [REMINDERS]
  await clock.advance(60_000)
  await mountBand($)
  await clock.advance(0)

  expect(await (await mountBand($)).find({ key: 'reminders-handoffs', text: 'Reminders 1 now' })).toBeDefined()
})

const lookOn = async (on: On, $: Engine, base: string) => {
  on('session.version', () => ({ value: { version: base, base } }))
  answerBeneath(on, { reminders: [WEEKLY], handoffs: [NOTE], installed: [REMINDERS, HANDOFF] }, [])

  await $.session.start(START)
  await $.command.run(command('reminders-pane'))
  const pane = await mountPane($)

  return [
    await pane.find({ type: 'Text', text: '▸ Now (1)' }),
    await pane.find({ type: 'Text', text: 'Reminders (1, 1 now)' }),
    await pane.find({ key: 'now' }),
  ]
}

test('from 2.1.306 the section titles and tabs are styled Text inside their buttons', async ($, on) => {
  const [section, tab] = await lookOn(on, $, '2.1.306')

  expect(section?.props.bold).toBe(true)
  expect(tab?.props.underline).toBe(true)
})

test('before 2.1.306 every button has a plain label', async ($, on) => {
  const [section, tab, button] = await lookOn(on, $, '2.1.192')

  expect(section).toBeUndefined()
  expect(tab).toBeUndefined()
  expect(button?.props.label).toBe('▸ Now (1)')
})

test('with only the handoff skill, the band says Handoffs', async ($, on) => {
  answerBeneath(on, { reminders: [], handoffs: [NOTE], installed: [HANDOFF] }, [])

  await $.session.start(START)
  await $.command.run(command('handoffs-pane'))

  expect(await (await mountBand($)).find({ key: 'reminders-handoffs', text: 'Handoffs 1' })).toBeDefined()
})
