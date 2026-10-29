#!/bin/bash
# Turns recorded takes into one demo video: a banner on top of each ticket's take saying what it brings,
# optional step captions, title cards, all joined into one mp4 with a chapter per ticket.
#   demo.sh doctor                                what this machine can do
#   demo.sh clip <take> <out.mp4> [options]       one ticket's take, ready to join
#       --title "<KEY · title>"                   the banner's first line (no banner without it)
#       --text "<what it brings>"                 the banner's second line, wrapped when long
#       --cues <file>                             step captions, one per line: <start s>|<end s>|<text>, in the take's time
#       --srt                                     write the captions to <out>.srt instead of drawing them on the video
#       --from <s> --to <s>                       trims the take
#       --pause <s>                               shortens every still screen to <s> seconds (default 1.5: time to read
#                                                 the result, not to watch the wait between two steps); 0 keeps them
#   demo.sh card <out.mp4> --title "<title>" [--text "<line>"] [--seconds 4]
#                                                 a title card (intro, a section, the end)
#   demo.sh join <out.mp4> <clip.mp4>...          joins the clips, one chapter per clip named after its title; merges
#                                                 their .srt files into <out>.srt
#   demo.sh jira-sprint <PROJECT> [--sprint "<name or id>"] [--jql "<jql>"] [--url]
#                                                 the open sprint's tickets (or that sprint's) as TSV: key, type, status,
#                                                 status category (new, indeterminate, done), summary;
#                                                 --url prints the REST path instead, to fetch() it from a Jira tab
# Every command takes --size WxH (default 1920x1080).
# Fonts: DEMO_FONT and DEMO_FONT_BOLD (a .ttf or .otf file) replace the system's.
# Jira: JIRA_BASE_URL, then JIRA_PAT (Server/Data Center) or JIRA_EMAIL + JIRA_API_TOKEN (Cloud). DRY_RUN=1 prints the request.
set -eu -o pipefail

SIZE=1920x1080
FPS=30
BG=0x0f172a
ACCENT=0x3b82f6
SUBTLE=0xcbd5e1

die() {
  echo "$*" >&2
  exit 1
}

os() {
  case "$(uname -s)" in
    Darwin) echo mac ;;
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
    *) echo linux ;;
  esac
}

native() { if command -v cygpath > /dev/null; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

absolute() {
  case "$1" in
    /* | [A-Za-z]:*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$PWD" "$1" ;;
  esac
}

need_ffmpeg() {
  command -v ffmpeg > /dev/null || die "ffmpeg is missing. Install it (brew install ffmpeg, winget install Gyan.FFmpeg, apt install ffmpeg)."
  command -v ffprobe > /dev/null || die "ffprobe is missing (it comes with ffmpeg)."
}

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

font() {
  local want=$1 f dir
  if [ "$want" = bold ] && [ -n "${DEMO_FONT_BOLD:-}" ]; then
    printf '%s' "$DEMO_FONT_BOLD"
    return
  fi
  if [ -n "${DEMO_FONT:-}" ]; then
    printf '%s' "$DEMO_FONT"
    return
  fi
  case "$(os)" in
    windows)
      dir="$(cygpath -u "${WINDIR:-C:\\Windows}")/Fonts"
      if [ "$want" = bold ]; then set -- "$dir/segoeuib.ttf" "$dir/arialbd.ttf"; else set -- "$dir/segoeui.ttf" "$dir/arial.ttf"; fi
      ;;
    mac)
      if [ "$want" = bold ]; then set -- "/System/Library/Fonts/Supplemental/Arial Bold.ttf" "/Library/Fonts/Arial Bold.ttf"
      else set -- "/System/Library/Fonts/Supplemental/Arial.ttf" "/Library/Fonts/Arial.ttf"; fi
      ;;
    *)
      if [ "$want" = bold ]; then
        set -- "$(fc-match -f '%{file}' 'sans:bold' 2> /dev/null || true)" /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
      else
        set -- "$(fc-match -f '%{file}' sans 2> /dev/null || true)" /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
      fi
      ;;
  esac
  for f; do
    if [ -n "$f" ] && [ -f "$f" ]; then
      printf '%s' "$f"
      return
    fi
  done
  [ "$want" = bold ] && font regular && return
  die "No font found: set DEMO_FONT to a .ttf file."
}

# ffmpeg runs inside $W with the fonts and texts copied there, so filter options only ever see plain
# relative names: no drive colons, spaces or quotes to escape, whatever the text says.
fonts() {
  cp "$(font regular)" "$W/r.ttf"
  cp "$(font bold)" "$W/b.ttf"
}

# wrap <max chars> < text: breaks at spaces only, so a long word stays whole.
wrap() {
  tr -d '\r' | awk -v max="$1" '{
    n = split($0, w, " "); line = ""
    for (i = 1; i <= n; i++) {
      if (line == "") line = w[i]
      else if (length(line) + 1 + length(w[i]) <= max) line = line " " w[i]
      else { print line; line = w[i] }
    }
    if (line != "") print line
  }'
}

# textfile <name> <max chars> <text>: writes the wrapped text with no final newline (drawtext would draw it) and
# prints its number of lines.
textfile() {
  local t
  t=$(printf '%s\n' "$3" | wrap "$2")
  printf '%s' "$t" > "$W/$1"
  printf '%s\n' "$t" | wc -l | tr -d ' '
}

dims() {
  case "$SIZE" in *x*) ;; *) die "--size is WxH, like 1920x1080." ;; esac
  WIDTH=$((${SIZE%x*} / 2 * 2))
  HEIGHT=$((${SIZE#*x} / 2 * 2))
}

duration() { ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$(native "$1")" | tr -d '\r'; }
title_of() { ffprobe -v error -show_entries format_tags=title -of default=nw=1:nk=1 "$(native "$1")" | tr -d '\r'; }

# ffmetadata escapes =, ;, #, \ and newlines with a backslash.
meta_escape() { printf '%s' "$1" | tr '\n' ' ' | sed 's/[\\=;#]/\\&/g'; }

clip() {
  local in=${1:?clip needs a take} out=${2:?clip needs an output file} title="" text="" cues="" srt="" from="" to="" pause=1.5
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title=${2?}; shift ;;
      --text) text=${2?}; shift ;;
      --cues) cues=${2?}; shift ;;
      --srt) srt=1 ;;
      --from) from=${2?}; shift ;;
      --to) to=${2?}; shift ;;
      --pause) pause=${2?}; shift ;;
      --size) SIZE=${2?}; shift ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
  [ -f "$in" ] || die "No such take: $in"
  [ -z "$cues" ] || [ -f "$cues" ] || die "No such cue file: $cues"
  need_ffmpeg
  dims
  fonts
  in=$(absolute "$in")
  out=$(absolute "$out")
  mkdir -p "$(dirname "$out")"

  local ts=$((HEIGHT / 27)) xs=$((HEIGHT / 38)) cs=$((HEIGHT / 30)) pad=$((HEIGHT / 54))
  local chars=$((WIDTH * 100 / (xs * 48) - 4)) tlines=0 xlines=0 bh=0 vf ch
  local filters=""
  if [ -n "$title" ]; then
    tlines=$(textfile title.txt $((WIDTH * 100 / (ts * 58) - 4)) "$title")
    bh=$((pad + tlines * ts * 125 / 100))
    filters="drawtext=fontfile=b.ttf:textfile=title.txt:fontsize=$ts:fontcolor=white:line_spacing=$((ts / 4)):x=$((pad * 2)):y=$pad"
    if [ -n "$text" ]; then
      xlines=$(textfile text.txt "$chars" "$text")
      filters="$filters,drawtext=fontfile=r.ttf:textfile=text.txt:fontsize=$xs:fontcolor=$SUBTLE:line_spacing=$((xs / 3)):x=$((pad * 2)):y=$((bh + pad / 3))"
      bh=$((bh + pad / 3 + xlines * xs * 135 / 100))
    fi
    bh=$(((bh + pad) / 2 * 2))
    filters="$filters,drawbox=x=0:y=$((bh - 4)):w=iw:h=4:color=$ACCENT:t=fill"
  fi
  local cut=()
  [ -z "$from" ] || cut+=(-ss "$from")
  [ -z "$to" ] || cut+=(-to "$to")

  # Still screens longer than $pause (the wait between two steps) keep only their first $pause seconds.
  # $W/drop lists the cut spans, "start end" in the trimmed take's time.
  : > "$W/drop"
  local keep=""
  if awk -v p="$pause" 'BEGIN { exit !(p > 0) }'; then
    ffmpeg -hide_banner -nostats ${cut[@]+"${cut[@]}"} -i "$(native "$in")" -map 0:v:0 -vf "fps=$FPS,freezedetect=d=$pause" -f null - 2>&1 |
      tr -d '\r' | awk -v p="$pause" '
        /freeze_start:/ { s = $NF + 0; open = 1 }
        /freeze_end:/ { if (open && $NF - s > p + 0.1) printf "%.3f %.3f\n", s + p, $NF; open = 0 }
        END { if (open) printf "%.3f 1e9\n", s + p }' > "$W/drop"
    if [ -s "$W/drop" ]; then
      keep=$(awk '{ printf "%sbetween(t,%s,%s)", (NR > 1 ? "+" : ""), $1, $2 }' "$W/drop")
      keep="select='not($keep)',setpts=N/$FPS/TB,"
    fi
  fi

  ch=$((HEIGHT - bh))
  vf="fps=$FPS,${keep}scale=$WIDTH:$ch:force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1,pad=$WIDTH:$HEIGHT:(ow-iw)/2:$bh+($ch-ih)/2:color=$BG"
  [ -z "$filters" ] || vf="$vf,$filters"

  if [ -n "$cues" ]; then
    tr -d '\r' < "$cues" | awk -F'|' -v from="${from:-0}" -v dropfile="$W/drop" '
      BEGIN { while ((getline line < dropfile) > 0) { split(line, d, " "); n++; a[n] = d[1]; b[n] = d[2] } }
      function moved(t,  i, cut) {
        cut = 0
        for (i = 1; i <= n; i++) if (t > a[i]) cut += (t < b[i] ? t : b[i]) - a[i]
        return t - cut
      }
      NF >= 3 {
        s = $1 - from; e = $2 - from; if (e <= 0) next; if (s < 0) s = 0
        s = moved(s); e = moved(e); if (e - s < 0.5) e = s + 0.5
        t = $3; for (i = 4; i <= NF; i++) t = t "|" $i
        printf "%.3f|%.3f|%s\n", s, e, t
      }' > "$W/cues"
    if [ -n "$srt" ]; then
      awk -F'|' 'function ts(s,  ms, h, m, x) {
          ms = int(s * 1000 + 0.5); h = int(ms / 3600000); ms -= h * 3600000; m = int(ms / 60000); ms -= m * 60000
          x = int(ms / 1000); ms -= x * 1000; return sprintf("%02d:%02d:%02d,%03d", h, m, x, ms)
        }
        { t = $3; for (i = 4; i <= NF; i++) t = t "|" $i; printf "%d\n%s --> %s\n%s\n\n", NR, ts($1), ts($2), t }' "$W/cues" > "${out%.*}.srt"
    else
      local n=0 s e t
      while IFS='|' read -r s e t; do
        n=$((n + 1))
        textfile "c$n.txt" $((WIDTH * 70 / 100 * 100 / (cs * 55))) "$t" > /dev/null
        vf="$vf,drawtext=fontfile=r.ttf:textfile=c$n.txt:fontsize=$cs:fontcolor=white:line_spacing=$((cs / 4)):box=1:boxcolor=black@0.65:boxborderw=$((cs / 2)):x=(w-text_w)/2:y=h-text_h-$((pad * 3)):enable='between(t,$s,$e)'"
      done < "$W/cues"
    fi
  fi

  printf ';FFMETADATA1\ntitle=%s\n' "$(meta_escape "${title:-${in##*/}}")" > "$W/meta.txt"
  (cd "$W" && ffmpeg -loglevel error -y ${cut[@]+"${cut[@]}"} -i "$(native "$in")" -i meta.txt -map 0:v:0 -map_metadata 1 \
    -vf "$vf" -an -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -movflags +faststart "$(native "$out")")
  echo "$out"
}

card() {
  local out=${1:?card needs an output file} title="" text="" seconds=4
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title=${2?}; shift ;;
      --text) text=${2?}; shift ;;
      --seconds) seconds=${2?}; shift ;;
      --size) SIZE=${2?}; shift ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
  [ -n "$title" ] || die "card needs --title."
  need_ffmpeg
  dims
  fonts
  out=$(absolute "$out")
  mkdir -p "$(dirname "$out")"
  local ts=$((HEIGHT / 16)) xs=$((HEIGHT / 32)) vf
  textfile title.txt $((WIDTH * 80 / 100 * 100 / (ts * 58))) "$title" > /dev/null
  vf="drawtext=fontfile=b.ttf:textfile=title.txt:fontsize=$ts:fontcolor=white:line_spacing=$((ts / 4)):x=(w-text_w)/2:y=h/2-text_h-$((ts / 3))"
  vf="$vf,drawbox=x=(iw-$((WIDTH / 8)))/2:y=ih/2-2:w=$((WIDTH / 8)):h=4:color=$ACCENT:t=fill"
  if [ -n "$text" ]; then
    textfile text.txt $((WIDTH * 70 / 100 * 100 / (xs * 55))) "$text" > /dev/null
    vf="$vf,drawtext=fontfile=r.ttf:textfile=text.txt:fontsize=$xs:fontcolor=$SUBTLE:line_spacing=$((xs / 3)):x=(w-text_w)/2:y=h/2+$((ts / 3))"
  fi
  vf="$vf,fade=t=in:st=0:d=0.4"
  printf ';FFMETADATA1\ntitle=%s\n' "$(meta_escape "$title")" > "$W/meta.txt"
  (cd "$W" && ffmpeg -loglevel error -y -f lavfi -i "color=c=$BG:s=${WIDTH}x$HEIGHT:r=$FPS:d=$seconds" -i meta.txt -map 0:v -map_metadata 1 \
    -vf "$vf" -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -movflags +faststart "$(native "$out")")
  echo "$out"
}

join() {
  local out=${1:?join needs an output file} f i=0 start=0 end d inputs=() graph="" concat="" srts=0
  shift
  [ $# -gt 0 ] || die "join needs clips."
  need_ffmpeg
  if [ "${1:-}" = --size ]; then
    SIZE=${2?}
    shift 2
  else
    SIZE=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$(native "$1")" | tr -d '\r')
  fi
  dims
  out=$(absolute "$out")
  mkdir -p "$(dirname "$out")"
  printf ';FFMETADATA1\ntitle=%s\n' "$(meta_escape "$(basename "${out%.*}")")" > "$W/meta.txt"
  : > "$W/all.srt"
  for f; do
    [ -f "$f" ] || die "No such clip: $f"
    d=$(duration "$f")
    end=$(awk -v s="$start" -v d="$d" 'BEGIN { printf "%d", s + d * 1000 }')
    printf '[CHAPTER]\nTIMEBASE=1/1000\nSTART=%s\nEND=%s\ntitle=%s\n' "$start" "$end" "$(meta_escape "$(title_of "$f")")" >> "$W/meta.txt"
    if [ -f "${f%.*}.srt" ]; then
      srts=$((srts + 1))
      tr -d '\r' < "${f%.*}.srt" >> "$W/all.srt.$i"
      awk -v off="$start" 'function ms(t,  a) { split(t, a, /[:,]/); return ((a[1] * 60 + a[2]) * 60 + a[3]) * 1000 + a[4] + off }
        function ts(m,  h, n, x) { h = int(m / 3600000); m -= h * 3600000; n = int(m / 60000); m -= n * 60000; x = int(m / 1000)
          return sprintf("%02d:%02d:%02d,%03d", h, n, x, m - x * 1000) }
        / --> / { print ts(ms($1)) " --> " ts(ms($3)); next } { print }' "$W/all.srt.$i" >> "$W/all.srt"
    fi
    inputs+=(-i "$(native "$(absolute "$f")")")
    graph="$graph[$i:v]scale=$WIDTH:$HEIGHT:force_original_aspect_ratio=decrease:force_divisible_by=2,pad=$WIDTH:$HEIGHT:(ow-iw)/2:(oh-ih)/2:color=$BG,setsar=1,fps=$FPS[v$i];"
    concat="$concat[v$i]"
    i=$((i + 1))
    start=$end
  done
  (cd "$W" && ffmpeg -loglevel error -y "${inputs[@]}" -i meta.txt -filter_complex "$graph${concat}concat=n=$i:v=1:a=0[v]" -map '[v]' \
    -map_metadata "$i" -map_chapters "$i" -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -movflags +faststart "$(native "$out")")
  if [ "$srts" -gt 0 ]; then
    awk 'BEGIN { RS = ""; FS = "\n" } { n++; printf "%d\n", n; for (i = 2; i <= NF; i++) print $i; print "" }' "$W/all.srt" > "${out%.*}.srt"
    echo "${out%.*}.srt"
  fi
  echo "$out"
}

# Windows' own curl uses the system certificate store, which corporate TLS inspection relies on.
CURL=${CURL:-curl}
CURL_OPTS=()
if [ "$CURL" = curl ] && command -v cygpath > /dev/null && [ -x "${SYSTEMROOT:-C:/Windows}/System32/curl.exe" ]; then
  CURL="${SYSTEMROOT:-C:/Windows}/System32/curl.exe"
  CURL_OPTS=(--ssl-revoke-best-effort)
fi

jira_sprint() {
  local project=${1:?jira-sprint needs a project key} sprint="" jql="" url_only="" path auth code
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --sprint) sprint=${2?}; shift ;;
      --jql) jql=${2?}; shift ;;
      --url) url_only=1 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
  if [ -z "$jql" ]; then
    case "$sprint" in
      "") jql="project = \"$project\" AND sprint in openSprints()" ;;
      *[!0-9]*) jql="project = \"$project\" AND sprint = \"$sprint\"" ;;
      *) jql="project = \"$project\" AND sprint = $sprint" ;;
    esac
  fi
  # Jira Cloud retired /rest/api/2/search; Server and Data Center don't have /rest/api/3/search/jql.
  if [ -n "${JIRA_EMAIL:-}" ]; then path=/rest/api/3/search/jql; else path=/rest/api/2/search; fi
  path="$path?maxResults=200&fields=summary,status,issuetype&jql=$(jq -rn --arg q "$jql" '$q | @uri' | tr -d '\r')"
  if [ -n "$url_only" ]; then
    echo "$path"
    return
  fi
  [ -n "${JIRA_BASE_URL:-}" ] || die "Set JIRA_BASE_URL, or run with --url and fetch() the path from a Jira tab."
  if [ -n "${JIRA_EMAIL:-}" ] && [ -n "${JIRA_API_TOKEN:-}" ]; then
    auth="Authorization: Basic $(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 | tr -d '\n')"
  elif [ -n "${JIRA_PAT:-}" ]; then
    auth="Authorization: Bearer $JIRA_PAT"
  else
    die "Set JIRA_PAT (Server/Data Center) or JIRA_EMAIL and JIRA_API_TOKEN (Cloud), or run with --url and fetch() the path from a Jira tab."
  fi
  if [ -n "${DRY_RUN:-}" ]; then
    echo "DRY_RUN GET ${JIRA_BASE_URL%/}$path" >&2
    return
  fi
  code=$(printf 'header = "%s"\n' "$auth" | "$CURL" ${CURL_OPTS[@]+"${CURL_OPTS[@]}"} -sS -K - -o "$(native "$W/body")" -w '%{http_code}' "${JIRA_BASE_URL%/}$path") ||
    die "Request failed: GET ${JIRA_BASE_URL%/}$path"
  case "$code" in
    2??) ;;
    *) die "HTTP $code from Jira: $(head -c 400 "$W/body"). Run with --url and fetch() the path from a Jira tab instead." ;;
  esac
  jq -r '.issues[] | [.key, .fields.issuetype.name, .fields.status.name, .fields.status.statusCategory.key, .fields.summary] | @tsv' "$(native "$W/body")" | tr -d '\r'
}

doctor() {
  echo "platform: $(os)"
  if command -v ffmpeg > /dev/null; then
    echo "ffmpeg: $(ffmpeg -version | head -n 1 | tr -d '\r')"
    if ffmpeg -hide_banner -filters 2> /dev/null | grep ' drawtext ' > /dev/null; then echo "drawtext: ok"; else echo "drawtext: missing (this ffmpeg has no libfreetype: banners and captions can't be drawn)"; fi
  else
    echo "ffmpeg: missing"
  fi
  echo "font: $(font regular 2>&1)"
  echo "bold font: $(font bold 2>&1)"
  command -v jq > /dev/null && echo "jq: ok" || echo "jq: missing (jira-sprint)"
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
  doctor) doctor ;;
  clip) clip "$@" ;;
  card) card "$@" ;;
  join) join "$@" ;;
  jira-sprint) jira_sprint "$@" ;;
  *)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2
    exit 1
    ;;
esac
