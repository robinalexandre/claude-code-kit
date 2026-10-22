# Working on this repo

For any agent (Claude Code, Codex, others) changing this kit:

- Read [CONTRIBUTING.md](CONTRIBUTING.md) first: how a part is laid out, described in `parts.json`, set up and tested.
- Everything must run on macOS (bash 3.2), Linux and Windows (Git Bash). Check before finishing: `bash tests/git-identity-guard.sh`, `bash tests/install-sandbox.sh --auto` (must end on `0 problem(s)`), and for a mod `cd mods && claude plugin test <mod>`.
- No personal data in any file (names, emails, hosts, paths). Ask before committing and pushing.
