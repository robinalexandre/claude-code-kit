#!/bin/bash
# Installs the parts of this kit you pick into ~/.claude.
#   ./install.sh            asks about each part
#   ./install.sh --all      installs every part
#   ./install.sh PART...    installs the named parts
#   ./install.sh --list     lists the parts
# Files it replaces and the previous settings.json are saved in
# ~/.claude/backups/before-kit-<date>/. Running it again is safe.
set -eu
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLAUDE="$HOME/.claude"
SETTINGS="$CLAUDE/settings.json"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    home=$(cygpath -m "$HOME")
    sep=';'
    ;;
  *)
    home=$HOME
    sep=':'
    ;;
esac

PARTS="team:rules:Base rules added to ~/.claude/CLAUDE.md (one team; ask before production, commits, pushes, PRs and decisions that need your context)
ci-review:skill:An AI review step on CI that checks each PR/MR against its proof (GitHub Actions, GitLab CI; API key or cloud provider)
test-evidence:skill:Screenshots, video and network proof of a ticket, attached to Jira or the PR (chrome-devtools MCP, jq, perl; video needs ffmpeg)
handoff:skill:Handoff notes between computers (needs the sync engine in sync/)
daily-sync:skill:Syncs before the first session of the day and every morning at a set time (needs the sync engine in sync/)
reminders:skill:Reminders for a later session, notified on the desktop and the phone every morning (needs daily-sync)
pr-watch:skill:Tracks your PRs until merged: new comments, votes, CI results, checked at each session start (Azure DevOps, GitHub; needs Python 3)
pr-pane:mod:A /prs pane of the PRs pr-watch tracks: status, CI, what each waits for, open in the browser, live refresh (needs pr-watch)
paste-preview:mod:Pasted text shown in full, previews of pasted images (macOS, Windows)
recent-prompts:mod:Your last two messages above the prompt, and a searchable history
wave-check:mod:A self-check whenever a reply doesn't start with your marker emoji
file-tools-guard:hook:Blocks shell workarounds (cat, sed -i, heredocs) for reading and editing files
recent-activity:hook:A digest of your recent sessions across your dev folder, at session start
session-registry:hook:Offers to resume the session left open in a terminal tab (zsh, JetBrains or Ghostty)
wave-check-hook:hook:A warning whenever a reply doesn't start with your marker emoji
nocturne-notify:hook:Keyboard-backlight signals through Agent Nocturne (github.com/taekchef/agent-nocturne)
statusline:statusline:A status line with folder, branch, model, context, effort and rate limit
video-montage:skill:Not dev, video montages from a folder of phone clips, Instagram Reel by default (ffmpeg; saving to Photos needs macOS)
insta360-montage:skill:Not dev, video montages from raw Insta360 footage, Instagram Reel by default (ffmpeg, python3)"

source_of() {
  case "$2" in
    skill) echo "skills/$1" ;;
    mod) echo "mods/$1" ;;
    rules) echo "rules/$1.md" ;;
    statusline) echo statusline-command.sh ;;
    hook) if [ "$1" = wave-check-hook ]; then echo hooks/wave-check.sh; else echo "hooks/$1.sh"; fi ;;
  esac
}

# A copy of the kit that carries only some parts offers only those.
PARTS=$(while IFS=: read -r name kind what; do
  if [ -e "$KIT/$(source_of "$name" "$kind")" ]; then printf '%s:%s:%s\n' "$name" "$kind" "$what"; fi
done <<< "$PARTS")

field() { awk -F: -v p="$1" -v f="$2" '$1 == p { print $f }' <<< "$PARTS"; }

if [ "${1:-}" = --list ]; then
  awk -F: '{ what = $0; sub(/^[^:]*:[^:]*:/, "", what); printf "%-17s %-10s %s\n", $1, $2, what }' <<< "$PARTS"
  exit 0
fi

command -v jq > /dev/null || {
  echo "Install jq first." >&2
  exit 1
}
. "$KIT/hooks/lib/jq.sh"

# Questions are read from the terminal, or one answer per line from KIT_INSTALL_ANSWERS (tests).
TTY=""
if [ -n "${KIT_INSTALL_ANSWERS:-}" ]; then
  exec 3< "$KIT_INSTALL_ANSWERS"
  TTY=answers
elif (: < /dev/tty) 2> /dev/null; then
  exec 3< /dev/tty
  TTY=/dev/tty
fi

# reply PROMPT: prints the answer, empty when there is no one to ask.
reply() {
  local answer=""
  [ -n "$TTY" ] || return 0
  read -r -u 3 -p "$1 " answer || answer=""
  [ "$TTY" = answers ] && printf '%s %s\n' "$1" "$answer" >&2
  printf '%s' "$answer"
}

ask() {
  case "$(reply "$1 [y/N]")" in [yY]*) return 0 ;; *) return 1 ;; esac
}

picked=""
if [ "${1:-}" = --all ]; then
  picked=$(cut -d: -f1 <<< "$PARTS")
elif [ $# -gt 0 ]; then
  for p in "$@"; do
    [ -n "$(field "$p" 1)" ] || {
      echo "Unknown part: $p (see ./install.sh --list)" >&2
      exit 1
    }
    picked="$picked$p"$'\n'
  done
else
  while IFS=: read -r name kind what; do
    ask "Install the $kind $name: $what?" && picked="$picked$name"$'\n'
  done <<< "$PARTS"
fi
picked=$(grep . <<< "$picked" || true)
[ -n "$picked" ] || {
  echo "Nothing picked."
  exit 0
}

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
hook_lib=""
for p in $picked; do
  case "$(field "$p" 2)" in hook | statusline) hook_lib=1 ;; esac
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
      ;;
    statusline) put statusline-command.sh statusline-command.sh && fragments+=("$KIT/settings/statusline.json") ;;
    rules)
      heading=$(grep -m1 '^## ' "$KIT/rules/$p.md")
      if grep -qxF -- "$heading" "$CLAUDE/CLAUDE.md" 2> /dev/null; then
        echo "~/.claude/CLAUDE.md already has \"$heading\"; left as is."
      else
        [ -f "$CLAUDE/CLAUDE.md" ] && cp -p "$CLAUDE/CLAUDE.md" "$BACKUP/CLAUDE.md"
        language=$(reply "Which language should Claude talk to you in (e.g. English, Français, Español)? [English]")
        language=${language:-English}
        awk -v l="$language" '{ gsub(/__LANGUAGE__/, l) } 1' "$KIT/rules/$p.md" >> "$CLAUDE/CLAUDE.md"
      fi
      ;;
  esac
  case "$p" in wave-check | wave-check-hook) marker_wanted=1 ;; esac
  echo "Installed $p"
done
if [ -n "$hook_lib" ]; then put hooks/lib hooks/lib; fi
chmod +x "$CLAUDE"/hooks/*.sh 2> /dev/null || true

# The wave-check parts check replies against an emoji the user picks once.
marker=$(jq -r '.env.CLAUDE_REPLY_MARKER // empty' "$SETTINGS")
if [ -n "$marker_wanted" ] && [ -z "$marker" ]; then
  marker=$(reply "Which emoji should start every reply from Claude (e.g. 🌊, 🦊, ✅)?")
  marker=${marker//[[:space:]]/}
  if [ -z "$marker" ]; then
    echo "No emoji given: wave-check stays idle until you set CLAUDE_REPLY_MARKER in $SETTINGS (env)."
  elif ask "Add \"Start every message with $marker\" to ~/.claude/CLAUDE.md? wave-check relies on that rule."; then
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
  if ask "Source claude-resume-here.zsh from ~/.zshrc, so a new terminal tab offers to resume the session left open there?"; then
    printf '\n[ -f ~/.claude/hooks/claude-resume-here.zsh ] && source ~/.claude/hooks/claude-resume-here.zsh\n' >> "$HOME/.zshrc"
  fi
fi

echo "Done. Previous files are in $BACKUP. Start a new Claude Code session to load them."
