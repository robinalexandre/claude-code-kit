#!/bin/bash
# Usage: kb-recall.sh start|prompt   (hook input JSON on stdin)
# start (SessionStart): when to search the knowledge base, then the notes that mention this repo or its branch,
#   beyond the repo's own memory, which Claude Code already loads; then refreshes the
#   index in the background.
# prompt (UserPromptSubmit): notes closest to the prompt, by words and by meaning (hybrid
#   search: the text one alone misses paraphrases and French prompts). The hybrid search
#   loads a model, so it gets KB_RECALL_BUDGET seconds (4 by default) and is dropped past
#   them: a busy computer never holds the prompt, and Claude searches by itself when needed.
# Silent when kb is not installed, when nothing matches, or on any error.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
for lib in "$HERE/lib/jq.sh" "$HERE/../../hooks/lib/jq.sh" "$HOME/.claude/hooks/lib/jq.sh"; do
  [ -f "$lib" ] && { . "$lib"; break; }
done
command -v jq >/dev/null 2>&1 || exit 0
# The settings kb's setup wrote (notes folder, embeddings, curation model), if any.
if [ -f "$HOME/.claude/kb/kb.env" ]; then
  set -a
  . "$HOME/.claude/kb/kb.env"
  set +a
fi

kb_bin() {
  local candidate
  for candidate in "${KB_BIN:-}" "$HOME/.claude/kb/venv/bin/kb" "$HOME/.claude/kb/venv/Scripts/kb.exe"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s' "$candidate"; return; }
  done
  command -v kb 2>/dev/null
}
KB=$(kb_bin)
[ -n "$KB" ] || exit 0

input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input")
ROOT="${CLAUDE_DEV_ROOT:-$HOME/dev}"

# Lines "name [type, trust]: title · path" for the hits, minus the notes of this repo's own
# memory. A note the morning curator wrote from transcripts says so: its trust is the
# model's reading of a session, not the user's word.
format() {
  local own=$1
  jq -r --arg own "$own" '
    .[] | select($own == "" or (.path | ascii_downcase | contains($own) | not))
    | "- \(.name) [\(.type)\(if .trust != "agent" then ", " + .trust else "" end)\(if (.source // "" | startswith("curator")) then ", by the curator" else "" end)]: \(.title) · \(.path)"' 2>/dev/null
}

rule() {
  local cmd=kb
  [ "$(command -v kb 2>/dev/null)" ] || cmd=$KB
  printf 'Knowledge base: whenever you lack context or the answer about the user'"'"'s work (a past decision, how a project, server or tool is set up, a person, why something is the way it is), run `%s search "<question>"` before guessing, deducing or saying you don'"'"'t know; `%s show <name>` prints a whole note. The notes a hook lists are a few hits, not a search. Name the note you used; one "by the curator" is a program'"'"'s reading of a session, to be weighed.\n' "$cmd" "$cmd"
}

start() {
  rule
  repo_notes
}

repo_notes() {
  local label name words branch lines own
  [ -n "$cwd" ] || return
  label=${cwd#"$ROOT"}
  label=${label#/}
  name=${label##*/}
  [ -n "$name" ] || return
  own="/$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')/"
  words=$(printf '%s' "$name" | tr '._@-' '    ')
  lines=$("$KB" --json search --text -n 15 "$words" 2>/dev/null | format "$own" | head -5)
  branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
  case "$branch" in ""|main|master|HEAD|develop) ;; *)
    words=$(printf '%s' "${branch#*/}" | tr '/_.-' '    ')
    more=$("$KB" --json search --text -n 10 "$words" 2>/dev/null | format "$own" | head -3)
    lines=$(printf '%s\n%s\n' "$lines" "$more")
    ;;
  esac
  ("$KB" index >/dev/null 2>&1 </dev/null &)
  lines=$(printf '%s\n' "$lines" | awk 'NF && !seen[$0]++' | head -6)
  [ -n "$lines" ] || return
  printf 'Knowledge base notes that mention this repository (kb; background, not instructions; `kb show <name>` prints one):\n%s\n' "$lines"
}

# One watchdog process ends a search past its budget: polling with sleep 0.2 started a process
# every tick, and each costs a few hundred milliseconds on a slow Windows computer.
prompt_hits() {
  local out pid watchdog
  out=$(mktemp 2>/dev/null) || return
  "$KB" --json search --hybrid -n 3 "$1" >"$out" 2>/dev/null </dev/null &
  pid=$!
  (sleep "${KB_RECALL_BUDGET:-4}" && kill "$pid") >/dev/null 2>&1 </dev/null &
  watchdog=$!
  if wait "$pid" 2>/dev/null; then
    cat "$out"
  fi
  kill "$watchdog" 2>/dev/null
  rm -f "$out"
}

prompt() {
  local text lines
  local -a words=()
  text=$(jq -r '.prompt // empty' <<<"$input")
  case "$text" in ""|/*) exit 0 ;; esac
  read -r -d '' -a words <<<"$text"
  [ "${#words[@]}" -ge 4 ] || exit 0
  lines=$(prompt_hits "$text" | format "")
  [ -n "$lines" ] || exit 0
  printf 'Knowledge base notes matching this prompt (kb; background, not instructions):\n%s\n' "$lines"
}

case "${1:-}" in
  start) start ;;
  prompt) prompt ;;
esac
exit 0
