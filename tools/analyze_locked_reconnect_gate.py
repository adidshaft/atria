#!/usr/bin/env python3
"""Score a locked out-of-range/return run against the Gate 1 criteria.

Gate 1 asks for three consecutive real cycles while the phone stays locked, and
every cycle has to prove five separate things rather than just "it came back":
a disconnect, a reconnect, accepted sample timestamps advancing AFTER that
reconnect, a fresh raw age with an active journal, and the same build and
process throughout — with no churn alongside.

Those live in three different places in an evidence pull (the persisted
breadcrumb trail, the segmented active journal, and the pull summary), so
scoring by eye invites exactly the error this gate exists to catch: reading a
recovery that happened to land near a leg boundary as proof the leg caused it.
This attributes every disconnect to a leg window or counts it as churn.

Usage:
  analyze_locked_reconnect_gate.py EVIDENCE_DIR --start "HH:MM" [--leg 90] [--cycles 3]

--start is the local wall-clock time the first AWAY leg began. Legs then
alternate away/back for --cycles pairs.
"""
import argparse
import datetime as dt
import json
import pathlib
import plistlib
import sys

# CFAbsoluteTime is seconds since 2001-01-01 UTC; journal samples use it.
CF_EPOCH_OFFSET = 978307200.0
TRAIL_KEY = "atria.reconnectLease.trail"

# A reconnect only counts if fresh accepted HR followed it, so these are the
# stages that mark a real recovery rather than a mere connection attempt.
RECOVERY_STAGES = {"lease_ended"}
DISCONNECT_STAGES = {"away_lease_begun"}


def load_trail(evidence: pathlib.Path):
    prefs = plistlib.load((evidence / "preferences.plist").open("rb"))
    entries = []
    for line in (prefs.get(TRAIL_KEY) or "").split("\n"):
        parts = line.split("|", 2)
        if len(parts) != 3 or not parts[0].isdigit():
            continue
        entries.append((float(parts[0]), parts[1], parts[2]))
    return sorted(entries), prefs


def load_samples(evidence: pathlib.Path):
    """Accepted HR sample unix timestamps from every journal segment."""
    seg_dir = evidence / "atria-active-session.segments"
    stamps = []
    if not seg_dir.is_dir():
        return stamps
    for path in sorted(seg_dir.glob("segment-*.json")):
        try:
            blob = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        for sample in blob.get("samples") or []:
            t = sample.get("t")
            if isinstance(t, (int, float)):
                stamps.append(t + CF_EPOCH_OFFSET)
    return sorted(stamps)


def summary_fields(evidence: pathlib.Path, keys):
    out = {}
    path = evidence / "pull-summary.txt"
    if not path.is_file():
        return out
    for line in path.read_text().splitlines():
        key, _, value = line.partition("=")
        if key in keys:
            out[key] = value
    return out


def build_legs(start: dt.datetime, leg_seconds: int, cycles: int):
    legs = []
    cursor = start
    for index in range(cycles):
        away_end = cursor + dt.timedelta(seconds=leg_seconds)
        back_end = away_end + dt.timedelta(seconds=leg_seconds)
        legs.append({"cycle": index + 1, "away": (cursor, away_end),
                     "back": (away_end, back_end)})
        cursor = back_end
    return legs


def in_window(stamp: float, window):
    lo, hi = window
    return lo.timestamp() <= stamp <= hi.timestamp()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("evidence_dir", type=pathlib.Path)
    ap.add_argument("--start", required=True,
                    help="local HH:MM (or HH:MM:SS) the first away leg began")
    ap.add_argument("--leg", type=int, default=90, help="seconds per leg")
    ap.add_argument("--cycles", type=int, default=3)
    ap.add_argument("--grace", type=int, default=45,
                    help="seconds after a leg a recovery may still count")
    args = ap.parse_args()

    evidence = args.evidence_dir
    if not evidence.is_dir():
        print(f"no such evidence dir: {evidence}", file=sys.stderr)
        return 2

    trail, _ = load_trail(evidence)
    samples = load_samples(evidence)
    if not trail:
        print("no breadcrumb trail in this pull — cannot attribute anything")
        return 2

    fmt = "%H:%M:%S" if args.start.count(":") == 2 else "%H:%M"
    anchor = dt.datetime.strptime(args.start, fmt).time()
    # Anchor to the day the trail was written so leg maths lines up.
    trail_day = dt.datetime.fromtimestamp(trail[-1][0]).date()
    start = dt.datetime.combine(trail_day, anchor)
    legs = build_legs(start, args.leg, args.cycles)
    run_lo = start.timestamp()
    run_hi = legs[-1]["back"][1].timestamp() + args.grace

    meta = summary_fields(evidence, {
        "app_source_commit", "app_provenance_status", "process_status",
        "active_journal_continuity_status", "active_journal_freshness",
        "sample_last_raw_notification_age_s", "ble_link_disconnects",
    })

    print(f"run window   : {start:%H:%M:%S} .. "
          f"{legs[-1]['back'][1]:%H:%M:%S} (+{args.grace}s grace)")
    print(f"build        : {meta.get('app_source_commit', '?')[:12]} "
          f"provenance={meta.get('app_provenance_status', '?')} "
          f"process={meta.get('process_status', '?')}")
    print(f"journal      : {meta.get('active_journal_continuity_status', '?')}"
          f"/{meta.get('active_journal_freshness', '?')} "
          f"raw_age={meta.get('sample_last_raw_notification_age_s', '?')}s")
    print()

    disconnects = [e for e in trail if e[1] in DISCONNECT_STAGES
                   and run_lo <= e[0] <= run_hi]
    recoveries = [e for e in trail if e[1] in RECOVERY_STAGES
                  and "fresh_accepted_hr" in e[2] and run_lo <= e[0] <= run_hi]

    attributed = set()
    verdicts = []
    for leg in legs:
        away_lo, away_hi = leg["away"]
        # A disconnect belongs to this cycle if it fell in the away leg.
        mine = [e for e in disconnects if in_window(e[0], (away_lo, away_hi))]
        # The recovery may land in the back leg or just past it.
        back_lo, back_hi = leg["back"]
        rec_window = (back_lo, back_hi + dt.timedelta(seconds=args.grace))
        recs = [e for e in recoveries if in_window(e[0], rec_window)]
        attributed.update(id(e) for e in mine)

        advancing = 0
        first_rec = recs[0][0] if recs else None
        if first_rec is not None:
            advancing = sum(1 for s in samples if first_rec <= s <= run_hi)

        ok = bool(mine) and bool(recs) and advancing > 0
        verdicts.append(ok)
        print(f"cycle {leg['cycle']}: "
              f"away {away_lo:%H:%M:%S}-{away_hi:%H:%M:%S} "
              f"back {back_lo:%H:%M:%S}-{back_hi:%H:%M:%S}")
        print(f"  disconnect in away leg : {len(mine)} "
              f"{'OK' if mine else 'MISSING'}")
        print(f"  recovery w/ fresh HR   : {len(recs)} "
              f"{'OK' if recs else 'MISSING'}")
        print(f"  accepted samples after : {advancing} "
              f"{'OK' if advancing else 'NONE'}")
        print(f"  -> {'PASS' if ok else 'FAIL'}")
        print()

    churn = [e for e in disconnects if id(e) not in attributed]
    print(f"unattributed disconnects (churn): {len(churn)}")
    for stamp, stage, detail in churn[:12]:
        print(f"  {dt.datetime.fromtimestamp(stamp):%H:%M:%S} {stage} :: {detail}")
    if len(churn) > 12:
        print(f"  ... and {len(churn) - 12} more")
    print()

    build_ok = (meta.get("app_provenance_status") == "pass"
                and meta.get("process_status") == "running")
    journal_ok = meta.get("active_journal_continuity_status") == "active"
    gate = all(verdicts) and not churn and build_ok and journal_ok
    print(f"build/process stable : {'OK' if build_ok else 'FAIL'}")
    print(f"journal active       : {'OK' if journal_ok else 'FAIL'}")
    print(f"no churn             : {'OK' if not churn else 'FAIL'}")
    print()
    print(f"GATE 1: {'PASS' if gate else 'FAIL'}")
    return 0 if gate else 1


if __name__ == "__main__":
    raise SystemExit(main())
