#!/bin/bash
# Handoff notes kept in the config sync repo, one Markdown file each.
#   handoff.sh json          every note, the open ones and those in done/, as JSON (the reminders
#                            and handoffs pane)
#   handoff.sh done ID       moves a note to done/: it was picked up
#   handoff.sh cancel ID     moves a note to done/, marked canceled: no one will pick it up
#   handoff.sh delete ID     deletes a note, a done one too
#   handoff.sh restore ID    opens a done or canceled note again
# A note moved to done/ gets a `closed:` line; done/ keeps a note DONE_DAYS days.
set -u
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SYNC="$HOME/.claude-sync"
DIR=${CLAUDE_HANDOFFS_DIR:-$SYNC/handoffs}
DONE="$DIR/done"
DONE_DAYS=60

if [ -f "$SK/../../hooks/lib/jq.sh" ]; then
  . "$SK/../../hooks/lib/jq.sh"
elif command -v cygpath > /dev/null 2>&1; then
  jq() { command jq -b "$@"; }
fi

# frontmatter FILE KEY: prints KEY's value from FILE's YAML front matter.
frontmatter() {
  awk -v k="$2" '{ sub(/\r$/, "") }
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    NR > 1 { i = index($0, ":"); if (substr($0, 1, i - 1) == k) { v = substr($0, i + 1); sub(/^ +/, "", v); sub(/ +$/, "", v); print v; exit } }' "$1"
}

body() { awk '{ sub(/\r$/, "") } NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm' "$1"; }

# set_field FILE KEY VALUE: sets KEY in FILE's front matter, added before its end if missing.
set_field() {
  awk -v k="$2" -v v="$3" '{ sub(/\r$/, "") }
    NR == 1 { print; next }
    !end && $0 == "---" { if (!set) print k ": " v; end = 1; print; next }
    !end && index($0, k ":") == 1 { print k ": " v; set = 1; next }
    { print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

machine() { tr -d '[:space:]' < "$SYNC/.machine" 2> /dev/null; }

one() {
  local f=$1
  jq -n --arg id "$(basename "$f" .md)" --arg state "$2" --arg title "$(frontmatter "$f" title)" \
    --arg from "$(frontmatter "$f" from)" --arg date "$(frontmatter "$f" date)" \
    --arg repo "$(frontmatter "$f" repo)" --arg branch "$(frontmatter "$f" branch)" \
    --arg closed "$(frontmatter "$f" closed)" --arg here "$(machine)" --arg body "$(body "$f")" \
    '{$id, $state, $title, $from, $date, $repo, $branch, $closed, $body}
     | with_entries(select(.value != "" and .value != "none"))
     | .isMine = ($from != "" and $from == $here)'
}

json() {
  local f
  [ -d "$DONE" ] && find "$DONE" -maxdepth 1 -name '*.md' -mtime +"$DONE_DAYS" -exec rm -f {} + 2> /dev/null
  {
    for f in "$DIR"/*.md; do [ -f "$f" ] && one "$f" open; done
    for f in "$DONE"/*.md; do
      [ -f "$f" ] || continue
      if [ "$(frontmatter "$f" canceled)" = yes ]; then one "$f" canceled; else one "$f" done; fi
    done
  } | jq -s .
}

note_file() {
  [ -n "${1:-}" ] && [ -f "$DIR/$1.md" ] || {
    echo "no open handoff ${1:-}" >&2
    exit 1
  }
}

# close ID [canceled]: moves the note to done/, with when it was closed.
close() {
  note_file "$1"
  set_field "$DIR/$1.md" closed "$(date '+%Y-%m-%d %H:%M')"
  [ -n "${2:-}" ] && set_field "$DIR/$1.md" canceled yes
  mkdir -p "$DONE"
  mv "$DIR/$1.md" "$DONE/$1.md"
}

drop_field() {
  awk -v k="$2" '{ sub(/\r$/, "") } NR == 1 { print; next } !end && $0 == "---" { end = 1 } !end && index($0, k ":") == 1 { next } { print }' \
    "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

restore() {
  [ -n "${1:-}" ] && [ -f "$DONE/$1.md" ] || {
    echo "no done handoff ${1:-}" >&2
    exit 1
  }
  drop_field "$DONE/$1.md" closed
  drop_field "$DONE/$1.md" canceled
  mv "$DONE/$1.md" "$DIR/$1.md"
  echo "restored: $1"
}

delete() {
  local f
  for f in "$DIR/${1:-}.md" "$DONE/${1:-}.md"; do
    if [ -n "${1:-}" ] && [ -f "$f" ]; then
      rm -f "$f"
      echo "deleted $1"
      return 0
    fi
  done
  echo "no handoff ${1:-}" >&2
  exit 1
}

case "${1:-}" in
  json) json ;;
  done) close "${2:-}" && echo "done: $2" ;;
  cancel) close "${2:-}" canceled && echo "canceled: $2" ;;
  delete) delete "${2:-}" ;;
  restore) restore "${2:-}" ;;
  *)
    echo "usage: handoff.sh json|done ID|cancel ID|delete ID|restore ID" >&2
    exit 2
    ;;
esac
exit 0
