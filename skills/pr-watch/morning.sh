#!/bin/bash
# Run by the morning sync (sync.sh morning): sends what changed on the tracked PRs to the desktop
# and the phone, through the reminders skill when it is installed. It only peeks: the next check in
# a session still reports the changes in full.
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out=$(bash "$SK/pr-watch.sh" check --peek 2> /dev/null) || exit 0
[ -n "$out" ] && [ "$out" != "No change." ] || exit 0
notify="$HOME/.claude/skills/reminders/reminders.sh"
[ -f "$notify" ] || exit 0
count=$(printf '%s\n' "$out" | grep -c .)
first=$(printf '%s\n' "$out" | head -1 | cut -c1-150)
[ "$count" -gt 1 ] && first="$first (+$((count - 1)))"
bash "$notify" notify "PR: $first" > /dev/null 2>&1
exit 0
