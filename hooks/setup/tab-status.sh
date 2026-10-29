#!/bin/bash
# Sets up tab-status: turns off Claude Code's own tab title, which would write over the status
# marks. Run it again any time:
#   bash ~/.claude/hooks/setup/tab-status.sh
set -eu
LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)
. "$LIB/jq.sh"
. "$LIB/ask.sh"
. "$LIB/kit.sh"

echo "  Claude Code writes its own tab title (a spinner and the session's title). tab-status"
echo "  shows the same title with a mark of the session's state, so Claude Code's has to be off."
if ask tab-status.title "Turn off Claude Code's own tab title?" y; then
  kit_env CLAUDE_CODE_DISABLE_TERMINAL_TITLE 1
  echo "  Done: new sessions show 🟡 working, 🔴 waiting for you, 🟢 done, ❌ failed."
  kit_setup_mark tab-status done
else
  echo "  Left on: tab-status still rings the bell, but its marks are written over."
  kit_setup_mark tab-status declined
fi
mkdir -p "$HOME/.claude/tab-status"
: > "$HOME/.claude/tab-status/.setup-asked"
