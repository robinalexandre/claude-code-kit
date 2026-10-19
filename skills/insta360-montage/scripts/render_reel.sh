#!/bin/zsh
# usage: MODE=proxy|full PROXY_DIR=<dir> CAM_DIR=<dir> [LABEL=1] [MOUNT=<mount.env>] render_reel.sh <shots.txt> <output.mp4>
#
# shots.txt: one shot per line, "#" comments allowed, also at the end of a line; with LABEL=1 that
# trailing comment is drawn on the shot (candidate reels: "# 7 jump 5.4s").
#   file start dur yaw pitch roll speed [pan_to|-] [h_fov|-] [v_fov|-] [roll_end ramp_from ramp_to]
#   file     = recording suffix (002, 003, ...), start = seconds on the PROXY timeline, dur = output seconds
#   speed    = 1 real time, 0.5 half-speed slow motion (source 60 fps -> real slow motion)
#   roll     = "auto" for rider-locked (measured on the proxy, keeps the rider upright), or a fixed v360 roll
#   pan_to   = yaw pans linearly from yaw to pan_to over the shot (for following a distant subject)
#   h_fov/v_fov override the default framing for that shot (tighter for distant subjects)
#   roll_end = fixed roll ramp between ramp_from and ramp_to seconds into the shot (rarely needed: prefer auto)
#
# Every shot is stitched from both lenses into an equirect with a feathered blend over the lens overlap and
# a per-shot exposure match of the back lens (stitch_gain.py), then projected. ffmpeg's dfisheye input is
# not used: with a >180 degree lens it overlaps both lenses (duplicated objects, an arc across the frame).
#
# A sync.txt next to shots.txt holds the per-file offset "file offset" (insv_time = lrv_time + offset),
# produced by sync_offset.py --write; it is required in full mode.
set -e
SHOTFILE=$1
FINAL=$2
MODE=${MODE:-proxy}
SKILL_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SKILL_DIR/lens.sh"
S=$(cd "$(dirname "$SHOTFILE")" && pwd)
OUT=$S/segs_$(basename ${FINAL%.mp4})
: ${PROXY_DIR:?set PROXY_DIR to the folder holding the .lrv proxies}
[ "$MODE" = "full" ] && : ${CAM_DIR:?set CAM_DIR to the folder holding the .insv files}
mkdir -p "$OUT"
rm -f "$OUT"/*.mp4(N) "$OUT"/list.txt(N)

if [ "$MODE" = "full" ]; then EW=3840; else EW=2048; fi
EH=$((EW/2))
MASK="$OUT/mask_${EW}.png"
make_mask $EW $EH "$MASK"

i=0
while IFS= read -r line; do
  label=""
  [[ "$line" == *\#* ]] && label=$(print -r -- "${line#*\#}" | sed 's/^ *//; s/[^A-Za-z0-9 .+-]//g')
  read -r file start dur yaw pitch roll speed yaw_end hfov vfov roll_end ramp_from ramp_to <<< "${line%%\#*}"
  [ -z "$file" ] && continue
  i=$((i+1))
  n=$(printf "%02d" $i)
  srcdur=$(printf "%.3f" $(echo "$dur * $speed" | bc))
  [ "$yaw_end" = "-" ] && yaw_end=""
  HF=${hfov:-$DEF_HFOV}; [ "$HF" = "-" ] && HF=$DEF_HFOV
  VF=${vfov:-$DEF_VFOV}; [ "$VF" = "-" ] && VF=$DEF_VFOV
  proxy=$(ls "$PROXY_DIR"/LRV_*_${file}.lrv)
  mid=$(printf "%.3f" $(echo "$start + $srcdur / 2" | bc -l))
  gains=$(python3 "$SKILL_DIR/stitch_gain.py" "$proxy" "$start" "$mid" 2>/dev/null)
  stitch=$(stitch_graph "$MODE" $EW $EH "$gains")
  if [ "$roll" = "auto" ]; then
    eval "$(python3 "$SKILL_DIR/auto_roll.py" --expr "$proxy" "$start" "$srcdur" 2>/dev/null)"
    reframe="[e]v360=e:${PROJ}:yaw=${yaw}:pitch=${pitch}:roll=${ROLL0}:h_fov=${SQ_FOV}:v_fov=${SQ_FOV}:w=${SQ_SIZE}:h=${SQ_SIZE},rotate=a='(${EXPR})*PI/180':ow=${SQ_SIZE}:oh=${SQ_SIZE}:c=black,crop=1080:1920"
  elif [ -n "$roll_end" ] && [ "$roll_end" != "-" ]; then
    delta=$((roll - roll_end))
    ang="(${delta})*clip((t-${ramp_from})/(${ramp_to}-${ramp_from})\,0\,1)*PI/180"
    reframe="[e]v360=e:${PROJ}:yaw=${yaw}:pitch=${pitch}:roll=${roll}:h_fov=${SQ_FOV}:v_fov=${SQ_FOV}:w=${SQ_SIZE}:h=${SQ_SIZE},rotate=a='${ang}':ow=${SQ_SIZE}:oh=${SQ_SIZE}:c=black,crop=1080:1920"
  elif [ -n "$yaw_end" ]; then
    # pan: shift the equirect horizontally over time (a pure yaw change), then project
    shift_x="mod((${yaw}+(${yaw_end}-(${yaw}))*t/${srcdur}+360)/360*${EW}\,${EW})"
    reframe="[e]split[e1][e2];[e1][e2]hstack,crop=${EW}:${EH}:x='${shift_x}':y=0,v360=e:${PROJ}:yaw=0:pitch=${pitch}:roll=${roll}:h_fov=${HF}:v_fov=${VF}:w=1080:h=1920"
  else
    reframe="[e]v360=e:${PROJ}:yaw=${yaw}:pitch=${pitch}:roll=${roll}:h_fov=${HF}:v_fov=${VF}:w=1080:h=1920"
  fi
  post="setpts=PTS/${speed},fps=30,format=yuv420p"
  [[ -n "${LABEL:-}" && -n "$label" ]] && post="${post},drawtext=text='${label}':x=40:y=80:fontsize=64:fontcolor=white:box=1:boxcolor=black@0.6:boxborderw=14"
  if [ "$MODE" = "full" ]; then
    src=$(ls "$CAM_DIR"/VID_*_${file}.insv)
    offset=$(awk -v f="$file" '$1==f{print $2}' "$S/sync.txt" 2>/dev/null)
    [ -z "$offset" ] && { echo "no offset for $file in $S/sync.txt (run sync_offset.py --write)"; exit 1; }
    fullstart=$(printf "%.3f" $(echo "$start + $offset" | bc))
    ffmpeg -nostdin -v error -y -hwaccel videotoolbox -ss "$fullstart" -t "$srcdur" -i "$src" -loop 1 -t "$srcdur" -i "$MASK" \
      -filter_complex "${stitch};${reframe},${post}[v];[0:a]atempo=${speed},aresample=48000[a]" \
      -map "[v]" -map "[a]" -ac 2 \
      -c:v libx264 -preset fast -crf 18 -c:a aac -b:a 192k "$OUT/$n.mp4"
  else
    ffmpeg -nostdin -v error -y -hwaccel videotoolbox -ss "$start" -t "$srcdur" -i "$proxy" -loop 1 -t "$srcdur" -i "$MASK" \
      -filter_complex "${stitch};${reframe},${post}[v];[0:a]atempo=${speed},aresample=48000[a]" \
      -map "[v]" -map "[a]" -ac 2 \
      -c:v libx264 -preset fast -crf 20 -c:a aac -b:a 192k "$OUT/$n.mp4"
  fi
  echo "file '$OUT/$n.mp4'" >> "$OUT/list.txt"
  echo "seg $n: $file @ ${start}s ${dur}s x${speed}${yaw_end:+ pan ${yaw}->${yaw_end}}${ROLL0:+ roll auto} gain ${gains}"
  unset ROLL0 EXPR
done < "$SHOTFILE"

TOTAL=$(awk '!/^#/ && NF{s+=$3} END{print s}' "$SHOTFILE")
FO=$(echo "$TOTAL-0.6" | bc)
ffmpeg -nostdin -v error -y -f concat -safe 0 -i "$OUT/list.txt" \
  -vf "fade=t=in:st=0:d=0.5,fade=t=out:st=$FO:d=0.6" \
  -af "loudnorm=I=-16:TP=-1.5:LRA=11,afade=t=in:st=0:d=0.5,afade=t=out:st=$FO:d=0.6" \
  -c:v libx264 -preset slow -crf 18 -profile:v high -level 4.1 -pix_fmt yuv420p -movflags +faststart \
  -c:a aac -b:a 192k \
  "$FINAL"
ffprobe -v error -show_entries format=duration -of csv=p=0 "$FINAL"
