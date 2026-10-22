#!/bin/bash
# Checks skills/reminders/reminders.sh in a throwaway folder: one-off and repeating reminders,
# done, stop, delete and the JSON the reminders pane reads. bash tests/reminders.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" CLAUDE_REMINDERS_DIR="$T/reminders"
mkdir -p "$HOME/.claude" "$CLAUDE_REMINDERS_DIR"
R() { bash "$KIT/skills/reminders/reminders.sh" "$@"; }
fails=0

check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

plus() {
  date -d "$1 days" +%Y-%m-%d 2> /dev/null && return
  case "$1" in -*) date -v"$1"d +%Y-%m-%d ;; *) date -v+"$1"d +%Y-%m-%d ;; esac
}
day_name() { date -d "+$1 days" +%A 2> /dev/null || date -v+"$1"d +%A; }

reminder() {
  local id=$1
  shift
  { echo ---; printf '%s\n' "$@"; echo ---; echo; echo "About $id."; } > "$CLAUDE_REMINDERS_DIR/$id.md"
}

state_of() { R list | awk -F'\t' -v i="$1" '$1 == i { print $2 }'; }

today=$(date +%Y-%m-%d)
reminder now-one "title: today" "on: $today"
reminder later-one "title: later" "on: $(plus 3)"
reminder old-one "title: old" "on: $(plus -5)" "until: $(plus -1)"
reminder every-today "title: each $(day_name 0)" "every: $(day_name 0 | tr 'A-Z' 'a-z')" "on: $(plus -14) 00:00"
reminder every-other "title: each $(day_name 2)" "every: $(day_name 2)" "group: Work"
reminder every-later-today "title: later today" "every: day" "on: $today 23:59"

check "a one-off reminder of today is due" '[ "$(state_of now-one)" = due ]'
check "a future one is later" '[ "$(state_of later-one)" = later ]'
check "one past its until is expired" '[ "$(state_of old-one)" = expired ]'
check "a repeating one on the weekday of today is due" '[ "$(state_of every-today)" = due ]'
check "a repeating one on another day is later" '[ "$(state_of every-other)" = later ]'
check "with no time of day it shows at 09:00" 'R list | grep -q "every-other.*next $(plus 2) 09:00"'
check "a repeating one before its time of day is later" '[ "$(state_of every-later-today)" = later ]'

R done every-today > /dev/null
check "done on a repeating one closes today only" '[ "$(state_of every-today)" = later ]'
check "and it shows again in a week" 'R list | grep -q "every-today.*next $(plus 7) 00:00"'

R done now-one > /dev/null
check "done on a one-off moves it to the past" '[ -f "$CLAUDE_REMINDERS_DIR/past/now-one.md" ] && [ -z "$(state_of now-one)" ]'
R stop every-other > /dev/null
check "stop ends a repeating one" '[ -f "$CLAUDE_REMINDERS_DIR/past/every-other.md" ]'
check "a closed one records when" 'grep -q "^closed: $today" "$CLAUDE_REMINDERS_DIR/past/every-other.md"'

json=$(R json)
check "json lists the current ones" '[ "$(jq -r ".[] | select(.id == \"later-one\") | .state" <<< "$json")" = later ]'
check "json lists the past ones" '[ "$(jq -r ".[] | select(.id == \"now-one\") | .state" <<< "$json")" = past ]'
check "json carries the group" '[ "$(jq -r ".[] | select(.id == \"every-other\") | .group" <<< "$json")" = Work ]'
check "json carries the body and the next time" 'jq -e ".[] | select(.id == \"every-today\") | .body and .next" <<< "$json" > /dev/null'

R restore every-other > /dev/null
check "restore puts a stopped one back, repeating as before" '[ "$(state_of every-other)" = later ] && R list | grep -q "every-other.*every"'
check "without its closed line" '! grep -q "^closed:" "$CLAUDE_REMINDERS_DIR/every-other.md"'
check "restore refuses a reminder that is not past" '! R restore later-one 2> /dev/null'

R delete now-one > /dev/null
check "delete removes a past one" '[ ! -f "$CLAUDE_REMINDERS_DIR/past/now-one.md" ]'
check "an unknown id is refused" '! R done nope 2> /dev/null'

TASKS="$T/assistant/tasks"
mkdir -p "$TASKS/past"
printf '[{"name": "Max", "dir": "assistant/tasks/"}, {"name": "Up", "dir": "../outside"}]\n' > "$CLAUDE_REMINDERS_DIR/agents.json"
{ echo ---; echo "title: water the plants"; echo "on: $(plus 1) 18:00"; echo ---; echo; echo "Remind me."; } > "$TASKS/plants.md"
{ echo ---; echo "title: ran"; echo "on: $today"; echo "closed: $today 09:00"; echo ---; } > "$TASKS/past/ran.md"
json=$(R json)
check "an assistant's task shows under its name" '[ "$(jq -r ".[] | select(.id == \"assistant/tasks/plants\") | .group + \"/\" + .agent + \"/\" + .state" <<< "$json")" = "Max/Max/later" ]'
check "one it ran is past" '[ "$(jq -r ".[] | select(.id == \"assistant/tasks/ran\") | .state" <<< "$json")" = past ]'
check "agents names each assistant's folder, never one going up" '[ "$(R agents)" = "$(printf "Max\t%s" "$T/assistant/tasks")" ]'
check "its tasks are not shown to coding sessions" '! R due | grep -q plants'
R done assistant/tasks/plants > /dev/null
check "done cancels an assistant's task into its own past" '[ -f "$TASKS/past/plants.md" ] && grep -q "^closed:" "$TASKS/past/plants.md"'
R restore assistant/tasks/plants > /dev/null
check "and restore puts it back" '[ -f "$TASKS/plants.md" ]'
check "an id outside the listed folders is refused" '! R done ../outside/x 2> /dev/null && ! R delete assistant/x/../../y 2> /dev/null'

echo "$fails failure(s)"
[ "$fails" -eq 0 ]
