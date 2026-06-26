#!/usr/bin/env python3
"""Summarize Atria saved sessions for Gate D/E workout evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
from pathlib import Path
from typing import Any


APPLE_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
# Standard BLE Heart Rate (`2A37`) is not guaranteed to arrive at exact 1 Hz
# cadence. This limit is for HR/workout coverage only; RR/HRV validators keep
# their stricter no->3s-gap contract.
GAP_LIMIT_SECONDS = 15.0
CLUSTER_GAP_SECONDS = 30 * 60
BORDERLINE_THRESHOLD_MARGIN_BPM = 5
MIN_WORKOUT_WINDOW_SECONDS = 10 * 60
MAX_WORKOUT_WINDOW_SECONDS = 90 * 60
WORKOUT_WINDOW_STEP_SECONDS = 5 * 60


def load_sessions(path: Path) -> list[dict[str, Any]]:
    data = json.loads(path.read_text())
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and isinstance(data.get("sessions"), list):
        return data["sessions"]
    raise SystemExit(f"{path} is not a sessions array or backup envelope")


def load_active_journal(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or data.get("schema") != 1:
        raise SystemExit(f"{path} is not an active-session journal v1 record")
    samples = data.get("samples") or []
    if len(samples) < 2:
        return None
    start = app_seconds(data.get("startedAt", samples[0].get("t", 0)))
    end = app_seconds(samples[-1].get("t", start))
    points = [
        {
            "t": max(0.0, app_seconds(sample.get("t", start)) - start),
            "bpm": int(sample.get("bpm", 0)),
        }
        for sample in samples
        if sample.get("bpm") is not None
    ]
    rr_points = [
        {
            "t": max(0.0, app_seconds(sample.get("t", start)) - start),
            "ms": int(sample.get("ms", 0)),
        }
        for sample in (data.get("rrSamples") or [])
        if sample.get("ms") is not None
    ]
    rr_summary = rr_gap_summary(rr_points)
    return {
        "label": f"{data.get('label', 'Active session')} active journal",
        "start": start,
        "end": end,
        "points": points,
        "rrPoints": rr_points,
        "activeJournal": True,
        "activeJournalRawHRNotifications": int(data.get("rawHRNotifications") or 0),
        "activeJournalAcceptedHRSamples": int(data.get("acceptedHRSamples") or 0),
        "activeJournalRawHRGaps": int(data.get("rawHRGaps") or 0),
        "activeJournalAcceptedHRGaps": int(data.get("acceptedHRGaps") or 0),
        "activeJournalMaxRawHRGap": float(data.get("maxRawHRGap") or 0),
        "activeJournalMaxAcceptedHRGap": float(data.get("maxAcceptedHRGap") or 0),
        "activeJournalRRMaxGap": rr_summary["max_gap"],
        "activeJournalRRGapOver3": rr_summary["gap_over_3"],
        "activeJournalRRGapOver5": rr_summary["gap_over_5"],
        "activeJournalRRCoverage3": rr_summary["coverage_3_percent"],
    }


def rr_gap_summary(rr_points: list[dict[str, Any]]) -> dict[str, Any]:
    if len(rr_points) < 2:
        return {"max_gap": 0.0, "gap_over_3": 0, "gap_over_5": 0, "coverage_3_percent": 0}
    ordered = sorted(rr_points, key=lambda point: float(point["t"]))
    span = max(0.0, float(ordered[-1]["t"]) - float(ordered[0]["t"]))
    observed_3 = 0.0
    max_gap = 0.0
    gap_over_3 = 0
    gap_over_5 = 0
    for previous, current in zip(ordered, ordered[1:]):
        gap = max(0.0, float(current["t"]) - float(previous["t"]))
        max_gap = max(max_gap, gap)
        if gap > 3:
            gap_over_3 += 1
        else:
            observed_3 += gap
        if gap > GAP_LIMIT_SECONDS:
            gap_over_5 += 1
    coverage = min(100, max(0, round((observed_3 / span) * 100))) if span > 0 else 0
    return {
        "max_gap": max_gap,
        "gap_over_3": gap_over_3,
        "gap_over_5": gap_over_5,
        "coverage_3_percent": coverage,
    }


def app_seconds(value: Any) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        text = value.strip()
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            parsed = dt.datetime.fromisoformat(text)
        except ValueError as exc:
            raise SystemExit(f"unsupported timestamp: {value}") from exc
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return (parsed.astimezone(dt.timezone.utc) - APPLE_EPOCH).total_seconds()
    raise SystemExit(f"unsupported timestamp type: {type(value).__name__}")


def apple_time(seconds: float, timezone: str) -> str:
    zone = timezone_for(timezone)
    return (APPLE_EPOCH + dt.timedelta(seconds=seconds)).astimezone(zone).strftime("%Y-%m-%d %H:%M:%S %Z")


def timezone_for(name: str) -> dt.timezone:
    if name.upper() == "IST":
        return dt.timezone(dt.timedelta(hours=5, minutes=30), "IST")
    return dt.timezone.utc


def day_key(seconds: float, timezone: str) -> dt.date:
    return (APPLE_EPOCH + dt.timedelta(seconds=seconds)).astimezone(timezone_for(timezone)).date()


def workout_threshold(rest: int, max_hr: int, threshold_fraction: float) -> int:
    # Match Swift's positive-BPM rounded() behavior instead of Python's
    # bankers rounding, so offline audits agree with on-device gates.
    return int(math.floor(rest + max(0, max_hr - rest) * threshold_fraction + 0.5))


def workout_summary(session: dict[str, Any], rest: int, max_hr: int, threshold_fraction: float = 0.50) -> dict[str, Any]:
    points = session.get("points") or []
    rr_points = session.get("rrPoints") or []
    rr_summary = rr_gap_summary(rr_points)
    threshold = workout_threshold(rest, max_hr, threshold_fraction)
    borderline_threshold = max(rest, threshold - BORDERLINE_THRESHOLD_MARGIN_BPM)
    start = app_seconds(session.get("start", 0))
    end = app_seconds(session.get("end", start))
    observed = 0.0
    dropped = 0.0
    max_gap = 0.0
    gap_count = 0
    elevated = 0.0
    bout = 0.0
    longest = 0.0
    borderline_elevated = 0.0
    borderline_bout = 0.0
    borderline_longest = 0.0
    for previous, current in zip(points, points[1:]):
        delta = max(0.0, float(current["t"]) - float(previous["t"]))
        if delta > GAP_LIMIT_SECONDS:
            dropped += delta
            max_gap = max(max_gap, delta)
            gap_count += 1
            bout = 0.0
            borderline_bout = 0.0
            continue
        observed += delta
        if int(current["bpm"]) >= threshold:
            elevated += delta
            bout += delta
            longest = max(longest, bout)
        else:
            bout = 0.0
        if int(current["bpm"]) >= borderline_threshold:
            borderline_elevated += delta
            borderline_bout += delta
            borderline_longest = max(borderline_longest, borderline_bout)
        else:
            borderline_bout = 0.0

    required_elevated = min(max(observed * 0.35, 5 * 60), 20 * 60)
    required_bout = min(max(observed * 0.20, 3 * 60), 8 * 60)
    ready = observed >= 10 * 60 and elevated >= required_elevated and longest >= required_bout
    bpms = [int(point["bpm"]) for point in points]
    peak = max(bpms) if bpms else 0
    samples_above_threshold = sum(1 for bpm in bpms if bpm >= threshold)
    samples_above_borderline = sum(1 for bpm in bpms if bpm >= borderline_threshold)
    threshold_gap = max(0, threshold - peak)
    stream_coverage = workout_stream_coverage_percent(observed=observed, duration=end - start)
    reason = "sustained_elevated_hr" if ready else "learning"
    if not ready:
        if observed < 10 * 60:
            reason = "observed_duration_below_10m_stream_gaps" if gap_count else "duration_below_10m"
        elif elevated < required_elevated:
            reason = "elevated_seconds_below_required"
        elif longest < required_bout:
            reason = "elevated_bout_below_required"
    primary_blocker = workout_primary_blocker(
        ready=ready,
        duration=end - start,
        observed_duration=observed,
        dropped_gap_seconds=dropped,
        max_sample_gap=max_gap,
        peak_hr=peak,
        threshold_hr=threshold,
        elevated_seconds=elevated,
        required_elevated_seconds=required_elevated,
        longest_bout=longest,
        required_bout=required_bout,
    )
    near_miss = workout_near_miss(
        ready=ready,
        observed_duration=observed,
        stream_coverage=stream_coverage,
        threshold_gap=threshold_gap,
        elevated_seconds=elevated,
    )
    strength_candidate = workout_strength_candidate(
        ready=ready,
        observed_duration=observed,
        stream_coverage=stream_coverage,
        threshold_gap=threshold_gap,
        elevated_seconds=elevated,
        borderline_elevated_seconds=borderline_elevated,
        borderline_longest_bout=borderline_longest,
    )
    failure_class = workout_failure_class(
        ready=ready,
        samples=len(bpms),
        peak_hr=peak,
        threshold_hr=threshold,
        borderline_elevated_seconds=borderline_elevated,
        elevated_seconds=elevated,
        required_elevated_seconds=required_elevated,
        longest_bout=longest,
        required_bout=required_bout,
        stream_coverage=stream_coverage,
        dropped_gap_seconds=dropped,
        max_sample_gap=max_gap,
    )
    return {
        "label": session.get("label", ""),
        "start": start,
        "end": end,
        "duration": end - start,
        "observed": observed,
        "dropped": dropped,
        "max_gap": max_gap,
        "gap_count": gap_count,
        "samples": len(points),
        "rr": len(session.get("rrPoints") or []),
        "avg": round(sum(bpms) / len(bpms)) if bpms else 0,
        "min": min(bpms) if bpms else 0,
        "p90": percentile_nearest_rank(bpms, 90),
        "p95": percentile_nearest_rank(bpms, 95),
        "p99": percentile_nearest_rank(bpms, 99),
        "peak": peak,
        "threshold": threshold,
        "hrr_percent": round(threshold_fraction * 100),
        "threshold_gap": threshold_gap,
        "samples_above_threshold": samples_above_threshold,
        "samples_above_borderline": samples_above_borderline,
        "stream_coverage": stream_coverage,
        "failure_class": failure_class,
        "primary_blocker": primary_blocker,
        "near_miss": near_miss,
        "near_miss_reason": workout_near_miss_reason(
            near_miss=near_miss,
            stream_coverage=stream_coverage,
            dropped_gap_seconds=dropped,
            max_sample_gap=max_gap,
            threshold_gap=threshold_gap,
            elevated_seconds=elevated,
            required_elevated_seconds=required_elevated,
            longest_bout=longest,
            required_bout=required_bout,
        ),
        "strength_candidate": strength_candidate,
        "strength_candidate_reason": workout_strength_candidate_reason(
            strength_candidate=strength_candidate,
            stream_coverage=stream_coverage,
            dropped_gap_seconds=dropped,
            max_sample_gap=max_gap,
            threshold_gap=threshold_gap,
            elevated_seconds=elevated,
            required_elevated_seconds=required_elevated,
            longest_bout=longest,
            required_bout=required_bout,
            borderline_elevated_seconds=borderline_elevated,
        ),
        "next_action": workout_next_action(
            ready=ready,
            stream_coverage=stream_coverage,
            dropped_gap_seconds=dropped,
            max_sample_gap=max_gap,
            peak_hr=peak,
            p95_hr=percentile_nearest_rank(bpms, 95),
            threshold_hr=threshold,
            elevated_seconds=elevated,
            required_elevated_seconds=required_elevated,
            longest_bout=longest,
            required_bout=required_bout,
        ),
        "elevated": elevated,
        "required_elevated": required_elevated,
        "longest": longest,
        "required_bout": required_bout,
        "borderline_threshold": borderline_threshold,
        "borderline_elevated": borderline_elevated,
        "borderline_longest": borderline_longest,
        "ready": ready,
        "reason": reason,
        "source": "active_journal" if session.get("activeJournal") else "single_session",
        "chunks": 1,
        "span": end - start,
        "labels": session.get("label", ""),
        "rr_max_gap": session.get("activeJournalRRMaxGap", rr_summary["max_gap"]),
        "rr_gap_over_3": session.get("activeJournalRRGapOver3", rr_summary["gap_over_3"]),
        "rr_gap_over_5": session.get("activeJournalRRGapOver5", rr_summary["gap_over_5"]),
        "rr_coverage_3_percent": session.get("activeJournalRRCoverage3", rr_summary["coverage_3_percent"]),
    }


def workout_stream_coverage_percent(observed: float, duration: float) -> int:
    if duration <= 0:
        return 0
    return min(100, max(0, round((observed / duration) * 100)))


def percentile_nearest_rank(values: list[int], percentile: int) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    rank = max(1, round((percentile / 100) * len(ordered)))
    return ordered[min(len(ordered) - 1, rank - 1)]


def workout_failure_class(
    *,
    ready: bool,
    samples: int,
    peak_hr: int,
    threshold_hr: int,
    borderline_elevated_seconds: float,
    elevated_seconds: float,
    required_elevated_seconds: float,
    longest_bout: float,
    required_bout: float,
    stream_coverage: int,
    dropped_gap_seconds: float,
    max_sample_gap: float,
) -> str:
    if ready:
        return "ready"
    if samples == 0:
        return "no_hr_samples"
    if peak_hr < threshold_hr and borderline_elevated_seconds < 60:
        return "hr_signal_below_workout_band"
    if peak_hr < threshold_hr:
        return "threshold_near_miss"
    if elevated_seconds < 60 and borderline_elevated_seconds < 120:
        return "insufficient_workout_band_time"
    if stream_coverage < 75 or dropped_gap_seconds > 0 or max_sample_gap > GAP_LIMIT_SECONDS:
        return "fragmented_stream"
    if elevated_seconds < required_elevated_seconds:
        return "insufficient_elevated_time"
    if longest_bout < required_bout:
        return "insufficient_continuous_bout"
    return "detector_not_workout"


def workout_primary_blocker(
    *,
    ready: bool,
    duration: float,
    observed_duration: float,
    dropped_gap_seconds: float,
    max_sample_gap: float,
    peak_hr: int,
    threshold_hr: int,
    elevated_seconds: float,
    required_elevated_seconds: float,
    longest_bout: float,
    required_bout: float,
) -> str:
    if ready:
        return "none"
    duration_blocked = observed_duration < 10 * 60
    actual_stream_gaps = dropped_gap_seconds > 0 or max_sample_gap > GAP_LIMIT_SECONDS
    stream_gap_blocked = actual_stream_gaps and (
        duration_blocked
        or (duration > 0 and dropped_gap_seconds / duration >= 0.25)
        or max_sample_gap > 30
    )
    hr_below_threshold = peak_hr < threshold_hr
    if duration_blocked and not actual_stream_gaps and hr_below_threshold:
        return "duration_below_10m_and_hr_below_threshold"
    if duration_blocked and not actual_stream_gaps:
        return "duration_below_10m"
    if stream_gap_blocked and hr_below_threshold:
        return "stream_gaps_and_hr_below_threshold"
    if stream_gap_blocked:
        return "stream_gaps"
    if hr_below_threshold:
        return "hr_below_threshold"
    if elevated_seconds < required_elevated_seconds:
        return "insufficient_elevated_time"
    if longest_bout < required_bout:
        return "insufficient_continuous_bout"
    return "detector_not_workout"


def workout_near_miss(
    *,
    ready: bool,
    observed_duration: float,
    stream_coverage: int,
    threshold_gap: int,
    elevated_seconds: float,
) -> bool:
    if ready:
        return False
    return (
        observed_duration >= 10 * 60
        and stream_coverage >= 20
        and (threshold_gap <= 5 or elevated_seconds > 0)
    )


def workout_near_miss_reason(
    *,
    near_miss: bool,
    stream_coverage: int,
    dropped_gap_seconds: float,
    max_sample_gap: float,
    threshold_gap: int,
    elevated_seconds: float,
    required_elevated_seconds: float,
    longest_bout: float,
    required_bout: float,
) -> str:
    if not near_miss:
        return "none"
    reasons = []
    if stream_coverage < 75 or dropped_gap_seconds > 0 or max_sample_gap > GAP_LIMIT_SECONDS:
        reasons.append("stream_coverage_low")
    if threshold_gap > 0:
        reasons.append(f"peak_within_{threshold_gap}_bpm_below_threshold")
    if elevated_seconds < required_elevated_seconds:
        reasons.append("elevated_seconds_below_required")
    if longest_bout < required_bout:
        reasons.append("continuous_bout_below_required")
    return "+".join(reasons) if reasons else "near_miss_low_confidence"


def workout_strength_candidate(
    *,
    ready: bool,
    observed_duration: float,
    stream_coverage: int,
    threshold_gap: int,
    elevated_seconds: float,
    borderline_elevated_seconds: float,
    borderline_longest_bout: float,
) -> bool:
    if ready:
        return False
    return (
        observed_duration >= 10 * 60
        and stream_coverage >= 20
        and (threshold_gap <= 5 or elevated_seconds > 0)
        and (borderline_elevated_seconds >= 30 or borderline_longest_bout >= 10)
    )


def workout_strength_candidate_reason(
    *,
    strength_candidate: bool,
    stream_coverage: int,
    dropped_gap_seconds: float,
    max_sample_gap: float,
    threshold_gap: int,
    elevated_seconds: float,
    required_elevated_seconds: float,
    longest_bout: float,
    required_bout: float,
    borderline_elevated_seconds: float,
) -> str:
    if not strength_candidate:
        return "none"
    reasons = ["diagnostic_only"]
    if stream_coverage < 75 or dropped_gap_seconds > 0 or max_sample_gap > GAP_LIMIT_SECONDS:
        reasons.append("stream_gaps_prevent_count")
    if threshold_gap > 0:
        reasons.append(f"peak_within_{threshold_gap}_bpm_below_hrr50")
    if borderline_elevated_seconds > 0:
        reasons.append(f"borderline_hr_band_{round(borderline_elevated_seconds)}s")
    if elevated_seconds < required_elevated_seconds:
        reasons.append("workout_band_time_insufficient")
    if longest_bout < required_bout:
        reasons.append("continuous_bout_insufficient")
    return "+".join(reasons)


def workout_next_action(
    *,
    ready: bool,
    stream_coverage: int,
    dropped_gap_seconds: float,
    max_sample_gap: float,
    peak_hr: int,
    p95_hr: int,
    threshold_hr: int,
    elevated_seconds: float,
    required_elevated_seconds: float,
    longest_bout: float,
    required_bout: float,
) -> str:
    if ready:
        return "count_workout"
    has_stream_gap = stream_coverage < 75 or dropped_gap_seconds > 0 or max_sample_gap > GAP_LIMIT_SECONDS
    needs_hr_reference = peak_hr < threshold_hr
    if has_stream_gap and needs_hr_reference:
        return "fix_stream_continuity_and_validate_intensity"
    if has_stream_gap:
        return "fix_stream_continuity_before_counting"
    if needs_hr_reference:
        return "validate_intensity_with_reference_or_profile"
    if p95_hr < threshold_hr and elevated_seconds < 60:
        return "validate_wrist_hr_underreporting_or_profile_before_more_workouts"
    if elevated_seconds < required_elevated_seconds or longest_bout < required_bout:
        return "keep_learning_until_sustained_hr"
    return "inspect_detector_inputs"


def session_duration(session: dict[str, Any]) -> float:
    start = app_seconds(session.get("start", 0))
    end = app_seconds(session.get("end", start))
    return max(0.0, end - start)


def workout_clusters(sessions: list[dict[str, Any]]) -> list[list[dict[str, Any]]]:
    ordered = sorted(sessions, key=lambda item: app_seconds(item.get("start", 0)))
    clusters: list[list[dict[str, Any]]] = []
    current: list[dict[str, Any]] = []
    current_end: float | None = None
    for session in ordered:
        start = app_seconds(session.get("start", 0))
        end = app_seconds(session.get("end", start))
        if current and current_end is not None and start - current_end > CLUSTER_GAP_SECONDS:
            clusters.append(current)
            current = []
        current.append(session)
        current_end = max(current_end or end, end)
    if current:
        clusters.append(current)
    return clusters


def aggregate_workout_summaries(
    sessions: list[dict[str, Any]],
    rest: int,
    max_hr: int,
    timezone: str,
    threshold_fraction: float = 0.50,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for aggregate in aggregate_workout_sessions(sessions, timezone):
        row = workout_summary(aggregate, rest, max_hr, threshold_fraction=threshold_fraction)
        row["source"] = "aggregate_chunks"
        row["chunks"] = aggregate["chunks"]
        row["span"] = aggregate["end"] - aggregate["start"]
        row["labels"] = aggregate["labels"]
        rows.append(row)
    for aggregate in stitched_observed_workout_sessions(sessions, timezone):
        row = workout_summary(aggregate, rest, max_hr, threshold_fraction=threshold_fraction)
        row["source"] = "stitched_observed_chunks"
        row["chunks"] = aggregate["chunks"]
        row["span"] = aggregate["span"]
        row["labels"] = aggregate["labels"]
        rows.append(row)
    return sorted_workout_candidates(rows)


def aggregate_workout_sessions(sessions: list[dict[str, Any]], timezone: str) -> list[dict[str, Any]]:
    eligible = [
        session
        for session in sessions
        if (session.get("points") or []) and session_duration(session) >= 60
    ]
    grouped: dict[dt.date, list[dict[str, Any]]] = {}
    for session in eligible:
        grouped.setdefault(day_key(app_seconds(session.get("start", 0)), timezone), []).append(session)

    aggregates: list[dict[str, Any]] = []
    for day_sessions in grouped.values():
        for cluster in workout_clusters(day_sessions):
            if len(cluster) <= 1:
                continue
            starts = [app_seconds(session.get("start", 0)) for session in cluster]
            ends = [app_seconds(session.get("end", session.get("start", 0))) for session in cluster]
            start = min(starts)
            end = max(ends)
            points: list[dict[str, Any]] = []
            labels = sorted({str(session.get("label", "")) for session in cluster if session.get("label", "")})
            for session in sorted(cluster, key=lambda item: app_seconds(item.get("start", 0))):
                session_start = app_seconds(session.get("start", 0))
                for point in session.get("points") or []:
                    points.append({
                        "t": session_start + float(point["t"]) - start,
                        "bpm": int(point["bpm"]),
                    })
            points.sort(key=lambda point: (point["t"], point["bpm"]))
            if len(points) < 2:
                continue
            if len(labels) == 1:
                label = f"{labels[0]} aggregate"
            elif labels:
                label = f"{labels[0]} + {len(labels) - 1} chunks"
            else:
                label = "Workout aggregate"
            aggregates.append({
                "label": label,
                "start": start,
                "end": end,
                "points": points,
                "rrPoints": [],
                "chunks": len(cluster),
                "labels": ",".join(labels),
            })
    return aggregates


def stitched_observed_workout_sessions(sessions: list[dict[str, Any]], timezone: str) -> list[dict[str, Any]]:
    eligible = [
        session
        for session in sessions
        if (session.get("points") or []) and session_duration(session) >= 60
    ]
    grouped: dict[dt.date, list[dict[str, Any]]] = {}
    for session in eligible:
        grouped.setdefault(day_key(app_seconds(session.get("start", 0)), timezone), []).append(session)

    stitched: list[dict[str, Any]] = []
    reset_gap = GAP_LIMIT_SECONDS + 1
    for day_sessions in grouped.values():
        for cluster in workout_clusters(day_sessions):
            if len(cluster) <= 1:
                continue
            starts = [app_seconds(session.get("start", 0)) for session in cluster]
            ends = [app_seconds(session.get("end", session.get("start", 0))) for session in cluster]
            start = min(starts)
            end = max(ends)
            cursor = 0.0
            points: list[dict[str, Any]] = []
            labels = sorted({str(session.get("label", "")) for session in cluster if session.get("label", "")})
            for session in sorted(cluster, key=lambda item: app_seconds(item.get("start", 0))):
                session_points = sorted(
                    session.get("points") or [],
                    key=lambda point: (float(point["t"]), int(point["bpm"])),
                )
                if not session_points:
                    continue
                previous = session_points[0]
                points.append({"t": cursor, "bpm": int(previous["bpm"])})
                for point in session_points[1:]:
                    delta = max(0.0, float(point["t"]) - float(previous["t"]))
                    cursor += reset_gap if delta > GAP_LIMIT_SECONDS else delta
                    points.append({"t": cursor, "bpm": int(point["bpm"])})
                    previous = point
                cursor += reset_gap
            if len(points) < 2:
                continue
            if len(labels) == 1:
                label = f"{labels[0]} aggregate observed"
            elif labels:
                label = f"{labels[0]} + {len(labels) - 1} chunks observed"
            else:
                label = "Workout aggregate observed"
            stitched.append({
                "label": label,
                "start": start,
                "end": start + points[-1]["t"],
                "points": points,
                "rrPoints": [],
                "chunks": len(cluster),
                "labels": ",".join(labels),
                "span": end - start,
            })
    return stitched


def sorted_workout_candidates(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(rows, key=workout_replay_sort_key, reverse=True)


def windowed_workout_summaries(
    sessions: list[dict[str, Any]],
    rest: int,
    max_hr: int,
    threshold_fraction: float = 0.50,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for session in sessions:
        if not (session.get("points") or []) or session_duration(session) < MIN_WORKOUT_WINDOW_SECONDS:
            continue
        rows.extend(
            workout_windows_for_session(
                session,
                rest,
                max_hr,
                source="windowed_workout",
                threshold_fraction=threshold_fraction,
            )
        )
    return sorted_workout_candidates(rows)


def aggregate_window_summaries(
    sessions: list[dict[str, Any]],
    rest: int,
    max_hr: int,
    timezone: str,
    threshold_fraction: float = 0.50,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for aggregate in aggregate_workout_sessions(sessions, timezone):
        rows.extend(
            workout_windows_for_session(
                aggregate,
                rest,
                max_hr,
                source="aggregate_window",
                threshold_fraction=threshold_fraction,
            )
        )
    return sorted_workout_candidates(rows)


def workout_windows_for_session(
    session: dict[str, Any],
    rest: int,
    max_hr: int,
    *,
    source: str,
    threshold_fraction: float = 0.50,
) -> list[dict[str, Any]]:
    session_start = app_seconds(session.get("start", 0))
    points = sorted(absolute_points(session.get("points") or [], session_start), key=lambda point: point["t"])
    if len(points) < 2:
        return []
    rr_points = sorted(absolute_rr_points(session.get("rrPoints") or [], session_start), key=lambda point: point["t"])
    times = [float(point["t"]) for point in points]
    rr_times = [float(point["t"]) for point in rr_points]
    start_indices = window_start_indices(times)
    rows: list[dict[str, Any]] = []
    seen: set[tuple[str, int, int]] = set()
    for start_index in start_indices:
        start = times[start_index]
        for target_duration in range(MIN_WORKOUT_WINDOW_SECONDS, MAX_WORKOUT_WINDOW_SECONDS + 1, WORKOUT_WINDOW_STEP_SECONDS):
            end_index = first_index_at_or_after(times, start + target_duration, low=start_index + 1)
            if end_index is None:
                break
            end = times[end_index]
            span = end - start
            if span < MIN_WORKOUT_WINDOW_SECONDS:
                continue
            if span > MAX_WORKOUT_WINDOW_SECONDS:
                break
            dedupe_key = (source, round(start * 1000), round(end * 1000))
            if dedupe_key in seen:
                continue
            seen.add(dedupe_key)
            window_points = [
                {"t": point["t"] - start, "bpm": point["bpm"]}
                for point in points[start_index:end_index + 1]
            ]
            rr_start_index = first_index_at_or_after(rr_times, start) if rr_points else None
            rr_end_index = first_index_after(rr_times, end) if rr_points else None
            window_rr_points = []
            if rr_start_index is not None and rr_end_index is not None:
                window_rr_points = [
                    {"t": point["t"] - start, "ms": point["ms"]}
                    for point in rr_points[rr_start_index:rr_end_index]
                ]
            row = workout_summary(
                {
                    "label": f"{session.get('label', 'Workout')} window {round(span / 60)}m",
                    "start": start,
                    "end": end,
                    "points": window_points,
                    "rrPoints": window_rr_points,
                },
                rest,
                max_hr,
                threshold_fraction=threshold_fraction,
            )
            row["source"] = source
            row["chunks"] = int(session.get("chunks", 1))
            row["span"] = span
            row["labels"] = str(session.get("labels") or session.get("label", ""))
            rows.append(row)
    return rows


def absolute_points(points: list[dict[str, Any]], start: float) -> list[dict[str, Any]]:
    return [
        {
            "t": start + float(point["t"]),
            "bpm": int(point["bpm"]),
        }
        for point in points
        if point.get("t") is not None and point.get("bpm") is not None
    ]


def absolute_rr_points(points: list[dict[str, Any]], start: float) -> list[dict[str, Any]]:
    return [
        {
            "t": start + float(point["t"]),
            "ms": int(point["ms"]),
        }
        for point in points
        if point.get("t") is not None and point.get("ms") is not None
    ]


def window_start_indices(times: list[float]) -> list[int]:
    if not times:
        return []
    indices: list[int] = []
    next_start = times[0]
    for index, timestamp in enumerate(times):
        if timestamp >= next_start:
            indices.append(index)
            next_start = timestamp + WORKOUT_WINDOW_STEP_SECONDS
    return indices


def first_index_at_or_after(times: list[float], target: float, low: int = 0) -> int | None:
    left = low
    right = len(times)
    while left < right:
        middle = (left + right) // 2
        if times[middle] < target:
            left = middle + 1
        else:
            right = middle
    return left if left < len(times) else None


def first_index_after(times: list[float], target: float, low: int = 0) -> int | None:
    left = low
    right = len(times)
    while left < right:
        middle = (left + right) // 2
        if times[middle] <= target:
            left = middle + 1
        else:
            right = middle
    return left if left <= len(times) else None


def all_workout_rows(
    sessions: list[dict[str, Any]],
    rest: int,
    max_hr: int,
    timezone: str,
    threshold_fraction: float = 0.50,
) -> list[dict[str, Any]]:
    rows = [workout_summary(session, rest, max_hr, threshold_fraction=threshold_fraction) for session in sessions]
    windowed_rows = windowed_workout_summaries(sessions, rest, max_hr, threshold_fraction=threshold_fraction)
    aggregate_rows = aggregate_workout_summaries(sessions, rest, max_hr, timezone, threshold_fraction=threshold_fraction)
    aggregate_window_rows = aggregate_window_summaries(sessions, rest, max_hr, timezone, threshold_fraction=threshold_fraction)
    return rows + windowed_rows + aggregate_rows + aggregate_window_rows


def order_workout_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(rows, key=workout_replay_sort_key, reverse=True)


def workout_replay_sort_key(row: dict[str, Any]) -> tuple:
    return (
        int(row["ready"]),
        int(row["near_miss"]),
        row["observed"] >= 10 * 60,
        row["elevated"] > 0 or row["peak"] >= row["threshold"],
        row["longest"],
        row["elevated"],
        row["borderline_longest"],
        row["borderline_elevated"],
        row["peak"],
        row["stream_coverage"],
        row["observed"],
        -row["max_gap"],
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("sessions_json", type=Path)
    parser.add_argument("--rest", type=int, required=True)
    parser.add_argument("--max-hr", type=int, required=True)
    parser.add_argument("--timezone", default="UTC", choices=["UTC", "IST"])
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--active-journal", type=Path)
    args = parser.parse_args()

    sessions = load_sessions(args.sessions_json)
    active_journal = load_active_journal(args.active_journal) if args.active_journal else None
    rows = [workout_summary(session, args.rest, args.max_hr) for session in sessions]
    active_rows = [workout_summary(active_journal, args.rest, args.max_hr)] if active_journal else []
    windowed_rows = windowed_workout_summaries(sessions, args.rest, args.max_hr)
    aggregate_rows = aggregate_workout_summaries(sessions, args.rest, args.max_hr, args.timezone)
    aggregate_window_rows = aggregate_window_summaries(sessions, args.rest, args.max_hr, args.timezone)
    all_rows = rows + windowed_rows + aggregate_rows + aggregate_window_rows + active_rows
    ready = sum(1 for row in rows if row["ready"])
    active_ready = sum(1 for row in active_rows if row["ready"])
    windowed_ready = sum(1 for row in windowed_rows if row["ready"])
    aggregate_ready = sum(1 for row in aggregate_rows if row["ready"])
    aggregate_window_ready = sum(1 for row in aggregate_window_rows if row["ready"])
    near_miss = sum(1 for row in all_rows if row["near_miss"])
    strength_candidate = sum(1 for row in all_rows if row["strength_candidate"])
    total_ready = ready + windowed_ready + aggregate_ready + aggregate_window_ready + active_ready
    print(f"sessions={len(rows)} ready={ready} active_journal={len(active_rows)} active_journal_ready={active_ready} windows={len(windowed_rows)} window_ready={windowed_ready} aggregates={len(aggregate_rows)} aggregate_ready={aggregate_ready} aggregate_windows={len(aggregate_window_rows)} aggregate_window_ready={aggregate_window_ready} total_ready={total_ready} near_miss={near_miss} strength_candidate={strength_candidate} strength_diagnostic_only=1 rest_hr={args.rest} max_hr={args.max_hr} threshold_method=hrr50 window_min_s={MIN_WORKOUT_WINDOW_SECONDS} window_max_s={MAX_WORKOUT_WINDOW_SECONDS} window_step_s={WORKOUT_WINDOW_STEP_SECONDS} cluster_gap_limit_s={CLUSTER_GAP_SECONDS}")
    print("source\tchunks\tlabel\tstart\tend\tspan_s\tduration_s\tobserved_s\tdropped_gap_s\tmax_gap_s\tgap_count\tstream_coverage_percent\tsamples\trr\trr_max_gap_s\trr_gap_over_3s\trr_gap_over_5s\trr_coverage_3s_percent\tavg\tmin\tp90\tp95\tp99\tpeak\tthreshold\tthreshold_gap_bpm\tsamples_above_threshold\tsamples_above_borderline\televated_s\trequired_elevated_s\tlongest_bout_s\trequired_bout_s\tborderline_threshold\tborderline_elevated_s\tborderline_longest_bout_s\tborderline_diagnostic_only\tready\tnear_miss\tnear_miss_reason\tstrength_candidate\tstrength_candidate_reason\tstrength_diagnostic_only\tnext_action\treason\tfailure_class\tprimary_blocker\tlabels")
    for fraction in (0.35, 0.40, 0.45, 0.50):
        sensitivity_rows = all_workout_rows(
            sessions,
            args.rest,
            args.max_hr,
            args.timezone,
            threshold_fraction=fraction,
        )
        if active_journal:
            sensitivity_rows.append(workout_summary(active_journal, args.rest, args.max_hr, threshold_fraction=fraction))
        sensitivity_rows = order_workout_rows(sensitivity_rows)
        ready_count = sum(1 for row in sensitivity_rows if row["ready"])
        window_ready_count = sum(
            1
            for row in sensitivity_rows
            if row["ready"] and row["source"] in ("windowed_workout", "aggregate_window")
        )
        window_candidate_count = sum(
            1
            for row in sensitivity_rows
            if row["source"] in ("windowed_workout", "aggregate_window")
        )
        best = sensitivity_rows[0] if sensitivity_rows else None
        best_elevated = f"{best['elevated']:.0f}" if best else "0"
        best_required_elevated = f"{best['required_elevated']:.0f}" if best else "0"
        best_longest = f"{best['longest']:.0f}" if best else "0"
        best_required_bout = f"{best['required_bout']:.0f}" if best else "0"
        best_borderline_elevated = f"{best['borderline_elevated']:.0f}" if best else "0"
        best_borderline_longest = f"{best['borderline_longest']:.0f}" if best else "0"
        print(
            "sensitivity "
            f"hrr_percent={round(fraction * 100)} "
            f"threshold={workout_threshold(args.rest, args.max_hr, fraction)} "
            f"ready={1 if ready_count else 0} ready_candidates={ready_count} "
            f"window_ready_candidates={window_ready_count} "
            f"window_candidates={window_candidate_count} "
            f"best_source={best['source'] if best else 'none'} "
            f"best_label={best['label'] if best else 'none'} "
            f"best_peak={best['peak'] if best else 0} "
            f"best_threshold_gap_bpm={best['threshold_gap'] if best else 0} "
            f"best_elevated_s={best_elevated} "
            f"best_required_elevated_s={best_required_elevated} "
            f"best_longest_bout_s={best_longest} "
            f"best_required_bout_s={best_required_bout} "
            f"best_borderline_threshold_hr={best['borderline_threshold'] if best else 0} "
            f"best_borderline_elevated_s={best_borderline_elevated} "
            f"best_borderline_longest_bout_s={best_borderline_longest} "
            f"best_stream_coverage_percent={best['stream_coverage'] if best else 0} "
            f"best_p95_hr={best['p95'] if best else 0} "
            f"best_p99_hr={best['p99'] if best else 0} "
            f"best_samples_above_threshold={best['samples_above_threshold'] if best else 0} "
            f"best_samples_above_borderline={best['samples_above_borderline'] if best else 0} "
            f"best_failure_class={best['failure_class'] if best else 'none'} "
            f"best_strength_candidate={1 if best and best['strength_candidate'] else 0} "
            f"best_strength_candidate_reason={best['strength_candidate_reason'] if best else 'none'} "
            f"best_next_action={best['next_action'] if best else 'none'} "
            "strength_diagnostic_only=1 diagnostic_only=1 detector_threshold_hrr50_unchanged=1"
        )

    ordered_rows = order_workout_rows(all_rows)
    for row in ordered_rows[: args.limit]:
        print(
            "\t".join(
                [
                    row["source"],
                    str(row["chunks"]),
                    row["label"],
                    apple_time(row["start"], args.timezone),
                    apple_time(row["end"], args.timezone),
                    f"{row['span']:.0f}",
                    f"{row['duration']:.0f}",
                    f"{row['observed']:.0f}",
                    f"{row['dropped']:.0f}",
                    f"{row['max_gap']:.1f}",
                    str(row["gap_count"]),
                    str(row["stream_coverage"]),
                    str(row["samples"]),
                    str(row["rr"]),
                    f"{row['rr_max_gap']:.1f}",
                    str(row["rr_gap_over_3"]),
                    str(row["rr_gap_over_5"]),
                    str(row["rr_coverage_3_percent"]),
                    str(row["avg"]),
                    str(row["min"]),
                    str(row["p90"]),
                    str(row["p95"]),
                    str(row["p99"]),
                    str(row["peak"]),
                    str(row["threshold"]),
                    str(row["threshold_gap"]),
                    str(row["samples_above_threshold"]),
                    str(row["samples_above_borderline"]),
                    f"{row['elevated']:.0f}",
                    f"{row['required_elevated']:.0f}",
                    f"{row['longest']:.0f}",
                    f"{row['required_bout']:.0f}",
                    str(row["borderline_threshold"]),
                    f"{row['borderline_elevated']:.0f}",
                    f"{row['borderline_longest']:.0f}",
                    "1",
                    "1" if row["ready"] else "0",
                    "1" if row["near_miss"] else "0",
                    row["near_miss_reason"],
                    "1" if row["strength_candidate"] else "0",
                    row["strength_candidate_reason"],
                    "1",
                    row["next_action"],
                    row["reason"],
                    row["failure_class"],
                    row["primary_blocker"],
                    row["labels"],
                ]
            )
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
