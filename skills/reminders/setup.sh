#!/bin/bash
# Sets up reminders: phone notifications through ntfy. Run it again any time:
#   bash ~/.claude/skills/reminders/setup.sh
set -eu
LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib" && pwd)
. "$LIB/jq.sh"
. "$LIB/ask.sh"
. "$LIB/kit.sh"
conf="$HOME/.claude/reminders.json"

echo "Reminders show at session start and as a desktop notification every morning (with daily-sync)."
echo "On the phone: through the Claude app (ask Claude when you leave the first reminder), or through ntfy,"
echo "a free app that receives what this computer sends to a topic."
current=$(jq -r '.ntfy // empty' "$conf" 2> /dev/null || true)
[ -n "$current" ] && echo "  ntfy is set: $current"
if ask reminders.ntfy "Send reminders to your phone through ntfy?"; then
  topic=${current:-https://ntfy.sh/claude-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')}
  topic=$(reply reminders.topic "Topic (anyone who knows it can read it, so keep it hard to guess):" "$topic")
  case "$topic" in http*) ;; *) topic="https://ntfy.sh/$topic" ;; esac
  [ -f "$conf" ] || echo '{}' > "$conf"
  jq --indent 2 --arg u "$topic" '.ntfy = $u' "$conf" > "$conf.tmp" && mv "$conf.tmp" "$conf"
  echo "  Install the ntfy app on your phone and subscribe to ${topic##*/} (server ${topic%/*})."
fi
kit_setup_mark reminders done
