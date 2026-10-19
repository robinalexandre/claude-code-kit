---
name: daily-sync
description: Sets up and checks the daily run of the Claude Code config sync (~/.claude-sync), so each computer picks up what the others left (reminders, handoffs, config) every morning and before its first session of the day. Use when the user says "sync every morning", "daily sync", "schedule the sync", "change the sync time", "is the morning sync on?", "stop the daily sync", or when another skill (reminders) needs the morning run.
---

# Daily sync

The sync engine (`~/.claude-sync/sync.sh`, see `~/.claude-sync/README.md`) does two things each day:

- **First session of the day:** its SessionStart hook waits for a full sync (`sync.sh fresh`, at most about 40 s) before the session starts, so handoff notes and reminders written on another computer are already there. Later sessions that day sync in the background as before.
- **Every morning at a set time (default 09:00):** the computer's own scheduler runs `sync.sh morning`, which syncs and then runs each `~/.claude/skills/*/morning.sh`. That's how the reminders skill notifies the user even when no session is open.

The scheduled run needs the sync engine installed on the computer. It doesn't need Claude Code to be open.

## Turn it on, change the time, turn it off

Scripts are in `~/.claude/skills/daily-sync/` (`$SK` below).

- `bash $SK/schedule.sh status`: whether the daily run is on, at what time, and the day of the last daily sync.
- `bash $SK/schedule.sh on [HH:MM]`: every day at that time (24 h, default `09:00`). Running it again replaces the time.
- `bash $SK/schedule.sh off`

What it creates:

| System | Scheduler | Missed run (computer asleep or off) |
|---|---|---|
| macOS | LaunchAgent `~/Library/LaunchAgents/com.claude-sync.morning.plist` | runs on wake |
| Linux | a `crontab` line ending in `# claude-sync-morning` | skipped; the first session of the day still syncs |
| Windows (Git Bash) | Task Scheduler task `claude-sync-morning` | runs as soon as the computer is back |

On Windows a console window opens for a few seconds while the task runs; that's expected.

Ask the user before turning it on for the first time on a computer, and tell them which time you used.

## Check that it works

1. `bash ~/.claude-sync/sync.sh morning`, then `bash ~/.claude-sync/sync.sh status`: the last log lines show the sync and each `morning:` step.
2. `bash $SK/schedule.sh status` shows the time.
3. If a step failed, the log is `~/.claude-sync/.state/log` (and `morning.log` on macOS).

## Add a morning step to another skill

Put a `morning.sh` at the root of the skill's folder. It runs after the morning sync, with no terminal and no Claude session, so it must be quick, need no input and write nothing to stdout that matters (stdout goes to the sync log).
