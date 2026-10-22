#!/bin/bash
# Checks how sync/sync.sh copes with a sync that fails where processes may fail to start (Windows,
# forced here with SYNC_RETRIES): it tries again, and the Stop hook tells the user once when it keeps
# failing or never finishes. In a throwaway home, sync repo and remote. bash tests/sync-retry.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0

check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

export HOME="$T/home" SYNC_DIR="$T/home/.claude-sync" SYNC_RETRIES=2 SYNC_RETRY_SEC=1
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
unset CLAUDE_CONFIG_DIR
git config --global user.email t@t && git config --global user.name t
S=$SYNC_DIR
mkdir -p "$HOME/.claude" "$HOME/dev" "$S/machines" "$S/claude"
cp "$KIT"/sync/*.sh "$KIT/sync/.gitignore" "$KIT/sync/.gitattributes" "$S/"
echo '# notes' > "$HOME/.claude/CLAUDE.md"
echo '{}' > "$HOME/.claude/settings.json"
echo '{"devDir": "~/dev"}' > "$S/machines/pc.json"
echo pc > "$S/.machine"
git -C "$S" init -q -b main && git -C "$S" add -A && git -C "$S" commit -q -m first
git -C "$S" remote add origin "$T/remote.git"
. "$KIT/sync/jq.sh"
sync() { bash "$S/sync.sh" "$@" < /dev/null > "$T/out" 2>&1; }
stop() { printf '{"hook_event_name": "%s"}' "$1" | bash "$S/sync.sh" bg; }
# A fresh lock makes the background syncs bg starts stand aside, so they can't change what is checked.
hold() { mkdir -p "$S/.state/lock"; }
gone() { for _ in $(seq 100); do [ -e "$1" ] || return 0; sleep 0.2; done; return 1; }

sync now
check "an unreachable remote fails every try" 'grep -q "trying the sync again (2 of 2)" "$S/.state/log" && [ -f "$S/.state/error" ]'

: > "$S/.state/log"
(for _ in $(seq 100); do grep -q "trying the sync again (1 of 2)" "$S/.state/log" && break; sleep 0.1; done
  git init -q --bare "$T/remote.git") &
sync now
wait
check "a sync that fails once succeeds on the next try" '! grep -q "(2 of 2)" "$S/.state/log" && grep -q "pushed to the sync repo" "$S/.state/log"'
check "and clears the error" '[ ! -f "$S/.state/error" ]'

hold
echo "could not reach the sync repo" > "$S/.state/error"
out=$(stop SessionEnd)
check "SessionEnd says nothing" '[ -z "$out" ]'
out=$(stop Stop)
check "Stop tells the user of an error that every try hit" '[[ "$out" == *"\"systemMessage\": \"⚠️ Claude config sync failed 3 times in a row: could not reach the sync repo\""* ]]'
out=$(stop Stop)
check "only once" '[ -z "$out" ]'
out=$(SYNC_RETRIES=0 stop Stop)
rm -f "$S/.state/told"
check "with no retries (macOS, Linux) it says nothing" '[ -z "$out" ]'

printf 'a "quoted" path C:\\Users\tand a tab\n' > "$S/.state/error"
echo '{"hook_event_name": "Stop", "last_assistant_message": "a \"quote\""}' > "$T/in"
out=$(bash "$S/sync.sh" bg < "$T/in")
check "the message stays valid JSON" '[[ "$(printf "%s" "$out" | jq -r .systemMessage)" == *"a \"quoted\" path C:\\Users and a tab"* ]]'

rm -f "$S/.state/error"
: > "$S/.state/pending" && touch -t 202001010000 "$S/.state/pending"
out=$(stop Stop)
check "a sync still running is not reported" '[ -z "$out" ]'
rm -rf "$S/.state/lock"
out=$(stop Stop)
check "Stop tells the user when no background sync finished for a while" '[[ "$out" == *"has not finished a background sync for 15 minutes"* ]]'
check "the background sync it starts clears it" 'gone "$S/.state/pending"'
gone "$S/.state/lock"

echo "$fails failure(s)"
[ "$fails" -eq 0 ]
