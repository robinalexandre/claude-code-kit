#!/bin/zsh
# Checks hooks/claude-resume-here.zsh in a throwaway home: the titles and briefs it shows, and what
# each key does to the registry (resume, keep, forget, leave). zsh tests/claude-resume-here.zsh
set -u
zmodload zsh/datetime
KIT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=${CLAUDE_RESUME_SCRIPT:-$KIT/hooks/claude-resume-here.zsh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0

check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

A=aaaaaaaa-0000-0000-0000-000000000001
B=bbbbbbbb-0000-0000-0000-000000000002
C=cccccccc-0000-0000-0000-000000000003
D=dddddddd-0000-0000-0000-000000000004
E=eeeeeeee-0000-0000-0000-000000000005

setup() {
  rm -rf "$T/home" "$T/work" "$T/other"
  export HOME="$T/home"
  mkdir -p "$HOME/.claude/session-registry" "$HOME/.claude/sessions" "$HOME/.claude/projects/p" "$T/work" "$T/other"
  local now=$(( EPOCHSECONDS * 1000 ))
  record() { printf '{"session_id":"%s","session_name":null,"cwd":"%s","transcript_path":"%s"}\n' "$1" "$2" "$3" > "$HOME/.claude/session-registry/$1.json"; }
  record "$A" "$T/work" "$HOME/.claude/projects/p/$A.jsonl"
  record "$B" "$T/work" "$HOME/.claude/projects/p/$B.jsonl"
  record "$C" "$T/work" "$HOME/.claude/projects/p/$C.jsonl"
  record "$D" "$T/other" "$HOME/.claude/projects/p/$D.jsonl"
  record "$E" "$T/work" "$HOME/.claude/projects/p/$E.jsonl"
  {
    printf '{"display":"Fix the login redirect","timestamp":%d,"project":"%s","sessionId":"%s"}\n' $(( now - 900000 )) "$T/work" "$A"
    printf '{"display":"Now add a test\\nfor the redirect","timestamp":%d,"project":"%s","sessionId":"%s"}\n' $(( now - 600000 )) "$T/work" "$A"
    printf '{"display":"Write the README","timestamp":%d,"project":"%s","sessionId":"%s"}\n' $(( now - 90000000 )) "$T/work" "$B"
    printf '{"display":"Still running","timestamp":%d,"project":"%s","sessionId":"%s"}\n' $(( now - 1000 )) "$T/work" "$E"
  } > "$HOME/.claude/history.jsonl"
  printf '{"type":"custom-title","customTitle":"Docs pass","sessionId":"%s"}\n' "$B" > "$HOME/.claude/projects/p/$B.jsonl"
  printf '{"sessionId":"%s","pid":%d}\n' "$E" $$ > "$HOME/.claude/sessions/live.json"
}

run() {  # $1 keys
  (cd "$T/work" && CLAUDECODE= CLAUDE_RESUME_TEST=1 CLAUDE_RESUME_DRY=1 CLAUDE_RESUME_KEYS="$1" HOME="$HOME" \
    zsh -c 'source "$1"; _claude_resume_here' zsh "$SCRIPT" 2>&1 | sed $'s/\e\\[[0-9;]*[A-Za-z]//g')
}

in_registry() { [ -f "$HOME/.claude/session-registry/$1.json" ]; }
skipped() { [ -f "$HOME/.claude/session-registry/skipped/$1.json" ]; }
claimed() { [ -f "$HOME/.claude/session-registry/claimed/$1.json" ]; }

setup
out=$(run $'\n')
check "lists the two sessions left open here" 'grep -q "2 Claude sessions left open here" <<< "$out"'
check "the newest one is shown first and checked" 'grep -q "^ \[x\] 1  .*Fix the login redirect" <<< "$out"'
check "its brief has the prompt count and the last prompt" 'grep -q "2 prompts" <<< "$out" && grep -q "last: Now add a test$" <<< "$out"'
check "a renamed session shows its title" 'grep -q "^ \[ \] 2  .*Docs pass" <<< "$out"'
check "the brief says when it was last used" 'grep -q "1 prompt · yesterday\|1 prompt · [0-9][0-9] [A-Z][a-z][a-z]" <<< "$out"'
check "Enter resumes the checked one only" 'grep -q "dry-run: claude --resume $A" <<< "$out" && ! grep -q "resume $B" <<< "$out"'
check "the resumed record is gone" '! in_registry $A && ! claimed $A && ! skipped $A'
check "the unchecked one is kept for the next tab" 'in_registry $B'
check "a session without a prompt is dropped silently" 'skipped $C && ! grep -q "$C" <<< "$out"'
check "a session from another folder is untouched" 'in_registry $D && ! grep -q "$D" <<< "$out"'
check "a live session is neither shown nor touched" 'in_registry $E && ! grep -q "Still running" <<< "$out"'

setup
out=$(run $'2\n')
check "checking both resumes both, newest first" '[ "$(grep -o "\-\-resume [a-e]" <<< "$out" | tr -d "\n")" = "--resume a--resume b" ]'
check "each resume after the first is announced" 'grep -q "Resuming .*Docs pass.* (2 of 2)" <<< "$out"'
check "both records are gone" '! in_registry $A && ! in_registry $B && ! claimed $A && ! claimed $B'

setup
out=$(run f)
check "f forgets them all" 'skipped $A && skipped $B && grep -q "Forgotten: 2 sessions" <<< "$out"'
check "f resumes nothing" '! grep -q dry-run <<< "$out"'

setup
out=$(run q)
check "q leaves them for the next tab" 'in_registry $A && in_registry $B && ! grep -q dry-run <<< "$out"'

setup
out=$(run $'n2d')
check "d forgets the checked ones and keeps the rest" 'skipped $B && in_registry $A && ! grep -q dry-run <<< "$out"'

setup
out=$(run $'n\n')
check "Enter with nothing checked leaves them" 'in_registry $A && in_registry $B && grep -q "Nothing checked" <<< "$out"'

setup
out=$(run $'a1\n')
check "a checks all, a digit toggles back" 'grep -q "resume $B" <<< "$out" && ! grep -q "resume $A" <<< "$out" && in_registry $A'

echo "$fails problem(s)"
exit $(( fails > 0 ))
