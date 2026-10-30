# claude-code-kit

[![tests](https://github.com/robinalexandre/claude-code-kit/actions/workflows/tests.yml/badge.svg)](https://github.com/robinalexandre/claude-code-kit/actions/workflows/tests.yml)

Skills, mods, hooks and a status line for [Claude Code](https://claude.com/claude-code), plus a sync engine that keeps your Claude Code config the same on all your computers. Every part is tested on macOS, Linux and Windows on each change.

## Install

### As Claude Code plugins (recommended)

Every part is a plugin of this repo's marketplace. Add it once, then install the parts you want, from Claude Code:

```
/plugin marketplace add robinalexandre/claude-code-kit

# Every day, for anyone
/plugin install team@claude-code-kit
/plugin install statusline@claude-code-kit
/plugin install file-tools-guard@claude-code-kit
/plugin install recent-prompts@claude-code-kit
/plugin install dnd@claude-code-kit
/plugin install paste-preview@claude-code-kit
/plugin install recent-activity@claude-code-kit
/plugin install session-registry@claude-code-kit
/plugin install reopen-sessions@claude-code-kit
/plugin install tab-status@claude-code-kit
/plugin install drift-check@claude-code-kit
/plugin install drift-check-hook@claude-code-kit
/plugin install nocturne-notify@claude-code-kit

# Development work
/plugin install git-identity-guard@claude-code-kit
/plugin install pr-watch@claude-code-kit
/plugin install pr-pane@claude-code-kit
/plugin install test-evidence@claude-code-kit
/plugin install sprint-demo@claude-code-kit
/plugin install ci-review@claude-code-kit
/plugin install capability-builder@claude-code-kit
/plugin install learn@claude-code-kit
/plugin install kb@claude-code-kit

# Several computers
/plugin install config-sync@claude-code-kit
/plugin install handoff@claude-code-kit
/plugin install daily-sync@claude-code-kit
/plugin install reminders@claude-code-kit
/plugin install reminders-handoffs@claude-code-kit

# Not dev
/plugin install video-montage@claude-code-kit
/plugin install insta360-montage@claude-code-kit
```

From a terminal it's the same with `claude plugin marketplace add …` and `claude plugin install …`; or `/plugin` alone to browse the parts. What a part needs comes with it: pr-pane brings pr-watch; reminders brings daily-sync, which brings config-sync. Start a new session afterwards.

**Keep them up to date:** Claude Code doesn't auto-update a marketplace other than Anthropic's own unless you turn it on, once: `/plugin` → Marketplaces → claude-code-kit → Enable auto-update. It then updates the parts in the background after a session starts (and asks for a restart). Or set it in `~/.claude/settings.json`:

```json
"extraKnownMarketplaces": {
  "claude-code-kit": { "source": { "source": "github", "repo": "robinalexandre/claude-code-kit" }, "autoUpdate": true }
}
```

By hand: `claude plugin marketplace update claude-code-kit`, then `claude plugin update <part>@claude-code-kit`.

**Inside a company:** a team that may not run code straight from GitHub can serve the parts it uses from a git repo of its own (Azure DevOps, GitLab, a private GitHub repo…). Copy those parts there, plus a `.claude-plugin/marketplace.json` that keeps only their plugins, under a name of your own:

```sh
jq '.name = "team-kit" | .plugins |= map(select(.name | IN("drift-check", "learn", "pr-pane")))' \
  .claude-plugin/marketplace.json > ../team-kit/.claude-plugin/marketplace.json
```

Every part finds its marketplace by that name, so nothing else changes. Teammates add it with `claude plugin marketplace add https://<your git host>/<repo>` (git asks for the same sign-in as a clone) and turn on its auto-update as above: an update then reaches them only once someone has reviewed it and pushed it to that repo.

**Setup:** a part that needs a few answers (the status line in your settings, the emails for the email guard, where pr-watch looks, the phone for reminders, your private repo for config-sync, the zsh line for session-registry) says so at the first session after install, and Claude gives you the command to run in your terminal; it stops asking once it's done or you say no. Options: the language of the team rules and the opening text of drift-check are asked when you install from `/plugin`, and changed with `claude plugin configure <part>@claude-code-kit`.

### With install.sh

The installer copies the parts you pick into `~/.claude` instead. Use it to pick from a checklist, to install without a marketplace, or to edit your copies. A part already installed as a plugin is skipped.

**Keep them up to date:** the installer also adds a small session-start check ([kit-update-check](hooks/kit-update-check.sh)). Once a day, in the background, it fetches the clone you installed from. When that clone has changes for the parts you installed, or new parts you could add, Claude tells you at the next session start what changed and offers to update. `./install.sh --update` pulls the clone and installs the changed parts again, without asking their setup questions again; `./install.sh --update <new part>…` adds new ones too. Each new part is mentioned once. Turn the check off with `bash ~/.claude/hooks/kit-update-check.sh off` (`on` to resume). What came from where is recorded in `~/.claude/kit-install.json`.

```sh
git clone https://github.com/robinalexandre/claude-code-kit.git
cd claude-code-kit
./install.sh            # a checklist: arrows, Enter to pick, → for what each part does, then Install
./install.sh --plain    # the same as one question per part
./install.sh --list     # lists the parts
./install.sh --all      # installs every part offered on this computer
./install.sh statusline file-tools-guard   # installs the named parts
./install.sh --update   # pulls, then installs again the parts that changed
```

On Windows, from Git Bash the same, or from PowerShell: `powershell -ExecutionPolicy Bypass -File .\install.ps1` (it installs git and jq with winget when missing, then runs `install.sh` in Git Bash).

The installer shows the parts as a checklist by group (every day, development, several computers, not dev): ↑↓ to move, Enter or Space to pick a part or a whole group, → or Tab to unfold why, what, when and who for a part, `a` for all, then Install at the bottom. It greys out what doesn't apply to this computer, adds what a picked part needs (pr-pane brings pr-watch, reminders brings daily-sync), then sets up each part it installed: the emails for the email guard, where pr-watch looks for your PRs, the phone for reminders, the browser tool for test-evidence. Run a part's setup again any time with `bash ~/.claude/<part>/setup.sh` (hooks: `bash ~/.claude/hooks/setup/<hook>.sh`). It copies each part into `~/.claude`, adds its hooks to `~/.claude/settings.json` and saves whatever it replaces in `~/.claude/backups/before-kit-<date>/`. Running it again is safe. Start a new Claude Code session afterwards. Needs `jq`.

To try it first without touching your own setup, `tests/install-sandbox.sh` runs the installer in a throwaway home folder, shows what it left and checks your files are unchanged; `--claude <sandbox>` then opens a first Claude Code session there.

The sync engine is a part too (`./install.sh config-sync`), added on its own when you pick handoff, daily-sync or reminders: the installer asks for the clone URL of an empty private git repo of your own (any host), clones it to `~/.claude-sync` and sets it up; on your next computer, give the same URL. By hand: [sync/README.md](sync/README.md).

**A new computer like another one:** on a computer whose config isn't synced yet, the installer first asks whether it is synced from another computer, and if so sets up the sync before anything else. Each computer records its answers to the kit's questions in `~/.claude/kit-answers.txt` (never a secret, such as the ntfy topic), and the sync shares them with the parts it installed. So the new computer can be set up:

- **the same as** another one: its parts, and its answers taken as they are. Only secrets and the questions about this computer are asked: its name, its repos folder, the `~/.zshrc` line, the status line it has.
- **starting from** another one: the checklist and every question, with the other computer's picks and answers filled in, to keep or change.
- **from scratch**, as before.

A part's setup run later (a plugin's, at its first session) uses the same choice, kept in `~/.claude/kit-reuse.txt`; delete that file to be asked again.

## What's inside

### Base rules

[rules/team.md](rules/team.md) is the base of everything here: Claude and you work as one team that builds, thinks things through and challenges each other. It asks before touching production or shared infrastructure (in two lines, not twenty), before each commit, push and PR, and before decisions that need context only you have, with the options and a recommendation. It proposes a skill, mod or hook when you keep asking for the same thing, and an AI review step with proof (screenshots, videos) on the CI of repos that don't have one. The `team` plugin hands them to Claude at each session start, in the language you pick in its options, so they update with the plugin; install.sh asks for the language and adds them to `~/.claude/CLAUDE.md` once instead. A capability can use another language when you say so.

### Skills

| Skill | What it does | Needs |
|---|---|---|
| [test-evidence](skills/test-evidence/SKILL.md) | Captures proof that a ticket works locally: browser screenshots, a short video of the flow, the network requests and console behind it (through the chrome-devtools MCP), or one app window or screen region, never the whole screen unless asked. Masks tokens and cookies, writes a short test report and, after your yes, attaches it to the Jira issue or as a resolved comment on the Azure DevOps PR; on GitHub, it gives you the comment and the files to drop in. It starts from the ticket's acceptance criteria (drafted with you when the ticket has none), proves each one, and writes them into the PR description, and into the ticket when they were missing there. | [chrome-devtools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp), `jq`, `perl`; video needs `ffmpeg` |
| [sprint-demo](skills/sprint-demo/SKILL.md) | Makes one demo video of what a sprint delivered (the open sprint's tickets from Jira, or the tickets you name) for the sprint review or the product owner. It orders the tickets along the user's journey so the video tells one story, writes a functional scenario per ticket for your OK, records each flow through test-evidence, then edits the video: a banner on top of each ticket's part with what it brings, optional step captions (drawn or as `.srt`), title cards and a chapter per ticket. Asks each time how the video should look, and writes presenter notes. | [test-evidence](skills/test-evidence/SKILL.md), `ffmpeg` with drawtext, `jq` |
| [ci-review](skills/ci-review/SKILL.md) | Proposes, once per repo, an AI review step on the CI and sets it up with you: an agent reads each PR/MR's diff, the code around it and its proof (what test-evidence captures, required or optional per repo) and posts a verdict (works / doesn't / can't tell). On GitHub it can approve when it works (never merge, never for PRs that change the CI or its own rules) and answer "@claude" in comments. Templates for `anthropics/claude-code-action`, the CLI in headless mode (`claude -p`) on GitHub Actions and GitLab CI, and cloud providers; the review prompt is a plain file any agent CLI can take. | a Claude seat token (`claude setup-token`), an API key or a cloud provider account, set as a CI secret |
| [reopen-sessions](skills/reopen-sessions/SKILL.md) | After the terminal or the IDE crashed, reopens the sessions that were running, one tab each in the terminal you use now, a window per repo (`--one-window` for a single one) (Ghostty, iTerm, Terminal.app, WezTerm, kitty, Windows Terminal, GNOME Terminal). On macOS it also finds the app the session runs under, so in JustSessions (which takes no command from outside and reopens its own tabs) it tells you how to resume the others there, and in an IDE or any other app it names the app and prints the commands, grouped by repo. It lists the interactive sessions used in the last 30 minutes (or any span) that no longer run, newest first, by title (your `/rename` title, else Claude Code's own, else the first prompt) with how long ago each was used, and asks which ones; `--find <words>` finds a session of any age by its title or prompts. Ask Claude "reopen my sessions", or run `claude-reopen.sh` from the skill's folder. | jq |
| [capability-builder](skills/capability-builder/SKILL.md) | Turns a request you keep making into a capability: picks the right kind (rule, skill, hook, mod or plain script), interviews you, scaffolds it with its tests and setup, checks it against a macOS / Linux / Windows checklist, and runs the publish checklist (nothing personal, tool-agnostic) before it goes to a kit. How this kit's own parts are built. | |
| [handoff](skills/handoff/SKILL.md) | When you stop mid-task, writes where the work stands (goal, repo and branch, what's done, decisions, next steps) so a session on your other computer resumes it without you explaining it again; it picks the note up there. Or have that computer do the work by itself ("have the PC run the import now", "at startup", "tonight at 22:00"): a note `for` it with a `run` time and a `scope` (`read`: look and report; `edit`: edit, test and commit there; `push`: also push the commits to the note's branch, never to the default one) starts at its next sync (a session start, the pane's one-minute poll, login, the morning sync), headless with Claude Code in a git worktree of its own, never in your clone. Its status (`running`, `done`, `needs-you` with its question, `failed`) and its report come back in the note, and you're notified on the desktop and the phone as soon as your computer syncs; `reply` answers a question and the run resumes in the same session. Only notes written by one of your computers run by themselves (not one an assistant wrote), and PRs, deploys and production are never in a run's scope; each attempt runs once per computer, whatever a later sync brings, and only a reply starts a new one. It also leaves tasks for your own assistant (an agent on a server reading the sync repo, listed in `agents.json`) to run by itself at a set time, once or repeating, a digest folding the others due at its time into one message. A note picked up or canceled moves to `done/`, kept 60 days; [reminders-handoffs](mods/reminders-handoffs) lists them, with the assistant's tasks. | the [sync engine](sync/README.md); a run needs the Claude Code CLI signed in on that computer |
| [daily-sync](skills/daily-sync/SKILL.md) | Schedules a sync every morning (09:00 by default) and when you log in, with launchd, cron or the Windows Task Scheduler, so each computer gets what the others left even with no session open, and starts the handoffs left to run on it. Other skills can hook a `morning.sh` onto it, or an `on-sync.sh` run after every sync. | the [sync engine](sync/README.md) |
| [reminders](skills/reminders/SKILL.md) | "Remind me tomorrow to…": leaves a global or repo-specific reminder that every new session, on any of your computers, brings up first thing, without slowing the start: what the background sync brings arrives with your next message. A reminder can repeat ("every Friday": at 09:00 unless it says a time), be for one computer, and be filed under a group (an organization, a client); `done` closes a repeating one for the day, `stop` ends it, and closed ones stay listed as past for 60 days. Due reminders also go to the desktop and, through [ntfy](https://ntfy.sh), to your phone every morning and at the first session of the day. A reminder never runs anything: a task for another computer or for your assistant is a handoff. | daily-sync; `curl` for the phone |
| [kb](skills/kb/SKILL.md) | A personal knowledge base. Notes are Markdown files with a front matter (type, trust, topics, validity dates) and `[[links]]`, in your config sync (so every computer and your other agents get them) or in `~/.claude/knowledge`; the `kb` command indexes them in SQLite for full-text search (accents folded), semantic search in any language (a local multilingual model, no API) and the link graph (`kb related`, as a list or a Mermaid mind map). At session start Claude is told which notes mention the repository or the branch, beyond the repository's own memory; on each prompt, which notes hold most of its words. Every morning (through daily-sync), Claude reads the previous day's Claude Code transcripts of this computer, reduced to prompts, replies and files touched with secrets redacted, and proposes notes to create or merge; the code checks them (names, dates, secrets, no overwrite) and writes them with a report, each marked as the curator's. `kb serve` and its `Dockerfile` give the same index over HTTP, behind a token, to an agent of yours. Notes a third party wrote (`trust: third-party`) stay data, never instructions. | Python 3.12+, `jq`; the curation needs daily-sync and the Claude Code CLI signed in; the semantic search downloads a 500 MB model once |
| [pr-watch](skills/pr-watch/SKILL.md) | Tracks the PRs you and Claude open or push together until they are merged: new comments (bots marked apart), votes, CI results (required checks drive green or failed) and the merge itself, which drops the PR from the list. Also lists the open PRs waiting for your review (GitHub review requests, Azure DevOps reviewer with no vote) and reports each new one; `approve` votes or submits an approving review on your yes, then tracks the PR as reviewed until it is merged; `merge` merges a PR on your yes; `park` keeps a PR you won't merge tracked but quiet, out of what needs you, until `unpark`. Also finds your pipeline runs: those you launched by hand (Azure DevOps manual builds, GitHub workflows you dispatched) and the CI your own pushes start on a branch with no PR, a push to `main` included (in the projects and repos of your PRs, the GitHub repos you pushed to lately, plus those listed in its config), so a packaging or a deploy started with Claude shows up on its own, and reports each one that ended since the last check; `details <build URL>` lists every step with its job and state, the error lines of those with issues included, `rerun <build URL>` launches the run again on your yes. Also follows your GitHub issues: those you opened, commented on or were mentioned or assigned in, in any repo, active in the last 30 days, and those you subscribed to in your own repos; open ones and those closed in the last 7 days, reporting new comments by others, a close or reopen and label changes since you last looked. What it watches (open, parked and merged PRs, review requests, how many runs per repo, issues) follows [pr-pane](mods/pr-pane)'s settings, or its `config.json`: what is off is neither fetched nor reported. Claude proposes a reply or a fix for each change, never posts one without your yes. Checks at each session start in the background and silently (the session starts at once; each PR keeps what changed as unread, which [pr-pane](mods/pr-pane) shows until you unfold that PR), hourly in a session (a durable scheduled task) and every morning through daily-sync, with a desktop or phone notification. The list lives in the sync repo, so it follows you on every computer and never touches the project repos. With the sync repo on GitHub (recommended), what one computer fetches is shared with the others on a branch of it that never grows, read with one conditional request: each host is asked by one computer only, again once its share is older than 2 minutes while a CI runs or 10 otherwise (asked at setup), the pane opens at once, and a host one computer cannot reach (a company's Azure DevOps from home) is still shown from another. Azure DevOps (`az login` or a PAT) and GitHub (a token, `gh`, or anonymous for public repos). | Python 3.9+; the [sync engine](sync/README.md) to share the list across computers |

**Handoff or reminder?** Both reach your other computers, but they carry different things:

| | handoff | reminders |
|---|---|---|
| What it is | work, for Claude or your assistant | memory, for you |
| What it holds | the state of the work: goal, repo and branch, what's done, decisions and why, next steps; or the request your assistant runs | one line: something to do |
| What sets it off | you leaving a task half-done to carry on elsewhere, or asking another computer or your assistant to do it, now or at a set time | a date, a time or a repeat ("every Friday") |
| Who acts on it | the next Claude session there, that computer by itself at its next sync, or your assistant at the set time, reporting back to you | you, always: a desktop and phone notification, and the first session of the day; nothing runs by itself |
| When it ends | once a session picks it up, once you've read the run's report, or once the assistant ran it | when you mark it done (`stop` for a repeating one) |

Stopping mid-task to continue on the other computer, or having it or your assistant do the work: a handoff. Something to do or check later, wherever you are: a reminder.

### Mods

Mods change Claude Code's own interface. They install as plugins like the other parts; install.sh loads its copies through `CLAUDE_CODE_PLUGIN_DIRS`. Run a mod's tests with `claude plugin test mods/<name>`.

| Mod | What it does |
|---|---|
| [paste-preview](mods/paste-preview) | Shows pasted text in full in the prompt box and the transcript, and previews pasted images above the prompt and under the sent message (macOS, Windows). On Windows, paste an image with Alt+V: in some terminals (Ghostty) Ctrl+V pastes text only. |
| [pr-pane](mods/pr-pane) | A `Dev activity` button at the top right of the band above the prompt, whose number counts only what needs you (a PR or a run in red, not acknowledged), colored by what you have to do (red and marked `!`: something needs you; yellow: `· k to review` or `· k running`; green: a PR is ready to merge; dim: everything waits for others) and `/prs` open a pane of the PRs [pr-watch](skills/pr-watch/SKILL.md) tracks, by priority. At the top, a collapsible "Pipeline runs" section lists your runs (a packaging or a deploy launched by hand, the CI of your pushes outside a PR, marked `push to <branch>`), one block per repo: the running ones first, then those ended in the last day, each with its pipeline, branch, status, time and duration, open by default while one runs; a run whose host did not answer keeps its last known state, marked `cached`. A run unfolds from its line: `rerun` (press twice: a new run of the same pipeline, branch and parameters on Azure DevOps, a re-run on GitHub), `diagnose with Claude` when it did not succeed (asks the session to read the steps and logs and propose the fix), then every step of the run grouped by job in pipeline order, each job folded unless a step had a problem, each step's messages and log lines under their own toggle. Then, under a red title and one open block per repo, the PRs that need you: a failed or expired CI, a merge conflict, changes requested, or a new comment since the last check (unfolding the PR marks its changes read: the button clears, the PR stays where it is until the session ends). Then the PRs waiting for your review, per repo too, each with `review with Claude` (a quick review by a subagent, nothing posted) and `approve` (press twice; it reads `approving…` while it runs). Then a collapsible "Waiting for others" section with your other open PRs, one collapsible block per repo in merge order (a stacked PR under the one it targets). Then "Issues I follow", per repo with `unfollow all` (press twice): each issue on one line (yellow when it moved since you last looked, with `· n issues updated` on the band), unfolding to who opened it, its labels and comments and what changed, which marks it read, with `unfollow`. A PR you park (its `park` button, under its details) leaves the red list and the band for a folded "Parked, kept but quiet" section, with `unpark`. Last, before the recent list, a collapsible "Approved, waiting for the merge" section holds the PRs you approved and your own PRs that only wait for the merge, grouped per repo the same way, each with a `merge` button (press twice; `merging…` while it runs; squash on GitHub when the repo allows it, complete on Azure DevOps). Every section and repo block wears the worst color of what it holds (red, then yellow, then green), so a folded one still says where to look. A red PR or run can be acknowledged (`ack`): it turns blue, leaves the count and the colors above it, and comes back when it changes; `ack + remind` asks Claude for a reminder and acks until its date, shown beside it. Every PR is one line, a colored dot (red: you have to act, yellow: someone or something else, green: only the merge is left), its number, title and what it waits for; its details fold under it: status, CI, votes, conflicts, the PR's description and the changes since the last check. A PR whose CI runs, and the repo block and section around it, open by default so a CI you just launched is on screen (a folded block hiding one says `CI running`); what you fold stays folded. Each PR's CI checks fold under it, open while they run or when a required one failed, refreshed every minute until they end; a failed check has `details` (its failed steps and error lines) and `rerun` (press twice: re-queue on Azure DevOps, rerun failed jobs on GitHub). A merge conflict is shown in red with a `fix with Claude` button that asks the session to rebase and resolve it (it asks you before pushing). PRs merged or closed in the last 7 days stay listed at the bottom. An error shared by several PRs and lists (a host this computer cannot reach or sign in to) is shown once, with what it hit. Click a PR to open it in the browser; `refresh` (or `r`) fetches them live and lists what changed since the last check, without marking it seen. Its settings, in the [Configuration pane](mods/configuration) or `claude plugin configure`, turn each section on or off (open PRs, parked, merged and closed, review requests, issues), set how many pipeline runs to show per repo (0 hides them), how long an issue stays followed without moving, how often each part is refreshed by itself, and follow the kit's low power mode (see [configuration](mods/configuration)); pr-watch follows them too, so what is off is no longer fetched or reported. Needs pr-watch. |
| [reminders-handoffs](mods/reminders-handoffs) | One pane for whichever of [reminders](skills/reminders/SKILL.md) and [handoff](skills/handoff/SKILL.md) you have, a tab each when you have both. A button at the right of the band above the prompt, named after them (`Reminders 1 now · Handoffs 1`, yellow when a reminder is due or a note from your other computer waits), `/reminders-pane` and `/handoffs-pane` open it. Reminders come in three foldable sections, Now, Upcoming (with when each shows next, repeating ones included) and Past; handoff notes in Open and Done, a run sent to another computer with its target and status (red when it asks a question or failed, `answer` or `read` then `done` once it's back; one this computer runs by itself has only `cancel`). Several groups in a section (a reminder's group, else its folder, else its computer; a note's repo) each get a foldable title. Each item is one line that unfolds to its dates, repo, branch and text, with `pick` (hands the reminder or the note to this session now), `done` (`done today` on a repeating reminder), `stop`, `cancel` and `delete` (press twice), and `restore` on a past one (back as it was, dates and repeat days included). |
| [recent-prompts](mods/recent-prompts) | Shows your last two messages above the prompt, and a searchable history pane; click one to scroll the transcript to it. With the learn mod, the history also lists each 💡 lesson between the messages it answered. |
| [dnd](mods/dnd) | Do not disturb for the [recent-prompts](mods/recent-prompts), [pr-pane](mods/pr-pane) and [reminders-handoffs](mods/reminders-handoffs) panes. A profile hides a pane (its band button too), or keeps only some repos, reminder groups or handoff repos, `@here` being the session's own repo; counts and colors follow what is kept. Turn one on by hand with `/dnd work 1h` or by asking Claude, for this session, this computer or all computers (asked when you don't say; the [status line](#status-line) shows `🔕 work · session` while one is on), or let a rule turn it on: a Wi-Fi network, days and hours (`days=weekend`, `from=19:00 to=08:00`), a folder (a repo shows only its own). `/dnd`, or its button in the [Configuration pane](mods/configuration), opens the Do not disturb pane: a press per profile asks until when and where, then `Activate` turns it on; a name creates one, and each profile unfolds to what it keeps (a checklist) and the rules that turn it on; `dnd.sh edit <profile>` is the same checklist on a terminal, with the installer's keys. Profiles live in the sync repo when there is one, so every computer gets them. Offered only beside one of those panes. |
| [configuration](mods/configuration) | A `Configuration` button at the right of the band and `/configuration` open the Configuration pane: every mod's settings, grouped per mod (a toggle, a choice, or a number or text typed and saved with Enter), changed for all computers or, with a private sync, for this computer only; a setting kept for this computer says the value the other computers use. Its own setting is the kit's low power mode: on, off, or on battery (the default: while the computer runs on its battery or in its low power mode, read on macOS, Linux and Windows), everything that fetches by itself (the dev activity pane and pr-watch, the reminders and handoffs pane, do not disturb) does it five times less often, and the [status line](#status-line) shows 🔋 low power. With [dnd](mods/dnd), its button opens the Do not disturb pane beside it. The kit's panes ([recent-prompts](mods/recent-prompts), [pr-pane](mods/pr-pane), [reminders-handoffs](mods/reminders-handoffs), [dnd](mods/dnd)) bring it with them. |
| [learn](mods/learn) | Learn while working: when the work touches security (the attack a line stops or lets in), an architecture choice and its cost, a design pattern or a performance trap, Claude ends its reply with a short "💡 Learn:" block quoting the real code (`file:line`, or a small before/after), never a lecture, and nothing on most turns. `/learn off|brief|normal|deep` sets it for the session (`brief`: one point, for security or a lasting decision; `deep`: up to three, with the trade-off and a reference), `/learn default <level>` for new sessions; the status line shows it as 💡 and the level name. The lessons stay in the chat, never in your repos. |
| [drift-check](mods/drift-check) | When a reply doesn't start with your [opening text](#the-opening-text), asks Claude to check that reply against your `CLAUDE.md` and fix what slipped. Formerly `wave-check`: `/plugin uninstall wave-check@claude-code-kit`, then install `drift-check`. |

### Hooks

| Hook | Events | What it does |
|---|---|---|
| [git-identity-guard](hooks/git-identity-guard.sh) | PreToolUse (Bash); git pre-commit, pre-push | Refuses a `git commit` or `git push` whose author or committer email isn't the one you chose for that remote: rules per host or path prefix (`github.com`, `gitlab.com/client-x`, `dev.azure.com/my-org`, longest match wins), else the email you committed with most in that repo (teammates' commits not counted). The refusal tells Claude to ask you before changing anything. The setup asks your rules and offers git's global pre-commit and pre-push, so commits and pushes made outside Claude (you, other agents, your editor, a script) are checked too, on the identity git really uses, each repo's own hooks still running. For anyone with work, personal or client emails, even on a single host. Rules in `~/.claude/git-identity.json`, or in the sync repo when you use the sync engine. |
| [file-tools-guard](hooks/file-tools-guard.sh) | PreToolUse (Bash) | Denies shell workarounds for files (`cat`/`head`/`tail` to read, `sed -i`, `sed -n`, heredocs, `cat > file`, `python -c`) so Claude uses its Read, Edit and Write tools. Pipelines are still allowed. |
| [recent-activity](hooks/recent-activity.sh) | Stop, SessionStart | Keeps a small record of each session under your dev folder (`CLAUDE_DEV_ROOT`, default `~/dev`) and starts every session with a digest of the last 14 days: titles, branches, PRs, last asks. Lets Claude resolve "the bug from yesterday" across repos. |
| [session-registry](hooks/session-registry.sh) + [claude-resume-here.zsh](hooks/claude-resume-here.zsh) | SessionStart, SessionEnd | Records open sessions. In a new JetBrains or Ghostty terminal tab (zsh), lists the sessions left open in that folder by title (the `/rename` title, else the first prompt) with a brief (prompts, last use, last prompt): check the ones to resume, forget the rest or leave them for the next tab. |
| [drift-check-hook](hooks/drift-check.sh) | UserPromptSubmit, Stop | Warns when a reply didn't start with your [opening text](#the-opening-text), and reminds Claude on the next prompt. Formerly `wave-check-hook`. |
| [tab-status](hooks/tab-status.sh) | SessionStart, UserPromptSubmit, PreToolUse (AskUserQuestion), PermissionRequest, Notification, PostToolUse, PermissionDenied, Stop, StopFailure, SessionEnd | Titles each session's terminal tab `<mark> <repo> · <session title>`: 🟡 working, 🔴 waiting for you (a permission, a question), 🟢 done and your turn, ❌ failed (`CLAUDE_TAB_ICONS="🟡 🔴 🟢 ❌"` changes the marks). The repo is the git repo of the session's folder, so tabs read by project; the title is your `/rename` one, else Claude Code's. When the session needs you it also rings the bell in that tab: Ghostty adds a 🔔 until you go back to it and bounces its dock icon when it is in the background (`bell-features`); iTerm, WezTerm, kitty and tmux have their own marks. Turns off Claude Code's own title (`CLAUDE_CODE_DISABLE_TERMINAL_TITLE`), which would write over it; the plugin offers a one-question setup for that. The busy events run in the background, so nothing waits on them. macOS and Linux; does nothing without a terminal (`claude -p`). |
| [nocturne-notify](hooks/nocturne-notify.sh) | most events | Sends Claude's state to [Agent Nocturne](https://github.com/taekchef/agent-nocturne) (keyboard-backlight signals) without the ~2 s per tool call its own adapter adds. |

### Status line

[statusline-command.sh](statusline-command.sh): folder, git branch (and worktree), model, context used, effort level, the 5-hour rate limit with its reset time, the learn level (💡 brief, with the learn mod) and the do-not-disturb profile on (🔕 work · session, with the dnd mod, only while one is on: for this session, this computer, everywhere, or by a rule, with its end) and 🔋 low power while the kit's low power mode slows what it fetches by itself, colour-coded.

### Sync engine

[sync/](sync/README.md): keeps `CLAUDE.md`, skills, mods, hooks, settings (the plugins you installed and their options included), MCP servers (without their secrets), memory and the untracked agent files of your repos the same on every computer, through a private git repo of your own (any host). Secrets are replaced by `__SECRET__` before anything leaves the computer, and your personal folders (memory, knowledge notes) can be encrypted in the repo with git-crypt (`sync.sh crypt`), the key staying off the repo. The config-sync plugin sets it up for you (it takes the clone URL of a repo you made, or creates one on GitHub with `gh`) and keeps the engine in that repo up to date, unless you changed it there yourself; install.sh does the same setup once.

## Projects

Built alongside the kit, in their own repos:

| Project | What it is |
|---|---|
| [intelligent-home-agent](https://github.com/robinalexandre/intelligent-home-agent) | A self-hosted voice home assistant: morning briefing and evening recap (with the [reminders](skills/reminders/SKILL.md) left in your coding sessions), home control through Home Assistant, weather for your outdoor activities, calendar and mail. Reachable from Siri, Home Assistant Assist (Google Home, Alexa), push notifications or a scheduled task. |

## The opening text

The drift-check mod and hook rest on one line in `~/.claude/CLAUDE.md`: "Start every message with 🌊" (or any emoji, word or name you like). A reply without it is a cheap, visible sign that Claude has started to drift from your instructions, usually deep in a long task. The installer asks for it, keeps it as the drift-check setting (`Opening text` in the Configuration pane, where you change it later) and offers to add the rule to your `CLAUDE.md`. `CLAUDE_REPLY_MARKER` in the `env` of `~/.claude/settings.json` still works when the setting is empty. Until one is set, both parts stay idle.

## Installing by hand

Copy the part into the same place under `~/.claude` (`skills/<name>`, `mods/<name>`, `hooks/<file>`, `statusline-command.sh`). For a hook or the status line, merge [settings/\<part\>.json](settings) into `~/.claude/settings.json`, replacing `__HOME__` with your home folder. For a mod, add its folder to `CLAUDE_CODE_PLUGIN_DIRS` in the `env` of `settings.json` (`:`-separated, `;` on Windows).

## Other things (not dev)

Skills from the same kit for life outside code.

| Skill | What it does | Needs |
|---|---|---|
| [video-montage](skills/video-montage/SKILL.md) | Edits a video montage from a folder of phone videos (a vertical Instagram Reel by default): reviews every clip, proposes numbered candidates, assembles once, checks the result frame by frame. Can save the result to the Photos library with write-only access. | `ffmpeg`; Photos saving needs macOS and Xcode's `swiftc` |
| [insta360-montage](skills/insta360-montage/SKILL.md) | Edits a video montage straight from raw Insta360 X-series `.insv` files, no Insta360 Studio: calibrates the camera mount, finds every action with a motion analysis, lets you pick from numbered candidate clips, then renders them with a rider-locked horizon, as a vertical Instagram Reel by default. Tuned on wingfoil sessions. | `ffmpeg`, `python3` |

## Contributing

Each part is described once in [parts.json](parts.json) (what, why, when, who), which the installer shows. To build a new one, install [capability-builder](skills/capability-builder/SKILL.md) and say "make this a skill", or follow [CONTRIBUTING.md](CONTRIBUTING.md). Questions and ideas: [Discussions](https://github.com/robinalexandre/claude-code-kit/discussions). Bugs: [issues](https://github.com/robinalexandre/claude-code-kit/issues).

## License

[MIT](LICENSE)
