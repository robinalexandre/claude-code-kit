#!/bin/bash
# Checks skills/reopen-sessions/claude-reopen.sh in a throwaway folder: which sessions it picks
# and what it would launch in each terminal. bash tests/claude-reopen.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$KIT/hooks/lib/jq.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" CLAUDE_REOPEN_ECHO=1
unset CLAUDE_CONFIG_DIR TERM_PROGRAM KITTY_WINDOW_ID WT_SESSION GNOME_TERMINAL_SCREEN CLAUDE_REOPEN_TERMINAL
P="$HOME/.claude/projects/p"
mkdir -p "$P" "$HOME/.claude/sessions" "$T/my app" "$T/other"
R() { bash "$KIT/skills/reopen-sessions/claude-reopen.sh" "$@"; }
fails=0

check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; printf '%s\n' "$out" | sed 's/^/     /'; fails=$((fails + 1)); fi
}

session() {
  printf '{"type":"user","entrypoint":"%s","cwd":"%s","timestamp":"%s","message":{"role":"user","content":"%s"}}\n' \
    "$3" "$2" "${5:-$(date -u +%Y-%m-%dT%H:%M:%S.000Z)}" "$4" > "$P/$1.jsonl"
}

session aaaaaaaa-1111-4000-8000-000000000001 "$T/my app" cli "Fix the login page"
session bbbbbbbb-2222-4000-8000-000000000002 "$T/other" cli "<command-name>x</command-name>" 2020-01-01T10:00:00.000Z
printf '{"type":"custom-title","customTitle":"Billing"}\n' >> "$P/bbbbbbbb-2222-4000-8000-000000000002.jsonl"
session cccccccc-3333-4000-8000-000000000003 "$T/other" sdk-py "automated run"
session dddddddd-4444-4000-8000-000000000004 "$T/gone" cli "folder deleted"
session eeeeeeee-5555-4000-8000-000000000005 "$T/other" cli "still running"
printf '{"pid":%s,"sessionId":"eeeeeeee-5555-4000-8000-000000000005"}\n' "$$" > "$HOME/.claude/sessions/$$.json"
session ffffffff-6666-4000-8000-000000000006 "$T/other" cli "old one"
touch -t 202001010000 "$P/ffffffff-6666-4000-8000-000000000006.jsonl"

out=$(R --list)
check "lists a recent cli session, newest first, with its age and first prompt" 'grep -q "^ 1\. aaaaaaaa  0 min ago .*my app  Fix the login page" <<< "$out"'
check "the /rename title wins over the first prompt" 'grep -q "^ 2\. bbbbbbbb  .*days ago .*Billing" <<< "$out"'
check "leaves out sdk sessions" '! grep -q cccccccc <<< "$out"'
check "skips a session whose folder is gone" 'grep -q "skip dddddddd (folder gone" <<< "$out"'
check "skips a running session" 'grep -q "skip eeeeeeee (already running)" <<< "$out"'
check "leaves out sessions older than the window" '! grep -q ffffffff <<< "$out"'

out=$(R --list ffffffff)
check "an id prefix picks an old session" 'grep -q "^ 1\. ffffffff  " <<< "$out"'

out=$(printf '2\n' | R --pick)
check "asks, and reopens only the picked one" 'grep -q "Reopen which" <<< "$out" && grep -q "claude --resume bbbbbbbb" <<< "$out" && ! grep -q "claude --resume aaaaaaaa" <<< "$out"'
out=$(printf '\n' | R --pick)
check "Enter reopens them all" '[ "$(grep -c "claude --resume" <<< "$out")" = 2 ]'
out=$(printf 'q\n' | R --pick)
check "q reopens nothing" '! grep -q "claude --resume" <<< "$out"'
out=$(R < /dev/null)
check "not in a terminal: no question" '! grep -q "Reopen which" <<< "$out"'

out=$(R aaaaaaaa)
check "no terminal: prints the command, path quoted" 'grep -qF "cd '"'"'$T/my app'"'"' && claude --resume aaaaaaaa-1111-4000-8000-000000000001" <<< "$out"'

out=$(TERM_PROGRAM=ghostty R aaaaaaaa bbbbbbbb)
check "ghostty: two folders, two windows" '[ "$(grep -c "new window" <<< "$out")" = 2 ] && ! grep -q "new tab in w" <<< "$out"'
check "ghostty: each tab runs the resume through a login shell" '[ "$(grep -c "command:\".* -lic .claude --resume [a-f0-9-]*; exec " <<< "$out")" = 2 ]'
check "ghostty: opens in the session folder" 'grep -qF "initial working directory:\"$T/my app\"" <<< "$out"'
out=$(TERM_PROGRAM=ghostty R --one-window aaaaaaaa bbbbbbbb)
check "ghostty --one-window: one window, then a tab" '[ "$(grep -c "new window" <<< "$out")" = 1 ] && [ "$(grep -c "new tab in w" <<< "$out")" = 1 ]'

# Two sessions in one repo (in two of its folders) and one elsewhere
mkdir -p "$T/shop/api" "$T/shop/web"
git -C "$T/shop" init -q
session abab7777-0000-4000-8000-000000000001 "$T/shop/api" cli "api work" 2026-01-03T10:00:00.000Z
session abab7777-0000-4000-8000-000000000002 "$T/other" cli "other work" 2026-01-02T10:00:00.000Z
session abab7777-0000-4000-8000-000000000003 "$T/shop/web" cli "web work" 2026-01-01T10:00:00.000Z
out=$(TERM_PROGRAM=ghostty R abab7777)
check "a window per repo, its sessions as tabs" '[ "$(grep -c "new window" <<< "$out")" = 2 ] && [ "$(grep -c "new tab in w" <<< "$out")" = 1 ]'
check "the tabs of a repo follow its window, before the next repo" '[ "$(grep -o "resume abab7777-0000-4000-8000-00000000000[0-9]" <<< "$out" | cut -c43- | tr -d "\n")" = 132 ]'
check "says how many windows" 'grep -q "one window per repo (2)" <<< "$out"'
out=$(R --terminal print abab7777)
check "print: a header per repo" '[ "$(grep -c "^# " <<< "$out")" = 2 ] && grep -q "^# .*shop$" <<< "$out"'
out=$(R --terminal gnome-terminal abab7777)
check "gnome-terminal: a window per repo, then tabs" '[ "$(grep -c "^gnome-terminal --window" <<< "$out")" = 2 ] && [ "$(grep -c "^gnome-terminal --tab" <<< "$out")" = 1 ]'
out=$(R --terminal wezterm abab7777)
check "wezterm: a window per repo, then tabs in it" '[ "$(grep -c "spawn --new-window" <<< "$out")" = 2 ] && [ "$(grep -c "spawn --window-id" <<< "$out")" = 1 ]'
rm -f "$P"/abab7777-*.jsonl

mkdir -p "$T/it's"
session 99999999-7777-4000-8000-000000000007 "$T/it's" cli "quote in the folder"
out=$(R --terminal print 99999999)
check "a quote in the folder name stays quoted" 'grep -qF "cd '"'$T/it'\\\\''s'"' && claude" <<< "$out"'

printf '{"type":"ai-title","aiTitle":"Payment webhook retries"}\n' >> "$P/aaaaaaaa-1111-4000-8000-000000000001.jsonl"
printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"webhook"}]}}\n' >> "$P/ffffffff-6666-4000-8000-000000000006.jsonl"
out=$(R --list)
check "Claude Code's own title wins over the first prompt" 'grep -q "aaaaaaaa .*Payment webhook retries" <<< "$out"'
out=$(R --list --find WEBHOOK)
check "--find matches a title, whatever the case" 'grep -q "aaaaaaaa" <<< "$out"'
check "--find ignores tool output" '! grep -q ffffffff <<< "$out"'
out=$(R --list --find "old one")
check "--find reaches sessions of any age" 'grep -q ffffffff <<< "$out"'

out=$(TERM_PROGRAM=iTerm.app R --one-window aaaaaaaa bbbbbbbb)
check "iterm: one window, one more tab" '[ "$(grep -c "create window" <<< "$out")" = 1 ] && [ "$(grep -c "create tab" <<< "$out")" = 1 ]'

out=$(R --terminal terminal --one-window aaaaaaaa bbbbbbbb)
check "terminal.app: Cmd-T for the second" '[ "$(grep -c "do script" <<< "$out")" = 2 ] && [ "$(grep -c keystroke <<< "$out")" = 1 ]'
out=$(R --terminal terminal aaaaaaaa bbbbbbbb)
check "terminal.app: two folders, two windows" '[ "$(grep -c "do script" <<< "$out")" = 2 ] && ! grep -q keystroke <<< "$out"'

out=$(WT_SESSION=x R aaaaaaaa)
check "windows terminal: a tab in the repo's named window" 'grep -q "^wt.exe -w claude-my app new-tab -d .*my app claude --resume aaaaaaaa" <<< "$out"'

out=$(KITTY_WINDOW_ID=1 R aaaaaaaa)
check "kitty: the repo's first session opens a window" 'grep -q "^kitty @ launch --type=os-window --cwd=.*my app claude --resume" <<< "$out"'

out=$(R --terminal nope aaaaaaaa 2>&1); code=$?
check "an unknown terminal is refused" '[ $code = 2 ] && grep -q "Unknown terminal" <<< "$out"'

rm -f "$P"/*.jsonl
out=$(R)
check "nothing recent: says so" 'grep -q "No session to reopen" <<< "$out"'

echo "$fails failure(s)"
[ "$fails" -eq 0 ]
