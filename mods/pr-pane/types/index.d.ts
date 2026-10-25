export type CiCheck = { name: string; state: string; required: boolean | null; link: string | null }

/** `until`: YYYY-MM-DD, empty when it lasts until the alert changes; `note`: the reminder's words. */
export type Ack = { until: string; note: string; at: string }

export type PrRow = {
  url: string
  repo: string
  number: string
  title: string
  /** The PR's body, cut by pr-watch; absent from snapshots taken before it was recorded. */
  description?: string
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
  /** The user acknowledged its current alert (pr-watch ack), until it changes or `until` passes. */
  ack?: Ack | null
  /** Kept but quiet (pr-watch park): never in "needs your attention", its changes not reported. */
  parked?: boolean
  parkedWhy?: string
  changes: string[]
  /** Its last activity on the host (a push, a comment, a vote); absent from records taken before. */
  updated?: string
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

/** A pipeline run the user launched by hand: queued or running, or ended in the last day. */
export type BuildRow = {
  url: string
  repo: string
  pipeline: string
  number: string
  branch: string
  /** `queued`, `running`, `succeeded`, `partially succeeded`, `failed` or `canceled`. */
  status: string
  requestedBy: string
  queued: string
  started: string
  ended: string
  /** The run's host did not answer: this is the run as last found there. */
  stale?: boolean
  ack?: Ack | null
  /** What started it: the user by hand, or a push of theirs; absent on runs recorded before. */
  trigger?: 'manual' | 'push' | null
  /** The title of the commit it ran on; absent when the host does not say or on runs recorded before. */
  commit?: string
  /** The file holding the steps pr-watch read for this ended run, when it kept them. */
  stepsFile?: string
}

/** A GitHub issue the user is subscribed to: open, or closed in the last days. */
export type IssueRow = {
  url: string
  repo: string
  number: string
  title: string
  author: string
  /** `open` or `closed`; `reason` says how it closed (`completed`, `not planned`). */
  state: string
  reason: string
  labels: string[]
  comments: number
  updated: string
  closed: string
  /** What changed since the user last saw it: new comments by others, a close or reopen, labels. */
  changes: string[]
}

/** One host's share: when and by which computer it was fetched. */
export type Share = { at: string; by: string }

export type PrSnapshot = {
  prs: PrRow[]
  reviews?: ReviewPr[]
  builds?: BuildRow[]
  /** Absent from a pr-watch that follows no issue. */
  issues?: IssueRow[]
  recent?: RecentPr[]
  errors: string[]
  isLive: boolean
  at: string
  /** Per host (`github`, `ado`): the shared snapshot shown; absent from a pr-watch that shares nothing. */
  sections?: Record<string, Share>
  /** The hosts this status fetched itself. */
  fetched?: string[]
}

export type CheckDetails = { isLoading: boolean; lines: string[] }

/** One step of a pipeline run; `errors` holds its messages when it failed or had issues. */
export type BuildStep = { name: string; job: string; state: string; errors: string[] }

export type BuildDetails = { isLoading: boolean; steps: BuildStep[] }

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
    'pr-pane': {
      snapshot: PrSnapshot | null
      /** pr-watch is installed: the band shows its button, even with nothing tracked. */
      isActive: boolean
      isRefreshing: boolean
      problem: string
      ciToggled: Record<string, boolean>
      details: Record<string, CheckDetails>
      /** By run URL: its steps, once the user asked for them. */
      buildDetails: Record<string, BuildDetails>
      /** By run URL: the steps of an ended run already read this session, shown again at once. */
      readSteps: Record<string, BuildStep[]>
      /** `<run URL>|<step index>` of the steps whose messages are unfolded. */
      openSteps: Record<string, boolean>
      armed: string
      /** `approve|<url>` or `merge|<url>` while pr-watch runs it. */
      busy: string
      isRecentOpen: boolean
      openRepos: Record<string, boolean>
      /** PR and issue URLs whose details are unfolded. */
      openPrs: Record<string, boolean>
      /** The changes the user read by opening a PR or an issue, kept on screen for the session. */
      readChanges: Record<string, string[]>
    }
  }
}
