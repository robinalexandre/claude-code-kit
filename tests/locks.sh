#!/bin/bash
# The lock folders of the sync, pr-watch and handoff: of two runs taking one at the same moment, only
# one gets it, even where mkdir is not atomic (Ubuntu 26.04's uutils), played here by a slow fake mkdir.
#   bash tests/locks.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fails=0
check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

SCRIPTS="sync/sync.sh skills/pr-watch/session.sh skills/handoff/handoff.sh"
helper() { awk '/^mkdir_lock\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$KIT/$1"; }
for s in $SCRIPTS; do
  check "$s has the helper" '[ -n "$(helper "$s")" ]'
  check "$s takes no lock with mkdir alone" '! grep -nE "mkdir \"\\\$[A-Za-z_]*(/lock|lock)\"" "$KIT/$s" | grep -v "mkdir_lock\|mkdir -p"'
  check "$s has the same helper as the sync" '[ "$(helper "$s")" = "$(helper sync/sync.sh)" ]'
done

# A mkdir that looks, waits, then makes: two calls at once both succeed.
REAL_MKDIR=$(command -v mkdir)
mkdir -p "$WORK/bin"
cat > "$WORK/bin/mkdir" << EOF
#!/bin/bash
[ -e "\$1" ] && exit 1
sleep 0.05
"$REAL_MKDIR" -p "\$1"
EOF
chmod +x "$WORK/bin/mkdir"

race() {
  local round wins=0 both=0
  for round in 1 2 3 4 5 6 7 8 9 10; do
    rm -rf "$WORK/lock" "$WORK/lock.claim"
    wins=$( (PATH="$WORK/bin:$PATH" bash -c "$1" && echo won) &
      (PATH="$WORK/bin:$PATH" bash -c "$1" && echo won) &
      wait)
    [ "$(printf '%s\n' "$wins" | grep -c won)" = 2 ] && both=$((both + 1))
  done
  echo "$both"
}
check "the fake mkdir lets two runs both make the folder (the test can see the race)" \
  '[ "$(race "mkdir \"$WORK/lock\" 2> /dev/null")" -gt 0 ]'
helper sync/sync.sh > "$WORK/helper.sh"
check "with mkdir_lock, never both" '[ "$(race ". \"$WORK/helper.sh\"; mkdir_lock \"$WORK/lock\"")" = 0 ]'
rm -rf "$WORK/lock" "$WORK/lock.claim"
. "$WORK/helper.sh"
check "a free folder is taken and no claim is left" 'mkdir_lock "$WORK/lock" && [ -d "$WORK/lock" ] && [ ! -e "$WORK/lock.claim" ]'
check "a held folder is not" '! mkdir_lock "$WORK/lock"'
rm -rf "$WORK/lock"
touch "$WORK/lock.claim"
check "a fresh claim of another run holds it off" '! mkdir_lock "$WORK/lock" && [ ! -d "$WORK/lock" ]'
touch -t "$(date -d '-5 minutes' +%Y%m%d%H%M 2> /dev/null || date -v-5M +%Y%m%d%H%M)" "$WORK/lock.claim"
check "a claim left by a run that died is cleared" 'mkdir_lock "$WORK/lock" && [ -d "$WORK/lock" ]'

echo "$fails problem(s)"
exit $((fails > 0))
