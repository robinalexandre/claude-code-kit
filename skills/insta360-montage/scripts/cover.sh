#!/bin/zsh
# usage: PROXY_DIR=<dir> CAM_DIR=<dir> cover.sh <shots dir with sync.txt> <nnn> <proxy seconds> <yaw> <pitch> <roll|auto> <out.jpg>
# One full-res 1080x1920 frame with the blended stitch and the default framing, for the Instagram cover.
set -e
SKILL_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SKILL_DIR/lens.sh"
S=$1; n=$2; t=$3; yaw=$4; pitch=$5; roll=$6; out=$7
proxy=$(ls "$PROXY_DIR"/LRV_*_${n}.lrv)
insv=$(ls "$CAM_DIR"/VID_*_${n}.insv)
offset=$(awk -v f="$n" '$1==f{print $2}' "$S/sync.txt")
ft=$(printf "%.3f" $(echo "$t + $offset" | bc))
if [ "$roll" = "auto" ]; then
  a=$(python3 "$SKILL_DIR/auto_roll.py" "$proxy" "$t" | sed 's/.*down_angle=\([-0-9.]*\).*/\1/')
  roll=$(printf "%.1f" $(echo "-1 * $a" | bc))
fi
gains=$(python3 "$SKILL_DIR/stitch_gain.py" "$proxy" "$t" 2>/dev/null)
tmp=$(mktemp -d)
make_mask 3840 1920 "$tmp/mask.png"
ffmpeg -nostdin -v error -hwaccel videotoolbox -ss "$ft" -i "$insv" -loop 1 -t 0.1 -i "$tmp/mask.png" -frames:v 1 \
  -filter_complex "$(stitch_graph full 3840 1920 "$gains");[e]v360=e:${PROJ}:yaw=${yaw}:pitch=${pitch}:roll=${roll}:h_fov=${DEF_HFOV}:v_fov=${DEF_VFOV}:w=1080:h=1920" \
  -q:v 2 -y "$out"
rm -rf "$tmp"
echo "$out (roll $roll, gains $gains)"
