export type Picture = {
  label: string
  path: string
  columns: number
  rows: number
  cells: string | null
}

declare module 'claude-code' {
  interface PluginState {
    'paste-preview': {
      draft: Picture[]
      sent: StateFamily<Picture[]>
      fullText: StateFamily<string>
    }
  }
}
