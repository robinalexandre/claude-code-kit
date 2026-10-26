#!/bin/bash
# Keeps the portable part of ~/.claude in sync with this git repo.
#   start    SessionStart hook: reports open handoffs and sync errors, then syncs in the background
#   bg       Stop / SessionEnd hook: syncs in the background; on Windows, says when syncs keep failing
#   now      syncs right away and says what happened
#   fresh    syncs and waits for it, unless a sync already succeeded today
#   morning  the scheduled daily run: syncs, then runs each ~/.claude/skills/*/morning.sh
#   poll     asks the remote whether main moved; syncs only when it did (panes call it every minute)
#   status   shows this machine's sync state
#   install  first run on a machine: backs up ~/.claude, then copies the repo's config into it
#   init     first run ever: copies this machine's config into an empty repo
#   crypt    encrypted folders (git-crypt): crypt status | on <folder>… | export <key file> | unlock <key file>
set -u

SYNC=${SYNC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
STATE="$SYNC/.state"
# Git Bash on Windows sometimes fails to start a process ("add_item ... failed"), which stops a sync
# halfway or before it begins. There a failed sync is tried again, a background sync that never
# finishes is noticed, and the user hears of it in the session only when it keeps failing.
case "${OSTYPE:-}" in msys* | cygwin*) RETRIES=${SYNC_RETRIES:-2} ;; *) RETRIES=${SYNC_RETRIES:-0} ;; esac
RETRY_SEC=${SYNC_RETRY_SEC:-5}
PENDING_MIN=15

spawn() {
  mkdir -p "$STATE"
  [ "$RETRIES" -eq 0 ] || [ -f "$STATE/pending" ] || : > "$STATE/pending"
  (nohup bash "$SYNC/sync.sh" run "${1:-}" >> "$STATE/log" 2>&1 < /dev/null &)
}

# tell: prints a Stop hook's systemMessage, once per problem, when the last sync failed every try
# or no background sync has finished for PENDING_MIN minutes.
tell() {
  local key msg
  [ "$RETRIES" -gt 0 ] || return 0
  if [ -f "$STATE/error" ]; then
    key=$(cat "$STATE/error")
    msg="failed $((RETRIES + 1)) times in a row: $key"
  elif [ -f "$STATE/pending" ] && [ -n "$(find "$STATE/pending" -mmin +"$PENDING_MIN" 2> /dev/null)" ] &&
    { [ ! -d "$STATE/lock" ] || [ -n "$(find "$STATE/lock" -maxdepth 0 -mmin +3 2> /dev/null)" ]; }; then
    key=pending
    msg="has not finished a background sync for $PENDING_MIN minutes (Git Bash may have failed to start it); it keeps trying, see bash ~/.claude-sync/sync.sh status"
  else
    rm -f "$STATE/told"
    return 0
  fi
  [ "$(cat "$STATE/told" 2> /dev/null)" = "$key" ] && return 0
  printf '%s\n' "$key" > "$STATE/told"
  msg=$(printf '%s' "⚠️ Claude config sync $msg" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\t' '  ')
  printf '{"systemMessage": "%s"}\n' "$msg"
}

case "${1:-}" in
  bg)
    # Runs after every reply, so it hands off before any setup.
    input=""
    [ -t 0 ] || input=$(cat)
    # Only a Stop hook's message reaches the user; at SessionEnd it would be lost.
    [[ $input =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"Stop\" ]] && tell
    spawn
    exit 0
    ;;
  fresh)
    [ "$(cat "$STATE/fresh-day" 2> /dev/null)" = "$(date +%Y-%m-%d)" ] && exit 0
    ;;
  poll)
    # One light request before any setup, one check per POLL_EVERY_SEC for the whole computer
    # (every open session asks): a sync runs only when another computer pushed, and pulls without
    # the forced scans. Each caller gets `head <commit>` so it notices a pull another session made.
    POLL_EVERY_SEC=50
    mkdir -p "$STATE"
    now=$(date +%s)
    last=$(cat "$STATE/poll-at" 2> /dev/null)
    known=$(git -C "$SYNC" rev-parse -q --verify refs/remotes/origin/main 2> /dev/null)
    if [ $((now - ${last:-0})) -lt "$POLL_EVERY_SEC" ]; then
      echo "head $known"
      exit 0
    fi
    echo "$now" > "$STATE/poll-at"
    remote=$(GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=10 \
      git -C "$SYNC" ls-remote origin refs/heads/main 2> /dev/null | cut -f1)
    if [ -z "$remote" ] || [ "$remote" = "$known" ]; then
      echo "head $known"
      exit 0
    fi
    echo "main moved: syncing"
    bash "$SYNC/sync.sh" run pull
    echo "head $(git -C "$SYNC" rev-parse -q --verify refs/remotes/origin/main 2> /dev/null)"
    exit 0
    ;;
esac
case "${1:-}" in
  # A pull can rewrite sync.sh while bash is still reading it, so the commands
  # that pull run from a private copy.
  run | now | install | fresh | morning)
    if [ -z "${SYNC_DIR:-}" ]; then
      mkdir -p "$SYNC/.state"
      find "$SYNC/.state" -maxdepth 1 -name 'run-*.sh' -mmin +60 -exec rm -f {} + 2> /dev/null
      cp "$SYNC/sync.sh" "$SYNC/.state/run-$$.sh" && SYNC_DIR=$SYNC exec bash "$SYNC/.state/run-$$.sh" "$@"
    fi
    case "${BASH_SOURCE[0]}" in */.state/run-*.sh) rm -f "${BASH_SOURCE[0]}" 2> /dev/null ;; esac
    ;;
esac

CLAUDE="$HOME/.claude"
CLAUDE_JSON="$HOME/.claude.json"
PATHS="CLAUDE.md statusline-command.sh keybindings.json reminders.json hooks mods skills agents commands output-styles"
AGENT_FILES="CLAUDE.md CLAUDE.local.md AGENTS.md .mcp.json"
MAX_FILE_KB=1024
PRUNE=(-name node_modules -o -name .build -o -name DerivedData -o -name Pods -o -name .venv -o -name vendor -o -name dist -o -name build)
FETCH_EVERY_MIN=2
SCAN_EVERY_MIN=2
NET_TIMEOUT=20
MAX_DELETES=10
MCP_RETRY_MIN=60
SECRET_RE='sk-ant-[A-Za-z0-9_-]{20,}|xkeysib-[A-Za-z0-9-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
# A quick case-insensitive search that finds at least everything redact_str and
# redact_keys would replace, so files without a match skip jq.
BROAD_RE='-----begin [a-z ]*private key|sk-ant-|xkeysib-|gh[pousr]_|github_pat_|akia[0-9a-z]{16}|eyj[a-z0-9_-]{10,}\.|(sk|pk|rk)_(live|test)_|xox[abprs]-|aiza|://[^/[:space:]:@]+:[^@[:space:]/]+@|authorization *:|(bearer|basic|token) +[a-z0-9._~+/=-]{8}|sshpass +-p|(password|passwd|pass|pwd|passphrase|token|secret|api[_-]?key|apikey|access[_-]?key|private[_-]?key|client[_-]?secret|credentials?)"? *[=:]|"[^"]*(key|token|secret|pass|pwd|auth|cred|cookie|session|private)[^"]*" *:'
export GIT_TERMINAL_PROMPT=0
. "$SYNC/jq.sh"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    PATH="/usr/bin:$PATH"
    HOME_FWD=$(cygpath -m "$HOME")
    native_path() { cygpath -w "$1"; }
    unix_path() { cygpath -u "$1"; }
    # Claude Code keys ~/.claude.json projects by folder; match its spelling of this one.
    project_key() {
      local m
      m=$(cygpath -m "$1")
      claude_json | jq -r --arg m "$m" \
        '[(.projects // {}) | keys[] | select(ascii_downcase | gsub("\\\\"; "/") == ($m | ascii_downcase))][0] // $m'
    }
    ;;
  *)
    HOME_FWD=$HOME
    native_path() { printf '%s' "$1"; }
    unix_path() { printf '%s' "$1"; }
    project_key() { (cd "$1" && pwd -P); }
    ;;
esac

cd "$SYNC" || exit 1
mkdir -p "$STATE"
MACHINE=$(tr -d '[:space:]' < .machine 2>/dev/null)
if [ -z "$MACHINE" ] || [ ! -f "machines/$MACHINE.json" ]; then
  echo "sync: unknown machine; run install.sh first" >&2
  exit 1
fi
MCONF="machines/$MACHINE.json"
EXCLUDES=$(jq -r '.exclude[]?' "$MCONF")
MCP_EXCLUDE=$(jq -c '.mcpExclude // []' "$MCONF")
DEV_DIR=$(jq -r '.devDir // "~/dev"' "$MCONF")
DEV_DIR=${DEV_DIR/#\~/$HOME}
# memory_dir DIR: where Claude Code keeps the memory of sessions started in DIR.
memory_dir() { printf '%s/projects/%s/memory' "$CLAUDE" "$(native_path "$1" | sed 's/[^A-Za-z0-9]/-/g')"; }
MEMORY=$(memory_dir "$DEV_DIR")
CHANGED=0
MCP_FAILED=""
KEPT=""

# Settings are stored with __HOME__ in place of the home folder, split into
# settings.shared.json and the machine's "settings" overlay.
# merge: overlay wins on scalars, arrays are unioned. unmerge undoes it, keeping
# the shared values the overlay hides.
# Secrets are stored as __SECRET__: redact for MCP servers, redact_any for repo
# and folder JSON files. fill and fill_any put this machine's own values back.
JQ_LIB='
def at($k): if type == "object" then .[$k] else null end;
def container: type == "object" or type == "array";
def merge($o):
  if type == "object" and ($o | type) == "object" then
    reduce ($o | keys_unsorted[]) as $k (.; .[$k] = (if has($k) then .[$k] | merge($o[$k]) else $o[$k] end))
  elif type == "array" and ($o | type) == "array" then . + ($o - .)
  else $o end;
def unmerge($o; $old):
  if type == "object" and ($o | type) == "object" then
    . as $cur
    | reduce keys_unsorted[] as $k ({};
        $cur[$k] as $v | ($o | at($k)) as $ov | ($old | at($k)) as $pv
        | if ($o | has($k)) | not then .[$k] = $v
          elif ($v | type) == ($ov | type) and ($v | container) then
            ($v | unmerge($ov; $pv)) as $nv
            | if ($nv | length) == 0 and $pv == null then . else .[$k] = $nv end
          elif $pv != null then .[$k] = $pv
          else . end)
  elif type == "array" and ($o | type) == "array" then
    map(. as $x | select((any($o[]; . == $x) | not) or ($old | type == "array" and any(.[]; . == $x))))
  else . end;
def render($h): walk(if type == "string" then split("__HOME__") | join($h) else . end);
def unrender($h): walk(if type == "string" then split($h) | join("__HOME__") else . end);
def secret_name: test("key|token|secret|pass|pwd|auth|cred|cookie|session|private"; "i");
# Masking fails closed: a value after a secret-looking name is replaced unless
# it is plainly not one — a reference ($VAR, <x>, {{x}}, %x%), a function call,
# a type annotation (_TOKEN: list[str] = [], secret: str = ""), an ENV_VAR_NAME,
# a shell default (${X_TOKEN:-}), or a YAML/HTTP keyword. The name may end an
# identifier after `_` or a camelCase hump (db_password, accessToken), never
# mid-word.
def ref: "(?:\\$|<[^>\\s]+>|\\{\\{|%\\w+%)";
def not_value: "(?!" + ref + ")(?!-?\\})(?![A-Za-z_][A-Za-z0-9_.]*[(\\[])(?![A-Za-z_][A-Za-z0-9_.]* +=(?!=))(?![A-Z][A-Z0-9]*_[A-Z0-9_]*(?![A-Za-z0-9]))(?!(?i:write|read|none|no-check|true|false|null|required|optional)(?![^\\s\"\\x27,;)]))";
def redact_str:
  gsub("sk-ant-[A-Za-z0-9_-]{20,}|xkeysib-[A-Za-z0-9-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]+|(sk|pk|rk)_(live|test)_[A-Za-z0-9]{16,}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[A-Za-z0-9_-]{30,}"; "__SECRET__")
  | gsub("(?<p>[A-Za-z][A-Za-z0-9+.-]*://[^/\\s:@]+:)(?!\\$\\{?\\w+\\}?@|<[^>]+>@|\\{\\{)[^@\\s/]+@"; "\(.p)__SECRET__@")
  | gsub("(?<p>(?i:authorization) *: *(?:(?i:bearer|basic|token|digest) +)?)(?!" + ref + ")[A-Za-z0-9._~+/=-]{8,}"; "\(.p)__SECRET__")
  | gsub("(?<p>(?<![A-Za-z0-9_])(Bearer|Basic|Token) +)(?!" + ref + ")[A-Za-z0-9._~+/=-]{8,}"; "\(.p)__SECRET__")
  | gsub("(?<p>sshpass +-p *[\"\\x27]?)(?!\\$)[^\\s\"\\x27]+"; "\(.p)__SECRET__")
  | gsub("(?<p>(?:(?<![A-Za-z0-9])|(?<=[a-z])(?=[A-Z]))(?i:password|passwd|pass|pwd|passphrase|token|secret|api[_-]?key|apikey|access[_-]?key|private[_-]?key|client[_-]?secret|credentials?)[\"\\x27]? *[=:] *[\"\\x27]?)" + not_value + "[^\\s&\"\\x27`),;]+"; "\(.p)__SECRET__");
# Values of secret-looking keys, except references like $VAR, <placeholder>, {{x}}.
def redact_keys:
  walk(if type == "object" then
    with_entries(if (.key | secret_name) and (.value | type) == "string" and .value != "" and (.value | test("^[$<{%]") | not)
      then .value = "__SECRET__" else . end)
  else . end);
def redact_args:
  . as $a
  | [range(length) as $i | $a[$i]
     | if type != "string" then .
       elif test("^--?[A-Za-z0-9_-]+=") and (sub("=.*"; "") | secret_name) then sub("=.*"; "=__SECRET__")
       elif $i > 0 and ($a[$i - 1] | type == "string" and test("^--?[A-Za-z0-9_-]+$") and secret_name) then "__SECRET__"
       else . end];
def redact:
  (if (.headers | type) == "object" then .headers |= map_values("__SECRET__") else . end)
  | (if (.env | type) == "object" then .env |= with_entries(if .key | secret_name then .value = "__SECRET__" else . end) else . end)
  | (if (.url | type) == "string" then .url |= gsub("(?<p>[?&][^=&#]*(key|token|secret|auth|sig|pass)[^=&#]*=)[^&#]*"; "\(.p)__SECRET__"; "i") else . end)
  | (if (.args | type) == "array" then .args |= redact_args else . end)
  | redact_keys
  | walk(if type == "string" then redact_str else . end);
def origin: (capture("^(?<o>[A-Za-z][A-Za-z0-9+.-]*://[^/?#]*)") | .o) // .;
def fill($loc):
  if ($loc | type) != "object" then .
  elif .command != $loc.command or ((.url // "") | origin) != (($loc.url // "") | origin) then .
  else ($loc | redact) as $r
    | reduce paths(type == "string" and contains("__SECRET__")) as $p (.;
        if (try ($r | getpath($p)) catch null) == getpath($p) then setpath($p; $loc | getpath($p)) else . end)
  end;
def redact_settings: redact_keys | walk(if type == "string" then redact_str else . end);
def fill_settings($loc):
  if ($loc | type) != "object" then .
  else ($loc | redact_settings) as $r
    | ([$loc | .. | strings | {key: redact_str, value: .} | select(.key != .value and .key != "__SECRET__")] | from_entries) as $m
    | reduce paths(. == "__SECRET__") as $p (.;
        if (try ($r | getpath($p)) catch null) == "__SECRET__" then setpath($p; $loc | getpath($p)) else . end)
    | walk(if type == "string" and contains("__SECRET__") and . != "__SECRET__" then ($m[.] // .) else . end)
  end;
def redact_any:
  redact_settings
  | if (.mcpServers | type) == "object" then .mcpServers |= map_values(if type == "object" then redact else . end) else . end;
def fill_any($loc):
  (if (.mcpServers | type) == "object" then .mcpServers |= with_entries(.key as $k | .value |= fill($loc | at("mcpServers") | at($k))) else . end)
  | fill_settings($loc);
def text_redact: split("\n") | map(redact_str) | join("\n");
# Puts back each line whose redaction matches a line of $loc, in order when
# several lines of $loc redact the same way. Fails rather than drop a line of
# $loc that holds a secret.
def text_fill($loc):
  ($loc | split("\n")) as $ll
  | (reduce ($ll[] | {key: redact_str, value: .} | select(.key != .value)) as $e ({}; .[$e.key] += [$e.value])) as $m
  | (reduce (split("\n")[]) as $l ({out: [], used: {}};
      if ($l | contains("__SECRET__")) and $m[$l] != null then
        (.used[$l] // 0) as $i
        | .out += [$m[$l][$i] // $m[$l][-1]]
        | .used[$l] = $i + 1
      else .out += [$l] end)
    | .out) as $out
  | if any($ll[]; redact_str != . and (. as $s | $out | index([$s])) == null) then error("a secret line would be lost")
    else $out | join("\n") end;
def servers($p): (if $p == "" then .mcpServers else ((.projects // {})[$p] // {}).mcpServers end) // {};
def without($names): with_entries(select(.key as $k | any($names[]; . == $k) | not));
def only($obj): with_entries(select(.key as $k | $obj | has($k)));
'

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$MACHINE" "$*" >> "$STATE/log"; }
say() { [ -n "${VERBOSE:-}" ] && echo "$*"; log "$*"; return 0; }
fail() {
  printf '%s\n' "$*" > "$STATE/error"
  log "error: $*"
  [ -n "${VERBOSE:-}" ] && echo "sync failed: $*" >&2
  return 1
}
warn() {
  printf '%s\n' "$*" > "$STATE/warn"
  log "warning: $*"
  [ -n "${VERBOSE:-}" ] && echo "warning: $*" >&2
  return 0
}

claude_json() { if [ -f "$CLAUDE_JSON" ]; then cat "$CLAUDE_JSON"; else echo '{}'; fi; }

ignored() {
  local p
  case "$1" in
    skills/synced | skills/synced/* | */.claude-plugin/types/* | *node_modules/* | .DS_Store | */.DS_Store | *.bak | *.backup.* | *.tmp) return 0 ;;
  esac
  for p in $EXCLUDES; do
    case "$1" in "$p" | "$p"/*) return 0 ;; esac
  done
  return 1
}

# files_in ROOT "PATHS": synced files under ROOT, relative and sorted.
files_in() {
  local f
  [ -d "$1" ] || return 0
  (
    cd "$1" || exit 0
    for f in $2; do
      [ -e "$f" ] && find "$f" -type f
    done
  ) | while IFS= read -r f; do
    f=${f#./}
    ignored "$f" || printf '%s\n' "$f"
  done | LC_ALL=C sort
}

# mirror capture|apply SRC DST "PATHS" [MAX_DELETES]: makes the synced files
# under DST match SRC. Capturing replaces secrets (view); applying puts this
# machine's own values back (write_local).
mirror() {
  local mode=$1 src=$2 dst=$3 want have gone f count rc special cipher=""
  [ "$mode" = capture ] && crypt_folders | grep -qxF -- "$dst" && cipher=1
  want=$(files_in "$src" "$4")
  have=$(files_in "$dst" "$4")
  gone=$(LC_ALL=C comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$have") | grep -v '^$')
  count=$(printf '%s' "$gone" | grep -c .)
  if [ "$count" -gt "${5:-$MAX_DELETES}" ]; then
    fail "refusing to delete $count files in $dst at once; run: bash ~/.claude-sync/sync.sh now"
    return 1
  fi
  # The few files that may hold a secret, found with one search. Nothing to search when SRC has
  # none of the files, which may not even exist yet (a second computer's first memory).
  if [ -z "$want" ]; then
    special=""
  elif [ "$mode" = capture ]; then
    special=$(cd "$src" && printf '%s\n' "$want" | grep . | tr '\n' '\0' | LC_ALL=C xargs -0 grep -laiE -e "$BROAD_RE" -- 2> /dev/null)
  else
    special=$(cd "$src" && printf '%s\n' "$want" | grep . | tr '\n' '\0' | xargs -0 grep -l __SECRET__ -- 2> /dev/null)
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -n "$cipher" ] && is_cipher "$src/$f" && continue
    if grep -qxF -- "$f" <<< "$special"; then
      if [ "$mode" = capture ]; then
        view "$src/$f"
        rc=$?
        if [ "$rc" -eq 2 ]; then
          [ -f "$STATE/kept/$dst/$f" ] || log "kept $src/$f on this machine: it may hold a secret that can't be replaced"
          mkdir -p "$(dirname "$STATE/kept/$dst/$f")" && touch "$STATE/kept/$dst/$f"
          continue
        fi
        rm -f "$STATE/kept/$dst/$f"
        [ "$rc" -eq 0 ] || {
          fail "could not read $src/$f"
          return 1
        }
        if grep -q __SECRET__ "$STATE/view"; then
          cmp -s "$STATE/view" "$dst/$f" && continue
          mkdir -p "$(dirname "$dst/$f")" && cp "$STATE/view" "$dst/$f" && CHANGED=$((CHANGED + 1))
          continue
        fi
      else
        write_local "$src/$f" "$dst/$f"
        rc=$?
        [ "$rc" -eq 3 ] && KEPT="$KEPT $dst/$f"
        [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || return 1
        continue
      fi
    fi
    cmp -s "$src/$f" "$dst/$f" && continue
    mkdir -p "$(dirname "$dst/$f")" && cp -p "$src/$f" "$dst/$f" && CHANGED=$((CHANGED + 1))
  done <<< "$want"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rm -f "$dst/$f" && CHANGED=$((CHANGED + 1))
    (cd "$dst" && rmdir -p "$(dirname "$f")" 2> /dev/null)
  done <<< "$gone"
  return 0
}

# replace_json TARGET NEW: moves NEW over TARGET unless they hold the same JSON.
replace_json() {
  if [ -f "$1" ] && [ "$(jq -S . "$1" 2> /dev/null)" = "$(jq -S . "$2")" ]; then
    rm -f "$2"
  else
    cp "$2" "$1" && rm -f "$2" && CHANGED=$((CHANGED + 1))
  fi
}

capture_settings() {
  [ -f "$CLAUDE/settings.json" ] || return 0
  [ -f settings.shared.json ] || echo '{}' > settings.shared.json
  jq --arg h "$HOME_FWD" --slurpfile m "$MCONF" --slurpfile old settings.shared.json \
    "$JQ_LIB del(.env.CLAUDE_DEV_ROOT) | if .env == {} then del(.env) else . end | unrender(\$h) | unmerge(\$m[0].settings // {}; \$old[0]) | redact_settings" \
    "$CLAUDE/settings.json" > "$STATE/shared.json" || {
    fail "~/.claude/settings.json is not valid JSON"
    return 1
  }
  replace_json settings.shared.json "$STATE/shared.json"
}

apply_settings() {
  local loc=/dev/null
  jq empty "$CLAUDE/settings.json" > /dev/null 2>&1 && loc="$CLAUDE/settings.json"
  jq -n --arg h "$HOME_FWD" --arg dev "$DEV_DIR" --slurpfile s settings.shared.json --slurpfile m "$MCONF" --slurpfile loc "$loc" \
    "$JQ_LIB \$s[0] | merge(\$m[0].settings // {}) | fill_any(\$loc[0] | unrender(\$h)) | render(\$h) | .env.CLAUDE_DEV_ROOT = \$dev" \
    > "$STATE/settings.json" || {
    fail "could not build settings.json"
    return 1
  }
  mkdir -p "$CLAUDE"
  replace_json "$CLAUDE/settings.json" "$STATE/settings.json"
}

# MCP servers. Those for all projects are in mcp/, a project's own ones in
# repos/<id>/mcp/, one file per server so two machines changing different
# servers never conflict. A seen file holds the servers as last synced here, so
# a server missing on one side reads as a deletion only if it was there before.

# local_mcp [PROJECT_KEY]: this machine's servers, redacted, as they would be shared.
local_mcp() {
  claude_json | jq --arg h "$HOME_FWD" --argjson x "$MCP_EXCLUDE" --arg p "${1:-}" \
    "$JQ_LIB servers(\$p) | with_entries(select(.key | test(\"^[A-Za-z0-9._-]+\$\"))) | unrender(\$h) | map_values(redact) | without(\$x)"
}

# shared_mcp DIR: the servers stored in DIR, as one JSON object.
shared_mcp() {
  if ls "$1"/*.json > /dev/null 2>&1; then
    jq -n 'reduce inputs as $s ({}; .[input_filename | sub("^.*/"; "") | sub("\\.json$"; "")] = $s)' "$1"/*.json
  else
    echo '{}'
  fi
}

# write_mcp MAP DIR: makes DIR hold exactly the servers in the JSON file MAP.
write_mcp() {
  local name f
  [ -d "$2" ] || [ "$(jq length "$1")" -gt 0 ] || return 0
  mkdir -p "$2"
  for name in $(jq -r 'keys[]' "$1"); do
    jq --arg k "$name" '.[$k]' "$1" > "$STATE/server.json" && replace_json "$2/$name.json" "$STATE/server.json"
  done
  for f in "$2"/*.json; do
    [ -f "$f" ] || continue
    name=${f##*/}
    jq -e --arg k "${name%.json}" 'has($k)' "$1" > /dev/null || { rm -f "$f" && CHANGED=$((CHANGED + 1)); }
  done
  rmdir -p "$2" 2> /dev/null
  return 0
}

# capture_mcp DIR SEEN [PROJECT_KEY]
capture_mcp() {
  local dir=$1 seen=$2
  [ -f "$CLAUDE_JSON" ] || return 0
  [ -f "$seen" ] || { mkdir -p "$(dirname "$seen")" && echo '{}' > "$seen"; }
  local_mcp "${3:-}" > "$STATE/mcp-local.json" || {
    fail "~/.claude.json is not valid JSON"
    return 1
  }
  shared_mcp "$dir" > "$STATE/mcp-old.json" &&
    jq -n --slurpfile cur "$STATE/mcp-local.json" --slurpfile old "$STATE/mcp-old.json" --slurpfile seen "$seen" '
      $cur[0] as $c | $seen[0] as $s
      | reduce ($c | keys_unsorted[]) as $k ($old[0]; if $s[$k] != $c[$k] then .[$k] = $c[$k] else . end)
      | reduce ($s | keys_unsorted[]) as $k (.; if $c | has($k) then . else del(.[$k]) end)' \
      > "$STATE/mcp-new.json" || {
    fail "could not read the synced MCP servers in ~/.claude-sync/$dir"
    return 1
  }
  write_mcp "$STATE/mcp-new.json" "$dir"
  mv "$STATE/mcp-local.json" "$seen"
}

# Git Bash would rewrite /paths inside the JSON argument without MSYS2_ARG_CONV_EXCL.
mcp_cli() {
  timed 60 env -u CLAUDECODE MSYS2_ARG_CONV_EXCL='*' claude mcp "$@" >> "$STATE/log" 2>&1 < /dev/null
}

# A failed claude CLI call is retried after MCP_RETRY_MIN, or at once when
# something new came in or the run was asked for.
mcp_due() {
  [ -n "${MCP_NOW:-}" ] || [ ! -f "$STATE/mcp-failed" ] ||
    [ -n "$(find "$STATE/mcp-failed" -mmin +"$MCP_RETRY_MIN" 2> /dev/null)" ]
}

# apply_mcp DIR SEEN [PROJECT_KEY PROJECT_DIR]: adds or updates the servers of DIR
# in ~/.claude.json through the claude CLI. A server deleted on another machine
# stays here until removed here too.
apply_mcp() {
  local dir=$1 seen=$2 key=${3:-} cwd=${4:-.} scope=user ops op name
  [ -d "$dir" ] || return 0
  [ -n "$key" ] && scope=local
  [ -f "$seen" ] || { mkdir -p "$(dirname "$seen")" && echo '{}' > "$seen"; }
  shared_mcp "$dir" > "$STATE/mcp-want.json" || {
    fail "could not read the synced MCP servers in ~/.claude-sync/$dir"
    return 1
  }
  ops=$(claude_json | jq -c --arg h "$HOME_FWD" --argjson x "$MCP_EXCLUDE" --arg p "$key" \
    --slurpfile want "$STATE/mcp-want.json" "$JQ_LIB"'
      servers($p) as $loc
      | $want[0] | without($x) | to_entries[]
      | .key as $k
      | (.value | fill($loc[$k] | unrender($h)) | render($h)) as $v
      | select($loc[$k] != $v)
      | {name: $k, server: $v, old: $loc[$k]}') || {
    fail "could not read ~/.claude.json"
    return 1
  }
  if [ -n "$ops" ] && mcp_due; then
    if ! command -v claude > /dev/null; then
      MCP_NOCLI=1
    else
      while IFS= read -r op; do
        name=$(jq -r .name <<< "$op")
        if jq -e '.old != null' <<< "$op" > /dev/null; then (cd "$cwd" && mcp_cli remove "$name" -s "$scope"); fi
        if (cd "$cwd" && mcp_cli add-json "$name" "$(jq -c .server <<< "$op")" -s "$scope"); then
          CHANGED=$((CHANGED + 1))
          MCP_TRIED=1
          say "MCP server $name added or updated${key:+ in $cwd}"
        else
          MCP_FAILED="$MCP_FAILED $name"
          if jq -e '.old != null' <<< "$op" > /dev/null; then
            (cd "$cwd" && mcp_cli add-json "$name" "$(jq -c .old <<< "$op")" -s "$scope")
          fi
        fi
      done <<< "$ops"
    fi
  fi
  local_mcp "$key" | jq --slurpfile want "$STATE/mcp-want.json" --slurpfile seen "$seen" \
    "$JQ_LIB only(\$want[0] + \$seen[0])" > "$seen.tmp" && mv "$seen.tmp" "$seen"
}

# Sets or clears the warning shown at session start. Each part stays until
# its check runs again: the MCP one when the CLI is tried, KEPT on a scan.
report() {
  local msg
  if [ -n "${MCP_NOCLI:-}" ]; then
    echo "MCP servers from the other machine(s) were not added: the claude command is not on PATH" > "$STATE/mcp-warn"
    touch "$STATE/mcp-failed"
  elif [ -n "$MCP_FAILED" ]; then
    echo "could not add MCP server(s):$MCP_FAILED; see bash ~/.claude-sync/sync.sh status" > "$STATE/mcp-warn"
    touch "$STATE/mcp-failed"
  elif [ -n "${MCP_TRIED:-}" ] || [ -n "${MCP_NOW:-}" ]; then
    rm -f "$STATE/mcp-warn" "$STATE/mcp-failed"
  fi
  if [ -n "$KEPT" ]; then
    echo "these files differ from the copy another machine shared, so they stay out of the sync until one of the two is deleted or they match:$KEPT" > "$STATE/kept-warn"
  elif [ -n "${SCANNED:-}" ]; then
    rm -f "$STATE/kept-warn"
  fi
  msg=$(cat "$STATE/mcp-warn" "$STATE/kept-warn" 2> /dev/null | paste -sd ';' - | sed 's/;/; /g')
  if [ -n "$msg" ]; then warn "$msg"; else rm -f "$STATE/warn"; fi
}

# Agent config that no repo's git tracks: AGENT_FILES, everything in .claude/,
# nested CLAUDE.md and AGENTS.md, and a project's own MCP servers.
#   repos/<id>/   for each repo in the dev folder, id being the origin URL
#                 without protocol, user or .git, e.g. github.com/owner/name
#   folders/      for the dev folder and the folders in it that aren't repos
# A seen copy in .state holds each file as last synced here, so a file unchanged
# here never overwrites a newer version from another machine.

# A repo's first commit is the same in every clone of it. repos/<id>/root keeps
# it, so a different repo that happens to have the same origin URL gets nothing.
root_of() { git -C "$1" rev-list --max-parents=0 HEAD 2> /dev/null | LC_ALL=C sort | head -1; }
same_root() { [ -n "$2" ] && { [ ! -f "repos/$1/root" ] || [ "$(tr -d '[:space:]' < "repos/$1/root")" = "$2" ]; }; }

# repo_line DIR: "<id> <root> <path>" for the repo checked out at DIR.
repo_line() {
  local id root
  id=$(git -C "$1" remote get-url origin 2> /dev/null |
    sed -E 's#^[A-Za-z+]+://##; s#^[^@/]*@##; s#:#/#; s#\.git/*$##; s#/+$##' | tr 'A-Z' 'a-z')
  case "$id" in "" | *..* | /* | *' '*) return 0 ;; esac
  root=$(root_of "$1")
  if same_root "$id" "$root"; then printf '%s %s %s\n' "$id" "$root" "$1"; fi
}

# repos: "<id> <root> <path>" for each main checkout (not worktrees) under the dev folder.
repos() {
  local g
  [ -d "$DEV_DIR" ] || return 0
  find "$DEV_DIR" -maxdepth 4 \( "${PRUNE[@]}" \) -prune -o -name .git -type d -print 2> /dev/null |
    while IFS= read -r g; do repo_line "${g%/.git}"; done | LC_ALL=C sort | awk '!seen[$1]++'
}

tracked() { git -C "$1" ls-files --error-unmatch -- "$2" > /dev/null 2>&1; }
in_repo() { git -C "$1" rev-parse --is-inside-work-tree > /dev/null 2>&1; }

agent_junk() {
  case "$1" in
    .claude/worktrees/* | */.claude/worktrees/* | .DS_Store | */.DS_Store | *.log | *node_modules/* | *.swp | *~) return 0 ;;
  esac
  return 1
}

# repo_files DIR: the agent files of the repo at DIR that its git doesn't track.
repo_files() {
  (
    cd "$1" || exit 0
    {
      for f in $AGENT_FILES; do [ -f "$f" ] && echo "$f"; done
      [ -d .claude ] && find .claude -path .claude/worktrees -prune -o -type f -print
      git ls-files -o --exclude-standard -- ':(glob)**/CLAUDE.md' ':(glob)**/CLAUDE.local.md' ':(glob)**/AGENTS.md'
    } | LC_ALL=C sort -u | LC_ALL=C comm -23 - <(git ls-files -- $AGENT_FILES .claude | LC_ALL=C sort)
  ) | while IFS= read -r f; do agent_junk "$f" || printf '%s\n' "$f"; done
}

# folder_files: the agent files of the dev folder and of the folders in it that
# aren't inside a repo, relative to the dev folder.
folder_files() {
  local p
  [ -d "$DEV_DIR" ] || return 0
  find "$DEV_DIR" -maxdepth 4 \( "${PRUNE[@]}" \) -prune -o \( -name CLAUDE.md -o -name CLAUDE.local.md \
    -o -name AGENTS.md -o -name .mcp.json \) -type f -print -o -name .claude -type d -print 2> /dev/null |
    while IFS= read -r p; do
      [ "$p" = "$CLAUDE" ] && continue
      in_repo "$(dirname "$p")" && continue
      if [ -d "$p" ]; then find "$p" -path "$p/worktrees" -prune -o -type f -print; else printf '%s\n' "$p"; fi
    done | while IFS= read -r p; do
      p=${p#"$DEV_DIR"/}
      agent_junk "$p" || printf '%s\n' "$p"
    done
}

is_json() { case "$1" in *.json) jq empty "$1" > /dev/null 2>&1 ;; *) return 1 ;; esac; }
is_text() { LC_ALL=C grep -qI . "$1" 2> /dev/null; }

# view FILE: writes FILE as it would be shared to $STATE/view, secrets replaced.
# Returns 2 when it must stay on this machine: too big, a secret is left, or it
# may hold one but can't be redacted (not valid JSON or UTF-8 text). Never
# falls back to the raw file.
view() {
  ! is_cipher "$1" || return 2
  [ "$(wc -c < "$1")" -le $((MAX_FILE_KB * 1024)) ] || return 2
  if is_json "$1"; then
    jq --arg h "$HOME_FWD" "$JQ_LIB unrender(\$h) | redact_any" "$1" > "$STATE/view" 2> /dev/null || return 2
  elif LC_ALL=C grep -aiqE -e "$BROAD_RE" -- "$1"; then
    is_text "$1" && iconv -f UTF-8 -t UTF-8 "$1" > /dev/null 2>&1 &&
      jq -R -s -r -j "$JQ_LIB text_redact" "$1" > "$STATE/view" 2> /dev/null || return 2
  else
    cp "$1" "$STATE/view" || return 1
  fi
  ! grep -qE "$SECRET_RE" "$STATE/view" || return 2
}

# capture_file LOCAL SHARED SEEN
capture_file() {
  local rc kept="$STATE/kept/${3#"$STATE"/}"
  # After both sides changed, apply_file decides, deleting included.
  [ -f "$STATE/conflict/${3#"$STATE"/}" ] && return 0
  if [ ! -f "$1" ]; then
    if [ -f "$3" ]; then
      rm -f "$2" "$3" && CHANGED=$((CHANGED + 1))
      rmdir -p "$(dirname "$2")" 2> /dev/null
    fi
    return 0
  fi
  is_cipher "$1" && return 0
  # The first time here, apply_file decides between this file and the shared one.
  [ ! -f "$3" ] && [ -f "$2" ] && return 0
  view "$1"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    [ -f "$kept" ] || log "kept $1 on this machine: it looks like it holds a secret, or is over $MAX_FILE_KB KB"
    mkdir -p "$(dirname "$kept")" && touch "$kept"
    return 0
  fi
  [ "$rc" -eq 0 ] || {
    fail "could not read $1"
    return 1
  }
  rm -f "$kept"
  [ -f "$3" ] && cmp -s "$STATE/view" "$3" && return 0
  mkdir -p "$(dirname "$2")" "$(dirname "$3")"
  cmp -s "$STATE/view" "$2" || { cp "$STATE/view" "$2" && CHANGED=$((CHANGED + 1)); }
  cp "$STATE/view" "$3"
}

# write_local SHARED LOCAL: puts SHARED in place, with this machine's secrets.
# Returns 3 when that would lose one of them.
write_local() {
  if is_json "$1" && is_json "$2"; then
    jq --arg h "$HOME_FWD" --slurpfile loc "$2" "$JQ_LIB fill_any(\$loc[0] | unrender(\$h)) | render(\$h)" "$1"
  elif is_json "$1"; then
    jq --arg h "$HOME_FWD" "$JQ_LIB render(\$h)" "$1"
  elif [ -f "$2" ] && is_text "$2" && is_text "$1"; then
    jq -R -s -r -j --rawfile loc "$2" "$JQ_LIB text_fill(\$loc)" "$1" 2> /dev/null || return 3
  else
    cat "$1"
  fi > "$STATE/out" || {
    fail "could not apply ~/.claude-sync/$1 to $2"
    return 1
  }
  if [ -f "$2" ]; then
    if is_json "$2"; then
      [ "$(jq -S . "$2")" = "$(jq -S . "$STATE/out")" ] && return 0
    else
      cmp -s "$2" "$STATE/out" && return 0
    fi
  fi
  mkdir -p "$(dirname "$2")" && cp "$STATE/out" "$2" && CHANGED=$((CHANGED + 1)) && say "updated $2"
}

# apply_file SHARED LOCAL SEEN
apply_file() {
  local base=/dev/null conflict="$STATE/conflict/${3#"$STATE"/}"
  [ -f "$1" ] || return 0
  [ -f "$3" ] && [ -f "$2" ] && ! is_cipher "$2" && cmp -s "$1" "$3" && return 0
  if [ -f "$2" ] && ! is_cipher "$2"; then
    # This machine's file changed too since the last sync (or this is the
    # first sync here): JSON merges both sides; other files that differ stay
    # apart, and out of the sync, until one of them is deleted.
    view "$2" || {
      KEPT="$KEPT $2"
      return 0
    }
    [ -f "$3" ] && base=$3
    if ! cmp -s "$STATE/view" "$1" && ! cmp -s "$STATE/view" "$base"; then
      if is_json "$1" && jq empty "$STATE/view" > /dev/null 2>&1; then
        cp "$1" "$STATE/merged" && bash "$SYNC/json-merge.sh" "$base" "$STATE/merged" "$STATE/view" &&
          replace_json "$1" "$STATE/merged"
      else
        KEPT="$KEPT $2"
        mkdir -p "$(dirname "$conflict")" && touch "$conflict"
        return 0
      fi
    fi
  fi
  write_local "$1" "$2"
  case $? in
    0) ;;
    3)
      KEPT="$KEPT $2"
      mkdir -p "$(dirname "$conflict")" && touch "$conflict"
      return 0
      ;;
    *) return 1 ;;
  esac
  rm -f "$conflict"
  mkdir -p "$(dirname "$3")" && cp "$1" "$3"
}

# seen_files DIR: the files under DIR, relative to it.
seen_files() { [ -d "$1" ] && (cd "$1" && find . -type f | sed 's#^\./##'); }

capture_repos() {
  local id r f key seen mcp_keys root
  mcp_keys=$(claude_json | jq -r '(.projects // {}) | to_entries[] | select((.value.mcpServers // {}) | length > 0) | .key')
  while read -r id root r; do
    while IFS= read -r f; do
      if tracked "$r" "$f"; then
        # Now in the repo itself, so it travels with it.
        rm -f "repos/$id/$f" "$STATE/repo-seen/$id/$f"
        continue
      fi
      capture_file "$r/$f" "repos/$id/$f" "$STATE/repo-seen/$id/$f" || return 1
    done < <({ repo_files "$r"; seen_files "$STATE/repo-seen/$id"; } | LC_ALL=C sort -u)
    key=$(project_key "$r")
    seen="$STATE/mcp-seen/$id.json"
    if [ -d "repos/$id/mcp" ] || grep -qxF -- "$key" <<< "$mcp_keys" || { [ -f "$seen" ] && ! grep -qx '{}' "$seen"; }; then
      capture_mcp "repos/$id/mcp" "$seen" "$key" || return 1
    fi
    if [ -d "repos/$id" ] && [ ! -f "repos/$id/root" ]; then
      printf '%s\n' "$root" > "repos/$id/root" && CHANGED=$((CHANGED + 1))
    fi
  done < <(repos)
}

apply_repos() {
  local id root r f seen
  while read -r id root r; do
    [ -f "repos/$id/root" ] || continue
    while IFS= read -r f; do
      seen="$STATE/repo-seen/$id/$f"
      [ -f "$seen" ] && [ -f "$r/$f" ] && ! is_cipher "$r/$f" && cmp -s "repos/$id/$f" "$seen" && continue
      tracked "$r" "$f" && continue
      apply_file "repos/$id/$f" "$r/$f" "$seen" || return 1
    done < <(cd "repos/$id" && find . \( -path ./mcp -o -path ./root \) -prune -o -type f -print | sed 's#^\./##')
    apply_mcp "repos/$id/mcp" "$STATE/mcp-seen/$id.json" "$(project_key "$r")" "$r" || return 1
  done < <(repos)
}

capture_folders() {
  local f
  while IFS= read -r f; do
    capture_file "$DEV_DIR/$f" "folders/$f" "$STATE/folder-seen/$f" || return 1
  done < <({ folder_files; seen_files "$STATE/folder-seen"; } | LC_ALL=C sort -u)
}

# A folder's files land only where that folder exists and isn't a repo.
apply_folders() {
  local f owner seen
  [ -d folders ] || return 0
  while IFS= read -r f; do
    seen="$STATE/folder-seen/$f"
    [ -f "$seen" ] && [ -f "$DEV_DIR/$f" ] && ! is_cipher "$DEV_DIR/$f" && cmp -s "folders/$f" "$seen" && continue
    case "$f" in
      .claude/*) owner=. ;;
      */.claude/*) owner=${f%%/.claude/*} ;;
      */*) owner=${f%/*} ;;
      *) owner=. ;;
    esac
    case "$DEV_DIR/$f" in "$CLAUDE"/*) continue ;; esac
    [ -d "$DEV_DIR/$owner" ] || continue
    in_repo "$DEV_DIR/$owner" && continue
    apply_file "folders/$f" "$DEV_DIR/$f" "$seen" || return 1
  done < <(seen_files folders)
}

# The memory of sessions started in a repo or folder of the dev folder (the dev
# folder's own is memory/), a flat folder of notes, found through the projects
# Claude Code lists in ~/.claude.json:
#   memory-repos/<id>/       a repo's, id as in repos/
#   memory-folders/<path>/   a folder's that isn't in a repo, path relative to the dev folder
# Files merge like the repo and folder ones, with seen copies in .state/seen/.

flat_files() { [ -d "$1" ] && (cd "$1" && find . -maxdepth 1 -type f | sed 's#^\./##' | while IFS= read -r f; do agent_junk "$f" || printf '%s\n' "$f"; done); }

# local_memories: "<synced folder>\t<path>" for each folder under the dev folder that has a memory here.
local_memories() {
  local p line
  claude_json | jq -r '(.projects // {}) | keys[]' | while IFS= read -r p; do
    p=$(unix_path "$p")
    case "$p" in "$DEV_DIR"/*) ;; *) continue ;; esac
    [ -d "$(memory_dir "$p")" ] || continue
    if [ -d "$p/.git" ]; then
      line=$(repo_line "$p")
      [ -n "$line" ] && printf 'memory-repos/%s\t%s\n' "${line%% *}" "$p"
    elif ! in_repo "$p"; then
      printf 'memory-folders/%s\t%s\n' "${p#"$DEV_DIR"/}" "$p"
    fi
  done
}

capture_memories() {
  local dst p m f
  while IFS=$'\t' read -r dst p; do
    crypt_skip "${dst%%/*}" && continue
    m=$(memory_dir "$p")
    while IFS= read -r f; do
      capture_file "$m/$f" "$dst/$f" "$STATE/seen/$dst/$f" || return 1
    done < <({ flat_files "$m"; flat_files "$STATE/seen/$dst"; } | LC_ALL=C sort -u)
  done < <(local_memories)
}

# apply_memory SYNCED DIR: puts the synced memory of DIR in place.
apply_memory() {
  local m f seen
  m=$(memory_dir "$2")
  while IFS= read -r f; do
    seen="$STATE/seen/$1/$f"
    [ -f "$seen" ] && [ -f "$m/$f" ] && ! is_cipher "$m/$f" && cmp -s "$1/$f" "$seen" && continue
    apply_file "$1/$f" "$m/$f" "$seen" || return 1
  done < <(flat_files "$1")
}

apply_memories() {
  local id root r d
  if ! crypt_skip memory-repos; then
    while read -r id root r; do
      [ -d "memory-repos/$id" ] && { apply_memory "memory-repos/$id" "$r" || return 1; }
    done < <(repos)
  fi
  [ -d memory-folders ] && ! crypt_skip memory-folders || return 0
  while IFS= read -r d; do
    d=${d#memory-folders/}
    [ -d "$DEV_DIR/$d" ] || continue
    in_repo "$DEV_DIR/$d" && continue
    apply_memory "memory-folders/$d" "$DEV_DIR/$d" || return 1
  done < <(find memory-folders -type f | sed 's#/[^/]*$##' | LC_ALL=C sort -u)
}

# Repos and folders are scanned at most every SCAN_EVERY_MIN, or at once when
# something came in or the run was asked for.
scan_due() {
  [ -n "${SCAN_NOW:-}" ] || [ ! -f "$STATE/scanned" ] ||
    [ -n "$(find "$STATE/scanned" -mmin +"$SCAN_EVERY_MIN" 2> /dev/null)" ]
}

# --- Encrypted folders (git-crypt) ---------------------------------------------------------
# Personal folders (memory, knowledge notes, an assistant's files…) can be encrypted in the repo
# with git-crypt: a git filter that encrypts at commit and decrypts at checkout, with a key that
# never goes in the repo. Everything after CRYPT_MARK in .gitattributes is the list of encrypted
# folders, kept by `sync.sh crypt`. A computer without the key (or without git-crypt) is locked:
# it sees ciphertext there, so the sync leaves those folders alone (never applies them to
# ~/.claude, never adds to them: git would commit the additions in clear) and says so.
CRYPT_MARK='# encrypted folders (sync.sh crypt): everything below is kept by sync.sh'

crypt_parse() { awk -v m="$CRYPT_MARK" '$0 == m { on = 1; next } on && $2 == "filter=git-crypt" { sub(/\/\*\*$/, "", $1); print $1 }'; }
crypt_folders() { [ ! -f .gitattributes ] || crypt_parse < .gitattributes; }
# crypt_known: the encrypted folders here and on origin/main as last fetched: another computer may
# have encrypted a folder this one has not pulled yet, and nothing of it must be committed in clear.
crypt_known() { { crypt_folders; git show origin/main:.gitattributes 2> /dev/null | crypt_parse; } | LC_ALL=C sort -u; }
crypt_on() { [ -n "$(crypt_folders)" ]; }
crypt_unlocked() { [ -f .git/git-crypt/keys/default ] && [ -n "$(git config --get filter.git-crypt.smudge)" ]; }
crypt_locked() { crypt_on && ! crypt_unlocked; }
# crypt_skip FOLDER: whether the sync must leave FOLDER alone here: encrypted (here or on origin),
# and this computer has no key.
crypt_skip() { ! crypt_unlocked && crypt_known | grep -qxF -- "$1"; }
crypt_told() {
  printf 'has encrypted folders (%s) locked on this computer: they are left alone here until you run bash ~/.claude-sync/sync.sh crypt unlock <key file>' "$(crypt_folders | tr '\n' ' ' | sed 's/ $//')"
}
# is_cipher FILE: whether FILE holds git-crypt ciphertext instead of its content: never shared,
# never committed (git-crypt would encrypt it a second time), and replaced by the clear version.
is_cipher() { [ -f "$1" ] && [ "$(LC_ALL=C head -c 10 "$1" | LC_ALL=C tr -d '\0')" = GITCRYPT ]; }
# blob REV PATH: the file at REV as a checkout writes it, so decrypted where this computer has the
# key. A plain git show gives the ciphertext of an encrypted folder.
blob() { git cat-file --filters "$1:$2"; }
# crypt_checkout: decrypts what git-crypt unlock left as ciphertext, or deleted, when its own
# checkout stopped partway (Windows, out of processes). Unlock wants a clean tree, so these files
# hold nothing but what is committed.
crypt_checkout() {
  local f left=()
  crypt_on || return 0
  while IFS= read -r f; do
    { [ ! -e "$f" ] || is_cipher "$f"; } && left+=("$f")
  done < <(git -c core.quotepath=off ls-files -- $(crypt_folders))
  [ ${#left[@]} -eq 0 ] || git checkout -- "${left[@]}"
}

crypt() {
  local cmd=${1:-status} f
  [ $# -eq 0 ] || shift
  case "$cmd" in
    status)
      if ! crypt_on; then
        echo "encryption: off (bash ~/.claude-sync/sync.sh crypt on <folder>…)"
        return 0
      fi
      echo "encrypted folders: $(crypt_folders | tr '\n' ' ')"
      if crypt_unlocked; then echo "this computer: unlocked"; else echo "this computer: LOCKED, those folders are left alone here (bash ~/.claude-sync/sync.sh crypt unlock <key file>)"; fi
      command -v git-crypt > /dev/null 2>&1 || echo "git-crypt is not installed here"
      ;;
    on)
      command -v git-crypt > /dev/null 2>&1 || {
        echo "git-crypt is not installed: brew install git-crypt, apt install git-crypt, or https://github.com/AGWA/git-crypt/releases"
        return 1
      }
      [ $# -gt 0 ] || {
        echo "usage: sync.sh crypt on <folder>…   (top-level folders of the repo, e.g. memory knowledge)"
        return 2
      }
      lock 60 || {
        echo "another sync is running; try again in a moment"
        return 1
      }
      VERBOSE="" sync_once force > /dev/null 2>&1 || true
      [ -f .git/git-crypt/keys/default ] || git-crypt init > /dev/null || return 1
      grep -qxF -- "$CRYPT_MARK" .gitattributes 2> /dev/null || printf '\n%s\n' "$CRYPT_MARK" >> .gitattributes
      for f in "$@"; do
        f=${f%/}
        case "$f" in "" | .* | */*) echo "  $f: give a top-level folder of the repo"; continue ;; esac
        if crypt_folders | grep -qxF -- "$f"; then
          echo "  $f: already encrypted"
          continue
        fi
        printf '%s/** filter=git-crypt diff=git-crypt\n' "$f" >> .gitattributes
        if [ -d "$f" ]; then
          git rm -r -q --cached -- "$f" > /dev/null 2>&1
          git add -- "$f"
        fi
        echo "  $f: encrypted from now on"
      done
      git add .gitattributes
      git diff --cached --quiet || git -c core.hooksPath=/dev/null commit -qm "chore(sync): encrypt $*" > /dev/null
      remote_sync force || return 1
      echo "The key is in .git/git-crypt/keys/default of this clone only. For your other computers:"
      echo "  bash ~/.claude-sync/sync.sh crypt export ~/claude-sync.key    (keep it in your password manager, never in the repo)"
      echo "  bash ~/.claude-sync/sync.sh crypt unlock <that file>          (on each other computer, once)"
      echo "Earlier commits still hold these files in clear: rewrite the history if that matters."
      ;;
    export)
      [ -n "${1:-}" ] || {
        echo "usage: sync.sh crypt export <key file>"
        return 2
      }
      crypt_unlocked || {
        echo "this computer has no key to export"
        return 1
      }
      git-crypt export-key "$1" && chmod 600 "$1" && echo "key written to $1: keep it in your password manager, never in the repo"
      ;;
    unlock)
      [ -f "${1:-}" ] || {
        echo "usage: sync.sh crypt unlock <key file>"
        return 2
      }
      command -v git-crypt > /dev/null 2>&1 || {
        echo "git-crypt is not installed: brew install git-crypt, apt install git-crypt, or https://github.com/AGWA/git-crypt/releases"
        return 1
      }
      lock 60 || {
        echo "another sync is running; try again in a moment"
        return 1
      }
      git-crypt unlock "$1" || crypt_unlocked || return 1
      crypt_checkout || return 1
      echo "unlocked: the encrypted folders now sync on this computer too"
      sync_once force
      ;;
    *)
      echo "usage: sync.sh crypt status | on <folder>… | export <key file> | unlock <key file>" >&2
      return 2
      ;;
  esac
}

capture() {
  mirror capture "$CLAUDE" claude "$PATHS" || return 1
  if [ -d "$MEMORY" ] && ! crypt_skip memory; then mirror capture "$MEMORY" memory "." || return 1; fi
  capture_settings || return 1
  capture_mcp mcp "$STATE/mcp-seen.json" || return 1
  if scan_due; then
    capture_repos || return 1
    capture_folders || return 1
    capture_memories || return 1
  fi
  # What this computer runs, for the others to see (inventory.sh); never stops a sync.
  [ ! -f "$SYNC/inventory.sh" ] || SYNC_DIR="$SYNC" bash "$SYNC/inventory.sh" write > /dev/null 2>&1 || true
}

apply() {
  mirror apply claude "$CLAUDE" "$PATHS" "${1:-$MAX_DELETES}" || return 1
  if ! crypt_skip memory; then
    mkdir -p "$MEMORY"
    mirror apply memory "$MEMORY" "." "${1:-$MAX_DELETES}" || return 1
  fi
  apply_settings
}

# The commit at which ~/.claude and the memory last matched the repo.
mark_applied() { git rev-parse HEAD > "$STATE/applied"; }

# local_of REPO_PATH: sets LROOT and LREL to where a claude/ or memory/ file of
# the repo lives on this machine; fails when it isn't synced here.
local_of() {
  case "$1" in
    claude/*)
      LROOT=$CLAUDE LREL=${1#claude/}
      case " $PATHS " in *" ${LREL%%/*} "*) ;; *) return 1 ;; esac
      ;;
    memory/*)
      crypt_skip memory && return 1
      LROOT=$MEMORY LREL=${1#memory/}
      ;;
    *) return 1 ;;
  esac
  ! ignored "$LREL"
}

# holds COMMIT REPO_PATH LOCAL: whether LOCAL is what the repo had at COMMIT
# (both missing counts).
holds() {
  local was="$STATE/was"
  case "$2" in *.json) was="$STATE/was.json" ;; esac
  if ! git cat-file -e "$1:$2" 2> /dev/null; then
    [ ! -e "$3" ]
    return
  fi
  [ -f "$3" ] && view "$3" || return 1
  blob "$1" "$2" > "$was" || return 1
  if is_json "$was"; then
    [ "$(jq -S . "$STATE/view")" = "$(jq -S . "$was")" ]
  else
    cmp -s "$STATE/view" "$was"
  fi
}

# pull_in FROM TO: puts on this machine the claude/ and memory/ files that
# changed in the repo between commits FROM and TO. Without it, a change that
# reached the repo some other way than this machine's capture (a rename made
# straight in the repo, an apply refused earlier) would be undone by the next
# capture. A file also changed here keeps this machine's version, with a
# warning; deleted files go to .state/trash.
pull_in() {
  local path both="" trash="$STATE/trash/$(date +%Y%m%d-%H%M%S)"
  [ "$(git rev-parse "$1")" = "$(git rev-parse "$2")" ] && return 0
  while IFS= read -r path; do
    [ -n "$path" ] && local_of "$path" || continue
    if ! is_cipher "$LROOT/$LREL"; then
      holds "$2" "$path" "$LROOT/$LREL" && continue
      if ! holds "$1" "$path" "$LROOT/$LREL"; then
        both="$both $path"
        continue
      fi
    fi
    if git cat-file -e "$2:$path" 2> /dev/null; then
      mkdir -p "$(dirname "$STATE/in/$path")" && blob "$2" "$path" > "$STATE/in/$path" || return 1
      write_local "$STATE/in/$path" "$LROOT/$LREL"
      case $? in 0) ;; 3) both="$both $path" ;; *) return 1 ;; esac
    else
      mkdir -p "$(dirname "$trash/$path")" && mv "$LROOT/$LREL" "$trash/$path" && CHANGED=$((CHANGED + 1))
      (cd "$LROOT" && rmdir -p "$(dirname "$LREL")" 2> /dev/null)
      say "removed $LROOT/$LREL (copy in $trash)"
    fi
  done < <(git -c core.quotepath=off diff --name-only --no-renames "$1" "$2" -- claude memory)
  rm -rf "$STATE/in"
  find "$STATE/trash" -mindepth 1 -maxdepth 1 -mtime +30 -exec rm -rf {} + 2> /dev/null
  [ -z "$both" ] || warn "changed both here and in the repo, this machine's version was kept:$both"
  return 0
}

# Brings in what reached the repo since the last run that matched it, before
# capturing anything.
catch_up() {
  local base
  base=$(cat "$STATE/applied" 2> /dev/null)
  [ -n "$base" ] && git cat-file -e "$base^{commit}" 2> /dev/null || return 0
  pull_in "$base" HEAD
}

# heal_memory: puts back in clear the memory files that hold ciphertext here (left by an older
# engine, or while this computer had no key). The repo and folder memories heal in apply_memories.
heal_memory() {
  local f
  [ -d "$MEMORY" ] && ! crypt_skip memory || return 0
  while IFS= read -r f; do
    is_cipher "$MEMORY/$f" && [ -f "memory/$f" ] && ! is_cipher "memory/$f" || continue
    write_local "memory/$f" "$MEMORY/$f" || return 1
  done < <(files_in "$MEMORY" .)
}

# What needs the claude CLI, a repo or a folder on this machine, so it is
# checked on every run.
apply_local() {
  apply_mcp mcp "$STATE/mcp-seen.json" || return 1
  if scan_due; then
    apply_repos || return 1
    apply_folders || return 1
    apply_memories || return 1
    touch "$STATE/scanned"
    SCANNED=1
  fi
  report
}

commit() {
  local f excl=()
  if ! crypt_unlocked; then
    while IFS= read -r f; do [ -n "$f" ] && excl+=(":(exclude)$f"); done < <(crypt_known)
  fi
  git add -A -- . ${excl[@]+"${excl[@]}"}
  if crypt_on && crypt_unlocked; then
    while IFS= read -r f; do
      is_cipher "$f" || continue
      git reset -q -- "$f"
      warn "left $f out of the commit: it holds ciphertext, it would be encrypted twice (git -C ~/.claude-sync checkout -- \"$f\")"
    done < <(git -c core.quotepath=off diff --cached --name-only --diff-filter=AM -- $(crypt_folders))
  fi
  git diff --cached --quiet && return 0
  if git diff --cached -U0 | grep -E '^\+' | grep -qE "$SECRET_RE"; then
    git reset -q
    fail "a change looks like it holds a secret (token or key), so nothing was synced; see: git -C ~/.claude-sync diff"
    return 1
  fi
  git commit -qm "chore(sync): update from $MACHINE" && say "saved local changes"
}

# timed SECONDS CMD...: runs CMD, killing it after SECONDS.
timed() {
  local secs=$1 pid watcher rc
  shift
  "$@" &
  pid=$!
  (sleep "$secs" && kill "$pid") > /dev/null 2>&1 &
  watcher=$!
  wait "$pid"
  rc=$?
  kill "$watcher" 2> /dev/null
  wait "$watcher" 2> /dev/null
  return $rc
}

has_remote_main() { git rev-parse -q --verify origin/main > /dev/null; }
ahead() { ! has_remote_main || [ -n "$(git rev-list -1 origin/main..HEAD)" ]; }

# JSON files merge by key and array item (json-merge.sh, see .gitattributes).
git_setup() {
  local driver="bash \"$SYNC/json-merge.sh\" %O %A %B"
  [ "$(git config merge.json.driver)" = "$driver" ] || git config merge.json.driver "$driver"
}

remote_sync() {
  local before came
  git remote get-url origin > /dev/null 2>&1 || {
    fail "this repo has no remote yet: git -C ~/.claude-sync remote add origin <your private repo's URL>"
    return 1
  }
  if [ "${1:-}" != force ] && [ "${1:-}" != pull ] && ! ahead && [ -f "$STATE/fetched" ] &&
    [ -z "$(find "$STATE/fetched" -mmin +"$FETCH_EVERY_MIN" 2> /dev/null)" ]; then
    return 0
  fi
  timed "$NET_TIMEOUT" git fetch -q origin || {
    fail "could not reach the sync repo ($(git remote get-url origin | sed -E 's#://[^/@]*@#://#'))"
    return 1
  }
  touch "$STATE/fetched"
  if has_remote_main; then
    before=$(git rev-parse HEAD)
    if ! git rebase -q origin/main > /dev/null 2>&1; then
      git rebase --abort > /dev/null 2>&1
      fail "the same file changed here and on another machine. To fix: in ~/.claude-sync run git rebase origin/main, resolve, git rebase --continue, then bash sync.sh install"
      return 1
    fi
    if [ "$(git rev-parse HEAD)" != "$before" ]; then
      crypt_recommit || return 1
      # The repo scan and the MCP servers cost seconds: done again only for what came in (most
      # pulls bring reminders, handoffs or PR records).
      came=$(git diff --name-only "$before" HEAD)
      grep -q '^mcp/' <<< "$came" && MCP_NOW=1
      grep -qE '^(repos|folders|memory-repos|memory-folders)/' <<< "$came" && SCAN_NOW=1
      pull_in "$before" HEAD || return 1
      apply_settings
      say "applied changes from the other machine(s)"
    fi
  fi
  if ahead; then
    timed "$NET_TIMEOUT" git push -q origin HEAD:main || {
      fail "could not push to the sync repo"
      return 1
    }
    say "pushed to the sync repo"
  fi
  rm -f "$STATE/error"
}

# The pull just brought a folder's encryption this computer did not know of when it committed:
# its own commits may hold files of that folder in clear. They are undone (the files stay on
# disk) and committed again: through the filter now that the attributes are here, or without
# that folder when this computer has no key.
crypt_recommit() {
  local f folders=()
  while IFS= read -r f; do [ -n "$f" ] && folders+=("$f"); done < <(crypt_folders)
  [ ${#folders[@]} -gt 0 ] || return 0
  ahead || return 0
  [ -n "$(git diff --name-only origin/main HEAD -- "${folders[@]}")" ] || return 0
  git reset -q origin/main
  say "undid local commits that would have pushed encrypted folders in clear"
  commit
}

lock() {
  local tries=${1:-0}
  while ! mkdir "$STATE/lock" 2> /dev/null; do
    if [ -n "$(find "$STATE/lock" -maxdepth 0 -mmin +3 2> /dev/null)" ]; then
      rm -rf "$STATE/lock"
      continue
    fi
    [ "$tries" -gt 0 ] || return 1
    tries=$((tries - 1))
    sleep 1
  done
  trap 'rm -rf "$STATE/lock"' EXIT
}

run() {
  lock "${2:-0}" || {
    say "another sync is running"
    return 0
  }
  sync_retry "${1:-}"
}

# sync_retry [force]: sync_once, tried RETRIES more times when it fails.
sync_retry() {
  local try=0
  until sync_once "${1:-}"; do
    [ "$try" -lt "$RETRIES" ] || return 1
    try=$((try + 1))
    say "trying the sync again ($try of $RETRIES)"
    sleep $((try * RETRY_SEC))
    CHANGED=0 MCP_FAILED="" KEPT=""
  done
  rm -f "$STATE/error" "$STATE/pending"
}

# A full sync that callers can wait for (the reminders skill does, in the
# background), skipped once one has succeeded today. Callers starting together
# wait for the same run.
fresh() {
  lock "${1:-60}" || return 0
  [ "$(cat "$STATE/fresh-day" 2> /dev/null)" = "$(date +%Y-%m-%d)" ] && return 0
  sync_retry force
}

morning() {
  local f
  lock 60 || return 0
  sync_retry force
  rm -rf "$STATE/lock"
  {
    for f in "$CLAUDE"/skills/*/morning.sh; do printf '%s\n' "$f"; done
    plugin_mornings
  } | while IFS= read -r f; do
    [ -f "$f" ] || continue
    say "morning: ${f#"$CLAUDE"/}"
    bash "$f" >> "$STATE/log" 2>&1 < /dev/null
  done
  return 0
}

# The morning.sh of each skill installed as a plugin from the claude-code-kit marketplace, unless
# a copy in ~/.claude/skills already runs.
plugin_mornings() {
  local name root
  jq -r '.plugins // {} | to_entries[] | select(.key | endswith("@claude-code-kit"))
    | [(.key | sub("@.*"; "")), ((.value | map(select(.scope == "user")) + .value)[0].installPath // "")] | @tsv' \
    "${CLAUDE_CONFIG_DIR:-$CLAUDE}/plugins/installed_plugins.json" 2> /dev/null |
    while IFS=$'\t' read -r name root; do
      [ -f "$CLAUDE/skills/$name/morning.sh" ] && continue
      command -v cygpath > /dev/null 2>&1 && root=$(cygpath -u "$root")
      [ -f "$root/skills/$name/morning.sh" ] && printf '%s\n' "$root/skills/$name/morning.sh"
    done
  return 0
}

sync_once() {
  if [ -f "$STATE/log" ] && [ "$(wc -c < "$STATE/log")" -gt 200000 ]; then
    tail -n 300 "$STATE/log" > "$STATE/log.tmp" && mv "$STATE/log.tmp" "$STATE/log"
  fi
  [ "${1:-}" = force ] && MCP_NOW=1 SCAN_NOW=1
  git_setup
  catch_up || return 1
  heal_memory || return 1
  capture || return 1
  commit || return 1
  remote_sync "${1:-}" || return 1
  mark_applied
  apply_local || return 1
  if [ "${1:-}" = force ]; then date +%Y-%m-%d > "$STATE/fresh-day"; fi
  if [ "$CHANGED" -eq 0 ] && [ -n "${VERBOSE:-}" ]; then echo "already up to date"; fi
  return 0
}

# frontmatter FILE KEY: prints KEY's value from FILE's YAML front matter.
frontmatter() {
  awk -v k="$2" '{ sub(/\r$/, "") }
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    NR > 1 { i = index($0, ":"); if (substr($0, 1, i - 1) == k) { v = substr($0, i + 1); sub(/^ +/, "", v); print v; exit } }' "$1"
}

start() {
  local notes="" err="" f from
  for f in handoffs/*.md; do
    [ -f "$f" ] || continue
    from=$(frontmatter "$f" from)
    [ "$from" = "$MACHINE" ] && continue
    notes="$notes
- $(frontmatter "$f" date) · from ${from:-?} · $(frontmatter "$f" title) → ~/.claude-sync/$f"
  done
  if [ -f "$STATE/error" ]; then
    err="last failed: $(cat "$STATE/error")"
    cp "$STATE/error" "$STATE/told"
  elif [ -f "$STATE/warn" ]; then
    err="warning: $(cat "$STATE/warn")"
  elif crypt_locked; then
    err=$(crypt_told)
  fi
  rm -f "$STATE/pending"
  spawn force
  [ -n "$notes$err" ] || return 0
  jq -n --arg notes "$notes" --arg err "$err" '
    (if $notes != "" then "Open handoff notes written on another machine. If the user wants to continue one, use the handoff skill." + $notes else "" end) as $ctx
    | (if $err != "" then "The Claude config sync (~/.claude-sync) " + $err else "" end) as $why
    | {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ([$ctx, $why] | map(select(. != "")) | join("\n\n"))}}
    + (if $err != "" then {systemMessage: ("⚠️ Claude config sync " + $err)} else {} end)'
}

status() {
  echo "machine: $MACHINE"
  echo "dev dir: $DEV_DIR ($(repos | wc -l | tr -d ' ') repos)"
  echo "memory:  $MEMORY"
  echo "commit:  $(git log -1 --format='%h %cr: %s')"
  echo "to push: $(git rev-list --count origin/main..HEAD 2> /dev/null || echo 'all') commit(s)"
  if [ -f "$STATE/error" ]; then echo "error:   $(cat "$STATE/error")"; else echo "error:   none"; fi
  if [ -f "$STATE/warn" ]; then echo "warning: $(cat "$STATE/warn")"; fi
  if crypt_on; then echo "crypt:   $(crypt_folders | tr '\n' ' ')($(crypt_unlocked && echo unlocked || echo LOCKED))"; fi
  if [ -f "$STATE/pending" ]; then echo "pending: a background sync has not finished since $(ls -l "$STATE/pending" | awk '{print $6, $7, $8}')"; fi
  [ -f "$STATE/log" ] && { echo "--- last log lines"; tail -n 8 "$STATE/log"; }
  return 0
}

backup() {
  local p id root r f
  BACKUP="$CLAUDE/backups/before-sync-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP"
  for p in $PATHS settings.json; do
    if [ -e "$CLAUDE/$p" ]; then cp -Rp "$CLAUDE/$p" "$BACKUP/"; fi
  done
  if [ -d "$MEMORY" ]; then cp -Rp "$MEMORY" "$BACKUP/memory"; fi
  if [ -f "$CLAUDE_JSON" ]; then cp -p "$CLAUDE_JSON" "$BACKUP/claude.json"; fi
  while read -r id root r; do
    while IFS= read -r f; do
      mkdir -p "$BACKUP/repos/$id/$(dirname "$f")" && cp -p "$r/$f" "$BACKUP/repos/$id/$f"
    done < <(repo_files "$r")
  done < <(repos)
  while IFS= read -r f; do
    mkdir -p "$BACKUP/folders/$(dirname "$f")" && cp -p "$DEV_DIR/$f" "$BACKUP/folders/$f"
  done < <(folder_files)
  while IFS=$'\t' read -r f p; do
    mkdir -p "$BACKUP/$f" && cp -Rp "$(memory_dir "$p")/." "$BACKUP/$f/"
  done < <(local_memories)
}

install() {
  [ -f claude/CLAUDE.md ] || {
    fail "the repo has no config yet (run init on the machine that has it)"
    return 1
  }
  backup
  git_setup
  MCP_NOW=1 SCAN_NOW=1
  apply 1000000 || return 1
  mark_applied
  apply_local || return 1
  say "installed the synced config into $CLAUDE (previous files saved in $BACKUP)"
}

# A hand-made settings.shared.json is kept and settings.json rebuilt from it;
# without one, this machine's settings become the shared ones.
init() {
  [ ! -f claude/CLAUDE.md ] || {
    fail "the repo already has a config; use install"
    return 1
  }
  backup
  git_setup
  mirror capture "$CLAUDE" claude "$PATHS" || return 1
  if [ -d "$MEMORY" ]; then mirror capture "$MEMORY" memory "." || return 1; fi
  if [ -f settings.shared.json ]; then apply_settings; else capture_settings; fi || return 1
  capture_mcp mcp "$STATE/mcp-seen.json" || return 1
  capture_repos || return 1
  capture_folders || return 1
  capture_memories || return 1
  commit
  say "saved this machine's config in the repo (previous files saved in $BACKUP)"
}

case "${1:-}" in
  start)
    [ -t 0 ] || cat > /dev/null
    start
    exit 0
    ;;
  run) run "${2:-}" ;;
  now) VERBOSE=1 run force 60 ;;
  fresh) fresh "${2:-60}" ;;
  morning) morning ;;
  status) status ;;
  install)
    VERBOSE=1
    lock 60 && install
    ;;
  init)
    VERBOSE=1
    lock 60 && init
    ;;
  crypt)
    shift
    crypt "$@"
    ;;
  *)
    echo "usage: sync.sh start|bg|now|fresh|morning|status|install|init|crypt" >&2
    exit 2
    ;;
esac
