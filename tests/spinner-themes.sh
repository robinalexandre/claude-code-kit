#!/bin/bash
# Tests skills/spinner-themes/spinner-themes.sh against throwaway settings files.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=${SPINNER_SCRIPT:-$ROOT/skills/spinner-themes/spinner-themes.sh}
. "$ROOT/hooks/lib/jq.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DIR="$TMP/a folder"
mkdir -p "$DIR"
export SPINNER_SETTINGS="$DIR/settings.json" SPINNER_THEMES_DIR="$DIR/own"
fails=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$3], got [$2]"; fails=$((fails + 1)); fi
}
run() { bash "$SCRIPT" "$@" > /dev/null 2>&1; echo $?; }
field() { jq -r "$1" < "$SPINNER_SETTINGS" | tr -d '\r'; }

check "every built-in theme has 15+ entries, no duplicate" \
  "$(for f in "$ROOT"/skills/spinner-themes/themes/*.txt; do
       n=$(grep -c . "$f"); u=$(sort -u "$f" | grep -c .)
       [ "$n" -ge 15 ] && [ "$n" = "$u" ] || basename "$f"
     done)" ""

check "set with no settings file creates it" "$(run set surf)" 0
check "replace is the default mode" "$(field .spinnerVerbs.mode)" replace
check "words come from the theme" "$(field '.spinnerVerbs.verbs[0]')" "$(head -1 "$ROOT/skills/spinner-themes/themes/surf.txt")"

printf '{"model":"opus","spinnerVerbs":{"mode":"append","verbs":["x"]}}\n' > "$SPINNER_SETTINGS"
run set wingfoil surf motorsport > /dev/null
check "other settings are kept" "$(field .model)" opus
check "an append from before becomes replace" "$(field .spinnerVerbs.mode)" replace
check "words shared by two themes appear once" "$(field '.spinnerVerbs.verbs | length == (unique | length)')" true

run set surf --append > /dev/null
check "--append keeps Claude Code's own words" "$(field .spinnerVerbs.mode)" append

check "an unknown theme is refused" "$(run set no-such-theme)" 1
check "no theme is refused" "$(run set)" 1

mkdir -p "$SPINNER_THEMES_DIR"
printf 'Custom one\n\n# a comment\r\n  Other one  \r\n' > "$SPINNER_THEMES_DIR/surf.txt"
run set surf > /dev/null
check "a theme of yours overrides the built-in one, CRLF and blanks dropped" \
  "$(field '.spinnerVerbs.verbs | join("|")')" "Custom one|Other one"
check "list marks it as yours" "$(bash "$SCRIPT" list | grep -c '^surf .*(yours)')" 1

printf 'not json\n' > "$SPINNER_SETTINGS"
check "invalid settings are refused" "$(run set surf)" 1
check "and left as they were" "$(tr -d '\r' < "$SPINNER_SETTINGS")" "not json"

printf '{"a":1,"spinnerVerbs":{"verbs":["x"]}}\n' > "$SPINNER_SETTINGS"
run off > /dev/null
check "off removes only spinnerVerbs" "$(jq -c . < "$SPINNER_SETTINGS" | tr -d '\r')" '{"a":1}'

echo "$fails problem(s)"
[ "$fails" -eq 0 ]
