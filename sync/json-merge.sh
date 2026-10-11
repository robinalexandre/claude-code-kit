#!/bin/bash
# Git merge driver for this repo's JSON files (see .gitattributes and
# git_setup in sync.sh). Merges by key and by array item, so two machines that
# add settings, permissions or MCP servers at the same time don't conflict.
# When both changed the same value, THEIRS wins: during the sync's rebase that
# is this machine's change.
#   json-merge.sh BASE OURS THEIRS    writes the result to OURS
set -u
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) jq() { command jq -b "$@"; } ;;
esac

base=$1
[ -s "$base" ] || base=/dev/null
jq -n --slurpfile b "$base" --slurpfile o "$2" --slurpfile t "$3" '
  def m3($b; $o; $t):
    if $o == $t then $o
    elif $o == $b then $t
    elif $t == $b then $o
    elif ($o | type) == "object" and ($t | type) == "object" then
      ($b | if type == "object" then . else {} end) as $bb
      | reduce (($o | keys_unsorted) + (($t | keys_unsorted) - ($o | keys_unsorted)))[] as $k ({};
          if ($o | has($k)) and ($t | has($k)) then .[$k] = m3($bb[$k]; $o[$k]; $t[$k])
          elif $o | has($k) then (if ($bb | has($k)) and $bb[$k] == $o[$k] then . else .[$k] = $o[$k] end)
          elif ($bb | has($k)) and $bb[$k] == $t[$k] then .
          else .[$k] = $t[$k] end)
    elif ($o | type) == "array" and ($t | type) == "array" then
      ($b | if type == "array" then . else [] end) as $ba
      | [($o + ($t - $o))[] | . as $x
         | select((any($ba[]; . == $x) | not) or (any($o[]; . == $x) and any($t[]; . == $x)))]
    else $t end;
  m3($b[0]; $o[0]; $t[0])' > "$2.merged" && mv "$2.merged" "$2"
