#!/bin/zsh
# usage: vstrip.sh <proxy dir> <out dir> <nnn> <start> <dur> <fps> <yaw> <pitch> <roll> <name>
# 9:16 frames in the final framing, 10 per row, from the proxy. For checking a candidate shot
# (jump phases, takeoff frame, what enters the background) before it goes in the shot list.
set -e
source "$(dirname "$0")/lens.sh"
PROXY=$1; OUT=$2; n=$3; start=$4; dur=$5; fps=$6; yaw=$7; pitch=$8; roll=$9; name=${10}
f=$(ls "$PROXY"/LRV_*_${n}.lrv)
mkdir -p "$OUT"
ffmpeg -nostdin -v error -hwaccel videotoolbox -ss "$start" -t "$dur" -i "$f" \
  -vf "fps=${fps},v360=dfisheye:${PROJ}:${LENS}:yaw=${yaw}:pitch=${pitch}:roll=${roll}:h_fov=${DEF_HFOV}:v_fov=${DEF_VFOV}:w=270:h=480,drawtext=text='+%{pts\:hms}':x=4:y=4:fontsize=18:fontcolor=white:box=1:boxcolor=black@0.6,tile=10x5" \
  -q:v 3 -y "$OUT/${name}_%02d.jpg"
ls "$OUT" | grep "^${name}_"
