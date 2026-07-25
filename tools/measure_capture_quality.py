#!/usr/bin/env python3
"""Report Atria's live capture quality as a single number per day.

The product promise is continuous wear data without the vendor app, so the
metric that matters is simply: what fraction of the day did Atria hold an
accepted heart-rate sample? Everything else (gap ledgers, recovery lanes,
reconnect machinery) exists to move this number.

This exists because a reliability regression once cost ~45% of a day's live
coverage while every suite still passed -- there was no single number that
would have shown it. Run this against a `pull_atria_state.sh` evidence
directory before and after any BLE change.

Usage:
  tools/measure_capture_quality.py EVIDENCE_DIR [--days N] [--json]
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import sys

APPLE_EPOCH_OFFSET = 978_307_200
# Sessions are stored on Apple's reference date; anything below this threshold
# is therefore Apple-epoch rather than Unix.
UNIX_PLAUSIBILITY_FLOOR = 1_000_000_000
SECONDS_PER_DAY = 86_400


def to_unix(value: float) -> float:
    """Normalise a stored timestamp to Unix seconds."""
    return value + APPLE_EPOCH_OFFSET if value < UNIX_PLAUSIBILITY_FLOOR else value


def load_sessions(evidence_dir: pathlib.Path) -> list[dict]:
    path = evidence_dir / "sessions.json"
    if not path.exists():
        raise SystemExit(f"no sessions.json in {evidence_dir}")
    payload = json.loads(path.read_text())
    if not isinstance(payload, list):
        raise SystemExit("sessions.json is not a list; refusing to guess its shape")
    return payload


def day_key(unix: float, tz: dt.tzinfo) -> str:
    return dt.datetime.fromtimestamp(unix, tz).strftime("%Y-%m-%d")


def summarise(sessions: list[dict], tz: dt.tzinfo) -> dict[str, dict]:
    """Accumulate per-day coverage.

    A session spanning midnight is split at the boundary so each day is
    charged only for the wall-clock it actually contains. Accepted samples are
    apportioned by that same split rather than assigned to the start day.
    """
    days: dict[str, dict] = {}
    for session in sessions:
        start_raw, end_raw = session.get("start"), session.get("end")
        if not isinstance(start_raw, (int, float)) or not isinstance(end_raw, (int, float)):
            continue
        start, end = to_unix(float(start_raw)), to_unix(float(end_raw))
        if end <= start:
            continue
        duration = end - start
        accepted = float(session.get("hrAccepted") or 0)

        cursor = start
        while cursor < end:
            key = day_key(cursor, tz)
            midnight = dt.datetime.fromtimestamp(cursor, tz).replace(
                hour=0, minute=0, second=0, microsecond=0
            ) + dt.timedelta(days=1)
            slice_end = min(end, midnight.timestamp())
            slice_seconds = slice_end - cursor

            bucket = days.setdefault(
                key,
                {
                    "session_seconds": 0.0,
                    "accepted_samples": 0.0,
                    "sessions": 0,
                    "max_accepted_gap_s": 0.0,
                    "accepted_gaps": 0,
                },
            )
            bucket["session_seconds"] += slice_seconds
            bucket["accepted_samples"] += accepted * (slice_seconds / duration)
            if cursor == start:
                bucket["sessions"] += 1
                bucket["max_accepted_gap_s"] = max(
                    bucket["max_accepted_gap_s"],
                    float(session.get("hrMaxAcceptedGap") or 0),
                )
                bucket["accepted_gaps"] += int(session.get("hrAcceptedGaps") or 0)
            cursor = slice_end
    return days


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence_dir", type=pathlib.Path)
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    tz = dt.datetime.now().astimezone().tzinfo
    days = summarise(load_sessions(args.evidence_dir), tz)
    if not days:
        print("no dated sessions found", file=sys.stderr)
        return 1

    now = dt.datetime.now(tz)
    today_key = now.strftime("%Y-%m-%d")
    # The current day is only partly elapsed, so charging it against a full
    # 86400 would report today as a collapse every time it is run.
    elapsed_today = max(
        1.0,
        (now - now.replace(hour=0, minute=0, second=0, microsecond=0)).total_seconds(),
    )

    ordered = sorted(days.items())[-args.days :]
    rows = []
    for key, bucket in ordered:
        span = elapsed_today if key == today_key else SECONDS_PER_DAY
        # Accepted samples arrive at ~1 Hz, so their count approximates the
        # seconds actually covered. Session wall-time is reported alongside it
        # so a low ratio (connected but silent) stays visible instead of
        # hiding inside a healthy-looking uptime figure.
        covered = min(bucket["accepted_samples"], span)
        rows.append(
            {
                "day": key,
                "partial": key == today_key,
                "accepted_coverage_percent": round(100 * covered / span, 1),
                "session_uptime_percent": round(
                    100 * min(bucket["session_seconds"], span) / span, 1
                ),
                "accepted_samples": int(bucket["accepted_samples"]),
                "sessions": bucket["sessions"],
                "max_accepted_gap_s": round(bucket["max_accepted_gap_s"], 1),
                "accepted_gaps": bucket["accepted_gaps"],
            }
        )

    if args.json:
        print(json.dumps(rows, indent=1))
        return 0

    print(f"{'day':12} {'accepted%':>10} {'uptime%':>8} {'samples':>9} "
          f"{'sess':>5} {'maxgap_s':>9} {'gaps':>6}")
    for row in rows:
        label = row["day"] + (" *" if row["partial"] else "")
        print(f"{label:12} {row['accepted_coverage_percent']:10.1f} "
              f"{row['session_uptime_percent']:8.1f} {row['accepted_samples']:9d} "
              f"{row['sessions']:5d} {row['max_accepted_gap_s']:9.1f} "
              f"{row['accepted_gaps']:6d}")
    if any(row["partial"] for row in rows):
        print("\n* today so far, measured against elapsed time rather than a full day")
    print()
    print("accepted% is the product metric: share of the day Atria held an "
          "accepted HR sample.")
    print("A large uptime%/accepted% spread means connected-but-silent links.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
