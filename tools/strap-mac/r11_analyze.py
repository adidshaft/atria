"""Offline decoder/analyzer for WHOOP 4 R11 (packet 0x2B, record 0x0B) from r10_capture --raw.

Layout (reverse-engineered 2026-09-23 from Mac captures, see docs/WHOOP4_PROTOCOL_FINDINGS.md):
  payload[0:3]  2B 0B 00
  payload[3:5]  u16le frame counter (equals the paired R10 frame's counter)
  payload[7:11] u32le device second (equals the paired R10)
  payload[11:13] varying (sub-second tick candidate)
  4 slots, slot k header at 13 + 425k (25 bytes; header[1] = sample count, 0 = empty),
  data at 38 + 425k: channel 0 = 50 x int32le, channel 1 = next 50 x int32le.
Usage: r11_analyze.py RAW.jsonl [--from WALL] [--to WALL]
"""
from __future__ import annotations

import json
import math
import sys

SLOT0, PITCH, HDR = 13, 425, 25


def slots(p: bytes):
    out = []
    for k in range(4):
        h = p[SLOT0 + PITCH * k: SLOT0 + PITCH * k + HDR]
        n = h[1]
        chans = []
        if n:
            base = SLOT0 + PITCH * k + HDR
            for c in range(2):
                o = base + 4 * n * c
                chans.append([int.from_bytes(p[o + 4 * i:o + 4 * i + 4], "little", signed=True) for i in range(n)])
        out.append({"slot": k, "n": n, "hdr": h.hex(), "chans": chans})
    return out


def dominant_bpm(series, fs, lo=40, hi=200):
    """Dominant frequency (in beats/min) of a detrended series via a plain DFT scan."""
    n = len(series)
    if n < 32:
        return None, 0.0
    mean = sum(series) / n
    x = [v - mean for v in series]
    # linear detrend
    t_mean = (n - 1) / 2
    slope = sum((i - t_mean) * x[i] for i in range(n)) / sum((i - t_mean) ** 2 for i in range(n))
    x = [x[i] - slope * (i - t_mean) for i in range(n)]
    best, best_p, total = None, 0.0, 0.0
    for bpm in range(lo, hi + 1):
        f = bpm / 60.0
        re = sum(x[i] * math.cos(2 * math.pi * f * i / fs) for i in range(n))
        im = sum(x[i] * math.sin(2 * math.pi * f * i / fs) for i in range(n))
        pw = re * re + im * im
        total += pw
        if pw > best_p:
            best, best_p = bpm, pw
    return best, (best_p / total if total else 0.0)


def main():
    path = sys.argv[1]
    lo = float(sys.argv[sys.argv.index("--from") + 1]) if "--from" in sys.argv else 0
    hi = float(sys.argv[sys.argv.index("--to") + 1]) if "--to" in sys.argv else 1e12
    rows = [json.loads(line) for line in open(path)]
    rows = [r for r in rows if lo <= r["w"] <= hi]
    r11 = [(r["w"], bytes.fromhex(r["hex"])) for r in rows if r["k"] == "r11"]
    hr = [(r["w"], bytes.fromhex(r["hex"])[1]) for r in rows if r["k"] == "hr"]
    print(json.dumps({"r11_frames": len(r11), "hr_samples": len(hr)}))
    if not r11:
        return
    headers = {}
    series = {}
    for w, p in r11:
        for s in slots(p):
            headers.setdefault((s["slot"], s["hdr"]), 0)
            headers[(s["slot"], s["hdr"])] += 1
            for c, ch in enumerate(s["chans"]):
                series.setdefault((s["slot"], c), []).extend(ch)
    print("slot headers seen:")
    for (k, h), n in sorted(headers.items()):
        print(f"  slot{k} x{n}: {h}")
    fs = 50 / 0.961
    hr_mean = sum(b for _, b in hr) / len(hr) if hr else None
    print(f"channel stats (fs~{fs:.1f} Hz), 2A37 mean HR {hr_mean and round(hr_mean, 1)}:")
    for key, s in sorted(series.items()):
        mean = sum(s) / len(s)
        sd = math.sqrt(sum((v - mean) ** 2 for v in s) / len(s))
        bpm, share = dominant_bpm(s[-600:], fs)
        print(f"  slot{key[0]} ch{key[1]}: n={len(s)} mean={mean:.0f} sd={sd:.0f} min={min(s)} max={max(s)}"
              f" dominant={bpm} bpm (power share {share:.2f})")


if __name__ == "__main__":
    main()
