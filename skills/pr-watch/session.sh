#!/bin/bash
# Checks the tracked PRs at each session start without delaying it, and says nothing in the session:
# the pr-pane band and pane show what the check found (each PR keeps its changes as unread).
#   session.sh start    SessionStart hook: runs `pr-watch.sh check --quiet` in the background
#   session.sh prompt   kept for settings that still call it: does nothing
#   session.sh run      the background check itself
# A check that ran less than PR_WATCH_SESSION_MINUTES ago (default 15) is not run again.
set -u
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WATCH_DIR=${PR_WATCH_DIR:-$HOME/.claude-sync/pr-watch}
STATE="$HOME/.claude/.pr-watch-state"
MINUTES=${PR_WATCH_SESSION_MINUTES:-15}

tracked() {
  local f
  for f in "$WATCH_DIR"/*.json; do
    [ -f "$f" ] && [ "${f##*/}" != config.json ] && return 0
  done
  return 1
}

start() {
  [ -t 0 ] || cat > /dev/null
  tracked || return 0
  mkdir -p "$STATE"
  # Left by the versions that handed the check's report to the session.
  rm -f "$STATE"/pending "$STATE"/quiet-* "$STATE"/taking-* 2> /dev/null
  [ -n "$(find "$STATE" -maxdepth 1 -name last -mmin -"$MINUTES" 2> /dev/null)" ] && return 0
  touch "$STATE/last"
  (nohup bash "$SK/session.sh" run > /dev/null 2>&1 < /dev/null &)
}

run() {
  if ! mkdir "$STATE/lock" 2> /dev/null; then
    [ -n "$(find "$STATE" -maxdepth 1 -name lock -mmin +10 2> /dev/null)" ] || return 0
    rm -rf "$STATE/lock" && mkdir "$STATE/lock" 2> /dev/null || return 0
  fi
  bash "$SK/pr-watch.sh" check --quiet > /dev/null 2>&1
  rm -rf "$STATE/lock"
}

case "${1:-}" in
  start) start ;;
  prompt) [ -t 0 ] || cat > /dev/null ;;
  run) run ;;
  *)
    echo "usage: session.sh start|prompt|run" >&2
    exit 2
    ;;
esac
exit 0
