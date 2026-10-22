#!/bin/bash
# Sets up daily-sync: the time of the morning sync. Run it again any time:
#   bash ~/.claude/skills/daily-sync/setup.sh
set -eu
. "$HOME/.claude/hooks/lib/ask.sh"
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ ! -d "$HOME/.claude-sync/.git" ]; then
  echo "  The sync engine isn't set up on this computer yet (sync/README.md in the kit)."
  echo "  Once it is, run: bash ~/.claude/skills/daily-sync/setup.sh"
  exit 0
fi
bash "$SK/schedule.sh" status || true
time=$(reply daily-sync.time "Time of the daily sync, 24 h (- for none):" 09:00)
case "$time" in
  -) bash "$SK/schedule.sh" off ;;
  [0-2][0-9]:[0-5][0-9]) bash "$SK/schedule.sh" on "$time" ;;
  *) echo "  Not a time (HH:MM): nothing changed." ;;
esac
