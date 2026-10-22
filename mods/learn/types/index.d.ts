export type LearnLevel = 'off' | 'brief' | 'normal' | 'deep'

declare module 'claude-code' {
  interface PluginState {
    learn: { level: LearnLevel }
  }
}
