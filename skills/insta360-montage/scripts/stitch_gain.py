"""Per-channel gain that matches the back lens to the front lens in the lens overlap.

Both lenses are rendered to a small equirect and compared in the two 12-degree bands around
yaw +-90 (black pixels outside a lens' coverage are ignored).
Usage: stitch_gain.py <insv|lrv> <seconds> [<seconds> ...]   -> prints "GR GG GB"
"""
import subprocess
import sys

W, H = 720, 360
FOV = 193
BAND = W * 12 // 360


def graph_for(path):
    fa = f"v360=fisheye:e:ih_fov={FOV}:iv_fov={FOV}:w={W}:h={H}"
    fb = f"v360=fisheye:e:ih_fov={FOV}:iv_fov={FOV}:yaw=180:w={W}:h={H}"
    if path.endswith(".insv"):
        head = f"[0:0]{fa},split[a1][a2];[0:1]{fb},split[b1][b2];"
    else:
        # proxy: both lenses side by side, front (rider) lens on the right
        head = (f"[0:v]split[v1][v2];[v1]crop=iw/2:ih:iw/2:0,{fa},split[a1][a2];"
                f"[v2]crop=iw/2:ih:0:0,{fb},split[b1][b2];")
    x1, x2 = W * 3 // 4 - BAND // 2, W // 4 - BAND // 2
    return (head +
            f"[a1]crop={BAND}:{H}:{x1}:0[ar];[a2]crop={BAND}:{H}:{x2}:0[al];"
            f"[b1]crop={BAND}:{H}:{x1}:0[br];[b2]crop={BAND}:{H}:{x2}:0[bl];"
            f"[ar][al][br][bl]hstack=4,format=rgb24")


def band_means(path, t):
    raw = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-ss", str(t), "-i", path, "-frames:v", "1",
                          "-filter_complex", graph_for(path), "-f", "rawvideo", "-"],
                         check=True, capture_output=True).stdout
    width = BAND * 4
    sums = [[0, 0, 0], [0, 0, 0]]
    counts = [0, 0]
    for y in range(H):
        row = raw[y * width * 3:(y + 1) * width * 3]
        for x in range(width):
            px = row[x * 3:x * 3 + 3]
            if max(px) < 8:
                continue
            k = 0 if x < BAND * 2 else 1
            for c in range(3):
                sums[k][c] += px[c]
            counts[k] += 1
    return ([s / max(1, counts[0]) for s in sums[0]],
            [s / max(1, counts[1]) for s in sums[1]])


if __name__ == "__main__":
    path = sys.argv[1]
    total = [0.0, 0.0, 0.0]
    n = 0
    for t in sys.argv[2:]:
        front, back = band_means(path, float(t))
        g = [min(1.6, max(0.6, f / b)) for f, b in zip(front, back)]
        print(f"t={t}  front={[round(v) for v in front]}  back={[round(v) for v in back]}  gain={[round(v, 3) for v in g]}",
              file=sys.stderr)
        total = [a + b for a, b in zip(total, g)]
        n += 1
    print(" ".join(f"{g / n:.3f}" for g in total))
