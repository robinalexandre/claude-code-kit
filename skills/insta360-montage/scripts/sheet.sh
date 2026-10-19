#!/bin/zsh
# usage: sheet.sh <video.mp4> <out.jpg> [fps, default 2]
# Timestamped contact sheet of a rendered reel (12 per row) for frame-by-frame verification.
set -e
ffmpeg -nostdin -v error -y -i "$1" \
  -vf "fps=${3:-2},scale=-2:400,drawtext=text='%{pts\:hms}':fontsize=22:fontcolor=yellow:box=1:boxcolor=black@0.6:x=8:y=8,tile=12x7" \
  -frames:v 1 "$2"
echo "$2"
