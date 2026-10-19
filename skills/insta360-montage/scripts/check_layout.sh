#!/bin/zsh
# usage: check_layout.sh <file.insv> <file.lrv> <seconds> <out.jpg>
# Renders the equirectangular view from the proxy and from the .insv with both stream orders,
# stacked, so the matching INSV_STACK order can be confirmed for a new camera model.
set -e
source "$(dirname "$0")/lens.sh"
insv=$1; lrv=$2; t=$3; out=$4
tmp=$(mktemp -d)
ffmpeg -nostdin -v error -hwaccel videotoolbox -ss "$t" -i "$lrv" -frames:v 1 \
  -vf "v360=dfisheye:e:${LENS}:w=1024:h=512,drawtext=text='lrv':x=8:y=8:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.6" -y "$tmp/a.jpg"
ffmpeg -nostdin -v error -hwaccel videotoolbox -ss "$t" -i "$insv" -frames:v 1 \
  -filter_complex "[0:0][0:1]hstack,v360=dfisheye:e:${LENS}:w=1024:h=512,drawtext=text='insv [0:0][0:1]':x=8:y=8:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.6" -y "$tmp/b.jpg"
ffmpeg -nostdin -v error -hwaccel videotoolbox -ss "$t" -i "$insv" -frames:v 1 \
  -filter_complex "[0:1][0:0]hstack,v360=dfisheye:e:${LENS}:w=1024:h=512,drawtext=text='insv [0:1][0:0]':x=8:y=8:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.6" -y "$tmp/c.jpg"
ffmpeg -nostdin -v error -i "$tmp/a.jpg" -i "$tmp/b.jpg" -i "$tmp/c.jpg" -filter_complex "vstack=3" -y "$out"
rm -rf "$tmp"
echo "$out"
