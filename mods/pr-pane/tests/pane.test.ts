import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

const SCROLL = { offset: 0, bodyRows: 30 }
const PANE_PROPS = {
  title: 'Tracked PRs',
  isFocused: true,
  bodyColumns: 64,
  placement: 'dock' as const,
  scroll: SCROLL,
  view: {},
}
const RUN = { command: 'prs', args: '', origin: { kind: 'composer' as const }, presentation: { isFullscreen: true, columns: 160 } }
const ran = (exitCode: number, stdout: string, stderr = '') => ({
  value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false },
})

const row = (number: string, fields: Record<string, unknown>) => ({
  url: `https://dev.azure.com/org/project/_git/shop/pullrequest/${number}`,
  repo: 'shop',
  number,
  title: `feat: change ${number}`,
  status: 'active',
  target: 'main',
  ci: 'CI green',
  votes: {},
  waiting: 'a review',
  note: '',
  changes: [],
  checked: '2026-01-01T10:00Z',
  ...fields,
})

const CACHED = { live: false, prs: [row('1', {}), row('2', { ci: 'CI failed', waiting: 'a CI fix' })], errors: [] }
const LIVE = {
  live: true,
  prs: [
    row('1', { votes: { 'Ada Lovelace': 'approved' }, waiting: 'the merge', changes: ['Ada Lovelace voted approved'] }),
    row('2', { ci: 'CI failed', waiting: 'a CI fix' }),
  ],
  errors: [],
}

const mountPane = ($: Engine, surface: 'terminal' | 'desktop') =>
  $.ui.mount({ plugin: 'pr-pane', surface, component: 'Pane', requestId: 'tracked-prs', props: PANE_PROPS })

for (const surface of ['terminal', 'desktop'] as const) {
  test(`/prs lists the tracked PRs, refresh shows live changes and open calls pr-watch (${surface})`, async ($, on) => {
    mock.clock(on)
    const calls: string[][] = []
    on('env.get', ($, e) => ({ value: e.name === 'HOME' ? '/home/someone' : undefined }))
    on('process.run', ($, e) => {
      calls.push([...e.argv])
      const args = e.argv.slice(2).join(' ')
      const stdout = args === 'status' ? JSON.stringify(CACHED) : args === 'status --live' ? JSON.stringify(LIVE) : ''

      return ran(0, stdout)
    })
    on('ui.render', () => Fragment({}))
    on('ui.open', () => ({ value: { isPlaced: true as const } }))

    await $.command.run(RUN)
    const pane = await mountPane($, surface)

    expect(calls[0]).toEqual(['bash', '-c', 'exit 0'])
    expect(calls[1]).toEqual(['bash', '/home/someone/.claude/skills/pr-watch/pr-watch.sh', 'status'])
    expect(await pane.find({ text: /^2 PRs/ })).toBeDefined()
    expect(await pane.find({ text: 'a CI fix' })).toBeDefined()

    await pane.press({ key: 'refresh' })

    expect(calls.some(argv => argv.slice(2).join(' ') === 'status --live')).toBe(true)
    expect(await pane.find({ text: 'the merge' })).toBeDefined()
    expect(await pane.find({ text: /Ada Lovelace voted approved/ })).toBeDefined()
    expect(await pane.find({ text: /live at/ })).toBeDefined()

    await pane.press({ key: 'open-shop-2' })

    expect(calls.at(-1)).toEqual([
      'bash',
      '/home/someone/.claude/skills/pr-watch/pr-watch.sh',
      'open',
      'https://dev.azure.com/org/project/_git/shop/pullrequest/2',
    ])
  })
}

const STACKED = {
  live: false,
  prs: [
    row('10', { repo: 'api', source: 'fix/base', target: 'main', after: '', waiting: 'a review' }),
    row('12', { repo: 'api', source: 'feat/on-top', target: 'fix/base', after: '10', waiting: '#10 to merge first' }),
    row('3', {
      repo: 'web',
      conflicts: true,
      ci: 'CI running',
      checks: [
        { name: 'build', state: 'running', required: true, link: 'https://ci.example/1' },
        { name: 'lint', state: 'passed', required: false, link: null },
      ],
    }),
  ],
  errors: [],
}

test('PRs are grouped per repo in merge order and CI checks show while they run, live every minute', async ($, on) => {
  const clock = mock.clock(on)
  let liveCalls = 0
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? '/home/someone' : undefined }))
  on('process.run', ($, e) => {
    liveCalls += e.argv.includes('--live') ? 1 : 0

    return ran(0, e.argv[2] === 'status' ? JSON.stringify(STACKED) : '')
  })
  on('ui.render', () => Fragment({}))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('ui.panes', () => ({ value: [{ id: 'tracked-prs', title: 'Tracked PRs', isShown: true, isFocused: false, isPlaced: true }] }))

  await $.command.run(RUN)
  const pane = await mountPane($, 'terminal')

  expect(await pane.find({ text: 'api' })).toBeDefined()
  expect(await pane.find({ text: ' · merge top to bottom' })).toBeDefined()
  expect(await pane.find({ text: '#10 to merge first' })).toBeDefined()
  expect(await pane.find({ key: 'ci-web-3', text: '▾ CI 1/2 running' })).toBeDefined()
  expect(await pane.find({ text: ' · optional' })).toBeDefined()
  expect(await pane.find({ text: /⚠ merge conflicts with main/ })).toBeDefined()

  await pane.press({ key: 'ci-web-3' })

  expect(await pane.find({ key: 'ci-web-3', text: '▸ CI 1/2 running' })).toBeDefined()
  expect(await pane.find({ text: ' · optional' })).toBeUndefined()

  const before = liveCalls
  await clock.advance(60_000)

  expect(liveCalls).toBe(before + 1)
})

test('a merge conflict marks the band and the pane asks Claude to rebase and fix it', async ($, on) => {
  mock.clock(on)
  const submitted: string[] = []
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? '/home/someone' : undefined }))
  on('process.run', ($, e) => {
    const conflicted = { ...STACKED, prs: [row('9', { conflicts: true, source: 'feat/x', waiting: 'a conflict fix' })] }

    return ran(0, e.argv[2] === 'status' ? JSON.stringify(conflicted) : '')
  })
  on('ui.render', () => Fragment({}))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('ui.toast', () => ({ value: undefined }))
  on('prompt.submit', ($, e) => {
    submitted.push(e.text)

    return { text: e.text }
  })

  await $.command.run(RUN)
  const band = await $.ui.mount({ plugin: 'pr-pane', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })
  const pane = await mountPane($, 'terminal')

  expect(await band.find({ key: 'prs', text: 'PRs 1 !' })).toBeDefined()

  await pane.press({ key: 'fix-shop-9' })

  expect(submitted).toHaveLength(1)
  expect(submitted[0]).toContain('shop #9')
  expect(submitted[0]).toContain('Rebase `feat/x` onto `main`')
  expect(submitted[0]).toContain('ask before pushing')
})

const FAILING = {
  live: false,
  prs: [
    row('7', {
      ci: 'CI failed',
      waiting: 'a CI fix',
      checks: [{ name: 'build', state: 'failed', required: true, link: 'https://ci.example/7' }],
    }),
  ],
  recent: [
    { url: 'https://github.com/o/shop/pull/5', repo: 'shop', number: '5', title: 'fix: old', status: 'merged', ended: '2026-01-01T09:00Z' },
  ],
  errors: [],
}
const DETAILS = { url: '', checks: [{ name: 'build', state: 'failed', link: null, errors: ['Run tests: failed', '  expected 2, got 3'] }] }

test('a failed check shows its errors, reruns only on a second press, and merged PRs stay listed', async ($, on) => {
  mock.clock(on)
  const calls: string[] = []
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? '/home/someone' : undefined }))
  on('process.run', ($, e) => {
    const command = e.argv.slice(2).join(' ')
    calls.push(command)

    if (command.startsWith('details')) {
      return ran(0, JSON.stringify(DETAILS))
    }

    return ran(0, command.startsWith('status') ? JSON.stringify(FAILING) : 'relaunched build')
  })
  on('ui.render', () => Fragment({}))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('ui.toast', () => ({ value: undefined }))

  await $.command.run(RUN)
  const pane = await mountPane($, 'terminal')

  expect(await pane.find({ key: 'recent', text: '▾ Recently merged or closed (1)' })).toBeDefined()
  expect(await pane.find({ text: 'shop #5' })).toBeDefined()

  await pane.press({ key: 'details-shop-7-build' })

  expect(await pane.find({ text: 'Run tests: failed' })).toBeDefined()
  expect(await pane.find({ text: '  expected 2, got 3' })).toBeDefined()

  await pane.press({ key: 'rerun-shop-7-build' })

  expect(calls.some(command => command.startsWith('rerun'))).toBe(false)
  expect(await pane.find({ key: 'rerun-shop-7-build', text: 'press again to relaunch' })).toBeDefined()

  await pane.press({ key: 'rerun-shop-7-build' })

  expect(calls).toContain('rerun https://dev.azure.com/org/project/_git/shop/pullrequest/7 build')
})

test('on Windows, Git Bash is found from git when bash is not on the PATH', async ($, on) => {
  mock.clock(on)
  const calls: string[][] = []
  on('env.get', ($, e) => ({ value: e.name === 'USERPROFILE' ? 'C:\\Users\\someone' : undefined }))
  on('process.run', ($, e) => {
    calls.push([...e.argv])

    if (e.argv[0] === 'bash') {
      return { deny: "Command 'bash' not found" }
    }

    if (e.argv[0] === 'git') {
      return ran(0, 'C:/Program Files/Git/mingw64/libexec/git-core\n')
    }

    return ran(0, e.argv[2] === 'status' ? JSON.stringify(CACHED) : '')
  })
  on('ui.render', () => Fragment({}))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))

  await $.command.run(RUN)
  const pane = await mountPane($, 'terminal')

  expect(calls).toContainEqual([
    'C:/Program Files/Git/bin/bash.exe',
    'C:/Users/someone/.claude/skills/pr-watch/pr-watch.sh',
    'status',
  ])
  expect(await pane.find({ text: /^2 PRs/ })).toBeDefined()
})

const BAND_PROPS = {
  hasSurvey: false,
  isWorking: false,
  maxRows: 10,
  bodyColumns: 80,
  scroll: { offset: 0, bodyRows: 10 },
  view: {},
}

test('the band shows a PRs button, marked when one needs us, that opens the pane', async ($, on) => {
  mock.clock(on)
  const opened: string[] = []
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? '/home/someone' : undefined }))
  on('process.run', () => ran(0, JSON.stringify(CACHED)))
  on('ui.render', () => Fragment({}))
  on('ui.open', ($, e) => {
    opened.push(e.id)

    return { value: { isPlaced: true as const } }
  })

  const empty = await $.ui.mount({ plugin: 'pr-pane', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })

  expect(await empty.find({ key: 'prs' })).toBeUndefined()

  await $.command.run(RUN)
  const band = await $.ui.mount({ plugin: 'pr-pane', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })

  expect(await band.find({ key: 'prs', text: 'PRs 2 !' })).toBeDefined()

  await band.press({ key: 'prs' })

  expect(opened).toEqual(['tracked-prs', 'tracked-prs'])
})

test('a failing pr-watch is shown in the pane', async ($, on) => {
  mock.clock(on)
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? '/home/someone' : undefined }))
  on('process.run', ($, e) => (e.argv[1] === '-c' ? ran(0, '') : ran(1, '', 'pr-watch: Python 3.9+ not found\n')))
  on('ui.render', () => Fragment({}))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))

  await $.command.run(RUN)
  const pane = await mountPane($, 'terminal')

  expect(await pane.find({ text: 'pr-watch: Python 3.9+ not found' })).toBeDefined()
})

test('no Git Bash anywhere is said in the pane and the band shows PRs ?', async ($, on) => {
  mock.clock(on)
  on('env.get', () => ({ value: undefined }))
  on('process.run', () => ({ deny: 'not found' }))
  on('ui.render', () => Fragment({}))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))

  await $.command.run(RUN)
  const pane = await mountPane($, 'terminal')
  const band = await $.ui.mount({ plugin: 'pr-pane', surface: 'terminal', component: 'AbovePrompt', props: BAND_PROPS })

  expect(await pane.find({ text: /Git Bash not found: set CLAUDE_CODE_GIT_BASH_PATH/ })).toBeDefined()
  expect(await band.find({ key: 'prs', text: 'PRs ?' })).toBeDefined()
})
