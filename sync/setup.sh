#!/bin/bash
# Sets up the config sync on this computer, from the kit (install.sh) or the config-sync plugin:
#   setup.sh           asks for your private config repo (or creates one with gh), clones it to
#                      ~/.claude-sync, puts the sync engine in it on the first computer, runs its install
#   setup.sh refresh   at session start (plugin): brings the engine in ~/.claude-sync up to this
#                      version of the kit, unless its files were changed there by hand
# kit-engine.json in the sync repo records the engine version and files the kit put there; a repo
# without it keeps its own engine and is never touched.
set -eu
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$HERE/../hooks/lib"
. "$LIB/jq.sh"
. "$LIB/ask.sh"
. "$LIB/kit.sh"
SYNC="$HOME/.claude-sync"
ENGINE=".gitattributes .gitignore README.md install.ps1 install.sh inventory.sh jq.sh json-merge.sh crypt-merge.sh sync.sh"
MANIFEST="$SYNC/kit-engine.json"

version() { jq -r '.plugins[] | select(.name == "config-sync") | .version // empty' "$HERE/../.claude-plugin/marketplace.json" 2> /dev/null; }

# newer A B: succeeds when version A is above version B.
newer() {
  awk -v a="$1" -v b="$2" 'BEGIN { n = split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= n || i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
    exit 1 }'
}

# .gitattributes ends with the list of encrypted folders (sync.sh crypt), kept across engine
# versions and left out of the engine's hash.
CRYPT_MARK='# encrypted folders (sync.sh crypt): everything below is kept by sync.sh'

hashes() {
  local f
  for f in $ENGINE; do
    [ -f "$1/$f" ] || continue
    if [ "$f" = .gitattributes ]; then
      printf '%s\t%s\n' "$f" "$(awk -v m="$CRYPT_MARK" '$0 == m { exit } { print }' "$1/$f" | git hash-object --stdin)"
    else
      printf '%s\t%s\n' "$f" "$(git hash-object "$1/$f")"
    fi
  done
}

put_engine() {
  local f crypt=""
  [ -f "$SYNC/.gitattributes" ] && crypt=$(awk -v m="$CRYPT_MARK" '$0 == m { on = 1; next } on' "$SYNC/.gitattributes")
  for f in $ENGINE; do cp "$HERE/$f" "$SYNC/$f"; done
  [ -z "$crypt" ] || printf '%s\n' "$crypt" >> "$SYNC/.gitattributes"
  chmod +x "$SYNC/install.sh" "$SYNC/sync.sh" "$SYNC/inventory.sh"
  hashes "$SYNC" | jq -R -s --arg v "$1" '{version: $v, files: (split("\n") | map(select(. != "") | split("\t") | {(.[0]): .[1]}) | add)}' > "$MANIFEST"
}

refresh() {
  local have want changed=""
  [ -f "$MANIFEST" ] || return 0
  have=$(jq -r '.version // "0"' "$MANIFEST")
  want=$(version)
  [ -n "$want" ] && newer "$want" "$have" || return 0
  while IFS=$'\t' read -r f sha; do
    [ "$(jq -r --arg f "$f" '.files[$f] // empty' "$MANIFEST")" = "$sha" ] || changed="$changed $f"
  done <<< "$(hashes "$SYNC")"
  if [ -n "$changed" ]; then
    [ "$(cat "$SYNC/.state/kit-engine-offered" 2> /dev/null)" = "$want" ] && return 0
    mkdir -p "$SYNC/.state" && echo "$want" > "$SYNC/.state/kit-engine-offered"
    echo "claude-code-kit: version $want of the sync engine is out, but these files of ~/.claude-sync were changed by hand:$changed. Tell the user; on their yes, run: bash \"$(kit_path "$HERE/setup.sh")\" refresh --force"
    return 0
  fi
  put_engine "$want"
  echo "claude-code-kit: the sync engine in ~/.claude-sync is now version $want; the next sync shares it with the user's other computers."
}

if [ "${1:-}" = refresh ]; then
  if [ "${2:-}" = --force ] && [ -d "$SYNC/.git" ]; then
    put_engine "$(version)"
    echo "Sync engine updated to $(version)."
  else
    refresh
  fi
  exit 0
fi

if [ -d "$SYNC/.git" ]; then
  echo "The config sync is already set up here ($SYNC). Run its install again with: bash $SYNC/install.sh"
  kit_setup_mark config-sync done
  exit 0
fi
if [ -e "$SYNC" ]; then
  echo "~/.claude-sync exists but is not a git repo: move it away, then run this again."
  exit 0
fi
kit_has git jq || exit 0

echo "The config sync keeps your CLAUDE.md, memory, skills, plugins and settings the same on all your computers,"
echo "MCP secrets replaced by __SECRET__, through an empty private git repo of your own (GitHub, GitLab, Azure"
echo "DevOps, any host). On your next computer, give the same repo: what the first one saved is installed there."
echo "Details: $(kit_path "$HERE/README.md")"
url=$(reply config-sync.repo "Its clone URL (blank: create one on GitHub with gh, or set it up later):")
if [ -z "$url" ]; then
  if ! command -v gh > /dev/null 2>&1 || ! gh auth status > /dev/null 2>&1; then
    echo "  Skipped: creating one needs gh signed in (https://cli.github.com, then gh auth login). Or create an"
    echo "  empty private repo on any host and run this again with its URL."
    exit 0
  fi
  name=$(reply config-sync.name "Name of the new private repo:" claude-config)
  if ! ask config-sync.create "Create the private repo $name on your GitHub account?"; then
    echo "  Nothing set up. Run this again with the URL of a repo you made, or to create one."
    exit 0
  fi
  gh repo create "$name" --private --description "Claude Code config, synced between my computers"
  url=$(gh repo view "$name" --json url -q .url)
fi

if ! git clone -q "$url" "$SYNC"; then
  rm -rf "$SYNC"
  echo "Couldn't clone $url: check the URL and that you can read it, then run this again."
  exit 0
fi
if [ ! -f "$SYNC/sync.sh" ]; then
  echo "First computer: putting the sync engine in the repo."
  put_engine "$(version)"
fi
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) machine=windows ;; Darwin) machine=mac ;; *) machine=linux ;; esac
machine=$(reply config-sync.machine "A name for this computer in the sync (e.g. work-pc, home-mac):" "$machine")
dev=$(reply config-sync.dev "Folder that holds your git repos:" "${CLAUDE_DEV_ROOT:-~/dev}")
bash "$SYNC/install.sh" "$machine" "$dev" || {
  echo "The sync's install stopped; run it again with: bash ~/.claude-sync/install.sh"
  exit 0
}
kit_setup_mark config-sync done

# Encrypted folders: offered once on the first computer; a later computer with the repo already
# encrypted only needs the key.
crypt_folders=$(awk -v m="$CRYPT_MARK" '$0 == m { on = 1; next } on && $2 == "filter=git-crypt" { sub(/\/\*\*$/, "", $1); print $1 }' "$SYNC/.gitattributes" 2> /dev/null | tr '\n' ' ')
if [ -n "$crypt_folders" ]; then
  if [ ! -f "$SYNC/.git/git-crypt/keys/default" ]; then
    echo "The repo encrypts these folders with git-crypt: $crypt_folders(they stay locked here until you give the key)."
    key=$(reply config-sync.key "Path of the key file exported from your other computer (blank: later, with sync.sh crypt unlock <file>):" "")
    if [ -n "$key" ]; then
      if [ -f "$key" ]; then bash "$SYNC/sync.sh" crypt unlock "$key"; else echo "  $key is not a file; later: bash ~/.claude-sync/sync.sh crypt unlock <key file>"; fi
    fi
  fi
elif command -v git-crypt > /dev/null 2>&1; then
  if ask config-sync.encrypt "Encrypt your personal folders in the repo with git-crypt (memory and knowledge notes; the key stays off the repo, you carry it to each computer)?"; then
    bash "$SYNC/sync.sh" crypt on memory memory-repos memory-folders knowledge
  fi
else
  echo "  To encrypt the personal folders of the repo (memory, knowledge) with git-crypt, install it and run:"
  echo "  bash ~/.claude-sync/sync.sh crypt on memory memory-repos memory-folders knowledge"
fi
