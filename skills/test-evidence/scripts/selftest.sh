#!/bin/bash
# Checks the test-evidence scripts on this machine: bash selftest.sh
# Nothing leaves the machine (uploads run with DRY_RUN=1). Screen tests capture a 64x64 corner
# and record it for 2 s; they are skipped when there is no display.
set -u
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0

pass() { echo "PASS $1"; }
fail() {
  echo "FAIL $1"
  fails=$((fails + 1))
}
skip() { echo "SKIP $1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

bash "$SK/capture.sh" doctor | sed 's/^/     /'

printf '%s\n' \
  'GET https://api.example.com/items?id=4&code=abc123&sig=Zm9v HTTP/1.1' \
  'Authorization: Bearer abcdefgh12345678' \
  'Cookie: session=abcdef' \
  '{"access_token":"s3cr3t","name":"Alice","mail":"alice@example.com","password": "hunter2"}' \
  'AccountName=a;AccountKey=QUJDREVGR0g=;EndpointSuffix=core.windows.net' \
  'token in a log: eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJl' > "$T/net.txt"
bash "$SK/redact.sh" "$T/net.txt" "$T/red.txt"
check "redact masks secrets" "! grep -q -E 'abc123|Zm9v|abcdefgh12345678|session=|s3cr3t|hunter2|QUJDREVGR0g|eyJhbGci' '$T/red.txt'"
check "redact keeps the rest" "grep -q 'id=4' '$T/red.txt' && grep -q Alice '$T/red.txt' && grep -q alice@example.com '$T/red.txt'"
check "redact prints to stdout" "[ \"\$(bash '$SK/redact.sh' '$T/net.txt' | wc -l | tr -d ' ')\" = 6 ]"
bash "$SK/redact.sh" --emails "$T/net.txt" "$T/red2.txt"
check "redact --emails" "! grep -q alice@example.com '$T/red2.txt'"

printf 'x' > "$T/01-shot.png"
printf 'x' > "$T/bad name.png"
printf 'Proof' > "$T/comment.md"
out=$(DRY_RUN=1 JIRA_BASE_URL=https://jira.example.com JIRA_PAT=x bash "$SK/attach.sh" jira ABC-1 "$T/01-shot.png" 2>&1)
check "jira upload request" "printf '%s' \"\$out\" | grep -q 'POST https://jira.example.com/rest/api/2/issue/ABC-1/attachments'"
out=$(DRY_RUN=1 ADO_ORG_URL=https://dev.azure.com/org ADO_PROJECT=proj ADO_REPO=repo bash "$SK/attach.sh" ado 7 "$T/01-shot.png" 2>&1)
check "ado upload request" "printf '%s' \"\$out\" | grep -q 'POST https://dev.azure.com/org/proj/_apis/git/repositories/repo/pullRequests/7/attachments/01-shot.png'"
out=$(DRY_RUN=1 ADO_ORG_URL=https://dev.azure.com/org ADO_PROJECT=proj ADO_REPO=repo bash "$SK/attach.sh" ado-comment 7 "$T/comment.md" 2>&1)
check "ado comment request" "printf '%s' \"\$out\" | grep -q 'pullRequests/7/threads'"
printf '![shot](URL:01-shot.png)' > "$T/placeholder.md"
out=$(DRY_RUN=1 ADO_ORG_URL=https://dev.azure.com/org ADO_PROJECT=proj ADO_REPO=repo bash "$SK/attach.sh" ado-comment 7 "$T/placeholder.md" "$T/01-shot.png" 2>&1)
check "ado comment uploads its files first" "printf '%s' \"\$out\" | grep -q 'attachments/01-shot.png' && printf '%s' \"\$out\" | grep -q 'threads'"
check "ado comment refuses a file without placeholder" "! DRY_RUN=1 ADO_ORG_URL=https://dev.azure.com/org ADO_PROJECT=proj ADO_REPO=repo bash '$SK/attach.sh' ado-comment 7 '$T/comment.md' '$T/01-shot.png' 2> /dev/null"
check "unsafe file names refused" "! JIRA_BASE_URL=https://jira.example.com JIRA_PAT=x bash '$SK/attach.sh' jira ABC-1 '$T/bad name.png' 2> /dev/null"

check "capture needs a target" "! bash '$SK/capture.sh' shot '$T/x.png' 2> /dev/null"

if command -v ffmpeg > /dev/null; then
  ffmpeg -loglevel error -y -f lavfi -i testsrc=size=321x241:rate=15 -t 2 -c:v libvpx -b:v 200k "$T/in.webm" 2> /dev/null ||
    ffmpeg -loglevel error -y -f lavfi -i testsrc=size=321x241:rate=15 -t 2 "$T/in.mkv"
  in=$T/in.webm
  [ -s "$in" ] || in=$T/in.mkv
  bash "$SK/capture.sh" mp4 "$in" "$T/out.mp4" > /dev/null
  check "mp4 conversion (odd size made even)" "ffprobe -v error -show_entries stream=width,height -of csv=p=0 '$T/out.mp4' | grep -q '^320,240'"
  bash "$SK/capture.sh" mp4 "$in" "$T/cut.mp4" 0.5 1.5 > /dev/null
  check "mp4 trimming" "ffprobe -v error -show_entries format=duration -of csv=p=0 '$T/cut.mp4' | grep -q '^1\\.'"
  bash "$SK/capture.sh" gif "$T/out.mp4" "$T/out.gif" 160 5 > /dev/null
  check "gif conversion" "[ -s '$T/out.gif' ]"
else
  skip "mp4 and gif conversion (no ffmpeg)"
fi

case "$(uname -s)" in
  Darwin | MINGW* | MSYS* | CYGWIN*) display=1 ;;
  *) if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then display=1; else display=""; fi ;;
esac
if [ -n "$display" ]; then
  bash "$SK/capture.sh" shot "$T/shot.png" --region 0,0,64,64 > /dev/null
  check "region screenshot" "[ -s '$T/shot.png' ]"
  check "window list" "bash '$SK/capture.sh' windows > /dev/null 2>&1"
  bash "$SK/capture.sh" record "$T/rec.mp4" --region 0,0,64,64 --max 30 > /dev/null &
  rec=$!
  sleep 4
  start=$(date +%s)
  bash "$SK/capture.sh" stop > /dev/null
  wait "$rec"
  check "record stops on request" "[ \$((\$(date +%s) - start)) -lt 20 ]"
  if command -v ffmpeg > /dev/null; then
    check "recording is a playable mp4" "ffprobe -v error -show_entries format=duration -of csv=p=0 '$T/rec.mp4' | grep -q '^[1-9]'"
  else
    check "recording saved" "ls '$T'/rec.rec.* > /dev/null 2>&1"
  fi
else
  skip "screen capture (no display)"
fi

echo
[ "$fails" -eq 0 ] && echo "All good." || echo "$fails failed."
[ "$fails" -eq 0 ]
