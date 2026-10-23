#!/bin/bash
# Checks hooks/lib/ask.sh in a throwaway home: answers are recorded (never a secret), and a computer
# set up like another one reuses its answers, asks its own questions, and fills in the other's answers
# as defaults. bash tests/kit-answers.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME/.claude" "$HOME/.claude-sync/inventory"
. "$KIT/hooks/lib/jq.sh"
. "$KIT/hooks/lib/ask.sh"
fails=0

check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

# No terminal: every question takes its default.
kit_tty() { return 1; }
recorded() { grep -qx "$1" "$KIT_ANSWERS_FILE"; }

check "without a terminal the default is the answer" '[ "$(reply language "Language?" English)" = English ]'
check "and it is recorded" 'recorded language=English'
reply daily-sync.time "Time?" 08:30 > /dev/null
reply language "Language?" Français > /dev/null
check "a new answer replaces the old one" 'recorded language=Français && [ "$(grep -c ^language= "$KIT_ANSWERS_FILE")" = 1 ] && recorded daily-sync.time=08:30'
reply reminders.topic "Topic?" secret-topic > /dev/null
check "a secret is never recorded" '! grep -q secret-topic "$KIT_ANSWERS_FILE"'

echo pc > "$HOME/.claude-sync/.machine"
jq -n '{machine: "mac", answers: {language: "English", marker: "🌊", "git-identity.match2": "", "reminders.topic": "leaked",
  "recent-activity.dev": "~/code", "config-sync.dev": "~/mac-dev"}}' > "$HOME/.claude-sync/inventory/mac.json"
jq -n '{machine: "pc", answers: {language: "Deutsch"}}' > "$HOME/.claude-sync/inventory/pc.json"
check "the other computers with answers are offered, never this one" '[ "$(kit_reuse_candidates)" = mac ]'

printf 'mode=same\nfrom=mac\n' > "$KIT_REUSE_FILE"
check "the same as mac: its answer, without asking" '[ "$(reply language "Language?" Français 2> /dev/null)" = English ]'
check "says where the answer comes from" '[[ "$(reply marker "Emoji?" 2>&1 > /dev/null)" == *"(as on mac)"* ]]'
check "a blank answer is reused as blank" '[ -z "$(reply git-identity.match2 "Host?" github.com 2> /dev/null)" ]'
check "a question mac had no answer for is asked as usual" '[ "$(reply daily-sync.time "Time?" 09:00 2> /dev/null)" = 09:00 ]'
check "a secret is never taken from another computer" '[ "$(reply reminders.topic "Topic?" mine 2> /dev/null)" = mine ]'
check "nor the settings of the sync itself" '[ "$(reply config-sync.dev "Folder?" "~/dev" 2> /dev/null)" = "~/dev" ]'
check "the questions about this computer are asked, with the answer of mac as the default" '[ "$(reply recent-activity.dev "Folder?" "~/dev" 2> /dev/null)" = "~/code" ] && [[ "$(reply recent-activity.dev "Folder?" 2>&1 > /dev/null)" != *"as on mac"* ]]'

printf 'mode=start\nfrom=mac\n' > "$KIT_REUSE_FILE"
check "starting from mac: its answer is the default" '[ "$(reply language "Language?" Français 2> /dev/null)" = English ] && [[ "$(reply language "Language?" 2>&1 > /dev/null)" != *"as on mac"* ]]'
check "and a yes/no question takes it too" 'printf "mode=start\nfrom=mac\n" > "$KIT_REUSE_FILE" && jq ".answers.zshrc = \"n\"" "$HOME/.claude-sync/inventory/mac.json" > "$T/m" && mv "$T/m" "$HOME/.claude-sync/inventory/mac.json" && ! ask zshrc "Source it?" y 2> /dev/null'

printf 'mode=none\nfrom=\n' > "$KIT_REUSE_FILE"
check "from scratch: the kit's own default" '[ "$(reply language "Language?" Français 2> /dev/null)" = Français ]'

echo "$fails failure(s)"
[ "$fails" -eq 0 ]
