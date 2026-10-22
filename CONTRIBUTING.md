# Contributing

> **Agents (Claude, Codex and others): never edit this file.** These are the maintainer's rules: follow them, and when one seems wrong or missing, tell the person you work with and let them change it. People change it through a pull request.

A part earns its place when it answers a request people keep making, works on its own as a plugin and after `install.sh`, and works the same on macOS, Linux and Windows (Git Bash). The [capability-builder](skills/capability-builder/SKILL.md) skill walks Claude (or you) through all of this; below is the short version.

## Add a part

1. **Pick the kind**: a rule (one line in `CLAUDE.md`), a skill (`skills/<name>/SKILL.md`), a hook (`hooks/<name>.sh` + `settings/<name>.json`), a mod (`mods/<name>/`), or a plain script. The lightest one that works; the logic in a plain script other agents can run too.
2. **Describe it** in [parts.json](parts.json): `what`, `why`, `when`, `who` in one sentence each, its `group`, and `needs`, `tools`, `os`, `setup`, `sync` when they apply. The installer shows those lines to whoever installs it.
3. **Setup** (only when it needs configuration): `setup.sh` in the part (hooks: `hooks/setup/<name>.sh`) using `reply` and `ask` from [hooks/lib/ask.sh](hooks/lib/ask.sh), every question with a default. It sources the kit's libs relative to itself (never `~/.claude/hooks/lib`) and ends with `kit_setup_mark <part> done` ([hooks/lib/kit.sh](hooks/lib/kit.sh)). For the plugin, add the part to [hooks/kit-session.sh](hooks/kit-session.sh), which offers the setup at session start until it's done or declined.
4. **Plugin**: an entry in [.claude-plugin/marketplace.json](.claude-plugin/marketplace.json) with a `version`. A mod is its own plugin (`"source": "./mods/<name>"`, version in its `plugin.json`). Any other part uses `"source": "."` and `"strict": false`, lists its skills (`"skills": ["./skills/<name>"]`, or `["./hooks"]` when it has none: without a list it would load every skill of the kit), its hooks with `${CLAUDE_PLUGIN_ROOT}/…` paths, and `dependencies` for what it `needs`. Never point at another part through `~/.claude/...`: find it with `kit_find` (bash) or `installed_plugins.json` (mods). A program outside Claude Code (git, zsh, the status line) runs a copy that `kit-session.sh` keeps in the plugin's data folder.
5. **Bump the version** of every plugin whose files or entry you change (`tests/plugin-versions.sh` fails otherwise): Claude Code updates a plugin only when its version moves. Patch for a fix, minor for a feature.
6. **Test**: a script in `tests/` (hooks: JSON on stdin, check the output), `claude plugin test <mod>` for a mod, `tests/plugins.sh` and `tests/install-sandbox.sh --auto`, which must end on `0 problem(s)`, and `claude plugin validate .`.
7. **README**: one row in the right table, and its `/plugin install` line.

## Rules for every file

- **Nothing personal**: no names, emails, hosts, home paths, companies or dates of your own. What was personal becomes a setting or a setup question.
- **Portable shell**: bash 3.2 (macOS), no `sed -i`, `grep -P`, `readlink -f`, `date -d`, `timeout`, associative arrays. Quote every path. `cygpath -m` (`kit_path`) before handing a path to a Windows program. Source `hooks/lib/jq.sh` for jq.
- **LF line endings** and the executable bit on scripts (`.gitattributes` handles the first).
- **Hooks are fast and fail silent**: they run on every event; a broken hook must never block a session.
- English everywhere; the language Claude speaks to the user is a setting.

## Rules for mods

Every pane looks and behaves the same way, so what someone learned in one works in the others:

- **Folded by default**: sections, groups and rows start folded, a section's only group or row too; what the user unfolds stays so for the session.
- **Grouped always**: a section files its rows under group titles (a repo, a folder, an organization, "General"), even when there is a single one.
- **The whole line folds**: clicking a folded line's text unfolds it, as its ▸ does. A part of the line that already has its own action (a link, a button) keeps it.
- **Lit under the pointer**: a line that folds lights up while the pointer is over it, from its first arrow to the end of its text (a keyed `Box` with a `hover` background).
- **A way back to the conversation**: every entry that comes from the transcript (a message, a reply, a lesson) has its ↗ that scrolls the conversation to it.
- **Nothing cut that can be read**: a body, a description, a reply or an error message wraps to the pane's width instead of ending in "…". Only one-line summaries (a title, a list of rows to pick from) are cut, and the full text is one unfold away.
- **Fits on one line**: a row's text leaves room for its arrows, icons and buttons, so the line never wraps.

Each mod also works on older Claude Code builds:

- A mod that uses something a newer build brings (for instance styled Text inside a Button, from 2.1.306) checks the running version, keeps a fallback drawn with what the oldest supported build has, and its tests check whichever the running build draws.
- CI runs every mod's tests on the latest build and on the oldest supported one (`OLDEST_CLAUDE` in [the tests workflow](.github/workflows/tests.yml)). Raise it only on purpose, when the kit no longer supports the builds below.

CI runs the tests on the three systems for every pull request.
