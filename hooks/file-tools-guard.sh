#!/bin/bash
# PreToolUse (Bash) hook: deny shell workarounds for reading or writing files.
set -u
input=$(cat)
# A command with none of the words below can't match a rule: it leaves before jq, a process on
# every Bash call.
words='sed|<<|cat|tee|python|head|tail|less|more'
[[ "$input" =~ $words ]] || exit 0
. "$(dirname "$0")/lib/jq.sh"
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

if [[ "$cmd" =~ (^|[\;\&]+)[[:space:]]*sed[[:space:]]+-i ]]; then
  deny "sed -i is not allowed: use the Edit tool."
fi
noredir=${cmd//[0-9]>/}
noredir=${noredir//&>/}
if [[ "$cmd" =~ \<\<-?[[:space:]]*[\'\"]?[A-Za-z_]+ ]] || [[ "$noredir" =~ (^|[\;\&\|]+)[[:space:]]*(cat|tee)[[:space:]]+[^|\;]*\> ]]; then
  deny "Heredocs / cat > file are not allowed: use the Write or Edit tool."
fi
if [[ "$cmd" =~ (^|[\;\&\|]+)[[:space:]]*python3?[[:space:]]+-c ]]; then
  deny "python -c is not allowed for file changes: use the Edit/Write tool (or a script file)."
fi
if [[ "$cmd" =~ (^|[\;\&]+)[[:space:]]*sed[[:space:]]+-n ]]; then
  deny "sed -n is not allowed for reading: use the Read tool (offset/limit)."
fi
if [[ ! "$cmd" =~ \| ]] && [[ "$cmd" =~ (^|[\;\&]+)[[:space:]]*(cat|head|tail|less|more)[[:space:]] ]]; then
  deny "Reading files with cat/head/tail is not allowed: use the Read tool."
fi
exit 0
