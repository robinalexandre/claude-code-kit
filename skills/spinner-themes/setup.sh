#!/bin/bash
# Picks the themes of the words Claude Code shows while it works. Run it again any time:
# bash <this folder>/setup.sh
set -eu
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$SK/../../hooks/lib"
. "$LIB/jq.sh"
. "$LIB/ask.sh"
. "$LIB/kit.sh"

echo "While it works, Claude Code shows a word (\"Thinking…\", \"Pondering…\"). This sets those words from themes."
bash "$SK/spinner-themes.sh" list | sed 's/^/  /'
echo "Name one or more, separated by spaces (empty keeps Claude Code's own words). Ask Claude for any other theme later."
themes=$(reply spinner-themes.themes "Themes:" "")
themes=$(printf '%s' "$themes" | tr ',' ' ')
if [ -n "${themes// /}" ]; then
  # shellcheck disable=SC2086
  bash "$SK/spinner-themes.sh" set $themes
fi
kit_setup_mark spinner-themes "done"
