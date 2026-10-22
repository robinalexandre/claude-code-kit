#!/bin/bash
# Installs the parts of this kit you pick into ~/.claude, then sets up each one.
#   ./install.sh            explains each part (why, what, when, who) and asks
#   ./install.sh --all      installs every part offered on this computer
#   ./install.sh PART...    installs the named parts
#   ./install.sh --list     lists the parts
# On Windows, from PowerShell: .\install.ps1 (it runs this script in Git Bash).
# Parts a picked one needs are installed with it. Files it replaces and the previous settings.json
# are saved in ~/.claude/backups/before-kit-<date>/. Running it again is safe.
set -eu
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLAUDE="$HOME/.claude"
SETTINGS="$CLAUDE/settings.json"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    os=windows
    home=$(cygpath -m "$HOME")
    sep=';'
    ;;
  Darwin) os=darwin home=$HOME sep=':' ;;
  *) os=linux home=$HOME sep=':' ;;
esac

command -v jq > /dev/null || {
  echo "Install jq first (macOS: brew install jq, Windows: winget install jqlang.jq, Linux: your package manager)." >&2
  exit 1
}
. "$KIT/hooks/lib/jq.sh"
. "$KIT/hooks/lib/ask.sh"

source_of() {
  case "$2" in
    skill) echo "skills/$1" ;;
    mod) echo "mods/$1" ;;
    rules) echo "rules/$1.md" ;;
    statusline) echo statusline-command.sh ;;
    hook) if [ "$1" = wave-check-hook ]; then echo hooks/wave-check.sh; else echo "hooks/$1.sh"; fi ;;
  esac
}

# name, kind, group, os, tools, needs, setup, sync: one line per part this copy of the kit carries.
PARTS=$(jq -r '.parts[] | [.name, .kind, .group, (.os // [] | join(",")), (.tools // [] | join(",")),
  (.needs // [] | join(",")), (.setup // "-"), (.sync // false | tostring)] | @tsv' "$KIT/parts.json" |
  while IFS=$'\t' read -r name kind rest; do
    if [ -e "$KIT/$(source_of "$name" "$kind")" ]; then printf '%s\t%s\t%s\n' "$name" "$kind" "$rest"; fi
  done)

field() { awk -F'\t' -v p="$1" -v f="$2" '$1 == p { print $f }' <<< "$PARTS"; }
about() { jq -r --arg p "$1" --arg k "$2" '.parts[] | select(.name == $p) | .[$k] // ""' "$KIT/parts.json"; }
offered() {
  local o
  o=$(field "$1" 4)
  [ -z "$o" ] || [[ ",$o," == *",$os,"* ]]
}

if [ "${1:-}" = --list ]; then
  while IFS=$'\t' read -r name kind group _; do
    printf '%-19s %-10s %-9s %s\n' "$name" "$kind" "$group" "$(about "$name" what)"
  done <<< "$PARTS"
  exit 0
fi

describe() {
  local p=$1 needs tools t missing=""
  printf '\n  %s (%s): %s\n' "$p" "$(field "$p" 2)" "$(about "$p" what)"
  printf '    Why:  %s\n    When: %s\n    Who:  %s\n' "$(about "$p" why)" "$(about "$p" when)" "$(about "$p" who)"
  needs=$(field "$p" 6)
  [ -n "$needs" ] && printf '    Needs %s, installed with it.\n' "${needs//,/, }"
  tools=$(field "$p" 5)
  for t in ${tools//,/ }; do command -v "$t" > /dev/null 2>&1 || missing="$missing $t"; done
  [ -n "$missing" ] && printf '    Not found on this computer:%s (install it before using %s).\n' "$missing" "$p"
  return 0
}

picked=""
if [ "${1:-}" = --all ]; then
  picked=$(while IFS=$'\t' read -r name _; do offered "$name" && echo "$name"; done <<< "$PARTS")
elif [ $# -gt 0 ]; then
  for p in "$@"; do
    [ -n "$(field "$p" 1)" ] || {
      echo "Unknown part: $p (see ./install.sh --list)" >&2
      exit 1
    }
    picked="$picked$p"$'\n'
  done
else
  echo "The kit's parts, by group. For each: what it does, why you'd want it, when it acts and who it's for."
  for group in $(jq -r '.groups[].id' "$KIT/parts.json"); do
    names=$(awk -F'\t' -v g="$group" '$3 == g { print $1 }' <<< "$PARTS")
    here="" elsewhere=""
    for p in $names; do if offered "$p"; then here="$here $p"; else elsewhere="$elsewhere $p"; fi; done
    [ -n "$here" ] || continue
    printf '\n== %s:%s\n' "$(jq -r --arg g "$group" '.groups[] | select(.id == $g) | .title' "$KIT/parts.json")" "$here"
    [ -n "$elsewhere" ] && printf '   (not offered on %s:%s)\n' "$os" "$elsewhere"
    ask "group.$group" "Go through this group?" y || continue
    for p in $here; do
      describe "$p"
      ask "part.$p" "  Install $p?" && picked="$picked$p"$'\n'
    done
  done
fi
picked=$(grep . <<< "$picked" || true)
[ -n "$picked" ] || {
  echo "Nothing picked."
  exit 0
}

# What a picked part needs is picked too, until nothing changes.
while :; do
  added=""
  for p in $picked; do
    for n in $(field "$p" 6 | tr ',' ' '); do
      grep -qx "$n" <<< "$picked" || { picked="$picked"$'\n'"$n"; added="$added $n"; echo "Adding $n: $p needs it."; }
    done
  done
  [ -z "$added" ] && break
done
picked=$(while IFS=$'\t' read -r name _; do grep -qx "$name" <<< "$picked" && echo "$name"; done <<< "$PARTS")

BACKUP="$CLAUDE/backups/before-kit-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$CLAUDE"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
mkdir -p "$BACKUP"
cp -p "$SETTINGS" "$BACKUP/settings.json"

# put SRC DEST: copies SRC (file or folder) to ~/.claude/DEST, saving what it replaces.
put() {
  local dest="$CLAUDE/$2"
  if [ -e "$dest" ]; then
    mkdir -p "$(dirname "$BACKUP/$2")"
    cp -Rp "$dest" "$BACKUP/$2"
    rm -rf "$dest"
  fi
  mkdir -p "$(dirname "$dest")"
  cp -R "$KIT/$1" "$dest"
}

fragments=()
mods=()
marker_wanted=""
zsh_resume=""
echo
for p in $picked; do
  case "$(field "$p" 2)" in
    skill)
      put "skills/$p" "skills/$p"
      if [ -f "$KIT/settings/$p.json" ]; then fragments+=("$KIT/settings/$p.json"); fi
      ;;
    mod)
      put "mods/$p" "mods/$p"
      mods+=("$home/.claude/mods/$p")
      ;;
    hook)
      case "$p" in
        wave-check-hook) put hooks/wave-check.sh hooks/wave-check.sh && fragments+=("$KIT/settings/wave-check.json") ;;
        session-registry)
          put hooks/session-registry.sh hooks/session-registry.sh
          put hooks/claude-resume-here.zsh hooks/claude-resume-here.zsh
          fragments+=("$KIT/settings/session-registry.json")
          zsh_resume=1
          ;;
        *) put "hooks/$p.sh" "hooks/$p.sh" && fragments+=("$KIT/settings/$p.json") ;;
      esac
      setup=$(field "$p" 7)
      if [ "$setup" != - ]; then put "$setup" "$setup"; fi
      ;;
    statusline) put statusline-command.sh statusline-command.sh && fragments+=("$KIT/settings/statusline.json") ;;
    rules)
      heading=$(grep -m1 '^## ' "$KIT/rules/$p.md")
      if grep -qxF -- "$heading" "$CLAUDE/CLAUDE.md" 2> /dev/null; then
        echo "~/.claude/CLAUDE.md already has \"$heading\"; left as is."
      else
        [ -f "$CLAUDE/CLAUDE.md" ] && cp -p "$CLAUDE/CLAUDE.md" "$BACKUP/CLAUDE.md"
        language=$(reply language "Which language should Claude talk to you in (e.g. English, Français, Español)?" English)
        awk -v l="$language" '{ gsub(/__LANGUAGE__/, l) } 1' "$KIT/rules/$p.md" >> "$CLAUDE/CLAUDE.md"
      fi
      ;;
  esac
  case "$p" in wave-check | wave-check-hook) marker_wanted=1 ;; esac
  echo "Installed $p"
done
# The setup scripts and every hook read these.
put hooks/lib hooks/lib
chmod +x "$CLAUDE"/hooks/*.sh "$CLAUDE"/hooks/setup/*.sh "$CLAUDE"/skills/*/*.sh 2> /dev/null || true

# The wave-check parts check replies against an emoji the user picks once.
marker=$(jq -r '.env.CLAUDE_REPLY_MARKER // empty' "$SETTINGS")
if [ -n "$marker_wanted" ] && [ -z "$marker" ]; then
  marker=$(reply marker "Which emoji should start every reply from Claude (e.g. 🌊, 🦊, ✅)?")
  marker=${marker//[[:space:]]/}
  if [ -z "$marker" ]; then
    echo "No emoji given: wave-check stays idle until you set CLAUDE_REPLY_MARKER in $SETTINGS (env)."
  elif ask marker.rule "Add \"Start every message with $marker\" to ~/.claude/CLAUDE.md? wave-check relies on that rule." y; then
    [ -f "$CLAUDE/CLAUDE.md" ] && [ ! -f "$BACKUP/CLAUDE.md" ] && cp -p "$CLAUDE/CLAUDE.md" "$BACKUP/CLAUDE.md"
    printf '\n- **Start every message with %s.** That includes one-line replies, questions back\n  to me, error reports, and the message after a long run of tool calls.\n' "$marker" >> "$CLAUDE/CLAUDE.md"
  fi
fi

# A file rather than <(...): native jq.exe on Windows can't open /proc/self/fd paths.
cat /dev/null ${fragments[@]+"${fragments[@]}"} > "$SETTINGS.fragments"
jq --arg h "$home" --arg sep "$sep" --arg marker "$marker" --argjson mods "$(jq -n '$ARGS.positional' --args ${mods[@]+"${mods[@]}"})" \
  --slurpfile frags "$SETTINGS.fragments" '
  def merge($o):
    if type == "object" and ($o | type) == "object" then
      reduce ($o | keys_unsorted[]) as $k (.; .[$k] = (if has($k) then .[$k] | merge($o[$k]) else $o[$k] end))
    elif type == "array" and ($o | type) == "array" then . + ($o - .)
    else $o end;
  def render: walk(if type == "string" then split("__HOME__") | join($h) else . end);
  def uniq: reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end);
  reduce $frags[] as $f (.; merge($f | render))
  | if ($mods | length) > 0 then
      .env.CLAUDE_CODE_PLUGIN_DIRS = ((.env.CLAUDE_CODE_PLUGIN_DIRS // "" | split($sep) | map(select(. != ""))) + $mods | uniq | join($sep))
    else . end
  | if $marker != "" then .env.CLAUDE_REPLY_MARKER = $marker else . end' \
  "$BACKUP/settings.json" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
rm -f "$SETTINGS.fragments"

if [ -n "$zsh_resume" ] && ! grep -qs claude-resume-here.zsh "$HOME/.zshrc"; then
  if ask zshrc "Source claude-resume-here.zsh from ~/.zshrc, so a new terminal tab offers to resume the session left open there?" y; then
    printf '\n[ -f ~/.claude/hooks/claude-resume-here.zsh ] && source ~/.claude/hooks/claude-resume-here.zsh\n' >> "$HOME/.zshrc"
  fi
fi

# Each part's own questions, once its files and settings are in place. Run one again any time:
# bash ~/.claude/<its setup>.
for p in $picked; do
  setup=$(field "$p" 7)
  [ "$setup" != - ] || continue
  printf '\n== Setting up %s\n' "$p"
  bash "$CLAUDE/$setup" || echo "Setting up $p stopped; run it again with: bash ~/.claude/$setup"
done

sync_parts=$(for p in $picked; do [ "$(field "$p" 8)" = true ] && printf ' %s' "$p"; done || true)
if [ -n "$sync_parts" ] && [ ! -d "$HOME/.claude-sync/.git" ]; then
  printf '\n%s need the sync engine, not set up on this computer yet: see %s/sync/README.md\n' "${sync_parts# }" "$KIT"
  echo "(a private GitHub repo of your own cloned to ~/.claude-sync, then its install.sh, or install.ps1 on Windows)."
fi

echo
echo "Done. Previous files are in $BACKUP. Start a new Claude Code session to load them."
