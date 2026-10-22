# Contributing

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

CI runs the tests on the three systems for every pull request.
