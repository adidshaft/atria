#!/usr/bin/env python3
"""Summarize Atria saved sessions for Gate E sleep evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
from pathlib import Path
from typing import Any


APPLE_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
MIN_SESSION_SECONDS = 20 * 60
STRICT_MINIMUM_SECONDS = 3 * 60 * 60
FRAGMENTED_MINIMUM_SECONDS = 150 * 60
FRAGMENTED_MINIMUM_SPAN_SECONDS = 3 * 60 * 60
SLEEP_CLUSTER_GAP_SECONDS = 2 * 60 * 60
NAP_MINIMUM_SECONDS = 20 * 60
NAP_MAXIMUM_SPAN_SECONDS = 3 * 60 * 60


def load_sessions(path: Path) -> list[dict[str, Any]]:
    data = json.loads(path.read_text())
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and isinstance(data.get("sessions"), list):
        return data["sessions"]
    raise SystemExit(f"{path} is not a sessions array or backup envelope")


def app_seconds(value: Any) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        text = value.strip()
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        parsed = dt.datetime.fromisoformat(text)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return (parsed.astimezone(dt.timezone.utc) - APPLE_EPOCH).total_seconds()
    raise SystemExit(f"unsupported timestamp type: {type(value).__name__}")


def app_to_unix(seconds: float) -> float:
    return (APPLE_EPOCH + dt.timedelta(seconds=seconds)).timestamp()


def apple_time(seconds: float, timezone: str) -> str:
    return (APPLE_EPOCH + dt.timedelta(seconds=seconds)).astimezone(timezone_for(timezone)).strftime("%Y-%m-%d %H:%M:%S %Z")


def iso_unix(seconds: float | None) -> str:
    if seconds is None or not math.isfinite(seconds):
        return "none"
    return dt.datetime.fromtimestamp(seconds, tz=dt.timezone.utc).isoformat()


def timezone_for(name: str) -> dt.timezone:
    if name.upper() == "IST":
        return dt.timezone(dt.timedelta(hours=5, minutes=30), "IST")
    return dt.timezone.utc


def day_key(seconds: float, timezone: str) -> dt.date:
    local = (APPLE_EPOCH + dt.timedelta(seconds=seconds)).astimezone(timezone_for(timezone))
    if local.hour <= 11:
        return local.date()
    return (APPLE_EPOCH + dt.timedelta(seconds=seconds)).astimezone(timezone_for(timezone)).date()


def session_start(session: dict[str, Any]) -> float:
    return app_seconds(session.get("start", 0))


def session_end(session: dict[str, Any]) -> float:
    return app_seconds(session.get("end", session.get("start", 0)))


def session_duration(session: dict[str, Any]) -> float:
    return max(0.0, session_end(session) - session_start(session))


def bpms(session: dict[str, Any]) -> list[int]:
    return [int(point["bpm"]) for point in session.get("points") or [] if point.get("bpm") is not None]


def avg_hr(session: dict[str, Any]) -> int:
    values = bpms(session)
    return round(sum(values) / len(values)) if values else 0


def peak_hr(session: dict[str, Any]) -> int:
    values = bpms(session)
    return max(values) if values else 0


def percentile_nearest_rank(values: list[int], percentile: float) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    rank = max(1, math.ceil(percentile * len(ordered)))
    return ordered[min(len(ordered) - 1, rank - 1)]


def sleep_day_for(session: dict[str, Any], timezone: str) -> dt.date:
    zone = timezone_for(timezone)
    end_local = (APPLE_EPOCH + dt.timedelta(seconds=session_end(session))).astimezone(zone)
    start_local = (APPLE_EPOCH + dt.timedelta(seconds=session_start(session))).astimezone(zone)
    if end_local.hour <= 11:
        return end_local.date()
    return start_local.date()


def is_overnight(session: dict[str, Any], timezone: str) -> bool:
    zone = timezone_for(timezone)
    start_hour = (APPLE_EPOCH + dt.timedelta(seconds=session_start(session))).astimezone(zone).hour
    end_hour = (APPLE_EPOCH + dt.timedelta(seconds=session_end(session))).astimezone(zone).hour
    return start_hour >= 20 or start_hour <= 5 or end_hour <= 11


def is_daytime_nap_window(session: dict[str, Any], timezone: str) -> bool:
    zone = timezone_for(timezone)
    start_hour = (APPLE_EPOCH + dt.timedelta(seconds=session_start(session))).astimezone(zone).hour
    end_hour = (APPLE_EPOCH + dt.timedelta(seconds=session_end(session))).astimezone(zone).hour
    return start_hour >= 11 and end_hour <= 20


def sleep_clusters(sessions: list[dict[str, Any]]) -> list[list[dict[str, Any]]]:
    clusters: list[list[dict[str, Any]]] = []
    current: list[dict[str, Any]] = []
    current_end: float | None = None
    for session in sorted(sessions, key=session_start):
        start = session_start(session)
        end = session_end(session)
        if current and current_end is not None and start - current_end > SLEEP_CLUSTER_GAP_SECONDS:
            clusters.append(current)
            current = []
        current.append(session)
        current_end = max(current_end or end, end)
    if current:
        clusters.append(current)
    return clusters


def load_archive_range(path: Path | None) -> dict[str, Any]:
    if path is None or not path.exists():
        return {
            "rows": 0,
            "validated_rows": 0,
            "first_unix": None,
            "last_unix": None,
            "status": "missing",
            "reason": "no_historical_gravity",
        }
    rows = []
    for line in path.read_text(errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    corrected = [
        int(row["clockCorrectedUnix7"])
        for row in rows
        if isinstance(row.get("clockCorrectedUnix7"), int) and int(row["clockCorrectedUnix7"]) > 0
    ]
    raw = [
        int(row["unix7"])
        for row in rows
        if isinstance(row.get("unix7"), int) and int(row["unix7"]) > 0
    ]
    timestamps = corrected or raw
    validated_rows = sum(1 for row in rows if row.get("gravityValidated") is True or row.get("source") == "0x2f")
    if not timestamps:
        return {
            "rows": len(rows),
            "validated_rows": validated_rows,
            "first_unix": None,
            "last_unix": None,
            "status": "unavailable",
            "reason": "no_timestamp_overlap",
        }
    return {
        "rows": len(rows),
        "validated_rows": validated_rows,
        "first_unix": min(timestamps),
        "last_unix": max(timestamps),
        "status": "available",
        "reason": "ok",
    }


def overlap_seconds(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def separation_seconds(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    if overlap_seconds(a_start, a_end, b_start, b_end) > 0:
        return 0.0
    if a_end < b_start:
        return b_start - a_end
    return a_start - b_end


def motion_status(start_app: float, end_app: float, archive: dict[str, Any]) -> dict[str, Any]:
    if archive["rows"] <= 0:
        return {**archive, "overlap_s": 0.0, "nearest_separation_s": "none", "validated": False, "reason": archive["reason"]}
    first = archive.get("first_unix")
    last = archive.get("last_unix")
    if first is None or last is None:
        return {**archive, "overlap_s": 0.0, "nearest_separation_s": "none", "validated": False, "reason": "no_timestamp_overlap"}
    start_unix = app_to_unix(start_app)
    end_unix = app_to_unix(end_app)
    overlap = overlap_seconds(start_unix, end_unix, float(first), float(last))
    separation = separation_seconds(start_unix, end_unix, float(first), float(last))
    if overlap <= 0:
        reason = "historical_archive_stale" if separation > 24 * 60 * 60 else "no_timestamp_overlap"
        return {**archive, "overlap_s": 0.0, "nearest_separation_s": separation, "validated": False, "reason": reason}
    if overlap < min(30 * 60, max(300.0, (end_unix - start_unix) * 0.25)):
        return {**archive, "overlap_s": overlap, "nearest_separation_s": 0.0, "validated": False, "reason": "insufficient_overlap_coverage"}
    if int(archive.get("validated_rows") or 0) < 60:
        return {**archive, "overlap_s": overlap, "nearest_separation_s": 0.0, "validated": False, "reason": "insufficient_validated_gravity"}
    return {**archive, "overlap_s": overlap, "nearest_separation_s": 0.0, "validated": True, "reason": "historical_gravity_low_motion_validated"}


def candidate_blocker(motion: dict[str, Any]) -> str:
    if motion.get("validated"):
        return "sleep_low_confidence_threshold"
    reason = str(motion.get("reason") or "")
    return {
        "no_historical_gravity": "sleep_motion_unvalidated_no_historical_gravity",
        "no_timestamp_overlap": "sleep_motion_unvalidated_no_historical_overlap",
        "historical_archive_stale": "sleep_motion_unvalidated_historical_stale",
        "historical_archive_future_or_misaligned": "sleep_motion_unvalidated_historical_misaligned",
        "insufficient_validated_gravity": "sleep_motion_unvalidated_insufficient_gravity",
        "insufficient_overlap_coverage": "sleep_motion_unvalidated_insufficient_coverage",
        "vector_delta_high": "sleep_motion_unvalidated_motion_too_high",
        "magnitude_variance_high": "sleep_motion_unvalidated_variance_too_high",
    }.get(reason, "sleep_motion_unvalidated")


def eligible_sessions(sessions: list[dict[str, Any]], rest: int, max_hr: int, timezone: str) -> tuple[list[dict[str, Any]], dict[str, int]]:
    counts = {
        "evaluated": 0,
        "too_short": 0,
        "not_overnight": 0,
        "hr_too_high": 0,
        "workout_like": 0,
    }
    eligible: list[dict[str, Any]] = []
    for session in sessions:
        if not (session.get("points") or []):
            continue
        counts["evaluated"] += 1
        if session_duration(session) < MIN_SESSION_SECONDS:
            counts["too_short"] += 1
            continue
        overnight = is_overnight(session, timezone)
        nap_like = (
            not overnight
            and is_daytime_nap_window(session, timezone)
            and NAP_MINIMUM_SECONDS <= session_duration(session) <= NAP_MAXIMUM_SPAN_SECONDS
            and avg_hr(session) <= rest + 12
            and peak_hr(session) <= rest + 35
        )
        if not (overnight or nap_like):
            counts["not_overnight"] += 1
            continue
        if overnight and (avg_hr(session) > rest + 18 or peak_hr(session) > rest + 55):
            counts["hr_too_high"] += 1
            continue
        # Full workout replay is handled by tools/analyze_workout_store.py.
        # For sleep audit parity, only reject obviously workout-like chunks.
        if peak_hr(session) >= rest + max(55, round((max_hr - rest) * 0.5)):
            counts["workout_like"] += 1
            continue
        eligible.append(session)
    return eligible, counts


def aggregate_candidates(sessions: list[dict[str, Any]], rest: int, max_hr: int, timezone: str, archive: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, int]]:
    eligible, counts = eligible_sessions(sessions, rest, max_hr, timezone)
    counts["eligible"] = len(eligible)
    grouped: dict[dt.date, list[dict[str, Any]]] = {}
    for session in eligible:
        grouped.setdefault(sleep_day_for(session, timezone), []).append(session)

    candidates: list[dict[str, Any]] = []
    for day, day_sessions in grouped.items():
        for cluster in sleep_clusters(day_sessions):
            start = min(session_start(session) for session in cluster)
            end = max(session_end(session) for session in cluster)
            duration = sum(session_duration(session) for session in cluster)
            gaps = [
                max(0.0, session_start(current) - session_end(previous))
                for previous, current in zip(cluster, cluster[1:])
            ]
            max_gap = max(gaps) if gaps else 0.0
            span = end - start
            strict_ready = duration >= STRICT_MINIMUM_SECONDS
            fragmented_ready = (
                len(cluster) > 1
                and span >= FRAGMENTED_MINIMUM_SPAN_SECONDS
                and duration >= FRAGMENTED_MINIMUM_SECONDS
                and max_gap <= SLEEP_CLUSTER_GAP_SECONDS
            )
            zone = timezone_for(timezone)
            cluster_start_hour = (APPLE_EPOCH + dt.timedelta(seconds=start)).astimezone(zone).hour
            cluster_end_hour = (APPLE_EPOCH + dt.timedelta(seconds=end)).astimezone(zone).hour
            nap_ready = (
                cluster_start_hour >= 11
                and cluster_end_hour <= 20
                and span <= NAP_MAXIMUM_SPAN_SECONDS
                and duration >= NAP_MINIMUM_SECONDS
            )
            if not (strict_ready or fragmented_ready or nap_ready):
                continue
            values = [bpm for session in cluster for bpm in bpms(session)]
            motion = motion_status(start, end, archive)
            candidates.append({
                "day": day.isoformat(),
                "sessions": len(cluster),
                "start": start,
                "end": end,
                "duration": duration,
                "span": span,
                "max_gap": max_gap,
                "samples": len(values),
                "avg": round(sum(values) / len(values)) if values else 0,
                "peak": max(values) if values else 0,
                "sleep_rhr": percentile_nearest_rank(values, 0.05),
                "strict_ready": strict_ready,
                "fragmented_ready": fragmented_ready,
                "nap_ready": nap_ready,
                "fallback_source": "hr_only_fragmented_sleep" if len(cluster) > 1 else "hr_only_sleep",
                "kind": "nap_candidate" if nap_ready else "overnight_sleep",
                "motion": motion,
                "ready": bool(motion.get("validated")),
                "blocker": "none" if motion.get("validated") else candidate_blocker(motion),
                "labels": ",".join(sorted({str(session.get("label", "")) for session in cluster if session.get("label")})),
            })
    counts["candidates"] = len(candidates)
    return sorted(candidates, key=lambda item: (item["ready"], item["day"], item["duration"]), reverse=True), counts


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("sessions_json", type=Path)
    parser.add_argument("--historical-archive", type=Path)
    parser.add_argument("--rest", type=int, required=True)
    parser.add_argument("--max-hr", type=int, required=True)
    parser.add_argument("--timezone", choices=["UTC", "IST"], default="UTC")
    parser.add_argument("--limit", type=int, default=10)
    args = parser.parse_args()

    sessions = load_sessions(args.sessions_json)
    archive = load_archive_range(args.historical_archive)
    candidates, counts = aggregate_candidates(sessions, args.rest, args.max_hr, args.timezone, archive)
    ready_count = sum(1 for candidate in candidates if candidate["ready"])
    fallback = candidates[0] if candidates else None
    print(
        f"sessions={len(sessions)} evaluated={counts['evaluated']} eligible={counts['eligible']} "
        f"too_short={counts['too_short']} not_overnight={counts['not_overnight']} "
        f"hr_too_high={counts['hr_too_high']} workout_like={counts['workout_like']} "
        f"candidates={counts['candidates']} ready={ready_count} "
        f"rest_hr={args.rest} max_hr={args.max_hr} strict_min_s={STRICT_MINIMUM_SECONDS} "
        f"fragmented_min_s={FRAGMENTED_MINIMUM_SECONDS} fragmented_min_span_s={FRAGMENTED_MINIMUM_SPAN_SECONDS} "
        f"cluster_gap_limit_s={SLEEP_CLUSTER_GAP_SECONDS} nap_min_s={NAP_MINIMUM_SECONDS} nap_max_span_s={NAP_MAXIMUM_SPAN_SECONDS}"
    )
    print(
        "archive "
        f"rows={archive['rows']} validated_rows={archive['validated_rows']} "
        f"first_unix={archive['first_unix'] if archive['first_unix'] is not None else 'none'} "
        f"last_unix={archive['last_unix'] if archive['last_unix'] is not None else 'none'} "
        f"first_iso={iso_unix(archive['first_unix'])} last_iso={iso_unix(archive['last_unix'])}"
    )
    if fallback:
        motion = fallback["motion"]
        print(
            "best "
            f"ready={1 if fallback['ready'] else 0} blocker={fallback['blocker']} "
            f"fallback_source={fallback['fallback_source']} diagnostic_only={0 if fallback['ready'] else 1} "
            f"duration_s={fallback['duration']:.0f} span_s={fallback['span']:.0f} "
            f"sessions={fallback['sessions']} motion_reason={motion['reason']} "
            f"motion_overlap_s={float(motion['overlap_s']):.0f} "
            f"motion_nearest_separation_s={motion['nearest_separation_s']} "
            f"motion_validated={1 if motion['validated'] else 0}"
        )
    else:
        print("best ready=0 blocker=sleep_learning fallback_source=none diagnostic_only=1")

    print("day\tkind\tstart\tend\tduration_s\tspan_s\tmax_gap_s\tsessions\tsamples\tavg\tpeak\tsleep_rhr\tstrict_ready\tfragmented_ready\tnap_ready\tready\tblocker\tfallback_source\tmotion_reason\tmotion_overlap_s\tmotion_nearest_separation_s\tmotion_validated\tlabels")
    for candidate in candidates[: args.limit]:
        motion = candidate["motion"]
        print(
            "\t".join([
                candidate["day"],
                candidate["kind"],
                apple_time(candidate["start"], args.timezone),
                apple_time(candidate["end"], args.timezone),
                f"{candidate['duration']:.0f}",
                f"{candidate['span']:.0f}",
                f"{candidate['max_gap']:.0f}",
                str(candidate["sessions"]),
                str(candidate["samples"]),
                str(candidate["avg"]),
                str(candidate["peak"]),
                str(candidate["sleep_rhr"]),
                "1" if candidate["strict_ready"] else "0",
                "1" if candidate["fragmented_ready"] else "0",
                "1" if candidate["nap_ready"] else "0",
                "1" if candidate["ready"] else "0",
                candidate["blocker"],
                candidate["fallback_source"],
                str(motion["reason"]),
                f"{float(motion['overlap_s']):.0f}",
                str(motion["nearest_separation_s"]),
                "1" if motion["validated"] else "0",
                candidate["labels"],
            ])
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
