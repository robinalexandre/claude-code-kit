#!/bin/bash
# Usage: wave-check.sh stop|prompt   (hook input JSON on stdin)
# Nudges, never blocks: warns when the last reply did not start with the
# CLAUDE_REPLY_MARKER emoji. Does nothing until that variable is set.
set -u
MARKER=${CLAUDE_REPLY_MARKER:-${CLAUDE_PLUGIN_OPTION_MARKER:-}}
[ -n "$MARKER" ] || exit 0
. "$(dirname "$0")/lib/jq.sh"
input=$(cat)
judge='sub("^\\s+"; "") | if . == "" then "empty" elif startswith($m) then "ok" else "missing" end'

# On Stop the final reply may not be in the transcript yet; Claude Code hands it over directly.
verdict=$(printf '%s' "$input" | jq -r --arg m "$MARKER" ".last_assistant_message | strings | $judge" 2>/dev/null)
if [ -z "$verdict" ]; then
  transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
  if [ -n "$transcript" ] && command -v cygpath >/dev/null 2>&1; then
    transcript=$(cygpath -u "$transcript")
  fi
  [ -f "$transcript" ] || exit 0
  verdict=$(grep -a '"type":"assistant"' "$transcript" \
    | jq -r --arg m "$MARKER" "select(.message.content[]? | .type==\"text\") | [.message.content[] | select(.type==\"text\") | .text] | join(\"\") | $judge" 2>/dev/null \
    | tail -n 1)
fi
[ "$verdict" = "missing" ] || exit 0

case "${1:-}" in
  stop)
    jq -n --arg m "$MARKER" '{systemMessage: "⚠️ Reply missing the \($m): the agent may be drifting."}'
    ;;
  prompt)
    echo "Reminder: your previous reply did not start with $MARKER. ~/.claude/CLAUDE.md asks for it on every message; start every message with $MARKER from now on."
    ;;
esac
exit 0
