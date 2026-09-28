#!/usr/bin/env python3
"""Turn an Atria session backup into plain CSVs for scoring (validation plan §2).

The backup is raw-deflate JSON (Apple Compression, no gzip header). Output:
  hr.csv      unix_time,bpm            every stored heart-rate point
  rr.csv      unix_time,rr_ms          every stored RR interval
  sleeps.csv  start,end,is_nap,source  confirmed sleeps (unix seconds)
  rollups.csv day,<numeric fields>     one row per daily rollup
Usage: atria_export.py BACKUP OUT_DIR
"""
from __future__ import annotations

import csv
import json
import sys
import zlib
from datetime import datetime
from pathlib import Path


def load_backup(path: str | Path) -> dict:
    raw = Path(path).read_bytes()
    try:
        text = zlib.decompress(raw, -15)
    except zlib.error:
        text = raw  # already plain JSON
    return json.loads(text)


def unix(value) -> float:
    if isinstance(value, (int, float)):
        # Foundation reference-date seconds are below 1e9 for modern dates.
        return float(value) + (978_307_200 if value < 1_000_000_000 else 0)
    return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()


def heart_rate(backup: dict) -> list[tuple[float, int]]:
    rows = []
    for session in backup.get("sessions", []):
        start = unix(session["start"])
        rows += [(start + p["t"], int(p["bpm"])) for p in session.get("points", []) if p.get("bpm")]
    return sorted(set(rows))


def rr_intervals(backup: dict) -> list[tuple[float, float]]:
    rows = []
    for session in backup.get("sessions", []):
        start = unix(session["start"])
        for p in session.get("rrPoints", []):
            t = p.get("t", 0)
            for key in ("ms", "rr", "value"):
                if key in p:
                    rows.append((start + t, float(p[key])))
                    break
    return sorted(set(rows))


def sleeps(backup: dict) -> list[tuple[float, float, bool, str]]:
    out = []
    for s in backup.get("confirmedSleeps", []):
        is_nap = "nap" in str(s.get("source", "")).lower()
        out.append((unix(s["start"]), unix(s["end"]), is_nap, s.get("source", "")))
    return sorted(out)


def write(path: Path, header: list[str], rows) -> None:
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__)
        return 2
    backup, out = load_backup(argv[1]), Path(argv[2])
    out.mkdir(parents=True, exist_ok=True)
    write(out / "hr.csv", ["unix_time", "bpm"], heart_rate(backup))
    write(out / "rr.csv", ["unix_time", "rr_ms"], rr_intervals(backup))
    write(out / "sleeps.csv", ["start", "end", "is_nap", "source"], sleeps(backup))
    rollups = backup.get("dailyRollups", [])
    keys = sorted({k for r in rollups for k, v in r.items() if isinstance(v, (int, float)) and not isinstance(v, bool)})
    write(out / "rollups.csv", ["day"] + keys, [[r.get("day")] + [r.get(k, "") for k in keys] for r in rollups])
    print(f"exported {len(heart_rate(backup))} HR points, {len(rr_intervals(backup))} RR, "
          f"{len(sleeps(backup))} sleeps, {len(rollups)} rollups -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
