export type CiCheck = { name: string; state: string; required: boolean | null; link: string | null }

export type PrRow = {
  url: string
  repo: string
  number: string
  title: string
  status: string
  target: string
  source?: string
  after?: string
  conflicts?: boolean
  ci: string
  checks?: CiCheck[]
  votes: Record<string, string>
  waiting: string
  note: string
  changes: string[]
  checked: string
}

export type RecentPr = { url: string; repo: string; number: string; title: string; status: string; ended: string }

export type PrSnapshot = { prs: PrRow[]; recent?: RecentPr[]; errors: string[]; isLive: boolean; at: string }

export type CheckDetails = { isLoading: boolean; lines: string[] }

declare module 'claude-code' {
  interface PluginState {
    'pr-pane': {
      snapshot: PrSnapshot | null
      isRefreshing: boolean
      problem: string
      ciToggled: Record<string, boolean>
      details: Record<string, CheckDetails>
      armed: string
      isRecentOpen: boolean
    }
  }
}
