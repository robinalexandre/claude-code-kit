#!/bin/zsh
# usage: frame.sh <proxy dir> <nnn> <seconds> <yaw> <pitch> <roll> <out.jpg> [h_fov] [v_fov] [projection]
# One 9:16 test frame (405x720) from the proxy, labelled with its parameters. Stack several with
# ffmpeg hstack to compare framings.
set -e
source "$(dirname "$0")/lens.sh"
PROXY=$1; n=$2; t=$3; yaw=$4; pitch=$5; roll=$6; out=$7; hfov=${8:-$DEF_HFOV}; vfov=${9:-$DEF_VFOV}; proj=${10:-$PROJ}
f=$(ls "$PROXY"/LRV_*_${n}.lrv)
ffmpeg -nostdin -v error -hwaccel videotoolbox -ss "$t" -i "$f" -frames:v 1 \
  -vf "v360=dfisheye:${proj}:${LENS}:yaw=${yaw}:pitch=${pitch}:roll=${roll}:h_fov=${hfov}:v_fov=${vfov}:w=405:h=720,drawtext=text='${n}@${t} ${proj} ${hfov}x${vfov} y${yaw} p${pitch} r${roll}':x=4:y=4:fontsize=16:fontcolor=white:box=1:boxcolor=black@0.6" \
  -y "$out"
