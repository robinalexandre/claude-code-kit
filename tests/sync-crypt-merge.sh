#!/bin/bash
# Two computers with the key change the same files of an encrypted folder: their syncs merge them
# as they merge clear files (JSON by key, other text line by line), the result stays encrypted in
# the repo, and only a real conflict (the same line changed on both) stops a sync. Git hands a merge
# driver the encrypted bytes, so without crypt-merge.sh every such change conflicted. Skipped
# where git-crypt is not installed. bash tests/sync-crypt-merge.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v git-crypt > /dev/null 2>&1 || {
  echo "skipped: git-crypt is not installed"
  exit 0
}
WORK=$(mktemp -d)
[ -n "${KEEP:-}" ] && echo "work folder kept: $WORK" || trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1 SYNC_RETRIES=0
mkdir -p "$HOME/.claude" "$HOME/dev"
git config --global user.email t@example.com
git config --global user.name t
fails=0
check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
computer() {
  local name=$1 dir=$2
  git clone -q "$WORK/remote.git" "$dir" 2> /dev/null
  echo "$name" > "$dir/.machine"
  mkdir -p "$dir/machines"
  printf '{"devDir": "%s"}\n' "$HOME/dev" > "$dir/machines/$name.json"
  [ -f "$dir/sync.sh" ] || cp "$KIT"/sync/*.sh "$KIT/sync/.gitattributes" "$KIT/sync/.gitignore" "$dir/"
}
S() { bash "$1/sync.sh" "${@:2}" < /dev/null 2>&1; }
stored() { git -C "$WORK/remote.git" show "main:$1" | LC_ALL=C head -c 9 | tr -d '\0'; }
clear_at() { git -C "$1" cat-file --filters "origin/main:$2"; }

git init -q --bare -b main "$WORK/remote.git" 2> /dev/null || { git init -q --bare "$WORK/remote.git" && git -C "$WORK/remote.git" symbolic-ref HEAD refs/heads/main; }
A="$WORK/a"
computer mac "$A"
mkdir -p "$A/state" "$A/claude"
echo "# rules" > "$A/claude/CLAUDE.md"
printf '{\n "checked": "monday",\n "votes": {"ada": "none"},\n "note": "first"\n}\n' > "$A/state/pr.json"
printf 'line one\nline two\nline three\nline four\nline five\n' > "$A/state/notes.md"
git -C "$A" add -A && git -C "$A" commit -qm "first" && git -C "$A" push -q origin HEAD:main
S "$A" crypt on state > /dev/null
S "$A" crypt export "$WORK/key" > /dev/null
check "the folder's line asks for the crypt merge driver" 'grep -q "^state/\*\* filter=git-crypt diff=git-crypt merge=crypt$" "$A/.gitattributes"'

# A folder encrypted by an older sync.sh, whose line has no merge driver: the next sync adds it.
printf 'old/** filter=git-crypt diff=git-crypt\n' >> "$A/.gitattributes"
S "$A" now > /dev/null
check "an older line gets the crypt merge driver" 'grep -q "^old/\*\* filter=git-crypt diff=git-crypt merge=crypt$" "$A/.gitattributes" && git -C "$WORK/remote.git" show main:.gitattributes | grep -q "^old/.* merge=crypt$"'

B="$WORK/b"
computer pc "$B"
(cd "$B" && git-crypt unlock "$WORK/key" > /dev/null 2>&1)
S "$B" now > /dev/null

# Each computer changes other keys of the JSON file and other lines of the text file.
printf '{\n "checked": "tuesday",\n "votes": {"ada": "none"},\n "note": "first"\n}\n' > "$A/state/pr.json"
printf 'line ONE\nline two\nline three\nline four\nline five\n' > "$A/state/notes.md"
S "$A" now > /dev/null
printf '{\n "checked": "monday",\n "votes": {"ada": "approved"},\n "note": "first"\n}\n' > "$B/state/pr.json"
printf 'line one\nline two\nline three\nline four\nline FIVE\n' > "$B/state/notes.md"
out=$(S "$B" now)
check "the second computer's sync goes through" '[ "$(git -C "$B" rev-parse HEAD)" = "$(git -C "$WORK/remote.git" rev-parse main)" ] && [[ "$out" != *"same file changed"* ]]'
check "the JSON file holds both changes" '[ "$(clear_at "$B" state/pr.json | jq -c "[.checked, .votes.ada]")" = "[\"tuesday\",\"approved\"]" ]'
check "the text file holds both changes" '[ "$(clear_at "$B" state/notes.md | tr "\n" " ")" = "line ONE line two line three line four line FIVE " ]'
check "both stay encrypted in the repo" '[ "$(stored state/pr.json)" = GITCRYPT ] && [ "$(stored state/notes.md)" = GITCRYPT ]'
check "and read clear on the computer" 'grep -q FIVE "$B/state/notes.md" && grep -q approved "$B/state/pr.json"'

# The same line changed on both: still a conflict, and nothing goes out in clear.
S "$A" now > /dev/null
sed 's/line two/line two from A/' "$A/state/notes.md" > "$WORK/n" && cp "$WORK/n" "$A/state/notes.md"
S "$A" now > /dev/null
sed 's/line two/line two from B/' "$B/state/notes.md" > "$WORK/n" && cp "$WORK/n" "$B/state/notes.md"
S "$B" now > /dev/null
check "the same line changed on both stops the sync" '[ "$(git -C "$B" rev-parse HEAD)" != "$(git -C "$WORK/remote.git" rev-parse main)" ]'
check "nothing in clear on the remote" '! git -C "$WORK/remote.git" grep -q "line two from" main && [ "$(stored state/notes.md)" = GITCRYPT ]'

echo "$fails problem(s)"
exit $((fails > 0))
