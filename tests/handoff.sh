#!/bin/bash
# Checks skills/handoff/handoff.sh in a throwaway folder: the JSON the reminders and handoffs pane
# reads, done, cancel and delete. bash tests/handoff.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" CLAUDE_HANDOFFS_DIR="$T/handoffs"
mkdir -p "$HOME/.claude-sync" "$CLAUDE_HANDOFFS_DIR"
echo laptop > "$HOME/.claude-sync/.machine"
H() { bash "$KIT/skills/handoff/handoff.sh" "$@"; }
fails=0

check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

note() {
  printf -- '---\ntitle: %s\nfrom: %s\ndate: 2026-01-02 10:00\nrepo: %s\nbranch: main\n---\n\n## Next steps\nRun it.\n' \
    "$2" "$3" "$4" > "$CLAUDE_HANDOFFS_DIR/$1.md"
}

state_of() { H json | jq -r --arg i "$1" '.[] | select(.id == $i) | .state'; }

note from-desk "Finish the import" desk owner/app
note from-here "Check the logs" laptop none

json=$(H json)
check "json lists the open notes" '[ "$(state_of from-desk)" = open ]'
check "a note from another computer is not mine" '[ "$(jq -r ".[] | select(.id == \"from-desk\") | .isMine" <<< "$json")" = false ]'
check "a note written here is mine" '[ "$(jq -r ".[] | select(.id == \"from-here\") | .isMine" <<< "$json")" = true ]'
check "repo none is left out" '[ "$(jq -r ".[] | select(.id == \"from-here\") | .repo // \"absent\"" <<< "$json")" = absent ]'
check "json carries the body" 'jq -e ".[] | select(.id == \"from-desk\") | .body | test(\"Run it\")" <<< "$json" > /dev/null'

H done from-desk > /dev/null
check "done moves a note to done/" '[ -f "$CLAUDE_HANDOFFS_DIR/done/from-desk.md" ] && [ "$(state_of from-desk)" = done ]'
check "with when it was closed" 'grep -q "^closed: " "$CLAUDE_HANDOFFS_DIR/done/from-desk.md"'
H cancel from-here > /dev/null
check "cancel marks it canceled" '[ "$(state_of from-here)" = canceled ]'
H delete from-desk > /dev/null
check "delete removes a done note" '[ ! -f "$CLAUDE_HANDOFFS_DIR/done/from-desk.md" ]'
check "an unknown note is refused" '! H done nope 2> /dev/null'

echo "$fails failure(s)"
[ "$fails" -eq 0 ]
