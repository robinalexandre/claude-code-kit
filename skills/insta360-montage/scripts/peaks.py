"""Motion peaks of one recording, from motion.sh output.

Usage: peaks.py <m<nnn>.txt> [all|<top n>] [min gap seconds, default 4]
"all" (the default) keeps every peak above mean + 1 standard deviation, so nothing is cut by an
arbitrary count: on one test session every jump sat beyond the 40 strongest peaks.
"""
import re
import sys

path = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else "all"
top_n = None if mode == "all" else int(mode)
min_gap = float(sys.argv[3]) if len(sys.argv) > 3 else 4.0

frames = []
pts = None
for line in open(path):
    m = re.search(r"pts_time:([\d.]+)", line)
    if m:
        pts = float(m.group(1))
        continue
    m = re.search(r"YAVG=([\d.]+)", line)
    if m and pts is not None:
        frames.append((pts, float(m.group(1))))

# smooth over ~1 s (5 frames) so a jump's burst of motion beats single-frame noise
vals = [v for _, v in frames]
win = 5
smooth = []
for i in range(len(vals)):
    lo, hi = max(0, i - win // 2), min(len(vals), i + win // 2 + 1)
    smooth.append(sum(vals[lo:hi]) / (hi - lo))

mean = sum(smooth) / len(smooth)
std = (sum((v - mean) ** 2 for v in smooth) / len(smooth)) ** 0.5
floor = mean + std if top_n is None else float("-inf")

cands = sorted(range(len(smooth)), key=lambda i: -smooth[i])
picked = []
for i in cands:
    if smooth[i] < floor:
        break
    t = frames[i][0]
    if all(abs(t - p[0]) >= min_gap for p in picked):
        picked.append((t, smooth[i]))
    if top_n is not None and len(picked) >= top_n:
        break

print(f"frames={len(frames)} mean={mean:.2f} std={std:.2f} peaks={len(picked)}")

for t, v in sorted(picked):
    m, s = divmod(t, 60)
    print(f"{int(m):02d}:{s:05.2f}  {v:6.2f}")
