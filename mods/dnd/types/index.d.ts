/** The panes a profile quiets: the history, the PRs & CI, the reminders, the handoffs. */
export type DndPart = 'history' | 'prs' | 'reminders' | 'handoffs'

/**
 * `only`: the names kept (repos, groups, folders; `@here` is the session's folder). `keep`, in what
 * is on: those names as the panes match them, lowercase, the last part of a path, @here resolved.
 */
export type DndPartRule = { mode?: 'show' | 'hide' | 'only'; only?: string[]; keep?: string[] }

export type DndProfile = Partial<Record<DndPart, DndPartRule>>

/** A rule turning a profile on when all its keys hold. */
export type DndRule = { profile: string; wifi?: string; folder?: string; days?: string; from?: string; to?: string }

/** What is on now for this session, as `dnd.sh active` prints it; `profile` '' when nothing is. */
export type DndActive = {
  profile: string
  why: string
  /** Epoch seconds the switch ends, 0 when it lasts. */
  until: number
  untilText: string
  /** `session`, `computer` or `everywhere` when turned on by hand, `rule` when a rule did, '' when off. */
  scope: string
  parts: DndProfile
  /** The session's repo, else its folder. */
  here: { path: string; name: string }
  wifi: string
}

/** Everything the pane shows, as `dnd.sh json` prints it. */
export type DndData = {
  profiles: Record<string, DndProfile>
  rules: DndRule[]
  active: DndActive
  /** By part: the names it lists now, offered in a profile's checklist. */
  known: Partial<Record<DndPart, string[]>>
  /** Every repo and folder worked in (the config sync's, the dev folder's), offered in every checklist. */
  workspaces?: string[]
  /** The Wi-Fi network this computer is on, '' when none or unknown. */
  wifi: string
  file: string
}

/** One setting a mod declares (its manifest's userConfig), as the /config menu holds it. */
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
}

/** The Mods tab: every user mod's settings, and this computer's name in the private sync ('' with none). */
export type ModsData = { settings: ModSetting[]; machine: string }

declare module 'claude-code' {
  interface PluginState {
    dnd: {
      /**
       * What the other panes read to hide or filter what they show; null before the first read.
       * Kept under the shape `dnd-active/1`: a pane naming another shape reads it as absent and
       * shows everything, so a change of its fields bumps the shape in every mod that reads it.
       */
      active: Shaped<DndActive | null>
      data: DndData | null
      problem: string
      /** A profile to turn on, asked until when and where in the pane: `<profile>|<for>|<scope>`. */
      pending: string
      /** Profiles and their parts (`<profile>|<part>`) unfolded in the pane. */
      unfolded: Record<string, boolean>
      /** `<what>|<name>` pressed once: a second press confirms. */
      armed: string
      busy: boolean
      /** The Configuration pane's tab shown. */
      tab: string
      /** The Mods tab's settings; null before the tab is first read. */
      mods: ModsData | null
      /** Where a change made in the Mods tab goes: every computer, or this one alone. */
      modsScope: 'all' | 'here'
    }
  }
}
