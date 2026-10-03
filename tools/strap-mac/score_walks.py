"""Score labelled walks (metronome_walk.py labels) against every step source in an R10 raw capture.

Sources: firmware step counter (R10 u16le @1293, delta over the window), the app's gyro-cadence
detector (strap_metrics.py port, 100 Hz parity), and the app's accel-peak detector (x1.11 gain).
Window = [start - PRE, stop + POST] so detector warm-up/confirmation is included.
Usage: score_walks.py RAW.jsonl [--labels PATH] [--pre S] [--post S] [--gate GX]
"""
from __future__ import annotations

import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.argv, _argv = [sys.argv[0]], sys.argv
src = open(os.path.join(HERE, "strap_metrics.py")).read().replace('if __name__ == "__main__":\n    main()', "")
exec(compile(src, "strap_metrics", "exec"))
sys.argv = _argv

args = sys.argv[1:]
raw = args[0]
labels_path = args[args.index("--labels") + 1] if "--labels" in args else "/tmp/atria-ble/walk-labels.jsonl"
PRE = float(args[args.index("--pre") + 1]) if "--pre" in args else 3.0
POST = float(args[args.index("--post") + 1]) if "--post" in args else 6.0


GATE_X = float(args[args.index("--gate") + 1]) if "--gate" in args else 0.7


def frame_gravity(lo, hi):
    g = {}
    for line in open(raw):
        r = json.loads(line)
        if r["k"] == "r10" and lo <= r["w"] <= hi:
            p = bytes.fromhex(r["hex"])
            g[int.from_bytes(p[3:5], "little")] = struct.unpack_from("<3f", p, 46)
    return g


def gated_gyro(frames, grav):
    """Gyro-cadence steps over contiguous frames whose gravity x >= GATE_X (arm hanging)."""
    total, run = 0.0, []
    for f in frames + [None]:
        ok = f is not None and grav.get(f["seq"], (0, 0, 0))[0] >= GATE_X
        if ok and (not run or ((f["seq"] - run[-1]["seq"]) & 0xFFFF) == 1):
            run.append(f)
            continue
        if run:
            total += span_steps([v for x in run for v in x["rot"]])[0]
        run = [f] if ok else []
    return total


def firmware_delta(lo, hi):
    vals = []
    for line in open(raw):
        r = json.loads(line)
        if r["k"] == "r10" and lo <= r["w"] <= hi:
            p = bytes.fromhex(r["hex"])
            vals.append(int.from_bytes(p[1293:1295], "little"))
    return (vals[-1] - vals[0]) if len(vals) > 1 else None


rows = []
for line in open(labels_path):
    lab = json.loads(line)
    lo, hi = lab["start"] - PRE, lab["stop"] + POST
    r10, _ = load([raw], lo, hi)
    gyro = sum(span_steps([v for f in s for v in f["rot"]])[0] for s in spans(r10))
    det = AccelPeakPedometer()
    for m in accel_magnitudes(raw, lo, hi):
        det.ingest(m)
    fw = firmware_delta(lo, hi)
    grav = frame_gravity(lo, hi)
    gvals = [grav[f["seq"]] for f in r10 if f["seq"] in grav]
    gmean = [round(sum(v[i] for v in gvals) / len(gvals), 2) for i in range(3)] if gvals else None
    t = lab["truth_steps"]
    row = {"label": lab["label"], "spm": lab["spm"], "truth": t, "firmware": fw,
           "gyro": round(gyro, 1), "gyro_gated": round(gated_gyro(r10, grav), 1),
           "accel": round(det.steps * 1.11, 1), "gravity": gmean, "frames": len(r10)}
    for k in ("firmware", "gyro", "gyro_gated", "accel"):
        row[k + "_err_pct"] = None if row[k] is None or t == 0 else round(100 * (row[k] - t) / t, 1)
    rows.append(row)
    print(json.dumps(row))
