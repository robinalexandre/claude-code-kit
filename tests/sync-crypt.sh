#!/bin/bash
# sync.sh crypt: encrypts a folder of the sync repo with git-crypt, a computer without the key
# leaves it alone (nothing applied, nothing added in clear) and says so, and the exported key
# unlocks it there. Skipped where git-crypt is not installed. bash tests/sync-crypt.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v git-crypt > /dev/null 2>&1 || {
  echo "skipped: git-crypt is not installed"
  exit 0
}
WORK=$(mktemp -d)
[ -n "${KEEP:-}" ] && echo "work folder kept: $WORK" || trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME/.claude" "$HOME/dev"
git config --global user.email t@example.com
git config --global user.name t
fails=0
check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
# A clone of the sync repo set up for computer NAME, as install.sh leaves it.
computer() {
  local name=$1 dir=$2
  git clone -q "$WORK/remote.git" "$dir"
  echo "$name" > "$dir/.machine"
  mkdir -p "$dir/machines"
  printf '{"devDir": "%s"}\n' "$HOME/dev" > "$dir/machines/$name.json"
  [ -f "$dir/sync.sh" ] || cp "$KIT"/sync/*.sh "$KIT/sync/.gitattributes" "$KIT/sync/.gitignore" "$dir/"
}
S() { bash "$1/sync.sh" "${@:2}" 2>&1; }

git init -q --bare -b main "$WORK/remote.git" 2> /dev/null || { git init -q --bare "$WORK/remote.git" && git -C "$WORK/remote.git" symbolic-ref HEAD refs/heads/main; }
A="$WORK/a"
computer mac "$A"
mkdir -p "$A/knowledge" "$A/claude"
echo "# rules" > "$A/claude/CLAUDE.md"
echo "Acme Books is the accounting firm." > "$A/knowledge/acme.md"
git -C "$A" add -A && git -C "$A" commit -qm "first" && git -C "$A" push -q origin HEAD:main
# A computer cloned before the encryption, which will commit before it pulls the change.
C="$WORK/c"
computer old "$C"
git -C "$C" add -A && git -C "$C" -c core.hooksPath=/dev/null commit -qm "old" > /dev/null && git -C "$C" push -q origin HEAD:main
git -C "$A" pull -q --rebase origin main

out=$(S "$A" crypt status)
check "status before: off" '[[ "$out" == *"encryption: off"* ]]'
out=$(S "$A" crypt on knowledge)
check "crypt on: says the folder is encrypted" '[[ "$out" == *"knowledge: encrypted from now on"* ]]'
check "the attributes line is after the marker" 'grep -q "^knowledge/\*\* filter=git-crypt" "$A/.gitattributes"'
check "the committed file is ciphertext" '[ "$(git -C "$A" show HEAD:knowledge/acme.md | LC_ALL=C head -c 9 | tr -d "\0")" = GITCRYPT ]'
check "the working copy is still clear" 'grep -q "Acme Books" "$A/knowledge/acme.md"'
check "pushed" '[ "$(git -C "$A" rev-parse HEAD)" = "$(git -C "$WORK/remote.git" rev-parse main)" ]'
out=$(S "$A" crypt status)
check "status after: unlocked" '[[ "$out" == *"encrypted folders: knowledge"* && "$out" == *"this computer: unlocked"* ]]'
S "$A" crypt export "$WORK/key" > /dev/null
check "export: a key file, readable by its owner only" '[ -f "$WORK/key" ] && [ "$(ls -l "$WORK/key" | cut -c1-10)" = "-rw-------" ]'

# The old computer writes in the folder before it has pulled the encryption, then syncs.
echo "A late note, written before the pull." > "$C/knowledge/late.md"
S "$C" now > /dev/null
check "a commit made before the pull is undone: nothing pushed in clear" '! git -C "$WORK/remote.git" grep -q "late note" main && [ -z "$(git -C "$C" ls-files knowledge/late.md)" ] && [ -f "$C/knowledge/late.md" ]'
check "the old computer is now locked and in sync" '[ "$(git -C "$C" rev-parse HEAD)" = "$(git -C "$WORK/remote.git" rev-parse main)" ] && [[ "$(S "$C" crypt status)" == *LOCKED* ]]'

# A computer that had the key but committed in the folder before pulling its encryption.
D="$WORK/d"
git clone -q "$WORK/remote.git" "$D" 2> /dev/null
git -C "$D" reset -q --hard "$(git -C "$D" rev-list --max-parents=0 HEAD | head -1)"
git -C "$D" reset -q --hard "$(git -C "$D" log --format=%H origin/main | tail -3 | head -1)"
echo pc2 > "$D/.machine"
printf '{"devDir": "%s"}\n' "$HOME/dev" > "$D/machines/pc2.json"
(cd "$D" && git-crypt unlock "$WORK/key" > /dev/null 2>&1)
echo "Written with the key, before the pull." > "$D/knowledge/early.md"
S "$D" now > /dev/null
check "a commit made with the key before the pull is made again through the filter" '[ "$(git -C "$WORK/remote.git" show main:knowledge/early.md | LC_ALL=C head -c 9 | tr -d "\0")" = GITCRYPT ] && ! git -C "$WORK/remote.git" grep -q "before the pull" main'

# A second computer, without the key.
B="$WORK/b"
computer pc "$B"
git -C "$B" add -A && git -C "$B" -c core.hooksPath=/dev/null commit -qm "pc" > /dev/null
check "locked clone sees ciphertext" '[ "$(LC_ALL=C head -c 9 "$B/knowledge/acme.md" | tr -d "\0")" = GITCRYPT ]'
out=$(S "$B" crypt status)
check "status on the locked computer" '[[ "$out" == *"this computer: LOCKED"* ]]'
echo "A new note written while locked." > "$B/knowledge/new.md"
S "$B" now > /dev/null
check "a file added while locked is not committed in clear" '[ -z "$(git -C "$B" ls-files knowledge/new.md)" ] && ! git -C "$WORK/remote.git" grep -q "written while locked" main'
out=$(echo '{}' | S "$B" start)
check "session start says the folders are locked" '[[ "$out" == *"locked on this computer"* && "$out" == *"crypt unlock"* ]]'
out=$(S "$B" crypt unlock "$WORK/key")
check "unlock: the files read clear" '[[ "$out" == *"unlocked"* ]] && grep -q "Acme Books" "$B/knowledge/acme.md"'
check "the note written while locked is now synced, encrypted" '[ -n "$(git -C "$B" ls-files knowledge/new.md)" ] && [ "$(git -C "$B" show HEAD:knowledge/new.md | LC_ALL=C head -c 9 | tr -d "\0")" = GITCRYPT ]'
out=$(S "$B" crypt on knowledge)
check "crypt on twice: already encrypted" '[[ "$out" == *"already encrypted"* ]]'

# The engine's setup keeps the encrypted folders across an engine update.
cp "$KIT/sync/setup.sh" "$WORK/setup.sh"
(
  cd "$A" && HOME="$WORK/home" SYNC_DIR="$A" bash -c '
    HERE="'"$KIT"'/sync"; SYNC="'"$A"'"
    . "$HERE/../hooks/lib/jq.sh"
    CRYPT_MARK="# encrypted folders (sync.sh crypt): everything below is kept by sync.sh"
    put_engine() { local f crypt=""; [ -f "$SYNC/.gitattributes" ] && crypt=$(awk -v m="$CRYPT_MARK" "\$0 == m { on = 1; next } on" "$SYNC/.gitattributes"); cp "$HERE/.gitattributes" "$SYNC/.gitattributes"; [ -z "$crypt" ] || printf "%s\n" "$crypt" >> "$SYNC/.gitattributes"; }
    put_engine'
)
check "an engine update keeps the encrypted folders" 'grep -q "^knowledge/\*\* filter=git-crypt" "$A/.gitattributes" && [ "$(grep -c "encrypted folders (sync.sh crypt)" "$A/.gitattributes")" = 1 ]'

echo "$fails problem(s)"
exit $((fails > 0))
