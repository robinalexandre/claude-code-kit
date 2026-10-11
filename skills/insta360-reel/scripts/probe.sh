#!/bin/zsh
# usage: probe.sh <camera dir>
# Lists the .insv/.lrv pairs with duration, streams and the keyframe interval of the proxy.
set -e
CAM=$1
for f in "$CAM"/VID_*.insv(N); do
  n=${${f:t}%.insv}; n=${n##*_}
  lrv=$(ls "$CAM"/LRV_*_${n}.lrv(N) | head -1)
  d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")
  s=$(ffprobe -v error -select_streams v -show_entries stream=codec_name,width,height,r_frame_rate -of csv=p=0 "$f" | tr '\n' ' ')
  printf "%s  %.1fs  %s\n" "${f:t}" "$d" "$s"
  if [ -n "$lrv" ]; then
    dl=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$lrv")
    sl=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=p=0 "$lrv")
    gop=$(ffprobe -v error -read_intervals "%+5" -select_streams v:0 -skip_frame nokey -show_entries frame=pts_time -of csv=p=0 "$lrv" | sed -n 2p)
    printf "  proxy %s  %.1fs  %s  keyframe every %ss  (proxy/full duration delta %.2fs -> run sync_offset.py)\n" "${lrv:t}" "$dl" "$sl" "$gop" "$(echo "$dl - $d" | bc)"
  else
    echo "  no proxy: use the .insv for review (slower)"
  fi
done
