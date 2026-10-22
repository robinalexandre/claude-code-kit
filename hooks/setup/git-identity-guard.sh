#!/bin/bash
# Sets up git-identity-guard: which email to commit with, host by host. Run it again any time:
#   bash ~/.claude/hooks/setup/git-identity-guard.sh
set -eu
. "$HOME/.claude/hooks/lib/jq.sh"
. "$HOME/.claude/hooks/lib/ask.sh"
GUARD="$HOME/.claude/hooks/git-identity-guard.sh"

echo "A rule says which email to commit and push with where. It matches a host or the start of a path:"
echo "github.com, github.com/my-company, gitlab.com/client-x, dev.azure.com/my-org. The longest match wins."
echo "A repo no rule matches expects the email you committed with most there; Claude asks you when it is unsure."
rules=$(bash "$GUARD" list || true)
[ -n "$rules" ] && printf 'Rules already recorded:\n%s\n' "$rules" | sed 's/^/  /'
default_email=$(git config --global --get user.email || true)
i=1
while [ "$i" -le 20 ]; do
  match=$(reply "git-identity.match$i" "Host or host/owner for a rule (blank when done):")
  [ -n "$match" ] || break
  email=$(reply "git-identity.email$i" "Email for $match:" "$default_email")
  if [[ "$email" == *@* ]]; then bash "$GUARD" set "$match" "$email"; else echo "  Not an email, skipped."; fi
  i=$((i + 1))
done

echo
echo "Claude's commits and pushes are checked from now on. Git itself can run the same check on every push,"
echo "whoever runs it (you, Claude, another agent, your editor), through git's global hooks folder."
echo "Each repo's own hooks keep running; git push --no-verify skips the check."
if [ -n "$(git config --global --get core.hooksPath || true)" ] && [ "$(git config --global --get core.hooksPath)" != "$(kit_path "$HOME/.claude/hooks/git")" ]; then
  echo "Not offered: git's global hooks folder is already $(git config --global --get core.hooksPath)."
elif ask git-identity.git-hooks "Check every push on this computer too?"; then
  bash "$GUARD" git-hooks on
fi
