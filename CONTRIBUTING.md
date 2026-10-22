# Contributing

A part earns its place when it answers a request people keep making, works on its own after `install.sh`, and works the same on macOS, Linux and Windows (Git Bash). The [capability-builder](skills/capability-builder/SKILL.md) skill walks Claude (or you) through all of this; below is the short version.

## Add a part

1. **Pick the kind**: a rule (one line in `CLAUDE.md`), a skill (`skills/<name>/SKILL.md`), a hook (`hooks/<name>.sh` + `settings/<name>.json`), a mod (`mods/<name>/`), or a plain script. The lightest one that works; the logic in a plain script other agents can run too.
2. **Describe it** in [parts.json](parts.json): `what`, `why`, `when`, `who` in one sentence each, its `group`, and `needs`, `tools`, `os`, `setup`, `sync` when they apply. The installer shows those lines to whoever installs it.
3. **Setup** (only when it needs configuration): `setup.sh` in the part (hooks: `hooks/setup/<name>.sh`) using `reply` and `ask` from [hooks/lib/ask.sh](hooks/lib/ask.sh), every question with a default.
4. **Test**: a script in `tests/` (hooks: JSON on stdin, check the output), `claude plugin test <mod>` for a mod, and `tests/install-sandbox.sh --auto`, which must end on `0 problem(s)`.
5. **README**: one row in the right table. A part that needs no setup can also go in [.claude-plugin/marketplace.json](.claude-plugin/marketplace.json); check it with `claude plugin validate .`.

## Rules for every file

- **Nothing personal**: no names, emails, hosts, home paths, companies or dates of your own. What was personal becomes a setting or a setup question.
- **Portable shell**: bash 3.2 (macOS), no `sed -i`, `grep -P`, `readlink -f`, `date -d`, `timeout`, associative arrays. Quote every path. `cygpath -m` (`kit_path`) before handing a path to a Windows program. Source `hooks/lib/jq.sh` for jq.
- **LF line endings** and the executable bit on scripts (`.gitattributes` handles the first).
- **Hooks are fast and fail silent**: they run on every event; a broken hook must never block a session.
- English everywhere; the language Claude speaks to the user is a setting.

CI runs the tests on the three systems for every pull request.
