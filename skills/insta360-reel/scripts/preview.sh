#!/bin/zsh
# usage: preview.sh <reel.mp4> <out.mp4>
# 720x1280 version under 30 MB so it can be sent with SendUserFile.
set -e
ffmpeg -nostdin -v error -y -i "$1" -vf scale=720:1280 -c:v libx264 -preset fast -crf 24 -c:a aac -b:a 128k -movflags +faststart "$2"
ls -la "$2" | awk '{printf "%.1f MB\n", $5/1048576}'
