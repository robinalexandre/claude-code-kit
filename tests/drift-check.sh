#!/bin/bash
# Checks hooks/drift-check.sh: the Stop warning and the next-prompt reminder, from the reply Claude Code
# hands over and from the transcript. macOS, Linux and Windows (Git Bash).
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v jq > /dev/null || { echo "Install jq first." >&2; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/wave-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
H="$KIT/hooks/drift-check.sh"
export CLAUDE_REPLY_MARKER=🌊
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

line() { jq -cn --arg t "$1" '{type: "assistant", message: {content: [{type: "text", text: $t}]}}'; }
line "🌊 First reply" > "$T/ok.jsonl"
line "Narration between two tool calls" >> "$T/ok.jsonl"
line "🌊 Final reply" >> "$T/ok.jsonl"
line "Final reply without the marker" > "$T/missing.jsonl"
# The transcript as a Stop hook can see it: the final reply not written yet, only the narration before it.
line "Narration between two tool calls" > "$T/stale.jsonl"

stop() { jq -n --arg p "$1" --arg r "${2-}" '{transcript_path: $p} + (if $r == "" then {} else {last_assistant_message: $r} end)' | bash "$H" stop; }
prompt() { jq -n --arg p "$1" '{transcript_path: $p}' | bash "$H" prompt; }

out=$(stop "$T/stale.jsonl" "🌊 Final reply

💡 Learn: a closing block")
check "stop: trusts the reply handed over over a stale transcript" '[ -z "$out" ]'
out=$(stop "$T/stale.jsonl" "Final reply without the marker")
check "stop: warns when the reply handed over misses the marker" '[[ "$out" == *"Reply missing the 🌊"* ]]'
out=$(stop "$T/ok.jsonl")
check "stop: falls back on the transcript, last reply fine" '[ -z "$out" ]'
out=$(stop "$T/missing.jsonl")
check "stop: falls back on the transcript, last reply missing" '[[ "$out" == *"Reply missing the 🌊"* ]]'
out=$(prompt "$T/ok.jsonl")
check "prompt: quiet after a reply with the marker" '[ -z "$out" ]'
out=$(prompt "$T/missing.jsonl")
check "prompt: reminds after a reply without it" '[[ "$out" == *"did not start with 🌊"* ]]'
out=$(CLAUDE_REPLY_MARKER= stop "$T/stale.jsonl" "No marker set")
check "idle with no marker" '[ -z "$out" ]'

[ "$fails" -eq 0 ] && echo "All drift-check checks pass." || { echo "$fails check(s) failed."; exit 1; }
