#!/bin/bash
# Sets up session-registry: sources claude-resume-here.zsh from ~/.zshrc, so a new terminal tab offers
# to resume the session left open in its folder. As a plugin, KIT_HOME is the plugin's data folder,
# where each session start keeps the file current.
set -eu
LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)
. "$LIB/ask.sh"
. "$LIB/kit.sh"
KIT_HOME=${KIT_HOME:-$(cd "$LIB/../.." && pwd)}
file="$KIT_HOME/hooks/claude-resume-here.zsh"
case "$file" in "$HOME"/*) shown="~/${file#"$HOME"/}" ;; *) shown=$file ;; esac

if grep -qsF "$shown" "$HOME/.zshrc" || grep -qsF "$file" "$HOME/.zshrc"; then
  echo "  ~/.zshrc already sources it."
elif ask zshrc "Source claude-resume-here.zsh from ~/.zshrc, so a new terminal tab offers to resume the session left open there?" y; then
  printf '\n[ -f %s ] && source %s\n' "$shown" "$shown" >> "$HOME/.zshrc"
  echo "  Added to ~/.zshrc; new terminal tabs pick it up."
else
  kit_setup_mark session-registry declined
  exit 0
fi
kit_setup_mark session-registry done
