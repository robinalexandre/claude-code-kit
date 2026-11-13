#!/bin/bash
# Sets the words Claude Code shows while it works (the spinner verbs) from one or more themes.
#   spinner-themes.sh list                 the themes, built-in and your own, with their word counts
#   spinner-themes.sh show THEME           the words of a theme
#   spinner-themes.sh current              what the settings hold now
#   spinner-themes.sh set THEME... [--append]
#                                          only these themes' words (--append: mixed with Claude Code's own)
#   spinner-themes.sh off                  back to Claude Code's own words
# Your own themes: one word or phrase per line in $SPINNER_THEMES_DIR/<theme>.txt
# (default ~/.claude/spinner-themes); one there overrides a built-in theme of the same name.
# The settings file is $SPINNER_SETTINGS (default ~/.claude/settings.json).
set -eu
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$SK/../../hooks/lib"
if [ -f "$LIB/jq.sh" ]; then . "$LIB/jq.sh"; fi
BUILTIN="$SK/themes"
OWN=${SPINNER_THEMES_DIR:-$HOME/.claude/spinner-themes}
SETTINGS=${SPINNER_SETTINGS:-$HOME/.claude/settings.json}

die() { echo "$*" >&2; exit 1; }

theme_file() {
  if [ -f "$OWN/$1.txt" ]; then
    printf '%s' "$OWN/$1.txt"
  elif [ -f "$BUILTIN/$1.txt" ]; then
    printf '%s' "$BUILTIN/$1.txt"
  else
    return 1
  fi
}

words() { tr -d '\r' < "$1" | awk 'NF && $0 !~ /^#/ { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print }'; }

list() {
  local f name where
  for f in "$BUILTIN"/*.txt "$OWN"/*.txt; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .txt)
    where=built-in
    case "$f" in "$OWN"/*) where=yours ;; esac
    if [ "$where" = built-in ] && [ -f "$OWN/$name.txt" ]; then continue; fi
    printf '%-14s %3d words  (%s)\n' "$name" "$(words "$f" | grep -c .)" "$where"
  done
}

write_settings() {
  local filter=$1 verbs=${2:-[]} tmp
  mkdir -p "$(dirname "$SETTINGS")"
  [ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  tmp="$SETTINGS.spinner.$$"
  jq --indent 2 --argjson verbs "$verbs" --arg mode "${MODE:-replace}" "$filter" < "$SETTINGS" > "$tmp" ||
    { rm -f "$tmp"; die "Could not update $SETTINGS (is it valid JSON?)."; }
  mv "$tmp" "$SETTINGS"
}

set_themes() {
  local all="" names="" f t verbs count
  MODE=replace
  for t in "$@"; do
    case "$t" in
      --append) MODE=append ;;
      *) f=$(theme_file "$t") || die "No theme named '$t'. Themes: $(list | awk '{printf "%s ", $1}')"
         all="$all$(words "$f")"$'\n'
         names="$names${names:+, }$t" ;;
    esac
  done
  [ -n "$all" ] || die "Name at least one theme."
  verbs=$(printf '%s' "$all" | awk 'NF && !seen[$0]++' | jq -R . | jq -s -c .)
  count=$(printf '%s' "$verbs" | jq length)
  write_settings '.spinnerVerbs = {mode: $mode, verbs: $verbs}' "$verbs"
  echo "Spinner: $count words from $names ($MODE) in $SETTINGS. New sessions show them."
}

case "${1:-}" in
  list) list ;;
  show) [ -n "${2:-}" ] || die "Usage: show THEME"; f=$(theme_file "$2") || die "No theme named '$2'."; words "$f" ;;
  current)
    [ -f "$SETTINGS" ] || { echo "No settings file: Claude Code's own words."; exit 0; }
    jq -r 'if .spinnerVerbs then "mode: \(.spinnerVerbs.mode // "append"), \(.spinnerVerbs.verbs | length) words: \(.spinnerVerbs.verbs | join(", "))" else "Claude Code'"'"'s own words." end' < "$SETTINGS"
    ;;
  set) shift; set_themes "$@" ;;
  off) [ -f "$SETTINGS" ] && write_settings 'del(.spinnerVerbs)'; echo "Spinner: Claude Code's own words." ;;
  *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 2 ;;
esac
