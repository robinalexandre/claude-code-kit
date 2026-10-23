import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { DndActive, DndData, DndPart, DndPartRule, DndProfile, DndRule, ModSetting, ModsData } from '../types'

// The Configuration pane, a tab per thing set up from it; do not disturb is the first.
const PANE = 'configuration'
const TITLE = 'Configuration'
const COMMAND = 'dnd'
const PANE_COMMAND = 'configuration'
const TABS = [
  { id: 'dnd', title: 'Do not disturb' },
  { id: 'mods', title: 'Mods' },
]
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
const tab = atom({ plugin: 'dnd', key: 'tab' } as const, 'dnd')
const mods = atom({ plugin: 'dnd', key: 'mods' } as const, null)
const modsScope = atom({ plugin: 'dnd', key: 'modsScope' } as const, 'all')

const PARTS: { part: DndPart; title: string }[] = [
  { part: 'history', title: 'History' },
  { part: 'prs', title: 'PRs & CI' },
  { part: 'reminders', title: 'Reminders' },
  { part: 'handoffs', title: 'Handoffs' },
]

const HERE = '@here'
const LENGTHS = ['30m', '1h', '2h']
const SCOPES = { session: ['here', 'session', 'this'], computer: ['all', 'computer', 'everywhere'] }

// The band's buttons share one row under everything above the prompt, whatever order the mods
// draw in: each takes that row out of what the mods beneath drew, adds its own button, and sorts
// them by key (band-1-history, band-2-prs, band-3-reminders, band-4-dnd).
const BAND_ROW = 'band-buttons'

type Drawn = { type?: string; props?: { key?: string }; children?: unknown[] }

const keyOf = (node: unknown) => (node !== null && typeof node === 'object' ? ((node as Drawn).props?.key ?? '') : '')

const byBandKey = (one: unknown, other: unknown) => keyOf(one).localeCompare(keyOf(other))

const takeBandRow = (tree: unknown): { rest: unknown; buttons: unknown[] } => {
  if (Array.isArray(tree)) {
    let buttons: unknown[] = []
    const rest = tree.map(child => {
      if (buttons.length > 0) {
        return child
      }

      const taken = takeBandRow(child)
      buttons = taken.buttons

      return taken.rest
    })

    // The engine reads every child of a drawn tree: the row taken out leaves no hole.
    return { rest: rest.filter(child => child !== null && child !== undefined), buttons }
  }

  const node = tree as Drawn | null

  if (node === null || typeof node !== 'object' || !Array.isArray(node.children)) {
    return { rest: tree, buttons: [] }
  }

  if (node.props?.key === BAND_ROW) {
    return { rest: null, buttons: node.children.flat(Infinity) }
  }

  const taken = takeBandRow(node.children)

  return taken.buttons.length > 0 ? { rest: { ...node, children: taken.rest }, buttons: taken.buttons } : { rest: tree, buttons: [] }
}

const slashed = (path: string) => path.replace(/\\/g, '/')

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
      await update($, active, () => now)
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
      await update($, active, () => loaded.active)
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

const turnOn = async ($: EngineInterface, profile: string, length: string, scope: 'session' | 'computer') => {
  await update($, pending, () => '')
  await change($, ['on', profile, ...(length !== '' ? [length] : []), ...(scope === 'session' ? await forSession($) : [])])
}

// Both switches off: this session's and the computer's; the rules decide again.
const turnOff = async ($: EngineInterface) => {
  await update($, pending, () => '')
  await run($, ['off', ...(await forSession($))]).catch(() => undefined)
  await change($, ['off'])
}

// The Mods tab. A change for every computer is a /config change, which the private sync shares;
// one for this computer alone is also written to the sync's machine file, whose settings win
// over the shared ones at each sync, so the shared value stays for the other computers.
type Json = Record<string, unknown>

const home = async ($: EngineInterface) => slashed((await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE')) ?? '~')

const settingsFile = async ($: EngineInterface) => {
  const dir = await $.env.get('CLAUDE_CONFIG_DIR')

  return `${dir ? slashed(dir) : `${await home($)}/.claude`}/settings.json`
}

const readJson = async ($: EngineInterface, path: string): Promise<Json> => {
  try {
    const parsed: unknown = JSON.parse(await $.fs.read(path))

    return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed) ? (parsed as Json) : {}
  } catch {
    return {}
  }
}

const objectAt = (value: unknown): Json => (value !== null && typeof value === 'object' && !Array.isArray(value) ? (value as Json) : {})

// This computer's file in the private sync, '' when there is no sync to keep a setting apart in.
const machineFile = async ($: EngineInterface) => {
  const sync = `${await home($)}/.claude-sync`

  try {
    const machine = (await $.fs.read(`${sync}/.machine`)).trim()
    const file = `${sync}/machines/${machine}.json`

    return machine !== '' && (await $.fs.exists(file)) ? { machine, file } : { machine: '', file: '' }
  } catch {
    return { machine: '', file: '' }
  }
}

// Settings name a plugin's options by its name, with or without `@<where it comes from>`.
const configKeyOf = (configs: Json, plugin: string) => Object.keys(configs).find(key => key === plugin || key.startsWith(`${plugin}@`))

const overlayValue = (overlay: Json, plugin: string, field: string) => {
  const configs = objectAt(objectAt(overlay.settings).pluginConfigs)
  const key = configKeyOf(configs, plugin)

  return key === undefined ? undefined : objectAt(objectAt(configs[key]).options)[field]
}

const loadMods = async ($: EngineInterface) => {
  const { machine, file } = await machineFile($)
  const overlay = file === '' ? {} : await readJson($, file)
  const settings = (await $.config.list())
    .filter(row => row.provider.tier === 'user' && row.key.includes('.'))
    .map((row): ModSetting => {
      const plugin = row.key.slice(0, row.key.indexOf('.'))
      const field = row.key.slice(plugin.length + 1)

      return {
        key: row.key,
        plugin,
        field,
        label: row.label,
        ...(row.description ? { description: row.description } : {}),
        kind: row.kind,
        value: Array.isArray(row.value) ? [...row.value] : (row.value as ModSetting['value']),
        ...(row.options ? { options: [...row.options] } : {}),
        isLocked: row.isLocked,
        isHere: overlayValue(overlay, plugin, field) !== undefined,
      }
    })

  await update($, mods, () => ({ settings, machine }))
}

// Writes the field's value into the machine file, or takes it out (undefined), leaving no empty object behind.
const writeOverlay = async ($: EngineInterface, file: string, setting: ModSetting, value: ModSetting['value'] | undefined) => {
  const overlay = await readJson($, file)
  const settings = objectAt(overlay.settings)
  const configs = objectAt(settings.pluginConfigs)
  const local = await readJson($, await settingsFile($))
  const key = configKeyOf(objectAt(local.pluginConfigs), setting.plugin) ?? configKeyOf(configs, setting.plugin) ?? setting.plugin
  const entry = objectAt(configs[key])
  const { [setting.field]: _dropped, ...others } = objectAt(entry.options)
  const options = value === undefined ? others : { ...others, [setting.field]: value }
  const { options: _old, ...entryRest } = entry
  const nextEntry = Object.keys(options).length > 0 ? { ...entryRest, options } : entryRest
  const { [key]: _was, ...otherConfigs } = configs
  const nextConfigs = Object.keys(nextEntry).length > 0 ? { ...otherConfigs, [key]: nextEntry } : otherConfigs
  const { pluginConfigs: _configs, ...settingsRest } = settings
  const nextSettings = Object.keys(nextConfigs).length > 0 ? { ...settingsRest, pluginConfigs: nextConfigs } : settingsRest

  await $.fs.write(file, `${JSON.stringify({ ...overlay, settings: nextSettings }, null, 2)}\n`)
}

// For this computer, /config writes first so the machine file names the plugin as settings.json
// does; for every computer, the machine file lets go first so the sync shares the new value.
const setMod = async ($: EngineInterface, setting: ModSetting, value: ModSetting['value']) => {
  const { file } = await machineFile($)
  const isHere = file !== '' && (await read($, modsScope)) === 'here'

  try {
    if (file !== '' && !isHere && setting.isHere) {
      await writeOverlay($, file, setting, undefined)
    }

    const { deny } = await $.config.set({ key: setting.key, value })

    if (deny !== undefined) {
      $.ui.toast(`Could not change ${setting.label}: ${deny}`)
    } else if (isHere) {
      await writeOverlay($, file, setting, value)
    }
  } catch (error) {
    $.ui.toast(`Could not change ${setting.label}: ${String(error).split('\n')[0] ?? ''}`)
  } finally {
    await loadMods($)
  }
}

const openPane = async ($: EngineInterface) => {
  await $.ui.open({ id: PANE, title: TITLE, columns: 64 })
  await load($)

  if ((await read($, tab)) === 'mods') {
    await loadMods($)
  }
}

const isLength = (word: string) => /^(\d+[mhd]|\d{1,2}:\d{2})$/.test(word)

// `/dnd`, `/dnd off`, `/dnd list`, `/dnd PROFILE [30m|2h|HH:MM] [here|all]`: without where, the
// pane asks.
const command = async ($: EngineInterface, args: string) => {
  const [first = '', ...rest] = args.trim().split(/\s+/).filter(word => word !== '')

  if (first === '') {
    await openPane($)

    return 'Configuration pane opened, on Do not disturb.'
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
  const scope = rest.find(word => SCOPES.session.includes(word)) ? 'session' : rest.find(word => SCOPES.computer.includes(word)) ? 'computer' : ''

  if (scope === '') {
    await update($, pending, () => `${first}|${length}`)
    await openPane($)

    return `Turn on ${first}${length !== '' ? ` for ${length}` : ''}: for this session or the whole computer? Choose in the Configuration pane.`
  }

  await turnOn($, first, length, scope)
  const now = await read($, active)

  return now?.profile === first ? `DnD ${first} on${now.untilText !== '' ? ` until ${now.untilText}` : ''}.` : (await read($, problem)) || `Could not turn ${first} on.`
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

const start = async ($: EngineInterface) => {
  await $.command
    .register({ name: COMMAND, description: 'Do not disturb: open the profiles, or turn one on (/dnd work 1h), off (/dnd off)' })
    .catch(() => undefined)
  await $.command.register({ name: PANE_COMMAND, description: 'Open the Configuration pane: do not disturb profiles' }).catch(() => undefined)
  ticking?.()
  ticking = $.clock.every(TICK_MS, () => void refresh($).catch(() => undefined))
  void refresh($).catch(() => undefined)
}

let refreshedAt = 0

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

  on('command.run', { command: PANE_COMMAND }, async $ => {
    await openPane($)

    return { text: 'Configuration pane opened.' }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const beneath = await next(e)

    if (e.props.hasSurvey || e.props.view.agentId !== undefined) {
      return beneath
    }

    const { Box, Button, Text } = $.ui.resolve(e)
    const now = await read($, active)
    const isOn = (now?.profile ?? '') !== '' && now?.profile !== 'none'
    // The profile on now is said beside it, so a hidden pane is never a surprise.
    const label = isOn ? `${TITLE} · dnd ${now?.profile}${now?.untilText ? ` until ${now.untilText}` : ''}` : TITLE

    const { rest, buttons } = takeBandRow(beneath)
    const mine = (
      <Box key="band-4-configuration" flexDirection="row">
        {isOn && <Text color="magenta">● </Text>}
        <Button key="configuration" label={label} dimColor={!isOn} onPress={() => void openPane($)} />
      </Box>
    )

    return (
      <Box flexDirection="column">
        {rest as never}
        <Box key={BAND_ROW} flexDirection="row" gap={2}>
          {[...buttons, mine].sort(byBandKey) as never}
        </Box>
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Input, Text } = $.ui.resolve(e)
    const shown = await read($, data)
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

    // A profile turned on without saying where: this session or the whole computer, and how long.
    const pendingBlock = () => {
      const [profile = '', length = ''] = waiting.split('|')
      const lengths = length !== '' ? [length] : ['', ...LENGTHS]
      const line = (scope: 'session' | 'computer', title: string) => (
        <Box key={`pending-${scope}`} flexDirection="row" gap={1} paddingLeft={2}>
          <Text>{title}</Text>
          {lengths.map(one => (
            <Button key={`on-${scope}-${one || 'open'}`} label={one === '' ? 'until off' : `for ${one}`} onPress={() => void turnOn($, profile, one, scope)} />
          ))}
        </Box>
      )

      return (
        <Box key="pending" flexDirection="column" marginTop={1}>
          <Box flexDirection="row" justifyContent="space-between">
            <Text bold>{`Turn on ${profile}${length !== '' ? ` for ${length}` : ''}:`}</Text>
            <Button key="pending-cancel" label="cancel" dimColor onPress={() => void update($, pending, () => '')} />
          </Box>
          {line('session', 'this session')}
          {line('computer', 'this computer')}
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
          <Button key={`use-${name}`} label="use" onPress={() => void update($, pending, () => `${name}|`)} />
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

    // One press per profile turns it on, then asks where and for how long.
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
                <Button key={`turn-on-${name}`} label={name} onPress={() => void update($, pending, () => `${name}|`)} />
              )
            )}
            {names.length > 0 && <Button key="turn-on-none" label="show everything" dimColor onPress={() => void update($, pending, () => 'none|')} />}
          </Box>
          <Box paddingLeft={2} marginTop={1}>
            <Input key="new-profile" label="New profile " placeholder="a name, e.g. work, meeting" submitLabel="create" onSubmit={create} />
          </Box>
        </Box>
      )
    }

    const isManual = now?.scope === 'session' || now?.scope === 'computer'
    const currentTab = await read($, tab)
    const modsShown = await read($, mods)
    const scope = await read($, modsScope)

    const showTab = (id: string) => {
      void update($, tab, () => id)

      if (id === 'mods') {
        void loadMods($)
      }
    }

    // One setting: a press flips a toggle or moves a choice on; a text or a number is typed.
    const settingRow = (setting: ModSetting) => {
      const where = setting.isHere ? ' (this computer)' : ''
      const title = `${setting.label}${where}`

      if (setting.isLocked) {
        return <Text key={`setting-${setting.key}`} dimColor>{truncate(`${title}: ${String(setting.value)} (locked)`, width - 4)}</Text>
      }

      if (setting.kind === 'boolean') {
        return (
          <Box key={`setting-${setting.key}`} flexDirection="row" hover={LIT_BOX}>
            <Button
              key={`set-${setting.key}`}
              label={`${setting.value === true ? '[x]' : '[ ]'} ${truncate(title, width - 8)}`}
              plain
              hover={LIT_TEXT}
              onPress={() => void setMod($, setting, setting.value !== true)}
            />
          </Box>
        )
      }

      if (setting.kind === 'choice') {
        const options = setting.options ?? []
        const following = options[(options.indexOf(String(setting.value)) + 1) % Math.max(1, options.length)] ?? ''

        return (
          <Box key={`setting-${setting.key}`} flexDirection="row" hover={LIT_BOX}>
            <Button
              key={`set-${setting.key}`}
              label={truncate(`${title}: ${String(setting.value)}`, width - 4)}
              plain
              hover={LIT_TEXT}
              onPress={() => void setMod($, setting, following)}
            />
          </Box>
        )
      }

      return (
        <Input
          key={`set-${setting.key}`}
          label={`${truncate(title, Math.floor(width / 2))} `}
          value={String(setting.value)}
          submitLabel="save"
          onSubmit={(typed: string) => void setMod($, setting, setting.kind === 'number' ? Number(typed) : typed)}
        />
      )
    }

    const modsTab = () => {
      if (modsShown === null) {
        return <Text dimColor>Loading…</Text>
      }

      const plugins = [...new Set(modsShown.settings.map(setting => setting.plugin))]

      return (
        <Box flexDirection="column">
          {modsShown.machine !== '' ? (
            <Box flexDirection="row" gap={1}>
              <Text>Changes apply to</Text>
              <Button key="scope-all" label="all computers" dimColor={scope !== 'all'} onPress={() => void update($, modsScope, () => 'all')} />
              <Button key="scope-here" label={`this computer only (${modsShown.machine})`} dimColor={scope !== 'here'} onPress={() => void update($, modsScope, () => 'here')} />
            </Box>
          ) : (
            <Text dimColor>Changes apply to this computer: there is no private sync to share them.</Text>
          )}
          {plugins.length === 0 && <Text dimColor>No mod has settings.</Text>}
          {plugins.map(plugin => {
            const key = `mod|${plugin}`
            const isOpen = open[key] ?? true
            const settings = modsShown.settings.filter(setting => setting.plugin === plugin)

            return (
              <Box key={key} flexDirection="column" marginTop={1}>
                {foldLine(key, `${plugin} (${settings.length})`, isOpen)}
                {isOpen && (
                  <Box flexDirection="column" paddingLeft={2}>
                    {settings.map(settingRow)}
                  </Box>
                )}
              </Box>
            )
          })}
        </Box>
      )
    }

    const tabRow = (
      <Box flexDirection="row" gap={2} marginBottom={1}>
        {TABS.map(one => (
          <Button key={`tab-${one.id}`} label={one.title} plain dimColor={one.id !== currentTab} onPress={() => showTab(one.id)} />
        ))}
      </Box>
    )

    if (currentTab === 'mods') {
      return (
        <Box flexDirection="column">
          {tabRow}
          {modsTab()}
        </Box>
      )
    }

    return (
      <Box flexDirection="column">
        {tabRow}
        <Text dimColor={now?.profile === ''}>{status()}</Text>
        <Box flexDirection="row" justifyContent="flex-end">
          <Box flexDirection="row" gap={1}>
            {isManual && <Button key="off" label="off" onPress={() => void turnOff($)} />}
            {now?.scope === 'rule' && <Button key="show-all" label="show all" dimColor onPress={() => void update($, pending, () => 'none|')} />}
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
