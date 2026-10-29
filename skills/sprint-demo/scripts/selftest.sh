#!/bin/bash
# Checks demo.sh on this machine: bash selftest.sh
# Nothing leaves the machine (Jira runs with DRY_RUN=1). The video checks need ffmpeg with drawtext
# and are skipped without it.
set -u
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
D="$T/a demo dir"
mkdir -p "$D"
fails=0

pass() { echo "PASS $1"; }
fail() {
  echo "FAIL $1"
  fails=$((fails + 1))
}
skip() { echo "SKIP $1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
native() { if command -v cygpath > /dev/null; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
probe() { ffprobe -v error "$@" | tr -d '\r'; }

bash "$SK/demo.sh" doctor | sed 's/^/     /'

out=$(DRY_RUN=1 JIRA_BASE_URL=https://jira.example.com JIRA_PAT=x bash "$SK/demo.sh" jira-sprint ABC 2>&1)
check "jira-sprint on Server asks the open sprint" "printf '%s' \"\$out\" | grep -q 'GET https://jira.example.com/rest/api/2/search?.*jql=project%20%3D%20%22ABC%22%20AND%20sprint%20in%20openSprints%28%29'"
out=$(DRY_RUN=1 JIRA_BASE_URL=https://x.atlassian.net JIRA_EMAIL=a@example.com JIRA_API_TOKEN=x bash "$SK/demo.sh" jira-sprint ABC --sprint 42 2>&1)
check "jira-sprint on Cloud uses search/jql and a sprint id" "printf '%s' \"\$out\" | grep -q '/rest/api/3/search/jql?.*sprint%20%3D%2042'"
out=$(bash "$SK/demo.sh" jira-sprint ABC --sprint "Sprint 12" --url 2>&1)
check "jira-sprint --url prints the path only" "printf '%s' \"\$out\" | grep -q '^/rest/api/2/search?.*sprint%20%3D%20%22Sprint%2012%22'"
check "jira-sprint without credentials says what to set" "! env -u JIRA_BASE_URL bash '$SK/demo.sh' jira-sprint ABC 2> /dev/null"

if ! command -v ffmpeg > /dev/null || ! ffmpeg -hide_banner -filters 2> /dev/null | grep ' drawtext ' > /dev/null; then
  skip "video checks (no ffmpeg with drawtext)"
  [ "$fails" -eq 0 ] && echo "All checks passed." || echo "$fails check(s) failed."
  exit "$fails"
fi

ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=640x400:rate=15:duration=6" -c:v libx264 -pix_fmt yuv420p "$(native "$D/take 1.mp4")"
printf '%s\n' '0.5|2.5|Le conseiller ouvre la fiche client' '3|5|Il valide : « Enregistré » apparaît|ici' > "$D/cues.txt"

bash "$SK/demo.sh" clip "$D/take 1.mp4" "$D/01-ABC-1.mp4" --size 1280x720 --from 1 --to 5 \
  --title "ABC-1 · Réservation d'un créneau" --text "Le client choisit lui-même son créneau de rendez-vous, sans appeler l'agence ; la confirmation part par e-mail, avec un texte assez long pour passer sur deux lignes." \
  --cues "$D/cues.txt" > /dev/null
check "clip is made" "[ -s '$D/01-ABC-1.mp4' ]"
check "clip has the asked size" "[ \"\$(probe -select_streams v:0 -show_entries stream=width,height -of csv=p=0 '$(native "$D/01-ABC-1.mp4")')\" = 1280,720 ]"
check "clip is trimmed" "awk -v d=\"\$(probe -show_entries format=duration -of default=nw=1:nk=1 '$(native "$D/01-ABC-1.mp4")')\" 'BEGIN { exit !(d > 3.8 && d < 4.3) }'"
check "clip keeps its title, accents included" "[ \"\$(probe -show_entries format_tags=title -of default=nw=1:nk=1 '$(native "$D/01-ABC-1.mp4")')\" = \"ABC-1 · Réservation d'un créneau\" ]"
check "clip has no sound track" "[ -z \"\$(probe -select_streams a -show_entries stream=index -of csv=p=0 '$(native "$D/01-ABC-1.mp4")')\" ]"
ffmpeg -loglevel error -y -ss 0.5 -i "$(native "$D/01-ABC-1.mp4")" -frames:v 1 -vf "crop=iw:8:0:8,scale=1:1" -f rawvideo -pix_fmt gray - > "$D/top.raw" 2> /dev/null
check "the banner darkens the top of the frame" "[ \$(od -An -tu1 '$D/top.raw' | tr -d ' ') -lt 60 ]"

bash "$SK/demo.sh" clip "$D/take 1.mp4" "$D/02-ABC-2.mp4" --size 1280x720 --title "ABC-2 = test; #2" --cues "$D/cues.txt" --srt --from 2 > /dev/null
check "--srt writes captions beside the clip" "grep -q '00:00:01,000 --> 00:00:03,000' '$D/02-ABC-2.srt' && grep -q 'Enregistré » apparaît|ici' '$D/02-ABC-2.srt'"
check "--srt shifts and clips the cues to the trim" "grep -q '00:00:00,000 --> 00:00:00,500' '$D/02-ABC-2.srt'"
check "metadata special characters survive" "[ \"\$(probe -show_entries format_tags=title -of default=nw=1:nk=1 '$(native "$D/02-ABC-2.mp4")')\" = 'ABC-2 = test; #2' ]"

bash "$SK/demo.sh" clip "$D/take 1.mp4" "$D/03-plain.mp4" --size 1280x720 --to 1 > /dev/null
check "a clip without a title has no banner" "[ -s '$D/03-plain.mp4' ]"

bash "$SK/demo.sh" card "$D/00-intro.mp4" --size 1280x720 --title "Démo du sprint 12" --text "Équipe Plateforme · 29 octobre" --seconds 2 > /dev/null
check "card is made" "[ -s '$D/00-intro.mp4' ]"

bash "$SK/demo.sh" join "$D/demo.mp4" "$D/00-intro.mp4" "$D/01-ABC-1.mp4" "$D/02-ABC-2.mp4" > /dev/null
check "join is made" "[ -s '$D/demo.mp4' ]"
chapters=$(probe -show_chapters -of csv=p=0 "$(native "$D/demo.mp4")")
check "one chapter per clip" "[ \$(printf '%s\n' \"\$chapters\" | grep -c .) = 3 ]"
check "chapters carry the clips' titles" "printf '%s' \"\$chapters\" | grep -q 'Démo du sprint 12' && printf '%s' \"\$chapters\" | grep -q 'ABC-1 · Réservation'"
check "joined captions are offset by the clips before them" "awk '/ --> / { split(\$1, a, /[:,]/); s = a[3] + a[4] / 1000; exit !(s > 5.9 && s < 6.2) }' '$D/demo.srt'"
check "joined captions are numbered from 1" "head -n 1 '$D/demo.srt' | grep -qx 1 && grep -qx 2 '$D/demo.srt'"

bash "$SK/demo.sh" join "$D/mixed.mp4" "$D/00-intro.mp4" "$D/take 1.mp4" > /dev/null
check "join scales a clip of another size" "[ \"\$(probe -select_streams v:0 -show_entries stream=width,height -of csv=p=0 '$(native "$D/mixed.mp4")')\" = 1280,720 ]"

[ "$fails" -eq 0 ] && echo "All checks passed." || echo "$fails check(s) failed."
exit "$fails"
