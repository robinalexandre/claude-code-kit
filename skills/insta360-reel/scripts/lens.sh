#!/bin/zsh
# Shared lens/projection settings, sourced by the other scripts.
# Verified on an Insta360 X6 (.insv = two 1920x1920 fisheye streams, .lrv = both lenses side by side,
# front/rider lens = stream 0:0 = right half of the proxy). For another camera, run check_layout.sh
# and stitch_cal.sh first.
FOV=${FOV:-193}                       # per-lens field of view (stitch_cal.sh minimises the overlap mismatch)
LENS="ih_fov=${FOV}:iv_fov=${FOV}"
FEATHER=${FEATHER:-13}                # degrees of blend across the lens overlap (2*(FOV/2-90) = 13 for FOV 193)
INSV_FRONT="[0:0]"                    # .insv stream holding the front (rider) lens
INSV_BACK="[0:1]"
# Mount calibration, measured once per session (SKILL.md section 2) in the file named by $MOUNT:
# RIDER_YAW/RIDER_PITCH point at the rider in the dual-fisheye layout (yaw 0 = right half of the proxy),
# RIDER_ROLL shows the rider upright on review views (the camera looks down from the wing).
[ -n "${MOUNT:-}" ] && source "$MOUNT"
export RIDER_YAW=${RIDER_YAW:-0} RIDER_PITCH=${RIDER_PITCH:-30} RIDER_ROLL=${RIDER_ROLL:-180}
if (( ${RIDER_YAW#-} > 90 )); then RIDER_CROP_X=0; else RIDER_CROP_X="iw/2"; fi
# default 9:16 framing on the rider (stereographic keeps a very wide view natural)
PROJ=${PROJ:-sg}
DEF_HFOV=${HFOV:-140}
DEF_VFOV=${VFOV:-190}
# square render used when the frame is rotated (rider-lock / turns); 250 matches the scale of 1920 px at v_fov 190
SQ_FOV=${SQ_FOV:-250}
SQ_SIZE=2720

# stitch_graph <mode> <EW> <EH> <gains "r g b">  -> filtergraph text that produces [e], a blended equirect
# from inputs 0 (video) and 1 (the feather mask image)
stitch_graph() {
  local mode=$1 ew=$2 eh=$3 g=($=4)
  local fa="v360=fisheye:e:${LENS}:w=${ew}:h=${eh}"
  local fb="v360=fisheye:e:${LENS}:yaw=180:w=${ew}:h=${eh},colorchannelmixer=rr=${g[1]}:gg=${g[2]}:bb=${g[3]}"
  if [ "$mode" = "full" ]; then
    echo "${INSV_FRONT}${fa}[fa];${INSV_BACK}${fb}[fb];[1:v]format=gray[m];[fb][fa][m]maskedmerge[e]"
  else
    echo "[0:v]split[v1][v2];[v1]crop=iw/2:ih:iw/2:0,${fa}[fa];[v2]crop=iw/2:ih:0:0,${fb}[fb];[1:v]format=gray[m];[fb][fa][m]maskedmerge[e]"
  fi
}

# make_mask <EW> <EH> <out.png>: 255 in the front lens region, 0 in the back, linear ramp over the overlap
make_mask() {
  local ew=$1 eh=$2 out=$3 bw=$(( $1 * FEATHER / 360 ))
  ffmpeg -nostdin -v error -f lavfi -i "nullsrc=size=${ew}x${eh}:rate=1,format=gray" -frames:v 1 \
    -vf "geq=lum='255*clip((${ew}/4+${bw}/2-abs(X-${ew}/2))/${bw},0,1)'" -y "$out"
}
