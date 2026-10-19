export type PrRow = {
  url: string
  repo: string
  number: string
  title: string
  status: string
  target: string
  ci: string
  votes: Record<string, string>
  waiting: string
  note: string
  changes: string[]
  checked: string
}

export type PrSnapshot = { prs: PrRow[]; errors: string[]; isLive: boolean; at: string }

declare module 'claude-code' {
  interface PluginState {
    'pr-pane': { snapshot: PrSnapshot | null; isRefreshing: boolean; problem: string }
  }
}
