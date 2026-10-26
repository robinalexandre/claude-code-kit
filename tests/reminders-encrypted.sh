#!/bin/bash
# Checks that skills/reminders tells encrypted reminders apart, that its setup then steers the
# phone notification away from a cloud routine, and that "ntfy_detail": "count" keeps the titles
# off the ntfy server. bash tests/reminders-encrypted.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$KIT/hooks/lib/jq.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" CLAUDE_REMINDERS_DIR="$T/sync/reminders"
mkdir -p "$HOME/.claude" "$CLAUDE_REMINDERS_DIR"
git -C "$T/sync" init -q
printf 'reminders.ntfy=n\n' > "$T/answers"
R() { bash "$KIT/skills/reminders/reminders.sh" "$@"; }
setup() { KIT_INSTALL_ANSWERS="$T/answers" bash "$KIT/skills/reminders/setup.sh" 2>&1; }
fails=0

check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

check "reminders in clear" '[ "$(R encrypted)" = clear ]'
check "setup offers the Claude app" 'setup | grep -q "through the Claude app"'

printf '# encrypted folders (sync.sh crypt): everything below is kept by sync.sh\nreminders/** filter=git-crypt diff=git-crypt\n' > "$T/sync/.gitattributes"
check "encrypted reminders" '[ "$(R encrypted)" = encrypted ]'
out=$(setup)
check "setup says a cloud routine can't read them" 'grep -q "cannot notify them" <<< "$out"'
check "setup names no assistant when there is none" '! grep -q "if it holds the key" <<< "$out"'

printf '[{"name": "Ada", "dir": "ada/tasks"}]\n' > "$CLAUDE_REMINDERS_DIR/agents.json"
check "setup offers the assistant" 'setup | grep -q "Ada: if it holds the key"'

printf 'memory/** filter=git-crypt diff=git-crypt\n' > "$T/sync/.gitattributes"
check "another folder encrypted leaves the reminders in clear" '[ "$(R encrypted)" = clear ]'

CLAUDE_REMINDERS_DIR="$T/nowhere/reminders" check "outside a repo counts as clear" '[ "$(R encrypted)" = clear ]'

printf 'reminders/** filter=git-crypt diff=git-crypt\n' > "$T/sync/.gitattributes"
printf 'reminders.ntfy=y\nreminders.topic=https://ntfy.example/topic\n' > "$T/answers"
setup > /dev/null
check "setup turns count only on by default when encrypted" '[ "$(jq -r .ntfy_detail "$HOME/.claude/reminders.json")" = count ]'
printf 'reminders.ntfy=y\nreminders.count=n\n' > "$T/answers"
setup > /dev/null
check "and off when the user says no" '[ "$(jq -r ".ntfy_detail // empty" "$HOME/.claude/reminders.json")" = "" ]'

# The phone and the desktop, faked: curl keeps what it would send, the notifiers do nothing.
mkdir -p "$T/bin"
printf '#!/bin/bash\ncat > "%s/sent"\n' "$T" > "$T/bin/curl"
for n in osascript notify-send powershell.exe; do printf '#!/bin/bash\nexit 0\n' > "$T/bin/$n"; done
chmod +x "$T/bin"/*
export PATH="$T/bin:$PATH"
printf -- '---\ntitle: Call the notary\non: 2020-01-01\n---\n\nAbout the lease.\n' > "$CLAUDE_REMINDERS_DIR/2020-01-01-notary.md"
printf -- '---\ntitle: Pay the plumber\non: 2020-01-01\n---\n' > "$CLAUDE_REMINDERS_DIR/2020-01-01-plumber.md"

rm -f "$T/sent"
R morning
check "the phone gets the titles by default" 'grep -q "Call the notary" "$T/sent"'
jq '.ntfy_detail = "count"' "$HOME/.claude/reminders.json" > "$T/conf" && mv "$T/conf" "$HOME/.claude/reminders.json"
rm -f "$T/sent"
R morning
check "with count only, the phone gets the count" '[ "$(jq -r .message "$T/sent")" = "2 reminders due" ]'
check "and no title" '! grep -q "notary\|plumber" "$T/sent"'
rm -f "$CLAUDE_REMINDERS_DIR/2020-01-01-plumber.md" "$T/sent"
R morning
check "one reminder is said in the singular" '[ "$(jq -r .message "$T/sent")" = "1 reminder due" ]'

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
