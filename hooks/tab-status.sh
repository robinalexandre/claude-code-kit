#!/bin/sh
# Shows each session's state in its terminal tab, as "<mark> <repo> · <session title>", and rings
# the bell when the session needs you, so a terminal that marks ringing tabs (Ghostty's 🔔, iTerm,
# WezTerm, kitty, tmux) points at it too. Marks: 🟡 working, 🔴 waiting for you (a permission, a
# question), 🟢 done, your turn, ❌ failed; CLAUDE_TAB_ICONS="🟡 🔴 🟢 ❌" changes them.
# Claude Code's own title must be off (CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1) or it writes over it.
#
#   tab-status.sh start|working|waiting|done|error|end     (the event's JSON on stdin)
#
# The hook's output is not the terminal: it writes to the tty of the closest ancestor that has
# one (Claude Code), found once per session and kept with the repo and title under
# ~/.claude/tab-status. Silent when there is no terminal (claude -p) and on Windows.
# TAB_STATUS_DEV writes there instead of the terminal (tests).

case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) cat > /dev/null; exit 0 ;; esac
state=${1:-working}

# "check" (at session start, for the plugin): Claude Code's own title would hide the marks
if [ "$state" = check ]; then
  cat > /dev/null
  [ -n "${CLAUDE_CODE_DISABLE_TERMINAL_TITLE:-}" ] && exit 0
  [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/tab-status/.setup-asked" ] && exit 0
  setup="$(cd "$(dirname "$0")" && pwd)/setup/tab-status.sh"
  printf 'tab-status: Claude Code still writes its own tab title, which hides the status marks. Early in this session, offer the user to run in their own terminal: bash "%s" (one question).\n' "$setup"
  exit 0
fi
now=$(date +%s)
input=$(cat)
command -v jq > /dev/null 2>&1 || exit 0

tab=$(printf '%s' "$input" | jq -r '[.session_id // "", .transcript_path // "", .cwd // ""] | join("\t")' 2>/dev/null)
sid=${tab%%"	"*}
rest=${tab#*"	"}
transcript=${rest%%"	"*}
cwd=${rest#*"	"}
case "$sid" in '' | */* | .*) exit 0 ;; esac

dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/tab-status"
f="$dir/$sid"
mkdir -p "$dir" 2>/dev/null || exit 0
if [ "$state" = start ]; then
  # A resumed session can open in another tab; sessions that crashed never send "end"
  rm -f "$f.tty" "$f.repo"
  find "$dir" -type f -mtime +7 -exec rm -f {} + 2>/dev/null
fi

if [ "$state" = working ] && [ -f "$f.state" ]; then
  # Background events can land after a later one: never cover a newer state, nor repeat this one
  read -r prev when < "$f.state"
  case "$prev" in
    working) exit 0 ;;
    waiting | done | error) [ "${when:-0}" -ge "$now" ] 2>/dev/null && exit 0 ;;
  esac
fi

dev=${TAB_STATUS_DEV:-}
if [ -z "$dev" ] && [ -f "$f.tty" ]; then read -r dev < "$f.tty"; fi
if [ -z "$dev" ]; then
  pid=$$
  i=0
  while [ "$i" -lt 8 ] && [ "${pid:-0}" -gt 1 ] 2>/dev/null; do
    tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$tty" in
      '' | '?' | '??' | -) ;;
      *) dev="/dev/$tty"; break ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    i=$((i + 1))
  done
  [ -n "$dev" ] || exit 0
  printf '%s\n' "$dev" > "$f.tty"
fi

if [ -f "$f.repo" ]; then
  read -r repo < "$f.repo"
else
  top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
  top=${top:-$cwd}
  if [ "$top" = "$HOME" ]; then repo="~"; else repo=${top##*/}; fi
  printf '%s\n' "$repo" > "$f.repo"
fi

title=""
if [ -f "$transcript" ]; then
  title=$(grep -a '"type":"custom-title"' "$transcript" | tail -n 1 | jq -r '.customTitle // empty' 2>/dev/null)
  [ -n "$title" ] || title=$(grep -a '"type":"ai-title"' "$transcript" | tail -n 1 | jq -r '.aiTitle // empty' 2>/dev/null)
  title=$(printf '%s' "$title" | tr -d '\000-\037' | cut -c1-80)
fi

if [ "$state" = end ]; then
  printf '\033]0;%s\033\\' "$repo" 2>/dev/null >> "$dev"
  rm -f "$f.state" "$f.tty" "$f.repo"
  exit 0
fi

# shellcheck disable=SC2086
set -- ${CLAUDE_TAB_ICONS:-🟡 🔴 🟢 ❌}
case "$state" in
  working) mark=$1 ;;
  waiting) mark=$2 ;;
  start | done) mark=$3 ;;
  error) mark=$4 ;;
  *) exit 0 ;;
esac
text="$mark $repo"
[ -n "$title" ] && text="$text · $title"

printf '%s %s\n' "$state" "$now" > "$f.state"
printf '\033]0;%s\033\\' "$text" 2>/dev/null >> "$dev"
case "$state" in waiting | done | error) printf '\a' 2>/dev/null >> "$dev" ;; esac
exit 0
