"""Measure the time offset between each .insv and its .lrv proxy from their (identical) audio.

The offset is constant within a recording but differs between recordings (0 to ~0.6 s on an X6).
Every cut is made on the proxy timeline; the renderer adds the offset when reading the .insv.

Usage:
  sync_offset.py <insv> <lrv> <t1> [<t2> ...]      print the lag at each probe time
  sync_offset.py --write <sync.txt> <camera dir> <proxy dir>
        measure every pair at three probe times, check they agree, write "<nnn> <offset>" lines
"""
import glob
import os
import struct
import subprocess
import sys

RATE = 8000
WIN = 40          # envelope window in samples (5 ms)
SPAN = 12.0       # seconds of audio to compare
MAX_LAG = 2.0     # seconds


def envelope(path, start):
    pcm = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-ss", str(start), "-t", str(SPAN),
                          "-i", path, "-vn", "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-"],
                         check=True, capture_output=True).stdout
    n = len(pcm) // 2
    samples = struct.unpack(f"<{n}h", pcm[:n * 2])
    env = []
    for i in range(0, n - WIN, WIN):
        env.append(sum(abs(s) for s in samples[i:i + WIN]) / WIN)
    mean = sum(env) / len(env)
    return [e - mean for e in env]


def best_lag(a, b):
    max_lag = int(MAX_LAG * RATE / WIN)
    best, best_score = 0, None
    for lag in range(-max_lag, max_lag + 1):
        score = 0.0
        for i in range(max(0, lag), min(len(a), len(b) + lag)):
            score += a[i] * b[i - lag]
        if best_score is None or score > best_score:
            best, best_score = lag, score
    return best


def offset_at(insv, lrv, t):
    a = envelope(insv, t - SPAN / 2)
    b = envelope(lrv, t - SPAN / 2)
    return best_lag(a, b) * WIN / RATE


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "csv=p=0", path], check=True, capture_output=True, text=True).stdout
    return float(out.strip())


def suffix(path):
    return os.path.basename(path).rsplit(".", 1)[0].rsplit("_", 1)[1]


if __name__ == "__main__":
    if sys.argv[1] == "--write":
        out, cam, proxy = sys.argv[2], sys.argv[3], sys.argv[4]
        lines = ["# insv_time = lrv_time + offset (measured by sync_offset.py on the audio)"]
        for insv in sorted(glob.glob(os.path.join(cam, "VID_*.insv"))):
            n = suffix(insv)
            lrvs = glob.glob(os.path.join(proxy, f"LRV_*_{n}.lrv"))
            if not lrvs:
                print(f"{n}: no proxy, skipped")
                continue
            d = duration(insv)
            probes = [60, d / 2, d - 60] if d > 180 else [d / 2]
            lags = [offset_at(insv, lrvs[0], t) for t in probes]
            spread = max(lags) - min(lags)
            flag = "" if spread <= 0.02 else f"  WARNING: offset varies by {spread:.3f}s, check manually"
            print(f"{n}: " + " ".join(f"{l:+.3f}" for l in lags) + flag)
            lines.append(f"{n} {sum(lags) / len(lags):.3f}")
        with open(out, "w") as f:
            f.write("\n".join(lines) + "\n")
        print(f"wrote {out}")
    else:
        insv, lrv = sys.argv[1], sys.argv[2]
        for t in sys.argv[3:]:
            lag = offset_at(insv, lrv, float(t))
            print(f"t={float(t):.0f}s  insv = lrv + {lag:+.3f}s")
