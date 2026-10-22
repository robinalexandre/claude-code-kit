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
  /** Written on this computer. */
  isMine?: boolean
  body?: string
}

declare module 'claude-code' {
  interface PluginState {
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
      /** `<part>|<action>|<id>` while it runs. */
      busy: string
    }
  }
}
