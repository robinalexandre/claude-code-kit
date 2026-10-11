#!/bin/zsh
# usage: motion.sh <proxy dir> <out dir>
# Per-frame motion energy (5 fps) on the rider lens (proxy half picked by RIDER_YAW) for every recording.
# Full decode: ~14 min per 30 min recording. Run in the background, then peaks.py on each m<nnn>.txt.
set -e
source "$(dirname "$0")/lens.sh"
PROXY=$1; OUT=$2
mkdir -p "$OUT"
for f in "$PROXY"/LRV_*.lrv(N); do
  n=${${f:t}%.lrv}; n=${n##*_}
  ffmpeg -nostdin -v error -hwaccel videotoolbox -i "$f" \
    -vf "fps=5,crop=iw/2:ih:${RIDER_CROP_X}:0,scale=96:96,format=gray,tblend=all_mode=difference,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=$OUT/m${n}.txt" \
    -f null -
  echo "done $n"
done
