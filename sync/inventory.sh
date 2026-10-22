#!/bin/bash
# What each computer runs, kept in the sync repo so any of them can tell what the others have:
# the system, Claude Code and tool versions, the plugins and mods installed, each kit clone and
# when this computer last synced. Written to inventory/<machine>.json at every sync.
#   inventory.sh write [--now]   collects this computer's (sync.sh runs it before each save, at
#                                most every 30 minutes; --now at once)
#   inventory.sh show     every computer, one block each, then what differs between them
#   inventory.sh json     every computer's, as one JSON array
# Works on macOS (bash 3.2), Linux and Windows (Git Bash); a tool that is missing is left out.
set -u
SYNC=${SYNC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
CLAUDE=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
OUT="$SYNC/inventory"
EVERY_MIN=${INVENTORY_EVERY_MIN:-30}
. "$SYNC/jq.sh"

first_line() { "$@" 2> /dev/null | tr -d '\r' | head -1; }

os_name() {
  case "$(uname -s)" in
    Darwin) printf 'macOS %s' "$(first_line sw_vers -productVersion)" ;;
    MINGW* | MSYS* | CYGWIN*) first_line cmd.exe //c ver | sed 's/^ *//' | grep . || echo Windows ;;
    *)
      if [ -f /etc/os-release ]; then
        (. /etc/os-release && printf '%s' "${PRETTY_NAME:-Linux}")
      else
        echo Linux
      fi
      ;;
  esac
}

# tool NAME: the first line its --version prints, or nothing when it isn't installed.
tool() {
  command -v "$1" > /dev/null 2>&1 || return 0
  first_line "$1" --version
}

tools() {
  jq -n --arg claude "$(tool claude)" --arg git "$(tool git)" --arg node "$(tool node)" \
    --arg jq "$(tool jq)" --arg gh "$(tool gh)" --arg python "$(tool python3)" --arg bash "${BASH_VERSION:-}" \
    '{claude: $claude, git: $git, node: $node, jq: $jq, gh: $gh, python: $python, bash: $bash}
     | with_entries(select(.value != ""))'
}

# Installed plugins by name@marketplace: version and scope, never their paths.
plugins() {
  local f="$CLAUDE/plugins/installed_plugins.json"
  [ -f "$f" ] || { echo '{}'; return 0; }
  jq '(.plugins // {}) | with_entries(.value = ([.value[] | {version, scope}] | first)) | with_entries(select(.value != null))' "$f" 2> /dev/null || echo '{}'
}

mods() {
  local m
  for m in "$CLAUDE"/mods/*/.claude-plugin/plugin.json; do
    [ -f "$m" ] && jq -c '{(.name): (.version // "")}' "$m" 2> /dev/null
  done | jq -s 'add // {}'
}

dev_dir() {
  local d
  d=$(jq -r '.devDir // "~/dev"' "$SYNC/machines/$1.json" 2> /dev/null)
  printf '%s' "${d/#\~/$HOME}"
}

# Every kit cloned in the dev folder (a repo holding .claude-plugin/marketplace.json, or the
# parts.json of a kit installed by install.sh): its name, branch, commit and how far it is from its
# upstream, as git last knew it.
kits() {
  local root=$1 m dir
  for dir in "$root"/*/; do
    dir=${dir%/}
    m="$dir/.claude-plugin/marketplace.json"
    [ -f "$m" ] || [ -f "$dir/parts.json" ] || continue
    git -C "$dir" rev-parse --git-dir > /dev/null 2>&1 || continue
    jq -n --arg name "$(jq -r '.name // empty' "$m" 2> /dev/null)" --arg folder "${dir##*/}" \
      --arg branch "$(git -C "$dir" rev-parse --abbrev-ref HEAD 2> /dev/null)" \
      --arg commit "$(git -C "$dir" log -1 --format='%h %cs %s' 2> /dev/null | cut -c1-90)" \
      --arg behind "$(git -C "$dir" rev-list --count 'HEAD..@{u}' 2> /dev/null)" \
      --arg ahead "$(git -C "$dir" rev-list --count '@{u}..HEAD' 2> /dev/null)" \
      --arg changed "$(git -C "$dir" status --porcelain 2> /dev/null | wc -l | tr -d ' ')" \
      '{name: (if $name == "" then $folder else $name end), folder: $folder, branch: $branch, commit: $commit,
        ahead: ($ahead | tonumber? // null), behind: ($behind | tonumber? // null), changed: ($changed | tonumber? // 0)}'
  done | jq -s '.'
}

# write [--now]: at most every EVERY_MIN minutes, as collecting takes a few seconds.
write() {
  local machine
  machine=$(tr -d '[:space:]' < "$SYNC/.machine" 2> /dev/null)
  [ -n "$machine" ] || return 0
  if [ "${1:-}" != --now ] && [ -n "$(find "$OUT/$machine.json" -mmin -"$EVERY_MIN" 2> /dev/null)" ]; then
    return 0
  fi
  mkdir -p "$OUT"
  jq -n --arg machine "$machine" --arg at "$(date '+%Y-%m-%d %H:%M')" --arg zone "$(date '+%z')" \
    --arg os "$(os_name)" --arg arch "$(uname -m)" --arg kernel "$(uname -sr)" --arg host "$(first_line hostname)" \
    --arg synced "$(git -C "$SYNC" log -1 --format='%h %cs' 2> /dev/null)" \
    --argjson tools "$(tools)" --argjson plugins "$(plugins)" --argjson mods "$(mods)" \
    --argjson kits "$(kits "$(dev_dir "$machine")")" \
    '{machine: $machine, collected: ($at + " " + $zone), host: $host, os: $os, arch: $arch, kernel: $kernel,
      sync: $synced, tools: $tools, plugins: $plugins, mods: $mods, kits: $kits}' > "$OUT/$machine.json.tmp" &&
    mv "$OUT/$machine.json.tmp" "$OUT/$machine.json"
}

all() {
  local f
  for f in "$OUT"/*.json; do [ -f "$f" ] && cat "$f"; done | jq -s 'sort_by(.machine)'
}

show() {
  local inventory
  inventory=$(all)
  [ "$(jq 'length' <<< "$inventory")" -gt 0 ] || { echo "No computer has written its inventory yet: it comes with the next sync."; return 0; }
  jq -r '.[] |
    "\(.machine)  (\(.host // "?"), collected \(.collected), last sync commit \(.sync // "?"))",
    "  \(.os) · \(.arch) · \(.kernel)",
    "  tools: " + ([.tools | to_entries[] | "\(.key) \(.value | sub("^[^0-9]*"; "") | split(" ")[0])"] | join(", ")),
    (.kits[] | "  kit \(.name): \(.branch) \(.commit)" +
      (if (.behind // 0) > 0 then " · \(.behind) behind" else "" end) +
      (if (.ahead // 0) > 0 then " · \(.ahead) ahead" else "" end) +
      (if .changed > 0 then " · \(.changed) changed" else "" end)),
    "  \(.plugins | length) plugins, \(.mods | length) mods",
    ""' <<< "$inventory"
  jq -r '
    def differs(f): [.[] | {machine, v: f}] | group_by(.v) | if length > 1 then map("\(.[0].v // "none") on \(map(.machine) | join(", "))") | join(" / ") else empty end;
    . as $all
    | ([.[] | .plugins | keys[]] | unique) as $names
    | ([.[] | .mods | keys[]] | unique) as $modnames
    | (["Differences:"] +
       ([$all | differs(.tools.claude) | "  Claude Code: " + .]) +
       [$names[] as $n | $all | differs(.plugins[$n].version) | "  plugin \($n): " + .] +
       [$modnames[] as $n | $all | differs(.mods[$n]) | "  mod \($n): " + .]) as $lines
    | if ($all | length) < 2 then "Only this computer has written its inventory so far: the others do at their next sync."
      elif ($lines | length) > 1 then $lines[] else "Every computer runs the same versions." end' <<< "$inventory"
}

case "${1:-show}" in
  write) write "${2:-}" ;;
  show) show ;;
  json) all ;;
  *)
    echo "usage: inventory.sh write|show|json" >&2
    exit 2
    ;;
esac
