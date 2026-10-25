/** One mod setting (a plugin's userConfig field) as the Mods list shows it. */
export type ModSetting = {
  /** `<plugin>.<field>`, as `$.config.set` takes it. */
  key: string
  plugin: string
  field: string
  label: string
  description?: string
  kind: 'boolean' | 'choice' | 'text' | 'number'
  value: boolean | string | number | string[]
  options?: string[]
  isLocked: boolean
  /** Kept for this computer alone, in the private sync's machine file, over the shared value. */
  isHere: boolean
  /** With isHere, the value every other computer has (the private sync's shared settings); absent: the default. */
  shared?: boolean | string | number | string[]
}

/** Every user mod's settings, and this computer's name in the private sync ('' with none). */
export type ModsData = { settings: ModSetting[]; machine: string }

/** Low power mode: what the user chose, and whether it slows the kit now. */
export type LowPower = { setting: string; isLow: boolean }

/** What dnd shares under the shape `dnd-active/1`; only whether it is set is read here. */
export type DndActiveSeen = Record<string, unknown>

declare module 'claude-code' {
  interface PluginState {
    configuration: {
      /** The settings listed; null before they are first read. */
      mods: ModsData | null
      /** Where a change goes: every computer, or this one alone. */
      scope: 'all' | 'here'
      /** Settings saved, counted: a typed field is drawn anew with each. */
      saves: number
      /** The mods folded (`mod|<plugin>`: false), open by default. */
      unfolded: Record<string, boolean>
      /**
       * Low power mode as the other mods read it, under the shape `low-power/1`: the setting (`on`,
       * `off`, `on battery`) and whether it is on now. null before the first check.
       */
      power: Shaped<LowPower | null>
    }
    dnd: {
      active: Shaped<DndActiveSeen | null>
    }
  }
}
