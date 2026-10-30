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
reminder every-3-days "title: every 3 days" "every: 3 days" "on: $(plus -1)"
reminder every-month "title: each month" "every: month" "on: $(plus -1)"
reminder twice-a-day "title: twice a day" "every: day" "times: 00:00, 23:59" "on: $(plus -3)"

check "a one-off reminder of today is due" '[ "$(state_of now-one)" = due ]'
check "a future one is later" '[ "$(state_of later-one)" = later ]'
check "one past its until is expired" '[ "$(state_of old-one)" = expired ]'
check "a repeating one on the weekday of today is due" '[ "$(state_of every-today)" = due ]'
check "a repeating one on another day is later" '[ "$(state_of every-other)" = later ]'
check "with no time of day it shows at 09:00" 'R list | grep -q "every-other.*next $(plus 2) 09:00"'
check "a repeating one before its time of day is later" '[ "$(state_of every-later-today)" = later ]'
check "every 3 days counts from its start" 'R list | grep -q "every-3-days.*next $(plus 2) 09:00"'
check "every month comes back a month later" '[[ "$(R list | awk -F"\t" "\$1 == \"every-month\"" | grep -o "next [0-9-]*" | cut -c6-)" > "$(plus 27)" ]]'
check "with times it shows the next of them today" 'R list | grep -q "twice-a-day.*next $today 23:59"'

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

# An assistant's tasks are the handoff skill's (tests/handoff.sh): reminders only names the
# assistants, for the one that can deliver the reminders.
TASKS="$T/assistant/tasks"
mkdir -p "$TASKS"
printf '[{"name": "Max", "dir": "assistant/tasks/"}, {"name": "Up", "dir": "../outside"}]\n' > "$CLAUDE_REMINDERS_DIR/agents.json"
{ echo ---; echo "title: water the plants"; echo "on: $today"; echo ---; } > "$TASKS/plants.md"
check "agents names each assistant's folder, never one going up" '[ "$(R agents)" = "$(printf "Max\t%s" "$T/assistant/tasks")" ]'
check "the json leaves the assistants' tasks out" '! R json | jq -e ".[] | select(.agent != null)" > /dev/null'
check "an id with a folder is refused" '! R done assistant/tasks/plants 2> /dev/null && [ -f "$TASKS/plants.md" ]'

echo "$fails failure(s)"
[ "$fails" -eq 0 ]
