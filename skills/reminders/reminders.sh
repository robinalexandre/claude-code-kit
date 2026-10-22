#!/bin/bash
# Reminders the user leaves for a later session, one Markdown file each, kept in
# the config sync repo so every computer sees them.
#   reminders.sh start           SessionStart hook: shows the due reminders, syncs in the background
#   reminders.sh prompt          UserPromptSubmit hook: hands over what that sync brought
#   reminders.sh morning         after the morning sync: notifies the due reminders
#   reminders.sh due [DIR]       due reminders for a session in DIR (default: all of them)
#   reminders.sh list            every reminder, with its state
#   reminders.sh done ID         deletes a reminder
#   reminders.sh notify [TEXT]   sends TEXT to the desktop and the phone (to test)
set -u
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SYNC="$HOME/.claude-sync"
DIR=${CLAUDE_REMINDERS_DIR:-$SYNC/reminders}
STATE="$HOME/.claude/.reminders-state"
CONF="$HOME/.claude/reminders.json"

if [ -f "$SK/../../hooks/lib/jq.sh" ]; then
  . "$SK/../../hooks/lib/jq.sh"
elif command -v cygpath > /dev/null 2>&1; then
  jq() { command jq -b "$@"; }
fi

# frontmatter FILE KEY: prints KEY's value from FILE's YAML front matter.
frontmatter() {
  awk -v k="$2" '{ sub(/\r$/, "") }
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    NR > 1 { i = index($0, ":"); if (substr($0, 1, i - 1) == k) { v = substr($0, i + 1); sub(/^ +/, "", v); sub(/ +$/, "", v); print v; exit } }' "$1"
}

body() { awk '{ sub(/\r$/, "") } NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm' "$1"; }

lower() { tr 'A-Z\\' 'a-z/'; }

# in_place DIR WHERE: whether DIR is the folder WHERE (a path or its tail, e.g.
# "dev/shop"), or inside it.
in_place() {
  local d w
  d="$(printf '%s/' "$1" | lower)"
  w=$(printf '%s' "${2#\~/}" | lower)
  w=${w%/}
  case "$d" in *"/$w/"*) return 0 ;; esac
  return 1
}

machine() { tr -d '[:space:]' < "$SYNC/.machine" 2> /dev/null; }

# state FILE [DIR]: due, later or expired; "elsewhere" when the reminder is
# for another folder or computer than a session in DIR.
state() {
  local f=$1 cwd=${2:-} on until where for now today
  now=$(date '+%Y-%m-%d %H:%M')
  today=${now% *}
  on=$(frontmatter "$f" on)
  until=$(frontmatter "$f" until)
  where=$(frontmatter "$f" where)
  for=$(frontmatter "$f" machine)
  [ ${#on} -eq 10 ] && on="$on 00:00"
  if [ -n "$until" ] && [[ "$until" < "$today" ]]; then
    echo expired
  elif [ -n "$on" ] && [[ "$now" < "$on" ]]; then
    echo later
  elif [ -n "$for" ] && [ "$for" != "$(machine)" ]; then
    echo elsewhere
  elif [ -n "$cwd" ] && [ -n "$where" ] && ! in_place "$cwd" "$where"; then
    echo elsewhere
  else
    echo due
  fi
}

files() { for f in "$DIR"/*.md; do [ -f "$f" ] && printf '%s\n' "$f"; done; }

due() {
  local f
  files | while IFS= read -r f; do
    [ "$(state "$f" "${1:-}")" = due ] && printf '%s\n' "$f"
  done
}

list() {
  local f
  files | while IFS= read -r f; do
    printf '%s\t%s\t%s\n' "$(basename "$f" .md)" "$(state "$f")" "$(frontmatter "$f" title)"
  done
}

conf() { [ -f "$CONF" ] && jq -r --arg k "$1" '.[$k] // empty' "$CONF" 2> /dev/null; }

desktop() {
  case "$(uname -s)" in
    Darwin)
      osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$1" "$2" > /dev/null 2>&1
      ;;
    MINGW* | MSYS* | CYGWIN*)
      R_TITLE=$1 R_TEXT=$2 powershell.exe -NoProfile -NonInteractive -Command '
        $m = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $x = $m::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $t = $x.GetElementsByTagName("text")
        $t.Item(0).AppendChild($x.CreateTextNode($env:R_TITLE)) > $null
        $t.Item(1).AppendChild($x.CreateTextNode($env:R_TEXT)) > $null
        $m::CreateToastNotifier("{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe").Show([Windows.UI.Notifications.ToastNotification]::new($x))' > /dev/null 2>&1
      ;;
    *)
      command -v notify-send > /dev/null || return 0
      [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
      notify-send "$1" "$2" > /dev/null 2>&1
      ;;
  esac
}

# The phone gets it through ntfy (https://ntfy.sh): the app subscribed to the
# topic in ~/.claude/reminders.json {"ntfy": "https://ntfy.sh/<topic>"}.
phone() {
  local url=${REMINDERS_NTFY:-$(conf ntfy)}
  [ -n "$url" ] || return 0
  jq -n --arg topic "${url##*/}" --arg title "$1" --arg message "$2" \
    '{topic: $topic, title: $title, message: $message, tags: ["bell"]}' |
    curl -fsS -m 10 -H 'Content-Type: application/json' --data-binary @- "${url%/*}" > /dev/null 2>&1
}

notify() {
  desktop "$1" "$2"
  phone "$1" "$2"
}

# summary FILE...: "title" for one reminder, "title (+N more)" for several.
summary() {
  local first
  first=$(frontmatter "$1" title)
  if [ $# -gt 1 ]; then printf '%s (+%d)' "$first" $(($# - 1)); else printf '%s' "$first"; fi
}

# Hook input: sets SID (the session) and CWD.
read_input() {
  local input=""
  [ -t 0 ] || input=$(cat)
  SID=$(printf '%s' "$input" | jq -r '.session_id // empty' 2> /dev/null | tr -cd 'A-Za-z0-9_-')
  SID=${SID:-default}
  CWD=$(printf '%s' "$input" | jq -r '.cwd // empty' 2> /dev/null)
  CWD=${CWD:-$PWD}
}

# unseen SID DIR: the due reminders for DIR that session SID hasn't been given yet.
unseen() {
  local f
  due "$2" | while IFS= read -r f; do
    grep -qxF "$(basename "$f" .md)" "$STATE/shown-$1" 2> /dev/null || printf '%s\n' "$f"
  done
}

# show EVENT SID DIR: hands the unseen reminders to the session as hook output.
show() {
  local context="" shown="" f id
  set -- "$1" "$2" "$3"
  while IFS= read -r f; do set -- "$@" "$f"; done < <(unseen "$2" "$3")
  [ $# -gt 3 ] || return 0
  local event=$1 sid=$2
  shift 3
  for f in "$@"; do
    id=$(basename "$f" .md)
    echo "$id" >> "$STATE/shown-$sid"
    shown="$shown 🔔 $(frontmatter "$f" title)"
    context="$context

### $id: $(frontmatter "$f" title)$([ -n "$(frontmatter "$f" until)" ] && printf ' (until %s)' "$(frontmatter "$f" until)")
$(body "$f")"
  done
  jq -n --arg ctx "$context" --arg shown "${shown# }" --arg sk "$SK" --arg ev "$event" '{
    systemMessage: $shown,
    hookSpecificOutput: {hookEventName: $ev, additionalContext: (
      "Reminders the user left for this session (reminders skill). In your next reply, before anything else, remind the user of each one in their own language, with what it involves, and offer to help with it. When the user says one is done or no longer needed, run: bash \"\($sk)/reminders.sh\" done <id>" + $ctx)}}'
}

# The session starts at once with what is already here. The day's sync runs in
# the background; whatever it brings is notified as soon as it lands, and handed
# to the session with the user's next message (prompt).
start() {
  local today f
  read_input
  mkdir -p "$STATE"
  find "$STATE" -maxdepth 1 \( -name 'shown-*' -o -name 'pending-*' \) -mtime +2 -exec rm -f {} + 2> /dev/null
  (nohup bash "$SK/reminders.sh" after-sync "$SID" "$CWD" > /dev/null 2>&1 < /dev/null &)
  set --
  while IFS= read -r f; do set -- "$@" "$f"; done < <(unseen "$SID" "$CWD")
  [ $# -gt 0 ] || return 0
  today=$(date +%Y-%m-%d)
  if [ "$(cat "$STATE/session-notified" 2> /dev/null)" != "$today" ]; then
    notify "Reminder" "$(summary "$@")"
    echo "$today" > "$STATE/session-notified"
  fi
  show SessionStart "$SID" "$CWD"
}

# Waits for the sync the session start launched (or runs today's first one).
after_sync() {
  local sid=$1 cwd=$2 n=0 f
  [ -f "$SYNC/sync.sh" ] || return 0
  sleep 2
  while [ -d "$SYNC/.state/lock" ] && [ $n -lt 90 ]; do
    sleep 1
    n=$((n + 1))
  done
  bash "$SYNC/sync.sh" fresh 60 > /dev/null 2>&1 < /dev/null
  set --
  while IFS= read -r f; do set -- "$@" "$f"; done < <(unseen "$sid" "$cwd")
  [ $# -gt 0 ] || return 0
  touch "$STATE/pending-$sid"
  notify "Reminder" "$(summary "$@")"
  date +%Y-%m-%d > "$STATE/session-notified"
}

prompt() {
  read_input
  [ -f "$STATE/pending-$SID" ] || return 0
  rm -f "$STATE/pending-$SID"
  show UserPromptSubmit "$SID" "$CWD"
}

morning() {
  local f
  set --
  while IFS= read -r f; do set -- "$@" "$f"; done < <(due)
  [ $# -gt 0 ] || return 0
  notify "Reminder" "$(summary "$@")"
}

done_() {
  local f="$DIR/${1:-}.md"
  [ -n "${1:-}" ] && [ -f "$f" ] || {
    echo "no reminder ${1:-}; see: reminders.sh list" >&2
    exit 1
  }
  rm -f "$f"
  echo "deleted $1"
}

case "${1:-}" in
  start) start ;;
  prompt) prompt ;;
  after-sync) after_sync "${2:-default}" "${3:-$PWD}" ;;
  morning) morning ;;
  due) due "${2:-}" ;;
  list) list ;;
  done) done_ "${2:-}" ;;
  notify) notify "Reminder" "${2:-Test from the reminders skill}" ;;
  *)
    echo "usage: reminders.sh start|prompt|morning|due [DIR]|list|done ID|notify [TEXT]" >&2
    exit 2
    ;;
esac
exit 0
