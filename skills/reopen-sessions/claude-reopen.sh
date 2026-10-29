#!/bin/bash
# Reopens, one terminal tab each, the interactive Claude Code sessions that were active
# recently and are no longer running (after the terminal or the IDE crashed).
#
#   claude-reopen.sh                  sessions active in the last 30 minutes, newest first;
#                                     in a terminal, asks which ones (Enter for all)
#   claude-reopen.sh 90               ... in the last 90 minutes
#   claude-reopen.sh --all            all of them, without asking
#   claude-reopen.sh --pick           ask even when not in a terminal (answer on stdin)
#   claude-reopen.sh --one-window     all the tabs in one window (default: a window per repo)
#   claude-reopen.sh --list [N]       only list them
#   claude-reopen.sh <id>...          these sessions (full id or its first 8 characters)
#   claude-reopen.sh --find <text>    sessions of any age whose title or prompts mention it
#   claude-reopen.sh --terminal <t>   ghostty, iterm, terminal (Terminal.app), wezterm, kitty,
#                                     wt (Windows Terminal), gnome-terminal, justsessions, or print
#
# The terminal is CLAUDE_REOPEN_TERMINAL, else the one this runs in: from its variables, else from
# the app this process runs under (macOS), so an IDE, JustSessions or any other app is named too.
# An app it cannot open tabs in gets the commands to run instead (print).
# CLAUDE_REOPEN_ECHO=1 prints what would be launched instead of launching it, and
# CLAUDE_REOPEN_APP stands for the app found above, "" for none (tests).
set -u
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -f "$SK/../../hooks/lib/jq.sh" ]; then
  . "$SK/../../hooks/lib/jq.sh"
fi
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECTS="$CLAUDE_DIR/projects"
LIVE="$CLAUDE_DIR/sessions"
CLAUDE_BIN="${CLAUDE_REOPEN_CLAUDE:-claude}"

list_only=0
pick_all=0
pick=0
one_window=0
find=
minutes=30
terminal="${CLAUDE_REOPEN_TERMINAL:-}"
ids=()
while [ $# -gt 0 ]; do
  case "$1" in
    --list) list_only=1 ;;
    --all) pick_all=1 ;;
    --pick) pick=1 ;;
    --one-window) one_window=1 ;;
    --find) find="${2:-}"; shift ;;
    --terminal) terminal="${2:-}"; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *[!0-9a-f-]*) echo "Not a session id: $1" >&2; exit 2 ;;
    ''|*[!0-9]*) ids+=("$1") ;;
    *) minutes="$1" ;;
  esac
  shift
done

if [ -z "$terminal" ]; then
  case "${TERM_PROGRAM:-}" in
    ghostty) terminal=ghostty ;;
    iTerm.app) terminal=iterm ;;
    Apple_Terminal) terminal=terminal ;;
    WezTerm) terminal=wezterm ;;
  esac
fi
if [ -z "$terminal" ]; then
  if [ -n "${KITTY_WINDOW_ID:-}" ]; then terminal=kitty
  elif [ -n "${WT_SESSION:-}" ]; then terminal=wt
  elif [ -n "${GNOME_TERMINAL_SCREEN:-}" ]; then terminal=gnome-terminal
  fi
fi

# The outermost .app of the first ancestor run from an app bundle (macOS)
parent_app() {
  local pid=$$ i=0 cmd
  while [ $i -lt 15 ] && [ "${pid:-0}" -gt 1 ] 2>/dev/null; do
    cmd=$(ps -o comm= -p "$pid" 2>/dev/null)
    case "$cmd" in
      *.app/Contents/*) cmd=${cmd%%.app/*}; printf '%s' "${cmd##*/}"; return ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    i=$((i + 1))
  done
}
app=
if [ -z "$terminal" ]; then
  if [ -n "${CLAUDE_REOPEN_APP+set}" ]; then app=$CLAUDE_REOPEN_APP
  elif [ "$(uname -s)" = Darwin ]; then app=$(parent_app)
  fi
  case "$app" in
    Ghostty) terminal=ghostty ;;
    iTerm|iTerm2) terminal=iterm ;;
    Terminal) terminal=terminal ;;
    WezTerm) terminal=wezterm ;;
    kitty) terminal=kitty ;;
    JustSessions) terminal=justsessions ;;
    *) terminal=print ;;
  esac
fi

is_live() {
  local f pid
  for f in "$LIVE"/*.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r '.sessionId // empty' "$f" 2>/dev/null)" = "$1" ] || continue
    pid=$(jq -r '.pid // empty' "$f" 2>/dev/null)
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null && return 0
    case "$(uname -s)" in
      MINGW*|MSYS*|CYGWIN*) tasklist //FI "PID eq $pid" //NH 2>/dev/null | grep -q " $pid " && return 0 ;;
    esac
  done
  return 1
}

# The /rename title, else the title Claude Code gave the session, else its first prompt
title_of() {
  local t
  t=$(grep -a '"type":"custom-title"' "$1" | tail -n 1 | jq -r '.customTitle // empty' 2>/dev/null)
  [ -n "$t" ] || t=$(grep -a '"type":"ai-title"' "$1" | tail -n 1 | jq -r '.aiTitle // empty' 2>/dev/null)
  [ -n "$t" ] || t=$(prompts_of "$1" | head -n 1)
  printf '%s' "$t" | tr '\n\t' '  ' | cut -c1-70
}

prompts_of() {
  grep -a '"type":"user"' "$1" | jq -r 'select(.message.content | type == "string") | .message.content' 2>/dev/null \
    | grep -v '^<' | grep -v '^[[:space:]]*$'
}

# Whether the session's titles or typed prompts mention the text (not tool output)
mentions() {
  { grep -a '"type":"custom-title"\|"type":"ai-title"' "$1" | jq -r '.customTitle // .aiTitle // empty' 2>/dev/null
    prompts_of "$1"; } | grep -q -i -F -- "$2"
}

shopt -s nullglob
candidates=()
if [ ${#ids[@]} -gt 0 ]; then
  for id in "${ids[@]}"; do
    for t in "$PROJECTS"/*/"$id"*.jsonl; do candidates+=("$t"); done
  done
elif [ -n "$find" ]; then
  while IFS= read -r t; do
    mentions "$t" "$find" && candidates+=("$t")
  done < <(grep -a -i -F -l -- "$find" "$PROJECTS"/*/*.jsonl 2>/dev/null)
elif [ -d "$PROJECTS" ]; then
  while IFS= read -r t; do candidates+=("$t"); done < <(find "$PROJECTS" -mindepth 2 -maxdepth 2 -name '*.jsonl' -mmin -"$minutes" 2>/dev/null)
fi

last_used() {
  local v
  v=$(grep -a '"timestamp":"' "$1" | tail -n 1 | jq -r '.timestamp | sub("\\.[0-9]+"; "") | fromdateiso8601' 2>/dev/null)
  echo "${v:-0}"
}

ago() {
  local m=$(( ($(date +%s) - $1) / 60 ))
  if [ "$1" -le 0 ]; then echo "?"
  elif [ $m -lt 60 ]; then echo "${m} min ago"
  elif [ $m -lt 2880 ]; then echo "$((m / 60)) h ago"
  else echo "$((m / 1440)) days ago"
  fi
}

ranked=()
for t in ${candidates[@]+"${candidates[@]}"}; do
  id=$(basename "$t" .jsonl)
  case "$id" in *[!0-9a-f-]*) continue ;; esac
  grep -aq '"entrypoint":"cli"' "$t" || continue
  if is_live "$id"; then echo "skip ${id:0:8} (already running)"; continue; fi
  ranked+=("$(last_used "$t")"$'\t'"$t")
done

dirs=()
sids=()
when=()
k=0
while IFS=$'\t' read -r used t; do
  [ -n "$t" ] || continue
  id=$(basename "$t" .jsonl)
  cwd=$(grep -a -m1 '"cwd":' "$t" | jq -r '.cwd // empty' 2>/dev/null)
  command -v cygpath > /dev/null 2>&1 && [ -n "$cwd" ] && cwd=$(cygpath -u "$cwd")
  if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then echo "skip ${id:0:8} (folder gone: $cwd)"; continue; fi
  k=$((k + 1))
  printf '%2d. %s  %-12s %s  %s\n' "$k" "${id:0:8}" "$(ago "$used")" "${cwd/#$HOME/~}" "$(title_of "$t")"
  dirs+=("$cwd")
  sids+=("$id")
done < <(printf '%s\n' ${ranked[@]+"${ranked[@]}"} | sort -rn)

if [ ${#sids[@]} -eq 0 ]; then
  if [ ${#ids[@]} -gt 0 ] || [ -n "$find" ]; then echo "No session to reopen."; else echo "No session to reopen (active in the last $minutes min)."; fi
  exit 0
fi
[ "$list_only" -eq 1 ] && exit 0

# Run by hand in a terminal: ask which ones, since the time window alone often catches one too many
if [ "$pick" -eq 1 ] || { [ "$pick_all" -eq 0 ] && [ ${#ids[@]} -eq 0 ] && [ ${#sids[@]} -gt 1 ] && [ -t 0 ] && [ -t 1 ]; }; then
  printf 'Reopen which? Numbers separated by spaces, Enter for all, q to quit: '
  read -r answer || answer=q
  case "$answer" in q*|Q*) exit 0 ;; esac
  if [ -n "$answer" ]; then
    keep_dirs=()
    keep_sids=()
    for x in $answer; do
      case "$x" in ''|*[!0-9]*) continue ;; esac
      [ "$x" -ge 1 ] && [ "$x" -le ${#sids[@]} ] || continue
      keep_dirs+=("${dirs[$((x - 1))]}")
      keep_sids+=("${sids[$((x - 1))]}")
    done
    [ ${#keep_sids[@]} -gt 0 ] || { echo "Nothing picked."; exit 0; }
    dirs=("${keep_dirs[@]}")
    sids=("${keep_sids[@]}")
  fi
fi

run() {
  if [ -n "${CLAUDE_REOPEN_ECHO:-}" ]; then printf '%s\n' "$*"; else "$@" > /dev/null; fi
}
as_quote() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }
sh_quote() { local q="'\\''"; printf "'%s'" "${1//\'/$q}"; }
resume_cmd() { printf '%s --resume %s' "$CLAUDE_BIN" "$1"; }
print_cmds() {
  local i=0
  while [ $i -lt $n ]; do
    [ "${firsts[$i]}" = 1 ] && echo "# ${groups[$i]/#$HOME/~}"
    echo "cd $(sh_quote "${dirs[$i]}") && $(resume_cmd "${sids[$i]}")"
    i=$((i + 1))
  done
}

n=${#sids[@]}

# One window per repo (the git repo of the session's folder, else the folder), its sessions as
# tabs; repos in the order of their latest session. firsts[i] is 1 when session i opens a window.
groups=()
i=0
while [ $i -lt $n ]; do
  g=$(git -C "${dirs[$i]}" rev-parse --show-toplevel 2>/dev/null) || g=""
  groups+=("${g:-${dirs[$i]}}")
  i=$((i + 1))
done
order_d=()
order_s=()
order_g=()
firsts=()
i=0
while [ $i -lt $n ]; do
  seen=0
  for x in ${order_g[@]+"${order_g[@]}"}; do [ "$x" = "${groups[$i]}" ] && seen=1; done
  if [ $seen -eq 0 ]; then
    j=$i
    while [ $j -lt $n ]; do
      if [ "${groups[$j]}" = "${groups[$i]}" ]; then
        if [ $j -eq $i ]; then firsts+=(1); else firsts+=(0); fi
        order_d+=("${dirs[$j]}")
        order_s+=("${sids[$j]}")
        order_g+=("${groups[$j]}")
      fi
      j=$((j + 1))
    done
  fi
  i=$((i + 1))
done
dirs=("${order_d[@]}")
sids=("${order_s[@]}")
groups=("${order_g[@]}")
if [ "$one_window" -eq 1 ]; then
  firsts=(1)
  i=1
  while [ $i -lt $n ]; do firsts+=(0); i=$((i + 1)); done
fi
windows=0
for x in "${firsts[@]}"; do [ "$x" = 1 ] && windows=$((windows + 1)); done

case "$terminal" in
  ghostty)
    # Typed input is lost while the shell starts, so the tab runs the command itself
    # through a login shell, then stays on a shell once Claude exits
    sh_bin="${SHELL:-/bin/sh}"
    s='tell application "Ghostty"
  activate'
    i=0
    while [ $i -lt $n ]; do
      inner="$(resume_cmd "${sids[$i]}"); exec $(sh_quote "$sh_bin") -l"
      cmd="$(sh_quote "$sh_bin") -lic $(sh_quote "$inner")"
      cfg="{initial working directory:$(as_quote "${dirs[$i]}"), command:$(as_quote "$cmd")}"
      if [ "${firsts[$i]}" = 1 ]; then
        s+="
  set w to new window with configuration $cfg"
      else
        s+="
  new tab in w with configuration $cfg"
      fi
      i=$((i + 1))
    done
    run osascript -e "$s
end tell" || exit 1
    ;;
  iterm)
    s='tell application "iTerm"
  activate'
    i=0
    while [ $i -lt $n ]; do
      cmd="cd $(sh_quote "${dirs[$i]}") && $(resume_cmd "${sids[$i]}")"
      if [ "${firsts[$i]}" = 1 ]; then
        s+="
  set w to (create window with default profile)"
      else
        s+="
  tell w to create tab with default profile"
      fi
      s+="
  tell current session of w to write text $(as_quote "$cmd")"
      i=$((i + 1))
    done
    run osascript -e "$s
end tell" || exit 1
    ;;
  terminal)
    # Terminal.app has no "new tab" verb: "do script" opens a window, Cmd-T a tab in it
    i=0
    while [ $i -lt $n ]; do
      cmd="cd $(sh_quote "${dirs[$i]}") && $(resume_cmd "${sids[$i]}")"
      if [ "${firsts[$i]}" = 1 ]; then
        s="tell application \"Terminal\"
  activate
  do script $(as_quote "$cmd")
end tell"
      else
        s="tell application \"Terminal\" to activate
tell application \"System Events\" to keystroke \"t\" using command down
delay 0.4
tell application \"Terminal\" to do script $(as_quote "$cmd") in selected tab of front window"
      fi
      run osascript -e "$s" || exit 1
      i=$((i + 1))
    done
    ;;
  wezterm)
    # A new window per repo, then its tabs go to the window of the pane that opened it
    i=0
    while [ $i -lt $n ]; do
      if [ "${firsts[$i]}" = 1 ]; then
        if [ -n "${CLAUDE_REOPEN_ECHO:-}" ]; then
          echo "wezterm cli spawn --new-window --cwd ${dirs[$i]} -- $CLAUDE_BIN --resume ${sids[$i]}"
          pane=1
        else
          pane=$(wezterm cli spawn --new-window --cwd "${dirs[$i]}" -- "$CLAUDE_BIN" --resume "${sids[$i]}") || exit 1
        fi
        win=$(wezterm cli list --format json 2>/dev/null | jq -r --arg p "$pane" '.[] | select((.pane_id | tostring) == $p) | .window_id' 2>/dev/null)
        [ -n "${CLAUDE_REOPEN_ECHO:-}" ] && win=1
      elif [ -n "${win:-}" ]; then
        run wezterm cli spawn --window-id "$win" --cwd "${dirs[$i]}" -- "$CLAUDE_BIN" --resume "${sids[$i]}" || exit 1
      else
        run wezterm cli spawn --cwd "${dirs[$i]}" -- "$CLAUDE_BIN" --resume "${sids[$i]}" || exit 1
      fi
      i=$((i + 1))
    done
    ;;
  kitty)
    i=0
    while [ $i -lt $n ]; do
      type=tab
      [ "${firsts[$i]}" = 1 ] && type=os-window
      run kitty @ launch --type="$type" --cwd="${dirs[$i]}" "$CLAUDE_BIN" --resume "${sids[$i]}" || exit 1
      i=$((i + 1))
    done
    ;;
  wt)
    # Windows Terminal windows can be named: one per repo, created by its first tab
    i=0
    while [ $i -lt $n ]; do
      d="${dirs[$i]}"
      command -v cygpath > /dev/null 2>&1 && d=$(cygpath -w "$d")
      w=0
      [ "$one_window" -eq 1 ] || w="claude-${groups[$i]##*/}"
      run wt.exe -w "$w" new-tab -d "$d" "$CLAUDE_BIN" --resume "${sids[$i]}" || exit 1
      i=$((i + 1))
    done
    ;;
  gnome-terminal)
    i=0
    while [ $i -lt $n ]; do
      where=--tab
      [ "${firsts[$i]}" = 1 ] && where=--window
      run gnome-terminal "$where" --working-directory="${dirs[$i]}" -- bash -c "$(resume_cmd "${sids[$i]}"); exec bash" || exit 1
      i=$((i + 1))
    done
    ;;
  justsessions)
    # JustSessions takes no command from outside (no URL scheme, AppleScript or CLI)
    echo
    echo "JustSessions reopens by itself the tabs it had when it quit (Settings > General)."
    echo "For the others, in Projects: double-click the session, or select it and press Resume."
    echo "Or run each of these in a plain terminal tab of JustSessions:"
    print_cmds
    exit 0
    ;;
  print)
    echo
    if [ -n "$app" ]; then
      echo "$app cannot be told to open tabs. Run each of these in its own tab:"
    else
      echo "No terminal I can open tabs in. Run each of these in its own tab:"
    fi
    print_cmds
    exit 0
    ;;
  *)
    echo "Unknown terminal: $terminal (ghostty, iterm, terminal, wezterm, kitty, wt, gnome-terminal, justsessions, print)" >&2
    exit 2
    ;;
esac
if [ "$windows" -gt 1 ]; then
  echo "$n session(s) reopened in $terminal, one window per repo ($windows)."
else
  echo "$n session(s) reopened in $terminal."
fi
