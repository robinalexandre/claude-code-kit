#!/bin/bash
# sync.sh poll: says nothing while the remote's main has not moved, syncs once it has, and asks the
# remote at most once per 50 seconds for the whole computer.
#   bash tests/sync-poll.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', expected '$3'"; failures=$((failures + 1)); fi
}

git init -q --bare -b main "$WORK/remote.git" 2> /dev/null || { git init -q --bare "$WORK/remote.git" && git -C "$WORK/remote.git" symbolic-ref HEAD refs/heads/main; }
git clone -q "$WORK/remote.git" "$WORK/other" 2> /dev/null
git -C "$WORK/other" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m one
git -C "$WORK/other" push -q origin HEAD:main
git clone -q "$WORK/remote.git" "$WORK/sync"
cp "$KIT/sync/sync.sh" "$WORK/sync/sync.sh"

out=$(bash "$WORK/sync/sync.sh" poll)
check "nothing said while main has not moved" "$out" ""

git -C "$WORK/other" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m two
git -C "$WORK/other" push -q origin HEAD:main
out=$(bash "$WORK/sync/sync.sh" poll 2> /dev/null | head -1)
check "asked again within 50 seconds: not even a request" "$out" ""

rm -f "$WORK/sync/.state/poll-at"
out=$(bash "$WORK/sync/sync.sh" poll 2> /dev/null | head -1)
check "a push from another computer starts a sync" "$out" "main moved: syncing"

echo "$failures failure(s)"
[ "$failures" -eq 0 ]
