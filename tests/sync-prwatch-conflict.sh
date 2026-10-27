#!/bin/bash
# Two computers both run pr-watch: one deletes a record (its PR ended and it moved to done/, it is no
# longer watched, or it aged out of done/) while the other rewrites it. The sync settles that
# modify/delete conflict by itself: the deletion wins for an active record, done/ keeps the record
# left. A conflict anywhere else still stops the sync.
# bash tests/sync-prwatch-conflict.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
[ -n "${KEEP:-}" ] && echo "work folder kept: $WORK" || trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1 SYNC_RETRIES=0
git config --global user.email t@example.com
git config --global user.name t
fails=0
check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
computer() {
  local name=$1 dir=$2 home=$3
  mkdir -p "$home/.claude" "$home/dev"
  git clone -q "$WORK/remote.git" "$dir" 2> /dev/null
  echo "$name" > "$dir/.machine"
  mkdir -p "$dir/machines"
  printf '{"devDir": "%s"}\n' "$home/dev" > "$dir/machines/$name.json"
  [ -f "$dir/sync.sh" ] || cp "$KIT"/sync/*.sh "$KIT/sync/.gitattributes" "$KIT/sync/.gitignore" "$dir/"
}
S() { HOME="$1" bash "$2/sync.sh" "${@:3}" 2>&1; }
on_remote() { git -C "$WORK/remote.git" cat-file -e "main:$1" 2> /dev/null; }
# record DIR FILE N STAMP [ENDED]: writes a pr-watch record, in done/ when ENDED is given.
record() {
  local status=active ended=""
  [ -n "${5:-}" ] && status=merged ended=$(printf ',\n "ended": "%s"' "$5")
  mkdir -p "$(dirname "$1/pr-watch/$2")"
  printf '{\n "url": "https://example.com/pr/%s",\n "checked": "%s",\n "seen": {"status": "%s", "comments": %s}%s\n}\n' \
    "$3" "$4" "$status" "$(($3 * 7))" "$ended" > "$1/pr-watch/$2"
}

git init -q --bare -b main "$WORK/remote.git" 2> /dev/null || { git init -q --bare "$WORK/remote.git" && git -C "$WORK/remote.git" symbolic-ref HEAD refs/heads/main; }
HA="$WORK/ha" A="$WORK/a" HB="$WORK/hb" B="$WORK/b"
computer mac "$A" "$HA"
echo "# Rules" > "$HA/.claude/CLAUDE.md"
record "$A" repo-1.json 1 2026-01-01T10:00Z
record "$A" repo-2.json 2 2026-01-01T10:00Z
record "$A" done/repo-3.json 3 2026-01-01T10:00Z 2025-12-01T10:00Z
record "$A" repo-4.json 4 2026-01-01T10:00Z
echo "first" > "$A/notes.txt"
S "$HA" "$A" init > /dev/null
S "$HA" "$A" now > /dev/null
computer pc "$B" "$HB"
S "$HB" "$B" install > /dev/null

record "$A" repo-1.json 1 2026-01-02T09:00Z
rm "$A/pr-watch/repo-2.json"
record "$A" done/repo-2.json 2 2026-01-02T09:00Z 2026-01-02T09:00Z
record "$A" done/repo-3.json 3 2026-01-02T09:00Z 2025-12-01T10:00Z
S "$HA" "$A" now > /dev/null

rm "$B/pr-watch/repo-1.json"
record "$B" done/repo-1.json 1 2026-01-02T09:05Z 2026-01-02T09:05Z
record "$B" repo-2.json 2 2026-01-02T09:05Z
rm "$B/pr-watch/done/repo-3.json"
out=$(S "$HB" "$B" now)
check "the sync goes through" '! [ -f "$B/.state/error" ] && [ -z "$(git -C "$B" rev-list -1 origin/main..HEAD)" ]'
check "no rebase is left half done" '! [ -d "$B/.git/rebase-merge" ] && ! [ -d "$B/.git/rebase-apply" ]'
check "a record that ended here is no longer watched" '! on_remote pr-watch/repo-1.json && on_remote pr-watch/done/repo-1.json'
check "a record that ended there is no longer watched" '! on_remote pr-watch/repo-2.json && on_remote pr-watch/done/repo-2.json'
check "an old done/ record changed there is kept" 'on_remote pr-watch/done/repo-3.json'
S "$HA" "$A" now > /dev/null
check "the other computer gets the same records" '! [ -e "$A/pr-watch/repo-1.json" ] && ! [ -e "$A/pr-watch/repo-2.json" ] && [ -e "$A/pr-watch/done/repo-1.json" ]'

rm "$A/pr-watch/repo-4.json"
S "$HA" "$A" now > /dev/null
record "$B" repo-4.json 4 2026-01-03T09:00Z
S "$HB" "$B" now > /dev/null
check "a record no longer watched there stays gone when only its check changed here" '! on_remote pr-watch/repo-4.json && ! [ -f "$B/.state/error" ] && [ -z "$(git -C "$B" rev-list -1 origin/main..HEAD)" ]'
check "and is gone here too" '! [ -e "$B/pr-watch/repo-4.json" ]'

rm "$A/notes.txt"
S "$HA" "$A" now > /dev/null
echo "second" > "$B/notes.txt"
out=$(S "$HB" "$B" now)
check "a conflict outside pr-watch still stops the sync" '[ -f "$B/.state/error" ] && [[ "$out" == *"the same file changed"* ]]'
check "and leaves no rebase half done" '! [ -d "$B/.git/rebase-merge" ] && ! [ -d "$B/.git/rebase-apply" ]'

echo "$fails problem(s)"
exit $((fails > 0))
