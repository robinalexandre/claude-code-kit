import { expect, test } from 'claude-code/testing'

const RUN = (args: string) => ({
  command: 'learn',
  args,
  origin: { kind: 'composer' as const },
  presentation: { isFullscreen: false, columns: 120 },
})

const LEVELS_FILE = '/home/someone/.claude/learn-levels.json'

test('/learn sets the level for the session, writes it for the status line, and keeps a default for new sessions', async ($, on) => {
  const store = new Map<string, unknown>()
  const files = new Map<string, string>([[LEVELS_FILE, JSON.stringify({ older: 'deep' })]])
  on('store.get', ($, e) => ({ value: store.get(e.key) }))
  on('store.set', ($, e) => {
    store.set(e.key, e.value)

    return { value: undefined }
  })
  on('env.get', ($, e) => ({ value: e.name === 'HOME' ? '/home/someone' : undefined }))
  on('session.id', () => ({ value: 'this-session' }))
  on('fs.read', ($, e) => {
    const text = files.get(e.path)

    return text === undefined ? { deny: 'missing' } : { value: text }
  })
  on('fs.write', ($, e) => {
    files.set(e.path, e.text)

    return { value: undefined }
  })
  const level = () => (JSON.parse(files.get(LEVELS_FILE) ?? '{}') as Record<string, string>)['this-session']

  expect((await $.command.run(RUN(''))).text).toContain('Learning is brief in this session (brief by default)')

  expect((await $.command.run(RUN('deep'))).text).toBe('Learning is deep for this session.')
  expect(level()).toBe('deep')
  expect(JSON.parse(files.get(LEVELS_FILE) ?? '{}').older).toBe('deep')

  expect((await $.command.run(RUN('default normal'))).text).toBe('New sessions start with learning normal. This one stays deep.')
  expect((await $.command.run(RUN(''))).text).toContain('deep in this session (normal by default)')

  expect((await $.command.run(RUN('loud'))).text).toBe('Not a level: loud. Levels: off, brief, normal, deep.')

  expect((await $.command.run(RUN('off'))).text).toBe('Learning is off for this session.')
  expect(level()).toBe('off')
})
