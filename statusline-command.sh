#!/bin/sh
# Claude Code status line
input=$(cat)
. "$(dirname "$0")/hooks/lib/jq.sh"

# Current working directory
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
[ -z "$cwd" ] && cwd=$(pwd)
command -v cygpath >/dev/null 2>&1 && cwd=$(cygpath -u "$cwd")
# Show only last two path components for brevity
short_dir=$(echo "$cwd" | awk -F/ '{if(NF>=2) print $(NF-1)"/"$NF; else print $NF}')

# Model display name
model=$(echo "$input" | jq -r '.model.display_name // empty')

# Context used percentage (colored: green <50%, yellow 50-79%, red >=80%)
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
if [ -n "$used" ]; then
  used_int=$(printf '%.0f' "$used")
  if [ "$used_int" -ge 80 ]; then
    ctx_str=$(printf '🧠 \033[31m%s%%\033[0m' "$used_int")
  elif [ "$used_int" -ge 50 ]; then
    ctx_str=$(printf '🧠 \033[33m%s%%\033[0m' "$used_int")
  else
    ctx_str=$(printf '🧠 \033[32m%s%%\033[0m' "$used_int")
  fi
fi

# 5-hour rate limit usage (colored like context: green <50%, yellow 50-79%, red >=80%)
# with reset clock time in parentheses
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
if [ -n "$five_pct" ]; then
  five_int=$(printf '%.0f' "$five_pct")
  if [ "$five_int" -ge 80 ]; then
    five_color='\033[31m'
  elif [ "$five_int" -ge 50 ]; then
    five_color='\033[33m'
  else
    five_color='\033[32m'
  fi
  five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
  reset_disp=""
  if [ -n "$five_reset" ]; then
    reset_clock=$(date -d "@$five_reset" +%H:%M 2>/dev/null || date -r "$five_reset" +%H:%M 2>/dev/null)
    [ -n "$reset_clock" ] && reset_disp=$(printf ' (%s)' "$reset_clock")
  fi
  rate_str=$(printf "⏳ ${five_color}%s%%%s\033[0m" "$five_int" "$reset_disp")
fi

# Reasoning effort level (only present when the model supports it)
# colored as a ramp: low blue, medium green, high yellow, xhigh magenta, max red
effort=$(echo "$input" | jq -r '.effort.level // empty')
if [ -n "$effort" ]; then
  case "$effort" in
    low)    eff_color='\033[34m' ;;
    medium) eff_color='\033[32m' ;;
    high)   eff_color='\033[33m' ;;
    xhigh)  eff_color='\033[35m' ;;
    max)    eff_color='\033[31m' ;;
    *)      eff_color='\033[37m' ;;
  esac
  eff_str=$(printf "⚡ ${eff_color}%s\033[0m" "$effort")
fi

# Learning level of this session, written by the learn mod: off, brief, normal or deep
session_id=$(echo "$input" | jq -r '.session_id // empty')
learn_file="$HOME/.claude/learn-levels.json"
if [ -n "$session_id" ] && [ -f "$learn_file" ]; then
  learn=$(jq -r --arg s "$session_id" '.[$s] // empty' "$learn_file" 2>/dev/null | tr -d '\r')
  case "$learn" in
    off)    learn_str=$(printf '💡 \033[2moff\033[0m') ;;
    brief)  learn_str=$(printf '💡 \033[34mbrief\033[0m') ;;
    normal) learn_str=$(printf '💡 \033[32mnormal\033[0m') ;;
    deep)   learn_str=$(printf '💡 \033[33mdeep\033[0m') ;;
  esac
fi

# Do-not-disturb profile on for this session, written by the dnd mod; shown only while one is on,
# with what turned it on (this session, this computer, or a rule, which every computer gets) and its end
dnd_file="$HOME/.claude/.dnd/active.json"
if [ -n "$session_id" ] && [ -f "$dnd_file" ]; then
  dnd=$(jq -r --arg s "$session_id" '.[$s] // empty | select((.profile // "") != "" and .profile != "none")
    | .profile + (if (.scope // "") != "" then " · " + .scope else "" end)
    + (if (.untilText // "") != "" then " (" + .untilText + ")" else "" end)' "$dnd_file" 2>/dev/null | tr -d '\r')
  [ -n "$dnd" ] && dnd_str=$(printf '🔕 \033[35m%s\033[0m' "$dnd")
fi

# The kit's low power mode, as the configuration mod last wrote it: on, or on battery and the
# computer on its battery or in its low power mode, checked here on macOS and Linux, else as written
power_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.low-power.json"
if [ -f "$power_file" ]; then
  power_setting=$(jq -r '.setting // empty' "$power_file" 2>/dev/null | tr -d '\r')
  power_low=$(jq -r '.lowPower // false' "$power_file" 2>/dev/null | tr -d '\r')
  if [ "$power_setting" = "on battery" ]; then
    if command -v pmset >/dev/null 2>&1; then
      power_low=false
      pmset -g batt 2>/dev/null | grep -q "'Battery Power'" && power_low=true
      pmset -g 2>/dev/null | grep -Eq 'lowpowermode[[:space:]]+1' && power_low=true
    elif [ -d /sys/class/power_supply ]; then
      for supply in /sys/class/power_supply/*; do
        [ "$(cat "$supply/type" 2>/dev/null)" = Mains ] || continue
        if [ "$(cat "$supply/online" 2>/dev/null)" = 0 ]; then power_low=true; else power_low=false; fi
      done
    fi
  fi
  [ "$power_setting" = off ] && power_low=false
  [ "$power_low" = true ] && power_str=$(printf '🔋 \033[33mlow power\033[0m')
fi

# Git branch (skip optional lock, non-fatal); detached HEAD falls back to the short SHA
branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
[ -z "$branch" ] && branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)

# Linked worktree: its git dir lives under <main>/.git/worktrees/<name>, so it differs from the common dir
git_dir=$(git -C "$cwd" --no-optional-locks rev-parse --absolute-git-dir 2>/dev/null)
git_common=$(git -C "$cwd" --no-optional-locks rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -n "$git_dir" ] && [ -n "$git_common" ] && [ "$git_dir" != "$git_common" ]; then
  branch_str=$(printf '🌳 \033[32m%s\033[0m \033[33m[worktree]\033[0m' "$branch")
elif [ -n "$branch" ]; then
  branch_str=$(printf '🌿 \033[32m%s\033[0m' "$branch")
fi

# Build output
out=""
[ -n "$short_dir" ]  && out="$out $(printf '📁 \033[36m%s\033[0m' "$short_dir")"
[ -n "$branch_str" ] && out="$out $branch_str"
[ -n "$model" ]      && out="$out $(printf '🤖 \033[35m%s\033[0m' "$model")"
[ -n "$ctx_str" ]   && out="$out $ctx_str"
[ -n "$eff_str" ]   && out="$out $eff_str"
[ -n "$rate_str" ]  && out="$out $rate_str"
[ -n "$learn_str" ] && out="$out $learn_str"
[ -n "$dnd_str" ]   && out="$out $dnd_str"
[ -n "$power_str" ] && out="$out $power_str"

# Trim leading space
out="${out# }"

printf '%s' "$out"
