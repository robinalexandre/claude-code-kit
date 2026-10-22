#!/bin/bash
# Sets up the status line: points statusLine in ~/.claude/settings.json at the kit's script.
# As a plugin, KIT_HOME is the plugin's data folder, where each session start keeps the script current.
set -eu
LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)
. "$LIB/jq.sh"
. "$LIB/ask.sh"
. "$LIB/kit.sh"
KIT_HOME=${KIT_HOME:-$(cd "$LIB/../.." && pwd)}
script="$KIT_HOME/statusline-command.sh"
settings="$HOME/.claude/settings.json"
[ -f "$script" ] || {
  echo "  $script isn't there yet: start a Claude Code session once, then run this again." >&2
  exit 1
}

command="bash \"$(kit_path "$script")\""
current=$(jq -r '.statusLine.command // empty' "$settings" 2> /dev/null || true)
if [ "$current" = "$command" ]; then
  echo "  The status line is already set."
elif [ -n "$current" ] && ! ask statusline.replace "Replace your status line ($current)?"; then
  kit_setup_mark statusline declined
  exit 0
else
  mkdir -p "$HOME/.claude"
  [ -f "$settings" ] || echo '{}' > "$settings"
  cp -p "$settings" "$settings.before-statusline"
  jq --indent 2 --arg c "$command" '.statusLine = {type: "command", command: $c}' "$settings.before-statusline" > "$settings"
  echo "  Status line set (previous settings in $settings.before-statusline). It shows from the next session."
fi
kit_setup_mark statusline done
