#!/usr/bin/env python3
"""Decide whether a WHOOP historical transfer is usable for current metrics.

This is a Gate H honesty tool. It verifies the stored-transfer transport with
whoop_codec.py, then compares the downloaded 0x2f time range with live realtime
frames and optional on-device saved sessions. A codec-valid transfer is useful
protocol evidence; it is not metric-usable unless it overlaps the intended local
session window and the RR layout is separately validated.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import re
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.analyze_historical_2f import (  # noqa: E402
    HistoricalFrame,
    codec_summary,
    extract_frames,
    extract_realtime_frames,
    frame_time_seconds,
)

APPLE_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
KEY_RE = re.compile(r"(?<![A-Za-z0-9_])_?([A-Za-z][A-Za-z0-9_]*)=")


def parse_app_time(value: Any) -> float:
    if isinstance(value, (int, float)):
        return (APPLE_EPOCH + dt.timedelta(seconds=float(value))).timestamp()
    if isinstance(value, str):
        text = value.strip()
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        parsed = dt.datetime.fromisoformat(text)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.astimezone(dt.timezone.utc).timestamp()
    raise ValueError(f"unsupported timestamp type: {type(value).__name__}")


def iso(value: float | None) -> str:
    if value is None or not math.isfinite(value):
        return "none"
    return dt.datetime.fromtimestamp(value, tz=dt.timezone.utc).isoformat()


def overlap_seconds(lhs: tuple[float, float], rhs: tuple[float, float]) -> float:
    return max(0.0, min(lhs[1], rhs[1]) - max(lhs[0], rhs[0]))


def separation_seconds(lhs: tuple[float, float], rhs: tuple[float, float]) -> float:
    if overlap_seconds(lhs, rhs) > 0:
        return 0.0
    if lhs[1] < rhs[0]:
        return rhs[0] - lhs[1]
    return lhs[0] - rhs[1]


def load_sessions(path: Path) -> list[dict[str, Any]]:
    data = json.loads(path.read_text())
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and isinstance(data.get("sessions"), list):
        return data["sessions"]
    raise SystemExit(f"{path} is not a sessions array or backup envelope")


def session_ranges(path: Path | None) -> list[tuple[str, float, float]]:
    if path is None:
        return []
    rows: list[tuple[str, float, float]] = []
    for session in load_sessions(path):
        try:
            start = parse_app_time(session.get("start"))
            end = parse_app_time(session.get("end"))
        except (TypeError, ValueError):
            continue
        if end < start:
            start, end = end, start
        rows.append((str(session.get("label", "")), start, end))
    return rows


def snapped_clock_offset(clock: dict[str, str]) -> int | None:
    try:
        offset = int(clock.get("clock_offset_s", ""))
    except ValueError:
        return None
    if abs(offset) < 86_400:
        return 0
    granularity = 300
    if offset >= 0:
        return ((offset + granularity // 2) // granularity) * granularity
    return ((offset - granularity // 2) // granularity) * granularity


def historical_range(
    log: Path,
    corrected_offset: int | None = None,
) -> tuple[float | None, float | None, dict[str, int]]:
    frames = extract_historical_frames(log)
    summary = codec_summary(frames)
    times = [frame_time_seconds(frame) for frame in frames]
    times = [time for time in times if time is not None and math.isfinite(time)]
    if not times:
        return None, None, summary
    if corrected_offset is not None:
        times = [time + corrected_offset for time in times]
    return min(times), max(times), summary


def extract_historical_frames(log: Path) -> list[HistoricalFrame]:
    frames = extract_frames(log)
    seen_payloads = {frame.payload.hex() for frame in frames}
    for line in log.read_text(errors="ignore").splitlines():
        tokens = kv_after("ATRIADBG historicalData", line)
        payload_hex = tokens.get("payload")
        if not payload_hex:
            continue
        try:
            payload = bytes.fromhex(payload_hex)
        except ValueError:
            continue
        if payload[:1] != b"\x2f" or payload.hex() in seen_payloads:
            continue
        seen_payloads.add(payload.hex())
        frames.append(
            HistoricalFrame(
                channel="historicalData",
                declared_len=len(payload),
                payload=payload,
                raw=payload,
                codec_ok=True,
            )
        )
    for frame in frames:
        setattr(frame, "source_app_historical_data", frame.channel == "historicalData")
    return frames


def kv_after(marker: str, line: str) -> dict[str, str]:
    if marker not in line:
        return {}
    tail = line.split(marker, 1)[1].strip()
    matches = list(KEY_RE.finditer(tail))
    parsed: dict[str, str] = {}
    for index, match in enumerate(matches):
        key = match.group(1)
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(tail)
        parsed[key] = tail[start:end].strip().rstrip(";")
    return parsed


def clock_report(log: Path) -> dict[str, str]:
    latest: dict[str, str] = {}
    set_responses = 0
    for line in log.read_text(errors="replace").splitlines():
        if "ATRIADBG historyClock status=set_clock_response" in line:
            set_responses += 1
        if "ATRIADBG historyClock status=get_clock_response" in line:
            latest = kv_after("ATRIADBG historyClock", line)
    if not latest:
        return {
            "clock_correlation_present": "0",
            "clock_set_responses": str(set_responses),
            "clock_offset_s": "missing",
            "clock_stale_history_policy": "missing_clock_ref",
        }
    stale = latest.get("stale", "0") == "1"
    return {
        "clock_correlation_present": "1",
        "clock_set_responses": str(set_responses),
        "clock_device_unix": latest.get("device", "missing"),
        "clock_wall_unix": latest.get("wall", "missing"),
        "clock_offset_s": latest.get("drift_s", "missing"),
        "clock_stale_history_policy": "corrected_diagnostic_only" if stale else "identity_or_small_drift",
    }


def best_session_overlap(
    historical: tuple[float, float],
    sessions: list[tuple[str, float, float]],
) -> dict[str, Any]:
    if not sessions:
        return {
            "saved_sessions": 0,
            "saved_overlap_seconds": 0.0,
            "saved_best_label": "none",
            "saved_best_separation_seconds": None,
        }
    best = None
    for label, start, end in sessions:
        current = {
            "label": label or "unlabeled",
            "overlap": overlap_seconds(historical, (start, end)),
            "separation": separation_seconds(historical, (start, end)),
            "start": start,
            "end": end,
        }
        if best is None or (
            current["overlap"],
            -current["separation"],
            current["end"],
        ) > (
            best["overlap"],
            -best["separation"],
            best["end"],
        ):
            best = current
    assert best is not None
    return {
        "saved_sessions": len(sessions),
        "saved_overlap_seconds": round(float(best["overlap"]), 1),
        "saved_best_label": best["label"],
        "saved_best_start_unix": round(float(best["start"]), 3),
        "saved_best_end_unix": round(float(best["end"]), 3),
        "saved_best_separation_seconds": round(float(best["separation"]), 1),
    }


def live_overlap_report_corrected(log: Path, corrected_offset: int | None) -> dict[str, Any]:
    historical_times = [frame_time_seconds(frame) for frame in extract_historical_frames(log)]
    historical_times = [
        (time + corrected_offset if corrected_offset is not None else time)
        for time in historical_times
        if time is not None and math.isfinite(time)
    ]
    realtime = extract_realtime_frames(log)
    realtime_unix = [frame.unix for frame in realtime if frame.unix is not None]
    realtime_rr_values = sum(len(frame.rr_values) for frame in realtime)
    if not historical_times or not realtime_unix:
        return {
            "historical_frames": len(historical_times),
            "realtime_frames": len(realtime),
            "realtime_rr_values": realtime_rr_values,
            "overlap": False,
        }
    hist_start = min(historical_times)
    hist_end = max(historical_times)
    rt_start = min(realtime_unix)
    rt_end = max(realtime_unix)
    overlap_start = max(hist_start, rt_start)
    overlap_end = min(hist_end, rt_end)
    overlap = max(0.0, overlap_end - overlap_start)
    if overlap > 0:
        separation = 0.0
    elif hist_end < rt_start:
        separation = rt_start - hist_end
    else:
        separation = hist_start - rt_end
    return {
        "historical_frames": len(historical_times),
        "historical_start_unix": round(hist_start, 3),
        "historical_end_unix": round(hist_end, 3),
        "historical_span_s": round(hist_end - hist_start, 1),
        "realtime_frames": len(realtime),
        "realtime_rr_values": realtime_rr_values,
        "realtime_start_unix": int(rt_start),
        "realtime_end_unix": int(rt_end),
        "realtime_span_s": int(rt_end - rt_start),
        "overlap": overlap > 0,
        "overlap_seconds": round(overlap, 1),
        "separation_seconds": round(separation, 1),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path, help="ATRIADBG live-device log")
    parser.add_argument(
        "--sessions-json",
        type=Path,
        help="Optional pulled Documents/sessions.json or backup envelope",
    )
    parser.add_argument(
        "--current-gap-hours",
        type=float,
        default=24.0,
        help="Maximum gap from the newest saved session to call history current",
    )
    args = parser.parse_args()

    clock = clock_report(args.log)
    corrected_offset = snapped_clock_offset(clock)
    start, end, codec = historical_range(args.log, corrected_offset=corrected_offset)
    frames = codec["codec_checked_frames"]
    codec_ok = codec["codec_ok_frames"]
    codec_clean = frames > 0 and codec_ok == frames
    print(f"historical_2f_frames={frames}")
    print(
        "historical_app_data_rows="
        f"{sum(1 for frame in extract_historical_frames(args.log) if frame.channel == 'historicalData')}"
    )
    for key, value in codec.items():
        print(f"{key}={value}")
    for key, value in clock.items():
        print(f"{key}={value}")
    print(f"clock_corrected_timeline={1 if corrected_offset not in (None, 0) else 0}")
    print(f"clock_snapped_offset_s={corrected_offset if corrected_offset is not None else 'missing'}")
    if start is None or end is None:
        print("historical_has_time_range=0")
        print("stored_transfer_verified=0")
        print("current_session_usable=0")
        print("metric_usable=0")
        print("reason=no_historical_time_range")
        return 0

    historical = (start, end)
    print("historical_has_time_range=1")
    print(f"historical_start_unix={round(start, 3)}")
    print(f"historical_end_unix={round(end, 3)}")
    print(f"historical_start_iso={iso(start)}")
    print(f"historical_end_iso={iso(end)}")
    print(f"historical_span_s={round(end - start, 1)}")

    live_report = live_overlap_report_corrected(args.log, corrected_offset)
    live_overlap = bool(live_report.get("overlap"))
    print(f"live_history_overlap={int(live_overlap)}")
    if "overlap_seconds" in live_report:
        print(f"live_overlap_seconds={live_report['overlap_seconds']}")
    if "separation_seconds" in live_report:
        print(f"live_history_separation_seconds={live_report['separation_seconds']}")

    sessions = session_ranges(args.sessions_json)
    saved = best_session_overlap(historical, sessions)
    for key, value in saved.items():
        print(f"{key}={value}")

    saved_overlap = float(saved["saved_overlap_seconds"])
    saved_current = False
    newest_gap: float | None = None
    if sessions:
        newest_end = max(row[2] for row in sessions)
        newest_gap = separation_seconds(historical, (newest_end, newest_end))
        saved_current = newest_gap <= args.current_gap_hours * 3600
        print(f"newest_saved_end_unix={round(newest_end, 3)}")
        print(f"newest_saved_end_iso={iso(newest_end)}")
        print(f"historical_to_newest_saved_gap_s={round(newest_gap, 1)}")
        print(f"current_gap_threshold_s={round(args.current_gap_hours * 3600, 1)}")

    stored_transfer_verified = codec_clean
    current_session_usable = stored_transfer_verified and (live_overlap or saved_overlap > 0)
    recent_but_not_overlapping = stored_transfer_verified and saved_current and saved_overlap == 0 and not live_overlap
    print(f"stored_transfer_verified={int(stored_transfer_verified)}")
    print(f"current_session_usable={int(current_session_usable)}")
    print("rr_layout_validated=0")
    print("external_rr_reference_validated=0")
    print("metric_usable=0")

    if not stored_transfer_verified:
        reason = "codec_validation_failed"
    elif current_session_usable:
        reason = "range_overlaps_local_evidence_but_rr_layout_and_external_reference_still_required"
    elif recent_but_not_overlapping:
        reason = "historical_near_saved_history_but_no_overlap"
    elif sessions:
        reason = "historical_old_or_nonoverlapping_saved_sessions"
    elif live_report.get("realtime_frames", 0):
        reason = "historical_old_or_nonoverlapping_live_realtime"
    else:
        reason = "stored_transfer_verified_without_local_overlap_context"
    print(f"reason={reason}")
    print("warning=do_not_feed_hrv_recovery_sleep_workout_trends_healthkit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
