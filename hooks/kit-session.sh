#!/bin/bash
# Session start of a part installed as a plugin from the claude-code-kit marketplace:
#   kit-session.sh PART            keeps the copy that programs outside Claude Code run (the status line,
#                                  git's hooks, zsh) up to date in the plugin's data folder, and tells
#                                  Claude when PART still has to be set up on this computer
#   kit-session.sh PART decline    the user doesn't want PART's setup: stop offering it
# The plugin's folder changes with each version; its data folder doesn't.
ROOT=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
DATA=${CLAUDE_PLUGIN_DATA:-}
. "$ROOT/hooks/lib/jq.sh"
. "$ROOT/hooks/lib/ask.sh"
. "$ROOT/hooks/lib/kit.sh"
part=$1

if [ "${2:-}" = decline ]; then
  kit_setup_mark "$part" declined
  exit 0
fi

# dnd is recommended once, to whoever has a pane it quiets as a plugin and not dnd itself.
if [ -z "$(kit_setup_state dnd-recommended)" ] && ! kit_plugin_root dnd > /dev/null; then
  for pane in recent-prompts pr-pane reminders-handoffs; do
    kit_plugin_root "$pane" > /dev/null || continue
    kit_setup_mark dnd-recommended yes
    printf 'claude-code-kit: %s It is not installed. Once in this session, when it fits, recommend it to the user (/plugin install dnd@claude-code-kit), saying why from the above; it is not recommended again.\n' "$KIT_DND_WHY"
    break
  done
fi

# mirror, setup, and whether the part works at all before its setup.
mirror="" setup="" required=""
case "$part" in
  statusline) mirror="statusline-command.sh hooks/lib/jq.sh" setup=hooks/setup/statusline.sh required=1 ;;
  git-identity-guard) mirror="hooks/git-identity-guard.sh hooks/lib/jq.sh" setup=hooks/setup/git-identity-guard.sh ;;
  session-registry) mirror=hooks/claude-resume-here.zsh setup=hooks/setup/session-registry.sh required=1 ;;
  recent-activity) setup=hooks/setup/recent-activity.sh ;;
  pr-watch) setup=skills/pr-watch/setup.sh ;;
  test-evidence) setup=skills/test-evidence/setup.sh ;;
  daily-sync) setup=skills/daily-sync/setup.sh required=1 ;;
  reminders) setup=skills/reminders/setup.sh ;;
  config-sync) setup=sync/setup.sh required=1 ;;
  *) exit 0 ;;
esac

if [ -n "$mirror" ] && [ -n "$DATA" ]; then
  for f in $mirror; do
    if ! cmp -s "$ROOT/$f" "$DATA/$f"; then
      mkdir -p "$(dirname "$DATA/$f")" && cp "$ROOT/$f" "$DATA/$f"
    fi
  done
fi

if [ "$part" = config-sync ] && [ -d "$HOME/.claude-sync/.git" ]; then
  bash "$ROOT/sync/setup.sh" refresh
  exit 0
fi

state=$(kit_setup_state "$part")
case "$state" in done | declined) exit 0 ;; esac

# What the setup leaves may already be here: shared by the config sync from another computer, or
# set up by hand. Only what lives on one computer (a schedule, ~/.zshrc, git's hooks) is asked again.
configured() {
  case "$part" in
    statusline) jq -r '.statusLine.command // empty' "$HOME/.claude/settings.json" 2> /dev/null | grep -q 'statusline-command\.sh' ;;
    session-registry) grep -qs claude-resume-here.zsh "$HOME/.zshrc" ;;
    recent-activity) [ -n "${CLAUDE_DEV_ROOT:-}" ] ;;
    git-identity-guard) [ -n "$(bash "$ROOT/hooks/git-identity-guard.sh" list 2> /dev/null)" ] ;;
    pr-watch) [ -f "${PR_WATCH_DIR:-$HOME/.claude-sync/pr-watch}/config.json" ] ;;
    test-evidence) jq -e '.mcpServers["chrome-devtools"]' "$HOME/.claude.json" > /dev/null 2>&1 ;;
    reminders) [ -f "$HOME/.claude/reminders.json" ] ;;
    daily-sync) bash "$ROOT/skills/daily-sync/schedule.sh" status 2> /dev/null | head -1 | grep -q '^on' ;;
    *) return 1 ;;
  esac
}
if configured; then
  kit_setup_mark "$part" done
  exit 0
fi
[ "$state" = offered ] && [ -z "$required" ] && exit 0

cmd="bash \"$(kit_path "$ROOT/$setup")\""
[ -n "$mirror" ] && [ -n "$DATA" ] && cmd="KIT_HOME=\"$(kit_path "$DATA")\" $cmd"
printf 'claude-code-kit: the %s plugin is installed but not set up on this computer yet. ' "$part"
printf 'Early in this session, offer the user to run its setup in their own terminal (it asks a few questions): %s ' "$cmd"
printf 'If they would rather not, run: bash "%s" %s decline\n' "$(kit_path "$ROOT/hooks/kit-session.sh")" "$part"
[ -z "$required" ] && kit_setup_mark "$part" offered
exit 0
