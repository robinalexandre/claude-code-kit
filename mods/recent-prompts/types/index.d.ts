/** One reply Claude wrote to the person: the text of a response, never its tool calls. */
export type Answer = { id: string; text: string; time?: string }

/** `kind` `learn`: a "💡 Learn:" block Claude ended a reply with (the learn mod), listed after the message it answered. */
export type RecentPrompt = { id: string; text: string; time?: string; kind?: 'learn'; answers?: Answer[] }

declare module 'claude-code' {
  interface PluginState {
    'recent-prompts': {
      prompts: RecentPrompt[]
      query: string
      waiting: string[]
      /** The messages and replies the person unfolded in the pane, by id. */
      unfolded: Record<string, boolean>
    }
  }
}
