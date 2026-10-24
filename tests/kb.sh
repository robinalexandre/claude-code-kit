#!/bin/bash
# Checks skills/kb in a throwaway home: the package installs in a virtualenv and passes its own
# tests, notes are indexed and found, and the recall hook says which notes match a prompt or a
# repository. bash tests/kb.sh   (needs Python 3.12+, jq and the network for pip)
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME/.claude"
fails=0
check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

py=""
for candidate in python3.13 python3.12 python3 python; do
  command -v "$candidate" > /dev/null 2>&1 || continue
  "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 12))' 2> /dev/null && { py=$candidate; break; }
done
[ -n "$py" ] || { echo "FAIL Python 3.12 or newer is missing"; exit 1; }

"$py" -m venv "$T/venv" || { echo "FAIL venv"; exit 1; }
if [ -x "$T/venv/bin/python" ]; then BIN="$T/venv/bin"; else BIN="$T/venv/Scripts"; fi
"$BIN/python" -m pip install -q --upgrade pip > /dev/null
PKG="$KIT/skills/kb/package"
command -v cygpath > /dev/null 2>&1 && PKG=$(cygpath -m "$PKG")
"$BIN/python" -m pip install -q "$PKG[dev]" || { echo "FAIL pip install"; exit 1; }
KB=$(ls "$BIN"/kb "$BIN"/kb.exe 2> /dev/null | head -1)
check "kb installed" '[ -x "$KB" ]'

(cd "$KIT/skills/kb/package" && "$BIN/pytest" -q tests > "$T/pytest.log" 2>&1)
check "the package's own tests pass" '[ $? -eq 0 ]' || tail -5 "$T/pytest.log"

# Python on Windows takes its home from USERPROFILE, not from this HOME: name the folders.
NOTES="$HOME/.claude/knowledge"
mkdir -p "$NOTES" "$HOME/.claude/kb"
win() { if command -v cygpath > /dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
export KB_EMBED=none KB_BIN=$KB KB_NOTES="$(win "$NOTES")" KB_DB="$(win "$HOME/.claude/kb/index.sqlite")"
cat > "$NOTES/acme-accountant.md" << 'EOF'
---
name: acme-accountant
title: Acme Books is the accounting firm
type: fact
trust: user
topics: [accounting, my-company]
---

Mails from Acme Books concern [[my-company]].
EOF
cat > "$NOTES/my-company.md" << 'EOF'
---
name: my-company
title: My Company, the repository and the business
type: project
source: "curator, session:abcd"
---

The my-company repository holds the shop; its main branch deploys.
EOF
out=$("$KB" index 2>&1)
check "kb index: two notes" '[[ "$out" == *"2 notes"* ]]'
check "kb search --text finds the accountant" '[ "$("$KB" --json search --text accounting firm | jq -r ".[0].name")" = acme-accountant ]'
check "kb related: the link both ways" '"$KB" --json related my-company | jq -e ".nodes | map(.name) | index(\"acme-accountant\")" > /dev/null'
check "kb check: nothing to report" '"$KB" check | grep -q "nothing to report"'

out=$(echo '{"prompt":"who is the accounting firm we use for the books"}' | bash "$KIT/skills/kb/recall.sh" prompt)
check "recall prompt: names the note" '[[ "$out" == *"acme-accountant [fact, user]"* ]]'
out=$(echo '{"prompt":"/help"}' | bash "$KIT/skills/kb/recall.sh" prompt)
check "recall prompt: quiet on a slash command" '[ -z "$out" ]'
mkdir -p "$HOME/dev/my-company"
out=$(echo "{\"cwd\":\"$HOME/dev/my-company\"}" | CLAUDE_DEV_ROOT="$HOME/dev" bash "$KIT/skills/kb/recall.sh" start)
check "recall start: the note of this repository, marked as the curator's" '[[ "$out" == *"my-company [project, by the curator]"* ]]'
out=$(echo '{"prompt":"nothing matches here"}' | KB_BIN=/nowhere/kb bash "$KIT/skills/kb/recall.sh" prompt)
check "recall: silent when kb is not installed" '[ -z "$out" ]'

printf 'KB_CURATE=off\n' > "$HOME/.claude/kb.env.test"
mkdir -p "$HOME/.claude/kb" && mv "$HOME/.claude/kb.env.test" "$HOME/.claude/kb/kb.env"
out=$(bash "$KIT/skills/kb/morning.sh" 2>&1)
check "morning.sh: quiet when the curation is off" '[ -z "$out" ] && [ ! -f "$HOME/.claude/kb/curate.log" ]'

echo
echo "$fails problem(s)"
exit $((fails > 0))
