#!/bin/bash
# SessionStart hook of the team plugin: hands Claude the kit's base rules (rules/team.md) in the
# language picked in the plugin's options. Skipped when ~/.claude/CLAUDE.md already has them (a copy
# installed by install.sh), so they never show twice.
ROOT=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
RULES="$ROOT/rules/team.md"
heading=$(grep -m1 '^## ' "$RULES")
grep -qxF -- "$heading" "$HOME/.claude/CLAUDE.md" 2> /dev/null && exit 0
language=${CLAUDE_PLUGIN_OPTION_LANGUAGE:-English}
echo "The user's base rules for working with Claude (claude-code-kit team plugin), as binding as their CLAUDE.md:"
awk -v l="$language" '{ gsub(/__LANGUAGE__/, l) } 1' "$RULES"
