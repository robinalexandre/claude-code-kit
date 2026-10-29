# Sourced by the parts that look for another part or record their setup, whichever way the kit was
# installed: copied into ~/.claude by install.sh, or as plugins from the kit's marketplace.
# Needs jq (hooks/lib/jq.sh).

# The marketplace's name, from the marketplace.json beside this file (a company's mirror of the kit
# serves it under its own name); read without jq, since every hook start sources this file. The
# marketplace's own name is the first "name" in the file. A copy in ~/.claude has none beside it.
KIT_MARKETPLACE=claude-code-kit
kit_market_file="${BASH_SOURCE[0]%/*}/../../.claude-plugin/marketplace.json"
if [ -f "$kit_market_file" ]; then
  while IFS= read -r kit_line; do
    case "$kit_line" in *'"name": "'*)
      kit_line=${kit_line#*\"name\": \"}
      KIT_MARKETPLACE=${kit_line%%\"*}
      break
      ;;
    esac
  done < "$kit_market_file"
fi
unset kit_market_file kit_line

# kit_plugin_root PART: the folder Claude Code installed PART's plugin in; nothing when it isn't one.
kit_plugin_root() {
  local list="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" root
  [ -f "$list" ] || return 1
  root=$(jq -r --arg id "$1@$KIT_MARKETPLACE" '(.plugins[$id] // []) | (map(select(.scope == "user")) + .)[0].installPath // empty' "$list" 2> /dev/null)
  [ -n "$root" ] || return 1
  if command -v cygpath > /dev/null 2>&1; then root=$(cygpath -u "$root"); fi
  [ -d "$root" ] && printf '%s' "$root"
}

# kit_find PART PATH: where PATH (relative to the kit, e.g. skills/reminders/reminders.sh) of an
# installed PART is: under ~/.claude for a copy, else in PART's plugin. Fails when PART isn't installed.
kit_find() {
  local root
  if [ -e "$HOME/.claude/$2" ]; then
    printf '%s' "$HOME/.claude/$2"
  elif root=$(kit_plugin_root "$1") && [ -e "$root/$2" ]; then
    printf '%s' "$root/$2"
  else
    return 1
  fi
}

# kit_morning_scripts: the morning.sh of each installed skill, copied or as a plugin, one per line.
kit_morning_scripts() {
  local f name root
  for f in "$HOME"/.claude/skills/*/morning.sh; do [ -f "$f" ] && printf '%s\n' "$f"; done
  for name in $(jq -r --arg m "@$KIT_MARKETPLACE" '.plugins // {} | keys[] | select(endswith($m)) | sub("@.*"; "")' \
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" 2> /dev/null); do
    [ -f "$HOME/.claude/skills/$name/morning.sh" ] && continue
    root=$(kit_plugin_root "$name") && [ -f "$root/skills/$name/morning.sh" ] && printf '%s\n' "$root/skills/$name/morning.sh"
  done
  return 0
}

# What dnd is for, said where it is recommended: beside a pane it quiets, when it is not installed.
KIT_DND_WHY='dnd quiets the history, PR & CI and reminders-handoffs panes when you need it: a profile hides a pane, or keeps only some repos and reminder groups (at the office, only the work repos; in a repo, only its own). Turn one on by hand ("in a meeting for 1h", for one session or the whole computer), or let it turn on by itself on a Wi-Fi network, on days and hours (week-ends, evenings) or in a folder.'

# A part's setup state on this computer: done, declined or offered; nothing before its first offer.
kit_setup_state() { cat "$HOME/.claude/kit-setup/$1" 2> /dev/null || true; }
kit_setup_mark() { mkdir -p "$HOME/.claude/kit-setup" && printf '%s\n' "$2" > "$HOME/.claude/kit-setup/$1"; }
