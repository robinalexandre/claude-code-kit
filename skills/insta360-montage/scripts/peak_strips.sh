#!/bin/zsh
# usage: peak_strips.sh <proxy dir> <out dir> <nnn> <t1> <t2> ... (seconds)
# One row of 8 frames (2.5 fps, 3.2 s centred on the peak) per time, 5 rows per sheet,
# wide flat view on the rider. Used to sort motion peaks into jumps / turns / crashes / noise.
set -e
source "$(dirname "$0")/lens.sh"
PROXY=$1; OUT=$2; n=$3; shift 3
f=$(ls "$PROXY"/LRV_*_${n}.lrv)
mkdir -p "$OUT/$n"
rows=()
for t in "$@"; do
  start=$(printf "%.2f" $(echo "$t - 1.6" | bc))
  row="$OUT/$n/row_${t}.jpg"
  ffmpeg -nostdin -v error -hwaccel videotoolbox -ss "$start" -t 3.2 -i "$f" \
    -vf "fps=2.5,v360=dfisheye:flat:${LENS}:yaw=${RIDER_YAW}:pitch=${RIDER_PITCH}:roll=${RIDER_ROLL}:h_fov=130:v_fov=90:w=400:h=225,drawtext=text='${n} @${t}s +%{pts\:hms}':x=4:y=4:fontsize=18:fontcolor=white:box=1:boxcolor=black@0.6,tile=8x1" \
    -frames:v 1 -q:v 3 -y "$row"
  rows+=("$row")
done
i=0; k=0
while [ $i -lt ${#rows[@]} ]; do
  k=$((k+1))
  chunk=("${rows[@]:$i:5}")
  args=(); for r in "${chunk[@]}"; do args+=(-i "$r"); done
  ffmpeg -nostdin -v error "${args[@]}" -filter_complex "vstack=inputs=${#chunk[@]}" -q:v 3 -y "$OUT/${n}_sheet_$(printf %02d $k).jpg"
  i=$((i+5))
done
ls "$OUT" | grep "^${n}_sheet"
