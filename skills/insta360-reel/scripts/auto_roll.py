"""Estimate the camera roll that keeps the rider upright, from the proxy video.

The rider (black wetsuit, black deck pad) is the only large dark region in a view
centred on the wing handle, and always hangs away from the handle, so the direction
from the frame centre to the dark-pixel centroid gives "down".

Usage:
  auto_roll.py <lrv> <t> [<t> ...]          print the down angle at each time
  auto_roll.py --expr <lrv> <start> <dur>   print ROLL0 (v360 roll at start) and a
                                            ffmpeg rotate expression in degrees, in
                                            source seconds from the shot start
"""
import math
import os
import subprocess
import sys

SIZE = 256
FOV = 190
DARK = 55
MIN_PIXELS = 1500
STEP = 0.5


def rider_yaw():
    """RIDER_YAW from the environment (set by lens.sh), else from the $MOUNT calibration file."""
    if "RIDER_YAW" in os.environ:
        return float(os.environ["RIDER_YAW"])
    mount = os.environ.get("MOUNT")
    if mount and os.path.exists(mount):
        for line in open(mount):
            key, _, value = line.split("#")[0].partition("=")
            if key.strip() == "RIDER_YAW":
                return float(value)
    return 0.0


RIDER_YAW = rider_yaw()


def render_gray(path, t):
    vf = (f"v360=dfisheye:sg:ih_fov=193:iv_fov=193:yaw={RIDER_YAW}:pitch=0:roll=0:"
          f"h_fov={FOV}:v_fov={FOV}:w={SIZE}:h={SIZE},format=gray")
    out = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-ss", str(t), "-i", path,
                          "-frames:v", "1", "-vf", vf, "-f", "rawvideo", "-"],
                         check=True, capture_output=True).stdout
    return out[:SIZE * SIZE]


def down_angle(path, t):
    px = render_gray(path, t)
    sx = sy = n = 0
    for i, v in enumerate(px):
        if v < DARK:
            sx += i % SIZE
            sy += i // SIZE
            n += 1
    if n < MIN_PIXELS:
        return None, n
    dx = sx / n - SIZE / 2
    dy = sy / n - SIZE / 2
    return math.degrees(math.atan2(dx, dy)), n


def unwrap(angles):
    out = [angles[0]]
    for a in angles[1:]:
        while a - out[-1] > 180:
            a -= 360
        while a - out[-1] < -180:
            a += 360
        out.append(a)
    return out


def smooth(vals):
    out = []
    for i in range(len(vals)):
        lo, hi = max(0, i - 1), min(len(vals), i + 2)
        out.append(sum(vals[lo:hi]) / (hi - lo))
    return out


def series(path, start, dur):
    times, angles = [], []
    t = start - STEP
    while t <= start + dur + STEP + 1e-6:
        a, _ = down_angle(path, round(t, 3))
        times.append(t)
        angles.append(a)
        t += STEP
    # fill gaps (rider not found: splash, underwater) from the neighbours
    known = [i for i, a in enumerate(angles) if a is not None]
    if not known:
        raise SystemExit("rider never found in this shot")
    for i in range(len(angles)):
        if angles[i] is None:
            j = min(known, key=lambda k: abs(k - i))
            angles[i] = angles[j]
    return times, smooth(unwrap(angles))


def rotate_expr(times, angles, start):
    # rotate = down_angle(t) - down_angle(start): piecewise linear, cumulative
    a0 = angles[0]
    terms = [f"{0:.2f}"]
    for i in range(len(times) - 1):
        t0, t1 = times[i] - start, times[i + 1] - start
        d = angles[i + 1] - angles[i]
        if abs(d) < 0.05:
            continue
        terms.append(f"({d:.2f})*clip((t-({t0:.2f}))/{t1 - t0:.2f}\\,0\\,1)")
    return a0, "+".join(terms)


if __name__ == "__main__":
    if sys.argv[1] == "--expr":
        path, start, dur = sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
        times, angles = series(path, start, dur)
        a0, expr = rotate_expr(times, angles, start)
        roll0 = ((-a0 + 180) % 360) - 180
        print(f"ROLL0={roll0:.2f}")
        print(f"EXPR={expr}")
        print("SAMPLES=" + " ".join(f"{t - start:.1f}:{a:.0f}" for t, a in zip(times, angles)), file=sys.stderr)
    else:
        path = sys.argv[1]
        for t in sys.argv[2:]:
            ang, n = down_angle(path, float(t))
            print(f"{t}\tdown_angle={ang:.1f}\tdark_px={n}" if ang is not None else f"{t}\tno rider found")
