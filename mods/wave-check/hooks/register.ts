import type { Register } from 'claude-code'

const TAG = '[wave-check]'

export const checkPrompt = (marker: string) =>
  [
    `Your last reply didn't start with ${marker}. ~/.claude/CLAUDE.md asks for it on every message,`,
    `so a missing ${marker} means the user's instructions may have slipped during that reply.`,
    `Check that reply, and anything you changed while writing it, against ~/.claude/CLAUDE.md`,
    `and the project's CLAUDE.md, and fix what slipped. Then answer in a line or two, starting`,
    `with ${marker}: what you corrected, or that the rest holds. ${TAG}`,
  ].join(' ')

export const register: Register = on => {
  // A self-check reply that misses the marker too must not trigger another check.
  const checkTurns = new Set<string>()

  on('turn.start', (_$, e, next) => {
    if (e.text.includes(TAG)) checkTurns.add(e.turnId)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    const isCheckTurn = checkTurns.delete(e.turnId)
    const marker = (await $.env.get('CLAUDE_REPLY_MARKER'))?.trim()
    if (!marker) return result

    const answer = e.answer.trimStart()
    const isMissing =
      e.agentId === undefined && e.reason === 'answer' && answer !== '' && !answer.startsWith(marker)

    if (isMissing && !isCheckTurn) void $.prompt.submit({ text: checkPrompt(marker) })

    return result
  })
}
