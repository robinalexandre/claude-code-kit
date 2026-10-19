#!/bin/bash
# Checks the tracked PRs at each session start without delaying it.
#   session.sh start    SessionStart hook: runs `pr-watch.sh check` in the background
#   session.sh prompt   UserPromptSubmit hook: hands over what that check found
#   session.sh run SID  the background check itself
# What a check finds waits in $STATE/pending until a session takes it, so nothing
# is lost when a session closes before the check ends. A check that ran less than
# PR_WATCH_SESSION_MINUTES ago (default 15) is not run again.
set -u
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WATCH_DIR=${PR_WATCH_DIR:-$HOME/.claude-sync/pr-watch}
STATE="$HOME/.claude/.pr-watch-state"
MINUTES=${PR_WATCH_SESSION_MINUTES:-15}

if [ -f "$HOME/.claude/hooks/lib/jq.sh" ]; then
  . "$HOME/.claude/hooks/lib/jq.sh"
elif command -v cygpath > /dev/null 2>&1; then
  jq() { command jq -b "$@"; }
fi

tracked() {
  local f
  for f in "$WATCH_DIR"/*.json; do
    [ -f "$f" ] && [ "${f##*/}" != config.json ] && return 0
  done
  return 1
}

read_sid() {
  local input=""
  [ -t 0 ] || input=$(cat)
  SID=$(printf '%s' "$input" | jq -r '.session_id // empty' 2> /dev/null | tr -cd 'A-Za-z0-9_-')
  SID=${SID:-default}
}

start() {
  read_sid
  tracked || return 0
  mkdir -p "$STATE"
  find "$STATE" -maxdepth 1 -name 'quiet-*' -mtime +2 -exec rm -f {} + 2> /dev/null
  [ -n "$(find "$STATE" -maxdepth 1 -name last -mmin -"$MINUTES" 2> /dev/null)" ] && return 0
  touch "$STATE/last"
  (nohup bash "$SK/session.sh" run "$SID" > /dev/null 2>&1 < /dev/null &)
}

run() {
  local sid=$1 out err
  if ! mkdir "$STATE/lock" 2> /dev/null; then
    [ -n "$(find "$STATE" -maxdepth 1 -name lock -mmin +10 2> /dev/null)" ] || return 0
    rm -rf "$STATE/lock" && mkdir "$STATE/lock" 2> /dev/null || return 0
  fi
  err="$STATE/lock/stderr"
  out=$(bash "$SK/pr-watch.sh" check 2> "$err")
  [ -s "$err" ] && out="$out"$'\n'"$(cat "$err")"
  out=$(printf '%s\n' "$out" | grep -v '^No change\.$' | grep .)
  if [ -n "$out" ]; then
    printf '%s\n' "$out" >> "$STATE/pending"
  else
    touch "$STATE/quiet-$sid"
  fi
  rm -rf "$STATE/lock"
}

prompt() {
  local found
  read_sid
  if [ -s "$STATE/pending" ] && mv "$STATE/pending" "$STATE/taking-$SID" 2> /dev/null; then
    found=$(cat "$STATE/taking-$SID")
    rm -f "$STATE/taking-$SID" "$STATE/quiet-$SID"
    jq -n --arg found "$found" --arg sk "$SK" '{
      systemMessage: "🔀 PR updates found at session start",
      hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: (
        "The pr-watch skill checked the tracked PRs at session start and found the changes below (already recorded as seen). In your next reply, before anything else, report them PR by PR as the pr-watch skill says (read new comment threads and failed CI runs, propose replies or fixes; never post or push without the user'"'"'s yes). Scripts: \($sk)\n\n" + $found)}}'
  elif [ -f "$STATE/quiet-$SID" ]; then
    rm -f "$STATE/quiet-$SID"
    jq -n '{systemMessage: "🔀 PRs checked at session start: no change"}'
  fi
}

case "${1:-}" in
  start) start ;;
  prompt) prompt ;;
  run) run "${2:-default}" ;;
  *)
    echo "usage: session.sh start|prompt" >&2
    exit 2
    ;;
esac
exit 0
