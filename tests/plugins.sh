#!/bin/bash
# Installs every plugin of the kit's marketplace with Claude Code in a throwaway home folder, then
# checks each one from where Claude Code put it: its skills and hook scripts are there, its session
# start says what it should, its setup works from the plugin, and the parts find each other.
#   tests/plugins.sh            the marketplace of this folder
#   tests/plugins.sh --keep     keeps the sandbox and prints where it is
# Your own ~/.claude is neither read nor changed. Works on macOS, Linux and Windows (Git Bash).
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MARKET="$KIT/.claude-plugin/marketplace.json"
SB=$(mktemp -d)
[ "${1:-}" = --keep ] || trap 'rm -rf "$SB"' EXIT
for var in $(env | awk -F= '/^(CLAUDE|ANTHROPIC|PR_WATCH|GIT_IDENTITY)/ { print $1 }'); do unset "$var"; done
export HOME="$SB" CLAUDE_CONFIG_DIR="$SB/.claude" GIT_CONFIG_GLOBAL="$SB/.gitconfig"
. "$KIT/hooks/lib/jq.sh"
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

claude plugin marketplace add "$KIT" > /dev/null 2>&1 || bad "marketplace add"
names=$(jq -r '.plugins[].name' "$MARKET")
for p in $names; do
  claude plugin install "$p@claude-code-kit" > "$SB/install.log" 2>&1 || bad "install $p" "$(tail -1 "$SB/install.log")"
done
LIST="$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
root_of() {
  local r
  r=$(jq -r --arg id "$1@claude-code-kit" '.plugins[$id][0].installPath // empty' "$LIST")
  command -v cygpath > /dev/null 2>&1 && [ -n "$r" ] && r=$(cygpath -u "$r")
  printf '%s' "$r"
}
data_of() { printf '%s' "$CLAUDE_CONFIG_DIR/plugins/data/$1-claude-code-kit"; }

# run_event PLUGIN EVENT: runs PLUGIN's hooks for EVENT as Claude Code would, prints what they print.
run_event() {
  local root data
  root=$(root_of "$1") data=$(data_of "$1")
  jq -r --arg p "$1" --arg e "$2" '.plugins[] | select(.name == $p) | .hooks[$e] // [] | .[].hooks[].command' "$MARKET" |
    while IFS= read -r cmd; do
      echo '{}' | CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PLUGIN_DATA="$data" bash -c "$cmd"
    done
}

for p in $names; do
  root=$(root_of "$p")
  [ -n "$root" ] && [ -d "$root" ] || {
    bad "$p installed"
    continue
  }
  version=$(jq -r --arg p "$p" '.plugins[] | select(.name == $p) | .version // empty' "$MARKET")
  source=$(jq -r --arg p "$p" '.plugins[] | select(.name == $p) | .source' "$MARKET")
  [ -z "$version" ] && version=$(jq -r '.version // empty' "$KIT/$source/.claude-plugin/plugin.json")
  installed=$(jq -r --arg id "$p@claude-code-kit" '.plugins[$id][0].version' "$LIST")
  check "$p installed at its version $version" '[ "$installed" = "$version" ]'
  want=0
  for s in $(jq -r --arg p "$p" '.plugins[] | select(.name == $p) | .skills // [] | .[] | select(. != "./hooks")' "$MARKET"); do
    check "$p skill ${s#./}" '[ -f "$root/$s/SKILL.md" ]'
    want=$((want + 1))
  done
  # A plugin rooted at the kit loads every skill in skills/ unless its entry lists its own.
  loaded=$(claude plugin details "$p@claude-code-kit" 2> /dev/null | awk '$1 == "Skills" { gsub(/[()]/, "", $2); print $2 }')
  check "$p loads $want skill(s), not ${loaded:-?}" '[ "${loaded:-x}" = "$want" ]'
  for f in $(jq -r --arg p "$p" '.plugins[] | select(.name == $p) | .hooks // {} | .[][].hooks[].command' "$MARKET" |
    grep -o 'CLAUDE_PLUGIN_ROOT}/[^"]*' | sed 's|CLAUDE_PLUGIN_ROOT}/||' | sort -u); do
    check "$p hook script $f" '[ -f "$root/$f" ]'
  done
done

# What each session start says on a computer where nothing is set up yet.
out=$(run_event team SessionStart)
check "team: the rules, in the default language" '[[ "$out" == *"How we work together"* && "$out" == *"talk to me in English"* ]]'
out=$(CLAUDE_PLUGIN_OPTION_LANGUAGE=Français run_event team SessionStart)
check "team: the language option" '[[ "$out" == *"talk to me in Français"* ]]'

out=$(run_event statusline SessionStart)
check "statusline: offers its setup" '[[ "$out" == *"statusline plugin is installed but not set up"* && "$out" == *"hooks/setup/statusline.sh"* ]]'
check "statusline: keeps a copy in its data folder" '[ -f "$(data_of statusline)/statusline-command.sh" ] && [ -f "$(data_of statusline)/hooks/lib/jq.sh" ]'
KIT_HOME=$(data_of statusline) bash "$(root_of statusline)/hooks/setup/statusline.sh" < /dev/null > /dev/null 2>&1
check "statusline: its setup points statusLine at the data folder" 'jq -e ".statusLine.command | contains(\"plugins/data/statusline\")" "$HOME/.claude/settings.json" > /dev/null'
line=$(echo '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus"}}' | bash "$(data_of statusline)/statusline-command.sh" 2> /dev/null)
check "statusline: the copy runs" '[ -n "$line" ]'
mkdir -p "$HOME/.claude/.dnd" && echo '{"s1": {"profile": "work", "scope": "session", "untilText": "15:00"}, "s2": {"profile": "", "scope": "", "untilText": ""}}' > "$HOME/.claude/.dnd/active.json"
line=$(echo '{"session_id":"s1","workspace":{"current_dir":"/tmp"}}' | bash "$(data_of statusline)/statusline-command.sh" 2> /dev/null)
check "statusline: says the do-not-disturb profile on, where and until when" '[[ "$line" == *"🔕"*"work · session (15:00)"* ]]'
line=$(echo '{"session_id":"s2","workspace":{"current_dir":"/tmp"}}' | bash "$(data_of statusline)/statusline-command.sh" 2> /dev/null)
check "statusline: quiet while no profile is on" '[[ "$line" != *"🔕"* ]]'
out=$(run_event statusline SessionStart)
check "statusline: quiet once set up" '[ -z "$out" ]'

out=$(run_event git-identity-guard SessionStart)
check "git-identity-guard: offers its setup once" '[[ "$out" == *"KIT_HOME="* ]] && [ -z "$(run_event git-identity-guard SessionStart)" ]'
check "git-identity-guard: keeps a copy for git's hooks" '[ -f "$(data_of git-identity-guard)/hooks/git-identity-guard.sh" ]'
git config --global user.email someone@example.com
printf 'git-identity.match1=\ngit-identity.git-hooks=y\n' > "$SB/answers"
KIT_INSTALL_ANSWERS="$SB/answers" KIT_HOME=$(data_of git-identity-guard) bash "$(root_of git-identity-guard)/hooks/setup/git-identity-guard.sh" > /dev/null 2>&1
hooks_path=$(git config --global --get core.hooksPath)
check "git-identity-guard: git's hooks live in the data folder" '[[ "$hooks_path" == *plugins/data/git-identity-guard* ]] && grep -q "plugins/data/git-identity-guard.*/hooks/git-identity-guard.sh" "$hooks_path/pre-commit"'

out=$(run_event session-registry SessionStart)
check "session-registry: offers its setup" '[[ "$out" == *"session-registry plugin is installed but not set up"* ]]'
bash "$(root_of session-registry)/hooks/kit-session.sh" session-registry decline
check "session-registry: declined, no longer offered" '[ -z "$(run_event session-registry SessionStart)" ]'

out=$(run_event config-sync SessionStart)
check "config-sync: offers to set up the sync" '[[ "$out" == *"config-sync plugin is installed but not set up"* && "$out" == *"sync/setup.sh"* ]]'
out=$(run_event daily-sync SessionStart)
check "daily-sync: offers its setup" '[[ "$out" == *"daily-sync plugin is installed but not set up"* ]]'
out=$(run_event wave-check-hook UserPromptSubmit)
check "wave-check-hook: idle with no marker" '[ -z "$out" ]'

# A second computer: what the setup leaves came with the config sync, so nothing is asked.
mkdir -p "$HOME/.claude-sync/pr-watch" && echo '{}' > "$HOME/.claude-sync/pr-watch/config.json"
echo '{"ntfy": "https://ntfy.example/topic"}' > "$HOME/.claude/reminders.json"
echo '{"mcpServers": {"chrome-devtools": {"command": "npx"}}}' > "$HOME/.claude.json"
for p in pr-watch reminders test-evidence; do
  out=$(run_event "$p" SessionStart 2>&1 | grep 'not set up' || true)
  check "$p: set up already (shared by the sync), not asked" '[ -z "$out" ] && [ "$(cat "$HOME/.claude/kit-setup/$p")" = done ]'
done
rm -rf "$HOME/.claude-sync"

# The parts find each other in their plugins.
. "$KIT/hooks/lib/kit.sh"
check "kit_find: reminders, from the pr-watch plugin" '[ "$(kit_find reminders skills/reminders/reminders.sh)" = "$(root_of reminders)/skills/reminders/reminders.sh" ]'
mornings=$(kit_morning_scripts)
check "kit_morning_scripts: pr-watch and reminders" '[[ "$mornings" == *pr-watch/morning.sh* && "$mornings" == *reminders/morning.sh* ]]'

# The sync engine kept current in a sync repo the plugin set up, and left alone once changed by hand.
SYNC="$HOME/.claude-sync"
git init -q "$SYNC"
cp -R "$KIT/sync/." "$SYNC/"
root=$(root_of config-sync)
(cd "$SYNC" && bash "$root/sync/setup.sh" refresh --force > /dev/null)
check "config-sync: kit-engine.json written" '[ "$(jq -r .version "$SYNC/kit-engine.json")" = "$(jq -r ".plugins[] | select(.name == \"config-sync\") | .version" "$MARKET")" ]'
jq '.version = "0.0.1"' "$SYNC/kit-engine.json" > "$SB/m" && mv "$SB/m" "$SYNC/kit-engine.json"
echo "# older" >> "$SYNC/README.md"
jq --arg h "$(git hash-object "$SYNC/README.md")" '.files["README.md"] = $h' "$SYNC/kit-engine.json" > "$SB/m" && mv "$SB/m" "$SYNC/kit-engine.json"
out=$(run_event config-sync SessionStart)
check "config-sync: an older engine is brought up to date" '[[ "$out" == *"is now version"* ]] && cmp -s "$SYNC/README.md" "$KIT/sync/README.md"'
jq '.version = "0.0.1"' "$SYNC/kit-engine.json" > "$SB/m" && mv "$SB/m" "$SYNC/kit-engine.json"
echo "# mine" >> "$SYNC/sync.sh"
out=$(run_event config-sync SessionStart)
check "config-sync: an engine changed by hand is left alone, and said once" '[[ "$out" == *"changed by hand: sync.sh"* ]] && tail -1 "$SYNC/sync.sh" | grep -q mine && [ -z "$(run_event config-sync SessionStart)" ]'
rm "$SYNC/kit-engine.json"
check "config-sync: a sync repo with its own engine is never touched" '[ -z "$(run_event config-sync SessionStart)" ]'

[ "${1:-}" = --keep ] && echo "Sandbox kept: $SB"
echo "$fails problem(s)"
[ "$fails" = 0 ]
