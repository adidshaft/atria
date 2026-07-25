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
        # `hrAccepted` is a summary counter that is finalised when the session
        # is closed, so for the newest session it can lag the samples actually
        # recorded (observed 223 vs 1525 points). The points array is the
        # sample record itself; prefer it and keep the counter as the fallback
        # for any session that stores no points.
        points = session.get("points")
        accepted = (
            float(len(points))
            if isinstance(points, list) and points
            else float(session.get("hrAccepted") or 0)
        )

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


def score_sleep_windows(sessions: list[dict], tz: dt.tzinfo, nights: int) -> list[dict]:
    """Score each 22:00->08:00 window against the auto-confirm spec.

    The constants are already in the app (minimumAutoConfirmHRCoverageFraction
    0.80, briefSleepGapCreditMax 20 min), so this reports the same three
    quantities the pipeline gates on rather than inventing a metric.

    Leading and trailing uncovered stretches are reported separately from
    interior gaps: a window that simply ends after the wearer gets up produces
    a large trailing gap that says nothing about capture reliability, and
    counting it as the headline gap makes every night look broken.
    """
    spans: dict[str, tuple[float, float]] = {}
    now = dt.datetime.now(tz)
    for back in range(nights, 0, -1):
        evening = (now - dt.timedelta(days=back)).replace(
            hour=22, minute=0, second=0, microsecond=0
        )
        spans[evening.strftime("%m-%d")] = (
            evening.timestamp(),
            (evening + dt.timedelta(hours=10)).timestamp(),
        )

    rows = []
    for label, (lo, hi) in spans.items():
        overlapping = [
            s for s in sessions
            if isinstance(s.get("start"), (int, float))
            and isinstance(s.get("end"), (int, float))
            and to_unix(float(s["start"])) < hi
            and to_unix(float(s["end"])) > lo
        ]
        if not overlapping:
            continue
        segments = sorted(
            (max(to_unix(float(s["start"])), lo), min(to_unix(float(s["end"])), hi))
            for s in overlapping
        )
        covered = sum(end - start for start, end in segments)
        interior = [
            segments[i + 1][0] - segments[i][1]
            for i in range(len(segments) - 1)
            if segments[i + 1][0] > segments[i][1]
        ]
        stubs = sum(
            1 for s in overlapping
            if to_unix(float(s["end"])) - to_unix(float(s["start"])) < 60
        )
        coverage = 100 * covered / (hi - lo)
        worst_interior = max(interior) / 60 if interior else 0.0
        rows.append(
            {
                "night": label,
                "coverage_percent": round(coverage, 1),
                "largest_interior_gap_min": round(worst_interior, 1),
                "leading_gap_min": round((segments[0][0] - lo) / 60, 1),
                "trailing_gap_min": round((hi - segments[-1][1]) / 60, 1),
                "sessions": len(overlapping),
                "stub_sessions_under_60s": stubs,
                "meets_spec": coverage >= 80 and worst_interior <= 20 and stubs == 0,
            }
        )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence_dir", type=pathlib.Path)
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--sleep-spec",
        action="store_true",
        help="score 22:00-08:00 windows against the auto-confirm capture spec",
    )
    args = parser.parse_args()

    if args.sleep_spec:
        tz = dt.datetime.now().astimezone().tzinfo
        rows = score_sleep_windows(load_sessions(args.evidence_dir), tz, args.days)
        if args.json:
            print(json.dumps(rows, indent=1))
            return 0
        print("22:00-08:00 windows vs auto-confirm spec "
              "(coverage >= 80%, interior gap <= 20 min, no sub-60s stubs)\n")
        print(f"{'night':8} {'cov%':>6} {'gap_min':>8} {'lead':>6} {'trail':>6} "
              f"{'sess':>5} {'stubs':>6}  verdict")
        for row in rows:
            print(f"{row['night']:8} {row['coverage_percent']:6.1f} "
                  f"{row['largest_interior_gap_min']:8.1f} {row['leading_gap_min']:6.1f} "
                  f"{row['trailing_gap_min']:6.1f} {row['sessions']:5d} "
                  f"{row['stub_sessions_under_60s']:6d}  "
                  f"{'PASS' if row['meets_spec'] else 'fail'}")
        print("\nlead/trail are uncovered edges (wearer awake), reported apart "
              "from interior gaps so they do not masquerade as capture loss.")
        return 0

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
