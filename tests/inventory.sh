#!/bin/bash
# Checks sync/inventory.sh in a throwaway sync repo and home: what it collects, the 30-minute
# pause, and the summary of two computers that differ. bash tests/inventory.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" SYNC_DIR="$T/sync"
mkdir -p "$HOME/.claude/plugins" "$HOME/.claude/mods/pane/.claude-plugin" "$HOME/my dev/kit/.claude-plugin" "$SYNC_DIR/machines"
cp "$KIT/sync/jq.sh" "$SYNC_DIR/"
. "$KIT/sync/jq.sh"
I() { bash "$KIT/sync/inventory.sh" "$@"; }
fails=0

check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

echo laptop > "$SYNC_DIR/.machine"
printf '{"devDir": "~/my dev"}\n' > "$SYNC_DIR/machines/laptop.json"
printf '{"version": 2, "plugins": {"notes@kit": [{"scope": "user", "version": "1.2.0", "installPath": "/secret/path"}]}}\n' > "$HOME/.claude/plugins/installed_plugins.json"
printf '{"name": "pane", "version": "0.3.0"}\n' > "$HOME/.claude/mods/pane/.claude-plugin/plugin.json"
printf '{"name": "my-kit", "plugins": []}\n' > "$HOME/my dev/kit/.claude-plugin/marketplace.json"
git -C "$HOME/my dev/kit" init -q && git -C "$HOME/my dev/kit" add -A &&
  git -C "$HOME/my dev/kit" -c user.email=t@t -c user.name=t commit -q -m "first"
touch "$HOME/my dev/kit/new-file"
mkdir -p "$HOME/my dev/team-kit" "$HOME/my dev/app"
echo '{"parts": []}' > "$HOME/my dev/team-kit/parts.json"
git -C "$HOME/my dev/team-kit" init -q
git -C "$HOME/my dev/app" init -q

I write
F="$SYNC_DIR/inventory/laptop.json"
check "it writes this computer's inventory" '[ "$(jq -r .machine "$F")" = laptop ] && [ -n "$(jq -r .os "$F")" ] && [ -n "$(jq -r .arch "$F")" ]'
check "with the tools it finds" '[ -n "$(jq -r .tools.bash "$F")" ] && [ "$(jq -r ".tools.jq // empty" "$F")" != "" ]'
check "the plugins with their version, never their paths" '[ "$(jq -r ".plugins[\"notes@kit\"].version" "$F")" = 1.2.0 ] && ! grep -q secret "$F"'
check "the mods" '[ "$(jq -r .mods.pane "$F")" = 0.3.0 ]'
check "each kit in a dev folder with a space, and its changed files" '[ "$(jq -r ".kits[0].name" "$F")" = my-kit ] && [ "$(jq -r ".kits[0].changed" "$F")" = 1 ]'
check "a kit installed by install.sh too, but no other repo" '[ "$(jq -r "[.kits[].name] | join(\",\")" "$F")" = my-kit,team-kit ]'

jq '.collected = "old"' "$F" > "$F.x" && mv "$F.x" "$F"
I write
check "it waits 30 minutes before collecting again" '[ "$(jq -r .collected "$F")" = old ]'
I write --now
check "unless asked to now" '[ "$(jq -r .collected "$F")" != old ]'

check "one computer alone is said so" 'I show | grep -q "Only this computer"'
jq '.machine = "desktop" | .tools.claude = "9.9.9 (Claude Code)" | .plugins["notes@kit"].version = "1.1.0"' "$F" > "$SYNC_DIR/inventory/desktop.json"
out=$(I show)
check "show lists every computer" '[[ "$out" == *"laptop  ("* ]] && [[ "$out" == *"desktop  ("* ]]'
check "and what differs between them" '[[ "$out" == *"plugin notes@kit: 1.1.0 on desktop / 1.2.0 on laptop"* ]] && [[ "$out" == *"Claude Code:"* ]]'
check "json gives them all" '[ "$(I json | jq length)" = 2 ]'

echo "$fails failure(s)"
[ "$fails" -eq 0 ]
