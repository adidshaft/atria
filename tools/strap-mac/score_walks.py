"""Score labelled walks (metronome_walk.py labels) against every step source in an R10 raw capture.

Sources: firmware step counter (R10 u16le @1293, delta over the window), the app's gyro-cadence
detector (strap_metrics.py port, 100 Hz parity), and the app's accel-peak detector (x1.11 gain).
Window = [start - PRE, stop + POST] so detector warm-up/confirmation is included.
Usage: score_walks.py RAW.jsonl [--labels PATH] [--pre S] [--post S]
"""
from __future__ import annotations

import json
import os
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
    t = lab["truth_steps"]
    row = {"label": lab["label"], "spm": lab["spm"], "truth": t, "firmware": fw,
           "gyro": round(gyro, 1), "accel": round(det.steps * 1.11, 1), "frames": len(r10)}
    for k in ("firmware", "gyro", "accel"):
        row[k + "_err_pct"] = None if row[k] is None else round(100 * (row[k] - t) / t, 1)
    rows.append(row)
    print(json.dumps(row))
