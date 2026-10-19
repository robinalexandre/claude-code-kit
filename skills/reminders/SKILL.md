---
name: reminders
description: Leaves a reminder for a later Claude Code session, on this computer or another one, and notifies the user on the desktop and on the phone (Claude mobile app through a scheduled task, or ntfy) every morning and at the first session of the day. Use when the user says "remind me", "rappelle-moi", "tomorrow when I open a session, tell me…", "don't let me forget", "list my reminders", "that reminder is done", or when a SessionStart message lists reminders.
---

# Reminders

A reminder is one Markdown file in `~/.claude-sync/reminders/` (or `$CLAUDE_REMINDERS_DIR`), the config sync repo, so every computer of the user gets it. Scripts are in `~/.claude/skills/reminders/` (`$SK` below).

It needs the sync engine (`~/.claude-sync`) and the daily-sync skill:

- **At session start**, the hook shows the due reminders it already has in the terminal and hands them to you, without waiting: the sync runs in the background. When it brings new ones, they are notified at once and reach you with the user's next message. Remind the user in your next reply, before anything else.
- **Every morning** (09:00 by default), the daily sync runs `morning.sh`, which sends the due reminders to the desktop and the phone, with no session open.
- **At the first session of the day** that has a due reminder, the same notification goes out once.

## Leave a reminder

Write `~/.claude-sync/reminders/<YYYY-MM-DD>-<short-slug>.md`:

```markdown
---
title: <one line the user will read in a notification, in their language>
on: <YYYY-MM-DD, or YYYY-MM-DD HH:MM: when it starts showing>
until: <YYYY-MM-DD: last day it shows (optional)>
where: <repo-specific only: the folder the session must be in, as a path or its tail like "dev/shop"; leave out for a global reminder>
machine: <a name from ~/.claude-sync/machines/ (optional: every computer)>
created: <YYYY-MM-DD HH:MM>
---

<What it is about and what the user wants to do, in their language: people, dates, links, the points to raise.
Enough for a session in a few days, without this conversation, to help.>
```

- **Always ask whether the reminder is global or for one repo/folder**, unless the user already said it: "Global (every session, any repo, any computer) or only in <the folder/repo in question>?", and say which you'd pick and why (work on this repo's code fits the repo; a call, a meeting or an errand is global). Global leaves `where` out. Opening a session in a folder is not a reason to tie the reminder to it. A repo-specific reminder sets `where` to that repo or folder.
- Ask only that and what you can't infer. "Tomorrow" means `on:` the next day; a meeting on a date means `until:` that date. When the user says "this morning" or "now", use today.
- Every new session gets each due reminder (global ones everywhere, repo-specific ones in their folder) until it's done or past `until`.
- Never put secrets in it: the file goes to GitHub.
- Then run `bash ~/.claude-sync/sync.sh now` so the other computers get it, and tell the user when and where it will show up.

## Manage them

- `bash $SK/reminders.sh list`: every reminder with its state (`due`, `later`, `expired`).
- `bash $SK/reminders.sh due [DIR]`: the files due for a session in DIR.
- When the user says a reminder is done or no longer needed: `bash $SK/reminders.sh done <id>` (the file name without `.md`), then `bash ~/.claude-sync/sync.sh now`. Offer to delete expired ones when you see them.

## Notifications

- **Desktop**: macOS notification, Windows toast, `notify-send` on Linux.
- **Phone, first choice: the Claude mobile app.** Always propose this first. It's a recurring Claude Code scheduled task (a cloud routine) that runs every morning in a fresh cloud session, reads the reminders from the sync repo on GitHub and ends with a short summary; its push notification lands in the Claude app. Set it up with the user's yes:
  - A session that a scheduled task creates from scratch gets no repo access, and the private sync repo is refused. So first create a dedicated cloud session with the private sync repo attached (`create_session` with its `source_url`, title "Morning reminders"). Its first message sets its job, read-only, and runs it once as a test:
    - pull the sync repo, and read this skill's `SKILL.md` for the format;
    - list what is due in the user's time zone: `on` not after now, `until` not before today; `where` and `machine` only limit coding sessions;
    - if something is due, send one `PushNotification` (one line, under 200 characters, in the user's language), then one line per reminder; otherwise reply "no reminders today" and send no notification.
  - Then make a daily scheduled task that wakes that session: `create_trigger` with `persistent_session_id`, a cron in the user's time zone (`CRON_TZ=<zone> M H * * *`, default around 09:00), and a short prompt: "run the morning check". Without these tools, the user can do the same at claude.ai/code.
  - Check that the test notification reached the phone.
- **Phone, alternative: [ntfy](https://ntfy.sh)**, when the user doesn't want the Claude app or wants the computer itself to push. They install the ntfy app and subscribe to a topic name that is hard to guess (anyone who knows it can read it); you write it on each computer to `~/.claude/reminders.json`: `{"ntfy": "https://ntfy.sh/<topic>"}` (or a self-hosted server URL). That file stays on the computer.
- Test both with `bash $SK/reminders.sh notify "test"`.
- If the morning run isn't scheduled on this computer (`bash ~/.claude/skills/daily-sync/schedule.sh status`), offer to turn it on with the daily-sync skill.
