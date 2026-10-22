#!/bin/bash
# Checks hooks/git-identity-guard.sh in a throwaway home folder: the Claude hook (commit and push
# commands, rules, the most-used email) and git's own pre-push. macOS, Linux and Windows (Git Bash).
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v jq > /dev/null || { echo "Install jq first." >&2; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/guard-test.XXXXXX")
export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
unset GIT_IDENTITY_FILE
mkdir -p "$HOME/.claude/hooks"
cp -R "$KIT/hooks/lib" "$KIT/hooks/git-identity-guard.sh" "$HOME/.claude/hooks/"
G="$HOME/.claude/hooks/git-identity-guard.sh"
git config --global user.name Me
git config --global init.defaultBranch main
fails=0

call() {
  local out
  out=$(jq -n --arg c "$2" --arg d "$1" '{tool_input: {command: $c}, cwd: $d}' | bash "$G")
  if [ -n "$out" ]; then echo "deny: $(printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecisionReason | head -1)"; else echo allow; fi
}
expect() {
  local got
  got=$(call "$2" "$3")
  if [[ "$got" == "$1"* ]]; then echo "ok   $3"; else echo "FAIL $3 -> $got"; fails=$((fails + 1)); fi
}
expect_rule() {
  local got
  got=$(bash "$G" set "$1" x@y.example)
  bash "$G" unset "$1"
  if [ "$got" = "$2 -> x@y.example" ]; then echo "ok   $1 is $2"; else echo "FAIL $1 -> $got"; fails=$((fails + 1)); fi
}

expect_rule "git@github.com:Owner/Repo.git" github.com/owner/repo
expect_rule "https://user@github.com/Owner/Repo" github.com/owner/repo
expect_rule "ssh://git@ssh.dev.azure.com:22/v3/Org/Proj/Repo" dev.azure.com/org/proj/repo
expect_rule "git@ssh.dev.azure.com:v3/Org/Proj/Repo" dev.azure.com/org/proj/repo
expect_rule "https://org.visualstudio.com/Proj/_git/Repo" dev.azure.com/org/proj/_git/repo
expect_rule "https://Org@dev.azure.com/Org/Proj/_git/Repo" dev.azure.com/org/proj/_git/repo

git init -q "$T/gh" && git -C "$T/gh" remote add origin git@github.com:someone/thing.git
git init -q "$T/ado" && git -C "$T/ado" remote add origin https://org@dev.azure.com/org/proj/_git/repo
git init -q "$T/local"
git -C "$T/gh" config user.email work@corp.example
git -C "$T/ado" config user.email work@corp.example

expect allow "$T" "ls -la"
expect "deny: No commit email is recorded for github.com/someone/thing" "$T/gh" "git commit -m x"
bash "$G" set github.com me@home.example > /dev/null
expect "deny: This commit would be authored as work@corp.example" "$T/gh" "git commit -m 'a; b'"
expect "deny: This commit would be authored" "$T" "cd gh && git add . && git commit -m x"
expect "deny: This commit would be authored" "$T" "git -C $T/gh commit -m x"
expect allow "$T/gh" "git -c user.email=me@home.example commit -m x"
expect allow "$T/gh" "GIT_AUTHOR_EMAIL=me@home.example GIT_COMMITTER_EMAIL=me@home.example git commit -m x"
expect "deny: This commit would be authored as work@corp.example" "$T/gh" "git -c user.email=me@home.example -c author.email=work@corp.example commit -m x"
expect "deny: This commit would be authored as work@corp.example" "$T/gh" "git -c user.email=me@home.example commit --author='<work@corp.example>' -m x"
expect "deny: No commit email is recorded for dev.azure.com/org/proj/_git/repo" "$T/ado" "git commit -m x"
bash "$G" set dev.azure.com/org work@corp.example > /dev/null
expect allow "$T/ado" "git commit -m x"
expect allow "$T/local" "git commit -m x"
git -C "$T/gh" config user.email me@home.example
expect allow "$T/gh" "git commit -m x"
expect allow "$T/gh" "git status && echo committed"

git -C "$T/gh" -c user.email=work@corp.example commit -q --allow-empty -m bad
expect "deny: These commits would be pushed to github.com/someone/thing" "$T/gh" "git push origin main"
git -C "$T/gh" commit -q --amend --no-edit --reset-author --allow-empty
expect allow "$T/gh" "git push -u origin HEAD"
expect allow "$T/gh" "git push git@gitlab.com:x/y.git HEAD"

# No rule: the email this user committed with most in the repo, teammates' commits not counted.
git init -q "$T/ws" && git -C "$T/ws" remote add origin https://example.org/team/ws.git
for i in 1 2; do git -C "$T/ws" -c user.email=me@usual.example commit -q --allow-empty -m "m$i"; done
git -C "$T/ws" -c user.name=Mate -c user.email=mate@team.example commit -q --allow-empty -m teammate
git -C "$T/ws" config user.email me@usual.example
expect allow "$T/ws" "git commit -m x"
git -C "$T/ws" config user.email other@corp.example
expect "deny: This commit would be authored as other@corp.example (committer other@corp.example), but the user commits to example.org/team/ws as me@usual.example" "$T/ws" "git commit -m x"
# An address in the history that isn't a plain one is never handed to Claude as the expected email.
git init -q "$T/odd" && git -C "$T/odd" remote add origin https://example.org/team/odd.git
for i in 1 2; do git -C "$T/odd" -c 'user.email=x@y.example;run-this' commit -q --allow-empty -m "m$i"; done
expect "deny: No commit email is recorded for example.org/team/odd" "$T/odd" "git commit -m x"

# git's own pre-push, through the global hooks folder, still running the repo's own hook.
bash "$G" git-hooks on > /dev/null
git init -q --bare "$T/bare.git"
git init -q "$T/p" && git -C "$T/p" remote add origin "$T/bare.git"
bash "$G" set "$(git -C "$T/p" remote get-url origin)" me@home.example > /dev/null
printf '#!/bin/sh\ntouch "%s"\n' "$T/own-ran" > "$T/p/.git/hooks/pre-push" && chmod +x "$T/p/.git/hooks/pre-push"
if git -C "$T/p" -c user.email=work@corp.example commit -q --allow-empty -m refused 2> "$T/err"; then
  echo "FAIL pre-commit let a wrong email through"
  fails=$((fails + 1))
else
  echo "ok   pre-commit refuses: $(head -1 "$T/err")"
fi
git -C "$T/p" -c user.email=work@corp.example commit -q --no-verify --allow-empty -m bad
if git -C "$T/p" push -q origin HEAD:main 2> "$T/err"; then
  echo "FAIL pre-push let a wrong email through"
  fails=$((fails + 1))
else
  echo "ok   pre-push refuses: $(head -1 "$T/err")"
fi
git -C "$T/p" -c user.email=me@home.example commit -q --amend --no-edit --reset-author --allow-empty
if git -C "$T/p" push -q origin HEAD:main 2> "$T/err" && [ -f "$T/own-ran" ]; then
  echo "ok   pre-push passes and the repo's own hook ran"
else
  echo "FAIL pre-push: $(cat "$T/err")"
  fails=$((fails + 1))
fi
bash "$G" git-hooks off > /dev/null
[ -z "$(git config --global --get core.hooksPath)" ] && echo "ok   git-hooks off" || { echo "FAIL git-hooks off"; fails=$((fails + 1)); }

rm -rf "$T"
echo "$fails failure(s)"
[ "$fails" -eq 0 ]
