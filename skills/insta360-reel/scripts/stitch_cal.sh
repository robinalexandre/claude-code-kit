#!/bin/zsh
# usage: stitch_cal.sh <file.insv> <seconds> <fov1> <fov2> ...
# Lens FOV calibration: renders each lens to its own equirect and prints the mean absolute difference
# between them in the 12-degree bands around yaw +-90. The FOV with the smallest difference goes in
# lens.sh (193 on the X6). Pick a frame with a distant, textured background (coastline), not a close object.
set -e
insv=$1; t=$2; shift 2
W=1920; H=960
tmp=$(mktemp -d)
for fov in "$@"; do
  ffmpeg -nostdin -v error -hwaccel videotoolbox -ss "$t" -i "$insv" -frames:v 1 \
    -filter_complex "[0:0]v360=fisheye:e:ih_fov=${fov}:iv_fov=${fov}:w=${W}:h=${H}[a];[0:1]v360=fisheye:e:ih_fov=${fov}:iv_fov=${fov}:yaw=180:w=${W}:h=${H}[b];[a][b]hstack" \
    -y "$tmp/pair.png"
  bw=$(( W * 12 / 360 ))
  x1=$(( W * 3 / 4 - bw / 2 )); x2=$(( W / 4 - bw / 2 ))
  d=$(ffmpeg -nostdin -v error -i "$tmp/pair.png" \
    -filter_complex "[0]split[p][q];[p]crop=${W}:${H}:0:0,split[a1][a2];[q]crop=${W}:${H}:${W}:0,split[b1][b2];[a1]crop=${bw}:${H}:${x1}:0[ar];[b1]crop=${bw}:${H}:${x1}:0[br];[a2]crop=${bw}:${H}:${x2}:0[al];[b2]crop=${bw}:${H}:${x2}:0[bl];[ar][br]blend=all_mode=difference,format=gray,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-[r];[al][bl]blend=all_mode=difference,format=gray,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-[l];[r][l]hstack" \
    -f null - 2>/dev/null | grep YAVG | sed 's/.*YAVG=//' | tr '\n' ' ')
  echo "fov $fov  overlap diff (right, left) = $d"
done
rm -rf "$tmp"
