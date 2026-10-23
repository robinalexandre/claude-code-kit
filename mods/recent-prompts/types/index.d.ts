/**
 * What else than plain text a reply can be, each kept when its setting is on: a question asked
 * with the picker, the person's pick, a plan, a file sent to the person, a push notification, a
 * slash command's output.
 */
export type AnswerKind = 'question' | 'pick' | 'plan' | 'file' | 'notification' | 'output'

/** One reply to the person: the text of a response, or one of the kinds above; never a tool call's work. */
export type Answer = { id: string; text: string; time?: string; kind?: AnswerKind }

/**
 * `kind` `learn`: a "💡 Learn:" block Claude ended a reply with (the learn mod), listed after the message it answered.
 * `kind` `command`: a slash command the person ran, listed as `/name args`.
 * An id that starts with `rebuilt-` was read back from the transcript, which gives no row ids to jump to.
 */
export type RecentPrompt = { id: string; text: string; time?: string; kind?: 'learn' | 'command'; answers?: Answer[] }

/** What the dnd mod has on, the part of it this pane reads: whether the history is hidden. */
export type DndActive = {
  profile: string
  parts: Partial<Record<string, { mode?: 'show' | 'hide' | 'only' }>>
}

declare module 'claude-code' {
  interface PluginState {
    /** The dnd mod's, read only under its shape `dnd-active/1`: absent when it is not installed. */
    dnd: {
      active: Shaped<DndActive | null>
    }
    'recent-prompts': {
      prompts: RecentPrompt[]
      query: string
      waiting: string[]
      /** The messages and replies the person unfolded in the pane, by id. */
      unfolded: Record<string, boolean>
    }
  }
}
