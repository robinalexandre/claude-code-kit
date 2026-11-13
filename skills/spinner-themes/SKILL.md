---
name: spinner-themes
description: Sets the words Claude Code shows while it thinks and works (the spinner verbs) from themes the user picks, such as wingfoil, surf, motorsport, skiing or cycling, and writes new themes on request for any sport, hobby or universe. Use when the user says "spinner words", "thinking words", "spinner verbs", "the words while Claude thinks", "mots de réflexion", "change my spinner", "make the spinner about <topic>", "add a <topic> theme", "back to the default words", or notices Claude Code's own words mixed in with theirs.
---

# Spinner themes

`$SK` is this skill's base directory. `spinner-themes.sh` writes `spinnerVerbs` into `~/.claude/settings.json` from theme files: one word or phrase per line, built-in ones in `$SK/themes/`, the user's own in `~/.claude/spinner-themes/` (one there overrides a built-in theme of the same name).

1. **See what is there**: `bash "$SK/spinner-themes.sh" list` and `current`. When the user's words are mixed with Claude Code's own, the mode is `append`: setting the themes again fixes it (`replace` is the default).
2. **Agree on the themes.** Use those the user named; otherwise show the list and ask which ones.
3. **A theme that doesn't exist yet**: write `~/.claude/spinner-themes/<theme>.txt` (lowercase, hyphens), 20 to 30 entries in the language Claude Code's interface is in (English unless the user says otherwise): actions in the -ing form or short phrases that read well followed by "…" ("Dropping in…", "Hitting the apex…"), real jargon of the activity that people who do it would recognize, nothing offensive. Show the list and adjust it before using it.
4. **Apply**: `bash "$SK/spinner-themes.sh" set <theme> <theme>…`. Add `--append` only when the user wants Claude Code's own words kept too. `off` goes back to Claude Code's own words. The words show in sessions started from then on.

The settings file is the user's own: the script changes only the `spinnerVerbs` key. With a config sync that rebuilds `settings.json` from shared files, the change is saved back to them at the next sync; check that it stuck with `current` after a sync.
