#!/bin/zsh
# usage: coarse_sheets.sh <proxy dir> <out dir> [seconds between frames, default 15]
# One stitched equirectangular frame every N seconds, 5x4 per sheet, per recording.
# Only keyframes are decoded, so this is I/O bound (~1 min per 30 min recording).
set -e
source "$(dirname "$0")/lens.sh"
PROXY=$1; OUT=$2; STEP=${3:-15}
mkdir -p "$OUT"
for f in "$PROXY"/LRV_*.lrv(N); do
  n=${${f:t}%.lrv}; n=${n##*_}
  ffmpeg -nostdin -v error -hwaccel videotoolbox -skip_frame nokey -i "$f" \
    -vf "fps=1/${STEP},v360=dfisheye:e:${LENS}:w=640:h=320,drawtext=text='%{pts\:hms}':x=8:y=8:fontsize=22:fontcolor=white:box=1:boxcolor=black@0.6,tile=5x4" \
    -q:v 3 -y "$OUT/f${n}_%02d.jpg"
  echo "sheets for $n: $(ls "$OUT"/f${n}_*.jpg | wc -l | tr -d ' ')"
done
