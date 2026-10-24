# Questions for install.sh and the setup scripts, sourced by them.
# Answers come from the terminal, or from the file KIT_INSTALL_ANSWERS (tests): one key=value per
# line, "prefix.*=value" answering every key under prefix. A key with no answer takes its default,
# and so does every question when there is no terminal.
#
# Each answer is recorded in ~/.claude/kit-answers.txt (this computer only; the config sync shares it
# through inventory/<computer>.json). A computer set up later can reuse another's answers, asked once
# and kept in ~/.claude/kit-reuse.txt: the same (only secrets and this computer's own questions asked),
# as defaults to change, or none. Delete that file to be asked again.

KIT_ANSWERS_FILE=${KIT_ANSWERS_FILE:-$HOME/.claude/kit-answers.txt}
KIT_REUSE_FILE=${KIT_REUSE_FILE:-$HOME/.claude/kit-reuse.txt}
# Never recorded: anyone who has them can read what they guard.
KIT_SECRET_KEYS="reminders.topic config-sync.repo config-sync.key"
# Asked on every computer, even one set up like another: they describe this computer.
KIT_OWN_KEYS="config-sync.* reuse.* recent-activity.dev zshrc statusline.replace"

kit_answer_in_file() {
  awk -v k="$1" '
    { i = index($0, "="); if (!i) next; key = substr($0, 1, i - 1); v = substr($0, i + 1) }
    key == k { print v; found = 1; exit }
    key ~ /\.\*$/ && index(k, substr(key, 1, length(key) - 1)) == 1 && !wild { wild = 1; w = v }
    END { if (!found && wild) print w }' "$KIT_INSTALL_ANSWERS"
}

# kit_key_in KEY LIST: succeeds when KEY is in LIST, whose words may end in ".*".
kit_key_in() {
  local word
  for word in $2; do
    case "$word" in
      *.\*) [ "${1#"${word%\*}"}" != "$1" ] && return 0 ;;
      *) [ "$1" = "$word" ] && return 0 ;;
    esac
  done
  return 1
}

kit_record() {
  local key=$1 value=$2 file=$KIT_ANSWERS_FILE
  kit_key_in "$key" "$KIT_SECRET_KEYS reuse.*" && return 0
  case "$value" in *$'\n'* | *$'\r'*) return 0 ;; esac
  mkdir -p "$(dirname "$file")" 2> /dev/null || return 0
  { awk -v k="$key" 'index($0, k "=") != 1' "$file" 2> /dev/null || true; printf '%s=%s\n' "$key" "$value"; } > "$file.tmp" &&
    mv "$file.tmp" "$file"
}

kit_tty() { (: < /dev/tty) 2> /dev/null; }

# The other computers of the config sync that recorded answers, one name per line.
kit_reuse_candidates() {
  local f mine
  mine=$(tr -d '[:space:]' 2> /dev/null < "$HOME/.claude-sync/.machine" || true)
  for f in "$HOME"/.claude-sync/inventory/*.json; do
    [ -f "$f" ] || continue
    jq -r --arg mine "$mine" 'select(.machine != $mine and ((.answers // {}) | length) > 0) | .machine' "$f" 2> /dev/null | tr -d '\r'
  done
}

# kit_reuse_setting from|mode: the choice kept in KIT_REUSE_FILE.
kit_reuse_setting() { sed -n "s/^$1=//p" "$KIT_REUSE_FILE" 2> /dev/null | tr -d '\r' | head -1; }

# Asks once, at the first question with a terminal, whether to set this computer up like another.
kit_reuse_init() {
  local names count pick mode i n
  [ -z "${KIT_INSTALL_ANSWERS:-}" ] && [ -z "${KIT_REUSE_ASKING:-}" ] && [ ! -f "$KIT_REUSE_FILE" ] || return 0
  names=$(kit_reuse_candidates)
  [ -n "$names" ] && kit_tty || return 0
  KIT_REUSE_ASKING=1
  count=$(grep -c . <<< "$names")
  echo "Your config sync has the answers another computer gave these questions." >&2
  i=0
  while IFS= read -r n; do
    i=$((i + 1))
    echo "  $i) the same as $n: only secrets and this computer's own questions (name, repos folder, shell) are asked" >&2
    echo "  $((count + i))) starting from $n: every question, with $n's answer filled in" >&2
  done <<< "$names"
  echo "  $((2 * count + 1))) from scratch" >&2
  pick=$(reply reuse.mode "Set this computer up:" 1)
  KIT_REUSE_ASKING=""
  case "$pick" in *[!0-9]* | "") pick=$((2 * count + 1)) ;; esac
  if [ "$pick" -ge 1 ] && [ "$pick" -le "$count" ]; then
    mode=same
  elif [ "$pick" -gt "$count" ] && [ "$pick" -le $((2 * count)) ]; then
    mode=start pick=$((pick - count))
  else
    mode=none pick=0
  fi
  n=""
  [ "$pick" -eq 0 ] || n=$(sed -n "${pick}p" <<< "$names")
  mkdir -p "$(dirname "$KIT_REUSE_FILE")" && printf 'mode=%s\nfrom=%s\n' "$mode" "$n" > "$KIT_REUSE_FILE"
}

# kit_from KEY: the answer the computer this one is set up like gave KEY; fails when it gave none.
kit_from() {
  local from value
  case "$(kit_reuse_setting mode)" in same | start) ;; *) return 1 ;; esac
  from=$(kit_reuse_setting from)
  [ -n "$from" ] && ! kit_key_in "$1" "$KIT_SECRET_KEYS config-sync.* reuse.*" || return 1
  value=$(jq -er --arg k "$1" '.answers | if has($k) then .[$k] else error end' "$HOME/.claude-sync/inventory/$from.json" 2> /dev/null) ||
    return 1
  printf '%s' "${value%$'\r'}"
}

# reply KEY PROMPT [DEFAULT]: prints the answer, DEFAULT when none is given.
reply() {
  local key=$1 prompt=$2 default=${3:-} answer="" from shown reused=""
  kit_reuse_init
  if from=$(kit_from "$key"); then
    default=$from
    [ "$(kit_reuse_setting mode)" = same ] && ! kit_key_in "$key" "$KIT_OWN_KEYS" && reused=1
  fi
  shown=$prompt
  [ -n "$default" ] && shown="$prompt [$default]"
  if [ -n "${KIT_INSTALL_ANSWERS:-}" ]; then
    answer=$(kit_answer_in_file "$key")
    printf '%s %s\n' "$shown" "${answer:-$default}" >&2
  elif [ -n "$reused" ]; then
    printf '%s %s (as on %s)\n' "$prompt" "${from:-(blank)}" "$(kit_reuse_setting from)" >&2
    answer=$from
  elif kit_tty; then
    read -r -p "$shown " answer < /dev/tty || answer=""
  fi
  answer=${answer:-$default}
  kit_record "$key" "$answer"
  printf '%s' "$answer"
}

# ask KEY PROMPT [y|n]: succeeds on yes; the default is no unless y is given.
ask() {
  local hint="y/N"
  [ "${3:-n}" = y ] && hint="Y/n"
  case "$(reply "$1" "$2 [$hint]" "")" in
    [yY]*) return 0 ;;
    [nN]*) return 1 ;;
    *) [ "${3:-n}" = y ] ;;
  esac
}

# kit_path PATH: PATH as Windows programs (git.exe, jq.exe, Claude Code) read it; unchanged elsewhere.
kit_path() {
  if command -v cygpath > /dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# kit_env KEY VALUE: sets an environment variable for Claude Code in ~/.claude/settings.json.
kit_env() {
  local settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || echo '{}' > "$settings"
  jq --indent 2 --arg k "$1" --arg v "$2" '.env[$k] = $v' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
}

# kit_has TOOL...: succeeds when every TOOL is on the PATH, else names the missing ones on stderr.
kit_has() {
  local t missing=""
  for t in "$@"; do command -v "$t" > /dev/null 2>&1 || missing="$missing $t"; done
  [ -z "$missing" ] && return 0
  echo "  Missing:$missing" >&2
  return 1
}
