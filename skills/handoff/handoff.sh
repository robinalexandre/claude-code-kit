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

# set_field FILE KEY VALUE: sets KEY in FILE's front matter, added before its end if missing.
set_field() {
  awk -v k="$2" -v v="$3" '{ sub(/\r$/, "") }
    NR == 1 { print; next }
    !end && $0 == "---" { if (!set) print k ": " v; end = 1; print; next }
    !end && index($0, k ":") == 1 { print k ": " v; set = 1; next }
    { print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# notes KIND FILE...: one line per FILE: KIND, its id, its front matter values (title from date repo
# branch closed canceled) and its body as a JSON string, \037 between them, from one awk run. An
# empty file has no line.
notes() {
  local kind=$1
  shift
  [ $# -gt 0 ] || return 0
  awk -v kind="$kind" -v keys="title from date repo branch closed canceled" '
    BEGIN { n = split(keys, k, " "); for (i = 1; i < 32; i++) ctl[sprintf("%c", i)] = sprintf("\\u%04x", i) }
    function esc(s,   out, i, c) {
      gsub(/\\/, "\\\\", s)
      gsub(/"/, "\\\"", s)
      if (s !~ /[[:cntrl:]]/) return s
      out = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); out = out ((c in ctl) ? ctl[c] : c) }
      return out
    }
    function flush(   j, line, id, parts, m) {
      if (file == "") return
      m = split(file, parts, "/")
      id = parts[m]
      sub(/\.md$/, "", id)
      line = kind "\037" id
      for (j = 1; j <= n; j++) line = line "\037" v[k[j]]
      sub(/\n+$/, "", body)
      print line "\037\"" esc(body) "\""
    }
    FNR == 1 { flush(); file = FILENAME; split("", v); body = ""; fm = 0 }
    { sub(/\r$/, "") }
    FNR == 1 && $0 == "---" { fm = 1; next }
    fm && $0 == "---" { fm = 0; next }
    fm { i = index($0, ":"); key = substr($0, 1, i - 1)
      if (i && !(key in v)) { val = substr($0, i + 1); sub(/^ +/, "", val); sub(/ +$/, "", val); v[key] = val }
      next }
    { body = body $0 "\n" }
    END { flush() }' "$@"
}

# json: every note, open and done, as one JSON array (the reminders and handoffs pane), from one
# awk and one jq run: one awk per field took a second per note on a slow Windows computer.
json() {
  local f here=""
  local -a open=() closed=()
  [ -d "$DONE" ] && find "$DONE" -maxdepth 1 -name '*.md' -mtime +"$DONE_DAYS" -exec rm -f {} + 2> /dev/null
  [ -f "$SYNC/.machine" ] && read -r here < "$SYNC/.machine"
  here=${here//[[:space:]]/}
  for f in "$DIR"/*.md; do [ -f "$f" ] && open+=("$f"); done
  for f in "$DONE"/*.md; do [ -f "$f" ] && closed+=("$f"); done
  {
    notes open ${open[@]+"${open[@]}"}
    notes done ${closed[@]+"${closed[@]}"}
  } | jq -nR --arg here "$here" '[inputs | split("\u001f") as $r
    | (if $r[0] == "open" then "open" elif $r[8] == "yes" then "canceled" else "done" end) as $state
    | {id: $r[1], state: $state, title: $r[2], from: $r[3], date: $r[4], repo: $r[5], branch: $r[6],
       closed: $r[7], body: ($r[9] | fromjson)}
    | with_entries(select(.value != "" and .value != "none"))
    | .isMine = ($r[3] != "" and $r[3] == $here)]'
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
