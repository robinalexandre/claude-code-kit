#!/bin/bash
# Schedules the daily config sync (sync.sh morning) with the computer's own scheduler, plus a sync
# when the user logs in (so a handoff left to run on this computer starts with no session open).
#   schedule.sh on [HH:MM]   every day at HH:MM (default 09:00), and at login
#   schedule.sh off
#   schedule.sh status
# macOS: LaunchAgents (a run missed while asleep happens on wake; the login one runs at load).
# Linux: crontab lines (the login one at boot).
# Windows (Git Bash): Task Scheduler tasks, the daily one also runs when a missed time comes back.
set -u
SYNC="$HOME/.claude-sync"
NAME=claude-sync-morning
LABEL=com.claude-sync.morning
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGIN_NAME=claude-sync-login
LOGIN_LABEL=com.claude-sync.login
LOGIN_PLIST="$HOME/Library/LaunchAgents/$LOGIN_LABEL.plist"

usage() {
  echo "usage: schedule.sh on [HH:MM] | off | status" >&2
  exit 2
}

valid_time() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }

run_ps() { powershell.exe -NoProfile -NonInteractive -Command "$1"; }

on() {
  local at=${1:-09:00} h m bash_exe script
  valid_time "$at" || usage
  [ -f "$SYNC/sync.sh" ] || {
    echo "No sync engine in $SYNC: install it first." >&2
    exit 1
  }
  h=$((10#${at%:*}))
  m=$((10#${at#*:}))
  case "$(uname -s)" in
    Darwin)
      mkdir -p "$(dirname "$PLIST")" "$SYNC/.state"
      cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>-lc</string><string>bash "\$HOME/.claude-sync/sync.sh" morning</string></array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$h</integer><key>Minute</key><integer>$m</integer></dict>
  <key>StandardOutPath</key><string>$SYNC/.state/morning.log</string>
  <key>StandardErrorPath</key><string>$SYNC/.state/morning.log</string>
</dict>
</plist>
EOF
      launchctl bootout "gui/$(id -u)" "$PLIST" > /dev/null 2>&1
      launchctl bootstrap "gui/$(id -u)" "$PLIST"
      cat > "$LOGIN_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LOGIN_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>-lc</string><string>sleep 30; bash "\$HOME/.claude-sync/sync.sh" run force 60</string></array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$SYNC/.state/login.log</string>
  <key>StandardErrorPath</key><string>$SYNC/.state/login.log</string>
</dict>
</plist>
EOF
      launchctl bootout "gui/$(id -u)" "$LOGIN_PLIST" > /dev/null 2>&1
      launchctl bootstrap "gui/$(id -u)" "$LOGIN_PLIST"
      ;;
    MINGW* | MSYS* | CYGWIN*)
      bash_exe=$(cygpath -w "$(command -v bash)")
      script=$(cygpath -m "$SYNC/sync.sh")
      run_ps "\$a = New-ScheduledTaskAction -Execute '$bash_exe' -Argument '-l \"$script\" morning'
\$t = New-ScheduledTaskTrigger -Daily -At '$at'
\$s = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName '$NAME' -Action \$a -Trigger \$t -Settings \$s -Force | Out-Null" || exit 1
      run_ps "\$a = New-ScheduledTaskAction -Execute '$bash_exe' -Argument '-l \"$script\" run force 60'
\$t = New-ScheduledTaskTrigger -AtLogOn -User \$env:USERNAME
\$t.Delay = 'PT30S'
\$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName '$LOGIN_NAME' -Action \$a -Trigger \$t -Settings \$s -Force | Out-Null" ||
        echo "Could not add the sync at login (the daily one is set)." >&2
      ;;
    *)
      command -v crontab > /dev/null || {
        echo "No crontab on this computer." >&2
        exit 1
      }
      {
        crontab -l 2> /dev/null | grep -v -e "# $NAME\$" -e "# $LOGIN_NAME\$"
        echo "$m $h * * * bash -lc 'bash \"\$HOME/.claude-sync/sync.sh\" morning' # $NAME"
        echo "@reboot sleep 60; bash -lc 'bash \"\$HOME/.claude-sync/sync.sh\" run force 60' # $LOGIN_NAME"
      } | crontab -
      ;;
  esac
  echo "The sync now runs every day at $at, and when you log in."
}

off() {
  case "$(uname -s)" in
    Darwin)
      launchctl bootout "gui/$(id -u)" "$PLIST" > /dev/null 2>&1
      launchctl bootout "gui/$(id -u)" "$LOGIN_PLIST" > /dev/null 2>&1
      rm -f "$PLIST" "$LOGIN_PLIST"
      ;;
    MINGW* | MSYS* | CYGWIN*)
      run_ps "Unregister-ScheduledTask -TaskName '$NAME' -Confirm:\$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName '$LOGIN_NAME' -Confirm:\$false -ErrorAction SilentlyContinue"
      ;;
    *) crontab -l 2> /dev/null | grep -v -e "# $NAME\$" -e "# $LOGIN_NAME\$" | crontab - ;;
  esac
  echo "The daily sync is off."
}

status() {
  local at=""
  case "$(uname -s)" in
    Darwin)
      [ -f "$PLIST" ] && at=$(awk -F'[<>]' '/<key>Hour<\/key>/ { printf "%02d:%02d", $9, $17 }' "$PLIST")
      ;;
    MINGW* | MSYS* | CYGWIN*)
      at=$(run_ps "(Get-ScheduledTask -TaskName '$NAME' -ErrorAction SilentlyContinue).Triggers | ForEach-Object { ([datetime]\$_.StartBoundary).ToString('HH:mm') }" 2> /dev/null | tr -d '\r')
      ;;
    *)
      at=$(crontab -l 2> /dev/null | awk -v n="# $NAME" 'index($0, n) { printf "%02d:%02d", $2, $1 }')
      ;;
  esac
  if [ -n "$at" ]; then echo "on, every day at $at"; else echo "off"; fi
  case "$(uname -s)" in
    Darwin) [ -f "$LOGIN_PLIST" ] && echo "and at login" ;;
    MINGW* | MSYS* | CYGWIN*) run_ps "if (Get-ScheduledTask -TaskName '$LOGIN_NAME' -ErrorAction SilentlyContinue) { 'and at login' }" 2> /dev/null | tr -d '\r' ;;
    *) crontab -l 2> /dev/null | grep -q "# $LOGIN_NAME\$" && echo "and at login (boot)" ;;
  esac
  if [ -f "$SYNC/.state/fresh-day" ]; then echo "last daily sync: $(cat "$SYNC/.state/fresh-day")"; fi
  return 0
}

case "${1:-}" in
  on) on "${2:-}" ;;
  off) off ;;
  status) status ;;
  *) usage ;;
esac
