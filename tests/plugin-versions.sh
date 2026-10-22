#!/bin/bash
# Fails when a plugin's files or marketplace entry changed since BASE but its version didn't: Claude
# Code only updates a plugin whose version moved, so a change without a bump never reaches its users.
#   tests/plugin-versions.sh [BASE]    BASE: a git ref, default origin/main; compares with the working tree
# Works on macOS, Linux and Windows (Git Bash).
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$KIT"
. hooks/lib/jq.sh
BASE=${1:-origin/main}
MARKET=.claude-plugin/marketplace.json
git rev-parse -q --verify "$BASE^{commit}" > /dev/null || {
  echo "No $BASE to compare with: skipped."
  exit 0
}
git show "$BASE:$MARKET" > /dev/null 2>&1 || {
  echo "No marketplace in $BASE: skipped."
  exit 0
}
changed=$( (git diff --name-only "$BASE" -- . && git ls-files --others --exclude-standard) | sort -u)

# Files a plugin ships beyond its skills and the scripts its hooks name.
extras() {
  case "$1" in
    team) echo rules/team.md ;;
    statusline) echo statusline-command.sh hooks/setup/statusline.sh ;;
    session-registry) echo hooks/claude-resume-here.zsh hooks/setup/session-registry.sh ;;
    git-identity-guard) echo hooks/setup/git-identity-guard.sh ;;
    recent-activity) echo hooks/setup/recent-activity.sh ;;
    config-sync) echo sync/ ;;
  esac
}

files_of() {
  local p=$1 source
  source=$(jq -r --arg p "$p" '.plugins[] | select(.name == $p) | .source' "$MARKET")
  if [ "$source" != . ]; then
    git ls-files "${source#./}" | grep -v '/tests/'
    return
  fi
  {
    jq -r --arg p "$p" '.plugins[] | select(.name == $p) | (.skills // [] | .[] | select(. != "./hooks") | sub("^\\./"; "") + "/"),
      (.hooks // {} | .[][].hooks[].command | capture("CLAUDE_PLUGIN_ROOT}/(?<f>[^\"]*)").f)' "$MARKET"
    extras "$p" | tr ' ' '\n'
  } | grep . | sort -u > "$KIT/.plugin-files.tmp"
  cat "$KIT/.plugin-files.tmp"
  # Each of the kit's shared scripts that one of the plugin's own scripts sources.
  local scripts lib
  scripts=$(git ls-files $(cat "$KIT/.plugin-files.tmp") | grep -E '\.(sh|zsh)$')
  for lib in jq ask kit; do
    if [ -n "$scripts" ] && grep -qE "^[^#]*\. .*lib/$lib\.sh" $scripts < /dev/null; then echo "hooks/lib/$lib.sh"; fi
  done
  rm -f "$KIT/.plugin-files.tmp"
}

version_in() {
  local ref=$1 p=$2 entry source
  if [ "$ref" = work ]; then entry=$(jq -c --arg p "$p" '.plugins[] | select(.name == $p)' "$MARKET"); else entry=$(git show "$ref:$MARKET" | jq -c --arg p "$p" '.plugins[] | select(.name == $p)'); fi
  [ -n "$entry" ] || return 0
  if [ "$(jq -r '.version // empty' <<< "$entry")" != "" ]; then
    jq -r .version <<< "$entry"
  else
    source=$(jq -r '.source | sub("^\\./"; "")' <<< "$entry")
    if [ "$ref" = work ]; then jq -r '.version // empty' "$source/.claude-plugin/plugin.json"; else git show "$ref:$source/.claude-plugin/plugin.json" 2> /dev/null | jq -r '.version // empty'; fi
  fi
}

fails=0
for p in $(jq -r '.plugins[].name' "$MARKET"); do
  old=$(version_in "$BASE" "$p")
  [ -n "$old" ] || continue
  new=$(version_in work "$p")
  why=""
  for f in $(files_of "$p"); do
    hit=$(grep -m1 -E "^${f//./\\.}" <<< "$changed" || true)
    [ -n "$hit" ] && why="$hit" && break
  done
  if [ -z "$why" ]; then
    a=$(git show "$BASE:$MARKET" | jq -cS --arg p "$p" '.plugins[] | select(.name == $p) | del(.version, .description)')
    b=$(jq -cS --arg p "$p" '.plugins[] | select(.name == $p) | del(.version, .description)' "$MARKET")
    [ "$a" != "$b" ] && why="its marketplace entry"
  fi
  if [ -n "$why" ] && [ "$new" = "$old" ]; then
    echo "FAIL $p: $why changed since $BASE, but its version is still $old (bump it)"
    fails=$((fails + 1))
  elif [ -n "$why" ]; then
    echo "ok   $p: $old -> $new"
  fi
done
echo "$fails problem(s)"
[ "$fails" = 0 ]
