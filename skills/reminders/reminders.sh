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
#   reminders.sh agents          the assistants that run tasks by themselves, and their folders
# A repeating reminder has `every: friday` (days in English, comma-separated, or `day` or
# `weekday`) and shows on those days from `on` until `until`, at the time of day `on` gives, else
# at REMINDERS_AT (09:00, when the morning sync notifies). Closing one moves it to past/ with a
# `closed:` line, where it stays PAST_DAYS days.
# Tasks for an assistant that runs them by itself (a personal agent reading the sync repo)
# live in that assistant's own folder, listed in agents.json next to the reminders:
# [{"name": "<assistant>", "dir": "<folder, from the sync repo's root>"}]. They share the
# reminders' format, show in the pane under the assistant's name, and their id is
# "<folder>/<file name>"; the assistant moves each one to past/ once it ran.
set -u
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SYNC="$HOME/.claude-sync"
DIR=${CLAUDE_REMINDERS_DIR:-$SYNC/reminders}
ROOT=$(dirname "$DIR")
AGENTS="$DIR/agents.json"
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

# weekdays EVERY: the ISO weekday numbers (1 = Monday) that EVERY names.
weekdays() {
  local d out=""
  for d in $(printf '%s' "$1" | lower | tr ',' ' '); do
    case "$d" in
      day | daily) out="1 2 3 4 5 6 7" ;;
      weekday | weekdays) out="$out 1 2 3 4 5" ;;
      mon*) out="$out 1" ;;
      tue*) out="$out 2" ;;
      wed*) out="$out 3" ;;
      thu*) out="$out 4" ;;
      fri*) out="$out 5" ;;
      sat*) out="$out 6" ;;
      sun*) out="$out 7" ;;
    esac
  done
  printf '%s' "${out# }"
}

# GNU date first, then BSD date (macOS).
shift_day() { date -d "$1 +$2 days" +%Y-%m-%d 2> /dev/null || date -j -v+"$2"d -f %Y-%m-%d "$1" +%Y-%m-%d; }
weekday_of() { date -d "$1" +%u 2> /dev/null || date -j -f %Y-%m-%d "$1" +%u; }

# next_time FILE: "YYYY-MM-DD HH:MM" a repeating reminder shows next, today's while it isn't closed.
next_time() {
  local f=$1 days on at closed base first k day
  days=$(weekdays "$(frontmatter "$f" every)")
  [ -n "$days" ] || return 0
  on=$(frontmatter "$f" on)
  at=$DEFAULT_AT
  [ ${#on} -gt 10 ] && at=${on:11:5}
  closed=$(frontmatter "$f" done)
  base=$(date +%Y-%m-%d)
  [ -n "$on" ] && [[ "$base" < "${on:0:10}" ]] && base=${on:0:10}
  first=$(weekday_of "$base")
  for k in 0 1 2 3 4 5 6 7; do
    case " $days " in *" $(((first + k - 1) % 7 + 1)) "*) ;; *) continue ;; esac
    day=$base
    [ "$k" -gt 0 ] && day=$(shift_day "$base" "$k")
    [ "$day" = "$closed" ] && continue
    printf '%s %s' "$day" "$at"
    return 0
  done
}

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
  [ -n "$(frontmatter "$f" every)" ] && on=$(next_time "$f")
  if [ -n "$until" ] && { [[ "$until" < "$today" ]] || [[ "$until" < "${on:0:10}" ]]; }; then
    echo expired
  elif [ -n "$(frontmatter "$f" every)" ] && [ -z "$on" ]; then
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

# agents: "name<TAB>folder" for each assistant in agents.json; a folder going up (..) is left out.
agents() {
  [ -f "$AGENTS" ] || return 0
  jq -r '.[] | select((.name // "") != "" and (.dir // "") != "")
    | select(.dir | test("(^|/)\\.\\.(/|$)") | not) | "\(.name)\t\(.dir | sub("/+$"; ""))"' \
    "$AGENTS" 2> /dev/null | tr -d '\r'
}

# file_of ID: the file of a reminder, or of an assistant's task when ID is "<its folder>/<name>".
file_of() {
  case "$1" in
    */*)
      agents | cut -f2 | grep -qxF "${1%/*}" || return 1
      printf '%s/%s.md' "$ROOT" "$1"
      ;;
    *) printf '%s/%s.md' "$DIR" "$1" ;;
  esac
}

past_of() {
  local f
  f=$(file_of "$1") || return 1
  printf '%s/past/%s' "$(dirname "$f")" "$(basename "$f")"
}

due() {
  local f
  files | while IFS= read -r f; do
    [ "$(state "$f" "${1:-}")" = due ] && printf '%s\n' "$f"
  done
}

list() {
  local f every
  files | while IFS= read -r f; do
    every=$(frontmatter "$f" every)
    printf '%s\t%s\t%s%s\n' "$(basename "$f" .md)" "$(state "$f")" "$(frontmatter "$f" title)" \
      "${every:+ (every $every, next $(next_time "$f"))}"
  done
}

# one FILE STATE: a reminder as one JSON object, its empty fields left out.
one() {
  local f=$1
  jq -n --arg id "$(basename "$f" .md)" --arg state "$2" --arg title "$(frontmatter "$f" title)" \
    --arg on "$(frontmatter "$f" on)" --arg until "$(frontmatter "$f" until)" --arg every "$(frontmatter "$f" every)" \
    --arg where "$(frontmatter "$f" where)" --arg machine "$(frontmatter "$f" machine)" \
    --arg group "$(frontmatter "$f" group)" --arg done "$(frontmatter "$f" done)" \
    --arg closed "$(frontmatter "$f" closed)" --arg next "$(next_time "$f")" --arg body "$(body "$f")" \
    '{$id, $state, $title, $on, $until, $every, $where, $machine, $group, $done, $closed, $next, $body}
     | with_entries(select(.value != ""))'
}

json() {
  local f name dir
  {
    files | while IFS= read -r f; do one "$f" "$(state "$f" "${1:-}")"; done
    for f in "$PAST"/*.md; do [ -f "$f" ] && one "$f" past; done
    agents | while IFS=$'\t' read -r name dir; do
      for f in "$ROOT/$dir"/*.md "$ROOT/$dir/past"/*.md; do
        [ -f "$f" ] || continue
        case "$f" in */past/*) set -- past ;; *) set -- "$(state "$f")" ;; esac
        one "$f" "$1" | jq --arg id "$dir/$(basename "$f" .md)" --arg agent "$name" \
          '.id = $id | .agent = $agent | .group = $agent'
      done
    done
  } | jq -s .
}

# set_field FILE KEY VALUE: sets KEY in FILE's front matter, added before its end if missing.
set_field() {
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

### $id: $(frontmatter "$f" title)$([ -n "$(frontmatter "$f" every)" ] && printf ' (every %s)' "$(frontmatter "$f" every)")$([ -n "$(frontmatter "$f" until)" ] && printf ' (until %s)' "$(frontmatter "$f" until)")
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
start() {
  local today f
  read_input
  mkdir -p "$STATE"
  find "$STATE" -maxdepth 1 \( -name 'shown-*' -o -name 'pending-*' \) -mtime +2 -exec rm -f {} + 2> /dev/null
  { printf '%s\n' "$PAST"; agents | cut -f2 | while IFS= read -r p; do printf '%s/%s/past\n' "$ROOT" "$p"; done; } |
    while IFS= read -r p; do
      [ -d "$p" ] && find "$p" -maxdepth 1 -name '*.md' -mtime +"$PAST_DAYS" -exec rm -f {} + 2> /dev/null
    done
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
  reminder_file "${1:-}"
  local f
  f=$(file_of "$1")
  if [ -n "$(frontmatter "$f" every)" ]; then
    set_field "$f" done "$(date +%Y-%m-%d)"
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
  notify) notify "Reminder" "${2:-Test from the reminders skill}" ;;
  agents) agents | while IFS=$'\t' read -r name dir; do printf '%s\t%s\n' "$name" "$ROOT/$dir"; done ;;
  *)
    echo "usage: reminders.sh start|prompt|morning|due [DIR]|list|json [DIR]|done ID|stop ID|delete ID|restore ID|notify [TEXT]|agents" >&2
    exit 2
    ;;
esac
exit 0
