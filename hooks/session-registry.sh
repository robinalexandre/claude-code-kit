#!/bin/bash
# Usage: session-registry.sh start|end   (hook input JSON on stdin)
set -u
# Git Bash on Windows: native jq.exe writes CRLF unless -b is passed.
command -v cygpath >/dev/null 2>&1 && jq() { command jq -b "$@"; }
REGISTRY="$HOME/.claude/session-registry"
mkdir -p "$REGISTRY"

input=$(cat)
id=$(printf '%s' "$input" | jq -r '.session_id // empty')
[ -z "$id" ] && exit 0

case "${1:-}" in
  start)
    printf '%s' "$input" | jq -c '{
      session_id,
      session_name: (.session_name // null),
      cwd,
      transcript_path: (.transcript_path // null),
      source: (.source // null),
      registered_at: (now | todate)
    }' > "$REGISTRY/$id.json.tmp" && mv "$REGISTRY/$id.json.tmp" "$REGISTRY/$id.json"
    ;;
  end)
    rm -f "$REGISTRY/$id.json"
    ;;
esac
exit 0
