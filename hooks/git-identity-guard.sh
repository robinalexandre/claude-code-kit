#!/bin/bash
# PreToolUse (Bash) hook: a `git commit` or `git push` goes ahead only when the author and committer
# email is the one the user chose for that remote (GitHub, Azure DevOps, AWS CodeCommit, any host),
# or, with no rule for it, the one they used most in that repo. Otherwise it is refused, with what to
# ask the user.
#   git-identity-guard.sh                    the hook (reads the tool call on stdin)
#   git-identity-guard.sh git-hooks [on|off] git's global pre-commit and pre-push run the same check
#                                            for every commit and push, whoever runs git
#   git-identity-guard.sh pre-push REMOTE URL   that check (git passes the refs on stdin)
#   git-identity-guard.sh pre-commit         the same at commit time, on the identity git will use
#   git-identity-guard.sh set MATCH EMAIL    record the email for remotes starting with MATCH
#                                            (github.com, github.com/<owner>, dev.azure.com/<org>, ...)
#   git-identity-guard.sh unset MATCH        forget a rule
#   git-identity-guard.sh list               the rules
#   git-identity-guard.sh check [DIR]        what a commit in DIR would be checked against
# The rules live in ~/.claude-sync when the sync engine is set up, so every computer applies the
# same; else in ~/.claude/git-identity.json; GIT_IDENTITY_FILE overrides both.
set -u
. "$(dirname "$0")/lib/jq.sh"
SELF="$(cd "$(dirname "$0")" && pwd)/git-identity-guard.sh"
# Where git's hooks find this script for good: ~/.claude for a copy, the plugin's data folder for a plugin.
KIT_HOME=${KIT_HOME:-$(cd "$(dirname "$0")/.." && pwd)}
if [ -n "${GIT_IDENTITY_FILE:-}" ]; then
  RULES=$GIT_IDENTITY_FILE
elif [ -d "$HOME/.claude-sync/.git" ]; then
  RULES="$HOME/.claude-sync/git-identity.json"
else
  RULES="$HOME/.claude/git-identity.json"
fi

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
is_email() { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+$ ]]; }

# One spelling per remote: host/path, lowercase, no scheme, user, port or .git.
normalize() {
  local u=$1
  u=${u%/}
  u=${u%.git}
  case "$u" in
    *://*)
      u=${u#*://}
      [[ "${u%%/*}" == *@* ]] && u=${u#*@}
      local host=${u%%/*} path=${u#*/}
      [ "$host" = "$u" ] && path=""
      u="${host%%:*}/$path"
      ;;
    *@*:*) u=${u#*@}; u="${u%%:*}/${u#*:}" ;;
    *:*) [[ "${u%%:*}" == */* ]] || u="${u%%:*}/${u#*:}" ;;
  esac
  u=$(lower "$u" | tr -cd 'a-z0-9._~/:@+-')
  case "$u" in
    ssh.dev.azure.com/v3/*) u="dev.azure.com/${u#ssh.dev.azure.com/v3/}" ;;
    vs-ssh.visualstudio.com/v3/*) u="dev.azure.com/${u#vs-ssh.visualstudio.com/v3/}" ;;
    *.visualstudio.com/*) u="dev.azure.com/${u%%.visualstudio.com/*}/${u#*.visualstudio.com/}" ;;
  esac
  printf '%s' "${u%/}"
}

# The email of the longest rule the remote starts with, empty when none.
expected_for() {
  [ -f "$RULES" ] || return 0
  jq -r --arg r "$1" '
    [.rules // [] | .[] | select(.match as $m | ($r == $m) or ($r | startswith($m + "/")))]
    | sort_by(.match | length) | last | .email // empty' "$RULES"
}

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# remote_of DIR [NAME]: the remote a commit in DIR goes to: NAME, the branch's upstream, origin, or the first.
remote_of() {
  local dir=$1 name=${2:-} up
  if [ -z "$name" ]; then
    up=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2> /dev/null)
    name=${up%%/*}
  fi
  if [ -z "$name" ] || ! git -C "$dir" remote | grep -qx "$name"; then
    name=$(git -C "$dir" remote | grep -x origin || git -C "$dir" remote | head -1)
  fi
  printf '%s' "$name"
}

unquote() {
  local t=$1
  t=${t#\"}; t=${t%\"}; t=${t#\'}; t=${t%\'}
  printf '%s' "$t"
}

email_in() {
  local t=$1
  [[ "$t" == *\<*\>* ]] && { t=${t#*<}; t=${t%%>*}; }
  printf '%s' "$t"
}

ask_rule() {
  deny "No commit email is recorded for $1. Ask the user which email to commit and push with there (never guess, never use another one), then record it: bash \"$SELF\" set <host or host/owner> <email>, and run the command again."
}

check_call() {
  local dir=$1 sub=$2 env_author=$3 env_committer=$4 author=$6
  shift 6
  git -C "$dir" rev-parse --git-dir > /dev/null 2>&1 || return 0
  local remotes target="" url="" arg
  remotes=$(git -C "$dir" remote)
  [ -n "$remotes" ] || return 0
  local -a refs=()
  if [ "$sub" = push ]; then
    for arg in "$@"; do
      case "$arg" in
        --all | --mirror | --branches) refs+=(--branches) ;;
        -*) ;;
        *)
          if [ -z "$target" ]; then
            target=$arg
          else
            arg=${arg#+}
            arg=${arg%%:*}
            [ -n "$arg" ] && refs+=("$arg")
          fi
          ;;
      esac
    done
  fi
  if [ -n "$target" ] && ! printf '%s\n' "$remotes" | grep -qx "$target"; then
    url=$target
    target=""
  else
    target=$(remote_of "$dir" "$target")
    url=$(git -C "$dir" remote get-url --push "$target" 2> /dev/null)
  fi
  [ -n "$url" ] || return 0
  local where expected
  where=$(normalize "$url")
  resolve "$dir" "$where"
  [ -n "$EXPECTED" ] || ask_rule "$where"
  expected=$EXPECTED
  local fix="Ask the user to confirm $expected ($SOURCE) before changing anything; on their yes, set it for this repo: git -C \"$dir\" config user.email $expected."

  if [ "$sub" = commit ]; then
    # git itself says who the commit would be from, with the command's own -c options and variables.
    local mine committer
    local -a envs=()
    [ -n "$env_author" ] && envs+=("GIT_AUTHOR_EMAIL=$env_author")
    [ -n "$env_committer" ] && envs+=("GIT_COMMITTER_EMAIL=$env_committer")
    mine=$(env ${envs[@]+"${envs[@]}"} git -C "$dir" ${GITC[@]+"${GITC[@]}"} var GIT_AUTHOR_IDENT 2> /dev/null)
    committer=$(env ${envs[@]+"${envs[@]}"} git -C "$dir" ${GITC[@]+"${GITC[@]}"} var GIT_COMMITTER_IDENT 2> /dev/null)
    [ -n "$author" ] && mine=$author
    mine=$(lower "$(email_in "$mine")")
    committer=$(lower "$(email_in "$committer")")
    [ -z "$mine" ] && deny "No git email is set in $dir. The user commits to $where as $expected. $fix"
    [ "$mine" = "$expected" ] && [ "$committer" = "$expected" ] && return 0
    deny "This commit would be authored as ${mine} (committer ${committer}), but the user commits to $where as $expected. $fix"
  fi

  [ ${#refs[@]} -gt 0 ] || refs=(HEAD)
  local not="--remotes"
  [ -n "$target" ] && not="--remotes=$target"
  local wrong
  wrong=$(git -C "$dir" log --format='%h %ae %ce' "${refs[@]}" --not "$not" 2> /dev/null |
    awk -v e="$expected" '{ if (tolower($2) != e || tolower($3) != e) print }' | head -5)
  [ -z "$wrong" ] && return 0
  deny "These commits would be pushed to $where with an email other than $expected ($SOURCE):
$wrong
$fix Rewriting commits needs its own yes (for the last commit not pushed yet: git commit --amend --no-edit --reset-author, after setting the email)."
}

# most_used DIR: the email the user (git's user.name) committed with most in DIR's history, with its count.
most_used() {
  local name
  name=$(lower "$(git -C "$1" config --get user.name 2> /dev/null)")
  [ -n "$name" ] || return 0
  git -C "$1" log --all -n 2000 --format='%an%x09%ae' 2> /dev/null |
    awk -F'\t' -v n="$name" 'tolower($1) == n { c[tolower($2)]++; t++ } END { for (e in c) if (c[e] > best) { best = c[e]; m = e } if (m != "") print m "\t" best "\t" t }'
}

# resolve DIR WHERE: sets EXPECTED (the email to use there, lowercase, empty when unknown) and SOURCE
# (why): the user's rule for the remote first, else the email they used most in this repo.
resolve() {
  local used
  EXPECTED=$(lower "$(expected_for "$2")")
  SOURCE="the email recorded for $2"
  [ -n "$EXPECTED" ] && return 0
  used=$(most_used "$1")
  [ -n "$used" ] || return 0
  EXPECTED=${used%%$'\t'*}
  # The history is the repo's, not the user's: only a plain address may come out of it.
  is_email "$EXPECTED" || { EXPECTED=""; return 0; }
  used=${used#*$'\t'}
  SOURCE="no email is recorded for $2, and the user's commits in this repo use it most: ${used%%$'\t'*} of ${used#*$'\t'}; once confirmed, record it: bash \"$SELF\" set <host or host/org> <email>"
}

# Git's own pre-push hook (git-hooks on): checks every commit the push sends, whoever runs git.
# Stdin: "<local ref> <local sha> <remote ref> <remote sha>" per ref.
pre_push() {
  local remote=$1 url=${2:-$1} where zero=0000000000000000000000000000000000000000 lref lsha rref rsha range wrong=""
  where=$(normalize "$url")
  resolve "$PWD" "$where"
  if [ -z "$EXPECTED" ]; then
    echo "git-identity-guard: no commit email recorded for $where (git-identity-guard.sh set <host> <email>)." >&2
    return 0
  fi
  while read -r lref lsha rref rsha; do
    [ "$lsha" = "$zero" ] && continue
    # Commits already on the remote (another branch, e.g. after a rebase onto develop)
    # are not this push's to vet.
    if [ "$rsha" != "$zero" ] && git remote | grep -qx "$remote"; then
      range="$lsha --not $rsha --remotes=$remote"
    elif [ "$rsha" != "$zero" ]; then
      range="$rsha..$lsha"
    elif git remote | grep -qx "$remote"; then
      range="$lsha --not --remotes=$remote"
    else
      range="$lsha --not --remotes"
    fi
    # shellcheck disable=SC2086
    wrong="$wrong"$'\n'"$(git log --format='%h %ae %ce' $range 2> /dev/null | awk -v e="$EXPECTED" '{ if (tolower($2) != e || tolower($3) != e) print }')"
  done
  [ -z "$(printf '%s' "$wrong" | tr -d '\n')" ] && return 0
  {
    echo "git-identity-guard: these commits use another email than $EXPECTED for $where:"
    printf '%s\n' "$wrong" | grep . | head -10
    echo "Fix the author (git config user.email $EXPECTED, then amend or rebase), or push with --no-verify if this is intended."
  } >&2
  return 1
}

# Git's own pre-commit hook (git-hooks on): the identity git will really use, whatever ran git
# (a wrapper, a script, another agent) and however the email was set.
pre_commit() {
  local r u where author committer
  r=$(remote_of "$PWD")
  [ -n "$r" ] || return 0
  u=$(git remote get-url --push "$r" 2> /dev/null)
  [ -n "$u" ] || return 0
  where=$(normalize "$u")
  resolve "$PWD" "$where"
  [ -n "$EXPECTED" ] || return 0
  author=$(lower "$(email_in "$(git var GIT_AUTHOR_IDENT 2> /dev/null)")")
  committer=$(lower "$(email_in "$(git var GIT_COMMITTER_IDENT 2> /dev/null)")")
  [ "$author" = "$EXPECTED" ] && [ "$committer" = "$EXPECTED" ] && return 0
  echo "git-identity-guard: this commit would be authored as $author (committer $committer), but $where expects $EXPECTED." >&2
  echo "Set it (git config user.email $EXPECTED), or commit with --no-verify if this is intended." >&2
  return 1
}

# git-hooks on|off: points git's global core.hooksPath at a folder whose pre-commit and pre-push run
# the check, and whose every hook runs the repo's own one, so repos keep their hooks.
HOOK_NAMES="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg
post-commit pre-rebase post-checkout post-merge pre-push post-rewrite pre-auto-gc push-to-checkout sendemail-validate"
git_hooks() {
  local dir="$KIT_HOME/hooks/git" name current guard
  guard="\$HOME${KIT_HOME#"$HOME"}/hooks/git-identity-guard.sh"
  case "$KIT_HOME" in "$HOME"/*) ;; *) guard="$KIT_HOME/hooks/git-identity-guard.sh" ;; esac
  # git.exe on Windows reads C:/Users/..., not Git Bash's /c/Users/...
  command -v cygpath > /dev/null 2>&1 && dir=$(cygpath -m "$dir")
  current=$(git config --global --get core.hooksPath)
  if [ "${1:-}" = off ]; then
    [ "$current" = "$dir" ] && git config --global --unset core.hooksPath
    echo "core.hooksPath unset"
    return 0
  fi
  if [ -n "$current" ] && [ "$current" != "$dir" ]; then
    echo "core.hooksPath is already $current: not changed" >&2
    return 1
  fi
  mkdir -p "$dir"
  for name in $HOOK_NAMES; do
    {
      printf '#!/bin/sh\n# Written by git-identity-guard.sh git-hooks on: runs the repo'"'"'s own %s hook.\n' "$name"
      if [ "$name" = pre-push ]; then
        printf 'input=$(cat)\nprintf "%%s\\n" "$input" | bash "%s" pre-push "$@" || exit 1\n' "$guard"
        printf 'own="$(git rev-parse --git-common-dir 2> /dev/null)/hooks/%s"\n[ -x "$own" ] || exit 0\nprintf "%%s\\n" "$input" | "$own" "$@"\n' "$name"
      elif [ "$name" = pre-commit ]; then
        printf 'bash "%s" pre-commit || exit 1\n' "$guard"
        printf 'own="$(git rev-parse --git-common-dir 2> /dev/null)/hooks/%s"\n[ -x "$own" ] && exec "$own" "$@"\nexit 0\n' "$name"
      else
        printf 'own="$(git rev-parse --git-common-dir 2> /dev/null)/hooks/%s"\n[ -x "$own" ] && exec "$own" "$@"\nexit 0\n' "$name"
      fi
    } > "$dir/$name"
    chmod +x "$dir/$name"
  done
  git config --global core.hooksPath "$dir"
  echo "core.hooksPath -> $dir"
}

hook() {
  local input cmd cwd
  input=$(cat)
  # Most commands are no commit or push: they leave before jq, a process on every Bash call.
  [[ "$input" =~ git.*(commit|push) ]] || exit 0
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
  [[ "$cmd" =~ git.*(commit|push) ]] || exit 0
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
  cwd=${cwd:-$PWD}
  local segs dir=$cwd line
  segs=${cmd//&&/$'\n'}
  segs=${segs//||/$'\n'}
  segs=${segs//;/$'\n'}
  segs=${segs//|/$'\n'}
  while IFS= read -r line; do
    local -a t=()
    read -ra t <<< "$line"
    [ ${#t[@]} -gt 0 ] || continue
    if [ "${t[0]}" = cd ] && [ ${#t[@]} -gt 1 ]; then
      local to
      to=$(unquote "${t[1]}")
      to=${to/#\~/$HOME}
      [[ "$to" == /* ]] || [[ "$to" =~ ^[A-Za-z]: ]] || to="$dir/$to"
      dir=$to
      continue
    fi
    local i=0 env_author="" env_committer="" here=$dir
    GITC=()
    while [ $i -lt ${#t[@]} ] && [[ "${t[$i]}" == *=* ]] && [[ "${t[$i]}" != -* ]]; do
      case "${t[$i]}" in
        GIT_AUTHOR_EMAIL=*) env_author=$(unquote "${t[$i]#*=}") ;;
        GIT_COMMITTER_EMAIL=*) env_committer=$(unquote "${t[$i]#*=}") ;;
      esac
      i=$((i + 1))
    done
    [ "${t[$i]:-}" = git ] || continue
    i=$((i + 1))
    while [ $i -lt ${#t[@]} ] && [[ "${t[$i]}" == -* ]]; do
      case "${t[$i]}" in
        -C) i=$((i + 1)); here=$(unquote "${t[$i]:-}"); here=${here/#\~/$HOME}; [[ "$here" == /* ]] || [[ "$here" =~ ^[A-Za-z]: ]] || here="$dir/$here" ;;
        -c) i=$((i + 1)); GITC+=(-c "$(unquote "${t[$i]:-}")") ;;
      esac
      i=$((i + 1))
    done
    local sub=${t[$i]:-}
    [ "$sub" = commit ] || [ "$sub" = push ] || continue
    local -a rest=("${t[@]:$((i + 1))}")
    local author="" j
    if [ "$sub" = commit ]; then
      for ((j = 0; j < ${#rest[@]}; j++)); do
        case "${rest[$j]}" in
          --author=*) author=$(unquote "${rest[$j]#--author=}") ;;
          --author) author=$(unquote "${rest[$((j + 1))]:-}") ;;
        esac
      done
      rest=()
    fi
    check_call "$here" "$sub" "$env_author" "$env_committer" "" "$author" "${rest[@]+"${rest[@]}"}"
  done <<< "$segs"
  exit 0
}

case "${1:-}" in
  set)
    [ -n "${2:-}" ] && is_email "${3:-}" || { echo "usage: $0 set MATCH EMAIL" >&2; exit 1; }
    mkdir -p "$(dirname "$RULES")"
    [ -f "$RULES" ] || echo '{"rules": []}' > "$RULES"
    m=$(normalize "$2")
    jq --indent 2 --arg m "$m" --arg e "$3" '.rules = ([.rules // [] | .[] | select(.match != $m)] + [{match: $m, email: $e}] | sort_by(.match))' \
      "$RULES" > "$RULES.tmp" && mv "$RULES.tmp" "$RULES"
    echo "$m -> $3"
    ;;
  unset)
    [ -f "$RULES" ] && jq --indent 2 --arg m "$(normalize "${2:-}")" '.rules |= map(select(.match != $m))' "$RULES" > "$RULES.tmp" && mv "$RULES.tmp" "$RULES"
    ;;
  list) [ -f "$RULES" ] && jq -r '.rules // [] | .[] | "\(.match)\t\(.email)"' "$RULES" ;;
  check)
    d=${2:-$PWD}
    r=$(remote_of "$d")
    u=$(git -C "$d" remote get-url --push "$r" 2> /dev/null)
    [ -n "$u" ] || { echo "no remote"; exit 0; }
    w=$(normalize "$u")
    printf '%s\texpected %s\tset %s\n' "$w" "$(expected_for "$w")" "$(git -C "$d" config --get user.email)"
    ;;
  pre-push) shift; pre_push "$@" ;;
  pre-commit) pre_commit ;;
  git-hooks) git_hooks "${2:-on}" ;;
  *) hook ;;
esac
