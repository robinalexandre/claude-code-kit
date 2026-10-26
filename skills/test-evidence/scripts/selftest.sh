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

# The fake secrets are put together at run time: written whole, the config sync's own secret
# masking would replace them in this file with __SECRET__, and the redact checks would test nothing.
bearer=abcdefgh
pw=hunter
tk=s3cr
jwt=eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0
printf '%s\n' \
  'GET https://api.example.com/items?id=4&code=abc123&sig=Zm9v HTTP/1.1' \
  "Authorization: Bearer ${bearer}12345678" \
  'Cookie: session=abcdef' \
  '{"access_token":"'"${tk}3t"'","name":"Alice","mail":"alice@example.com","password": "'"${pw}2"'"}' \
  'AccountName=a;AccountKey=QUJDREVGR0g=;EndpointSuffix=core.windows.net' \
  "token in a log: $jwt.c2lnbmF0dXJl" > "$T/net.txt"
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
git init -q "$T/repo"
ado_from_remote() {
  git -C "$T/repo" remote remove origin 2> /dev/null
  git -C "$T/repo" remote add origin "$1"
  (cd "$T/repo" && DRY_RUN=1 bash "$SK/attach.sh" ado 7 "$T/01-shot.png" 2>&1)
}
check "ado target from an https remote" "ado_from_remote https://org@dev.azure.com/org/proj/_git/repo | grep -q 'POST https://dev.azure.com/org/proj/_apis/git/repositories/repo/'"
check "ado target from a visualstudio.com remote" "ado_from_remote https://org.visualstudio.com/DefaultCollection/proj/_git/repo | grep -q 'POST https://org.visualstudio.com/proj/_apis/git/repositories/repo/'"
check "ado target from an ssh remote" "ado_from_remote git@ssh.dev.azure.com:v3/org/proj/repo | grep -q 'POST https://dev.azure.com/org/proj/_apis/git/repositories/repo/'"
check "ado target refuses a look-alike host" "! ado_from_remote https://evil.example/x.visualstudio.com/proj/_git/repo | grep -q 'POST'"
check "ado target refuses a look-alike ssh host" "! ado_from_remote git@evil.example:ssh.dev.azure.com:v3/org/proj/repo | grep -q 'POST'"
check "unsafe file names refused" "! JIRA_BASE_URL=https://jira.example.com JIRA_PAT=x bash '$SK/attach.sh' jira ABC-1 '$T/bad name.png' 2> /dev/null"

printf 'x' > "$T/report.md"
ado_upload() { DRY_RUN=1 ADO_ORG_URL=https://dev.azure.com/org ADO_PROJECT=proj ADO_REPO=repo bash "$SK/attach.sh" ado 7 "$@" 2>&1; }
check "ado refuses an extension Azure DevOps rejects, before uploading anything" "! ado_upload '$T/01-shot.png' '$T/report.md' | grep -q 'POST'"
check "ado accepts an upper-case allowed extension" "printf 'x' > '$T/02-SHOT.PNG' && ado_upload '$T/02-SHOT.PNG' | grep -q 'attachments/02-SHOT.PNG'"

# A stand-in for curl: the PR already holds 01-shot.png, any other upload gets a new link.
cat > "$T/fake-curl" << 'EOF'
#!/bin/bash
cat > /dev/null
out="" method=GET url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -X) method=$2; shift ;;
    -H | -w | -K | --data-binary | -F) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
echo "$method $url" >> "${FAKE_CURL_LOG:?}"
case "$method $url" in
  "GET "*/attachments\?*) echo '{"count":1,"value":[{"displayName":"01-shot.png","url":"https://ado.example/old/01-shot.png"}]}' > "$out" ;;
  "POST "*/attachments/*) name=${url##*/attachments/}; echo "{\"url\":\"https://ado.example/new/${name%%\?*}\"}" > "$out" ;;
  *) echo '{}' > "$out" ;;
esac
printf 200
EOF
chmod +x "$T/fake-curl"
printf 'x' > "$T/03-new.png"
out=$(FAKE_CURL_LOG="$T/curl.log" CURL="$T/fake-curl" AZURE_DEVOPS_PAT=x ADO_ORG_URL=https://dev.azure.com/org ADO_PROJECT=proj ADO_REPO=repo \
  bash "$SK/attach.sh" ado 7 "$T/01-shot.png" "$T/03-new.png" 2>&1)
check "ado reuses an attachment already on the PR" "printf '%s' \"\$out\" | grep -q 'https://ado.example/old/01-shot.png' && ! grep -q 'POST .*attachments/01-shot.png' '$T/curl.log'"
check "ado uploads the files not yet on the PR" "printf '%s' \"\$out\" | grep -q 'https://ado.example/new/03-new.png'"

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
