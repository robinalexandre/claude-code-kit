#!/bin/bash
# The secrets of a synced text file are masked in the sync repo, its code is not: a type
# annotation after a secret-looking name (_TOKEN: list[str] = []) stays as written, a value is
# masked, and the computer's own file keeps its values. bash tests/sync-redact.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
[ -n "${KEEP:-}" ] && echo "work folder kept: $WORK" || trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME/.claude/skills/demo" "$HOME/dev"
git config --global user.email t@example.com
git config --global user.name t
fails=0
check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

git init -q --bare -b main "$WORK/remote.git" 2> /dev/null || { git init -q --bare "$WORK/remote.git" && git -C "$WORK/remote.git" symbolic-ref HEAD refs/heads/main; }
A="$WORK/a"
git clone -q "$WORK/remote.git" "$A" 2> /dev/null
echo mac > "$A/.machine"
mkdir -p "$A/machines"
printf '{"devDir": "%s"}\n' "$HOME/dev" > "$A/machines/mac.json"
cp "$KIT"/sync/*.sh "$KIT/sync/.gitattributes" "$KIT/sync/.gitignore" "$A/"
git -C "$A" add -A && git -C "$A" commit -qm "first" && git -C "$A" push -q origin HEAD:main

F="$HOME/.claude/skills/demo/demo.py"
printf '%s\n' \
  '_GITHUB_TOKEN: list[str] = []' \
  'client_secret: str = ""' \
  'token = get_token()' \
  'password = "hunter2"' \
  'api_key: abcdef123456' > "$F"
cp "$F" "$WORK/original.py"
bash "$A/sync.sh" now > /dev/null 2>&1
S="$A/claude/skills/demo/demo.py"
check "the file is synced" '[ -f "$S" ]'
check "a generic type annotation is kept" 'grep -qxF "_GITHUB_TOKEN: list[str] = []" "$S"'
check "an annotation with a default is kept" 'grep -qxF "client_secret: str = \"\"" "$S"'
check "a function call is kept" 'grep -qxF "token = get_token()" "$S"'
check "a quoted value is masked" 'grep -qxF "password = \"__SECRET__\"" "$S" && ! grep -q hunter2 "$S"'
check "a bare value is masked" 'grep -qxF "api_key: __SECRET__" "$S"'
check "the local file keeps its values" 'cmp -s "$F" "$WORK/original.py"'

echo "$fails problem(s)"
exit $((fails > 0))
