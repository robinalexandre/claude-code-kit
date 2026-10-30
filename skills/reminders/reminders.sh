#!/bin/bash
# Reminders the user leaves for a later session, one Markdown file each, kept in
# the config sync repo so every computer sees them.
#   reminders.sh start           SessionStart hook: shows the due reminders, syncs in the background
#   reminders.sh prompt          UserPromptSubmit hook: hands over what that sync brought
#   reminders.sh morning         after the morning sync: notifies the due reminders
#   reminders.sh due [DIR]       due reminders for a session in DIR (default: all of them)
#   reminders.sh list            every reminder, with its state
#   reminders.sh json [DIR]      every reminder, the past ones too, as JSON (the reminders pane)
#   reminders.sh done ID         closes a reminder; a repeating one only for today
#   reminders.sh stop ID         closes a reminder, a repeating one for good
#   reminders.sh delete ID       deletes a reminder, a past one too
#   reminders.sh restore ID      puts a past reminder back, with its dates and repeat days
#   reminders.sh notify [TEXT]   sends TEXT to the desktop and the phone (to test)
#   reminders.sh agents          the user's assistants and their folders (one can deliver the reminders)
#   reminders.sh encrypted       "encrypted" when the sync repo encrypts the reminders (git-crypt), else "clear"
# A repeating reminder has `every: friday` (days in English, comma-separated, or `day` or
# `weekday`) and shows on those days from `on` until `until`, at the time of day `on` gives, else
# at REMINDERS_AT (09:00, when the morning sync notifies). Closing one moves it to past/ with a
# `closed:` line, where it stays PAST_DAYS days.
# A reminder is for the user to remember; a task an assistant runs by itself is the handoff
# skill's.
set -u
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SYNC="$HOME/.claude-sync"
DIR=${CLAUDE_REMINDERS_DIR:-$SYNC/reminders}
ROOT=$(dirname "$DIR")
PAST="$DIR/past"
PAST_DAYS=60
DEFAULT_AT=${REMINDERS_AT:-09:00}
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

MACHINE=""
[ -f "$SYNC/.machine" ] && read -r MACHINE < "$SYNC/.machine"
MACHINE=${MACHINE//[[:space:]]/}
NOW=$(date '+%Y-%m-%d %H:%M')

# The dates, repeats and states, shared with the handoff skill (an assistant's tasks).
. "$SK/../../hooks/lib/schedule.sh" || {
  echo "reminders: hooks/lib/schedule.sh is missing next to the skill; install the kit's reminders part again" >&2
  exit 1
}

files() { for f in "$DIR"/*.md; do [ -f "$f" ] && printf '%s\n' "$f"; done; }

# agents: "name<TAB>folder" for each assistant (one can deliver the reminders: see Notifications in
# SKILL.md); their tasks are the handoff skill's.
agents() { agents_in "$ROOT/handoffs/agents.json" "$DIR/agents.json"; }

# file_of ID: the file of a reminder.
file_of() {
  case "$1" in */* | *..*) return 1 ;; esac
  printf '%s/%s.md' "$DIR" "$1"
}

past_of() {
  local f
  f=$(file_of "$1") || return 1
  printf '%s/past/%s' "$(dirname "$f")" "$(basename "$f")"
}

due() {
  local f
  files | while IFS= read -r f; do
    state_of "$f" "${1:-}"
    [ "$S" = due ] && printf '%s\n' "$f"
  done
}

list() {
  local f id
  files | while IFS= read -r f; do
    state_of "$f"
    id=${f##*/}
    printf '%s\t%s\t%s%s\n' "${id%.md}" "$S" "$F_title" "${F_every:+ (every $F_every, next $NEXT)}"
  done
}

# json [DIR]: every reminder as a JSON array (the reminders pane), its objects' empty fields left
# out. One awk and one jq run in all: the pane gives it 30 s.
json() {
  local f
  local -a open=() past=()
  for f in "$DIR"/*.md; do [ -f "$f" ] && open+=("$f"); done
  for f in "$PAST"/*.md; do [ -f "$f" ] && past+=("$f"); done
  {
    records open "" "" ${open[@]+"${open[@]}"}
    records past "" "" ${past[@]+"${past[@]}"}
  } | items_json "${1:-}"
}

# set_field FILE KEY VALUE: sets KEY in FILE's front matter, added before its end if missing.
set_field() {
  F_FILE=""
  awk -v k="$2" -v v="$3" '{ sub(/\r$/, "") }
    NR == 1 { print; next }
    !end && $0 == "---" { if (!set) print k ": " v; end = 1; print; next }
    !end && index($0, k ":") == 1 { print k ": " v; set = 1; next }
    { print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# close ID: moves the reminder to past/, with when it was closed.
close() {
  local f p
  f=$(file_of "$1")
  p=$(past_of "$1")
  mkdir -p "$(dirname "$p")"
  set_field "$f" closed "$(date '+%Y-%m-%d %H:%M')"
  mv "$f" "$p"
}

drop_field() {
  F_FILE=""
  awk -v k="$2" '{ sub(/\r$/, "") } NR == 1 { print; next } !end && $0 == "---" { end = 1 } !end && index($0, k ":") == 1 { next } { print }' \
    "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

restore() {
  local p
  p=$(past_of "${1:-}") && [ -n "${1:-}" ] && [ -f "$p" ] || {
    echo "no past reminder ${1:-}" >&2
    exit 1
  }
  drop_field "$p" closed
  mv "$p" "$(file_of "$1")"
  echo "restored: $1 ($(state "$(file_of "$1")"))"
}

reminder_file() {
  [ -n "${1:-}" ] && [ -f "$(file_of "$1")" ] || {
    echo "no reminder ${1:-}; see: reminders.sh list" >&2
    exit 1
  }
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

# notify TITLE TEXT [PHONE_TEXT]: PHONE_TEXT, when given, goes to the phone instead of TEXT.
notify() {
  desktop "$1" "$2"
  phone "$1" "${3:-$2}"
}

# phone_text N: with "ntfy_detail": "count" in reminders.json, the phone gets only how many
# reminders are due: what goes to an ntfy server travels and stays there in clear.
phone_text() {
  [ "$(conf ntfy_detail)" = count ] || return 0
  if [ "$1" -gt 1 ]; then printf '%d reminders due' "$1"; else printf '1 reminder due'; fi
}

# encrypted: whether the sync repo encrypts the reminders folder (sync.sh crypt). Then only
# what holds the key can read them: a cloud routine reading the repo from GitHub cannot.
encrypted() {
  git -C "$ROOT" check-attr filter -- "$(basename "$DIR")/x.md" 2> /dev/null | grep -q ': git-crypt$'
}

# summary FILE...: "title" for one reminder, "title (+N more)" for several.
summary() {
  fields "$1"
  if [ $# -gt 1 ]; then printf '%s (+%d)' "$F_title" $(($# - 1)); else printf '%s' "$F_title"; fi
}

# Hook input: sets SID (the session) and CWD.
read_input() {
  local input=""
  SID="" CWD=""
  [ -t 0 ] || input=$(cat)
  { IFS= read -r SID; IFS= read -r CWD; } < <(printf '%s' "$input" | jq -r '.session_id // "", .cwd // ""' 2> /dev/null)
  SID=${SID//[^A-Za-z0-9_-]/}
  SID=${SID:-default}
  CWD=${CWD:-$PWD}
}

# unseen SID DIR: the due reminders for DIR that session SID hasn't been given yet.
unseen() {
  local f id shown=$'\n' line
  if [ -f "$STATE/shown-$1" ]; then
    while IFS= read -r line; do shown="$shown$line"$'\n'; done < "$STATE/shown-$1"
  fi
  due "$2" | while IFS= read -r f; do
    id=${f##*/}
    [[ "$shown" == *$'\n'"${id%.md}"$'\n'* ]] || printf '%s\n' "$f"
  done
}

# show EVENT SID FILE...: hands these reminders to the session as hook output.
show() {
  local context="" shown="" f id event=$1 sid=$2
  shift 2
  [ $# -gt 0 ] || return 0
  for f in "$@"; do
    id=${f##*/}
    id=${id%.md}
    fields "$f"
    echo "$id" >> "$STATE/shown-$sid"
    shown="$shown 🔔 $F_title"
    context="$context

### $id: $F_title${F_every:+ (every $F_every)}${F_until:+ (until $F_until)}
$(body "$f")"
  done
  jq -n --arg ctx "$context" --arg shown "${shown# }" --arg sk "$SK" --arg ev "$event" '{
    systemMessage: $shown,
    hookSpecificOutput: {hookEventName: $ev, additionalContext: (
      "Reminders the user left for this session (reminders skill). In your next reply, before anything else, remind the user of each one in their own language, with what it involves, and offer to help with it. When the user says one is done, run: bash \"\($sk)/reminders.sh\" done <id> (a repeating one is then closed for today only); when they no longer want a repeating one: reminders.sh stop <id>" + $ctx)}}'
}

# The session starts at once with what is already here. The day's sync runs in
# the background; whatever it brings is notified as soon as it lands, and handed
# to the session with the user's next message (prompt).
# The old state and past reminders are cleaned once a day: each find is another process.
start() {
  local today=${NOW% *} f last=""
  read_input
  mkdir -p "$STATE"
  [ -f "$STATE/cleaned" ] && read -r last < "$STATE/cleaned"
  if [ "$last" != "$today" ]; then
    find "$STATE" -maxdepth 1 \( -name 'shown-*' -o -name 'pending-*' \) -mtime +2 -exec rm -f {} + 2> /dev/null
    [ -d "$PAST" ] && find "$PAST" -maxdepth 1 -name '*.md' -mtime +"$PAST_DAYS" -exec rm -f {} + 2> /dev/null
    echo "$today" > "$STATE/cleaned"
  fi
  (nohup bash "$SK/reminders.sh" after-sync "$SID" "$CWD" > /dev/null 2>&1 < /dev/null &)
  set --
  while IFS= read -r f; do set -- "$@" "$f"; done < <(unseen "$SID" "$CWD")
  [ $# -gt 0 ] || return 0
  last=""
  [ -f "$STATE/session-notified" ] && read -r last < "$STATE/session-notified"
  if [ "$last" != "$today" ]; then
    # In the background: PowerShell's toast alone takes seconds on Windows.
    (notify "Reminder" "$(summary "$@")" "$(phone_text $#)" > /dev/null 2>&1 < /dev/null &)
    echo "$today" > "$STATE/session-notified"
  fi
  show SessionStart "$SID" "$@"
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
  NOW=$(date '+%Y-%m-%d %H:%M')
  set --
  while IFS= read -r f; do set -- "$@" "$f"; done < <(unseen "$sid" "$cwd")
  [ $# -gt 0 ] || return 0
  touch "$STATE/pending-$sid"
  notify "Reminder" "$(summary "$@")" "$(phone_text $#)"
  date +%Y-%m-%d > "$STATE/session-notified"
}

prompt() {
  local f
  read_input
  [ -f "$STATE/pending-$SID" ] || return 0
  rm -f "$STATE/pending-$SID"
  set --
  while IFS= read -r f; do set -- "$@" "$f"; done < <(unseen "$SID" "$CWD")
  show UserPromptSubmit "$SID" "$@"
}

morning() {
  local f
  set --
  while IFS= read -r f; do set -- "$@" "$f"; done < <(due)
  [ $# -gt 0 ] || return 0
  notify "Reminder" "$(summary "$@")" "$(phone_text $#)"
}

done_() {
  reminder_file "${1:-}"
  local f
  f=$(file_of "$1")
  fields "$f"
  if [ -n "$F_every" ]; then
    set_field "$f" done "${NOW% *}"
    echo "done for today: $1 (next: $(next_time "$f"))"
  else
    close "$1"
    echo "done: $1"
  fi
}

stop() {
  reminder_file "${1:-}"
  close "$1"
  echo "stopped: $1"
}

delete() {
  local f
  for f in "$(file_of "${1:-}")" "$(past_of "${1:-}")"; do
    if [ -n "${1:-}" ] && [ -f "$f" ]; then
      rm -f "$f"
      echo "deleted $1"
      return 0
    fi
  done
  echo "no reminder ${1:-}; see: reminders.sh list" >&2
  exit 1
}

case "${1:-}" in
  start) start ;;
  prompt) prompt ;;
  after-sync) after_sync "${2:-default}" "${3:-$PWD}" ;;
  morning) morning ;;
  due) due "${2:-}" ;;
  list) list ;;
  json) json "${2:-}" ;;
  done) done_ "${2:-}" ;;
  stop) stop "${2:-}" ;;
  delete) delete "${2:-}" ;;
  restore) restore "${2:-}" ;;
  notify) notify "${3:-Reminder}" "${2:-Test from the reminders skill}" ;;
  agents) agents | while IFS=$'\t' read -r name dir; do printf '%s\t%s\n' "$name" "$ROOT/$dir"; done ;;
  encrypted) if encrypted; then echo encrypted; else echo clear; fi ;;
  *)
    echo "usage: reminders.sh start|prompt|morning|due [DIR]|list|json [DIR]|done ID|stop ID|delete ID|restore ID|notify [TEXT [TITLE]]|agents|encrypted" >&2
    exit 2
    ;;
esac
exit 0
