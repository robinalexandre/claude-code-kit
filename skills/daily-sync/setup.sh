#!/bin/bash
# Sets up daily-sync: the time of the morning sync. Run it again any time:
#   bash ~/.claude/skills/daily-sync/setup.sh
set -eu
LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib" && pwd)
. "$LIB/jq.sh"
. "$LIB/ask.sh"
. "$LIB/kit.sh"
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ ! -d "$HOME/.claude-sync/.git" ]; then
  echo "  The sync engine isn't set up on this computer yet (the config-sync plugin, or sync/README.md in the kit)."
  echo "  Once it is, run: bash $SK/setup.sh"
  exit 0
fi
bash "$SK/schedule.sh" status || true
time=$(reply daily-sync.time "Time of the daily sync, 24 h (- for none):" 09:00)
case "$time" in
  -) bash "$SK/schedule.sh" off && kit_setup_mark daily-sync declined ;;
  [0-2][0-9]:[0-5][0-9]) bash "$SK/schedule.sh" on "$time" && kit_setup_mark daily-sync done ;;
  *) echo "  Not a time (HH:MM): nothing changed." ;;
esac
