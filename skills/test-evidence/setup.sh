#!/bin/bash
# Sets up test-evidence: the browser it drives (the chrome-devtools MCP) and the tools it uses.
# Run it again any time: bash ~/.claude/skills/test-evidence/setup.sh
set -eu
. "$HOME/.claude/hooks/lib/jq.sh"
. "$HOME/.claude/hooks/lib/ask.sh"

kit_has jq perl || true
command -v ffmpeg > /dev/null 2>&1 || echo "  No ffmpeg: screenshots and network proof work, videos don't."
if jq -e '.mcpServers["chrome-devtools"]' "$HOME/.claude.json" > /dev/null 2>&1; then
  echo "  The chrome-devtools MCP is set up."
  exit 0
fi
echo "test-evidence drives Chrome through the chrome-devtools MCP server, not set up for all your projects yet."
if ! command -v claude > /dev/null 2>&1 || ! command -v npx > /dev/null 2>&1; then
  echo "  Needs claude and npx (Node.js) on the PATH, then: claude mcp add -s user chrome-devtools -- npx -y chrome-devtools-mcp@latest"
elif ask test-evidence.mcp "Add it (claude mcp add -s user chrome-devtools -- npx -y chrome-devtools-mcp@latest)?" y; then
  claude mcp add -s user chrome-devtools -- npx -y chrome-devtools-mcp@latest
fi
