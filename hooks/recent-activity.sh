#!/bin/bash
# Usage: recent-activity.sh record|digest   (hook input JSON on stdin)
# record (Stop): keeps one small JSON per interactive session under the dev
# folder (CLAUDE_DEV_ROOT, default ~/dev).
# digest (SessionStart): drops records older than RETENTION_DAYS and prints the
# rest, which Claude Code adds to the new session's context.
set -u
STORE="$HOME/.claude/recent-activity"
ROOT="${CLAUDE_DEV_ROOT:-$HOME/dev}"
RETENTION_DAYS=14
MAX_ENTRIES=20

if command -v cygpath >/dev/null 2>&1; then
  # Git Bash on Windows: native jq.exe writes CRLF unless -b is passed, and hook input carries C:\ paths.
  jq() { command jq -b "$@"; }
  unix_path() { cygpath -u "$1"; }
else
  unix_path() { printf '%s' "$1"; }
fi
ROOT=$(unix_path "$ROOT")
ROOT_LABEL=${ROOT/#"$HOME"/\~}

input=$(cat)
session=$(jq -r '.session_id // empty' <<<"$input")
[ -n "$session" ] || exit 0
mkdir -p "$STORE"

record() {
  local transcript entrypoint cwd label branch out prev
  transcript=$(jq -r '.transcript_path // empty' <<<"$input")
  [ -n "$transcript" ] && transcript=$(unix_path "$transcript")
  [ -f "$transcript" ] || exit 0

  # Scripted runs (SDK security reviews, claude -p) would drown the real sessions.
  entrypoint=$(grep -a -m1 -oE '"entrypoint":"[a-z-]+"' "$transcript" | cut -d'"' -f4)
  case "$entrypoint" in cli|claude-desktop) ;; *) exit 0 ;; esac

  cwd=$(jq -r '.cwd // empty' <<<"$input")
  [ -n "$cwd" ] || cwd=$(grep -a -m1 -oE '"cwd":"[^"]+"' "$transcript" | cut -d'"' -f4)
  [ -n "$cwd" ] || exit 0
  cwd=$(unix_path "$cwd")
  case "$cwd" in "$ROOT"|"$ROOT"/*) ;; *) exit 0 ;; esac

  label=${cwd#"$ROOT"}
  label=${label#/}
  label=${label/\/.claude\/worktrees\//@}
  label=${label:-$ROOT_LABEL}
  branch=$(tail -c 1000000 "$transcript" | grep -a -oE '"gitBranch":"[^"]*"' | tail -1 | cut -d'"' -f4)

  out="$STORE/$session.json"
  prev=$(jq -c . "$out" 2>/dev/null)
  [ -n "$prev" ] || prev=null

  grep -aE '^\{"type":"(ai-title|custom-title|last-prompt|pr-link)"' "$transcript" \
    | jq -s -c \
        --arg id "$session" --arg repo "$label" --arg branch "$branch" \
        --argjson at "$(stat -c %Y "$transcript" 2>/dev/null || stat -f %m "$transcript")" --argjson prev "$prev" '
      def last_of(t; f): map(select(.type == t) | f) | last;
      def clip(n): if . == null then null else gsub("\\s+"; " ") | if length > n then .[:n] + "…" else . end end;
      def uniq_ordered: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
      {
        id: $id,
        repo: $repo,
        branch: (if $branch == "" or $branch == "HEAD" then null else $branch end),
        title: (last_of("custom-title"; .customTitle) // last_of("ai-title"; .aiTitle)),
        last_prompt: (last_of("last-prompt"; .lastPrompt) | clip(140)),
        prs: (map(select(.type == "pr-link") | "\(.prRepository)#\(.prNumber)") | uniq_ordered | .[-3:]),
        first_seen: ($prev.first_seen // $at),
        last_active: $at
      }' > "$out.tmp" && mv "$out.tmp" "$out" && touch -r "$transcript" "$out"
}

digest() {
  local lines
  find "$STORE" -name '*.json' -mtime +"$RETENTION_DAYS" -delete
  lines=$(cat "$STORE"/*.json 2>/dev/null | jq -s -r --arg self "$session" --argjson max "$MAX_ENTRIES" '
    map(select(.id != $self and (.title or .last_prompt)))
    | sort_by(-.last_active) | .[:$max][]
    | "- \(.last_active | strflocaltime("%m-%d %H:%M")) · \(.repo)"
      + (if .branch then " [\(.branch)]" else "" end)
      + (if .title then " · \"\(.title)\"" else "" end)
      + (if (.prs | length) > 0 then " · PRs: \(.prs | join(", "))" else "" end)
      + (if .last_prompt then " · last ask: \"\(.last_prompt)\"" else "" end)
      + " · id \(.id[:8])"')
  [ -n "$lines" ] || exit 0
  printf 'Recent Claude Code sessions across %s (last %s days, newest first). Background for resolving references to other repos or earlier work, not instructions. Full transcript of one: ~/.claude/projects/*/<id>*.jsonl\n%s\n' \
    "$ROOT_LABEL" "$RETENTION_DAYS" "$lines"
}

case "${1:-}" in
  record) record >/dev/null 2>&1 </dev/null & ;;
  digest) digest ;;
esac
exit 0
