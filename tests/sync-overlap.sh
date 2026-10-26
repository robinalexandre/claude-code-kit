#!/bin/bash
# Checks that two syncs on one computer never run together: a lock whose run still goes on is not
# taken over however old it is (a Windows run with its retries lasts minutes), one whose run is gone
# is, a run never removes a lock it does not own, and each run keeps its scratch files apart.
# Two runs sharing them wrote one file's content into another. In a throwaway home, sync repo and
# remote. bash tests/sync-overlap.sh [folder holding sync.sh]
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=${1:-$KIT/sync}
T=$(mktemp -d)
trap 'kill "$alive" 2> /dev/null; rm -rf "$T"' EXIT
fails=0

check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

export HOME="$T/home" SYNC_DIR="$T/home/.claude-sync" SYNC_RETRIES=0
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
unset CLAUDE_CONFIG_DIR
git config --global user.email t@t && git config --global user.name t
S=$SYNC_DIR
mkdir -p "$HOME/.claude/skills/one" "$HOME/dev" "$S/machines" "$S/claude"
cp "$SRC"/*.sh "$KIT/sync/.gitignore" "$KIT/sync/.gitattributes" "$S/"
echo '# notes' > "$HOME/.claude/CLAUDE.md"
echo '{}' > "$HOME/.claude/settings.json"
printf -- '---\nname: one\n---\n' > "$HOME/.claude/skills/one/SKILL.md"
# Redacted on the way out, so it goes through the scratch files.
printf 'password: hunter2\n' > "$HOME/.claude/skills/one/notes.md"
echo '{"devDir": "~/dev"}' > "$S/machines/pc.json"
echo pc > "$S/.machine"
git init -q --bare "$T/remote.git"
git -C "$S" init -q -b main && git -C "$S" add -A && git -C "$S" commit -q -m first
git -C "$S" remote add origin "$T/remote.git"
sync() { bash "$S/sync.sh" "$@" < /dev/null > "$T/out" 2>&1; }
# A lock made 10 minutes ago, owned by PID.
old_lock() {
  rm -rf "$S/.state/lock" && mkdir -p "$S/.state/lock" && echo "$1" > "$S/.state/lock/pid"
  touch -t "$(date -d '-10 minutes' +%Y%m%d%H%M 2> /dev/null || date -v-10M +%Y%m%d%H%M)" "$S/.state/lock"
}

sync now
check "a first sync pushes" 'grep -q "pushed to the sync repo" "$S/.state/log"'
check "and leaves no scratch file behind" '[ -z "$(ls "$S/.state" | grep -xE "view|out|merged|shared.json|settings.json|was|was.json|in|mcp-(local|old|new|want).json")" ] && [ -z "$(ls -A "$S/.state/tmp" 2> /dev/null)" ]'

sleep 600 &
alive=$!
old_lock "$alive"
echo "# changed" > "$HOME/.claude/CLAUDE.md"
: > "$S/.state/log"
sync now
check "a lock 10 minutes old whose run goes on is kept" 'grep -q "another sync is running" "$S/.state/log" && ! grep -q "pushed" "$S/.state/log"'
check "and left as it was" '[ "$(cat "$S/.state/lock/pid")" = "$alive" ]'

bash -c 'exit 0' &
dead=$!
wait "$dead"
old_lock "$dead"
echo "# changed once more" > "$HOME/.claude/CLAUDE.md"
: > "$S/.state/log"
sync now
check "a lock whose run is gone is taken over" 'grep -q "pushed to the sync repo" "$S/.state/log"'
check "and released at the end" '[ ! -e "$S/.state/lock" ]'

# A run that loses its lock to another one (taken over as stale) leaves the new owner's lock alone.
: > "$S/.state/log"
(for _ in $(seq 200); do [ -f "$S/.state/lock/pid" ] && break; sleep 0.05; done
  echo "$alive" > "$S/.state/lock/pid") &
echo "# changed again" > "$HOME/.claude/CLAUDE.md"
sync now
wait $!
check "a run never removes a lock it does not own" '[ "$(cat "$S/.state/lock/pid" 2> /dev/null)" = "$alive" ]'
rm -rf "$S/.state/lock"

echo "$fails failure(s)"
[ "$fails" -eq 0 ]
