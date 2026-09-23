"""Mac-side metrics from raw WHOOP 4 R10 captures (r10_capture.py --raw JSONL).

Steps: exact port of AtriaGyroCadenceResearchPedometer (Atria/Atria/AtriaR10Motion.swift):
rotation-magnitude (deg/s) spectral cadence over 4 s Hann windows, 0.5 s hop, band 1.3-3.0 Hz,
level gate 35 dps, prominence 1.6, sway ratio 1.4, >=2 anchors per bout, turn discount 0.6.
Kept at the app's 100 Hz assumption for parity with its July validation (measured frame rate
is 100 samples / 0.961 s ~ 104 Hz; cadence therefore reads ~4% low vs a 104 Hz model).
Spans break on any counter skip or device-time gap > 1 s (wear-gate pauses, transit loss).

HRV: RR intervals from R10 bytes 18 (count) / 19.. (u16le ms), cross-checked against
2A37 RR (flags bit4, u16le; on this strap raw x 1.024 = ms, NOT the spec 1/1024 s). Artifact filter: 300-2000 ms and |delta| <= 20%.
Usage: strap_metrics.py RAW.jsonl [RAW2.jsonl ...] [--from UNIX] [--to UNIX] [--minutes]
"""
from __future__ import annotations

import json
import math
import struct
import sys
from datetime import datetime

FS = int(__import__("os").environ.get("STRAP_FS", "100"))
WIN, HOP = int(4.0 * FS), int(0.5 * FS)
BAND_LO, BAND_HI, FLOOR, CEIL = 1.3, 3.0, 0.3, 4.0
LEVEL_GATE, PROMINENCE, SWAY, MIN_ANCHORS, TURN_DISCOUNT = 35.0, 1.6, 1.4, 2, 0.6
GYR_SCALE = 0.06103515625
HANN = [0.5 * (1 - math.cos(2 * math.pi * i / (WIN - 1))) for i in range(WIN)]
BIN_HZ = FS / WIN
FLOOR_BIN = math.ceil(FLOOR / BIN_HZ)
CEIL_BIN = math.floor(CEIL / BIN_HZ)
TRIG = {b: ([math.cos(-2 * math.pi * b * n / WIN) for n in range(WIN)],
            [math.sin(-2 * math.pi * b * n / WIN) for n in range(WIN)]) for b in range(FLOOR_BIN, CEIL_BIN + 1)}


def window_verdict(window):
    mean = sum(window) / WIN
    if mean < LEVEL_GATE:
        return (False, None)
    tapered = [(window[i] - mean) * HANN[i] for i in range(WIN)]
    mags = {}
    for b, (cs, sn) in TRIG.items():
        re = sum(t * c for t, c in zip(tapered, cs))
        im = sum(t * s for t, s in zip(tapered, sn))
        mags[b] = math.sqrt(re * re + im * im)
    in_band = {b: m for b, m in mags.items() if BAND_LO <= b * BIN_HZ <= BAND_HI}
    below = [m for b, m in mags.items() if FLOOR < b * BIN_HZ < BAND_LO]
    ordered = sorted(mags.values())
    median = ordered[len(ordered) // 2] if ordered else 0
    if not in_band or median <= 0:
        return (True, None)
    pb, pv = max(in_band.items(), key=lambda kv: kv[1])
    if pv / median < PROMINENCE or (max(below) if below else 0) > SWAY * pv:
        return (True, None)
    cadence = pb * BIN_HZ
    lo, hi = mags.get(pb - 1), mags.get(pb + 1)
    if lo is not None and hi is not None:
        den = lo - 2 * pv + hi
        if abs(den) > 1e-12:
            cadence += min(0.5, max(-0.5, 0.5 * (lo - hi) / den)) * BIN_HZ
    return (True, cadence)


def span_steps(samples):
    if len(samples) < WIN:
        return 0.0, []
    verdicts = []
    for start in range(0, len(samples) - WIN + 1, HOP):
        verdicts.append(window_verdict(samples[start:start + WIN]))
    total, bouts, i = 0.0, [], 0
    while i < len(verdicts):
        if not verdicts[i][0]:
            i += 1
            continue
        end = i
        while end < len(verdicts) and verdicts[end][0]:
            end += 1
        anchors = sorted(c for _, c in verdicts[i:end] if c is not None)
        if len(anchors) >= MIN_ANCHORS:
            med = anchors[len(anchors) // 2]
            eff = len(anchors) + TURN_DISCOUNT * ((end - i) - len(anchors))
            steps = eff * (HOP / FS) * med
            total += steps
            bouts.append({"start_s": i * HOP / FS, "dur_s": (end - i) * HOP / FS,
                          "cadence_spm": round(med * 60, 1), "steps": round(steps, 1)})
        i = end
    return total, bouts


def load(paths, lo, hi):
    r10, hr = [], []
    for path in paths:
        for line in open(path):
            r = json.loads(line)
            if not lo <= r["w"] <= hi:
                continue
            p = bytes.fromhex(r["hex"])
            if r["k"] == "r10" and len(p) >= 1288:
                gyr = [struct.unpack_from("<100h", p, o) for o in (688, 888, 1088)]
                rot = [math.sqrt((gyr[0][k] ** 2 + gyr[1][k] ** 2 + gyr[2][k] ** 2)) * GYR_SCALE for k in range(100)]
                n_rr = p[18] if p[18] <= 4 else 0
                rr = [int.from_bytes(p[19 + 2 * j:21 + 2 * j], "little") for j in range(n_rr)]
                r10.append({"w": r["w"], "seq": int.from_bytes(p[3:5], "little"),
                            "ts": int.from_bytes(p[7:11], "little"), "hr": p[17], "rr": rr, "rot": rot})
            elif r["k"] == "hr":
                flags = p[0]
                off = 3 if flags & 1 else 2
                if flags & 0x08:
                    off += 2
                rrs = []
                if flags & 0x10:
                    while off + 1 < len(p):
                        rrs.append(int.from_bytes(p[off:off + 2], "little") * 1.024)  # empirical: WHOOP 2A37 RR raw x1.024 = ms (R10 RR ms matches bpm)
                        off += 2
                hr.append({"w": r["w"], "bpm": p[1] if not flags & 1 else int.from_bytes(p[1:3], "little"), "rr": rrs})
    r10.sort(key=lambda x: x["w"])
    return r10, hr


def spans(r10):
    out, cur = [], []
    for f in r10:
        if cur:
            prev = cur[-1]
            if ((f["seq"] - prev["seq"]) & 0xFFFF) != 1 or not 0 <= f["ts"] - prev["ts"] <= 1:
                out.append(cur)
                cur = []
        cur.append(f)
    if cur:
        out.append(cur)
    return out


def hrv(rr):
    clean = [x for x in rr if 300 <= x <= 2000]
    good = [clean[0]] if clean else []
    for x in clean[1:]:
        if abs(x - good[-1]) <= 0.2 * good[-1]:
            good.append(x)
    if len(good) < 10:
        return None
    diffs = [b - a for a, b in zip(good, good[1:])]
    mean = sum(good) / len(good)
    return {"n_rr": len(good), "rejected": len(rr) - len(good), "mean_rr_ms": round(mean, 1),
            "hr_from_rr": round(60000 / mean, 1),
            "rmssd_ms": round(math.sqrt(sum(d * d for d in diffs) / len(diffs)), 1),
            "sdnn_ms": round(math.sqrt(sum((x - mean) ** 2 for x in good) / len(good)), 1)}


def main():
    args = sys.argv[1:]
    lo = float(args[args.index("--from") + 1]) if "--from" in args else 0
    hi = float(args[args.index("--to") + 1]) if "--to" in args else 1e12
    paths = [a for a in args if a.endswith(".jsonl")]
    r10, hr = load(paths, lo, hi)
    if not r10:
        print("no R10 frames")
        return
    fmt = lambda w: datetime.fromtimestamp(w).strftime("%H:%M:%S")
    sp = spans(r10)
    total = 0.0
    print(f"R10 frames {len(r10)}  {fmt(r10[0]['w'])} -> {fmt(r10[-1]['w'])}  spans {len(sp)}")
    for s in sp:
        steps, bouts = span_steps([v for f in s for v in f["rot"]])
        total += steps
        if bouts:
            for b in bouts:
                print(f"  bout @ {fmt(s[0]['w'] + b['start_s'] * 0.961)} dur {b['dur_s']}s cadence {b['cadence_spm']} spm steps {b['steps']}")
    print(f"STEPS total {total:.1f} (gyro-cadence port, 100 Hz parity)")
    r10_rr = [x for f in r10 for x in f["rr"]]
    std_rr = [x for h in hr for x in h["rr"]]
    print("HRV from R10 RR:", json.dumps(hrv(r10_rr)))
    print("HRV from 2A37 RR:", json.dumps(hrv(std_rr)))
    if "--minutes" in args:
        buckets = {}
        for f in r10:
            buckets.setdefault(int(f["w"] // 60), []).append(f)
        for m in sorted(buckets):
            fs = buckets[m]
            rot = sum(sum(f["rot"]) for f in fs) / (100 * len(fs))
            print(f"  {fmt(m * 60)} frames {len(fs)} mean_rot {rot:.1f} dps hr {round(sum(f['hr'] for f in fs) / len(fs))}")


if __name__ == "__main__":
    main()


class AccelPeakPedometer:
    """Exact port of AtriaStrapPedometer.StreamingDetector (acceleration-magnitude peaks, g)."""

    def __init__(self, filter_length=8, peak_window=29, sensitivity=0.06, confirmation=6):
        self.fl, self.pw, self.sens, self.conf = filter_length, peak_window | 1, sensitivity, confirmation
        self.half = self.pw // 2
        self.fw, self.fsum, self.lp = [], 0.0, []
        self.n, self.mean, self.thr_hist, self.thr = 0, 0.0, [], None
        self.possible, self.regular, self.seek_max, self.cur_max, self.cur_max_i = 0, False, True, 0.0, -1
        self.steps = 0

    def ingest(self, m):
        self.n += 1
        self.mean += (m - self.mean) / self.n
        self.fw.append(m)
        self.fsum += m
        if len(self.fw) > self.fl:
            self.fsum -= self.fw.pop(0)
        self.lp.append(self.fsum / len(self.fw))
        if len(self.lp) < self.pw:
            return
        c = self.lp[self.half]
        is_max = all(v <= c for v in self.lp)
        is_min = all(v >= c for v in self.lp)
        if is_max or is_min:
            self._candidate(self.n - self.half - 1, is_max, c)
        self.lp.pop(0)

    def _candidate(self, idx, is_max, v):
        if self.seek_max:
            if is_max:
                self.cur_max, self.cur_max_i, self.seek_max = v, idx, False
            return
        if is_max:
            if v > self.cur_max:
                self.cur_max, self.cur_max_i = v, idx
            return
        if idx - self.cur_max_i > 120:
            self.seek_max, self.possible, self.regular = True, 0, False
            return
        t = self.thr if self.thr is not None else self.mean
        if self.cur_max > t + self.sens / 2 and v < t - self.sens / 2:
            if self.cur_max - v > self.sens:
                self.thr_hist.append((self.cur_max + v) / 2)
                if len(self.thr_hist) > 4:
                    self.thr_hist.pop(0)
                self.thr = sum(self.thr_hist) / len(self.thr_hist)
            self.possible += 1
            if self.regular:
                self.steps += 1
            elif self.possible >= self.conf:
                self.steps += self.possible
                self.regular = True
        else:
            self.possible, self.regular = 0, False
        self.seek_max = True


def accel_magnitudes(path, lo, hi):
    out = []
    for line in open(path):
        r = json.loads(line)
        if r["k"] != "r10" or not lo <= r["w"] <= hi:
            continue
        p = bytes.fromhex(r["hex"])
        ax = [struct.unpack_from("<100h", p, o) for o in (85, 285, 485)]
        out.extend(math.sqrt(ax[0][k] ** 2 + ax[1][k] ** 2 + ax[2][k] ** 2) / 4096 for k in range(100))
    return out
