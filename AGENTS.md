# Working on this repo

For any agent (Claude Code, Codex, others) changing this kit:

- Read [CONTRIBUTING.md](CONTRIBUTING.md) first: how a part is laid out, described in `parts.json`, set up and tested.
- [CONTRIBUTING.md](CONTRIBUTING.md) holds the maintainer's rules: follow them and never edit that file; when a rule seems wrong or missing, say so to the person you work with.
- A mod follows its Rules for mods: folded by default, always grouped, the whole line folds and lights under the pointer, a ↗ back to the conversation, long text wraps, and it works on the oldest supported Claude Code build too.
- Everything must run on macOS (bash 3.2), Linux and Windows (Git Bash). Check before finishing: `bash tests/git-identity-guard.sh`, `bash tests/kit-update-check.sh`, `bash tests/install-sandbox.sh --auto` and `bash tests/plugins.sh` (both must end on `0 problem(s)`), `bash tests/plugin-versions.sh` (every plugin you changed has a new version), `claude plugin validate .`, and for a mod `cd mods && claude plugin test <mod>`.
- Every part is a plugin of `.claude-plugin/marketplace.json`: bump the version of each plugin you change, or its users never get the change.
- No personal data in any file (names, emails, hosts, paths). Ask before committing and pushing.
