#!/bin/bash
# Checks hooks/kit-update-check.sh and install.sh --update in a throwaway home, with a clone of a
# throwaway copy of this kit: silence while up to date, a note for an installed part changed
# upstream and silence for the others, the update itself, off and on. bash tests/kit-update-check.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
. "$KIT/hooks/lib/jq.sh"
. "$KIT/hooks/lib/ask.sh"
export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
unset CLAUDE_CONFIG_DIR
mkdir -p "$HOME"
git config --global user.name kit-test
git config --global user.email kit-test@example.com
git config --global init.defaultBranch main
RECORD="$HOME/.claude/kit-install.json"
C="$HOME/.claude/hooks/kit-update-check.sh"
fails=0

check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

start() { bash "$C"; }
commit_of() { jq -r --arg p "$1" '.parts[$p].commit' "$RECORD"; }
publish() {
  echo "# change" >> "$T/upstream/$1"
  git -C "$T/upstream" commit -qam "change $1"
}

mkdir -p "$T/upstream"
(cd "$KIT" && git ls-files -co --exclude-standard | while IFS= read -r f; do [ -f "$f" ] && echo "$f"; done | tar -cf - -T -) |
  tar -xf - -C "$T/upstream"
git -C "$T/upstream" init -q && git -C "$T/upstream" add -A && git -C "$T/upstream" commit -qm base
git clone -q "$T/upstream" "$T/kit"

check "no record: nothing said" '[ -z "$(start 2> /dev/null)" ]'

bash "$T/kit/install.sh" file-tools-guard ci-review > "$T/install.log" 2>&1 < /dev/null
check "install records the clone" '[ "$(jq -r .kit "$RECORD")" = "$(kit_path "$T/kit")" ]'
check "and each part with its commit and files" '[ "$(jq -c ".parts[\"ci-review\"].files" "$RECORD")" = "[\"skills/ci-review\"]" ] &&
  [ "$(commit_of file-tools-guard)" = "$(git -C "$T/kit" rev-parse HEAD)" ]'
check "the check comes with every install" 'jq -e "[.hooks.SessionStart[].hooks[].command] | any(test(\"kit-update-check.sh\"))" "$HOME/.claude/settings.json" > /dev/null'

touch "$HOME/.claude/kit-update/fetched" 2> /dev/null || { mkdir -p "$HOME/.claude/kit-update" && touch "$HOME/.claude/kit-update/fetched"; }
check "up to date: nothing said" '[ -z "$(start)" ]'

publish README.md
bash "$C" fetch
check "a change no installed part uses: nothing said" '[ -z "$(start)" ]'

publish skills/ci-review/SKILL.md
bash "$C" fetch
out=$(start)
check "a change to an installed part is told" '[[ "$out" == *"Changes for the parts installed here: ci-review"* && "$out" == *"- change skills/ci-review/SKILL.md"* && "$out" == *"install.sh\" --update"* ]]'
check "without the parts it didn't touch, or the other commits" '[[ "$out" != *file-tools-guard* && "$out" != *README* ]]'
check "told once" '[ -z "$(start)" ]'
check "changed lists it" '[ "$(bash "$C" changed)" = ci-review ]'

bash "$C" off > /dev/null
bash "$C" fetch
check "off: nothing said" '[ -z "$(start)" ]'
bash "$C" on > /dev/null

before=$(commit_of file-tools-guard)
bash "$T/kit/install.sh" --update > "$T/update.log" 2>&1 < /dev/null
check "update pulls and installs the changed part" 'tail -1 "$HOME/.claude/skills/ci-review/SKILL.md" | grep -qx "# change"'
check "its commit moves" '[ "$(commit_of ci-review)" = "$(git -C "$T/kit" rev-parse HEAD)" ]'
check "the other parts keep theirs" '[ "$(commit_of file-tools-guard)" = "$before" ]'
bash "$C" fetch
check "nothing left to say after the update" '[ -z "$(start)" ]'
check "update with nothing new" 'bash "$T/kit/install.sh" --update 2>&1 < /dev/null | grep -q "No installed part changed"'

case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) elsewhere=linux ;; *) elsewhere=windows ;; esac
for p in demo-skill elsewhere-skill; do
  mkdir -p "$T/upstream/skills/$p" && printf -- '---\nname: %s\n---\n' "$p" > "$T/upstream/skills/$p/SKILL.md"
done
jq --arg os "$elsewhere" '.parts += [
  {name: "demo-skill", kind: "skill", group: "dev", what: "A demo skill."},
  {name: "elsewhere-skill", kind: "skill", group: "dev", os: [$os], what: "Another system only."}]' \
  "$T/upstream/parts.json" > "$T/parts.json" && mv "$T/parts.json" "$T/upstream/parts.json"
git -C "$T/upstream" add -A && git -C "$T/upstream" commit -qm "add demo-skill"
bash "$C" fetch
out=$(start)
check "a new part is offered" '[[ "$out" == *"New parts, not offered before:"* && "$out" == *"- demo-skill: A demo skill."* ]]'
check "only when this system has it" '[[ "$out" != *elsewhere-skill* ]]'
bash "$C" fetch
check "a new part is told once" '[ -z "$(start)" ]'
bash "$T/kit/install.sh" --update demo-skill > "$T/update.log" 2>&1 < /dev/null
check "update installs a new part named after it" '[ -f "$HOME/.claude/skills/demo-skill/SKILL.md" ] && [ "$(commit_of demo-skill)" = "$(git -C "$T/kit" rev-parse HEAD)" ]'

rm -f "$HOME/.claude/kit-update/fetched"
start > /dev/null
check "a check starts when the last is a day old" '[ -f "$HOME/.claude/kit-update/fetched" ]'
sleep 2

echo "$fails problem(s)"
[ "$fails" = 0 ]
