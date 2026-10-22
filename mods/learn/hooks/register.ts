import type { EngineInterface, Register } from 'claude-code'

import type { LearnLevel } from '../types'

const COMMAND = 'learn'
const LEVELS: readonly LearnLevel[] = ['off', 'brief', 'normal', 'deep']
const DEFAULT_KEY = 'defaultLevel'
const FALLBACK: LearnLevel = 'brief'
const level = { plugin: 'learn', key: 'level' } as const

const SIZE: Record<Exclude<LearnLevel, 'off'>, string> = {
  brief:
    'At most one point, only for security or a decision with lasting impact: three lines of prose and up to six lines of code.',
  normal: 'Up to two points, each up to five lines of prose and ten lines of code.',
  deep:
    'Up to three points, each with the trade-off or the alternative not taken, and where it helps a reference by name ' +
    '(an OWASP entry, an RFC, a pattern catalog).',
}

const guide = (current: Exclude<LearnLevel, 'off'>) =>
  [
    `# Learning while working (level: ${current})`,
    'The person wants to learn from the work as it happens. When what this turn did or read touches something worth ' +
      'knowing, end the reply with a block headed "💡 Learn:" after everything else, the reply itself unchanged.',
    '- Worth it, first to last: security (name the attack it stops or lets in: injection, broken access control, SSRF, ' +
      'XSS, CSRF, secrets in code or logs, TOCTOU, weak crypto); an architecture choice and what it costs; a design ' +
      'pattern by its name; a concurrency or performance trap; a non-obvious idiom of the language or framework.',
    '- About this code, never a lecture: quote the real lines with `file:line`, or a minimal before/after in a code ' +
      'block. Name the thing precisely and say in one sentence why it matters here.',
    `- ${SIZE[current]}`,
    '- Nothing worth it this turn (most turns): no block. Never repeat a point already made in this session.',
    '- Same language as the reply. It goes in the chat only, never into the repo as comments or docs.',
    "- It is the one exception to a concise style the person chose: the rest of the reply stays as they asked.",
  ].join('\n')

const parse = (word: string): LearnLevel | undefined => LEVELS.find(one => one === word.trim().toLowerCase())

const current = async ($: EngineInterface) => (await $.state.get(level)).value ?? FALLBACK

const LEVELS_KEPT = 50

// The status line shows the level beside the others: it reads it from this file, by session id.
const show = async ($: EngineInterface, now: LearnLevel) => {
  const home = ((await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE')) ?? '').replace(/\\/g, '/')

  if (home === '') {
    return
  }

  const path = `${home}/.claude/learn-levels.json`
  const id = await $.session.id()
  let levels: Record<string, string> = {}

  try {
    levels = JSON.parse(await $.fs.read(path)) as Record<string, string>
  } catch {
    levels = {}
  }

  const kept = Object.entries(levels).filter(([session]) => session !== id).slice(-(LEVELS_KEPT - 1))
  await $.fs.write(path, `${JSON.stringify(Object.fromEntries([...kept, [id, now]]), null, 1)}\n`)
}

const setLevel = async ($: EngineInterface, now: LearnLevel) => {
  await $.state.set(level, now)
  await show($, now)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: COMMAND,
      description: 'Short lessons on the security, architecture or patterns behind the code: off, brief, normal, deep',
      argumentHint: '[off|brief|normal|deep] | default <level>',
    })
    // The level used to be pinned under the prompt; the status line shows it now.
    $.ui.status(undefined)
    const held = (await $.state.get(level)).value
    const stored = parse(String((await $.store.get(DEFAULT_KEY)) ?? ''))

    if (held === undefined) {
      await $.state.set(level, stored ?? FALLBACK)
    }

    await show($, held ?? stored ?? FALLBACK)

    return next(e)
  })

  on('command.run', { command: COMMAND }, async ($, e) => {
    const words = e.args.trim().split(/\s+/).filter(word => word !== '')
    const isDefault = words[0] === 'default'
    const asked = parse(isDefault ? (words[1] ?? '') : (words[0] ?? ''))

    if (words.length === 0) {
      const now = await current($)
      const stored = parse(String((await $.store.get(DEFAULT_KEY)) ?? '')) ?? FALLBACK

      return {
        text: `Learning is ${now} in this session (${stored} by default). /learn off|brief|normal|deep for this session, /learn default <level> for new ones.`,
      }
    }

    if (asked === undefined) {
      return { text: `Not a level: ${e.args.trim()}. Levels: ${LEVELS.join(', ')}.` }
    }

    if (isDefault) {
      await $.store.set(DEFAULT_KEY, asked)

      return { text: `New sessions start with learning ${asked}. This one stays ${await current($)}.` }
    }

    await setLevel($, asked)

    return {
      text: asked === 'off' ? 'Learning is off for this session.' : `Learning is ${asked} for this session.`,
    }
  })

  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    const now = await current($)

    if (now === 'off') {
      return composed
    }

    return { sections: [...composed.sections, { id: 'learn:guide', text: guide(now), scope: 'session' as const }] }
  })
}
