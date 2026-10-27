#!/bin/bash
# Claude Code status line
# Every process costs hundreds of milliseconds in Git Bash on Windows, so one jq call reads the input
# and the files the mods write, and one git call reads the branch: no $(…) around echo, printf or awk.
. "$(dirname "$0")/hooks/lib/jq.sh"

claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# Learning level of this session, written by the learn mod: off, brief, normal or deep
learn_file="$HOME/.claude/learn-levels.json"
# Do-not-disturb profile on for this session, written by the dnd mod; shown only while one is on,
# with what turned it on (this session, this computer, or a rule, which every computer gets) and its end
dnd_file="$HOME/.claude/.dnd/active.json"
# The kit's low power mode, as the configuration mod last wrote it
power_file="$claude_dir/.low-power.json"
files=()
[ -f "$learn_file" ] && files+=(--rawfile learn "$learn_file")
[ -f "$dnd_file" ] && files+=(--rawfile dnd "$dnd_file")
[ -f "$power_file" ] && files+=(--rawfile power "$power_file")

# Line 1: the working directory. Line 2: model, context, effort, 5-hour limit, learning level and
# do-not-disturb, colored. Lines 3-4: the low power setting and state.
# Context and 5-hour limit: green <50%, yellow 50-79%, red >=80%. Effort: low blue, medium green,
# high yellow, xhigh magenta, max red.
{
  IFS= read -r cwd
  IFS= read -r segments
  IFS= read -r power_setting
  IFS= read -r power_low
} < <(jq -r ${files[@]+"${files[@]}"} '
  def paint($code; $s): "\u001b[\($code)m\($s)\u001b[0m";
  def ramp: if . >= 80 then "31" elif . >= 50 then "33" else "32" end;
  def file($k): ($ARGS.named[$k] // "" | try fromjson catch null) // {};
  (.session_id // "") as $sid
  | ((.context_window.used_percentage | numbers | round) // null) as $ctx
  | (.rate_limits.five_hour // {}) as $five
  | (($five.used_percentage | numbers | round) // null) as $rate
  | (($five.resets_at | tonumber? | strflocaltime("%H:%M")) // null) as $reset
  | (.effort.level // "" | strings) as $effort
  | ((if $sid == "" then null else file("learn")[$sid] end | strings) // "") as $learn
  | (if $sid == "" then null else file("dnd")[$sid] end) as $dnd
  | file("power") as $power
  | (.workspace.current_dir // .cwd // ""),
    ([ (.model.display_name // empty | "🤖 " + paint("35"; .)),
       ($ctx // empty | "🧠 " + paint(ramp; "\(.)%")),
       (if $effort == "" then empty else "⚡ " + paint({low: "34", medium: "32", high: "33", xhigh: "35", max: "31"}[$effort] // "37"; $effort) end),
       ($rate // empty | "⏳ " + paint(ramp; "\(.)%" + (if $reset then " (\($reset))" else "" end))),
       ({off: paint("2"; "off"), brief: paint("34"; "brief"), normal: paint("32"; "normal"), deep: paint("33"; "deep")}[$learn] // empty | "💡 " + .),
       ($dnd // empty | objects | select((.profile // "") != "" and .profile != "none")
         | "🔕 " + paint("35"; .profile + (if (.scope // "") != "" then " · " + .scope else "" end)
             + (if (.untilText // "") != "" then " (" + .untilText + ")" else "" end)))
     ] | join(" ")),
    ($power.setting // ""),
    ($power.lowPower // false)
' 2> /dev/null)
[ -z "$cwd" ] && cwd=$PWD

# Show only the last two path components for brevity
dir=${cwd//\\//}
dir=${dir%/}
case "$dir" in
  */*) short_dir="${dir%/*}"; short_dir="${short_dir##*/}/${dir##*/}" ;;
  *) short_dir=$dir ;;
esac

# "on battery": the computer on its battery or in its low power mode, checked here on macOS and
# Linux, else as the configuration mod wrote it
if [ "$power_setting" = "on battery" ]; then
  if command -v pmset > /dev/null 2>&1; then
    power_low=false
    pmset -g batt 2> /dev/null | grep -q "'Battery Power'" && power_low=true
    pmset -g 2> /dev/null | grep -Eq 'lowpowermode[[:space:]]+1' && power_low=true
  elif [ -d /sys/class/power_supply ]; then
    for supply in /sys/class/power_supply/*; do
      [ "$(cat "$supply/type" 2> /dev/null)" = Mains ] || continue
      if [ "$(cat "$supply/online" 2> /dev/null)" = 0 ]; then power_low=true; else power_low=false; fi
    done
  fi
fi
[ "$power_setting" = off ] && power_low=false

# Git branch, detached HEAD as the short SHA. A linked worktree's git dir lives under
# <main>/.git/worktrees/<name>, so it differs from the common dir. rev-parse prints HEAD both for a
# detached HEAD and an unborn branch, whose name only branch --show-current gives.
{
  IFS= read -r git_dir
  IFS= read -r git_common
  IFS= read -r branch
} < <(git -C "$cwd" --no-optional-locks rev-parse --absolute-git-dir --path-format=absolute --git-common-dir \
  --abbrev-ref HEAD 2> /dev/null)
if [ -n "$git_dir" ] && { [ -z "$branch" ] || [ "$branch" = HEAD ]; }; then
  branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2> /dev/null) ||
    branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2> /dev/null)
fi

e=$'\033'
out="📁 $e[36m$short_dir$e[0m"
if [ -n "$git_dir" ] && [ -n "$git_common" ] && [ "$git_dir" != "$git_common" ]; then
  out="$out 🌳 $e[32m$branch$e[0m $e[33m[worktree]$e[0m"
elif [ -n "$branch" ]; then
  out="$out 🌿 $e[32m$branch$e[0m"
fi
[ -n "$segments" ] && out="$out $segments"
[ "$power_low" = true ] && out="$out 🔋 $e[33mlow power$e[0m"
# The private sync paused on this computer (sync.sh pause): shown last, until sync.sh resume
[ -f "${SYNC_DIR:-$HOME/.claude-sync}/.state/paused" ] && out="$out ⏸️  $e[33msync paused$e[0m"

printf '%s' "$out"
