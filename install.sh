#!/bin/bash
# Installs the parts of this kit you pick into ~/.claude, then sets up each one.
#   ./install.sh            a checklist of the parts: arrows to move, Enter or Space to pick, → for
#                           what each does (why, what, when, who), then Install
#   ./install.sh --plain    the same as plain questions, one part at a time
#   ./install.sh --all      installs every part offered on this computer
#   ./install.sh PART...    installs the named parts
#   ./install.sh --list     lists the parts
#   ./install.sh --update [PART...]   pulls this clone, installs again the parts it changed, and
#                           the named parts new in it
# On Windows, from PowerShell: .\install.ps1 (it runs this script in Git Bash).
# Parts a picked one needs are installed with it. Files it replaces and the previous settings.json
# are saved in ~/.claude/backups/before-kit-<date>/. Running it again is safe.
# What it installed, and from which commit, goes to ~/.claude/kit-install.json: kit-update-check.sh
# reads it at session start to tell when this clone has changes for them.
set -eu
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLAUDE="$HOME/.claude"
SETTINGS="$CLAUDE/settings.json"
RECORD="$CLAUDE/kit-install.json"

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
    sync) echo sync/setup.sh ;;
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
ABOUT=$(jq -r '.parts[] | [.name, .what, .why, .when, .who] | @tsv' "$KIT/parts.json")
about() {
  awk -F'\t' -v p="$1" -v k="$2" 'BEGIN { split("what why when who", n, " "); for (i in n) at[n[i]] = i + 1 }
    $1 == p { print $at[k] }' <<< "$ABOUT"
}
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

# pick_parts: a checklist on the terminal, by group, driven by the keyboard; prints the picked
# parts, one per line. Nothing when the user quits.
pick_parts() {
  local -a row=() kind=() what=() details=()
  local group p i j names rows cols sel="|" open="|" cur=1 top=0 key rest count
  read -r rows cols < <(stty size < /dev/tty 2> /dev/null || echo "24 80")
  [ "${rows:-0}" -gt 5 ] || rows=24
  [ "${cols:-0}" -gt 20 ] || cols=80
  for group in $(jq -r '.groups[].id' "$KIT/parts.json"); do
    names=$(awk -F'\t' -v g="$group" '$3 == g { print $1 }' <<< "$PARTS")
    [ -n "$names" ] || continue
    row+=("$group") kind+=(g) details+=("")
    what+=("$(jq -r --arg g "$group" '.groups[] | select(.id == $g) | .title' "$KIT/parts.json")")
    for p in $names; do
      row+=("$p") kind+=(p) what+=("$(about "$p" what)")
      details+=("$(describe "$p" | tail -n +3 | sed 's/^ *//' | fold -s -w $((cols - 10)))")
    done
  done
  row+=(install) kind+=(i) what+=("") details+=("")

  local offer="|"
  for p in $(cut -f1 <<< "$PARTS"); do if offered "$p"; then offer="$offer$p|"; fi; done
  is_offered() { [[ "$offer" == *"|$1|"* ]]; }
  is_on() { [[ "$sel" == *"|$1|"* ]]; }
  turn_on() {
    local n
    offered "$1" || return 0
    is_on "$1" || sel="$sel$1|"
    for n in $(field "$1" 6 | tr ',' ' '); do turn_on "$n"; done
  }
  turn_off() { sel=${sel//|$1|/|}; }
  toggle_group() {
    local k all=1
    for ((k = $1 + 1; k < ${#row[@]}; k++)); do [ "${kind[k]}" = p ] || break; offered "${row[k]}" && ! is_on "${row[k]}" && all=0; done
    for ((k = $1 + 1; k < ${#row[@]}; k++)); do [ "${kind[k]}" = p ] || break; if [ "$all" = 1 ]; then turn_off "${row[k]}"; else turn_on "${row[k]}"; fi; done
  }

  draw() {
    local -a out=()
    local line mark first=0 last name height
    local head
    printf -v head '\033[1mPick what to install\033[0m  ↑↓ move · Enter/Space pick · → or Tab details · a all · q quit'
    for ((i = 0; i < ${#row[@]}; i++)); do
      if [ "${kind[i]}" = g ] && [ "$i" -gt 0 ]; then out+=(""); fi
      [ "$i" = "$cur" ] && first=${#out[@]}
      case "${kind[i]}" in
        g)
          count=0
          for ((j = i + 1; j < ${#row[@]}; j++)); do
            [ "${kind[j]}" = p ] || break
            if is_on "${row[j]}"; then count=$((count + 1)); fi
          done
          line="${what[i]}${count:+ ($count picked)}"
          [ "$count" = 0 ] && line=${what[i]}
          line=${line:0:$((cols - 2))}
          if [ "$i" = "$cur" ]; then printf -v line '\033[7;1m%s\033[0m' "$line"; out+=("$line"); else printf -v line '\033[1m%s\033[0m' "$line"; out+=("$line"); fi
          ;;
        p)
          name=${row[i]}
          if ! is_offered "$name"; then mark='[-]'; elif is_on "$name"; then mark='[x]'; else mark='[ ]'; fi
          if [[ "$open" == *"|$name|"* ]]; then line="▾"; else line="▸"; fi
          line="  $mark $line $name: ${what[i]}"
          [ "${#line}" -ge "$cols" ] && line="${line:0:$((cols - 2))}…"
          if [ "$i" = "$cur" ]; then
            printf -v line '\033[7m%s\033[0m' "$line"; out+=("$line")
          elif ! is_offered "$name"; then
            printf -v line '\033[2m%s (not on %s)\033[0m' "${line:0:$((cols - 14))}" "$os"; out+=("$line")
          elif is_on "$name"; then
            printf -v line '\033[32m%s\033[0m' "$line"; out+=("$line")
          else
            out+=("$line")
          fi
          if [[ "$open" == *"|$name|"* ]]; then
            while IFS= read -r line; do printf -v line '\033[2m        %s\033[0m' "$line"; out+=("$line"); done <<< "${details[i]}"
          fi
          ;;
        i)
          count=0
          for ((j = 0; j < ${#row[@]}; j++)); do if [ "${kind[j]}" = p ] && is_on "${row[j]}"; then count=$((count + 1)); fi; done
          out+=("")
          [ "$i" = "$cur" ] && first=${#out[@]}
          line="  [ Install $count part$([ "$count" = 1 ] || echo s) ]"
          if [ "$i" = "$cur" ]; then printf -v line '\033[7;1m%s\033[0m' "$line"; out+=("$line"); else printf -v line '\033[1m%s\033[0m' "$line"; out+=("$line"); fi
          ;;
      esac
      [ "$i" = "$cur" ] && last=$((${#out[@]} - 1))
    done
    height=$((rows - 3))
    [ "$first" -lt "$top" ] && top=$first
    [ "$last" -ge $((top + height)) ] && top=$((last - height + 1))
    [ "$first" -lt "$top" ] && top=$first
    {
      printf '\033[H\033[2J%s\033[K\n\033[K\n' "$head"
      for ((j = top; j < top + height && j < ${#out[@]}; j++)); do printf '%s\033[K\n' "${out[j]}"; done
    } > /dev/tty
  }

  printf '\033[?1049h\033[?25l' > /dev/tty
  trap 'printf "\033[?25h\033[?1049l" > /dev/tty' EXIT
  trap 'exit 130' INT
  while :; do
    draw
    IFS= read -rsn1 key < /dev/tty || key=q
    if [ "$key" = $'\e' ]; then
      IFS= read -rsn2 -t 1 rest < /dev/tty || rest=""
      key="esc$rest"
    fi
    case "$key" in
      'esc[A' | k) [ "$cur" -gt 0 ] && cur=$((cur - 1)) ;;
      'esc[B' | j) [ "$cur" -lt $((${#row[@]} - 1)) ] && cur=$((cur + 1)) ;;
      'esc[C' | l | $'\t') [ "${kind[cur]}" = p ] && { [[ "$open" == *"|${row[cur]}|"* ]] && open=${open//|${row[cur]}|/|} || open="$open${row[cur]}|"; } ;;
      'esc[D' | h) [ "${kind[cur]}" = p ] && open=${open//|${row[cur]}|/|} ;;
      '' | ' ')
        case "${kind[cur]}" in
          p) if is_on "${row[cur]}"; then turn_off "${row[cur]}"; else turn_on "${row[cur]}"; fi ;;
          g) toggle_group "$cur" ;;
          i) break ;;
        esac
        ;;
      a) for ((j = 0; j < ${#row[@]}; j++)); do [ "${kind[j]}" = p ] && turn_on "${row[j]}"; done ;;
      q | esc) sel="|" && break ;;
    esac
  done
  printf '\033[?25h\033[?1049l' > /dev/tty
  trap - EXIT INT
  for ((j = 0; j < ${#row[@]}; j++)); do if [ "${kind[j]}" = p ] && is_on "${row[j]}"; then echo "${row[j]}"; fi; done
}

update=""
was_installed=""
if [ "${1:-}" = --update ]; then
  [ -f "$RECORD" ] || {
    echo "Nothing was installed on this computer with install.sh: nothing to update."
    exit 0
  }
  recorded=$(jq -r '.kit // empty' "$RECORD")
  [ "$recorded" = "$(kit_path "$KIT")" ] || {
    echo "This computer's parts come from another clone: run $recorded/install.sh --update instead." >&2
    exit 1
  }
  shift
  if [ "${1:-}" = --pulled ]; then
    shift
  else
    git -C "$KIT" pull --ff-only --quiet || {
      echo "Couldn't bring $KIT up to date (local changes, or it has diverged): pull it yourself, then run ./install.sh --update again." >&2
      exit 1
    }
    # The pull may have changed this very script, and bash reads a running script as it goes.
    exec bash "$KIT/install.sh" --update --pulled "$@"
  fi
  update=1
  was_installed=$(jq -r '.parts // {} | keys[]' "$RECORD")
fi

[ "${1:-}" = --plain ] && { KIT_INSTALL_PLAIN=1; shift; }
picked=""
if [ -n "$update" ]; then
  picked=$(bash "$KIT/hooks/kit-update-check.sh" changed HEAD | grep -vx kit-update-check || true)
  if [ -n "$picked" ]; then echo "Updating: $(echo $picked)"; else echo "No installed part changed."; fi
  # Parts new in the kit, named after --update.
  for p in "$@"; do
    [ -n "$(field "$p" 1)" ] || {
      echo "Unknown part: $p (see ./install.sh --list)" >&2
      exit 1
    }
    picked="$picked"$'\n'"$p"
  done
elif [ "${1:-}" = --all ]; then
  picked=$(while IFS=$'\t' read -r name _; do if offered "$name"; then echo "$name"; fi; done <<< "$PARTS")
elif [ $# -gt 0 ]; then
  for p in "$@"; do
    [ -n "$(field "$p" 1)" ] || {
      echo "Unknown part: $p (see ./install.sh --list)" >&2
      exit 1
    }
    picked="$picked$p"$'\n'
  done
elif [ -z "${KIT_INSTALL_ANSWERS:-}" ] && [ "${KIT_INSTALL_PLAIN:-}" != 1 ] && [ "${TERM:-dumb}" != dumb ] &&
  (: < /dev/tty) 2> /dev/null; then
  picked=$(pick_parts)
  [ -n "$picked" ] && echo "Picked: $(echo $picked)"
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
      if ask "part.$p" "  Install $p?"; then picked="$picked$p"$'\n'; fi
    done
  done
fi
picked=$(grep . <<< "$picked" || true)
[ -n "$picked" ] || [ -n "$update" ] || {
  echo "Nothing picked."
  exit 0
}

# What a picked part needs is picked too, until nothing changes. A part that keeps its data in the
# sync repo needs the sync engine.
while :; do
  added=""
  for p in $picked; do
    needs=$(field "$p" 6 | tr ',' ' ')
    if [ "$(field "$p" 8)" = true ] && [ -n "$(field config-sync 1)" ]; then needs="$needs config-sync"; fi
    for n in $needs; do
      grep -qx "$n" <<< "$picked" || { picked="$picked"$'\n'"$n"; added="$added $n"; echo "Adding $n: $p needs it."; }
    done
  done
  [ -z "$added" ] && break
done
picked=$(while IFS=$'\t' read -r name _; do if grep -qx "$name" <<< "$picked"; then echo "$name"; fi; done <<< "$PARTS")

# A part already installed as a plugin from the claude-code-kit marketplace stays a plugin: a copy too
# would run its hooks twice.
plugins=$(jq -r '.plugins // {} | keys[] | select(endswith("@claude-code-kit")) | sub("@.*"; "")' \
  "${CLAUDE_CONFIG_DIR:-$CLAUDE}/plugins/installed_plugins.json" 2> /dev/null || true)
for p in $plugins; do
  if grep -qx "$p" <<< "$picked"; then
    echo "Skipping $p: installed as a plugin (claude plugin uninstall $p@claude-code-kit to copy it instead)."
    picked=$(grep -vx "$p" <<< "$picked" || true)
  fi
done
[ -n "$picked" ] || [ -n "$update" ] || exit 0

BACKUP="$CLAUDE/backups/before-kit-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$CLAUDE"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
mkdir -p "$BACKUP"
cp -p "$SETTINGS" "$BACKUP/settings.json"

# The kit's files each part came from, "part<TAB>path" lines, for the record.
installed=""
note() { installed="$installed$current"$'\t'"$1"$'\n'; }

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
  note "$1"
}

# frag FILE: merges the kit's settings FILE into settings.json.
frag() {
  fragments+=("$KIT/$1")
  note "$1"
}

fragments=()
mods=()
marker_wanted=""
zsh_resume=""
sync_wanted=""
echo
for p in $picked; do
  current=$p
  case "$(field "$p" 2)" in
    sync)
      sync_wanted=1
      note sync
      continue
      ;;
    skill)
      put "skills/$p" "skills/$p"
      if [ -f "$KIT/settings/$p.json" ]; then frag "settings/$p.json"; fi
      ;;
    mod)
      put "mods/$p" "mods/$p"
      mods+=("$home/.claude/mods/$p")
      ;;
    hook)
      case "$p" in
        wave-check-hook) put hooks/wave-check.sh hooks/wave-check.sh && frag settings/wave-check.json ;;
        session-registry)
          put hooks/session-registry.sh hooks/session-registry.sh
          put hooks/claude-resume-here.zsh hooks/claude-resume-here.zsh
          frag settings/session-registry.json
          zsh_resume=1
          ;;
        *) put "hooks/$p.sh" "hooks/$p.sh" && frag "settings/$p.json" ;;
      esac
      setup=$(field "$p" 7)
      if [ "$setup" != - ]; then put "$setup" "$setup"; fi
      ;;
    statusline) put statusline-command.sh statusline-command.sh && frag settings/statusline.json ;;
    rules)
      note "rules/$p.md"
      heading=$(grep -m1 '^## ' "$KIT/rules/$p.md")
      if grep -qxF -- "$heading" "$CLAUDE/CLAUDE.md" 2> /dev/null; then
        echo "~/.claude/CLAUDE.md already has \"$heading\"; left as is."
        [ -n "$update" ] && echo "  It changed in the kit: compare it with $KIT/rules/$p.md."
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
# The setup scripts and every hook read these. The update check comes with every install.
current=kit-update-check
put hooks/lib hooks/lib
put hooks/kit-update-check.sh hooks/kit-update-check.sh
frag settings/kit-update-check.json
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

# A kit that isn't a git clone can't be checked for updates: no record.
if commit=$(git -C "$KIT" rev-parse -q --verify HEAD 2> /dev/null); then
  if [ -f "$RECORD" ]; then cp -p "$RECORD" "$BACKUP/kit-install.json"; else echo '{}' > "$RECORD"; fi
  jq --indent 2 --arg kit "$(kit_path "$KIT")" --arg commit "$commit" --arg installed "$installed" \
    --arg offered "$(cut -f1 <<< "$PARTS")" '
    (if .kit == $kit then .parts // {} else {} end) as $old
    | .known = ((if .kit == $kit then .known // [] else [] end) + ($offered | split("\n") | map(select(. != ""))) | unique)
    | .kit = $kit
    | .parts = $old + ($installed | split("\n") | map(select(. != "") | split("\t")) | group_by(.[0])
        | map({key: .[0][0], value: {commit: $commit, files: (map(.[1]) | unique)}}) | from_entries)' \
    "$RECORD" > "$RECORD.tmp" && mv "$RECORD.tmp" "$RECORD"
  rm -f "$CLAUDE/kit-update/report"
fi

if [ -n "$zsh_resume" ] && ! grep -qs claude-resume-here.zsh "$HOME/.zshrc"; then
  if ask zshrc "Source claude-resume-here.zsh from ~/.zshrc, so a new terminal tab offers to resume the session left open there?" y; then
    printf '\n[ -f ~/.claude/hooks/claude-resume-here.zsh ] && source ~/.claude/hooks/claude-resume-here.zsh\n' >> "$HOME/.zshrc"
  fi
fi

# Before the parts' own setups: some keep their data in the sync repo once it is there. The sync is
# set up from the kit itself (sync/setup.sh, shared with the config-sync plugin): it goes to
# ~/.claude-sync, not ~/.claude.
if [ -n "$sync_wanted" ] && [ -n "$update" ] && grep -qx config-sync <<< "$was_installed"; then
  bash "$KIT/sync/setup.sh" refresh
elif [ -n "$sync_wanted" ]; then
  printf '\n== Setting up config-sync\n'
  bash "$KIT/sync/setup.sh" || echo "Setting up config-sync stopped; run it again with: bash $KIT/sync/setup.sh"
fi

# Each part's own questions, once its files and settings are in place; an update doesn't ask again
# for a part set up before. Run one again any time: bash ~/.claude/<its setup>.
for p in $picked; do
  setup=$(field "$p" 7)
  [ "$setup" != - ] && [ "$(field "$p" 2)" != sync ] || continue
  if [ -n "$update" ] && grep -qx "$p" <<< "$was_installed"; then continue; fi
  printf '\n== Setting up %s\n' "$p"
  bash "$CLAUDE/$setup" || echo "Setting up $p stopped; run it again with: bash ~/.claude/$setup"
done

echo
echo "Done. Previous files are in $BACKUP. Start a new Claude Code session to load them."
