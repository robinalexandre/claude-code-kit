import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { ModSetting } from '../types'

// The kit's Configuration pane: every mod's settings. The pane mods depend on this one, so it comes
// with any of them; dnd's Do not disturb pane opens from here as a tab of its own.
const PANE = 'configuration'
const TITLE = 'Configuration'
const COMMAND = 'configuration'
const DND_PANE = 'dnd'
const DND_TITLE = 'Do not disturb'
// Under the pointer, what folds turns to the theme's suggestion color with the text drawn on it in
// the theme's inverse text color: readable in a light and a dark theme alike.
const LIT_BOX = { backgroundColor: 'suggestion' }
const LIT_TEXT = { color: 'inverseText', dimColor: false }

const mods = atom({ plugin: 'configuration', key: 'mods' } as const, null)
const scope = atom({ plugin: 'configuration', key: 'scope' } as const, 'all')
const saves = atom({ plugin: 'configuration', key: 'saves' } as const, 0)
const unfolded = atom({ plugin: 'configuration', key: 'unfolded' } as const, {})
const power = atom({ plugin: 'configuration', key: 'power' } as const, null, { shape: 'low-power/1' })
const syncPause = atom({ plugin: 'configuration', key: 'syncPause' } as const, null)

// Set by dnd once it has read what is on: dnd is installed. Read under dnd's shape.
const dndActive = atom({ plugin: 'dnd', key: 'active' } as const, null, { shape: 'dnd-active/1' })

// The band's buttons share one row under everything above the prompt, whatever order the mods
// draw in: each takes that row out of what the mods beneath drew, adds its own button, and sorts
// them by key (band-1-history, band-2-prs, band-3-reminders, band-4-configuration).
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

const home = async ($: EngineInterface) => slashed((await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE')) ?? '~')

const truncate = (text: string, width: number) =>
  text.length > width ? `${text.slice(0, Math.max(0, width - 1))}…` : text

// A change for every computer is a /config change, which the private sync shares; one for this
// computer alone is also written to the sync's machine file, whose settings win over the shared
// ones at each sync, so the shared value stays for the other computers.
type Json = Record<string, unknown>

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
  // The private sync builds settings.json from its shared settings, then the machine file's over them.
  const shared = file === '' ? {} : { settings: await readJson($, `${await home($)}/.claude-sync/settings.shared.json`) }
  const settings = (await $.config.list())
    .filter(row => row.provider.tier === 'user' && row.key.includes('.'))
    .map((row): ModSetting => {
      const plugin = row.key.slice(0, row.key.indexOf('.'))
      const field = row.key.slice(plugin.length + 1)
      const isHere = overlayValue(overlay, plugin, field) !== undefined
      const sharedValue = isHere ? overlayValue(shared, plugin, field) : undefined

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
        isHere,
        ...(sharedValue !== undefined ? { shared: sharedValue as ModSetting['value'] } : {}),
      }
    })

  await update($, mods, () => ({ settings, machine }))
}

// What every other computer has for a setting this one keeps apart.
const sharedText = (setting: ModSetting) =>
  setting.shared === undefined ? 'the default' : setting.shared === true ? 'on' : setting.shared === false ? 'off' : String(setting.shared)

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
  const isHere = file !== '' && (await read($, scope)) === 'here'

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
    await update($, saves, count => count + 1)
  }
}

// The private sync's pause: `sync.sh pause` stops every sync on this computer until `resume`.
const syncDir = async ($: EngineInterface) => `${await home($)}/.claude-sync`

const loadSync = async ($: EngineInterface, error?: string) => {
  const sync = await syncDir($)

  if (!(await $.fs.exists(`${sync}/sync.sh`))) {
    return
  }

  const since = await $.fs.read(`${sync}/.state/paused`).then(
    text => text.trim(),
    () => undefined,
  )

  await update($, syncPause, () => ({ isPaused: since !== undefined, since: since ?? '', ...(error ? { error } : {}) }))
}

// On Windows, Claude Code's own PATH has Git's cmd folder (git) but not bash: Git Bash is found
// from the variable Claude Code reads for it, then from git's own install folder. There a bare name
// comes last: Windows looks for it in the current folder first, where a repo could plant a bash.exe.
let bashFound: string | undefined

const runs = async ($: EngineInterface, argv: string[]) => {
  try {
    return (await $.process.run(argv, { timeoutMs: 10_000 })).exitCode === 0
  } catch {
    return false
  }
}

const bash = async ($: EngineInterface) => {
  if (bashFound !== undefined) {
    return bashFound
  }

  const fromGit = async () => {
    const execPath = await $.process.run(['git', '--exec-path'], { timeoutMs: 10_000 }).catch(() => undefined)
    const root = slashed(execPath?.stdout.trim() ?? '').replace(/\/(mingw64|clangarm64|mingw32)\/.*$/, '')

    return execPath?.exitCode === 0 && root !== '' ? `${root}/bin/bash.exe` : ''
  }
  const fromEnv = async () => slashed((await $.env.get('CLAUDE_CODE_GIT_BASH_PATH')) ?? '')
  const fromFiles = async () => `${slashed((await $.env.get('ProgramFiles')) ?? 'C:/Program Files')}/Git/bin/bash.exe`
  const bare = async () => 'bash'
  const candidates =
    (await $.env.get('OS')) === 'Windows_NT' ? [fromEnv, fromGit, fromFiles, bare] : [fromEnv, bare, fromGit, fromFiles]

  for (const candidate of candidates) {
    const path = await candidate()

    if (path !== '' && (await runs($, [path, '-c', 'exit 0']))) {
      bashFound = path

      return path
    }
  }

  throw new Error('Git Bash not found: set CLAUDE_CODE_GIT_BASH_PATH to bash.exe')
}

const setSync = async ($: EngineInterface, verb: 'pause' | 'resume') => {
  let error: string | undefined

  try {
    const result = await $.process.run([await bash($), `${await syncDir($)}/sync.sh`, verb], { timeoutMs: 30_000 })

    if (result.exitCode !== 0) {
      error = (result.stderr.trim() || result.stdout.trim() || `exit ${result.exitCode}`).split('\n')[0]
    }
  } catch (caught) {
    error = String(caught).split('\n')[0] ?? ''
  }

  await loadSync($, error)
}

const openPane = async ($: EngineInterface) => {
  await $.ui.open({ id: PANE, title: TITLE, columns: 64 })
  await Promise.all([loadMods($), loadSync($)])
}

// Low power mode, for every part of the kit that fetches by itself: `on`, `off`, or `on battery`
// (while the computer runs on its battery or in its low power mode). The mods read it under the
// shape `low-power/1`; scripts (pr-watch, the status line) from ~/.claude/.low-power.json.
const POWER_FILE = '.low-power.json'
const POWER_EVERY_MS = 60_000
// A PowerShell call costs a second: Windows is asked less often.
const POWER_EVERY_WINDOWS_MS = 5 * 60_000
const POWER_KEPT_MS = 10 * 60_000
const LINUX_MAINS = ['AC', 'ACAD', 'AC0', 'ADP0', 'ADP1']

type PowerWay = 'pmset' | 'linux' | 'windows' | 'none'
let powerWay: PowerWay | undefined

const ran = async ($: EngineInterface, argv: string[]) => {
  try {
    const result = await $.process.run(argv, { timeoutMs: 10_000 })

    return result.exitCode === 0 ? result.stdout : undefined
  } catch {
    return undefined
  }
}

const linuxMains = async ($: EngineInterface) => {
  for (const name of LINUX_MAINS) {
    const online = await $.fs.read(`/sys/class/power_supply/${name}/online`).catch(() => undefined)

    if (online !== undefined) {
      return online.trim()
    }
  }

  return undefined
}

// Whether the computer runs on its battery or in its low power mode; false when it cannot tell.
const onBattery = async ($: EngineInterface) => {
  if (powerWay === undefined || powerWay === 'pmset') {
    const battery = await ran($, ['pmset', '-g', 'batt'])

    if (battery !== undefined) {
      powerWay = 'pmset'
      const settings = (await ran($, ['pmset', '-g'])) ?? ''

      return battery.includes("'Battery Power'") || /lowpowermode\s+1/.test(settings)
    }
  }

  if (powerWay === undefined || powerWay === 'linux') {
    const online = await linuxMains($)

    if (online !== undefined) {
      powerWay = 'linux'

      return online === '0'
    }
  }

  if (powerWay === undefined || powerWay === 'windows') {
    const system = slashed((await $.env.get('SystemRoot')) ?? 'C:/Windows')
    const status = await ran($, [`${system}/System32/WindowsPowerShell/v1.0/powershell.exe`, '-NoProfile', '-NonInteractive', '-Command', '(Get-CimInstance Win32_Battery).BatteryStatus'])

    if (status !== undefined) {
      powerWay = 'windows'

      // 1: the battery is discharging, on battery power.
      return status.trim().split(/\s+/).includes('1')
    }
  }

  powerWay = 'none'

  return false
}

let powerSetting = 'on battery'
let powerWritten = { text: '', at: 0 }

const checkPower = async ($: EngineInterface) => {
  const isLow = powerSetting === 'on' || (powerSetting === 'on battery' && (await onBattery($)))
  const now = await $.clock.now()
  await update($, power, () => ({ setting: powerSetting, isLow }))
  const text = JSON.stringify({ setting: powerSetting, lowPower: isLow })

  // Written when it changes, and now and then so the scripts know it is still checked.
  if (text !== powerWritten.text || now - powerWritten.at >= POWER_KEPT_MS / 2) {
    const dir = await $.env.get('CLAUDE_CONFIG_DIR')
    const path = `${dir ? slashed(dir) : `${await home($)}/.claude`}/${POWER_FILE}`
    await $.fs
      .write(path, `${JSON.stringify({ setting: powerSetting, lowPower: isLow, at: new Date(now).toISOString() })}\n`)
      .then(() => {
        powerWritten = { text, at: now }
      })
      .catch(() => undefined)
  }
}

let powerTicking: { cancel: () => void } | undefined

const startPower = async ($: EngineInterface) => {
  powerTicking?.cancel()
  await checkPower($)
  powerTicking = $.clock.every(powerWay === 'windows' ? POWER_EVERY_WINDOWS_MS : POWER_EVERY_MS, () => void checkPower($).catch(() => undefined))
}

let loadAsked = false

export const register: Register = (on, options) => {
  powerSetting = typeof options.lowPower === 'string' ? options.lowPower : 'on battery'

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: COMMAND, description: "Open the Configuration pane: every mod's settings" }).catch(() => undefined)
    void startPower($).catch(() => undefined)

    return next(e)
  })

  on('command.run', { command: COMMAND }, async $ => {
    await openPane($)

    return { text: 'Configuration pane opened.' }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const beneath = await next(e)

    // A reload (a setting changed) brings no session start: the power check starts again here.
    if (powerTicking === undefined) {
      powerTicking = { cancel: () => undefined }
      void startPower($).catch(() => undefined)
    }

    if (e.props.hasSurvey || e.props.view.agentId !== undefined) {
      return beneath
    }

    const { Box, Button } = $.ui.resolve(e)
    const { rest, buttons } = takeBandRow(beneath)
    const mine = (
      <Box key="band-4-configuration" flexDirection="row">
        <Button key="configuration" label={TITLE} dimColor onPress={() => void openPane($)} />
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
    const shown = await read($, mods)
    const where = await read($, scope)
    const saved = await read($, saves)
    const open = await read($, unfolded)
    const hasDnd = (await read($, dndActive)) !== null
    const sync = await read($, syncPause)
    const width = Math.max(30, e.props.bodyColumns - 2)

    // Read on the first draw after a load or reload: opened by another mod's button (dnd's), or kept
    // open while a mod brought new settings.
    if (!loadAsked) {
      loadAsked = true
      void loadMods($)
      void loadSync($)
    }

    // One setting: a press flips a toggle or moves a choice on; a text or a number is typed.
    const settingRow = (setting: ModSetting) => {
      const title = `${setting.label}${setting.isHere ? ' (this computer)' : ''}`

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

      // The field keeps what was typed until it is drawn anew: a key per save draws the saved value
      // again, even when it did not change. A number that does not read as one is not saved.
      const save = (typed: string) => {
        if (setting.kind !== 'number') {
          void setMod($, setting, typed)
        } else if (typed.trim() !== '' && Number.isFinite(Number(typed))) {
          void setMod($, setting, Number(typed))
        } else {
          void update($, saves, count => count + 1)
        }
      }

      return (
        <Input
          key={`set-${setting.key}-${saved}`}
          label={`${truncate(title, Math.floor(width / 2))} `}
          value={String(setting.value)}
          submitLabel="save"
          onSubmit={save}
        />
      )
    }

    const toggle = (key: string) => void update($, unfolded, all => ({ ...all, [key]: !(all[key] ?? true) }))

    const header = (
      <Box flexDirection="row" justifyContent="space-between" marginBottom={1}>
        <Text bold>Mod settings</Text>
        {hasDnd && <Button key="open-dnd" label={`${DND_TITLE} ›`} dimColor onPress={() => void $.ui.open({ id: DND_PANE, title: DND_TITLE, columns: 64 })} />}
      </Box>
    )

    const syncRow = sync !== null && (
      <Box key="sync" flexDirection="column" marginBottom={1}>
        <Box flexDirection="row" gap={2}>
          <Text {...(sync.isPaused ? { color: 'yellow' } : { dimColor: true })}>
            {truncate(sync.isPaused ? `Config sync paused since ${sync.since}` : 'Config sync on', width - 10)}
          </Text>
          <Button key={sync.isPaused ? 'sync-resume' : 'sync-pause'} label={sync.isPaused ? 'Resume' : 'Pause'} onPress={() => void setSync($, sync.isPaused ? 'resume' : 'pause')} />
        </Box>
        {sync.error !== undefined && <Text color="red">{truncate(`Could not change the sync: ${sync.error}`, width - 2)}</Text>}
      </Box>
    )

    if (shown === null) {
      return (
        <Box flexDirection="column">
          {header}
          {syncRow}
          <Text dimColor>Loading…</Text>
        </Box>
      )
    }

    const plugins = [...new Set(shown.settings.map(setting => setting.plugin))]

    return (
      <Box flexDirection="column">
        {header}
        {syncRow}
        {shown.machine !== '' ? (
          <Box flexDirection="row" gap={1}>
            <Text>Changes apply to</Text>
            <Button key="scope-all" label="all computers" dimColor={where !== 'all'} onPress={() => void update($, scope, () => 'all')} />
            <Button key="scope-here" label={`this computer only (${shown.machine})`} dimColor={where !== 'here'} onPress={() => void update($, scope, () => 'here')} />
          </Box>
        ) : (
          <Text dimColor>Changes apply to this computer: there is no private sync to share them.</Text>
        )}
        {plugins.length === 0 && <Text dimColor>No mod has settings.</Text>}
        {plugins.map(plugin => {
          const key = `mod|${plugin}`
          const isOpen = open[key] ?? true
          const settings = shown.settings.filter(setting => setting.plugin === plugin)

          return (
            <Box key={key} flexDirection="column" marginTop={1}>
              <Box flexDirection="row" hover={LIT_BOX}>
                <Button key={`fold-${key}`} label={`${isOpen ? '▾' : '▸'} ${truncate(`${plugin} (${settings.length})`, width - 4)}`} plain hover={LIT_TEXT} onPress={() => toggle(key)} />
              </Box>
              {isOpen && (
                <Box flexDirection="column" paddingLeft={2}>
                  {settings.map(setting => (
                    <Box key={`row-${setting.key}`} flexDirection="column">
                      {settingRow(setting)}
                      {setting.isHere && <Text dimColor>{truncate(`  used here instead of all computers' value: ${sharedText(setting)}`, width - 4)}</Text>}
                    </Box>
                  ))}
                </Box>
              )}
            </Box>
          )
        })}
      </Box>
    )
  })
}
