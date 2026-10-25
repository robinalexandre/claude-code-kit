#!/bin/bash
# Sets up kb: its Python environment, the folder of your notes, the semantic search and the morning
# curation. Run it again any time: bash ~/.claude/skills/kb/setup.sh
#   setup.sh upgrade [VERSION]   installs the package again in the existing environment, no questions
set -eu
LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib" && pwd)
. "$LIB/jq.sh"
. "$LIB/ask.sh"
. "$LIB/kit.sh"
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE="$HOME/.claude/kb"
VENV="$STATE/venv"
ENVFILE="$STATE/kb.env"

python_bin() {
  local candidate
  for candidate in python3.13 python3.12 python3 python; do
    command -v "$candidate" > /dev/null 2>&1 || continue
    "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 12))' 2> /dev/null && { printf '%s' "$candidate"; return; }
  done
  return 1
}
venv_bin() {
  if [ -x "$VENV/bin/$1" ]; then printf '%s' "$VENV/bin/$1"; else printf '%s' "$VENV/Scripts/$1.exe"; fi
}
setting() { sed -n "s/^$1=//p" "$ENVFILE" 2> /dev/null | head -1 | tr -d '\r"'; }
plugin_version() {
  jq -r '.plugins[] | select(.name == "kb") | .version // empty' "$SK/../../.claude-plugin/marketplace.json" 2> /dev/null || true
}

# install EXTRA: the package into the virtualenv, made first when missing.
install() {
  local py
  if [ ! -f "$VENV/pyvenv.cfg" ]; then
    py=$(python_bin) || { echo "  kb needs Python 3.12 or newer: install it, then run this setup again."; return 1; }
    mkdir -p "$STATE"
    "$py" -m venv "$VENV"
  fi
  # python -m pip: on Windows, pip.exe cannot replace itself and refuses to run an upgrade; and
  # a Windows python wants D:/… paths, not Git Bash's /d/… (kit_path).
  "$(venv_bin python)" -m pip install -q --upgrade pip
  "$(venv_bin python)" -m pip install -q "$(kit_path "$SK/package")$1"
  printf '%s\n' "${2:-$(plugin_version)}" > "$STATE/version"
}

if [ "${1:-}" = upgrade ]; then
  extra=""
  [ "$(setting KB_EMBED)" = fastembed ] && extra="[embed]"
  install "$extra" "${2:-}"
  exit 0
fi

echo "kb keeps your knowledge as Markdown notes, indexed for text, semantic and link search, and recalls"
echo "them at session start and on each prompt. With daily-sync, it also curates each day's Claude Code"
echo "transcripts into notes every morning."
default="$HOME/.claude/knowledge"
[ -d "$HOME/.claude-sync/.git" ] && default="$HOME/.claude-sync/knowledge"
notes=$(reply kb.notes "Folder of your notes (in your config sync, every computer gets them):" "$(setting KB_NOTES)")
notes=${notes:-$default}
embed=none
extra=""
if ask kb.embed "Semantic search in any language (downloads a 500 MB model once, local only)?" y; then
  embed=fastembed
  extra="[embed]"
fi
curate=off
model=$(setting KB_CURATE_MODEL)
folders=$(setting KB_SYNC_FOLDERS)
if ask kb.curate "Curate your Claude Code transcripts into notes every morning (daily-sync, your Claude login)?" y; then
  curate=on
  model=$(reply kb.curateModel "Claude model for the curation (sonnet, haiku, opus):" "${model:-sonnet}")
  if [ -d "$HOME/.claude-sync/.git" ]; then
    echo "  The curation also reads what changed in your config sync: reminders, handoffs, notes, memory,"
    echo "  CLAUDE.md and skills, and every repo's CLAUDE.md and AGENTS.md."
    folders=$(reply kb.syncFolders "Other folders of the config sync to read, such as an assistant's own (space-separated, empty for none):" "$folders")
  fi
fi

echo "  Installing kb in ${VENV}…"
install "$extra"
mkdir -p "$notes"
{
  printf 'KB_NOTES=%s\n' "$notes"
  printf 'KB_EMBED=%s\n' "$embed"
  printf 'KB_CURATE=%s\n' "$curate"
  [ -n "$model" ] && printf 'KB_CURATE_MODEL=%s\n' "$model"
  if [ -n "$folders" ]; then printf 'KB_SYNC_FOLDERS="%s"\n' "$folders"; fi
} > "$ENVFILE"
echo "  Indexing ${notes}…"
KB_NOTES=$notes KB_EMBED=$embed "$(venv_bin kb)" index || echo "  The first index failed; the next session start tries again."
echo "  Saved in $ENVFILE. Ask Claude \"what do you know about…\" or \"note this for good\"."
kit_setup_mark kb done
