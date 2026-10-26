#!/bin/bash
# sync.sh crypt with the memory folder: encrypting it keeps every computer's memory in clear and
# the repo's copy encrypted once; a computer that got ciphertext in its memory (an older engine,
# git-crypt's checkout stopping partway) neither shares nor commits it, and gets the clear
# version back once unlocked. Skipped where git-crypt is not installed. bash tests/sync-crypt-memory.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v git-crypt > /dev/null 2>&1 || {
  echo "skipped: git-crypt is not installed"
  exit 0
}
WORK=$(mktemp -d)
[ -n "${KEEP:-}" ] && echo "work folder kept: $WORK" || trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name t
fails=0
check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
is_cipher() { [ "$(LC_ALL=C head -c 10 "$1" | LC_ALL=C tr -d '\0')" = GITCRYPT ]; }
# computer NAME DIR HOME: a clone of the sync repo for computer NAME, with its own home folder.
computer() {
  local name=$1 dir=$2 home=$3
  mkdir -p "$home/.claude" "$home/dev"
  git clone -q "$WORK/remote.git" "$dir" 2> /dev/null
  echo "$name" > "$dir/.machine"
  mkdir -p "$dir/machines"
  printf '{"devDir": "%s"}\n' "$home/dev" > "$dir/machines/$name.json"
  [ -f "$dir/sync.sh" ] || cp "$KIT"/sync/*.sh "$KIT/sync/.gitattributes" "$KIT/sync/.gitignore" "$dir/"
}
# S HOME DIR ARGS…: runs that computer's sync.sh.
S() { HOME="$1" bash "$2/sync.sh" "${@:3}" 2>&1; }
memory_of() { S "$1" "$2" status | awk '/^memory:/ { sub(/^memory: */, ""); print; exit }'; }
native() { cygpath -w "$1" 2> /dev/null || printf '%s' "$1"; }
# folder HOME: a notes folder of the dev folder that Claude Code knows, and prints its memory folder.
folder() {
  mkdir -p "$1/dev/notes"
  jq -n --arg p "$(native "$1/dev/notes")" '{projects: {($p): {}}}' > "$1/.claude.json"
  printf '%s/.claude/projects/%s/memory' "$1" "$(native "$1/dev/notes" | sed 's/[^A-Za-z0-9]/-/g')"
}

git init -q --bare -b main "$WORK/remote.git" 2> /dev/null || { git init -q --bare "$WORK/remote.git" && git -C "$WORK/remote.git" symbolic-ref HEAD refs/heads/main; }
HA="$WORK/ha" A="$WORK/a"
computer mac "$A" "$HA"
git -C "$A" add -A && git -C "$A" commit -qm "first" && git -C "$A" push -q origin HEAD:main
MA=$(memory_of "$HA" "$A")
mkdir -p "$MA"
echo "Ride at dawn, the wind drops at noon." > "$MA/note.md"
FA=$(folder "$HA")
mkdir -p "$FA"
echo "Folder note: high tide at six." > "$FA/tide.md"
S "$HA" "$A" now > /dev/null
check "the memory is synced in clear before the encryption" 'git -C "$WORK/remote.git" show main:memory/note.md | grep -q "Ride at dawn" && git -C "$WORK/remote.git" show main:memory-folders/notes/tide.md | grep -q "high tide"'

S "$HA" "$A" crypt on memory memory-folders > /dev/null
S "$HA" "$A" now > /dev/null
check "after crypt on, the first sync keeps the local memory in clear" 'grep -q "Ride at dawn" "$MA/note.md"'
check "the repo holds the memory encrypted once" 'git -C "$A" cat-file --filters main:memory/note.md | grep -q "Ride at dawn" && git -C "$WORK/remote.git" show main:memory/note.md | is_cipher /dev/stdin'
S "$HA" "$A" crypt export "$WORK/key" > /dev/null

# A second computer whose memory holds the ciphertext, as an older engine left it.
HB="$WORK/hb" B="$WORK/b"
computer pc "$B" "$HB"
MB=$(memory_of "$HB" "$B")
mkdir -p "$MB"
git -C "$B" show HEAD:memory/note.md > "$MB/note.md"
FB=$(folder "$HB")
mkdir -p "$FB"
git -C "$B" show HEAD:memory-folders/notes/tide.md > "$FB/tide.md"
before=$(git -C "$WORK/remote.git" rev-parse main:memory/note.md)
S "$HB" "$B" now > /dev/null
check "while locked, the ciphertext in the memory is not shared" '[ "$(git -C "$WORK/remote.git" rev-parse main:memory/note.md)" = "$before" ]'
out=$(S "$HB" "$B" crypt unlock "$WORK/key")
check "unlock puts the memory back in clear" '[[ "$out" == *unlocked* ]] && grep -q "Ride at dawn" "$MB/note.md"'
check "and a folder's memory too" 'grep -q "high tide" "$FB/tide.md"'
check "and leaves the repo encrypted once" '[ "$(git -C "$WORK/remote.git" rev-parse main:memory/note.md)" = "$before" ]'

# A ciphertext left in the clone of an unlocked computer (git-crypt's checkout stopped partway).
tide=$(git -C "$WORK/remote.git" rev-parse main:memory-folders/notes/tide.md)
git -C "$B" show HEAD:memory-folders/notes/tide.md > "$B/memory-folders/notes/tide.md"
out=$(VERBOSE=1 S "$HB" "$B" now)
check "a ciphertext in the clone is left out of the commit, with a warning" '[ "$(git -C "$WORK/remote.git" rev-parse main:memory-folders/notes/tide.md)" = "$tide" ] && [[ "$out" == *"holds ciphertext"* ]]'
check "the local memory stays in clear" 'grep -q "Ride at dawn" "$MB/note.md" && grep -q "high tide" "$FB/tide.md"'

echo "$fails problem(s)"
exit $((fails > 0))
