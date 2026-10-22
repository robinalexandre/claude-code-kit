#!/bin/bash
# Tells Claude when the clone a kit was installed from with install.sh has changes for the parts
# installed on this computer, or parts it didn't offer before. Plugins don't need it: Claude Code
# updates them.
#   kit-update-check.sh             session start: says what the last check found, and starts the next
#                                   one in the background when the last is a day old; a new part is
#                                   told once
#   kit-update-check.sh fetch       the check itself: fetches the clone, keeps a note of what changed
#   kit-update-check.sh changed [REF]   the installed parts with changes up to REF (default: the
#                                   clone's upstream), one per line; install.sh --update uses it
#   kit-update-check.sh off | on    stops or resumes the checks on this computer
# install.sh records the clone, the commit and files of each part it installed, and the parts the
# clone offered, in ~/.claude/kit-install.json; without it this does nothing.
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/jq.sh"
. "$HERE/lib/ask.sh"
RECORD="$HOME/.claude/kit-install.json"
STATE="$HOME/.claude/kit-update"
[ -f "$RECORD" ] || exit 0
KIT=$(jq -r '.kit // empty' "$RECORD")
[ -n "$KIT" ] && git -C "$KIT" rev-parse --git-dir > /dev/null 2>&1 || exit 0

upstream() {
  git -C "$KIT" rev-parse -q --verify '@{u}^{commit}' 2> /dev/null ||
    git -C "$KIT" rev-parse -q --verify 'refs/remotes/origin/HEAD^{commit}' 2> /dev/null
}

# part, commit, files: one line per installed part.
parts() {
  jq -r '.parts // {} | to_entries[] | [.key, .value.commit, (.value.files | join(" "))] | @tsv' "$RECORD"
}

changed() {
  local to=$1 p from files
  parts | while IFS=$'\t' read -r p from files; do
    git -C "$KIT" cat-file -e "$from^{commit}" 2> /dev/null || continue
    if [ -n "$(git -C "$KIT" rev-list -1 "$from..$to" -- $files)" ]; then echo "$p"; fi
  done
}

# New parts offered on this system, "name<TAB>what" lines; nothing for a record from before .known.
new_parts() {
  local os
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) os=windows ;;
    Darwin) os=darwin ;;
    *) os=linux ;;
  esac
  jq -e 'has("known")' "$RECORD" > /dev/null 2>&1 || return 0
  git -C "$KIT" show "$1:parts.json" 2> /dev/null | jq -r --arg os "$os" --argjson known "$(jq -c .known "$RECORD")" '
    .parts[] | select((.os // []) as $o | ($o | length) == 0 or ($o | index($os)))
    | select(.name as $n | $known | index($n) | not) | [.name, .what] | @tsv'
}

report() {
  local to names fresh p from files
  to=$(upstream) || return 0
  names=$(changed "$to" | tr '\n' ' ')
  fresh=$(new_parts "$to")
  [ -n "$names" ] || [ -n "$fresh" ] || return 0
  printf 'Kit updates, from the clone this computer installed the kit from with install.sh (%s).\n' "$KIT"
  if [ -n "$names" ]; then
    printf 'Changes for the parts installed here: %s\n' "${names% }"
    parts | while IFS=$'\t' read -r p from files; do
      case " $names " in *" $p "*) git -C "$KIT" log --no-merges --format='%H %s' "$from..$to" -- $files ;; esac
    done | awk '!seen[$1]++ { sub(/^[^ ]+ /, "- "); print }' | head -15
  fi
  if [ -n "$fresh" ]; then
    printf 'New parts, not offered before:\n'
    awk -F'\t' '{ print "- " $1 ": " $2 }' <<< "$fresh"
  fi
  printf 'Early in this session, tell the user in a few words what changed for them and what is new, and offer to update. '
  printf 'On their yes, run: bash "%s/install.sh" --update, followed by the names of the new parts they want ' "$KIT"
  printf '(files they edited in ~/.claude are replaced; the previous ones go to ~/.claude/backups/; '
  printf 'a new part with a setup asks questions, so offer them to run that command in their own terminal). '
  printf 'If they want no more of these checks, run: bash "%s" off\n' "$(kit_path "$HERE/kit-update-check.sh")"
  printf '%s\n' "$fresh" | cut -f1 | grep . > "$STATE/told.tmp"
}

# The new parts of a report shown: told once.
remember_told() {
  [ -s "$STATE/told" ] || return 0
  jq --indent 2 --arg t "$(< "$STATE/told")" '.known = ((.known // []) + ($t | split("\n") | map(select(. != ""))) | unique)' \
    "$RECORD" > "$RECORD.tmp" && mv "$RECORD.tmp" "$RECORD"
}

case "${1:-}" in
  changed)
    to=${2:-}
    if [ -n "$to" ]; then to=$(git -C "$KIT" rev-parse -q --verify "$to^{commit}"); else to=$(upstream); fi
    [ -n "$to" ] && changed "$to"
    ;;
  fetch)
    mkdir -p "$STATE"
    GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" \
      git -C "$KIT" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 fetch --quiet 2> /dev/null || exit 0
    rm -f "$STATE/told.tmp"
    report > "$STATE/report.tmp"
    if [ -s "$STATE/report.tmp" ]; then
      mv "$STATE/report.tmp" "$STATE/report"
      if [ -f "$STATE/told.tmp" ]; then mv "$STATE/told.tmp" "$STATE/told"; else rm -f "$STATE/told"; fi
    else
      rm -f "$STATE/report.tmp" "$STATE/report" "$STATE/told.tmp" "$STATE/told"
    fi
    ;;
  off | on)
    [ "$1" = on ] && check=true || check=false
    jq --indent 2 --argjson c "$check" '.check = $c' "$RECORD" > "$RECORD.tmp" && mv "$RECORD.tmp" "$RECORD"
    echo "Kit update checks: $1."
    ;;
  "")
    [ "$(jq -r .check "$RECORD")" = false ] && exit 0
    if [ -f "$STATE/report" ]; then
      cat "$STATE/report"
      remember_told
      rm -f "$STATE/report" "$STATE/told"
    fi
    mkdir -p "$STATE"
    if [ -z "$(find "$STATE/fetched" -mmin -1440 2> /dev/null)" ]; then
      touch "$STATE/fetched"
      (nohup bash "$HERE/kit-update-check.sh" fetch > /dev/null 2>&1 < /dev/null &)
    fi
    ;;
esac
exit 0
