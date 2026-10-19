#!/bin/zsh
# usage: SRC=<clip folder> [LABEL=1] build.sh <shots.txt> <output.mp4>
# shots.txt: one shot per line, "clip start duration" (clip without extension). "#" comments are
# allowed, also at the end of a line; with LABEL=1 that trailing comment is drawn on the shot
# (candidate reels: "# 7 jump 5s").
set -e
SHOTFILE=$1
FINAL=$2
S=${S:-$(dirname $SHOTFILE)}
OUT=$S/segs_$(basename ${FINAL%.mp4})
mkdir -p $OUT
rm -f $OUT/*.mp4(N) $OUT/list.txt(N)

i=0
while IFS= read -r line; do
  label=""
  [[ "$line" == *\#* ]] && label=$(print -r -- "${line#*\#}" | sed 's/^ *//; s/[^A-Za-z0-9 .+-]//g')
  read -r clip start dur <<< "${line%%\#*}"
  [ -z "$clip" ] && continue
  i=$((i+1))
  n=$(printf "%02d" $i)
  src=$(ls "$SRC/$clip".(MOV|mov|mp4|MP4)(N) | head -1)
  vf="scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,fps=30,format=yuv420p"
  [[ -n "${LABEL:-}" && -n "$label" ]] && vf="$vf,drawtext=text='${label}':x=40:y=80:fontsize=64:fontcolor=white:box=1:boxcolor=black@0.6:boxborderw=14"
  ffmpeg -nostdin -v error -y -ss $start -t $dur -i "$src" \
    -vf "$vf" \
    -af "aresample=48000" -ac 2 \
    -c:v libx264 -preset fast -crf 18 -c:a aac -b:a 192k \
    "$OUT/$n.mp4"
  echo "file '$OUT/$n.mp4'" >> $OUT/list.txt
done < $SHOTFILE

TOTAL=$(awk '!/^ *#/ && NF{s+=$3} END{print s}' $SHOTFILE)
FO=$(echo "$TOTAL-0.6" | bc)
ffmpeg -v error -y -f concat -safe 0 -i $OUT/list.txt \
  -vf "fade=t=in:st=0:d=0.5,fade=t=out:st=$FO:d=0.6" \
  -af "loudnorm=I=-16:TP=-1.5:LRA=11,afade=t=in:st=0:d=0.5,afade=t=out:st=$FO:d=0.6" \
  -c:v libx264 -preset slow -crf 18 -profile:v high -level 4.1 -pix_fmt yuv420p -movflags +faststart \
  -c:a aac -b:a 192k \
  "$FINAL"
ffprobe -v error -show_entries format=duration -of csv=p=0 "$FINAL"
