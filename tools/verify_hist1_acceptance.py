#!/usr/bin/env python3
"""Verify an exact HIST-1 phone-away/reconnect recovery from pulled artifacts."""

from __future__ import annotations

import argparse
import json
import math
import struct
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from compare_hist1_analytics import compare as compare_analytics


MIN_GAP_SECONDS = 60 * 60
MAX_RECONNECT_TO_PULL_SECONDS = 30 * 60
COVERAGE_BUCKET_SECONDS = 15
MAX_CONTINUITY_GAP_SECONDS = 3.0
MAX_P95_GAP_SECONDS = 1.5
MIN_SAMPLE_DENSITY_HZ = 0.8
MIN_SLEEP_CADENCE_SECONDS = 3 * 60 * 60
MIN_SCREENSHOT_DIMENSION = 500
MIN_SCREENSHOT_BYTES = 10_000
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
APPLE_REFERENCE_UNIX_OFFSET = 978_307_200.0


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


def valid_sha256(value: str | None) -> bool:
    if value is None or len(value) != 64:
        return False
    try:
        int(value, 16)
    except ValueError:
        return False
    return value == value.lower()


def archive_files(pull_directory: Path) -> list[Path]:
    files: list[Path] = []
    base = pull_directory / "historical-archive.jsonl"
    if base.is_file():
        files.append(base)
    segments = pull_directory / "historical-archive-segments"
    if segments.is_dir():
        files.extend(sorted(path for path in segments.rglob("*.jsonl") if path.is_file()))
    return files


def validated_layouts(fields: dict[str, str]) -> set[str]:
    value = fields.get("historical_archive_validated_metric_layouts", "")
    return {item for item in value.split(",") if item and item != "none"}


def strict_number(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    return number if math.isfinite(number) else None


def valid_bpm(value: object) -> bool:
    number = strict_number(value)
    return number is not None and 25 <= number <= 230


def field_number(value: str | None) -> float | None:
    try:
        number = float(value) if value is not None else math.nan
    except ValueError:
        return None
    return number if math.isfinite(number) else None


def effective_timestamp(row: dict[str, Any]) -> float | None:
    corrected = strict_number(row.get("clockCorrectedUnix7"))
    raw = strict_number(row.get("unix7"))
    value = corrected if corrected is not None and corrected > 0 else raw
    return value if value is not None and value > 0 else None


def is_validated_metric_row(row: dict[str, Any], layouts: set[str]) -> bool:
    heart_rate = strict_number(row.get("whoofHR17"))
    return (
        row.get("metricUsable") is True
        and isinstance(row.get("layoutVersion"), str)
        and row.get("layoutVersion") in layouts
        and row.get("clockCorrectionStatus") == "clock_ref_present"
        and row.get("gravityValidated") is True
        and heart_rate is not None
        and 25 <= heart_rate <= 230
        and effective_timestamp(row) is not None
    )


def unix_timestamp(value: object) -> float | None:
    number = strict_number(value)
    if number is None or number <= 0:
        return None
    # SavedSession and active-journal dates use Apple's 2001 reference epoch;
    # historical rows already carry Unix time.
    return number + APPLE_REFERENCE_UNIX_OFFSET if number < 1_200_000_000 else number


def live_timeline_timestamps(pull_directory: Path) -> list[float]:
    timestamps: list[float] = []
    sessions_path = pull_directory / "sessions.json"
    if sessions_path.is_file():
        try:
            document = json.loads(sessions_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            document = []
        sessions = document if isinstance(document, list) else document.get("sessions", []) if isinstance(document, dict) else []
        if isinstance(sessions, list):
            for session in sessions:
                if not isinstance(session, dict):
                    continue
                start = unix_timestamp(session.get("start"))
                points = session.get("points")
                if start is None or not isinstance(points, list):
                    continue
                for point in points:
                    offset = strict_number(point.get("t")) if isinstance(point, dict) else None
                    if offset is not None and offset >= 0 and valid_bpm(point.get("bpm")):
                        timestamps.append(start + offset)

    segment_directory = pull_directory / "atria-active-session.segments"
    if segment_directory.is_dir():
        for path in sorted(segment_directory.glob("segment-*.json")):
            try:
                segment = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            samples = segment.get("samples") if isinstance(segment, dict) else None
            if not isinstance(samples, list):
                continue
            for sample in samples:
                timestamp = unix_timestamp(sample.get("t")) if isinstance(sample, dict) else None
                if timestamp is not None and valid_bpm(sample.get("bpm")):
                    timestamps.append(timestamp)
    return timestamps


def percentile_nearest_rank(values: list[float], fraction: float) -> float:
    if not values:
        return math.inf
    ordered = sorted(values)
    rank = max(1, math.ceil(len(ordered) * min(1.0, max(0.0, fraction))))
    return ordered[min(len(ordered) - 1, rank - 1)]


def continuity_summary(
    timestamps: list[float], window_start: float, window_end: float
) -> dict[str, float | int | bool | None]:
    retained = sorted({value for value in timestamps if window_start <= value < window_end})
    duration = max(0.0, window_end - window_start)
    if not retained or duration <= 0:
        return {
            "points": len(retained),
            "density_hz": 0.0,
            "max_gap_s": duration,
            "p95_gap_s": math.inf,
            "start_lag_s": duration,
            "end_lag_s": duration,
            "continuous": False,
            "first_timestamp": retained[0] if retained else None,
            "last_timestamp": retained[-1] if retained else None,
        }
    internal = [current - previous for previous, current in zip(retained, retained[1:])]
    start_lag = max(0.0, retained[0] - window_start)
    # The window end is exclusive. One-Hz evidence at end-1 is complete.
    end_lag = max(0.0, window_end - retained[-1] - 1.0)
    all_gaps = [start_lag, end_lag, *internal]
    density = len(retained) / duration
    max_gap = max(all_gaps, default=duration)
    p95 = percentile_nearest_rank(internal or [max(start_lag, end_lag)], 0.95)
    continuous = (
        max_gap <= MAX_CONTINUITY_GAP_SECONDS
        and p95 <= MAX_P95_GAP_SECONDS
        and density >= MIN_SAMPLE_DENSITY_HZ
    )
    return {
        "points": len(retained),
        "density_hz": density,
        "max_gap_s": max_gap,
        "p95_gap_s": p95,
        "start_lag_s": start_lag,
        "end_lag_s": end_lag,
        "continuous": continuous,
        "first_timestamp": retained[0],
        "last_timestamp": retained[-1],
    }


def interval_overlaps_window(
    fields: dict[str, str], start_key: str, end_key: str,
    window_start: datetime, window_end: datetime,
) -> bool:
    try:
        start = parse_time(fields[start_key])
        end = parse_time(fields[end_key])
    except (KeyError, ValueError):
        return False
    return start < window_end and end > window_start and end > start


def sleep_cadence_evidence(
    fields: dict[str, str], window_start: datetime, window_end: datetime
) -> dict[str, object]:
    """Require a real tonight window, never an unchanged older sleep record."""
    confirmed_overlap = interval_overlaps_window(
        fields,
        "latest_confirmed_sleep_start",
        "latest_confirmed_sleep_end",
        window_start,
        window_end,
    )
    confirmed_duration = positive_int(fields.get("latest_confirmed_sleep_duration_s"))
    confirmed_samples = positive_int(fields.get("latest_confirmed_sleep_samples"))
    confirmed_stage_segments = positive_int(fields.get("latest_confirmed_sleep_stage_segments"))
    confirmed_stage_total = positive_int(fields.get("latest_confirmed_sleep_stage_total_s"))
    confirmed_motion = fields.get("latest_confirmed_sleep_motion_validated") == "1"
    if (
        confirmed_overlap
        and confirmed_duration >= MIN_SLEEP_CADENCE_SECONDS
        and confirmed_samples >= int(confirmed_duration * MIN_SAMPLE_DENSITY_HZ)
        and confirmed_motion
        and confirmed_stage_segments > 0
        and confirmed_stage_total >= int(confirmed_duration * 0.8)
    ):
        return {
            "status": "confirmed",
            "duration_s": confirmed_duration,
            "samples": confirmed_samples,
            "motion_validated": True,
            "stage_segments": confirmed_stage_segments,
            "reason": fields.get("latest_confirmed_sleep_source", "missing"),
        }

    candidate_overlap = interval_overlaps_window(
        fields,
        "latest_sleep_like_raw_start",
        "latest_sleep_like_raw_end",
        window_start,
        window_end,
    )
    candidate_duration = positive_int(fields.get("latest_sleep_like_raw_duration_s"))
    candidate_samples = positive_int(fields.get("latest_sleep_like_raw_samples"))
    candidate_reason = fields.get("latest_sleep_like_raw_reason", "missing")
    candidate_average = field_number(fields.get("latest_sleep_like_raw_avg_hr"))
    if (
        candidate_overlap
        and candidate_duration >= MIN_SLEEP_CADENCE_SECONDS
        and candidate_samples >= int(candidate_duration * MIN_SAMPLE_DENSITY_HZ)
        and candidate_reason == "low_motion_low_hr"
        and candidate_average is not None
        and 25 <= candidate_average <= 100
    ):
        return {
            "status": "candidate",
            "duration_s": candidate_duration,
            "samples": candidate_samples,
            "motion_validated": True,
            "stage_segments": 0,
            "reason": candidate_reason,
        }
    return {
        "status": "missing",
        "duration_s": max(confirmed_duration, candidate_duration),
        "samples": max(confirmed_samples, candidate_samples),
        "motion_validated": False,
        "stage_segments": confirmed_stage_segments,
        "reason": candidate_reason,
    }


def scan_gap_rows(
    pull_directory: Path,
    layouts: set[str],
    gap_start: datetime,
    reconnect: datetime,
) -> dict[str, object]:
    files = archive_files(pull_directory)
    parse_errors = 0
    gap_rows: list[tuple[float, str]] = []
    for path in files:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for raw_line in handle:
                if not raw_line.strip():
                    continue
                try:
                    row = json.loads(raw_line)
                except json.JSONDecodeError:
                    parse_errors += 1
                    continue
                if not isinstance(row, dict) or not is_validated_metric_row(row, layouts):
                    continue
                timestamp = effective_timestamp(row)
                identity = row.get("_atriaHistoryKey")
                if timestamp is None or not isinstance(identity, str) or not identity:
                    continue
                if gap_start.timestamp() <= timestamp < reconnect.timestamp():
                    gap_rows.append((timestamp, identity))

    live_timestamps = [
        timestamp for timestamp in live_timeline_timestamps(pull_directory)
        if gap_start.timestamp() <= timestamp < reconnect.timestamp()
    ]
    # Historical recovery must stand on the durable archive itself. Live rows
    # are retained as a diagnostic but cannot conceal a sparse/failed offload.
    timeline_timestamps = sorted({timestamp for timestamp, _ in gap_rows})
    duration = reconnect.timestamp() - gap_start.timestamp()
    total_buckets = max(1, math.ceil(duration / COVERAGE_BUCKET_SECONDS))
    covered_buckets = {
        min(total_buckets - 1, int((timestamp - gap_start.timestamp()) / COVERAGE_BUCKET_SECONDS))
        for timestamp in timeline_timestamps
    }
    identities = [identity for _, identity in gap_rows]
    return {
        "files": files,
        "parse_errors": parse_errors,
        "archive_rows": len(gap_rows),
        "live_points": len(set(live_timestamps)),
        "timeline_points": len(timeline_timestamps),
        "identities": identities,
        "unique_identities": len(set(identities)),
        "duplicate_identities": len(identities) - len(set(identities)),
        "total_buckets": total_buckets,
        "covered_buckets": len(covered_buckets),
        "missing_buckets": sorted(set(range(total_buckets)) - covered_buckets),
        "coverage_percent": len(covered_buckets) / total_buckets * 100,
        "first_timestamp": min(timeline_timestamps, default=None),
        "last_timestamp": max(timeline_timestamps, default=None),
        "continuity": continuity_summary(
            timeline_timestamps, gap_start.timestamp(), reconnect.timestamp()
        ),
    }


def scan_identity_index(path: Path) -> dict[str, object]:
    entries = 0
    parse_errors = 0
    keys: list[str] = []
    if not path.is_file():
        return {"exists": False, "entries": 0, "parse_errors": 0, "keys": Counter(), "duplicates": 0}
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            if not raw_line.strip():
                continue
            try:
                row = json.loads(raw_line)
            except json.JSONDecodeError:
                parse_errors += 1
                continue
            key = row.get("key") if isinstance(row, dict) else None
            if not isinstance(key, str) or not key:
                parse_errors += 1
                continue
            entries += 1
            keys.append(key)
    counts = Counter(keys)
    return {
        "exists": True,
        "entries": entries,
        "parse_errors": parse_errors,
        "keys": counts,
        "duplicates": sum(count - 1 for count in counts.values()),
    }


def png_dimensions(path: Path) -> tuple[int, int] | None:
    try:
        header = path.read_bytes()[:24]
    except OSError:
        return None
    if len(header) != 24 or header[:8] != PNG_SIGNATURE or header[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", header[16:24])
    return (width, height) if width > 0 and height > 0 else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pull-summary", required=True, type=Path)
    parser.add_argument("--pre-pull-summary", required=True, type=Path)
    parser.add_argument("--pre-relaunch-pull-summary", required=True, type=Path)
    parser.add_argument("--recovery-log", required=True, type=Path)
    parser.add_argument("--timeline-screenshot", required=True, type=Path)
    parser.add_argument("--gap-start", required=True,
                        help="ISO timestamp when the phone-away gap started.")
    parser.add_argument("--reconnect", required=True,
                        help="ISO timestamp when phone and strap reconnected.")
    parser.add_argument("--pull-time",
                        help="ISO timestamp for the post-reconnect pull. Defaults to pull-summary mtime.")
    args = parser.parse_args()

    blockers: list[str] = []
    if not args.pull_summary.is_file():
        blockers.append(f"missing_pull_summary:{args.pull_summary}")
        fields: dict[str, str] = {}
    else:
        fields = parse_key_values(args.pull_summary)
    if not args.pre_pull_summary.is_file():
        blockers.append(f"missing_pre_pull_summary:{args.pre_pull_summary}")
        pre_fields: dict[str, str] = {}
    else:
        pre_fields = parse_key_values(args.pre_pull_summary)
    if not args.pre_relaunch_pull_summary.is_file():
        blockers.append(f"missing_pre_relaunch_pull_summary:{args.pre_relaunch_pull_summary}")
        pre_relaunch_fields: dict[str, str] = {}
    else:
        pre_relaunch_fields = parse_key_values(args.pre_relaunch_pull_summary)

    try:
        gap_start = parse_time(args.gap_start)
        reconnect = parse_time(args.reconnect)
    except ValueError as error:
        parser.error(str(error))
    gap_seconds = (reconnect - gap_start).total_seconds()
    if gap_seconds < MIN_GAP_SECONDS:
        blockers.append(f"gap_seconds_lt_{MIN_GAP_SECONDS}")

    if args.pull_time:
        pull_time = parse_time(args.pull_time)
    elif args.pull_summary.is_file():
        pull_time = datetime.fromtimestamp(args.pull_summary.stat().st_mtime, tz=timezone.utc)
    else:
        pull_time = reconnect
    reconnect_to_pull = (pull_time - reconnect).total_seconds()
    if reconnect_to_pull < 0:
        blockers.append("pull_before_reconnect")
    if reconnect_to_pull > MAX_RECONNECT_TO_PULL_SECONDS:
        blockers.append(f"reconnect_to_pull_seconds_gt_{MAX_RECONNECT_TO_PULL_SECONDS}")

    screenshot_dimensions = png_dimensions(args.timeline_screenshot)
    screenshot_bytes = args.timeline_screenshot.stat().st_size if args.timeline_screenshot.is_file() else 0
    if (
        screenshot_dimensions is None
        or min(screenshot_dimensions) < MIN_SCREENSHOT_DIMENSION
        or screenshot_bytes < MIN_SCREENSHOT_BYTES
    ):
        blockers.append(f"invalid_timeline_screenshot:{args.timeline_screenshot}")

    if fields.get("process_status") != "running":
        blockers.append("atria_not_running")
    if fields.get("app_provenance_status") != "pass":
        blockers.append("installed_app_provenance_not_verified")
    if fields.get("official_whoop_process_status") != "not_listed":
        blockers.append("official_whoop_not_closed")
    if not truthy_zero(fields.get("offline_range_loss_backfill_pending")):
        blockers.append("range_loss_backfill_still_pending")
    if fields.get("offline_sync_last_status") not in {"gap_recovered", "metric_progress"}:
        blockers.append("offline_sync_status_not_exact_gap_recovery")
    if fields.get("historical_archive_metric_ready") != "1":
        blockers.append("archive_metric_not_ready")
    if fields.get("historical_archive_metric_promotion_blocker") != "none":
        blockers.append("archive_metric_promotion_blocked")
    if positive_int(fields.get("historical_archive_metric_usable_rows")) <= 0:
        blockers.append("no_metric_usable_archive_rows")

    baseline_layouts = validated_layouts(pre_fields)
    post_layouts = validated_layouts(fields)
    if not baseline_layouts:
        blockers.append("missing_pre_gap_validated_metric_layouts")
    if post_layouts != baseline_layouts:
        blockers.append("validated_metric_layouts_changed_since_installed_baseline")

    if pre_relaunch_fields.get("process_status") != "running":
        blockers.append("pre_relaunch_atria_not_running")
    if pre_relaunch_fields.get("app_provenance_status") != "pass":
        blockers.append("pre_relaunch_installed_app_provenance_not_verified")
    if pre_relaunch_fields.get("active_journal_final_status") != "ok":
        blockers.append("pre_relaunch_active_journal_not_lossless")
    if pre_relaunch_fields.get("app_provenance_sha256") != fields.get("app_provenance_sha256"):
        blockers.append("pre_relaunch_post_app_provenance_mismatch")
    if pre_relaunch_fields.get("app_binary_sha256") != fields.get("app_binary_sha256"):
        blockers.append("pre_relaunch_post_app_binary_mismatch")

    resident_timestamps = [
        timestamp
        for timestamp in live_timeline_timestamps(args.pre_relaunch_pull_summary.parent)
        if gap_start.timestamp() <= timestamp < reconnect.timestamp()
    ]
    resident_continuity = continuity_summary(
        resident_timestamps, gap_start.timestamp(), reconnect.timestamp()
    )
    if not resident_continuity["continuous"]:
        blockers.append("resident_overnight_continuity_failed_before_relaunch")

    sleep_evidence = sleep_cadence_evidence(fields, gap_start, reconnect)
    sleep_window_applicable = gap_seconds >= MIN_SLEEP_CADENCE_SECONDS
    if sleep_window_applicable:
        if sleep_evidence["status"] == "missing":
            blockers.append("tonight_sleep_cadence_window_missing")
        post_sleep_revision = fields.get("sleep_projection_artifact_revision")
        if (
            not valid_sha256(post_sleep_revision)
            or post_sleep_revision == pre_fields.get("sleep_projection_artifact_revision")
        ):
            blockers.append("sleep_projection_not_advanced_for_overnight_window")

    pull_directory = args.pull_summary.parent
    gap = scan_gap_rows(pull_directory, baseline_layouts, gap_start, reconnect)
    if not gap["files"]:
        blockers.append("missing_archive_files")
    if gap["parse_errors"]:
        blockers.append("archive_parse_errors")
    if not baseline_layouts:
        blockers.append("missing_validated_metric_layouts")
    if gap["archive_rows"] == 0:
        blockers.append("no_validated_metric_rows_in_gap")
    if gap["missing_buckets"]:
        blockers.append("exact_gap_buckets_missing")
    historical_continuity = gap["continuity"]
    if not historical_continuity["continuous"]:
        blockers.append("historical_recovery_not_continuous_one_hz")
    if gap["duplicate_identities"]:
        blockers.append("duplicate_gap_archive_identities")

    identity_path = pull_directory / "historical-archive.identity.jsonl"
    identity = scan_identity_index(identity_path)
    if not identity["exists"]:
        blockers.append("missing_history_identity_index")
    if identity["parse_errors"]:
        blockers.append("history_identity_index_parse_errors")
    if identity["duplicates"]:
        blockers.append("history_identity_index_duplicates")
    identity_counts: Counter[str] = identity["keys"]  # type: ignore[assignment]
    missing_identity_keys = sorted({key for key in gap["identities"] if identity_counts[key] != 1})
    if missing_identity_keys:
        blockers.append("gap_rows_missing_unique_identity_index_entry")

    pre_identity = scan_identity_index(args.pre_pull_summary.parent / "historical-archive.identity.jsonl")
    if not pre_identity["exists"]:
        blockers.append("missing_pre_gap_history_identity_index")
    if pre_identity["parse_errors"]:
        blockers.append("pre_gap_history_identity_index_parse_errors")
    if pre_identity["duplicates"]:
        blockers.append("pre_gap_history_identity_index_duplicates")
    pre_identity_counts: Counter[str] = pre_identity["keys"]  # type: ignore[assignment]
    preexisting_gap_identity_keys = sorted({
        key for key in gap["identities"] if pre_identity_counts[key] > 0
    })
    if preexisting_gap_identity_keys:
        blockers.append("gap_rows_already_present_in_pre_gap_pull")
    new_identity_count = int(identity["entries"]) - int(pre_identity["entries"])
    if new_identity_count < int(gap["unique_identities"]):
        blockers.append("post_gap_identity_revision_delta_too_small")

    analytics_details: dict[str, object] = {}
    if not args.recovery_log.is_file():
        blockers.append(f"missing_recovery_log:{args.recovery_log}")
    if args.pre_pull_summary.is_file() and args.recovery_log.is_file() and args.pull_summary.is_file():
        analytics_blockers, analytics_details = compare_analytics(SimpleNamespace(
            pre_pull_summary=args.pre_pull_summary,
            post_pull_summary=args.pull_summary,
            recovery_log=args.recovery_log,
            gap_start=args.gap_start,
            reconnect=args.reconnect,
        ))
        blockers.extend(f"analytics:{blocker}" for blocker in analytics_blockers)

    status = "pass" if not blockers else "fail"
    print(f"hist1_acceptance_status={status}")
    print("mode=deliberate_gap_exact_archive")
    print(f"pull_summary={args.pull_summary}")
    print(f"pre_pull_summary={args.pre_pull_summary}")
    print(f"pre_relaunch_pull_summary={args.pre_relaunch_pull_summary}")
    print(f"recovery_log={args.recovery_log}")
    print(f"timeline_screenshot={args.timeline_screenshot}")
    print(f"timeline_screenshot_dimensions={'x'.join(map(str, screenshot_dimensions)) if screenshot_dimensions else 'invalid'}")
    print(f"timeline_screenshot_bytes={screenshot_bytes}")
    print(f"gap_seconds={int(gap_seconds)}")
    print(f"reconnect_to_pull_seconds={int(reconnect_to_pull)}")
    print(f"archive_files_scanned={len(gap['files'])}")
    print(f"archive_parse_errors={gap['parse_errors']}")
    print(f"archive_metric_points_in_gap={gap['archive_rows']}")
    print(f"live_metric_points_in_gap={gap['live_points']}")
    print(f"timeline_points_derived={gap['timeline_points']}")
    print(f"timeline_unique_identities={gap['unique_identities']}")
    print(f"timeline_duplicate_identities={gap['duplicate_identities']}")
    print(f"gap_bucket_seconds={COVERAGE_BUCKET_SECONDS}")
    print(f"gap_buckets_expected={gap['total_buckets']}")
    print(f"gap_buckets_covered={gap['covered_buckets']}")
    print(f"gap_buckets_missing={len(gap['missing_buckets'])}")
    print(f"gap_coverage_percent={gap['coverage_percent']:.3f}")
    print(f"historical_sample_density_hz={historical_continuity['density_hz']:.6f}")
    print(f"historical_max_gap_s={historical_continuity['max_gap_s']:.3f}")
    print(f"historical_p95_gap_s={historical_continuity['p95_gap_s']:.3f}")
    print(f"historical_start_lag_s={historical_continuity['start_lag_s']:.3f}")
    print(f"historical_end_lag_s={historical_continuity['end_lag_s']:.3f}")
    print(f"historical_continuous_one_hz={1 if historical_continuity['continuous'] else 0}")
    print(f"resident_metric_points_in_gap={resident_continuity['points']}")
    print(f"resident_sample_density_hz={resident_continuity['density_hz']:.6f}")
    print(f"resident_max_gap_s={resident_continuity['max_gap_s']:.3f}")
    print(f"resident_p95_gap_s={resident_continuity['p95_gap_s']:.3f}")
    print(f"resident_start_lag_s={resident_continuity['start_lag_s']:.3f}")
    print(f"resident_end_lag_s={resident_continuity['end_lag_s']:.3f}")
    print(f"resident_continuous_one_hz={1 if resident_continuity['continuous'] else 0}")
    print(f"sleep_cadence_applicable={1 if sleep_window_applicable else 0}")
    print(f"sleep_cadence_status={sleep_evidence['status']}")
    print(f"sleep_cadence_duration_s={sleep_evidence['duration_s']}")
    print(f"sleep_cadence_samples={sleep_evidence['samples']}")
    print(f"sleep_cadence_motion_validated={1 if sleep_evidence['motion_validated'] else 0}")
    print(f"sleep_cadence_stage_segments={sleep_evidence['stage_segments']}")
    print(f"sleep_cadence_reason={sleep_evidence['reason']}")
    print(f"gap_first_metric_unix={gap['first_timestamp'] if gap['first_timestamp'] is not None else 'missing'}")
    print(f"gap_last_metric_unix={gap['last_timestamp'] if gap['last_timestamp'] is not None else 'missing'}")
    print(f"identity_index_entries={identity['entries']}")
    print(f"identity_index_duplicates={identity['duplicates']}")
    print(f"pre_gap_identity_index_entries={pre_identity['entries']}")
    print(f"preexisting_gap_identity_keys={len(preexisting_gap_identity_keys)}")
    print(f"post_gap_identity_revision_delta={new_identity_count}")
    print(f"gap_identity_keys_missing_or_nonunique={len(missing_identity_keys)}")
    for key, value in analytics_details.items():
        print(f"analytics_{key}={value}")
    for key in [
        "process_status",
        "official_whoop_process_status",
        "offline_range_loss_backfill_pending",
        "offline_sync_last_status",
        "offline_sync_last_reason",
        "historical_archive_metric_usable_rows",
        "historical_archive_metric_ready",
        "historical_archive_metric_promotion_blocker",
        "historical_archive_validated_metric_layouts",
        "app_source_match_status",
        "app_provenance_verification_mode",
        "app_provenance_status",
        "app_binary_sha256",
        "app_build",
        "app_version",
        "app_source_commit",
        "app_source_fingerprint",
        "app_source_dirty_fingerprint",
    ]:
        print(f"{key}={fields.get(key, 'missing')}")
    print("blockers=" + (",".join(blockers) if blockers else "none"))
    return 0 if not blockers else 1


if __name__ == "__main__":
    raise SystemExit(main())
