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
  /** Tracked because the user approved it: listed apart until it is merged. */
  reviewed?: boolean
  changes: string[]
  checked: string
}

export type RecentPr = {
  url: string
  repo: string
  number: string
  title: string
  status: string
  reviewed?: boolean
  ended: string
}

/** An open PR whose review was asked from the user and not given yet. */
export type ReviewPr = { url: string; repo: string; number: string; title: string; author: string; updated: string }

export type PrSnapshot = {
  prs: PrRow[]
  reviews?: ReviewPr[]
  recent?: RecentPr[]
  errors: string[]
  isLive: boolean
  at: string
}

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
      approving: string
      isRecentOpen: boolean
      openRepos: Record<string, boolean>
    }
  }
}
