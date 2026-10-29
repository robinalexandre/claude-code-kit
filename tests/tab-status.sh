#!/bin/bash
# Checks hooks/tab-status.sh in a throwaway folder: the title and bell each state writes, the
# order guard for background events, the end of a session. bash tests/tab-status.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" TAB_STATUS_DEV="$T/tty"
unset CLAUDE_CONFIG_DIR CLAUDE_TAB_ICONS
mkdir -p "$HOME" "$T/repo/sub dir"
git -C "$T/repo" init -q
TR="$T/session.jsonl"
printf '{"type":"user","message":{"content":"hi"}}\n{"type":"ai-title","aiTitle":"Fix the login"}\n' > "$TR"
fails=0

check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; printf '     %s\n' "$(od -c "$T/tty" 2>/dev/null | head -3)"; fails=$((fails + 1)); fi
}

ev() {
  : > "$T/tty"
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"x"}' "${2:-s1}" "$TR" "$T/repo/sub dir" \
    | sh "$KIT/hooks/tab-status.sh" "$1"
}
title() { local s; s=$(cat "$T/tty"); s=${s#*]0;}; printf '%s' "${s%%$'\033'*}"; }
rang() { LC_ALL=C grep -q "$(printf '\a')" "$T/tty"; }

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    # Windows: the hook does nothing (no tty to write to)
    ev done
    check "windows: writes nothing" '[ ! -s "$T/tty" ]'
    echo "$fails failure(s)"
    [ "$fails" -eq 0 ]
    exit
    ;;
esac

ev start
check "start: green, the repo and the session title" '[ "$(title)" = "🟢 repo · Fix the login" ]'
check "start: no bell" '! rang'

ev working
check "working: yellow, no bell" '[ "$(title)" = "🟡 repo · Fix the login" ] && ! rang'

ev working
check "working again: nothing written" '[ ! -s "$T/tty" ]'

ev waiting
check "waiting: red, and the bell" '[ "$(title)" = "🔴 repo · Fix the login" ] && rang'

printf '%s %s\n' waiting $(($(date +%s) + 60)) > "$HOME/.claude/tab-status/s1.state"
ev working
check "a background event older than the last state is dropped" '[ ! -s "$T/tty" ]'

printf '%s %s\n' waiting 1 > "$HOME/.claude/tab-status/s1.state"
ev working
check "after the wait, back to working" '[ "$(title)" = "🟡 repo · Fix the login" ]'

printf '{"type":"custom-title","customTitle":"Login bug"}\n' >> "$TR"
ev done
check "done: green, the /rename title wins, and the bell" '[ "$(title)" = "🟢 repo · Login bug" ] && rang'

ev error
check "error: a cross" '[ "$(title)" = "❌ repo · Login bug" ]'

CLAUDE_TAB_ICONS="W N D E" ev waiting
check "marks can be changed" '[ "$(title)" = "N repo · Login bug" ]'

ev end
check "end: the repo alone, and nothing kept" '[ "$(title)" = "repo" ] && [ -z "$(ls "$HOME/.claude/tab-status")" ]'

: > "$T/tty"
printf '{"session_id":"../x","cwd":"%s"}' "$T" | sh "$KIT/hooks/tab-status.sh" done
check "a session id with a path in it is refused" '[ ! -s "$T/tty" ]'

esc=$(printf '\033')
mkdir -p "$T/re${esc}]0;x$(printf '\a')po"
: > "$T/tty"
jq -cn --arg c "$T/re${esc}]0;x$(printf '\a')po" '{session_id: "s3", cwd: $c}' | sh "$KIT/hooks/tab-status.sh" done
check "control characters in the folder name are dropped" '[ "$(LC_ALL=C tr -cd "\033" < "$T/tty" | wc -c)" -eq 2 ] && [ "$(LC_ALL=C tr -cd "\007" < "$T/tty" | wc -c)" -eq 1 ] && grep -q "re\]0;xpo" "$T/tty"'

out=$(printf 'not json' | sh "$KIT/hooks/tab-status.sh" done 2>&1); code=$?
check "bad input: silent, exit 0" '[ -z "$out" ] && [ $code = 0 ]'

if command -v setsid > /dev/null 2>&1; then
  # Without a controlling terminal anywhere up the tree (claude -p, CI)
  out=$(unset TAB_STATUS_DEV; printf '{"session_id":"s2","cwd":"%s"}' "$T" | setsid sh "$KIT/hooks/tab-status.sh" done 2>&1)
  check "no terminal: silent" '[ -z "$out" ] && [ ! -f "$HOME/.claude/tab-status/s2.tty" ]'
fi

echo "$fails failure(s)"
[ "$fails" -eq 0 ]
