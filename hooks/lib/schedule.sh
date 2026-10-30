# Dated Markdown items shared by the reminders and handoff skills: a reminder, or a task an
# assistant runs by itself, is one file with a YAML front matter (title on until where machine
# every times done group closed digest). Sourced; the caller sets NOW ("YYYY-MM-DD HH:MM"),
# MACHINE and DEFAULT_AT (the time of day a repeating one shows when `on` gives none).
# A repeating one has `every: friday` (days in English, comma-separated, or `day` or `weekday`,
# or "3 days", or `month`) and shows on those days from `on` until `until`.

ITEM_KEYS="title on until where machine every times done group closed digest"

# fields FILE: sets F_<key> to each of FILE's front matter values in one awk run. Every process
# costs a few hundred milliseconds on some Windows computers, against the hooks' 10 s timeout.
F_FILE=""
fields() {
  [ "$F_FILE" = "$1" ] && return 0
  IFS=$'\037' read -r F_title F_on F_until F_where F_machine F_every F_times F_done F_group F_closed F_digest < <(
    awk -v keys="$ITEM_KEYS" '
      BEGIN { n = split(keys, k, " ") }
      { sub(/\r$/, "") }
      NR == 1 && $0 != "---" { exit }
      NR > 1 && $0 == "---" { exit }
      NR > 1 { i = index($0, ":"); key = substr($0, 1, i - 1)
        if (i && !(key in v)) { val = substr($0, i + 1); sub(/^ +/, "", val); sub(/ +$/, "", val); v[key] = val } }
      END { for (j = 1; j <= n; j++) printf "%s%s", v[k[j]], (j < n ? "\037" : "\n") }' "$1"
  )
  F_FILE=$1
}

lower() { tr 'A-Z\\' 'a-z/'; }

# in_place DIR WHERE: whether DIR is the folder WHERE (a path or its tail, e.g.
# "dev/shop"), or inside it.
in_place() {
  local d w
  d="$(printf '%s/' "$1" | lower)"
  w=$(printf '%s' "${2#\~/}" | lower)
  w=${w%/}
  case "$d" in *"/$w/"*) return 0 ;; esac
  return 1
}

# weekdays EVERY: the ISO weekday numbers (1 = Monday) that EVERY (lower-case) names.
weekdays() {
  local d out=""
  for d in ${1//,/ }; do
    case "$d" in
      day | daily) out="1 2 3 4 5 6 7" ;;
      weekday | weekdays) out="$out 1 2 3 4 5" ;;
      mon*) out="$out 1" ;;
      tue*) out="$out 2" ;;
      wed*) out="$out 3" ;;
      thu*) out="$out 4" ;;
      fri*) out="$out 5" ;;
      sat*) out="$out 6" ;;
      sun*) out="$out 7" ;;
    esac
  done
  printf '%s' "${out# }"
}

# GNU date first, then BSD date (macOS).
epoch_of() { date -d "$1 12:00" +%s 2> /dev/null || date -j -f '%Y-%m-%d %H:%M' "$1 12:00" +%s; }

# days_from DAY N: DAY and the N days after it, one "YYYY-MM-DD <ISO weekday>" line each. GNU date
# reads them all in one run; noon plus whole days stays on the right date across DST changes.
days_from() {
  local e k
  if e=$(date -d "$1 12:00" +%s 2> /dev/null); then
    for ((k = 0; k <= $2; k++)); do printf '@%d\n' $((e + k * 86400)); done | date -f - '+%Y-%m-%d %u'
  else
    for ((k = 0; k <= $2; k++)); do date -j -v+"$k"d -f %Y-%m-%d "$1" '+%Y-%m-%d %u'; done
  fi
}

# next_time FILE: "YYYY-MM-DD HH:MM" a repeating one shows next, today's while it isn't closed:
# on the weekdays `every` names, every N days counted from `on`, or each month on `on`'s day (the
# last day of a shorter month). With `times: 08:00, 14:00`, the next of those times.
# next_time_of sets NEXT instead, without a subshell.
next_time() {
  next_time_of "$1"
  printf '%s' "$NEXT"
}

next_time_of() {
  local every on at times base today=${NOW% *} now=${NOW#* } mode since=0 n=0 wds="" k=0 d w t
  local -a day=() wd=()
  NEXT=""
  fields "$1"
  [ -n "$F_every" ] || return 0
  every=$F_every
  case "$every" in *[A-Z\\]*) every=$(printf '%s' "$every" | lower) ;; esac
  while [[ "$every" == *"  "* ]]; do every=${every//  / }; done
  on=$F_on
  at=$DEFAULT_AT
  [ ${#on} -gt 10 ] && at=${on:11:5}
  times=${F_times//,/ }
  base=$today
  [ -n "$on" ] && [[ "$base" < "${on:0:10}" ]] && base=${on:0:10}
  case "$every" in
    [0-9]*day | [0-9]*days)
      mode=days
      n=${every%% *}
      n=${n%day*}
      [ -n "$on" ] && [ "$n" -gt 0 ] 2> /dev/null || return 0
      [ "$base" = "${on:0:10}" ] || since=$((($(epoch_of "$base") - $(epoch_of "${on:0:10}") + 43200) / 86400))
      ;;
    month | monthly)
      mode=month
      [ -n "$on" ] || return 0
      ;;
    *)
      mode=week
      wds=" $(weekdays "$every") "
      ;;
  esac
  while read -r d w; do
    day[k]=$d
    wd[k]=$w
    k=$((k + 1))
  done < <(days_from "$base" 63)
  for ((k = 0; k < 63; k++)); do
    d=${day[k]:-}
    [ -n "$d" ] || return 0
    [ "$d" = "$F_done" ] && continue
    case "$mode" in
      days) [ $(((since + k) % n)) -eq 0 ] || continue ;;
      month)
        w=${day[k + 1]:-}
        [ "${d:8:2}" = "${on:8:2}" ] || { [[ "${on:8:2}" > "${d:8:2}" ]] && [ "${w:8:2}" = 01 ]; } || continue
        ;;
      week) [[ "$wds" == *" ${wd[k]} "* ]] || continue ;;
    esac
    if [ -n "$times" ]; then
      at=""
      for t in $times; do
        { [ "$d" != "$today" ] || [[ ! "$t" < "$now" ]]; } && { at=$t; break; }
      done
      [ -n "$at" ] || continue
    fi
    NEXT="$d $at"
    return 0
  done
}

# state FILE [DIR]: due, later or expired; "elsewhere" when it is for another folder or computer
# than a session in DIR. state_of sets S instead.
state() {
  state_of "$@"
  echo "$S"
}

state_of() {
  local f=$1 cwd=${2:-} on today=${NOW% *}
  fields "$f"
  on=$F_on
  [ ${#on} -eq 10 ] && on="$on 00:00"
  if [ -n "$F_every" ]; then
    next_time_of "$f"
    on=$NEXT
  fi
  if [ -n "$F_until" ] && { [[ "$F_until" < "$today" ]] || [[ "$F_until" < "${on:0:10}" ]]; }; then
    S=expired
  elif [ -n "$F_every" ] && [ -z "$on" ]; then
    S=expired
  elif [ -n "$on" ] && [[ "$NOW" < "$on" ]]; then
    S=later
  elif [ -n "$F_machine" ] && [ "$F_machine" != "$MACHINE" ]; then
    S=elsewhere
  elif [ -n "$cwd" ] && [ -n "$F_where" ] && ! in_place "$cwd" "$F_where"; then
    S=elsewhere
  else
    S=due
  fi
}

# records KIND AGENT FOLDER FILE...: one line per FILE: KIND, AGENT, FOLDER, the file, its front
# matter values in fields' order and its body as a JSON string, \037 between them, from one awk
# run for all the files. An empty file has no line.
records() {
  local kind=$1 agent=$2 folder=$3
  shift 3
  [ $# -gt 0 ] || return 0
  awk -v kind="$kind" -v agent="$agent" -v folder="$folder" -v keys="$ITEM_KEYS" '
    BEGIN { n = split(keys, k, " "); for (i = 1; i < 32; i++) ctl[sprintf("%c", i)] = sprintf("\\u%04x", i) }
    function esc(s,   out, i, c) {
      gsub(/\\/, "\\\\", s)
      gsub(/"/, "\\\"", s)
      if (s !~ /[[:cntrl:]]/) return s
      out = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); out = out ((c in ctl) ? ctl[c] : c) }
      return out
    }
    function flush(   j, line) {
      if (file == "") return
      line = kind "\037" agent "\037" folder "\037" file
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

# items_json CWD: the records on stdin as a JSON array (the reminders and handoffs pane), each with
# its state and when a repeating one shows next, its empty fields left out. One jq run in all.
items_json() {
  local cwd=$1 kind name dir f id body
  while IFS=$'\037' read -r kind name dir f F_title F_on F_until F_where F_machine F_every F_times F_done F_group F_closed F_digest body; do
    F_FILE=$f
    NEXT=""
    case "$kind" in
      open) state_of "$f" "$cwd" ;;
      agent) state_of "$f" ;;
      *)
        S=past
        next_time_of "$f"
        ;;
    esac
    id=${f##*/}
    id=${id%.md}
    case "$kind" in agent*) id="$dir/$id" ;; esac
    printf '%s\037' "$kind" "$name" "$id" "$S" "$F_title" "$F_on" "$F_until" "$F_every" "$F_times" "$F_digest" \
      "$F_where" "$F_machine" "$F_group" "$F_done" "$F_closed" "$NEXT"
    printf '%s\n' "$body"
  done | jq -nR '[inputs | split("\u001f") as $r
    | {id: $r[2], state: $r[3], title: $r[4], on: $r[5], until: $r[6], every: $r[7], times: $r[8], digest: $r[9],
       where: $r[10], machine: $r[11], group: $r[12], done: $r[13], closed: $r[14], next: $r[15], body: ($r[16] | fromjson)}
    | with_entries(select(.value != ""))
    | if ($r[0] | startswith("agent")) then .agent = $r[1] | .group = $r[1] else . end]'
}

# agents_in FILE...: "name<TAB>folder" for each assistant in the first FILE that exists
# ([{"name": "<assistant>", "dir": "<folder, from the sync repo's root>"}]); a folder going up (..)
# is left out.
agents_in() {
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    jq -r '.[] | select((.name // "") != "" and (.dir // "") != "")
      | select(.dir | test("(^|/)\\.\\.(/|$)") | not) | "\(.name)\t\(.dir | sub("/+$"; ""))"' \
      "$f" 2> /dev/null | tr -d '\r'
    return 0
  done
}
