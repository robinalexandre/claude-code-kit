/** The parts the pane shows, each when its skill is installed. */
export type Source = 'reminders' | 'handoffs'

/** One reminder as `reminders.sh json` prints it; fields with no value are left out. */
export type Reminder = {
  id: string
  /** due, later, expired, elsewhere (another folder or computer) or past (closed). */
  state: string
  title: string
  on?: string
  until?: string
  /** Repeating ones: the days, as written ("friday", "monday, thursday", "day", "weekday"). */
  every?: string
  /** Repeating ones run several times a day: "08:00, 14:00". */
  times?: string
  /** An assistant's repeating task that folds the others due at its time into its message: "yes". */
  digest?: string
  /** Repeating ones: when it shows next, "YYYY-MM-DD HH:MM". */
  next?: string
  /** Repeating ones: the last day it was closed for. */
  done?: string
  where?: string
  machine?: string
  /** What it is filed under in the pane: an organization, a client, a project. */
  group?: string
  /** Past ones: when it was closed. */
  closed?: string
  body?: string
  /** A task for this assistant, which runs it by itself; its group is the assistant's name. */
  agent?: string
}

/** One handoff note as `handoff.sh json` prints it. */
export type Handoff = {
  id: string
  /** open, done (picked up) or canceled. */
  state: string
  title: string
  /** The computer that wrote it. */
  from?: string
  date?: string
  repo?: string
  branch?: string
  closed?: string
  /** The computer that runs it by itself, with `run`. */
  for?: string
  /** When that computer runs it: now, or a date and time. */
  run?: string
  /** What the run may do: read, edit or push. */
  scope?: string
  /** The run's state: queued, running, done, needs-you or failed. */
  status?: string
  /** The computer that ran it. */
  run_by?: string
  started?: string
  ended?: string
  /** Written on this computer. */
  isMine?: boolean
  /** For this computer. */
  isForHere?: boolean
  body?: string
  /** Set on an assistant's task, listed beside the notes: then the rest is a Reminder's. */
  agent?: string
}

/**
 * What the dnd mod has on, the part of it this pane reads: by part, hidden, or the names kept
 * (`keep`: lowercase, the last part of a path).
 */
export type DndActive = {
  profile: string
  parts: Partial<Record<string, { mode?: 'show' | 'hide' | 'only'; keep?: string[] }>>
}

declare module 'claude-code' {
  interface PluginState {
    /** The dnd mod's, read only under its shape `dnd-active/1`: absent when it is not installed. */
    dnd: {
      active: Shaped<DndActive | null>
    }
    /** The configuration mod's low power mode, read under its shape `low-power/1`. */
    configuration: {
      power: Shaped<{ setting: string; isLow: boolean } | null>
    }
    'reminders-handoffs': {
      reminders: Reminder[] | null
      handoffs: Handoff[] | null
      /** The parts whose skill is installed, in tab order. */
      enabled: Source[]
      /** By part: why its list could not be read, '' when it could. */
      problems: Partial<Record<Source, string>>
      tab: Source
      /** Reminder and note ids whose details are unfolded. */
      openIds: Record<string, boolean>
      /** Sections and groups (`<section>|<group>`) the user folded or unfolded. */
      openSections: Record<string, boolean>
      /** `<part>|<action>|<id>` pressed once: a second press confirms. */
      armed: string
      /** `<part>|<action>|<id>` while it runs, `refresh` while the refresh button's sync runs. */
      busy: string
      /** When the lists were last read, in epoch milliseconds; 0 before the first read. */
      loadedTime: number
    }
  }
}
