# Questions for install.sh and the setup scripts, sourced by them.
# Answers come from the terminal, or from the file KIT_INSTALL_ANSWERS (tests): one key=value per
# line, "prefix.*=value" answering every key under prefix. A key with no answer takes its default,
# and so does every question when there is no terminal.

kit_answer_in_file() {
  awk -v k="$1" '
    { i = index($0, "="); if (!i) next; key = substr($0, 1, i - 1); v = substr($0, i + 1) }
    key == k { print v; found = 1; exit }
    key ~ /\.\*$/ && index(k, substr(key, 1, length(key) - 1)) == 1 && !wild { wild = 1; w = v }
    END { if (!found && wild) print w }' "$KIT_INSTALL_ANSWERS"
}

# reply KEY PROMPT [DEFAULT]: prints the answer, DEFAULT when none is given.
reply() {
  local key=$1 prompt=$2 default=${3:-} answer=""
  local shown=$prompt
  [ -n "$default" ] && shown="$prompt [$default]"
  if [ -n "${KIT_INSTALL_ANSWERS:-}" ]; then
    answer=$(kit_answer_in_file "$key")
    printf '%s %s\n' "$shown" "${answer:-$default}" >&2
  elif (: < /dev/tty) 2> /dev/null; then
    read -r -p "$shown " answer < /dev/tty || answer=""
  fi
  printf '%s' "${answer:-$default}"
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
