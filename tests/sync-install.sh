#!/bin/bash
# Checks how sync/install.sh names the computer, in a throwaway home folder: a name another
# computer's report claims is refused, this computer's own name is kept. Every run here stops before
# the sync is set up (no git identity), so nothing outside the folder is touched. bash tests/sync-install.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0

check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

SYNC="$T/home/.claude-sync"
mkdir -p "$SYNC/inventory" "$SYNC/machines"
cp "$KIT"/sync/*.sh "$SYNC/"
git -C "$SYNC" init -q
here=$(hostname 2> /dev/null | tr -d '\r' | head -1)
printf '{"machine": "mac", "host": "someone-elses-mac"}\n' > "$SYNC/inventory/mac.json"
printf '{"machine": "pc", "host": "%s"}\n' "$here" > "$SYNC/inventory/pc.json"

install() {
  env -u CLAUDE_CONFIG_DIR HOME="$T/home" GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
    bash "$SYNC/install.sh" "$@" < /dev/null > "$T/out" 2>&1
}
said() { grep -q "$1" "$T/out"; }

install mac
check "a name another computer uses is refused" 'said "already goes by mac" && ! said "git name"'
install 'my mac'
check "a name with a space is refused" 'said "letters, digits"'
install ../mac
check "a name that leaves the folder is refused" 'said "letters, digits"'
install pc
check "a name this computer reported is kept" '! said "already goes by" && said "git name"'
install home-mac
check "a new name is kept" '! said "already goes by" && said "git name"'
echo mac > "$SYNC/.machine"
install mac
check "this computer's own name is kept when its hostname changed" '! said "already goes by" && said "git name"'

echo "$fails failure(s)"
[ "$fails" -eq 0 ]
