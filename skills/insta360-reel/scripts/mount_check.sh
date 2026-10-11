#!/bin/zsh
# usage: mount_check.sh <proxy dir> <out.jpg>
# Where is the camera and which way does it look? Three stitched equirect frames per recording (at 10%,
# 50% and 90% of it) with a 45-degree grid: x -> yaw = (x/W - 0.5) * 360, y -> pitch = (0.5 - y/H) * 180.
# Find the rider on each frame, confirm with frame.sh, then write $S/mount.env (SKILL.md section 2).
set -e
source "$(dirname "$0")/lens.sh"
PROXY=$1; OUT=$2
tmp=$(mktemp -d)
i=0
for f in "$PROXY"/LRV_*.lrv(N); do
  n=${${f:t}%.lrv}; n=${n##*_}
  d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")
  for p in 0.1 0.5 0.9; do
    t=$(printf "%.1f" $(echo "$d * $p" | bc -l))
    i=$((i+1))
    ffmpeg -nostdin -v error -hwaccel videotoolbox -ss "$t" -i "$f" -frames:v 1 \
      -vf "v360=dfisheye:e:${LENS}:w=768:h=384,drawgrid=w=iw/8:h=ih/4:t=1:c=yellow@0.7,drawtext=text='${n} @${t}s':x=8:y=8:fontsize=18:fontcolor=white:box=1:boxcolor=black@0.6" \
      -y "$tmp/$(printf %03d $i).jpg"
  done
done
ffmpeg -nostdin -v error -pattern_type glob -i "$tmp/*.jpg" -vf "tile=3x$(( (i + 2) / 3 ))" -frames:v 1 -q:v 3 -y "$OUT"
rm -rf "$tmp"
echo "$OUT: $i frames, grid every 45 degrees, centre = yaw 0 pitch 0"
