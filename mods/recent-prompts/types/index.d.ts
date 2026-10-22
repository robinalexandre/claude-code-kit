/** `kind` `learn`: a "💡 Learn:" block Claude ended a reply with (the learn mod), listed after the message it answered. */
export type RecentPrompt = { id: string; text: string; time?: string; kind?: 'learn' }

declare module 'claude-code' {
  interface PluginState {
    'recent-prompts': { prompts: RecentPrompt[]; query: string; waiting: string[] }
  }
}
