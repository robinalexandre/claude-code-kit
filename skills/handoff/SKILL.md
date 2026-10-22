---
name: handoff
description: Write a handoff note so the user can continue the current work on their other computer, or pick up a note written there. Use when the user says "handoff", "hand off", "I'll continue on the PC / on the Mac / at work / at home", "pick up the handoff", "continue what I started on the other machine", or when a SessionStart message lists open handoff notes and the user wants to resume one.
---

# Handoff between computers

Notes live in `~/.claude-sync/handoffs/`, a git repo that syncs the Claude Code config between the user's computers (see `~/.claude-sync/README.md`). The other computer only sees what is in that repo and on GitHub, nothing else from this one.

## Write a note

1. Check the code first. In each repo involved, run `git status` and `git log @{u}..` to find uncommitted or unpushed work. The other computer can't see it until it is pushed. Tell the user what is unpushed, say what you'd commit and push (and what you'd leave out, such as a half-done experiment), and ask; never push without their yes.
2. Write `~/.claude-sync/handoffs/<YYYY-MM-DD>-<short-slug>.md`:

   ```markdown
   ---
   title: <one line: what this work is>
   from: <contents of ~/.claude-sync/.machine>
   date: <YYYY-MM-DD HH:MM>
   repo: <GitHub owner/name, or "none">
   branch: <branch, or "none">
   ---

   ## Goal
   ## Where it stands
   ## Decisions made (and why)
   ## Next steps
   ## Open questions
   ```

   Keep it short and concrete: PR and ticket numbers, commands to run, files as repo-relative paths. Say what the user already approved or rejected so the next session doesn't ask again.
3. Never put secrets in the note: tokens, passwords, API keys, connection strings, customer data. Say where they live instead ("the Brevo key is in the Brevo MCP config"). The sync refuses to push anything that looks like a key, and the note would stay stuck on this machine.
4. Run `bash ~/.claude-sync/sync.sh now` so the note reaches GitHub right away, and tell the user it's ready to pick up on the other computer.

## Pick up a note

1. Run `bash ~/.claude-sync/sync.sh now` to get the latest notes.
2. List `~/.claude-sync/handoffs/*.md`. If several are open, ask which one, and suggest the likeliest (the one for the current repo, or the newest).
3. Read it, then get the code in place: clone or fetch the repo and check out the branch. If that would switch branches or touch uncommitted local work, ask first.
4. Sum up the goal and the next step in a few lines, and continue from there. If something in the note no longer holds (the code or the PR moved on, a next step now looks wrong), say so before carrying on.
5. Once the user is continuing the work, close the note so it stops showing up at session start: `bash <this skill's folder>/handoff.sh done <id>` (the file name without `.md`; the folder is `~/.claude/skills/handoff/`, or the handoff plugin's). It moves to `handoffs/done/`.

## Manage notes

- `handoff.sh cancel <id>`: a note no one will pick up; it moves to `done/`, marked canceled.
- `handoff.sh delete <id>`: deletes a note, a done one too. `done/` keeps notes 60 days.
- `handoff.sh restore <id>`: opens a done or canceled note again.
- `handoff.sh json`: every note, open and done, as JSON. The [reminders-handoffs](../../mods/reminders-handoffs) mod reads it: `/handoffs`, or the button above the prompt, with `pick` to pick one up now.
- After any of these, `bash ~/.claude-sync/sync.sh now` so the other computer sees it.
