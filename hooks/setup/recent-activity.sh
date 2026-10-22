#!/bin/bash
# Sets up recent-activity: the folder that holds your git repos. Run it again any time:
#   bash ~/.claude/hooks/setup/recent-activity.sh
set -eu
. "$HOME/.claude/hooks/lib/jq.sh"
. "$HOME/.claude/hooks/lib/ask.sh"

current=${CLAUDE_DEV_ROOT:-$(jq -r '.env.CLAUDE_DEV_ROOT // empty' "$HOME/.claude/settings.json" 2> /dev/null || true)}
current=${current:-$HOME/dev}
dir=$(reply recent-activity.dev "Folder that holds your git repos:" "$current")
dir=${dir/#\~/$HOME}
[ -d "$dir" ] || echo "  $dir doesn't exist yet; the digest stays empty until it does."
kit_env CLAUDE_DEV_ROOT "$(kit_path "$dir")"
echo "  Sessions started under $dir are listed at each session start."
