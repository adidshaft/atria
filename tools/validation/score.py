#!/usr/bin/env python3
"""Score Atria against a reference (metric validation plan §2 and §3).

Subcommands (all inputs are CSVs from atria_export.py / ref_hr_strap.py, plus a
windows file with one JSON object per line: {"label", "start", "stop"} in unix
seconds — metronome_track.py writes exactly this):

  hr     ATRIA_HR REF_HR WINDOWS   per-window MAE, bias, % within 5 bpm, lag
  rr     ATRIA_RR REF_RR WINDOWS   beat match rate within 20 ms, RMSSD bias
  sleep  ATRIA_SLEEPS DIARY        onset/wake/duration error per night
                                   (diary columns: lights_out,wake as unix or
                                   'YYYY-MM-DD HH:MM' local)

Prints a table and writes score.json beside the first input. Nothing leaves
the machine. Pass bars default to the plan's; override with --bar key=value.
"""
from __future__ import annotations

import csv
import json
import math
import statistics
import sys
from datetime import datetime
from pathlib import Path

BARS = {
    "hr_rest_mae": 2.0, "hr_walk_mae": 4.0, "hr_hard_mae": 6.0, "hr_within5": 0.85, "hr_lag": 5.0,
    "rr_match": 0.90, "rmssd_bias": 3.0,
    "sleep_edge_min": 15.0, "sleep_duration_min": 20.0,
}


def read_series(path: str, value_col: str) -> list[tuple[float, float]]:
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            v = r.get(value_col, "")
            if v not in ("", None):
                rows.append((float(r["unix_time"]), float(v)))
    return sorted(rows)


def read_windows(path: str) -> list[dict]:
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def per_second(series, start, stop) -> dict[int, float]:
    buckets: dict[int, list[float]] = {}
    for t, v in series:
        if start <= t < stop:
            buckets.setdefault(int(t), []).append(v)
    return {s: statistics.median(v) for s, v in buckets.items()}


def hr_window(atria, ref, start, stop) -> dict:
    a, r = per_second(atria, start, stop), per_second(ref, start, stop)
    common = sorted(set(a) & set(r))
    if not common:
        return {"pairs": 0}
    diffs = [a[s] - r[s] for s in common]
    best_lag, best_mae = 0, math.inf
    for lag in range(-10, 11):  # positive lag: Atria trails the reference
        pairs = [(a[s + lag], r[s]) for s in r if s + lag in a]
        if len(pairs) >= max(10, len(common) // 2):
            # Shape match after removing the constant offset (bias is
            # reported separately), so a steady offset cannot pull the lag.
            offset = sum(x - y for x, y in pairs) / len(pairs)
            mae = sum(abs(x - y - offset) for x, y in pairs) / len(pairs)
            if mae < best_mae:
                best_lag, best_mae = lag, mae
    return {
        "pairs": len(common),
        "mae": round(sum(abs(d) for d in diffs) / len(diffs), 2),
        "bias": round(sum(diffs) / len(diffs), 2),
        "within5": round(sum(abs(d) <= 5 for d in diffs) / len(diffs), 3),
        "lag_s": best_lag,
    }


def clean_rr(rr: list[float]) -> list[float]:
    out = []
    for v in rr:
        if not 300 <= v <= 2000:
            continue
        if out and abs(v - out[-1]) > 0.2 * out[-1]:
            continue
        out.append(v)
    return out


def rmssd(rr: list[float]) -> float | None:
    rr = clean_rr(rr)
    if len(rr) < 20:
        return None
    return math.sqrt(sum((b - a) ** 2 for a, b in zip(rr, rr[1:])) / (len(rr) - 1))


def rr_window(atria, ref, start, stop) -> dict:
    a = [(t, v) for t, v in atria if start <= t < stop]
    r = [(t, v) for t, v in ref if start <= t < stop]
    matched = 0
    j = 0
    for t, v in r:
        while j < len(a) and a[j][0] < t - 0.3:
            j += 1
        k = j
        while k < len(a) and a[k][0] <= t + 0.3:
            if abs(a[k][1] - v) <= 20:
                matched += 1
                break
            k += 1
    ra, rr_ = rmssd([v for _, v in a]), rmssd([v for _, v in r])
    return {
        "ref_beats": len(r), "atria_beats": len(a),
        "match": round(matched / len(r), 3) if r else None,
        "rmssd_atria": round(ra, 1) if ra else None,
        "rmssd_ref": round(rr_, 1) if rr_ else None,
        "rmssd_bias": round(ra - rr_, 1) if ra and rr_ else None,
    }


def parse_time(value: str) -> float:
    try:
        return float(value)
    except ValueError:
        return datetime.strptime(value.strip(), "%Y-%m-%d %H:%M").timestamp()


def sleep_scores(sleeps_path: str, diary_path: str) -> list[dict]:
    with open(sleeps_path) as f:
        sleeps = [(float(r["start"]), float(r["end"]), r["is_nap"] == "True") for r in csv.DictReader(f)]
    rows = []
    with open(diary_path) as f:
        for d in csv.DictReader(f):
            on, wake = parse_time(d["lights_out"]), parse_time(d["wake"])
            overlap = [s for s in sleeps if s[0] < wake and s[1] > on]
            if not overlap:
                rows.append({"night": d["lights_out"], "found": False})
                continue
            main = max(overlap, key=lambda s: min(s[1], wake) - max(s[0], on))
            rows.append({
                "night": d["lights_out"], "found": True, "is_nap": main[2],
                "onset_err_min": round((main[0] - on) / 60, 1),
                "wake_err_min": round((main[1] - wake) / 60, 1),
                "duration_err_min": round(((main[1] - main[0]) - (wake - on)) / 60, 1),
                "pieces": len(overlap),
            })
    return rows


def hr_bar(label: str, bars: dict) -> float:
    label = label.lower()
    if any(k in label for k in ("rest", "sit", "recovery", "supine")):
        return bars["hr_rest_mae"]
    if "walk" in label:
        return bars["hr_walk_mae"]
    return bars["hr_hard_mae"]


def main(argv: list[str]) -> int:
    bars = dict(BARS)
    args = []
    i = 1
    while i < len(argv):
        if argv[i] == "--bar":
            k, v = argv[i + 1].split("=")
            bars[k] = float(v)
            i += 2
        else:
            args.append(argv[i])
            i += 1
    if not args:
        print(__doc__)
        return 2
    cmd, results, ok = args[0], [], True
    if cmd == "hr" and len(args) == 4:
        atria, ref = read_series(args[1], "bpm"), read_series(args[2], "bpm")
        for w in read_windows(args[3]):
            s = hr_window(atria, ref, w["start"], w["stop"])
            if s["pairs"]:
                s["pass"] = (s["mae"] <= hr_bar(w["label"], bars) and s["within5"] >= bars["hr_within5"]
                             and abs(s["lag_s"]) <= bars["hr_lag"])
                ok &= s["pass"]
            results.append({"label": w["label"], **s})
    elif cmd == "rr" and len(args) == 4:
        atria, ref = read_series(args[1], "rr_ms"), read_series(args[2], "rr_ms")
        for w in read_windows(args[3]):
            s = rr_window(atria, ref, w["start"], w["stop"])
            s["pass"] = bool(s["match"] is not None and s["match"] >= bars["rr_match"]
                             and s["rmssd_bias"] is not None and abs(s["rmssd_bias"]) <= bars["rmssd_bias"])
            ok &= s["pass"]
            results.append({"label": w["label"], **s})
    elif cmd == "sleep" and len(args) == 3:
        for s in sleep_scores(args[1], args[2]):
            s["pass"] = bool(s.get("found") and not s.get("is_nap")
                             and abs(s["onset_err_min"]) <= bars["sleep_edge_min"]
                             and abs(s["wake_err_min"]) <= bars["sleep_edge_min"]
                             and abs(s["duration_err_min"]) <= bars["sleep_duration_min"])
            ok &= s["pass"]
            results.append(s)
    else:
        print(__doc__)
        return 2
    for r in results:
        print("  ".join(f"{k}={v}" for k, v in r.items()))
    print("OVERALL", "PASS" if ok and results else "FAIL")
    Path(args[1]).with_name(f"score-{cmd}.json").write_text(json.dumps({"bars": bars, "results": results}, indent=2))
    return 0 if ok and results else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
