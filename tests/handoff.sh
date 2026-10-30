#!/bin/bash
# Checks skills/handoff/handoff.sh in a throwaway folder: the JSON the reminders and handoffs pane
# reads, done, cancel and delete. bash tests/handoff.sh
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" CLAUDE_HANDOFFS_DIR="$T/handoffs"
mkdir -p "$HOME/.claude-sync" "$CLAUDE_HANDOFFS_DIR"
echo laptop > "$HOME/.claude-sync/.machine"
H() { bash "$KIT/skills/handoff/handoff.sh" "$@"; }
fails=0

check() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

note() {
  printf -- '---\ntitle: %s\nfrom: %s\ndate: 2026-01-02 10:00\nrepo: %s\nbranch: main\n---\n\n## Next steps\nRun it.\n' \
    "$2" "$3" "$4" > "$CLAUDE_HANDOFFS_DIR/$1.md"
}

state_of() { H json | jq -r --arg i "$1" '.[] | select(.id == $i) | .state'; }

note from-desk "Finish the import" desk owner/app
note from-here "Check the logs" laptop none

json=$(H json)
check "json lists the open notes" '[ "$(state_of from-desk)" = open ]'
check "a note from another computer is not mine" '[ "$(jq -r ".[] | select(.id == \"from-desk\") | .isMine" <<< "$json")" = false ]'
check "a note written here is mine" '[ "$(jq -r ".[] | select(.id == \"from-here\") | .isMine" <<< "$json")" = true ]'
check "repo none is left out" '[ "$(jq -r ".[] | select(.id == \"from-here\") | .repo // \"absent\"" <<< "$json")" = absent ]'
check "json carries the body" 'jq -e ".[] | select(.id == \"from-desk\") | .body | test(\"Run it\")" <<< "$json" > /dev/null'

H done from-desk > /dev/null
check "done moves a note to done/" '[ -f "$CLAUDE_HANDOFFS_DIR/done/from-desk.md" ] && [ "$(state_of from-desk)" = done ]'
check "with when it was closed" 'grep -q "^closed: " "$CLAUDE_HANDOFFS_DIR/done/from-desk.md"'
H cancel from-here > /dev/null
check "cancel marks it canceled" '[ "$(state_of from-here)" = canceled ]'
H restore from-here > /dev/null
check "restore opens a canceled note again" '[ "$(state_of from-here)" = open ] && ! grep -qE "^(closed|canceled):" "$CLAUDE_HANDOFFS_DIR/from-here.md"'
H delete from-desk > /dev/null
check "delete removes a done note" '[ ! -f "$CLAUDE_HANDOFFS_DIR/done/from-desk.md" ]'
check "an unknown note is refused" '! H done nope 2> /dev/null'

# An assistant's tasks: in its own folder, listed in agents.json, in the reminders' format.
TASKS="$T/assistant/tasks"
mkdir -p "$TASKS/past"
printf '[{"name": "Max", "dir": "assistant/tasks/"}, {"name": "Up", "dir": "../outside"}]\n' > "$CLAUDE_HANDOFFS_DIR/agents.json"
{ echo ---; echo "title: water the plants"; echo "on: 2999-01-01 18:00"; echo ---; echo; echo "Remind me."; } > "$TASKS/plants.md"
{ echo ---; echo "title: brief"; echo "on: 2026-01-01 09:00"; echo "every: day"; echo "digest: yes"; echo ---; } > "$TASKS/brief.md"
{ echo ---; echo "title: ran"; echo "on: 2026-01-01"; echo "closed: 2026-01-01 09:00"; echo ---; } > "$TASKS/past/ran.md"
json=$(H json)
check "an assistant's task shows under its name" '[ "$(jq -r ".[] | select(.id == \"assistant/tasks/plants\") | .group + \"/\" + .agent + \"/\" + .state" <<< "$json")" = "Max/Max/later" ]'
check "one it ran is past" '[ "$(jq -r ".[] | select(.id == \"assistant/tasks/ran\") | .state" <<< "$json")" = past ]'
check "a repeating one says when it runs next" 'jq -e ".[] | select(.id == \"assistant/tasks/brief\") | .next and .digest == \"yes\"" <<< "$json" > /dev/null'
check "the notes are still there beside them" 'jq -e ".[] | select(.id == \"from-here\")" <<< "$json" > /dev/null'
check "agents names each assistant's folder, never one going up" '[ "$(H agents)" = "$(printf "Max\t%s" "$TASKS")" ]'
H done assistant/tasks/plants > /dev/null
check "done cancels a task into its own past" '[ -f "$TASKS/past/plants.md" ] && grep -q "^closed:" "$TASKS/past/plants.md"'
H restore assistant/tasks/plants > /dev/null
check "and restore puts it back" '[ -f "$TASKS/plants.md" ] && ! grep -q "^closed:" "$TASKS/plants.md"'
check "an id outside the listed folders is refused" '! H done ../outside/x 2> /dev/null && ! H delete assistant/x/../../y 2> /dev/null && ! H cancel assistant/tasks/../../z 2> /dev/null'
H done assistant/tasks/brief > /dev/null
check "done on a repeating task skips today only" '[ -f "$TASKS/brief.md" ] && grep -q "^done: " "$TASKS/brief.md"'
H delete assistant/tasks/ran > /dev/null
check "delete removes a past task" '[ ! -f "$TASKS/past/ran.md" ]'
printf '[{"name": "Max", "dir": "assistant/tasks"}]\n' > "$T/reminders-agents.json"
mkdir -p "$T/reminders" && mv "$T/reminders-agents.json" "$T/reminders/agents.json" && rm -f "$CLAUDE_HANDOFFS_DIR/agents.json"
check "agents.json still read next to the reminders, where it used to be" '[ "$(H agents | cut -f1)" = Max ]'
rm -rf "$T/reminders" "$T/assistant"

# Runs left for a computer: due, run, the report, the push, replies, interruptions and the sender's
# notifications, with a stub in place of Claude and a local bare repo in place of the remote.
export HANDOFF_SYNC=true HANDOFF_NOTIFY="$T/notified" HANDOFF_CLAUDE="$T/claude" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "$HOME/.claude-sync/machines" "$HOME/dev" "$T/remote/owner"
printf '{"devDir": "%s"}\n' "$HOME/dev" > "$HOME/.claude-sync/machines/laptop.json"
echo '{}' > "$HOME/.claude-sync/machines/desk.json"
git init -q --bare -b main "$T/remote/owner/app.git"
git clone -q "$T/remote/owner/app.git" "$HOME/dev/app" 2> /dev/null
(cd "$HOME/dev/app" && echo one > a.txt && git add a.txt && git commit -qm init && git push -q origin main &&
  git checkout -qb feat/x && git push -q origin feat/x && git checkout -q main && git remote set-head origin main)

# The stub: STUB=done commits a file, needs asks a question, fail exits 1. It keeps its arguments.
cat > "$T/claude" << 'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$STUB_ARGS"
pwd > "$STUB_ARGS.pwd"
case "$STUB" in
  done) echo two > b.txt && git add b.txt && git commit -qm "feat: add b" ;;
  needs) printf '{"result": "Which table?\\nSTATUS: needs-you", "session_id": "s-1", "is_error": false}\n'; exit 0 ;;
  fail) echo "boom" >&2; exit 1 ;;
esac
printf '{"result": "Added b.\\nSTATUS: done", "session_id": "s-2", "is_error": false}\n'
EOF
chmod +x "$T/claude"
export STUB_ARGS="$T/args"

run_note() {
  printf -- '---\ntitle: %s\nfrom: desk\ndate: 2026-01-02 10:00\nrepo: owner/app\nbranch: feat/x\nfor: laptop\nrun: %s\nscope: %s\n---\n\n## Next steps\nAdd b.\n' \
    "$2" "$3" "$4" > "$CLAUDE_HANDOFFS_DIR/$1.md"
}
field() { awk -v k="$2" 'NR > 1 && $0 == "---" { exit } index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }' "$CLAUDE_HANDOFFS_DIR/$1.md"; }

run_note go "Add b" now push
run_note later "Later" "2999-01-01 09:00" edit
run_note other "For desk" now edit
sed -i.bak 's/^for: laptop/for: desk/' "$CLAUDE_HANDOFFS_DIR/other.md" && rm -f "$CLAUDE_HANDOFFS_DIR/other.md.bak"
due=$(H due)
check "due lists a run now for this computer" 'grep -qx go <<< "$due"'
check "not one whose time has not come" '! grep -qx later <<< "$due"'
check "nor one for another computer" '! grep -qx other <<< "$due"'
check "json says which computer a note is for" '[ "$(H json | jq -r ".[] | select(.id == \"go\") | .isForHere")" = true ]'
check "run refuses a note for another computer" '! H run other 2> /dev/null'
# Seen from desk later on, it would start in the background.
rm -f "$CLAUDE_HANDOFFS_DIR/other.md"
run_note agent "From the assistant" now edit
sed -i.bak 's/^from: desk/from: assistant/' "$CLAUDE_HANDOFFS_DIR/agent.md" && rm -f "$CLAUDE_HANDOFFS_DIR/agent.md.bak"
check "a note an agent wrote never runs by itself" '! H due | grep -qx agent && ! H run agent 2> /dev/null'
rm -f "$CLAUDE_HANDOFFS_DIR/agent.md"

STUB=done H run go
check "a run that ends well is done" '[ "$(field go status)" = done ] && [ "$(field go run_by)" = laptop ]'
check "it runs in a worktree, not in the clone" '[ "$(cat "$STUB_ARGS.pwd")" = "$(cd "$HOME/.claude/handoff-runs/go/work" && pwd)" ]'
check "with the tools of its scope and no push for Claude" 'grep -q "Bash(git push:\*)" "$STUB_ARGS" && grep -qx dontAsk "$STUB_ARGS"'
check "the report and the commits go into the note" 'grep -q "^## Run on laptop, .* · done" "$CLAUDE_HANDOFFS_DIR/go.md" && grep -q "Added b" "$CLAUDE_HANDOFFS_DIR/go.md" && grep -q "feat: add b" "$CLAUDE_HANDOFFS_DIR/go.md"'
check "scope push pushes to the branch of the note" '[ "$(git -C "$T/remote/owner/app.git" log -1 --format=%s feat/x)" = "feat: add b" ] && grep -q "pushed to feat/x" "$CLAUDE_HANDOFFS_DIR/go.md"'
check "the clone itself is untouched" '[ "$(git -C "$HOME/dev/app" branch --show-current)" = main ] && [ ! -f "$HOME/dev/app/b.txt" ]'
check "a done run is not due again" '! H due | grep -qx go'

# The same attempt never runs twice on one computer, whatever the note says.
sed -i.bak -e '/^status: /d' "$CLAUDE_HANDOFFS_DIR/go.md" && rm -f "$CLAUDE_HANDOFFS_DIR/go.md.bak"
rm -f "$STUB_ARGS"
STUB=done H run go 2> /dev/null
check "a status a merge took away does not run it again" '! H due | grep -qx go && [ ! -f "$STUB_ARGS" ]'
awk 'NR > 1 && $0 == "---" && !d { print "status: done"; d = 1 } { print }' "$CLAUDE_HANDOFFS_DIR/go.md" > "$T/go" && mv "$T/go" "$CLAUDE_HANDOFFS_DIR/go.md"
cat > "$T/slow" << 'EOF'
#!/bin/bash
echo x >> "$STUB_COUNT"
sleep 2
printf '{"result": "Slow.\\nSTATUS: done", "session_id": "s-3", "is_error": false}\n'
EOF
chmod +x "$T/slow"
run_note twice "Started twice" now read
STUB_COUNT="$T/count" HANDOFF_CLAUDE="$T/slow" H run twice &
STUB_COUNT="$T/count" HANDOFF_CLAUDE="$T/slow" H run twice &
STUB_COUNT="$T/count" HANDOFF_CLAUDE="$T/slow" H on-sync
wait
sleep 3
check "runs started together run it once" '[ "$(wc -l < "$T/count" | tr -d " ")" = 1 ] && [ "$(field twice status)" = done ]'
mkdir -p "$HOME/.claude/handoff-runs/fresh/lock"
run_note fresh "Lock without a pid yet" now read
rm -f "$STUB_ARGS"
H run fresh
check "a lock made a moment ago, before its pid, is not taken" '[ ! -f "$STUB_ARGS" ] && [ -z "$(field fresh status)" ]'
rm -f "$CLAUDE_HANDOFFS_DIR/fresh.md" "$CLAUDE_HANDOFFS_DIR/twice.md"

run_note ask "Fill the table" now edit
STUB=needs H run ask
check "a question leaves it needs-you" '[ "$(field ask status)" = needs-you ] && [ "$(field ask session)" = s-1 ] && grep -q "Which table" "$CLAUDE_HANDOFFS_DIR/ask.md"'
check "an edit run pushes nothing" '! grep -q "pushed to" "$CLAUDE_HANDOFFS_DIR/ask.md"'
H reply ask "The users table" > /dev/null
check "a reply goes under Replies and queues it again" 'grep -q "^- .* · laptop: The users table$" "$CLAUDE_HANDOFFS_DIR/ask.md" && [ "$(field ask status)" = queued ] && H due | grep -qx ask'
STUB=done H run ask
check "the next run resumes the session with the reply" 'grep -qx -- --resume "$STUB_ARGS" && grep -qx s-1 "$STUB_ARGS" && grep -q "The users table" "$STUB_ARGS"'

run_note bad "Break" now read
STUB=fail H run bad
check "a run that fails is failed, with what it said" '[ "$(field bad status)" = failed ] && grep -q "boom" "$CLAUDE_HANDOFFS_DIR/bad.md"'
check "a read run gets no edit tool" '! grep -q "Edit" "$STUB_ARGS"'

run_note cut "Cut short" now edit
awk 'NR > 1 && $0 == "---" && !d { print "status: running"; print "run_by: laptop"; d = 1 } { print }' "$CLAUDE_HANDOFFS_DIR/cut.md" > "$T/cut" &&
  mv "$T/cut" "$CLAUDE_HANDOFFS_DIR/cut.md"
H on-sync
check "a run whose process is gone is marked failed, not run again" '[ "$(field cut status)" = failed ] && grep -q "Interrupted" "$CLAUDE_HANDOFFS_DIR/cut.md"'

# The sender's side: the same notes seen from desk.
echo desk > "$HOME/.claude-sync/.machine"
rm -f "$T/notified"
H on-sync
check "the sender is told of each status once" 'grep -q "^Handoff done: Add b · on laptop" "$T/notified" && grep -q "^Handoff failed: Break" "$T/notified"'
n=$(wc -l < "$T/notified")
H on-sync
check "and not again while it stays the same" '[ "$(wc -l < "$T/notified")" -eq "$n" ]'
H reply bad "Try again" > /dev/null
check "a reply queues a failed run again" '[ "$(field bad status)" = queued ]'
check "machines lists the computers" '[ "$(H machines | tr "\n" " ")" = "desk laptop " ]'

echo "$fails failure(s)"
[ "$fails" -eq 0 ]
