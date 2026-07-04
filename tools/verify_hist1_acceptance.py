#!/usr/bin/env python3
"""Verify HIST-1 phone-away/reconnect acceptance evidence."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from pathlib import Path


MIN_GAP_SECONDS = 60 * 60
MAX_RECONNECT_TO_PULL_SECONDS = 30 * 60
MIN_TIMELINE_POINTS = 1


def parse_key_values(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        fields[key] = value
    return fields


def parse_time(value: str) -> datetime:
    normalized = value.strip().replace("Z", "+00:00")
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        raise ValueError(f"{value!r} must include a timezone offset")
    return parsed.astimezone(timezone.utc)


def truthy_zero(value: str | None) -> bool:
    return (value or "").lower() in {"0", "false", "no"}


def positive_int(value: str | None) -> int:
    try:
        return int(float(value or "0"))
    except ValueError:
        return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pull-summary", required=True, type=Path)
    parser.add_argument("--timeline-screenshot", required=True, type=Path)
    parser.add_argument("--timeline-points", required=True, type=int)
    parser.add_argument("--gap-start", help="ISO timestamp when the 1h phone-away gap started.")
    parser.add_argument("--reconnect", help="ISO timestamp when the phone/strap reconnected.")
    parser.add_argument("--pull-time", help="ISO timestamp for the post-reconnect pull. Defaults to pull-summary mtime.")
    parser.add_argument("--allow-current-proof", action="store_true",
                        help="Allow current-state proof without deliberate gap timestamps.")
    args = parser.parse_args()

    blockers: list[str] = []
    if not args.pull_summary.exists():
        blockers.append(f"missing_pull_summary:{args.pull_summary}")
        fields: dict[str, str] = {}
    else:
        fields = parse_key_values(args.pull_summary)

    if not args.timeline_screenshot.exists():
        blockers.append(f"missing_timeline_screenshot:{args.timeline_screenshot}")
    if args.timeline_points < MIN_TIMELINE_POINTS:
        blockers.append(f"timeline_points_lt_{MIN_TIMELINE_POINTS}")

    if fields.get("process_status") != "running":
        blockers.append("atria_not_running")
    if fields.get("official_whoop_process_status") != "not_listed":
        blockers.append("official_whoop_not_closed")
    if not truthy_zero(fields.get("offline_range_loss_backfill_pending")):
        blockers.append("range_loss_backfill_still_pending")
    if fields.get("offline_sync_last_status") not in {"archive_metric_ready", "archived", "throttled"}:
        blockers.append("offline_sync_status_not_accepted")
    if fields.get("historical_archive_metric_ready") != "1":
        blockers.append("archive_metric_not_ready")
    if fields.get("historical_archive_metric_promotion_blocker") != "none":
        blockers.append("archive_metric_promotion_blocked")
    if positive_int(fields.get("historical_archive_metric_usable_rows")) <= 0:
        blockers.append("no_metric_usable_archive_rows")

    if args.allow_current_proof:
        mode = "current_proof"
    else:
        mode = "deliberate_gap"
        if not args.gap_start or not args.reconnect:
            blockers.append("missing_deliberate_gap_timestamps")
        else:
            gap_start = parse_time(args.gap_start)
            reconnect = parse_time(args.reconnect)
            gap_seconds = (reconnect - gap_start).total_seconds()
            if gap_seconds < MIN_GAP_SECONDS:
                blockers.append(f"gap_seconds_lt_{MIN_GAP_SECONDS}")

            if args.pull_time:
                pull_time = parse_time(args.pull_time)
            else:
                pull_time = datetime.fromtimestamp(args.pull_summary.stat().st_mtime, tz=timezone.utc)
            reconnect_to_pull = (pull_time - reconnect).total_seconds()
            if reconnect_to_pull < 0:
                blockers.append("pull_before_reconnect")
            if reconnect_to_pull > MAX_RECONNECT_TO_PULL_SECONDS:
                blockers.append(f"reconnect_to_pull_seconds_gt_{MAX_RECONNECT_TO_PULL_SECONDS}")

    status = "pass" if not blockers else "fail"
    print(f"hist1_acceptance_status={status}")
    print(f"mode={mode}")
    print(f"pull_summary={args.pull_summary}")
    print(f"timeline_screenshot={args.timeline_screenshot}")
    print(f"timeline_points={args.timeline_points}")
    for key in [
        "process_status",
        "official_whoop_process_status",
        "offline_range_loss_backfill_pending",
        "offline_sync_last_status",
        "offline_sync_last_reason",
        "historical_archive_metric_usable_rows",
        "historical_archive_metric_ready",
        "historical_archive_metric_promotion_blocker",
    ]:
        print(f"{key}={fields.get(key, 'missing')}")
    if blockers:
        print("blockers=" + ",".join(blockers))
    else:
        print("blockers=none")
    return 0 if not blockers else 1


if __name__ == "__main__":
    raise SystemExit(main())
