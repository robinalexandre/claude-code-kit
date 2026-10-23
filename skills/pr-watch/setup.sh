#!/bin/bash
# Sets up pr-watch: where it looks for your PRs and review requests, and which authors are bots.
# Run it again any time: bash ~/.claude/skills/pr-watch/setup.sh
set -eu
LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib" && pwd)
. "$LIB/jq.sh"
. "$LIB/ask.sh"
. "$LIB/kit.sh"
dir=${PR_WATCH_DIR:-$HOME/.claude-sync/pr-watch}
conf="$dir/config.json"

command -v python3 > /dev/null 2>&1 || command -v python > /dev/null 2>&1 || echo "  Python 3 is missing: pr-watch needs it."
if command -v gh > /dev/null 2>&1 && gh auth status > /dev/null 2>&1; then
  echo "  GitHub: gh is signed in."
else
  echo "  GitHub: for GitHub PRs, install gh (https://cli.github.com) and run gh auth login."
fi
if [ -n "${AZURE_DEVOPS_PAT:-}" ] || command -v az > /dev/null 2>&1; then
  echo "  Azure DevOps: found (az login, or AZURE_DEVOPS_PAT)."
else
  echo "  Azure DevOps: for Azure DevOps PRs, install the Azure CLI and run az login, or set AZURE_DEVOPS_PAT."
fi

echo "pr-watch tracks the PRs you add, and also finds your own PRs and the reviews you are asked for where"
echo "you tell it to look. Lists are comma separated; Enter keeps what is shown, - empties it."
now() { jq -r --arg k "$1" '.[$k] // [] | join(", ")' "$conf" 2> /dev/null || true; }
list() {
  local answer
  answer=$(reply "pr-watch.$1" "$2" "$(now "$1")")
  [ "$answer" = - ] && answer=""
  printf '%s' "$answer"
}
github=$(list githubRepos "GitHub repos to look in (owner/repo):")
orgs=$(list azureOrgs "Azure DevOps organizations to look in:")
projects=$(list azureProjects "Azure DevOps projects whose pipeline runs you start by hand (org/project):")
bots=$(list bots "Comment authors that are bots, reported apart (display name or login):")
track='["opened", "assigned", "approved"]'
ask pr-watch.autoTrack "Track your own open PRs by themselves (opened by you, assigned to you, approved by you)?" y || track='[]'

if git -C "$dir" remote get-url origin 2> /dev/null | grep -q 'github\.com'; then
  echo "What one computer fetches is shared with your others through your config sync's GitHub repo, so"
  echo "each host is asked by one computer only, and fetched again once its share is older than:"
else
  echo "Recommended: the config sync (config-sync) on a GitHub repo. pr-watch then shares what one computer"
  echo "fetches with the others: fewer requests to the hosts, an instant pane, and a host one computer can't"
  echo "reach still shown from another. Without it, each computer fetches on its own, once its copy is older than:"
fi
minutes() {
  local answer
  answer=$(reply "pr-watch.cacheMinutes.$1" "$2" "$(jq -r --arg k "$1" --arg d "$3" '.cacheMinutes[$k] // ($d | tonumber)' "$conf" 2> /dev/null || echo "$3")")
  case "$answer" in '' | *[!0-9.]* | *.*.*) answer=$3 ;; esac
  printf '%s' "$answer"
}
running=$(minutes running "  minutes, while a CI or a pipeline run is in progress:" 2)
idle=$(minutes idle "  minutes, otherwise:" 10)
shared=true
ask pr-watch.sharedCache "Share what this computer fetches with your other computers?" y || shared=false

mkdir -p "$dir"
[ -f "$conf" ] || echo '{}' > "$conf"
jq --indent 2 --arg g "$github" --arg o "$orgs" --arg p "$projects" --arg b "$bots" --argjson t "$track" \
  --argjson r "$running" --argjson i "$idle" --argjson s "$shared" '
  def items: split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""));
  .githubRepos = ($g | items) | .azureOrgs = ($o | items) | .azureProjects = ($p | items)
  | .bots = ($b | items) | .autoTrack = $t | .cacheMinutes = {running: $r, idle: $i} | .sharedCache = $s' \
  "$conf" > "$conf.tmp" && mv "$conf.tmp" "$conf"
echo "  Saved in $conf. Ask Claude \"watch this PR\" with a link, or \"check my PRs\"."
kit_setup_mark pr-watch done
