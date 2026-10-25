import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { DndActive, DndData, DndPart, DndPartRule, DndProfile, DndRule } from '../types'

// The Do not disturb pane. The configuration mod's pane (every mod's settings) opens it, and it opens
// that one: Claude Code shows the two as tabs.
const PANE = 'dnd'
const TITLE = 'Do not disturb'
const COMMAND = 'dnd'
const CONFIGURATION_PANE = 'configuration'
const TICK_MS = 60_000
// Under the pointer, what folds turns to the theme's suggestion color with the text drawn on it in
// the theme's inverse text color: readable in a light and a dark theme alike.
const LIT_BOX = { backgroundColor: 'suggestion' }
const LIT_TEXT = { color: 'inverseText', dimColor: false }

// The panes read it under the same shape; see the types.
const active = atom({ plugin: 'dnd', key: 'active' } as const, null, { shape: 'dnd-active/1' })
const data = atom({ plugin: 'dnd', key: 'data' } as const, null)
const problem = atom({ plugin: 'dnd', key: 'problem' } as const, '')
const pending = atom({ plugin: 'dnd', key: 'pending' } as const, '')
const unfolded = atom({ plugin: 'dnd', key: 'unfolded' } as const, {})
const armed = atom({ plugin: 'dnd', key: 'armed' } as const, '')
const busy = atom({ plugin: 'dnd', key: 'busy' } as const, false)

const PARTS: { part: DndPart; title: string }[] = [
  { part: 'history', title: 'History' },
  { part: 'prs', title: 'Dev activity' },
  { part: 'reminders', title: 'Reminders' },
  { part: 'handoffs', title: 'Handoffs' },
]

const HERE = '@here'
const LENGTHS = ['30m', '1h', '2h']
type Scope = 'session' | 'computer' | 'everywhere'
const SCOPES: Record<Scope, string[]> = {
  session: ['here', 'session', 'this'],
  computer: ['computer', 'pc', 'mac'],
  everywhere: ['all', 'everywhere'],
}
const WHERE: [Scope, string][] = [
  ['session', 'this session'],
  ['computer', 'this computer'],
  ['everywhere', 'all computers'],
]
const scopeOf = (word: string) => (Object.keys(SCOPES) as Scope[]).find(scope => SCOPES[scope].includes(word))

const slashed = (path: string) => path.replace(/\\/g, '/')

const home = async ($: EngineInterface) => slashed((await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE')) ?? '~')

const truncate = (text: string, width: number) =>
  text.length > width ? `${text.slice(0, Math.max(0, width - 1))}…` : text

const runs = async ($: EngineInterface, argv: string[]) => {
  try {
    return (await $.process.run(argv, { timeoutMs: 10_000 })).exitCode === 0
  } catch {
    return false
  }
}

// On Windows, Claude Code's own PATH has Git's cmd folder (git) but not bash: Git Bash is found
// from the variable Claude Code reads for it, then from git's own install folder.
let bashFound: string | undefined

const bash = async ($: EngineInterface) => {
  if (bashFound !== undefined) {
    return bashFound
  }

  const fromGit = async () => {
    const execPath = await $.process.run(['git', '--exec-path'], { timeoutMs: 10_000 }).catch(() => undefined)
    const root = slashed(execPath?.stdout.trim() ?? '').replace(/\/(mingw64|clangarm64|mingw32)\/.*$/, '')

    return execPath?.exitCode === 0 && root !== '' ? `${root}/bin/bash.exe` : ''
  }
  const candidates = [
    async () => slashed((await $.env.get('CLAUDE_CODE_GIT_BASH_PATH')) ?? ''),
    async () => 'bash',
    fromGit,
    async () => `${slashed((await $.env.get('ProgramFiles')) ?? 'C:/Program Files')}/Git/bin/bash.exe`,
  ]

  for (const candidate of candidates) {
    const path = await candidate()

    if (path !== '' && (await runs($, [path, '-c', 'exit 0']))) {
      bashFound = path

      return path
    }
  }

  throw new Error('Git Bash not found: set CLAUDE_CODE_GIT_BASH_PATH to bash.exe')
}

// The script ships in this plugin's own skill, beside the manifest's folder.
const script = ($: EngineInterface) => `${slashed($.plugin.root).replace(/\/\.claude-plugin\/?$/, '')}/skills/dnd/dnd.sh`

const run = async ($: EngineInterface, args: string[]) => {
  const ran = await $.process.run([await bash($), script($), ...args], { timeoutMs: 30_000 })

  return { ...ran, said: (ran.exitCode === 0 ? ran.stdout : ran.stderr).trim().split('\n')[0] ?? '' }
}

const forSession = async ($: EngineInterface) => ['--session', await $.session.id()]

const SHOWN_KEPT = 50

// The status line shows the profile on beside the others: it reads it from this file, by session id.
const show = async ($: EngineInterface, now: DndActive) => {
  const base = await home($)

  if (base === '~') {
    return
  }

  const path = `${base}/.claude/.dnd/active.json`
  const id = await $.session.id()
  let shown: Record<string, unknown> = {}

  try {
    const parsed: unknown = JSON.parse(await $.fs.read(path))
    shown = parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : {}
  } catch {
    shown = {}
  }

  const kept = Object.entries(shown).filter(([session]) => session !== id).slice(-(SHOWN_KEPT - 1))
  await $.fs.write(path, `${JSON.stringify(Object.fromEntries([...kept, [id, { profile: now.profile, scope: now.scope, untilText: now.untilText }]]), null, 1)}\n`)
}

const setActive = async ($: EngineInterface, now: DndActive) => {
  await update($, active, () => now)
  await show($, now).catch(() => undefined)
}

// What is on for this session: every minute, after each turn, and after each change.
const refresh = async ($: EngineInterface) => {
  try {
    const ran = await run($, ['active', slashed(await $.session.cwd()), ...(await forSession($))])

    if (ran.exitCode !== 0) {
      await update($, problem, () => ran.said || `dnd.sh exited with ${ran.exitCode}`)

      return
    }

    const now = JSON.parse(ran.stdout) as DndActive
    const before = await read($, active)

    // The other panes redraw on each write: only a change is written.
    if (JSON.stringify(before) !== JSON.stringify(now)) {
      await setActive($, now)
    }

    await update($, problem, () => '')
  } catch (error) {
    await update($, problem, () => String(error).split('\n')[0] ?? '')
  }
}

// Profile edits made from the pane, written one after another; `edits` counts every one queued, so
// a read started before the last of them knows it is stale.
let edits = 0
let writes: Promise<unknown> = Promise.resolve()

// Profiles, rules and the names each part lists, for the pane.
const load = async ($: EngineInterface) => {
  const since = edits

  try {
    const ran = await run($, ['json', slashed(await $.session.cwd()), ...(await forSession($))])

    if (ran.exitCode !== 0) {
      await update($, problem, () => ran.said)

      return
    }

    if (since !== edits) {
      return
    }

    const loaded = JSON.parse(ran.stdout) as DndData
    await update($, data, () => loaded)

    if (JSON.stringify(await read($, active)) !== JSON.stringify(loaded.active)) {
      await setActive($, loaded.active)
    }

    await update($, problem, () => '')
  } catch (error) {
    await update($, problem, () => String(error).split('\n')[0] ?? '')
  }
}

// Runs one change, says what went wrong, and reads everything again.
const change = async ($: EngineInterface, args: string[], quiet = false) => {
  await update($, busy, () => true)

  try {
    const ran = await run($, args)

    if (ran.exitCode !== 0 || !quiet) {
      $.ui.toast(ran.exitCode === 0 ? ran.said : `DnD: ${ran.said}`)
    }

    return ran
  } finally {
    await load($)
    await update($, busy, () => false)
  }
}

// One part of a profile set from the pane: shown at once, written behind, everything read again
// once the last press is written. Reading it all takes seconds; a press must not wait for it.
const editPart = ($: EngineInterface, profile: string, part: DndPart, rule: DndPartRule) => {
  const mine = ++edits

  void update($, data, all => (all === null ? all : { ...all, profiles: { ...all.profiles, [profile]: { ...all.profiles[profile], [part]: rule } } }))
  writes = writes.then(async () => {
    const ran = await run($, ['set', profile, part, rule.mode ?? 'show', ...(rule.mode === 'only' ? rule.only ?? [] : [])]).catch(error => ({
      exitCode: 1,
      said: String(error).split('\n')[0] ?? '',
    }))

    if (ran.exitCode !== 0) {
      $.ui.toast(`DnD: ${ran.said}`)
    }

    if (mine === edits) {
      await load($)
    }
  })
}

const turnOn = async ($: EngineInterface, profile: string, length: string, scope: Scope) => {
  await update($, pending, () => '')
  const where = scope === 'session' ? await forSession($) : scope === 'everywhere' ? ['--everywhere'] : []
  await change($, ['on', profile, ...(length !== '' ? [length] : []), ...where])
}

// A profile to turn on, asked until when and where in the pane: `<profile>|<for>|<scope>`.
const ask = ($: EngineInterface, profile: string, length = '', scope: Scope = 'session') => update($, pending, () => `${profile}|${length}|${scope}`)

// Every switch off: this session's, the computer's and every computer's; the rules decide again.
const turnOff = async ($: EngineInterface) => {
  await update($, pending, () => '')
  await run($, ['off', ...(await forSession($))]).catch(() => undefined)
  await change($, ['off'])
}

const openPane = async ($: EngineInterface) => {
  await $.ui.open({ id: PANE, title: TITLE, columns: 64 })
  await load($)
}

const isLength = (word: string) => /^(\d+[mhd]|\d{1,2}:\d{2})$/.test(word)

// `/dnd`, `/dnd off`, `/dnd list`, `/dnd PROFILE [30m|2h|HH:MM] [here|pc|all]`: without where,
// the pane asks.
const command = async ($: EngineInterface, args: string) => {
  const [first = '', ...rest] = args.trim().split(/\s+/).filter(word => word !== '')

  if (first === '') {
    await openPane($)

    return 'Do not disturb pane opened.'
  }

  if (first === 'off') {
    await turnOff($)

    return (await read($, active))?.profile ? `Switch off; ${(await read($, active))?.profile} stays on by a rule.` : 'DnD off: everything shows.'
  }

  if (first === 'list') {
    const ran = await run($, ['list', ...(await forSession($))])

    return ran.exitCode === 0 ? ran.stdout.trimEnd() : ran.said
  }

  const length = rest.find(isLength) ?? ''
  const scope = rest.map(scopeOf).find(one => one !== undefined)

  if (scope === undefined) {
    await ask($, first, length)
    await openPane($)

    return `Turn on ${first}${length !== '' ? ` for ${length}` : ''}: for this session, this computer or all computers? Choose in the Do not disturb pane.`
  }

  await turnOn($, first, length, scope)
  const now = await read($, active)
  const where = WHERE.find(([one]) => one === scope)?.[1] ?? scope

  return now?.profile === first ? `DnD ${first} on for ${where}${now.untilText !== '' ? ` until ${now.untilText}` : ''}.` : (await read($, problem)) || `Could not turn ${first} on.`
}

// In words: what a profile hides or keeps.
const summary = (profile: DndProfile) => {
  const said = PARTS.flatMap(({ part, title }) => {
    const rule = profile[part]

    if (rule?.mode === 'hide') {
      return [`no ${title.toLowerCase()}`]
    }

    if (rule?.mode === 'only') {
      return [`${title.toLowerCase()}: ${(rule.only ?? []).map(name => (name === HERE ? 'this folder' : name)).join(', ') || 'none'}`]
    }

    return []
  })

  return said.length > 0 ? said.join(' · ') : 'shows everything'
}

const ruleText = (rule: DndRule) =>
  [
    rule.wifi ? `Wi-Fi ${rule.wifi}` : '',
    rule.folder ? `in ${rule.folder}` : '',
    rule.days ?? '',
    rule.from || rule.to ? `${rule.from ?? '00:00'}-${rule.to ?? '24:00'}` : '',
  ]
    .filter(part => part !== '')
    .join(', ')

let ticking: (() => void) | undefined
let ticks = 0

// In the kit's low power mode (the configuration mod's, read under its shape), one tick in five reads.
const LOW_POWER_FACTOR = 5
const lowPower = atom({ plugin: 'configuration', key: 'power' } as const, null, { shape: 'low-power/1' })

const tick = async ($: EngineInterface) => {
  ticks += 1

  if ((await read($, lowPower))?.isLow !== true || ticks % LOW_POWER_FACTOR === 0) {
    await refresh($)
  }
}

const start = async ($: EngineInterface) => {
  await $.command
    .register({ name: COMMAND, description: 'Do not disturb: open the profiles, or turn one on (/dnd work 1h), off (/dnd off)' })
    .catch(() => undefined)
  ticking?.()
  ticking = $.clock.every(TICK_MS, () => void tick($).catch(() => undefined))
  void refresh($).catch(() => undefined)
}

let refreshedAt = 0
let loadAsked = false

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await start($)

    return next(e)
  })

  // A /clear starts a fresh session without a session.start: the switch is read again once it has.
  on('session.end', async ($, e, next) => {
    const ended = await next(e)

    if (e.reason === 'clear') {
      $.clock.after(0, () => void start($))
    }

    return ended
  })

  // A turn can change the folder or follow a switch made in words: read it again, at most every 10s.
  on('turn.complete', async ($, e, next) => {
    const now = await $.clock.now()

    if (now - refreshedAt >= 10_000) {
      refreshedAt = now
      void refresh($).catch(() => undefined)
    }

    return next(e)
  })

  on('command.run', { command: COMMAND }, async ($, e) => ({ text: await command($, e.args) }))

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Input, Text } = $.ui.resolve(e)
    const shown = await read($, data)

    // Opened from the Configuration pane's button, the profiles are read on the first draw.
    if (shown === null && !loadAsked) {
      loadAsked = true
      void load($)
    }

    const now = (await read($, active)) ?? shown?.active ?? null
    const trouble = await read($, problem)
    const waiting = await read($, pending)
    const open = await read($, unfolded)
    const armedKey = await read($, armed)
    const isBusy = await read($, busy)
    const width = Math.max(30, e.props.bodyColumns - 2)

    const toggle = (key: string) => void update($, unfolded, all => ({ ...all, [key]: !(all[key] ?? false) }))

    // A second press confirms what cannot be undone.
    const confirmButton = (key: string, label: string, onConfirm: () => void) =>
      armedKey === key ? (
        <Button key={`confirm-${key}`} label={`${label}? press again`} variant="primary" onPress={() => {
          void update($, armed, () => '')
          onConfirm()
        }} />
      ) : (
        <Button key={`arm-${key}`} label={label} dimColor onPress={() => void update($, armed, () => key)} />
      )

    // A line that folds: the whole of it, lit under the pointer; `buttons` do something else.
    const foldLine = (key: string, text: string, isOpen: boolean, buttons: unknown[] = [], room = 0) => (
      <Box key={`line-${key}`} flexDirection="row" justifyContent="space-between">
        <Box flexDirection="row" flexShrink={1} hover={LIT_BOX}>
          <Button key={`fold-${key}`} label={`${isOpen ? '▾' : '▸'} ${truncate(text, Math.max(8, width - room - 4))}`} plain hover={LIT_TEXT} onPress={() => toggle(key)} />
        </Box>
        <Box flexDirection="row" flexShrink={0} gap={1}>
          {buttons as never}
        </Box>
      </Box>
    )

    const status = () => {
      if (trouble !== '') {
        return `Could not read the profiles: ${truncate(trouble, width - 30)}`
      }

      if (now === null) {
        return 'Loading…'
      }

      if (now.profile === '') {
        return 'Off: everything shows.'
      }

      const end = now.untilText !== '' ? ` until ${now.untilText}` : ''

      return now.profile === 'none' ? `Everything shows${end}, the rules quiet (${now.why}).` : `On: ${now.profile} (${now.why})${end}.`
    }

    // A profile to turn on: until when and where, picked, then one press. A length typed with
    // /dnd that is not among the usual ones is offered too.
    const pendingBlock = () => {
      const [profile = '', length = '', scope = 'session'] = waiting.split('|')
      const lengths = ['', ...LENGTHS, ...(length !== '' && !LENGTHS.includes(length) ? [length] : [])]
      const choice = (key: string, label: string, isPicked: boolean, onPress: () => void) => (
        <Button key={key} label={label} {...(isPicked ? { variant: 'primary' as const } : { plain: true as const, dimColor: true })} onPress={onPress} />
      )

      return (
        <Box key="pending" flexDirection="column" marginTop={1}>
          <Box flexDirection="row" justifyContent="space-between">
            <Text bold>{`Turn on ${profile}:`}</Text>
            <Button key="pending-cancel" label="cancel" dimColor onPress={() => void update($, pending, () => '')} />
          </Box>
          <Box flexDirection="row" gap={1} paddingLeft={2}>
            <Text>Until</Text>
            {lengths.map(one => choice(`until-${one || 'off'}`, one === '' ? 'off' : one, one === length, () => void ask($, profile, one, scope as Scope)))}
          </Box>
          <Box flexDirection="row" gap={1} paddingLeft={2}>
            <Text>Where</Text>
            {WHERE.map(([one, title]) => choice(`where-${one}`, title, one === scope, () => void ask($, profile, length, one)))}
          </Box>
          <Box paddingLeft={2} marginTop={1}>
            <Button key="activate" label="Activate" variant="primary" onPress={() => void turnOn($, profile, length, scope as Scope)} />
          </Box>
        </Box>
      )
    }

    // One part of a profile: a button per mode, the one on lit; `only` lists the names to check:
    // the session's folder, the ones checked, what the part lists now, then every repo and folder.
    const partBlock = (name: string, profile: DndProfile, part: DndPart, title: string) => {
      const rule = profile[part]
      const mode = rule?.mode ?? 'show'
      const kept = rule?.only ?? []
      const lastPart = (one: string) => one.toLowerCase().replace(/^.*\//, '')
      const names = [HERE, ...kept, ...(shown?.known[part] ?? []), ...(shown?.workspaces ?? [])].filter(
        (one, index, all) => all.findIndex(other => lastPart(other) === lastPart(one)) === index
      )
      const setRule = (nextRule: DndPartRule) => editPart($, name, part, nextRule)
      const modes: ['show' | 'hide' | 'only', string][] = part === 'history' ? [['show', 'show'], ['hide', 'hide']] : [['show', 'all'], ['hide', 'hide'], ['only', 'only…']]

      return (
        <Box key={`part-${name}-${part}`} flexDirection="column" paddingLeft={4}>
          <Box flexDirection="row" gap={1}>
            <Text>{`${title}:`}</Text>
            {modes.map(([one, label]) => (
              <Button
                key={`mode-${name}-${part}-${one}`}
                label={label}
                {...(one === mode ? { variant: 'primary' as const } : { plain: true as const, dimColor: true })}
                onPress={() => one !== mode && setRule({ mode: one, only: kept })}
              />
            ))}
          </Box>
          {mode === 'only' &&
            names.map(one => {
              const isKept = kept.some(other => other.toLowerCase() === one.toLowerCase())

              return (
                <Box key={`name-${name}-${part}-${one}`} flexDirection="row" paddingLeft={2} hover={LIT_BOX}>
                  <Button
                    key={`check-${name}-${part}-${one}`}
                    label={`${isKept ? '[x]' : '[ ]'} ${truncate(one === HERE ? `this folder (${now?.here.name ?? 'the session'})` : one, width - 14)}`}
                    plain
                    hover={LIT_TEXT}
                    onPress={() => setRule({ mode: 'only', only: isKept ? kept.filter(other => other.toLowerCase() !== one.toLowerCase()) : [...kept, one] })}
                  />
                </Box>
              )
            })}
        </Box>
      )
    }

    const rulesOf = (name: string) => (shown?.rules ?? []).map((rule, index) => ({ rule, index })).filter(({ rule }) => rule.profile === name)

    // What turns a profile on by itself: its rules, and the ones a press adds from where this
    // session is; hours and days are asked in words to Claude.
    const rulesBlock = (name: string) => {
      const wifi = shown?.wifi ?? ''
      const adds: [string, string[]][] = [
        ...(wifi !== '' ? [[`+ on Wi-Fi ${truncate(wifi, 16)}`, [`wifi=${wifi}`]] as [string, string[]]] : []),
        [`+ in ${truncate(now?.here.name ?? 'this folder', 16)}`, [`folder=${now?.here.path ?? ''}`]],
        ['+ week-ends', ['days=weekend']],
      ]

      return (
        <Box key={`rules-${name}`} flexDirection="column" paddingLeft={4}>
          <Text dimColor>Turns on by itself:</Text>
          {rulesOf(name).length === 0 && (
            <Box paddingLeft={2}>
              <Text dimColor>never (by hand only)</Text>
            </Box>
          )}
          {rulesOf(name).map(({ rule, index }) => (
            <Box key={`rule-${index}`} flexDirection="row" justifyContent="space-between" paddingLeft={2}>
              <Text>{truncate(ruleText(rule), width - 20)}</Text>
              {confirmButton(`unrule|${index}`, 'delete', () => void change($, ['unrule', String(index + 1)], true))}
            </Box>
          ))}
          <Box flexDirection="row" gap={1} paddingLeft={2}>
            {adds.map(([label, pairs]) => (
              <Button key={`add-${name}-${label}`} label={label} dimColor onPress={() => void change($, ['rule', name, ...pairs], true)} />
            ))}
          </Box>
        </Box>
      )
    }

    // A profile's line says what it hides and whether a rule turns it on; its text opens the editor.
    const profileRow = (name: string, profile: DndProfile) => {
      const key = `profile|${name}`
      const isOpen = open[key] ?? false
      const isCurrent = now?.profile === name
      const ruled = rulesOf(name).length > 0 ? ' (rule)' : ''
      const buttons = [
        isCurrent ? (
          <Text key={`on-${name}`} color="green">on</Text>
        ) : (
          <Button key={`use-${name}`} label="use" onPress={() => void ask($, name)} />
        ),
        <Button key={`edit-${name}`} label={isOpen ? 'done' : 'edit'} dimColor={!isOpen} onPress={() => toggle(key)} />,
        confirmButton(`delete|${name}`, 'delete', () => void change($, ['delete', name])),
      ]

      return (
        <Box key={`row-${name}`} flexDirection="column" paddingLeft={2}>
          {foldLine(key, `${name}${ruled} · ${summary(profile)}`, isOpen, buttons, 24)}
          {isOpen && PARTS.map(({ part, title }) => partBlock(name, profile, part, title))}
          {isOpen && rulesBlock(name)}
        </Box>
      )
    }

    const profilesSection = () => {
      const entries = Object.entries(shown?.profiles ?? {})

      return (
        <Box key="profiles" flexDirection="column" marginTop={1}>
          <Text bold>{`Profiles (${entries.length})`}</Text>
          {entries.map(([name, profile]) => profileRow(name, profile))}
        </Box>
      )
    }

    // A new profile opens in its editor, ready to pick what it keeps.
    const create = (value: string) => {
      const name = value.trim().replace(/\s+/g, '-')

      if (name !== '' && name !== 'none') {
        void change($, ['set', name, 'history', 'show'], true).then(() => update($, unfolded, all => ({ ...all, [`profile|${name}`]: true })))
      }
    }

    // One press per profile, then until when and where. `none` (everything shows) is only offered
    // while a rule has a profile on, beside the status: it quiets the rules for a while.
    const turnOnRow = () => {
      const names = Object.keys(shown?.profiles ?? {})

      return (
        <Box key="turn-on" flexDirection="column" marginTop={1}>
          <Text bold>Turn on</Text>
          <Box flexDirection="row" flexWrap="wrap" gap={1} paddingLeft={2}>
            {names.length === 0 && <Text dimColor>no profile yet: create one below</Text>}
            {names.map(name =>
              now?.profile === name ? (
                <Text key={`current-${name}`} color="green">{`${name} (on)`}</Text>
              ) : (
                <Button key={`turn-on-${name}`} label={name} onPress={() => void ask($, name)} />
              )
            )}
          </Box>
          <Box paddingLeft={2} marginTop={1}>
            <Input key="new-profile" label="New profile " placeholder="a name, e.g. work, meeting" submitLabel="create" onSubmit={create} />
          </Box>
        </Box>
      )
    }

    const isManual = now?.scope === 'session' || now?.scope === 'computer' || now?.scope === 'everywhere'

    return (
      <Box flexDirection="column">
        <Box flexDirection="row" justifyContent="flex-end" marginBottom={1}>
          <Button key="mod-settings" label="Mod settings ›" dimColor onPress={() => void $.ui.open({ id: CONFIGURATION_PANE, title: 'Configuration', columns: 64 })} />
        </Box>
        <Text dimColor={now?.profile === ''}>{status()}</Text>
        <Box flexDirection="row" justifyContent="flex-end">
          <Box flexDirection="row" gap={1}>
            {isManual && <Button key="off" label="off" onPress={() => void turnOff($)} />}
            {now?.scope === 'rule' && <Button key="quiet-rules" label="quiet the rules" dimColor onPress={() => void ask($, 'none')} />}
            {isBusy ? <Text dimColor>…</Text> : <Button key="refresh" label="refresh" dimColor onPress={() => void load($)} />}
          </Box>
        </Box>
        {waiting !== '' && pendingBlock()}
        {shown !== null && waiting === '' && turnOnRow()}
        {shown !== null && profilesSection()}
        {shown !== null && (
          <Box marginTop={1}>
            <Text dimColor>{truncate(`Saved in ${shown.file}`, width)}</Text>
          </Box>
        )}
      </Box>
    )
  })
}
