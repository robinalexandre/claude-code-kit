---
name: capability-builder
description: Turns a request the user keeps making into a capability that works on its own, everywhere: picks the right kind (skill, hook, mod, rule or plain script), interviews the user, scaffolds it with tests, checks it on macOS, Linux and Windows (Git Bash), and runs the checklist before it is shared in a kit. Use when the user says "make this a skill", "turn this into a hook", "build a capability", "automate this every time", "add it to the kit", "contribute to claude-code-kit", or when you notice the same kind of request coming back in the conversation or the memory.
---

# Capability builder

A capability is worth building when the same ask comes back: a third "take screenshots for the PR", the same check before every commit, the same setup explained to every newcomer. Build it in the user's own `~/.claude` first, where it is used and tested for real, then offer to share a generic copy in a kit (the public claude-code-kit, a team kit, or one the user keeps).

## 1. Spot it and say it

Name the repeated ask in one line, with two real examples from this conversation or the memory, and propose the kind that fits (step 2) with the reason. Build nothing before the user's yes.

## 2. Pick the kind

| Kind | Fits when | Lives in |
|---|---|---|
| Rule | One sentence Claude must always follow, no code. | a line in `~/.claude/CLAUDE.md` (and `AGENTS.md` for other agents) |
| Skill | A procedure Claude follows on demand, with judgement, maybe scripts. | `skills/<name>/SKILL.md` + scripts beside it |
| Hook | Must happen every time, deterministically, whatever Claude decides (block, check, record, notify). | `hooks/<name>.sh` + `settings/<name>.json` (the hooks config) |
| Mod | Changes Claude Code's own interface: a pane, a band, a slash command, a toast. | `mods/<name>/` (load the plugin-authoring skill to build it) |
| Plain script | Useful outside Claude too (CI, other agents, a terminal). | a script in the repo, documented in README / AGENTS.md |

Prefer the lightest that works. A rule Claude forgets is a hook; a hook that needs judgement is a skill; a skill that only runs one command is a script. Tool-agnostic first: the logic in a plain script any agent or a person can run, the skill or hook a thin layer over it.

## 3. Interview

Ask only what the examples don't already answer, in one message:
- Trigger: the words the user says, or the event (before a commit, at session start, after a reply).
- Input and output: what it reads, what it writes or shows, where.
- What must never happen (the failure that would hurt most), and what to do on error.
- What is personal (names, emails, hosts, paths, tokens, brands, dates). Each becomes a setting or a question the setup asks, never a value in the files.

## 4. Scaffold

Follow the layout of the kit it may go to (claude-code-kit shown):
- **Skill**: `SKILL.md` with `name` and a `description` that says what it does AND the phrases that should trigger it. Scripts beside it, referred to as "this skill's base directory" (`$SK`), never by an absolute path.
- **Hook**: reads the event JSON on stdin with jq; denies with `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "<what to do instead>"}}`; prints nothing and exits 0 otherwise. Fast (it runs on every event), and silent on its own errors (`2>/dev/null || true` in the settings) so it never blocks the user. The settings fragment uses `__HOME__` for the home folder.
- **Setup**: when it needs configuration, `setup.sh` in the part (hooks: `hooks/setup/<name>.sh`), sourcing `hooks/lib/ask.sh`: `reply KEY PROMPT [DEFAULT]` and `ask KEY PROMPT [y|n]`, each with a default, so the install test can run it unattended. Explain in two lines what the question is for before asking it.
- **Catalog**: an entry in `parts.json`: `what`, `why`, `when`, `who` in one short sentence each, its `group`, and `needs`, `tools`, `os`, `setup`, `sync` when they apply. The installer shows those four lines to whoever installs it.
- **README**: one row in the right table.

## 5. Test

- A test script in `tests/` with real cases: the ones that must pass, the ones that must be refused, and an edge case or two (paths with spaces, no git remote, an empty config). Hooks: pipe JSON into the script and check its output. Mods: `claude plugin test <mod>`.
- `tests/install-sandbox.sh --auto`: installs everything in a throwaway home folder and checks paths, settings and setups. 0 problems before going further.
- Use it for real on the user's machine once, and show the result.

## 6. Cross-platform checklist

Everything must work on macOS (bash 3.2, BSD tools), Linux (GNU tools) and Windows (Git Bash, native `jq.exe`, `git.exe`):
- No `sed -i`, `sed -E` with GNU-only escapes, `grep -P`, `readlink -f`, `date -d`, `stat -c`, `timeout`, `mapfile`, associative arrays (bash 3.2). Use awk, jq, POSIX options, or a checked fallback.
- Paths: quote every one (spaces), `$HOME` not `~` inside quotes, `cygpath -m` (`kit_path`) before handing a path to a Windows program (git config, jq, Claude Code settings). No `/proc/self/fd` (`<(...)` given to jq.exe), no hard-coded tool locations.
- Source `hooks/lib/jq.sh`: it handles jq.exe's CRLF and slow mise shims.
- LF line endings, executable bit set (`git update-index --chmod=+x` when committing from Windows).
- Machine-only things behind a platform check (`uname -s`: Darwin, Linux, MINGW*/MSYS*).

## 7. Share it

Ask once, when it works: "Publish a generic copy to <kit>?". On yes:
1. Pull the kit (`git pull --ff-only`), copy the part, and replace whatever is personal (step 3) by a setting or a setup question. Search the copy for the user's name, emails, hosts, home path and company names before going on.
2. Run the tests and the install sandbox; show the user the diff.
3. Commit with the email the user uses for that host, and push only on their yes. A kit with a team mirror (see the kit's README): push the part there too, on its own yes.
