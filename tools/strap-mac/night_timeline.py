"""Night-timeline analyzer (Python reference) for WHOOP 4 raw captures (r10_capture/night_capture --raw).

Per-minute features from native R10 (HR @17, RR ms @18.., motion-intensity float @42, firmware step
counter u16 @1293, skin temp u16 @1917, wear @13), with v24 history rows (0x2F, HR @17) filling minutes
without live frames. Thresholds self-calibrate per night (population rule): "still" is relative to the
night's own resting-motion floor; HR levels are relative to the night's own sleeping distribution.

Episodes: settling, restless, up (walking), longest undisturbed stretch, awake, not worn. Sleep
staging (deep/REM) is NOT claimed: motion+HR alone are not validated for stages. Final wake is the
last sustained stillness; lying still after waking reads as rest (inherent limit, ~±10 min).
Usage: night_timeline.py RAW.jsonl [--from "YYYY-mm-dd HH:MM"] [--to "..."] [--lights-off "..."] [--json]
"""
from __future__ import annotations

import json
import math
import statistics
import struct
import sys
from datetime import datetime

A = sys.argv[1:]


def opt(name, default=None):
    return A[A.index(name) + 1] if name in A else default


def ts(text):
    return datetime.strptime(text, "%Y-%m-%d %H:%M").timestamp() if text else None


def load_minutes(path, lo=None, hi=None):
    mins = {}

    def slot(w):
        m = int(w // 60) * 60
        return mins.setdefault(m, {"hr": [], "mot": [], "fw": [], "skin": [], "rr": [], "wear0": 0,
                                   "live": 0, "hist_hr": []})

    for line in open(path):
        if '"k":"r10"' not in line and '"k":"hist"' not in line:
            continue
        r = json.loads(line)
        p = bytes.fromhex(r["hex"])
        if r["k"] == "r10" and len(p) >= 1919:
            w = int.from_bytes(p[7:11], "little") + int.from_bytes(p[11:13], "little") / 32768
            if (lo and w < lo) or (hi and w > hi):
                continue
            d = slot(w)
            d["live"] += 1
            if p[17]:
                d["hr"].append(p[17])
            d["mot"].append(struct.unpack_from("<f", p, 42)[0])
            d["fw"].append(int.from_bytes(p[1293:1295], "little"))
            d["skin"].append(int.from_bytes(p[1917:1919], "little") / 10)
            n = p[18] if p[18] <= 4 else 0
            d["rr"] += [int.from_bytes(p[19 + 2 * j:21 + 2 * j], "little") for j in range(n)]
            if p[13] == 0:
                d["wear0"] += 1
        elif r["k"] == "hist" and p and p[0] == 0x2F and len(p) > 17:
            w = int.from_bytes(p[7:11], "little")
            if (lo and w < lo) or (hi and w > hi):
                continue
            if 30 <= p[17] <= 220:
                slot(w)["hist_hr"].append(p[17])
    out = []
    for m in sorted(mins):
        d = mins[m]
        hr = d["hr"] or d["hist_hr"]
        fw = d["fw"]
        out.append({"t": m, "live": d["live"] > 0,
                    "hr": statistics.mean(hr) if hr else None,
                    "motion": statistics.mean(d["mot"]) if d["mot"] else None,
                    "steps": ((fw[-1] - fw[0]) & 0xFFFF) if len(fw) > 1 else 0,
                    "skin": statistics.mean(d["skin"]) if d["skin"] else None,
                    "rr": d["rr"], "off_wrist": d["wear0"] > 0 or (d["live"] and not d["hr"])})
    return out


def rmssd(rr):
    rr = [x for x in rr if 300 <= x <= 2000]
    good = rr[:1]
    for x in rr[1:]:
        if abs(x - good[-1]) <= 0.2 * good[-1]:
            good.append(x)
    if len(good) < 20:
        return None
    d = [b - a for a, b in zip(good, good[1:])]
    return math.sqrt(sum(x * x for x in d) / len(d))


def classify(mins):
    motions = sorted(m["motion"] for m in mins if m["motion"] is not None)
    floor = motions[max(0, len(motions) // 10)] if motions else 0.007   # night's resting-motion floor
    still_max = 2.5 * floor
    for m in mins:
        if m["off_wrist"]:
            m["state"] = "not_worn"
        elif m["motion"] is None:
            m["state"] = "unknown_motion"   # history-only minute: HR present, motion not decoded
        elif m["motion"] <= still_max and m["steps"] == 0:
            m["state"] = "still"
        else:
            m["state"] = "restless"
    # Walking = >= 2 consecutive minutes with firmware steps totalling >= 40 (roll-overs are isolated bursts).
    i = 0
    while i < len(mins):
        if mins[i]["steps"] > 0:
            j = i
            while j + 1 < len(mins) and mins[j + 1]["steps"] > 0:
                j += 1
            if j > i and sum(m["steps"] for m in mins[i:j + 1]) >= 40:
                for m in mins[i:j + 1]:
                    m["state"] = "up"
            i = j + 1
        else:
            i += 1
    return floor


def still_score(m):
    return 1.0 if m["state"] == "still" else 0.5 if m["state"] == "unknown_motion" else 0.0


def sustained_runs(mins, length=20, frac=0.8):
    """Indices i where the window mins[i:i+length] is >= frac still (sustained rest)."""
    out = []
    for i in range(0, max(0, len(mins) - length + 1)):
        seg = mins[i:i + length]
        if sum(still_score(m) for m in seg) / length >= frac and not any(m["state"] == "up" for m in seg):
            out.append(i)
    return out


def episodes(mins, lights_off=None):
    floor = classify(mins)
    starts = sustained_runs(mins)
    if not starts:
        return {"onset": None, "wake": None, "episodes": [], "motion_floor": floor}
    onset_i = starts[0]
    wake_i = starts[-1] + 20 - 1
    while wake_i + 1 < len(mins) and mins[wake_i + 1]["state"] in ("still", "unknown_motion"):
        wake_i += 1
    eps = []

    def add(kind, a, b, **kw):
        eps.append({"kind": kind, "start": mins[a]["t"], "end": mins[b]["t"] + 60, **kw})

    if lights_off is not None and mins[0]["t"] <= lights_off < mins[onset_i]["t"]:
        a = next(i for i, m in enumerate(mins) if m["t"] >= lights_off)
        add("settling", a, onset_i - 1)
    # Interruptions: runs of non-still minutes (gaps <= 2 still minutes merged).
    i = onset_i
    interruptions = []
    while i <= wake_i:
        if mins[i]["state"] in ("restless", "up", "not_worn"):
            j = i
            k = i
            while k + 1 <= wake_i and (mins[k + 1]["state"] in ("restless", "up", "not_worn")
                                        or any(m["state"] in ("restless", "up") for m in mins[k + 2:k + 4])
                                        and mins[k + 1]["state"] == "still"):
                k += 1
                if mins[k]["state"] in ("restless", "up", "not_worn"):
                    j = k
            seg = mins[i:j + 1]
            is_up = any(m["state"] == "up" for m in seg)
            if is_up or j - i + 1 >= 5:
                # Split: restless lead-in / walking core (first..last "up" minute) / restless tail.
                parts = [(i, j, "restless")]
                if is_up:
                    ups = [k for k in range(i, j + 1) if mins[k]["state"] == "up"]
                    parts = [(i, ups[0] - 1, "restless"), (ups[0], ups[-1], "up"), (ups[-1] + 1, j, "restless")]
                for a, b, kind in parts:
                    if b < a or (kind == "restless" and b - a + 1 < 5):
                        continue
                    part = mins[a:b + 1]
                    if kind == "restless" and all(m["state"] == "not_worn" for m in part):
                        kind = "not_worn"
                    hrs = [m["hr"] for m in part if m["hr"]]
                    add(kind, a, b, steps=sum(m["steps"] for m in part),
                        hr=round(statistics.mean(hrs)) if hrs else None)
                interruptions.append((i, j))
            i = j + 1
        else:
            i += 1
    # Deepest steady stretch: longest span between reported interruptions.
    bounds = [onset_i - 1] + [x for ij in interruptions for x in ij] + [wake_i + 1]
    best = max(((bounds[k + 1] - bounds[k] - 1, bounds[k] + 1, bounds[k + 1] - 1)
                for k in range(0, len(bounds) - 1, 2)), default=(0, None, None))
    if best[1] is not None and best[0] >= 30:
        seg = mins[best[1]:best[2] + 1]
        rr = [x for m in seg for x in m["rr"]]
        hrs = [m["hr"] for m in seg if m["hr"]]
        rv = rmssd(rr)
        add("longest_undisturbed", best[1], best[2], hr=round(statistics.mean(hrs)) if hrs else None,
            rmssd=round(rv) if rv else None)
    if wake_i + 1 < len(mins):
        add("awake", wake_i + 1, len(mins) - 1)
    eps.sort(key=lambda e: e["start"])
    hr_sleep = [m["hr"] for m in mins[onset_i:wake_i + 1] if m["hr"] and m["state"] in ("still", "unknown_motion")]
    return {"onset": mins[onset_i]["t"], "wake": mins[wake_i]["t"] + 60,
            "sleeping_hr": statistics.median(hr_sleep) if hr_sleep else None,
            "motion_floor": floor, "episodes": eps}


def main():
    path = A[0]
    mins = load_minutes(path, ts(opt("--from")), ts(opt("--to")))
    res = episodes(mins, lights_off=ts(opt("--lights-off")))
    f = lambda u: datetime.fromtimestamp(u).strftime("%H:%M") if u else "—"
    if "--json" in A:
        print(json.dumps(res))
        return
    print(f"minutes {len(mins)}  live {sum(m['live'] for m in mins)}  asleep {f(res['onset'])}  wake {f(res['wake'])}"
          f"  sleeping HR ~{res['sleeping_hr'] and round(res['sleeping_hr'])}")
    for e in res["episodes"]:
        extra = {k: v for k, v in e.items() if k not in ("kind", "start", "end")}
        print(f"  {e['kind']:12s} {f(e['start'])}–{f(e['end'])}  {extra}")


if __name__ == "__main__":
    main()
