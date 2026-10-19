# claude-code-kit

Skills, mods, hooks and a status line for [Claude Code](https://claude.com/claude-code), plus a sync engine that keeps your Claude Code config the same on all your computers.

## Install

```sh
git clone https://github.com/robinalexandre/claude-code-kit.git
cd claude-code-kit
./install.sh            # asks about each part
./install.sh --list     # lists the parts
./install.sh --all      # installs every part
./install.sh statusline file-tools-guard   # installs the named parts
```

Needs `jq`. Works on macOS and Linux, and on Windows from Git Bash. The installer copies each part into `~/.claude`, adds its hooks to `~/.claude/settings.json` and saves whatever it replaces in `~/.claude/backups/before-kit-<date>/`. Running it again is safe. Start a new Claude Code session afterwards.

The sync engine installs differently: see [sync/README.md](sync/README.md).

## What's inside

### Base rules

[rules/team.md](rules/team.md) is the base of everything here: Claude and you work as one team that builds, thinks things through and challenges each other. It asks before touching production or shared infrastructure (in two lines, not twenty), before each commit, push and PR, and before decisions that need context only you have, with the options and a recommendation. The installer adds it to `~/.claude/CLAUDE.md` once (part `team`).

### Skills

| Skill | What it does | Needs |
|---|---|---|
| [insta360-reel](skills/insta360-reel/SKILL.md) | Builds a vertical Instagram Reel straight from raw Insta360 X-series `.insv` files, no Insta360 Studio: calibrates the camera mount, finds every action with a motion analysis, lets you pick from numbered candidate clips, then renders them with a rider-locked horizon. Tuned on wingfoil sessions. | `ffmpeg`, `python3` |
| [instagram-reel](skills/instagram-reel/SKILL.md) | Builds a Reel from a folder of phone videos: reviews every clip, proposes numbered candidates, assembles once, checks the result frame by frame. Can save the result to the Photos library with write-only access. | `ffmpeg`; Photos saving needs macOS and Xcode's `swiftc` |
| [test-evidence](skills/test-evidence/SKILL.md) | Captures proof that a ticket works locally: browser screenshots, a short video of the flow, the network requests and console behind it (through the chrome-devtools MCP), or one app window or screen region, never the whole screen unless asked. Masks tokens and cookies, writes a short test report and, after your yes, attaches it to the Jira issue or as a resolved comment on the Azure DevOps PR. | [chrome-devtools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp), `jq`, `perl`; video needs `ffmpeg` |
| [handoff](skills/handoff/SKILL.md) | Writes a handoff note so you can continue the current work on your other computer, and picks it up there. | the [sync engine](sync/README.md) |
| [daily-sync](skills/daily-sync/SKILL.md) | Schedules a sync every morning (09:00 by default) with launchd, cron or the Windows Task Scheduler, so each computer gets what the others left even with no session open. Other skills can hook a `morning.sh` onto it. | the [sync engine](sync/README.md) |
| [reminders](skills/reminders/SKILL.md) | "Remind me tomorrow to…": leaves a global or repo-specific reminder that every new session, on any of your computers, brings up first thing, without slowing the start: what the background sync brings arrives with your next message. Due reminders also go to the desktop and, through [ntfy](https://ntfy.sh), to your phone every morning and at the first session of the day. | daily-sync; `curl` for the phone |

### Mods

Mods change Claude Code's own interface. The installer loads them through `CLAUDE_CODE_PLUGIN_DIRS`. Run a mod's tests with `claude plugin test mods/<name>`.

| Mod | What it does |
|---|---|
| [paste-preview](mods/paste-preview) | Shows pasted text in full in the prompt box and the transcript, and previews pasted images above the prompt and under the sent message (macOS, Windows). |
| [recent-prompts](mods/recent-prompts) | Shows your last two messages above the prompt, and a searchable history pane; click one to scroll the transcript to it. |
| [wave-check](mods/wave-check) | When a reply doesn't start with your marker emoji, asks Claude to check that reply against your `CLAUDE.md` and fix what slipped. |

### Hooks

| Hook | Events | What it does |
|---|---|---|
| [file-tools-guard](hooks/file-tools-guard.sh) | PreToolUse (Bash) | Denies shell workarounds for files (`cat`/`head`/`tail` to read, `sed -i`, `sed -n`, heredocs, `cat > file`, `python -c`) so Claude uses its Read, Edit and Write tools. Pipelines are still allowed. |
| [recent-activity](hooks/recent-activity.sh) | Stop, SessionStart | Keeps a small record of each session under your dev folder (`CLAUDE_DEV_ROOT`, default `~/dev`) and starts every session with a digest of the last 14 days: titles, branches, PRs, last asks. Lets Claude resolve "the bug from yesterday" across repos. |
| [session-registry](hooks/session-registry.sh) + [claude-resume-here.zsh](hooks/claude-resume-here.zsh) | SessionStart, SessionEnd | Records open sessions. In a new JetBrains or Ghostty terminal tab (zsh), offers to resume the session that was left open in that folder. |
| [wave-check](hooks/wave-check.sh) | UserPromptSubmit, Stop | Warns when a reply didn't start with your marker emoji, and reminds Claude on the next prompt. |
| [nocturne-notify](hooks/nocturne-notify.sh) | most events | Sends Claude's state to [Agent Nocturne](https://github.com/taekchef/agent-nocturne) (keyboard-backlight signals) without the ~2 s per tool call its own adapter adds. |

### Status line

[statusline-command.sh](statusline-command.sh): folder, git branch (and worktree), model, context used, effort level and the 5-hour rate limit with its reset time, colour-coded.

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

## License

[MIT](LICENSE)
