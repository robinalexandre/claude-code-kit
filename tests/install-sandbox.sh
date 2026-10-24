#!/bin/bash
# Tries the installer the way a newcomer meets it, in a throwaway home folder: your own ~/.claude,
# ~/.gitconfig and shell files are neither read nor changed (checked before and after).
#   tests/install-sandbox.sh                  you answer the installer's questions yourself
#   tests/install-sandbox.sh --auto [FILE]    answers from FILE (key=value lines, see hooks/lib/ask.sh);
#                                             without FILE: every part, English, 🌊, no ~/.zshrc line
#   tests/install-sandbox.sh --claude DIR     opens Claude Code in a sandbox made earlier, for the
#                                             first session (Claude asks you to sign in there)
#   tests/install-sandbox.sh --report DIR     what the installer left in DIR, and the checks
#   tests/install-sandbox.sh --clean DIR      deletes a sandbox
# Works on macOS, Linux and Windows (Git Bash).
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REAL_HOME=$HOME
PATH_SEP=':'
command -v cygpath > /dev/null 2>&1 && PATH_SEP=';'
WATCHED=".claude/settings.json .claude/CLAUDE.md .claude.json .gitconfig .zshrc .bashrc .bash_profile"

die() {
  echo "$*" >&2
  exit 1
}

fingerprint() {
  local f
  for f in $WATCHED; do
    if [ -f "$REAL_HOME/$f" ]; then printf '%s %s\n' "$f" "$(cksum < "$REAL_HOME/$f")"; else echo "$f none"; fi
  done
}

# in_sandbox HOME CMD...: runs CMD with HOME (and what derives from it) in the sandbox, and none of
# this session's Claude settings in the environment.
in_sandbox() {
  local home=$1 var
  shift
  local -a unset_args=()
  for var in $(env | awk -F= '/^(CLAUDE|ANTHROPIC|MCP_|PR_WATCH|GIT_IDENTITY)/ { print $1 }'); do
    unset_args+=(-u "$var")
  done
  local profile=$home
  command -v cygpath > /dev/null 2>&1 && profile=$(cygpath -w "$home")
  env ${unset_args[@]+"${unset_args[@]}"} HOME="$home" USERPROFILE="$profile" ZDOTDIR="$home" \
    XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" XDG_STATE_HOME="$home/.local/state" \
    GIT_CONFIG_GLOBAL="$home/.gitconfig" CLAUDE_DEV_ROOT="$home/dev" "$@"
}

# Every group and part, English, 🌊; every setup question keeps its default, except those that would
# reach outside the sandbox.
auto_answers() {
  printf '%s\n' 'group.*=y' 'part.*=y' 'language=English' 'marker=🌊' 'marker.rule=y' 'zshrc=n' \
    'test-evidence.mcp=n' 'git-identity.match1=github.com' 'git-identity.email1=me@example.com' \
    'kb.embed=n' 'kb.curate=n' > "$1"
}

report() {
  local sandbox=$1 home="$1/home" problems=0 path
  [ -d "$home/.claude" ] || die "Nothing installed in $sandbox."
  echo
  echo "== What the installer put in $home/.claude"
  (cd "$home/.claude" && find . -maxdepth 2 -not -path './backups*' | sort | sed 's|^\./||' | grep .)
  echo
  echo "== settings.json"
  jq . "$home/.claude/settings.json" || { echo "!! settings.json is not valid JSON"; problems=$((problems + 1)); }
  if [ -f "$home/.claude/CLAUDE.md" ]; then
    echo
    echo "== CLAUDE.md"
    cat "$home/.claude/CLAUDE.md"
  fi
  echo
  echo "== Checks"
  while read -r path; do
    [ -z "$path" ] && continue
    if [ -e "$path" ]; then echo "ok   hook script $path"; else echo "!!   a hook runs $path, which is missing"; problems=$((problems + 1)); fi
  done < <(jq -r '.. | .command? // empty | strings' "$home/.claude/settings.json" | grep -o '"[^"]*\.\(sh\|zsh\|py\)"' | tr -d '"' | sort -u)
  while read -r path; do
    [ -z "$path" ] && continue
    if [ -d "$path" ]; then echo "ok   mod $path"; else echo "!!   mod folder $path is missing"; problems=$((problems + 1)); fi
  done < <(jq -r '.env.CLAUDE_CODE_PLUGIN_DIRS // empty' "$home/.claude/settings.json" | tr -d '\r' | tr "$PATH_SEP" '\n')
  # kit-install.json names the clone the kit was installed from, wherever it is.
  if grep -rIl --exclude-dir=backups --exclude=kit-install.json -- "$REAL_HOME/" "$home/.claude" 2> /dev/null | grep -q .; then
    echo "!!   files in the sandbox name your real home folder:"
    grep -rIl --exclude-dir=backups --exclude=kit-install.json -- "$REAL_HOME/" "$home/.claude" | sed 's/^/       /'
    problems=$((problems + 1))
  else
    echo "ok   nothing in the sandbox points at your real home folder"
  fi
  if [ -f "$sandbox/before.txt" ]; then
    if [ "$(fingerprint)" = "$(cat "$sandbox/before.txt")" ]; then
      echo "ok   your own ~/.claude, git and shell files are unchanged"
    elif [ "$(fingerprint | grep -v '^\.claude\.json ')" = "$(grep -v '^\.claude\.json ' "$sandbox/before.txt")" ]; then
      echo "note your ~/.claude.json changed during the test: a Claude Code session open meanwhile writes it too"
    else
      echo "!!   one of your own files changed during the test:"
      diff <(cat "$sandbox/before.txt") <(fingerprint) | sed 's/^/       /'
      problems=$((problems + 1))
    fi
  fi
  if [ -f "$sandbox/failed" ]; then echo "!!   the installer failed"; problems=$((problems + 1)); fi
  if grep -q 'stopped; run it again' "$sandbox/install.log" 2> /dev/null; then
    echo "!!   a setup stopped:"
    grep 'stopped; run it again' "$sandbox/install.log" | sed 's/^/       /'
    problems=$((problems + 1))
  fi
  [ -f "$sandbox/questions.txt" ] && { echo; echo "== Questions the installer asked"; cat "$sandbox/questions.txt"; }
  echo
  echo "$problems problem(s). Next: $0 --claude $sandbox   (first session)   ·   $0 --clean $sandbox"
  [ "$problems" -eq 0 ]
}

case "${1:-}" in
  --clean)
    [ -n "${2:-}" ] && [ -f "$2/.kit-sandbox" ] || die "Not a sandbox: ${2:-}"
    rm -rf "$2" && echo "Deleted $2"
    exit 0
    ;;
  --report)
    [ -n "${2:-}" ] && [ -f "$2/.kit-sandbox" ] || die "Not a sandbox: ${2:-}"
    report "$2"
    exit
    ;;
  --claude)
    [ -n "${2:-}" ] && [ -f "$2/.kit-sandbox" ] || die "Not a sandbox: ${2:-}"
    command -v claude > /dev/null || die "Claude Code is not installed."
    repo="$2/home/dev/sample-app"
    if [ ! -d "$repo/.git" ]; then
      mkdir -p "$repo"
      in_sandbox "$2/home" git -C "$repo" init -q
      printf '# Sample app\n\nA throwaway repo for the first session.\n' > "$repo/README.md"
    fi
    echo "Claude Code in the sandbox ($repo). Your real config is not loaded; sign in when asked."
    echo "Try: \"what did the kit install, and what should I configure first?\""
    cd "$repo" && in_sandbox "$2/home" claude
    exit
    ;;
esac

command -v jq > /dev/null || die "Install jq first."
tmp=${TMPDIR:-/tmp}
SANDBOX=$(mktemp -d "${tmp%/}/kit-sandbox.XXXXXX") || die "No temp folder."
touch "$SANDBOX/.kit-sandbox"
mkdir -p "$SANDBOX/home/dev"
fingerprint > "$SANDBOX/before.txt"
echo "Sandbox: $SANDBOX (home: $SANDBOX/home)"

if [ "${1:-}" = --auto ]; then
  answers=${2:-}
  if [ -z "$answers" ]; then
    answers="$SANDBOX/answers.txt"
    auto_answers "$answers"
  fi
  in_sandbox "$SANDBOX/home" env KIT_INSTALL_ANSWERS="$answers" bash "$KIT/install.sh" 2> "$SANDBOX/questions.txt" | tee "$SANDBOX/install.log"
  status=${PIPESTATUS[0]}
else
  in_sandbox "$SANDBOX/home" bash "$KIT/install.sh" | tee "$SANDBOX/install.log"
  status=${PIPESTATUS[0]}
fi
echo "Installer exit code: $status"
[ "$status" -eq 0 ] || touch "$SANDBOX/failed"
report "$SANDBOX"
