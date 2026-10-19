#!/bin/bash
# Sets up the Claude Code config sync on this computer. Run it from the cloned repo:
#   ~/.claude-sync/install.sh [machine-name [dev-folder]]
# The machine name picks machines/<name>.json (default: mac, windows or linux).
# The dev folder holds your git repos; without it, the install asks.
# On the first computer (the repo holds no config yet) it saves this computer's
# config in the repo; on the next ones it installs the saved config.
set -eu
SYNC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SYNC"

case "$(uname -s)" in
  Darwin) machine=mac ;;
  MINGW* | MSYS* | CYGWIN*) machine=windows ;;
  *) machine=linux ;;
esac
machine=${1:-$machine}

for tool in git jq; do
  command -v "$tool" > /dev/null || {
    echo "Install $tool first." >&2
    exit 1
  }
done
if [ "$SYNC" != "$HOME/.claude-sync" ]; then
  echo "Clone the repo to ~/.claude-sync: the hooks look for it there." >&2
  exit 1
fi
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    jq() { command jq -b "$@"; }
    home=$(cygpath -m "$HOME")
    ;;
  *) home=$HOME ;;
esac

git config core.autocrlf false

# The sync commits under this repo's own git identity, asked once per computer.
if [ -z "$(git config --local user.email || true)" ]; then
  name=$(git config user.name || true)
  email=$(git config user.email || true)
  if [ -t 0 ]; then
    read -r -p "Name for the sync's commits [$name]: " answer || answer=""
    name=${answer:-$name}
    read -r -p "Email for the sync's commits (a GitHub noreply address works) [$email]: " answer || answer=""
    email=${answer:-$email}
  fi
  if [ -z "$name" ] || [ -z "$email" ]; then
    echo "Set a git name and email first: git config --global user.name / user.email" >&2
    exit 1
  fi
  git config user.name "$name"
  git config user.email "$email"
fi

if [ ! -f "machines/$machine.json" ]; then
  mkdir -p machines
  printf '{\n  "devDir": "~/dev",\n  "exclude": [],\n  "settings": {}\n}\n' > "machines/$machine.json"
  echo "Created machines/$machine.json for this computer."
fi

current=$(jq -r '.devDir // "~/dev"' "machines/$machine.json")
if [ $# -ge 2 ]; then
  dev=$2
elif [ -t 0 ]; then
  read -r -p "Folder that holds your git repos [$current]: " dev || dev=""
else
  dev=""
fi
dev=${dev:-$current}
dev=${dev/#\~/$HOME}
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) dev=$(cygpath -u "$dev") ;; esac
[ -d "$dev" ] || echo "Note: $dev doesn't exist yet; repos cloned there will sync once it does."
case "$dev" in
  "$HOME") dev="~" ;;
  "$HOME"/*) dev="~/${dev#"$HOME"/}" ;;
  *) case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) dev=$(cygpath -m "$dev") ;; esac ;;
esac
if [ "$dev" != "$current" ]; then
  jq --arg d "$dev" '.devDir = $d' "machines/$machine.json" > "machines/$machine.json.tmp"
  mv "machines/$machine.json.tmp" "machines/$machine.json"
  echo "Dev folder for $machine: $dev"
fi
printf '%s\n' "$machine" > .machine

if [ -f claude/CLAUDE.md ]; then
  bash sync.sh install
else
  # First computer: the hooks that run the sync go into settings.json, which
  # the repo then shares with the other computers.
  settings="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  [ -f "$settings" ] || echo '{}' > "$settings"
  cp -p "$settings" "$settings.before-sync"
  jq --arg s "$home/.claude-sync/sync.sh" '
    def merge($o):
      if type == "object" and ($o | type) == "object" then
        reduce ($o | keys_unsorted[]) as $k (.; .[$k] = (if has($k) then .[$k] | merge($o[$k]) else $o[$k] end))
      elif type == "array" and ($o | type) == "array" then . + ($o - .)
      else $o end;
    def run($arg; $t): {hooks: [{type: "command", command: "bash \"\($s)\" \($arg)", timeout: $t}]};
    merge({hooks: {SessionStart: [run("start"; 60)], Stop: [run("bg"; 5)], SessionEnd: [run("bg"; 5)]}})' \
    "$settings.before-sync" > "$settings"
  # The next computers recognize a saved config by its CLAUDE.md.
  [ -f "$HOME/.claude/CLAUDE.md" ] || : > "$HOME/.claude/CLAUDE.md"
  bash sync.sh init
fi
bash sync.sh now
echo "Done. Start a new Claude Code session to load the synced config."
