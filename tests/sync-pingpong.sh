#!/bin/bash
# Two computers stop pushing their own copy back over the other's change: a JSON file written
# with other whitespace is the same file, and a line that only looks like it holds a secret
# (# id-token: the action…) can be rewritten on the other computer, the local copy going to
# .state/trash. A secret line the incoming change can't fill back is still kept.
# bash tests/sync-pingpong.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
[ -n "${KEEP:-}" ] && echo "work folder kept: $WORK" || trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name t
fails=0
check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
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
blob() { git -C "$WORK/remote.git" rev-parse "main:$1"; }

git init -q --bare -b main "$WORK/remote.git" 2> /dev/null || { git init -q --bare "$WORK/remote.git" && git -C "$WORK/remote.git" symbolic-ref HEAD refs/heads/main; }
HA="$WORK/ha" A="$WORK/a" HB="$WORK/hb" B="$WORK/b"
computer mac "$A" "$HA"
echo "# Rules" > "$HA/.claude/CLAUDE.md"
mkdir -p "$HA/.claude/mods/demo/hooks" "$HA/.claude/skills/demo"
echo '{ "modules": ["./register.ts"] }' > "$HA/.claude/mods/demo/hooks/hooks.json"
printf '%s\n' 'on: push' '# id-token: the action trades it for its token.' 'permissions: {}' > "$HA/.claude/skills/demo/ci.yml"
printf '%s\n' 'password: hunter2 # prod' 'user: me' > "$HA/.claude/skills/demo/db.yml"
S "$HA" "$A" init > /dev/null
S "$HA" "$A" now > /dev/null
check "the line that looks like a secret is masked in the repo" 'git -C "$WORK/remote.git" show main:claude/skills/demo/ci.yml | grep -q "token: __SECRET__"'

computer pc "$B" "$HB"
S "$HB" "$B" install > /dev/null
printf '{\n  "modules": [\n    "./register.ts"\n  ]\n}\n' > "$HB/.claude/mods/demo/hooks/hooks.json"
printf '%s\n' 'on: push' '# The id-token permission lets the action trade it for its token.' 'permissions: {}' > "$HB/.claude/skills/demo/ci.yml"
printf '%s\n' 'password: __SECRET__ # staging' 'user: me' > "$HB/.claude/skills/demo/db.yml"
S "$HB" "$B" now > /dev/null
hooks=$(blob claude/mods/demo/hooks/hooks.json)

out=$(VERBOSE=1 S "$HA" "$A" now)
check "the rewritten line reaches the first computer" 'grep -qxF "# The id-token permission lets the action trade it for its token." "$HA/.claude/skills/demo/ci.yml"'
check "the local copy it replaced is in the trash" 'grep -rqF "# id-token: the action" "$A/.state/trash"'
check "a JSON file that only differs in whitespace is not pushed back" '[ "$(blob claude/mods/demo/hooks/hooks.json)" = "$hooks" ]'
check "a secret line the change can't fill back is kept" 'grep -qxF "password: hunter2 # prod" "$HA/.claude/skills/demo/db.yml"'
check "with a warning" '[[ "$out" == *"version was kept"*db.yml* ]]'

S "$HB" "$B" now > /dev/null
S "$HA" "$A" now > /dev/null
check "the rewritten line stays in the repo" 'git -C "$WORK/remote.git" show main:claude/skills/demo/ci.yml | grep -q "The id-token permission"'
check "the JSON file still holds the second computer's form" '[ "$(blob claude/mods/demo/hooks/hooks.json)" = "$hooks" ]'
check "the first computer keeps its own form" 'grep -qxF "{ \"modules\": [\"./register.ts\"] }" "$HA/.claude/mods/demo/hooks/hooks.json"'

echo "$fails problem(s)"
exit $((fails > 0))
