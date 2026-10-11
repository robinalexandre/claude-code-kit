#!/bin/sh
# Keyboard-backlight status signal for Claude Code events (Agent Nocturne).
#
# Replaces the agent-nocturne plugin adapter. That adapter awaited stdin EOF
# (`for await (const chunk of process.stdin)`) before it ever spoke to the
# daemon, so it hit its own 2s hook timeout on essentially every event and
# added ~2s to every tool call. This talks to the same `nocturne` CLI and
# daemon, but returns in milliseconds.
#
# Usage: nocturne-notify.sh <event> [<event>...] [extra nocturne flags]
# Events: startup thinking tool-start tool-error tool-end tool-batch-end
#         permission waiting-input blocked compact background notification
#         done error cancelled idle
#
# Attention events are latched states in the daemon; pass --ttl <ms> to say how
# long they keep signalling (they also clear as soon as an `idle` arrives for
# the same session).
#
# The session id matters: the daemon keys one latch per agent:session, so
# without it every Claude window would share a single latch and one window
# finishing a tool would cancel another window's pending permission blink.
#
# Fails open: if the CLI is missing this exits 0 and never interrupts the agent.

BIN="${NOCTURNE_BIN:-}"
[ -n "$BIN" ] || BIN="$(command -v nocturne 2>/dev/null)"
if [ -z "$BIN" ]; then
  for d in "$HOME"/.nvm/versions/node/*/bin; do
    if [ -x "$d/nocturne" ]; then BIN="$d/nocturne"; break; fi
  done
fi
[ -n "$BIN" ] && [ -x "$BIN" ] || exit 0

SESSION="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_PID:-default}}"

# Detach completely: no stdin, no inherited pipes, no waiting.
( "$BIN" notify "$@" --agent claude --session "$SESSION" --quiet >/dev/null 2>&1 </dev/null & )

exit 0
