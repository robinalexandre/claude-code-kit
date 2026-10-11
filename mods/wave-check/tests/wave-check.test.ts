import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'
import { checkPrompt } from '../hooks/register'

const MARKER = '🌊'

const engine = (on: On, variables: Record<string, string> = { CLAUDE_REPLY_MARKER: MARKER }) => {
  const submitted: string[] = []
  mock.env(on, variables)
  on('prompt.submit', (_$, e) => {
    submitted.push(e.text)
    return { text: e.text }
  })
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_$, e) => ({ text: e.answer }))
  return submitted
}

const finish = ($: Engine, turnId: string, answer: string) =>
  $.turn.complete({ answer, durationMs: 1, isAborted: false, turnId, reason: 'answer' })

test('a reply without the marker gets one self-check', async ($, on) => {
  const submitted = engine(on)
  await finish($, 't1', 'Done, the patch is applied.')
  expect(submitted).toEqual([checkPrompt(MARKER)])
})

test('a reply that starts with the marker is left alone', async ($, on) => {
  const submitted = engine(on)
  await finish($, 't1', '🌊 Done.')
  await finish($, 't2', '\n  🌊 Done after a blank line.')
  expect(submitted).toEqual([])
})

test('any emoji can be the marker', async ($, on) => {
  const submitted = engine(on, { CLAUDE_REPLY_MARKER: '🦊' })
  await finish($, 't1', '🦊 Done.')
  await finish($, 't2', '🌊 Wrong marker.')
  expect(submitted).toEqual([checkPrompt('🦊')])
})

test('nothing is checked until a marker is set', async ($, on) => {
  const submitted = engine(on, {})
  await finish($, 't1', 'Done, the patch is applied.')
  expect(submitted).toEqual([])
})

test('interrupted, empty and subagent turns are left alone', async ($, on) => {
  const submitted = engine(on)
  await $.turn.complete({ answer: 'Partial', durationMs: 1, isAborted: true, turnId: 't1', reason: 'aborted' })
  await finish($, 't2', '')
  await $.turn.complete({
    answer: 'Subagent report',
    durationMs: 1,
    isAborted: false,
    turnId: 't3',
    agentId: 'agent-1',
    reason: 'answer',
  })
  expect(submitted).toEqual([])
})

test('a self-check reply that misses the marker does not loop', async ($, on) => {
  const submitted = engine(on)
  await $.turn.start({ text: checkPrompt(MARKER), turnId: 'check' })
  await finish($, 'check', 'Checked, nothing slipped.')
  expect(submitted).toEqual([])
})
