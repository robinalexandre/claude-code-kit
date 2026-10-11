export type RecentPrompt = { id: string; text: string; time?: string }

declare module 'claude-code' {
  interface PluginState {
    'recent-prompts': { prompts: RecentPrompt[]; query: string; waiting: string[] }
  }
}
