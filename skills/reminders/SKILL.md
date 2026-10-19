---
name: reminders
description: Leaves a reminder for a later Claude Code session, on this computer or another one, and notifies the user on the desktop and the phone every morning and at the first session of the day. Use when the user says "remind me", "rappelle-moi", "tomorrow when I open a session, tell me…", "don't let me forget", "list my reminders", "that reminder is done", or when a SessionStart message lists reminders.
---

# Reminders

A reminder is one Markdown file in `~/.claude-sync/reminders/` (or `$CLAUDE_REMINDERS_DIR`), the config sync repo, so every computer of the user gets it. Scripts are in `~/.claude/skills/reminders/` (`$SK` below).

It needs the sync engine (`~/.claude-sync`) and the daily-sync skill:

- **At session start**, the hook waits for the day's first sync, then shows the due reminders for the session's folder in the terminal and hands them to you. Remind the user in your first reply, before anything else.
- **Every morning** (09:00 by default), the daily sync runs `morning.sh`, which sends the due reminders to the desktop and the phone, with no session open.
- **At the first session of the day** that has a due reminder, the same notification goes out once.

## Leave a reminder

Write `~/.claude-sync/reminders/<YYYY-MM-DD>-<short-slug>.md`:

```markdown
---
title: <one line the user will read in a notification, in their language>
on: <YYYY-MM-DD, or YYYY-MM-DD HH:MM: when it starts showing>
until: <YYYY-MM-DD: last day it shows (optional)>
where: <folder the session must be in, as a path or its tail like "dev/shop" (optional: every session)>
machine: <a name from ~/.claude-sync/machines/ (optional: every computer)>
created: <YYYY-MM-DD HH:MM>
---

<What it is about and what the user wants to do, in their language: people, dates, links, the points to raise.
Enough for a session in a few days, without this conversation, to help.>
```

- Ask only what you can't infer. "Tomorrow" means `on:` the next day; a meeting on a date means `until:` that date. When the user says "this morning" or "now", use today.
- `where` takes the folder the user named ("in that folder", "in the shop repo"). Leave it out when they want it everywhere.
- Never put secrets in it: the file goes to GitHub.
- Then run `bash ~/.claude-sync/sync.sh now` so the other computers get it, and tell the user when and where it will show up.

## Manage them

- `bash $SK/reminders.sh list`: every reminder with its state (`due`, `later`, `expired`).
- `bash $SK/reminders.sh due [DIR]`: the files due for a session in DIR.
- When the user says a reminder is done or no longer needed: `bash $SK/reminders.sh done <id>` (the file name without `.md`), then `bash ~/.claude-sync/sync.sh now`. Offer to delete expired ones when you see them.

## Notifications

- **Desktop**: macOS notification, Windows toast, `notify-send` on Linux.
- **Phone**: through [ntfy](https://ntfy.sh). The user installs the ntfy app, subscribes to a topic name that is hard to guess (anyone who knows it can read it), and you write it on each computer to `~/.claude/reminders.json`: `{"ntfy": "https://ntfy.sh/<topic>"}` (or a self-hosted ntfy server URL). That file stays on the computer. Without it, only the desktop gets notified.
- Test both with `bash $SK/reminders.sh notify "test"`.
- If the morning run isn't scheduled on this computer (`bash ~/.claude/skills/daily-sync/schedule.sh status`), offer to turn it on with the daily-sync skill.
