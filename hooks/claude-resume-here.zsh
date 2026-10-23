# Sourced from ~/.zshrc. In a WebStorm or Ghostty terminal tab, offer to resume
# the Claude Code sessions that were left open in this directory (recorded by the
# SessionStart hook and never cleanly ended). Runs once, at the first prompt.
#
# Each session is shown by its title (the /rename title, else its first prompt)
# with a brief: how many prompts, when it was last used, what the last prompt was.
# Keys: 1-9 check or uncheck, a all, n none, Enter resumes the checked ones one
# after another in this tab and keeps the others for the next tab, d forgets the
# checked ones, f forgets them all, q (or 10 s of silence) leaves them all alone.
#
# CLAUDE_RESUME_DRY=1 prints the resume command instead of running it.
# CLAUDE_RESUME_KEYS feeds the keys (tests); CLAUDE_RESUME_TEST lifts the terminal check.

[[ ( "$TERMINAL_EMULATOR" == "JetBrains-JediTerm" || "$TERM_PROGRAM" == "ghostty" || -n "$CLAUDE_RESUME_TEST" ) && ( -o interactive || -n "$CLAUDE_RESUME_TEST" ) && -z "$CLAUDECODE" ]] || return 0

zmodload zsh/datetime zsh/stat 2>/dev/null

_claude_resume_here() {
  add-zsh-hook -d precmd _claude_resume_here 2>/dev/null
  local reg="$HOME/.claude/session-registry" rec id i key
  local -a recs ids titles counts lasts stamps order checked
  mkdir -p "$reg/claimed" "$reg/skipped"

  for rec in "$reg"/*.json(N); do
    [[ "$(jq -r '.cwd // empty' "$rec" 2>/dev/null)" == "$PWD" ]] || continue
    id=$(jq -r '.session_id // empty' "$rec" 2>/dev/null)
    [[ -n "$id" ]] || continue
    _claude_session_live "$id" && continue
    mv "$rec" "$reg/claimed/" 2>/dev/null || continue
    rec="$reg/claimed/${rec:t}"
    if ! _claude_resume_describe "$rec" "$id"; then
      mv "$rec" "$reg/skipped/"
      continue
    fi
    recs+=("$rec"); ids+=("$id")
    stamps+=("${reply[1]}"); titles+=("${reply[2]}"); counts+=("${reply[3]}"); lasts+=("${reply[4]}")
  done
  (( ${#ids} )) || return 0

  for i in {1..${#ids}}; do order+=("$(printf '%020d %d' "${stamps[i]}" "$i")"); done
  order=(${${(On)order}##* })
  local total=${#ids} shown=${#ids}
  (( shown > 9 )) && shown=9
  for i in {1..$shown}; do checked[i]=0; done
  checked[1]=1

  _claude_resume_draw
  local timeout=10 lines=$_claude_resume_lines
  while :; do
    if ! _claude_resume_key "$timeout"; then
      print "  No key in ${timeout} s: left for the next tab."
      _claude_resume_release
      return 0
    fi
    timeout=""
    case "$key" in
      [1-9]) (( key <= shown )) && checked[key]=$(( 1 - checked[key] )) ;;
      a) for i in {1..$shown}; do checked[i]=1; done ;;
      n) for i in {1..$shown}; do checked[i]=0; done ;;
      f)
        mv "${recs[@]}" "$reg/skipped/" 2>/dev/null
        print "  Forgotten: $total session${${total:#1}:+s}."
        return 0 ;;
      d)
        local -a kept
        for i in {1..$shown}; do
          if (( checked[i] )); then mv "${recs[order[i]]}" "$reg/skipped/" 2>/dev/null; else kept+=("${recs[order[i]]}"); fi
        done
        (( total > shown )) && for i in {$(( shown + 1 ))..$total}; do kept+=("${recs[order[i]]}"); done
        (( ${#kept} )) && mv "${kept[@]}" "$reg/" 2>/dev/null
        print "  Forgotten the checked ones; ${#kept} kept for the next tab."
        return 0 ;;
      q|$'\e')
        _claude_resume_release
        print "  Left for the next tab."
        return 0 ;;
      $'\n'|$'\r')
        local -a run
        for i in {1..$shown}; do (( checked[i] )) && run+=("${order[i]}"); done
        if (( ! ${#run} )); then
          _claude_resume_release
          print "  Nothing checked: left for the next tab."
          return 0
        fi
        for i in {1..$total}; do (( ${run[(Ie)$i]} )) || mv "${recs[i]}" "$reg/" 2>/dev/null; done
        local k=0
        for i in "${run[@]}"; do
          (( k++ ))
          rm -f "${recs[i]}"
          (( ${#run} > 1 )) && print -r -- $'🌊 Resuming \e[1m'"${titles[i]}"$'\e[0m'" ($k of ${#run})"
          if [[ -n "$CLAUDE_RESUME_DRY" ]]; then
            print "dry-run: claude --resume ${ids[i]}"
          else
            command claude --resume "${ids[i]}"
          fi
        done
        return 0 ;;
    esac
    print -n "\e[${lines}A\e[J"
    _claude_resume_draw
  done
}

# Prints the list; _claude_resume_lines holds how many lines it took.
_claude_resume_draw() {
  local i j mark when title brief cols=${COLUMNS:-100} b=$'\e[1m' r=$'\e[0m' dim=$'\e[2m'
  (( cols < 60 )) && cols=100
  local s=""; (( total > 1 )) && s=s
  print -r -- "🌊 ${b}${total}${r} Claude session${s} left open here:"
  _claude_resume_lines=2
  for i in {1..$shown}; do
    j=${order[i]}
    mark=" "; (( checked[i] )) && mark="x"
    _claude_resume_when "${stamps[j]}"; when=$REPLY
    title=${titles[j]}
    (( ${#title} > cols - 36 )) && title="${title[1,cols-39]}…"
    print -r -- " [$mark] $i  ${b}${title}${r} ${dim}· ${counts[j]} prompt${${counts[j]:#1}:+s} · ${when}${r}"
    (( _claude_resume_lines++ ))
    if (( counts[j] > 1 )) && [[ -n "${lasts[j]}" && "${lasts[j]}" != "${titles[j]}" ]]; then
      brief=${lasts[j]}
      (( ${#brief} > cols - 20 )) && brief="${brief[1,cols-23]}…"
      print -r -- "        ${dim}↳ last: ${brief}${r}"
      (( _claude_resume_lines++ ))
    fi
  done
  if (( total > shown )); then
    print -r -- "        ${dim}… and $(( total - shown )) older (f forgets them too)${r}"
    (( _claude_resume_lines++ ))
  fi
  print -r -- "${dim}1-$shown check · a all · n none · Enter resume checked · d forget checked · f forget all · q leave${r}"
}

# Sets reply=(epoch_seconds title prompt_count last_prompt); fails when the session holds no prompt.
_claude_resume_describe() {
  local rec=$1 id=$2 transcript name title count=0 first="" last="" stamp="" hist="$HOME/.claude/history.jsonl"
  transcript=$(jq -r '.transcript_path // empty' "$rec" 2>/dev/null)
  local us=$'\x1f'
  if [[ -f "$hist" ]]; then
    IFS=$us read -r count first last stamp <<< "$(grep -a -F "\"sessionId\":\"$id\"" "$hist" 2>/dev/null | jq -rs '
      map(select((.display | type) == "string" and (.display | ltrimstr(" ") | length) > 0)) | sort_by(.timestamp)
      | [length, (.[0].display // "" | split("\n")[0] // ""), (.[-1].display // "" | split("\n")[0] // ""),
         ((.[-1].timestamp // 0) / 1000 | floor)] | map(tostring) | join("\u001f")' 2>/dev/null)"
  fi
  if (( ${count:-0} == 0 )) && [[ -f "$transcript" ]]; then
    IFS=$us read -r count first last stamp <<< "$(grep -a '"type":"user"' "$transcript" | jq -rs '
      map(select((.isMeta | not) and (.message.content | type) == "string" and (.message.content | startswith("<") | not)))
      | [length, (.[0].message.content // "" | split("\n")[0] // ""), (.[-1].message.content // "" | split("\n")[0] // ""),
         ((.[-1].timestamp // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)] | map(tostring) | join("\u001f")' 2>/dev/null)"
  fi
  count=${count:-0}
  name=""
  [[ -f "$transcript" ]] && name=$(grep -a '"type":"custom-title"' "$transcript" | tail -n 1 | jq -r '.customTitle // empty' 2>/dev/null)
  [[ -z "$name" ]] && name=$(jq -r '.session_name // empty' "$rec" 2>/dev/null)
  title=${name:-$first}
  [[ -n "$title" ]] || return 1
  if [[ -z "$stamp" || "$stamp" == 0 ]]; then
    if [[ -f "$transcript" ]]; then stamp=$(zstat +mtime "$transcript" 2>/dev/null); else stamp=$(zstat +mtime "$rec" 2>/dev/null); fi
  fi
  reply=("${stamp:-0}" "$title" "$count" "$last")
}

# Reads one key into $key: from CLAUDE_RESUME_KEYS when set, else the terminal. $1 is a timeout in seconds or "".
_claude_resume_key() {
  key=""
  if [[ -n "$CLAUDE_RESUME_KEYS" ]]; then
    key=${CLAUDE_RESUME_KEYS[1]}
    CLAUDE_RESUME_KEYS=${CLAUDE_RESUME_KEYS[2,-1]}
  elif [[ -n "$1" ]]; then
    read -t "$1" -k 1 key 2>/dev/null
  else
    read -k 1 key 2>/dev/null
  fi
  [[ -n "$key" ]]
}

_claude_resume_release() {
  (( ${#recs} )) && mv "${recs[@]}" "$reg/" 2>/dev/null
  return 0
}

# Sets REPLY to a short relative time for an epoch in seconds.
_claude_resume_when() {
  local now=$EPOCHSECONDS day yday
  local d=$(( now - $1 ))
  if (( $1 <= 0 )); then REPLY="unknown"
  elif (( d < 120 )); then REPLY="just now"
  elif (( d < 3600 )); then REPLY="$(( d / 60 )) min ago"
  elif (( d < 86400 )); then REPLY="$(( d / 3600 )) h ago"
  else
    strftime -s day '%Y-%m-%d' "$1"
    strftime -s yday '%Y-%m-%d' $(( now - 86400 ))
    if [[ "$day" == "$yday" ]]; then strftime -s REPLY 'yesterday %H:%M' "$1"; else strftime -s REPLY '%d %b' "$1"; fi
  fi
}

_claude_session_live() {
  local f pid
  for f in "$HOME/.claude/sessions"/*.json(N); do
    [[ "$(jq -r '.sessionId // empty' "$f" 2>/dev/null)" == "$1" ]] || continue
    pid=$(jq -r '.pid // empty' "$f" 2>/dev/null)
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
  done
  return 1
}

autoload -U add-zsh-hook
add-zsh-hook precmd _claude_resume_here
