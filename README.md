# claude-code-kit

[![tests](https://github.com/robinalexandre/claude-code-kit/actions/workflows/tests.yml/badge.svg)](https://github.com/robinalexandre/claude-code-kit/actions/workflows/tests.yml)

Skills, mods, hooks and a status line for [Claude Code](https://claude.com/claude-code), plus a sync engine that keeps your Claude Code config the same on all your computers. Every part is tested on macOS, Linux and Windows on each change.

## Install

```sh
git clone https://github.com/robinalexandre/claude-code-kit.git
cd claude-code-kit
./install.sh            # a checklist: arrows, Enter to pick, → for what each part does, then Install
./install.sh --plain    # the same as one question per part
./install.sh --list     # lists the parts
./install.sh --all      # installs every part offered on this computer
./install.sh statusline file-tools-guard   # installs the named parts
```

On Windows, from Git Bash the same, or from PowerShell: `powershell -ExecutionPolicy Bypass -File .\install.ps1` (it installs git and jq with winget when missing, then runs `install.sh` in Git Bash).

The installer shows the parts as a checklist by group (every day, development, several computers, not dev): ↑↓ to move, Enter or Space to pick a part or a whole group, → or Tab to unfold why, what, when and who for a part, `a` for all, then Install at the bottom. It greys out what doesn't apply to this computer, adds what a picked part needs (pr-pane brings pr-watch, reminders brings daily-sync), then sets up each part it installed: the emails for the email guard, where pr-watch looks for your PRs, the phone for reminders, the browser tool for test-evidence. Run a part's setup again any time with `bash ~/.claude/<part>/setup.sh` (hooks: `bash ~/.claude/hooks/setup/<hook>.sh`). It copies each part into `~/.claude`, adds its hooks to `~/.claude/settings.json` and saves whatever it replaces in `~/.claude/backups/before-kit-<date>/`. Running it again is safe. Start a new Claude Code session afterwards. Needs `jq`.

To try it first without touching your own setup, `tests/install-sandbox.sh` runs the installer in a throwaway home folder, shows what it left and checks your files are unchanged; `--claude <sandbox>` then opens a first Claude Code session there.

**As plugins:** the parts that need no setup also install from Claude Code itself:

```
/plugin marketplace add robinalexandre/claude-code-kit
/plugin install capability-builder@claude-code-kit
/plugin install test-evidence@claude-code-kit
/plugin install ci-review@claude-code-kit
/plugin install file-tools-guard@claude-code-kit
/plugin install paste-preview@claude-code-kit
/plugin install recent-prompts@claude-code-kit
/plugin install learn@claude-code-kit
```

The sync engine installs differently: see [sync/README.md](sync/README.md).

## What's inside

### Base rules

[rules/team.md](rules/team.md) is the base of everything here: Claude and you work as one team that builds, thinks things through and challenges each other. It asks before touching production or shared infrastructure (in two lines, not twenty), before each commit, push and PR, and before decisions that need context only you have, with the options and a recommendation. It proposes a skill, mod or hook when you keep asking for the same thing, and an AI review step with proof (screenshots, videos) on the CI of repos that don't have one. The installer asks which language Claude should talk to you in and adds the rules to `~/.claude/CLAUDE.md` once (part `team`); a capability can use another language when you say so.

### Skills

| Skill | What it does | Needs |
|---|---|---|
| [test-evidence](skills/test-evidence/SKILL.md) | Captures proof that a ticket works locally: browser screenshots, a short video of the flow, the network requests and console behind it (through the chrome-devtools MCP), or one app window or screen region, never the whole screen unless asked. Masks tokens and cookies, writes a short test report and, after your yes, attaches it to the Jira issue or as a resolved comment on the Azure DevOps PR. | [chrome-devtools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp), `jq`, `perl`; video needs `ffmpeg` |
| [ci-review](skills/ci-review/SKILL.md) | Proposes, once per repo, an AI review step on the CI and sets it up with you: an agent reads each PR/MR's diff and its proof (what test-evidence captures) and posts a verdict (works / doesn't / can't tell, with what to capture). Templates for `anthropics/claude-code-action`, the CLI in headless mode (`claude -p`) on GitHub Actions and GitLab CI, and cloud providers; the review prompt is a plain file any agent CLI can take. | an API key or a cloud provider account, set as a CI secret |
| [capability-builder](skills/capability-builder/SKILL.md) | Turns a request you keep making into a capability: picks the right kind (rule, skill, hook, mod or plain script), interviews you, scaffolds it with its tests and setup, checks it against a macOS / Linux / Windows checklist, and runs the publish checklist (nothing personal, tool-agnostic) before it goes to a kit. How this kit's own parts are built. | |
| [handoff](skills/handoff/SKILL.md) | Writes a handoff note so you can continue the current work on your other computer, and picks it up there. | the [sync engine](sync/README.md) |
| [daily-sync](skills/daily-sync/SKILL.md) | Schedules a sync every morning (09:00 by default) with launchd, cron or the Windows Task Scheduler, so each computer gets what the others left even with no session open. Other skills can hook a `morning.sh` onto it. | the [sync engine](sync/README.md) |
| [reminders](skills/reminders/SKILL.md) | "Remind me tomorrow to…": leaves a global or repo-specific reminder that every new session, on any of your computers, brings up first thing, without slowing the start: what the background sync brings arrives with your next message. Due reminders also go to the desktop and, through [ntfy](https://ntfy.sh), to your phone every morning and at the first session of the day. | daily-sync; `curl` for the phone |
| [pr-watch](skills/pr-watch/SKILL.md) | Tracks the PRs you and Claude open or push together until they are merged: new comments (bots marked apart), votes, CI results (required checks drive green or failed) and the merge itself, which drops the PR from the list. Also lists the open PRs waiting for your review (GitHub review requests, Azure DevOps reviewer with no vote) and reports each new one; `approve` votes or submits an approving review on your yes, then tracks the PR as reviewed until it is merged; `merge` merges a PR on your yes; `park` keeps a PR you won't merge tracked but quiet, out of what needs you, until `unpark`. Also finds your pipeline runs: those you launched by hand (Azure DevOps manual builds, GitHub workflows you dispatched) and the CI your own pushes start on a branch with no PR, a push to `main` included (in the projects and repos of your PRs, the GitHub repos you pushed to lately, plus those listed in its config), so a packaging or a deploy started with Claude shows up on its own, and reports each one that ended since the last check; `details <build URL>` lists every step with its job and state, the error lines of those with issues included, `rerun <build URL>` launches the run again on your yes. Claude proposes a reply or a fix for each change, never posts one without your yes. Checks at each session start in the background and silently (the session starts at once; each PR keeps what changed as unread, which [pr-pane](mods/pr-pane) shows until you unfold that PR), hourly in a session (a durable scheduled task) and every morning through daily-sync, with a desktop or phone notification. The list lives in the sync repo, so it follows you on every computer and never touches the project repos. Azure DevOps (`az login` or a PAT) and GitHub (a token, `gh`, or anonymous for public repos). | Python 3.9+; the [sync engine](sync/README.md) to share the list across computers |

### Mods

Mods change Claude Code's own interface. The installer loads them through `CLAUDE_CODE_PLUGIN_DIRS`. Run a mod's tests with `claude plugin test mods/<name>`.

| Mod | What it does |
|---|---|
| [paste-preview](mods/paste-preview) | Shows pasted text in full in the prompt box and the transcript, and previews pasted images above the prompt and under the sent message (macOS, Windows). |
| [pr-pane](mods/pr-pane) | A `PRs & CI` button at the top right of the band above the prompt, whose number counts only what needs you (a PR or a run in red, not acknowledged), colored by what you have to do (red and marked `!`: something needs you; yellow: `· k to review` or `· k running`; green: a PR is ready to merge; dim: everything waits for others) and `/prs` open a pane of the PRs [pr-watch](skills/pr-watch/SKILL.md) tracks, by priority. At the top, a collapsible "Pipeline runs" section lists your runs (a packaging or a deploy launched by hand, the CI of your pushes outside a PR, marked `push to <branch>`), one block per repo: the running ones first, then those ended in the last day, each with its pipeline, branch, status, time and duration, open by default while one runs; a run whose host did not answer keeps its last known state, marked `cached`. A run unfolds from its line: `rerun` (press twice: a new run of the same pipeline, branch and parameters on Azure DevOps, a re-run on GitHub), `diagnose with Claude` when it did not succeed (asks the session to read the steps and logs and propose the fix), then every step of the run grouped by job in pipeline order, each job folded unless a step had a problem, each step's messages and log lines under their own toggle. Then, under a red title and one open block per repo, the PRs that need you: a failed or expired CI, a merge conflict, changes requested, or a new comment since the last check (unfolding the PR marks its changes read: the button clears, the PR stays where it is until the session ends). Then the PRs waiting for your review, per repo too, each with `review with Claude` (a quick review by a subagent, nothing posted) and `approve` (press twice; it reads `approving…` while it runs). Then a collapsible "Waiting for others" section with your other open PRs, one collapsible block per repo in merge order (a stacked PR under the one it targets). A PR you park (its `park` button, under its details) leaves the red list and the band for a folded "Parked, kept but quiet" section, with `unpark`. Last, before the recent list, a collapsible "Approved, waiting for the merge" section holds the PRs you approved and your own PRs that only wait for the merge, grouped per repo the same way, each with a `merge` button (press twice; `merging…` while it runs; squash on GitHub when the repo allows it, complete on Azure DevOps). Every section and repo block wears the worst color of what it holds (red, then yellow, then green), so a folded one still says where to look. A red PR or run can be acknowledged (`ack`): it turns blue, leaves the count and the colors above it, and comes back when it changes; `ack + remind` asks Claude for a reminder and acks until its date, shown beside it. Every PR is one line, a colored dot (red: you have to act, yellow: someone or something else, green: only the merge is left), its number, title and what it waits for; its details fold under it: status, CI, votes, conflicts, the PR's description and the changes since the last check. A PR whose CI runs, and the repo block and section around it, open by default so a CI you just launched is on screen (a folded block hiding one says `CI running`); what you fold stays folded. Each PR's CI checks fold under it, open while they run or when a required one failed, refreshed every minute until they end; a failed check has `details` (its failed steps and error lines) and `rerun` (press twice: re-queue on Azure DevOps, rerun failed jobs on GitHub). A merge conflict is shown in red with a `fix with Claude` button that asks the session to rebase and resolve it (it asks you before pushing). PRs merged or closed in the last 7 days stay listed at the bottom. An error shared by several PRs and lists (a host this computer cannot reach or sign in to) is shown once, with what it hit. Click a PR to open it in the browser; `refresh` (or `r`) fetches them live and lists what changed since the last check, without marking it seen. Needs pr-watch. |
| [recent-prompts](mods/recent-prompts) | Shows your last two messages above the prompt, and a searchable history pane; click one to scroll the transcript to it. With the learn mod, the history also lists each 💡 lesson between the messages it answered. |
| [learn](mods/learn) | Learn while working: when the work touches security (the attack a line stops or lets in), an architecture choice and its cost, a design pattern or a performance trap, Claude ends its reply with a short "💡 Learn:" block quoting the real code (`file:line`, or a small before/after), never a lecture, and nothing on most turns. `/learn off|brief|normal|deep` sets it for the session (`brief`: one point, for security or a lasting decision; `deep`: up to three, with the trade-off and a reference), `/learn default <level>` for new sessions; the status line shows it as 💡 and the level name. The lessons stay in the chat, never in your repos. |
| [wave-check](mods/wave-check) | When a reply doesn't start with your marker emoji, asks Claude to check that reply against your `CLAUDE.md` and fix what slipped. |

### Hooks

| Hook | Events | What it does |
|---|---|---|
| [git-identity-guard](hooks/git-identity-guard.sh) | PreToolUse (Bash); git pre-commit, pre-push | Refuses a `git commit` or `git push` whose author or committer email isn't the one you chose for that remote: rules per host or path prefix (`github.com`, `gitlab.com/client-x`, `dev.azure.com/my-org`, longest match wins), else the email you committed with most in that repo (teammates' commits not counted). The refusal tells Claude to ask you before changing anything. The setup asks your rules and offers git's global pre-commit and pre-push, so commits and pushes made outside Claude (you, other agents, your editor, a script) are checked too, on the identity git really uses, each repo's own hooks still running. For anyone with work, personal or client emails, even on a single host. Rules in `~/.claude/git-identity.json`, or in the sync repo when you use the sync engine. |
| [file-tools-guard](hooks/file-tools-guard.sh) | PreToolUse (Bash) | Denies shell workarounds for files (`cat`/`head`/`tail` to read, `sed -i`, `sed -n`, heredocs, `cat > file`, `python -c`) so Claude uses its Read, Edit and Write tools. Pipelines are still allowed. |
| [recent-activity](hooks/recent-activity.sh) | Stop, SessionStart | Keeps a small record of each session under your dev folder (`CLAUDE_DEV_ROOT`, default `~/dev`) and starts every session with a digest of the last 14 days: titles, branches, PRs, last asks. Lets Claude resolve "the bug from yesterday" across repos. |
| [session-registry](hooks/session-registry.sh) + [claude-resume-here.zsh](hooks/claude-resume-here.zsh) | SessionStart, SessionEnd | Records open sessions. In a new JetBrains or Ghostty terminal tab (zsh), offers to resume the session that was left open in that folder. |
| [wave-check](hooks/wave-check.sh) | UserPromptSubmit, Stop | Warns when a reply didn't start with your marker emoji, and reminds Claude on the next prompt. |
| [nocturne-notify](hooks/nocturne-notify.sh) | most events | Sends Claude's state to [Agent Nocturne](https://github.com/taekchef/agent-nocturne) (keyboard-backlight signals) without the ~2 s per tool call its own adapter adds. |

### Status line

[statusline-command.sh](statusline-command.sh): folder, git branch (and worktree), model, context used, effort level, the learn level (💡 brief, with the learn mod) and the 5-hour rate limit with its reset time, colour-coded.

### Sync engine

[sync/](sync/README.md): keeps `CLAUDE.md`, skills, mods, hooks, settings, MCP servers (without their secrets), memory and the untracked agent files of your repos the same on every computer, through a private GitHub repo. Secrets are replaced by `__SECRET__` before anything leaves the computer.

## Projects

Built alongside the kit, in their own repos:

| Project | What it is |
|---|---|
| [intelligent-home-agent](https://github.com/robinalexandre/intelligent-home-agent) | A self-hosted voice home assistant: morning briefing and evening recap (with the [reminders](skills/reminders/SKILL.md) left in your coding sessions), home control through Home Assistant, weather for your outdoor activities, calendar and mail. Reachable from Siri, Home Assistant Assist (Google Home, Alexa), push notifications or a scheduled task. |

## The marker emoji

The wave-check mod and hook rest on one line in `~/.claude/CLAUDE.md`: "Start every message with 🌊" (or any emoji you like). A reply without it is a cheap, visible sign that Claude has started to drift from your instructions, usually deep in a long task. The installer asks for your emoji, stores it as `CLAUDE_REPLY_MARKER` in the `env` of `~/.claude/settings.json` and offers to add the rule to your `CLAUDE.md`. Until the variable is set, both parts stay idle.

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
