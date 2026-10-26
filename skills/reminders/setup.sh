#!/bin/bash
# Sets up reminders: phone notifications through ntfy. Run it again any time:
#   bash ~/.claude/skills/reminders/setup.sh
set -eu
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB=$(cd "$SK/../../hooks/lib" && pwd)
. "$LIB/jq.sh"
. "$LIB/ask.sh"
. "$LIB/kit.sh"
conf="$HOME/.claude/reminders.json"

echo "Reminders show at session start and as a desktop notification every morning (with daily-sync)."
encrypted=$(bash "$SK/reminders.sh" encrypted)
if [ "$encrypted" = encrypted ]; then
  echo "Your sync repo encrypts the reminders (git-crypt): only what holds the key can read them. A Claude app"
  echo "cloud routine reads the repo from GitHub without the key, so it cannot notify them. On the phone, use:"
  echo "  - ntfy (below): this computer reads its own decrypted copy and pushes; it has to be on in the morning."
  assistants=$(bash "$SK/reminders.sh" agents | cut -f1 | paste -sd, - | sed 's/,/, /g')
  [ -z "$assistants" ] || echo "  - $assistants: if it holds the key, a daily task that lists the due reminders (ask Claude)."
  echo "  - a cloud routine only if you put the key in its environment: the key then leaves your computers."
else
  echo "On the phone: through the Claude app (ask Claude when you leave the first reminder), or through ntfy,"
  echo "a free app that receives what this computer sends to a topic."
fi
current=$(jq -r '.ntfy // empty' "$conf" 2> /dev/null || true)
[ -n "$current" ] && echo "  ntfy is set: $current"
if ask reminders.ntfy "Send reminders to your phone through ntfy?"; then
  topic=${current:-https://ntfy.sh/claude-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')}
  topic=$(reply reminders.topic "Topic (anyone who knows it can read it, so keep it hard to guess):" "$topic")
  case "$topic" in http*) ;; *) topic="https://ntfy.sh/$topic" ;; esac
  [ -f "$conf" ] || echo '{}' > "$conf"
  jq --indent 2 --arg u "$topic" '.ntfy = $u' "$conf" > "$conf.tmp" && mv "$conf.tmp" "$conf"
  echo "  Install the ntfy app on your phone and subscribe to ${topic##*/} (server ${topic%/*})."
  default=n
  [ "$encrypted" = encrypted ] || [ "$(jq -r '.ntfy_detail // empty' "$conf")" = count ] && default=y
  if ask reminders.count "Send the phone only how many reminders are due, not their titles (the ntfy server sees what it carries)?" "$default"; then
    jq --indent 2 '.ntfy_detail = "count"' "$conf" > "$conf.tmp" && mv "$conf.tmp" "$conf"
  else
    jq --indent 2 'del(.ntfy_detail)' "$conf" > "$conf.tmp" && mv "$conf.tmp" "$conf"
  fi
fi
kit_setup_mark reminders done
