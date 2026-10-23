#!/bin/bash
# Do-not-disturb profiles for the kit's panes (history, PRs & CI, reminders, handoffs): what each
# profile hides or keeps, and the rules that turn one on by themselves.
#   dnd.sh active [DIR]                the profile on now for a session in DIR, as JSON; a part kept
#                                      `only` some names also lists them in `keep`, as the panes
#                                      match them: lowercase, the last part of a path, @here resolved
#   dnd.sh json [DIR]                  profiles, rules, the switches, what is on, the names each
#                                      part lists now and every repo and folder worked in
#                                      (workspaces), as JSON (the pane)
#   dnd.sh list                        profiles and rules, in words
#   dnd.sh on PROFILE [FOR]            turns PROFILE on for this computer, over the rules; FOR: 30m,
#                                      2h, 1d, or HH:MM to end then; without it, until `off`
#   dnd.sh off                         back to the rules
#   dnd.sh known PART                  the names PART lists now, one per line
# active, json, list, on and off take --session ID (Claude Code: $CLAUDE_CODE_SESSION_ID): `on`
# and `off` then switch that session only, over the computer's switch.
#   dnd.sh set PROFILE PART MODE [NAME...]
#                                      PART: history, prs, reminders, handoffs; MODE: show, hide or
#                                      only (the NAMEs: repos, groups, folders; @here is the folder
#                                      of the session); creates PROFILE when new
#   dnd.sh delete PROFILE              deletes PROFILE and its rules
#   dnd.sh rule PROFILE KEY=VALUE...   a rule that turns PROFILE on: wifi=NAME, folder=PATH,
#                                      days=sat,sun (or weekday, weekend, day), from=HH:MM, to=HH:MM;
#                                      all its keys must hold
#   dnd.sh unrule N                    deletes rule N (numbered from 1, as `list` shows them)
#   dnd.sh edit PROFILE                a checklist on the terminal to pick what PROFILE shows
#   dnd.sh wifi                        the Wi-Fi network this computer is on
# Profiles and rules live in the config sync repo when there is one (every computer gets them),
# else in ~/.claude/dnd; the switch and the Wi-Fi name stay on this computer. The profile `none`
# shows everything: `dnd.sh on none 2h` keeps every rule quiet for two hours.
set -u
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SYNC="$HOME/.claude-sync"
if [ -n "${CLAUDE_DND_DIR:-}" ]; then
  DIR=$CLAUDE_DND_DIR
elif [ -f "$SYNC/sync.sh" ]; then
  DIR="$SYNC/dnd"
else
  DIR="$HOME/.claude/dnd"
fi
FILE="$DIR/profiles.json"
LOCAL=${CLAUDE_DND_LOCAL:-$HOME/.claude/.dnd}
SWITCH="$LOCAL/switch.json"
WIFI="$LOCAL/wifi"
WIFI_FRESH=300
PARTS="history prs reminders handoffs"

if [ -f "$SK/../../hooks/lib/jq.sh" ]; then
  . "$SK/../../hooks/lib/jq.sh"
elif command -v cygpath > /dev/null 2>&1; then
  jq() { command jq -b "$@"; }
fi

die() {
  echo "$*" >&2
  exit 1
}

profiles() { if [ -f "$FILE" ]; then cat "$FILE"; else echo '{"profiles": {}, "rules": []}'; fi; }

# save FILTER [ARGS...]: rewrites profiles.json through the jq FILTER.
save() {
  local filter=$1 out
  shift
  mkdir -p "$DIR"
  out=$(profiles | jq --indent 2 "$@" "$filter") || die "Could not update $FILE"
  printf '%s\n' "$out" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
}

has_profile() { profiles | jq -e --arg p "$1" '.profiles | has($p)' > /dev/null; }

slashed() { printf '%s' "$1" | tr '\\' '/'; }

# The Wi-Fi network's name; macOS hides it from ipconfig unless asked with verbose logging, and
# system_profiler, which still tells it, takes seconds.
wifi_now() {
  local name=""
  case "$(uname -s)" in
    Darwin)
      name=$(ipconfig getsummary en0 2> /dev/null | awk -F' : ' '/^ +SSID :/ { print $2; exit }')
      if [ -z "$name" ] || [ "$name" = "<redacted>" ]; then
        name=$(system_profiler SPAirPortDataType 2> /dev/null |
          awk '/Current Network Information:/ { getline; sub(/^ +/, ""); sub(/:$/, ""); print; exit }')
      fi
      ;;
    MINGW* | MSYS* | CYGWIN*)
      name=$(netsh wlan show interfaces 2> /dev/null | awk -F': ' '/^ +SSID +:/ { sub(/\r$/, "", $2); print $2; exit }')
      ;;
    *)
      command -v nmcli > /dev/null 2>&1 && name=$(nmcli -t -f active,ssid dev wifi 2> /dev/null | awk -F: '$1 == "yes" { print $2; exit }')
      [ -z "$name" ] && command -v iwgetid > /dev/null 2>&1 && name=$(iwgetid -r 2> /dev/null)
      ;;
  esac
  printf '%s\n' "$name"
}

wifi_refresh() {
  local name
  name=$(wifi_now)
  mkdir -p "$LOCAL"
  printf '%s\t%s\n' "$(date +%s)" "$name" > "$WIFI.tmp" && mv "$WIFI.tmp" "$WIFI"
  printf '%s\n' "$name"
}

# The name last found, read again in the background once it is WIFI_FRESH seconds old: a session
# never waits for system_profiler, except the first time.
wifi_cached() {
  local at name
  if [ ! -f "$WIFI" ]; then
    wifi_refresh
    return
  fi
  IFS=$'\t' read -r at name < "$WIFI"
  if [ $(($(date +%s) - ${at:-0})) -ge "$WIFI_FRESH" ]; then
    (wifi_refresh > /dev/null 2>&1 &) < /dev/null > /dev/null 2>&1
  fi
  printf '%s\n' "${name:-}"
}

# The git repo DIR is in, else DIR itself.
here() {
  local top
  top=$(git -C "$1" rev-parse --show-toplevel 2> /dev/null) || top=$1
  slashed "${top:-$1}"
}

switch() { if [ -f "$SWITCH" ]; then cat "$SWITCH"; else echo '{}'; fi; }

# set_switch PROFILE UNTIL: the session's switch with --session, else the computer's; PROFILE ""
# takes it off. A session's switch with no end goes after two days, its session long gone.
set_switch() {
  local out
  mkdir -p "$LOCAL"
  out=$(switch | jq --arg p "$1" --argjson u "$2" --arg s "$SESSION" --argjson now "$(date +%s)" '
    ({profile: $p, until: $u, at: $now}) as $one
    | if $s == "" then (if $p == "" then del(.computer) else .computer = $one end)
      else (if $p == "" then del(.sessions[$s]) else .sessions[$s] = $one end) end
    | .sessions = ((.sessions // {}) | with_entries(select(
        if .value.until > 0 then .value.until > $now else $now - (.value.at // 0) < 172800 end)))') || die "Could not update $SWITCH"
  printf '%s\n' "$out" > "$SWITCH.tmp" && mv "$SWITCH.tmp" "$SWITCH"
}

# active DIR: what is on for a session in DIR. The session's switch first, the computer's next,
# then the rules in their order, those naming a folder before the others.
active() {
  local dir top wifi=""
  dir=$(slashed "${1:-$PWD}")
  top=$(here "$dir")
  if profiles | jq -e '.rules | any(has("wifi"))' > /dev/null 2>&1; then wifi=$(wifi_cached); fi
  profiles | jq --argjson switches "$(switch)" --arg session "$SESSION" --arg dir "$dir" --arg top "$top" --arg wifi "$wifi" \
    --arg home "$(slashed "$(cygpath -m "$HOME" 2> /dev/null || echo "$HOME")")" --argjson now "$(date +%s)" --arg day "$(date +%u)" --arg time "$(date +%H:%M)" '
    def low: ascii_downcase;
    def expand: if startswith("~/") then $home + .[1:] else . end | sub("/+$"; "");
    def inside($folder): ($dir | low) + "/" | startswith(($folder | expand | low) + "/");
    def days: [splits(", *") | low | if . == "day" or . == "daily" then 1, 2, 3, 4, 5, 6, 7
      elif startswith("weekday") then 1, 2, 3, 4, 5 elif startswith("weekend") then 6, 7
      elif startswith("mon") then 1 elif startswith("tue") then 2 elif startswith("wed") then 3
      elif startswith("thu") then 4 elif startswith("fri") then 5 elif startswith("sat") then 6
      elif startswith("sun") then 7 else empty end];
    def hours: (.from // "00:00") as $f | (.to // "24:00") as $t
      | if $f <= $t then $time >= $f and $time < $t else $time >= $f or $time < $t end;
    def holds: ((has("folder") | not) or inside(.folder))
      and ((has("wifi") | not) or ($wifi != "" and (.wifi | low) == ($wifi | low)))
      and ((has("days") | not) or (.days | days | any(. == ($day | tonumber))))
      and (((has("from") or has("to")) | not) or hours);
    def why: [if has("folder") then "in " + (.folder | sub("/+$"; "") | split("/") | last) else empty end,
      if has("wifi") then "on Wi-Fi " + .wifi else empty end,
      if has("days") then .days else empty end,
      if has("from") or has("to") then (.from // "00:00") + "-" + (.to // "24:00") else empty end] | join(", ");
    def live: . != null and (.profile // "") != "" and ((.until // 0) == 0 or .until > $now);
    .profiles as $profiles
    | ($switches.sessions[$session] // null) as $mine
    | (if $session != "" and ($mine | live) then
        {profile: $mine.profile, why: "turned on for this session", until: ($mine.until // 0), scope: "session"}
      elif ($switches.computer | live) then
        {profile: $switches.computer.profile, why: "turned on by hand", until: ($switches.computer.until // 0), scope: "computer"}
      else
        ([.rules[] | select(has("folder"))] + [.rules[] | select(has("folder") | not)])
        | map(select(.profile as $p | $profiles | has($p)) | select(holds)) | first
        | if . == null then {profile: "", why: "", until: 0, scope: ""} else {profile, why: why, until: 0, scope: "rule"} end
      end) as $on
    | $on + {
        untilText: (if $on.until > 0 then $on.until | strflocaltime(if $on.until - $now < 86400 then "%H:%M" else "%d/%m %H:%M" end) else "" end),
        parts: (if $on.profile == "" or $on.profile == "none" then {} else $profiles[$on.profile] end
          | map_values(if .mode == "only" then .keep = [.only // [] | .[] | if . == "@here" then $top else . end
              | sub("/+$"; "") | split("/") | last | low] else . end)),
        here: {path: $top, name: ($top | split("/") | last)},
        wifi: $wifi
      }'
}

# The end of FOR as epoch seconds: 30m, 2h, 1d from now, or the next HH:MM.
until_of() {
  local for=$1 now
  now=$(date +%s)
  # Only digits reach the arithmetic: bash would run a $(...) hidden in an array index there.
  case "$for" in
    [0-9]*[mhd]) case "${for%?}" in *[!0-9]*) return 1 ;; esac ;;
    *[!0-9:]* | '') return 1 ;;
  esac
  case "$for" in
    *m) echo $((now + ${for%m} * 60)) ;;
    *h) echo $((now + ${for%h} * 3600)) ;;
    *d) echo $((now + ${for%d} * 86400)) ;;
    [0-9]:[0-5][0-9] | [01][0-9]:[0-5][0-9] | 2[0-3]:[0-5][0-9])
      jq -n --argjson now "$now" --arg at "$for" '
        ($now | localtime) as $t | ($at | split(":") | map(tonumber)) as [$h, $m]
        | ($t | .[3] = $h | .[4] = $m | .[5] = 0 | mktime) as $then
        | ($t | .[5] |= floor | mktime) as $nowlocal
        | $now + ($then - $nowlocal) | if . <= $now then . + 86400 else . end'
      ;;
    *) return 1 ;;
  esac
}

# skill_script SKILL SCRIPT: the kit skill's script beside this one, else in ~/.claude/skills.
skill_script() {
  local s
  for s in "$SK/../$1/$2" "$HOME/.claude/skills/$1/$2"; do
    if [ -f "$s" ]; then
      echo "$s"
      return 0
    fi
  done
  return 1
}

# known PART: the names PART lists now (repos of the PRs pr-watch tracks, reminder groups and
# folders, handoff repos), offered in the checklist.
known() {
  local script
  case "$1" in
    prs)
      cat "$SYNC"/pr-watch/*.json 2> /dev/null | jq -r 'select(type == "object") | .url // empty' 2> /dev/null |
        sed -E 's#^https?://github\.com/([^/]+/[^/]+)/pull/.*#\1#; s#^https?://dev\.azure\.com/[^/]+/([^/]+)/_git/([^/]+)/.*#\1/\2#'
      ;;
    reminders)
      script=$(skill_script reminders reminders.sh) &&
        bash "$script" json 2> /dev/null | jq -r '.[] | .group // (.where // "" | split("/") | last) | select(. != null and . != "")' 2> /dev/null
      ;;
    handoffs)
      script=$(skill_script handoff handoff.sh) &&
        bash "$script" json 2> /dev/null | jq -r '.[] | .repo // empty | split("/") | last' 2> /dev/null
      ;;
  esac
  return 0
}

# workspaces: every repo and folder worked in, offered in each checklist beside what the parts list
# now: the config sync's repos (owner/repo, an Azure DevOps one project/repo) and folders, and the
# git repos in the dev folder ($CLAUDE_DEV_ROOT, else ~/dev) and one level under it, worktrees
# left out. One name per repo: the panes match on its last part.
workspaces() {
  local dev=${CLAUDE_DEV_ROOT:-$HOME/dev} d
  {
    if [ -d "$SYNC/repos" ]; then
      (
        cd "$SYNC/repos" || exit 0
        for d in */*/*/ */*/*/_git/*/; do
          [ -d "$d" ] || continue
          d=${d%/}
          case "$d" in
            */_git/*) printf '%s\n' "$(basename "$(dirname "$(dirname "$d")")")/$(basename "$d")" ;;
            dev.azure.com/*) ;;
            *) printf '%s\n' "${d#*/}" ;;
          esac
        done
      )
    fi
    for d in "$SYNC"/folders/*/; do [ -d "$d" ] && basename "$d"; done
    for d in "$dev"/*/.git "$dev"/*/*/.git; do [ -d "$d" ] && basename "$(dirname "$d")"; done
  } | awk '{ last = tolower($0); sub(/.*\//, "", last) } !seen[last]++'
  return 0
}

# A checklist on the terminal, the keys of the kit's installer: what PROFILE shows of each part.
edit() {
  local profile=$1 cur=0 key rest i line mark names candidates
  (: < /dev/tty) 2> /dev/null || die "dnd.sh edit needs a terminal; use dnd.sh set instead."
  has_profile "$profile" || save '.profiles[$p] = {}' --arg p "$profile"
  local -a row=() kind=() part=() name=()
  for p in $PARTS; do
    row+=("$p") kind+=(part) part+=("$p") name+=("")
    [ "$p" = history ] && continue
    names=$(profiles | jq -r --arg p "$profile" --arg part "$p" '.profiles[$p][$part].only // [] | .[]')
    candidates=$({
      echo "@here"
      printf '%s\n' "$names"
      known "$p"
      workspaces
    } | grep -v '^$' | awk '!seen[tolower($0)]++')
    while IFS= read -r one; do row+=("$one") kind+=(name) part+=("$p") name+=("$one"); done <<< "$candidates"
    row+=("+ another name") kind+=(add) part+=("$p") name+=("")
  done
  row+=(save) kind+=(save) part+=("") name+=("")

  mode_of() { profiles | jq -r --arg p "$profile" --arg part "$1" '.profiles[$p][$part].mode // "show"'; }
  picked() { profiles | jq -e --arg p "$profile" --arg part "$1" --arg n "$2" '.profiles[$p][$part].only // [] | index($n) != null' > /dev/null; }
  title() { case "$1" in history) echo History ;; prs) echo "PRs & CI" ;; reminders) echo Reminders ;; handoffs) echo Handoffs ;; esac; }

  draw() {
    {
      printf '\033[H\033[2J\033[1mWhat "%s" shows\033[0m  ↑↓ move · Enter/Space change · q quit\033[K\n\033[K\n' "$profile"
      for ((i = 0; i < ${#row[@]}; i++)); do
        case "${kind[i]}" in
          part)
            local mode
            mode=$(mode_of "${part[i]}")
            case "$mode" in show) mark="everything" ;; hide) mark="hidden" ;; only) mark="only the ones picked below" ;; esac
            line="$(title "${part[i]}"): $mark"
            ;;
          name)
            [ "$(mode_of "${part[i]}")" = only ] || continue
            if picked "${part[i]}" "${name[i]}"; then mark='[x]'; else mark='[ ]'; fi
            line="    $mark ${name[i]}"
            [ "${name[i]}" = "@here" ] && line="$line (the folder of the session)"
            ;;
          add)
            [ "$(mode_of "${part[i]}")" = only ] || continue
            line="    ${row[i]}"
            ;;
          save) line="[ Done ]" && printf '\033[K\n' ;;
        esac
        if [ "$i" = "$cur" ]; then printf '\033[7m%s\033[0m\033[K\n' "$line"; elif [ "${kind[i]}" = part ]; then printf '\033[1m%s\033[0m\033[K\n' "$line"; else printf '%s\033[K\n' "$line"; fi
      done
    } > /dev/tty
  }

  # Rows of a part shown as "everything" or "hidden" are skipped by the arrows.
  visible() { [ "${kind[$1]}" = part ] || [ "${kind[$1]}" = save ] || [ "$(mode_of "${part[$1]}")" = only ]; }
  step() {
    local next=$((cur + $1))
    while [ "$next" -ge 0 ] && [ "$next" -lt ${#row[@]} ] && ! visible "$next"; do next=$((next + $1)); done
    [ "$next" -ge 0 ] && [ "$next" -lt ${#row[@]} ] && cur=$next
    return 0
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
      'esc[A' | k) step -1 ;;
      'esc[B' | j) step 1 ;;
      '' | ' ')
        case "${kind[cur]}" in
          part)
            local p=${part[cur]} next
            case "$(mode_of "$p"):$p" in
              show:*) next=hide ;;
              hide:history) next=show ;;
              hide:*) next=only ;;
              *) next=show ;;
            esac
            save '.profiles[$p][$part] = ((.profiles[$p][$part] // {}) + {mode: $m})' --arg p "$profile" --arg part "$p" --arg m "$next"
            ;;
          name)
            save '.profiles[$p][$part].only = ((.profiles[$p][$part].only // []) | if index($n) then map(select(. != $n)) else . + [$n] end)' \
              --arg p "$profile" --arg part "${part[cur]}" --arg n "${name[cur]}"
            ;;
          add)
            printf '\033[?25h' > /dev/tty
            printf '\n  Name (a repo, a group or a folder): ' > /dev/tty
            IFS= read -r line < /dev/tty || line=""
            printf '\033[?25l' > /dev/tty
            if [ -n "$line" ]; then
              save '.profiles[$p][$part].only = ((.profiles[$p][$part].only // []) - [$n] + [$n])' --arg p "$profile" --arg part "${part[cur]}" --arg n "$line"
              row=("${row[@]:0:cur}" "$line" "${row[@]:cur}") kind=("${kind[@]:0:cur}" name "${kind[@]:cur}")
              part=("${part[@]:0:cur}" "${part[cur]}" "${part[@]:cur}") name=("${name[@]:0:cur}" "$line" "${name[@]:cur}")
            fi
            ;;
          save) break ;;
        esac
        ;;
      q | esc) break ;;
    esac
  done
  printf '\033[?25h\033[?1049l' > /dev/tty
  trap - EXIT INT
  echo "Saved \"$profile\" in $FILE."
}

SESSION=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --session)
      SESSION=${2:-}
      shift 2 || shift
      ;;
    --session=*)
      SESSION=${1#*=}
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
set -- ${args[@]+"${args[@]}"}

case "${1:-}" in
  active) active "${2:-$PWD}" ;;
  known) known "${2:-}" | grep -v '^$' | awk '!seen[tolower($0)]++' ;;
  json)
    known_all=$(for p in prs reminders handoffs; do known "$p" | grep -v '^$' | awk '!seen[tolower($0)]++' | jq -R . | jq -s --arg p "$p" '{($p): .}'; done | jq -s add)
    workspaces_all=$(workspaces | grep -v '^$' | awk '!seen[tolower($0)]++' | jq -R . | jq -s .)
    profiles | jq --argjson active "$(active "${2:-$PWD}")" --argjson switch "$(switch)" --arg file "$FILE" --argjson known "$known_all" \
      --argjson workspaces "$workspaces_all" --arg wifi "$(wifi_cached)" \
      '{profiles, rules, switch: $switch, active: $active, known: $known, workspaces: $workspaces, wifi: $wifi, file: $file}'
    ;;
  list)
    profiles | jq -r '
      "Profiles:", (.profiles | to_entries[] | "  \(.key): " + ([.value | to_entries[]
        | "\(.key) \(.value.mode // "show")" + (if (.value.mode // "") == "only" then " " + (.value.only // [] | join(", ")) else "" end)]
        | if length == 0 then "everything" else join("; ") end)),
      "Rules:", (.rules | to_entries[] | "  \(.key + 1). \(.value.profile) when " + (.value | del(.profile) | to_entries | map("\(.key)=\(.value)") | join(" ")))'
    printf 'On now: %s\n' "$(active "$PWD" | jq -r 'if .profile == "" then "nothing" else .profile + " (" + .why + (if .untilText != "" then ", until " + .untilText else "" end) + ")" end')"
    ;;
  on)
    profile=${2:-}
    [ -n "$profile" ] || die "Usage: dnd.sh on PROFILE [30m|2h|1d|HH:MM]"
    [ "$profile" = none ] || has_profile "$profile" || die "No profile named $profile (see dnd.sh list)."
    until=0
    if [ -n "${3:-}" ]; then until=$(until_of "$3") || die "Unknown length: $3 (30m, 2h, 1d or HH:MM)"; fi
    set_switch "$profile" "$until"
    active "$PWD" | jq -r --arg s "$SESSION" '"On" + (if $s != "" then " for this session" else " for this computer" end) + ": " + .profile + (if .untilText != "" then " until " + .untilText else "" end)'
    ;;
  off)
    set_switch "" 0
    active "$PWD" | jq -r 'if .profile == "" then "Off: nothing is hidden." else "Now on: " + .profile + " (" + .why + ")" end'
    ;;
  set)
    [ $# -ge 4 ] || die "Usage: dnd.sh set PROFILE PART show|hide|only [NAME...]"
    profile=$2 part=$3 mode=$4
    shift 4
    [ "$profile" != none ] || die "none is kept for showing everything."
    case " $PARTS " in *" $part "*) ;; *) die "Unknown part: $part ($PARTS)" ;; esac
    case "$mode" in show | hide) ;; only) [ "$part" != history ] || die "The history is shown or hidden, not filtered." ;; *) die "Unknown mode: $mode (show, hide, only)" ;; esac
    save '.profiles[$p][$part] = ({mode: $m} + (if $m == "only" then {only: ($names | map(if . == "here" then "@here" else . end))} else {} end))' \
      --arg p "$profile" --arg part "$part" --arg m "$mode" --argjson names "$(jq -n '$ARGS.positional' --args "$@")"
    ;;
  delete)
    has_profile "${2:-}" || die "No profile named ${2:-} (see dnd.sh list)."
    save 'del(.profiles[$p]) | .rules |= map(select(.profile != $p))' --arg p "$2"
    ;;
  rule)
    profile=${2:-}
    has_profile "$profile" || die "No profile named $profile (see dnd.sh list)."
    shift 2
    [ $# -gt 0 ] || die "Usage: dnd.sh rule PROFILE wifi=NAME folder=PATH days=sat,sun from=HH:MM to=HH:MM"
    for pair in "$@"; do
      case "${pair%%=*}" in wifi | folder | days | from | to) ;; *) die "Unknown key: ${pair%%=*} (wifi, folder, days, from, to)" ;; esac
    done
    save '.rules += [{profile: $p} + ($pairs | map(index("=") as $i | {(.[:$i]): .[$i + 1:]}) | add)]' --arg p "$profile" \
      --argjson pairs "$(jq -n '$ARGS.positional' --args "$@")"
    ;;
  unrule)
    case "${2:-}" in '' | *[!0-9]*) die "Usage: dnd.sh unrule N" ;; esac
    profiles | jq -e --argjson n "$2" '$n >= 1 and $n <= (.rules | length)' > /dev/null || die "No rule $2 (see dnd.sh list)."
    save 'del(.rules[$n - 1])' --argjson n "$2"
    ;;
  edit)
    [ -n "${2:-}" ] && [ "$2" != none ] || die "Usage: dnd.sh edit PROFILE"
    edit "$2"
    ;;
  wifi) wifi_refresh ;;
  *)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    exit 1
    ;;
esac
