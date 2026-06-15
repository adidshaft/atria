#!/usr/bin/env python3
"""Summarize the app's local historical JSONL archive."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any
import datetime as dt
import math
import struct

APPLE_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)


def parse_kv_file(path: Path) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for line in path.read_text(errors="replace").splitlines():
        if not line.strip() or "=" not in line:
            continue
        key, value = line.split("=", 1)
        parsed[key.strip()] = value.strip()
    return parsed


def parse_int(value: str | None, default: int = 0) -> int:
    if value is None:
        return default
    try:
        return int(value)
    except ValueError:
        return default


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


def best_session_overlap(
    historical: tuple[float, float],
    sessions: list[tuple[str, float, float]],
) -> dict[str, Any]:
    if not sessions:
        return {
            "saved_sessions": 0,
            "saved_overlap_seconds": 0.0,
            "saved_best_label": "none",
            "saved_best_separation_seconds": "none",
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
        "saved_best_start_iso": iso(float(best["start"])),
        "saved_best_end_unix": round(float(best["end"]), 3),
        "saved_best_end_iso": iso(float(best["end"])),
        "saved_best_separation_seconds": round(float(best["separation"]), 1),
    }


def decode_historical_gravity(payload_hex: str) -> tuple[float, float, float, float, bool] | None:
    try:
        payload = bytes.fromhex(payload_hex)
    except (TypeError, ValueError):
        return None
    if len(payload) < 2:
        return None
    version = payload[1]
    if version == 25:
        if len(payload) < 75:
            return None
        x_raw, y_raw, z_raw = struct.unpack_from("<hhh", payload, 69)
        x, y, z = x_raw / 16384.0, y_raw / 16384.0, z_raw / 16384.0
    else:
        if len(payload) < 48:
            return None
        x, y, z = struct.unpack_from("<fff", payload, 36)
    magnitude = math.sqrt(x * x + y * y + z * z)
    return x, y, z, magnitude, 0.8 <= magnitude <= 1.2


def load_rows(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(errors="replace").splitlines(), start=1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"{path}:{line_number}: invalid JSONL row: {exc}") from exc
        rows.append(row)
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument(
        "--usability",
        type=Path,
        help="Optional tools/analyze_historical_usability.py output for codec/overlap evidence.",
    )
    parser.add_argument(
        "--sessions-json",
        type=Path,
        help="Optional pulled Documents/sessions.json or backup envelope for archive/session overlap evidence.",
    )
    args = parser.parse_args()

    rows = load_rows(args.archive)
    if not rows:
        print("rows=0")
        print("ready=0 reason=empty_archive")
        return 0

    schemas = sorted({str(row.get("schema", "missing")) for row in rows})
    layouts = sorted({str(row.get("layoutVersion", "undecodable")) for row in rows})
    metric_usable = sum(1 for row in rows if row.get("metricUsable") is True)
    current_usable = sum(1 for row in rows if row.get("currentSessionUsable") is True)
    undecodable = sum(1 for row in rows if row.get("source") == "0x2f" and "layoutVersion" not in row)
    unix_values = [int(row["unix7"]) for row in rows if isinstance(row.get("unix7"), int) and int(row["unix7"]) > 0]
    whoof_rr_values = sum(len(row.get("whoofRR19") or []) for row in rows)
    k_rr_values = sum(len(row.get("kRR64") or []) for row in rows)
    candidate_rr_values = sum(len(row.get("candidateRR") or []) for row in rows)
    payload_lengths = sorted({int(row.get("payloadLength", 0)) for row in rows})
    raw_payloads = sum(1 for row in rows if isinstance(row.get("rawPayloadHex"), str) and row["rawPayloadHex"])
    clock_rows = [row for row in rows if row.get("clockCorrectionStatus")]
    corrected_values = [
        int(row["clockCorrectedUnix7"])
        for row in rows
        if isinstance(row.get("clockCorrectedUnix7"), int) and int(row["clockCorrectedUnix7"]) > 0
    ]
    clock_statuses = sorted({str(row.get("clockCorrectionStatus")) for row in clock_rows})
    clock_offsets = [
        int(row["clockDriftSeconds"])
        for row in rows
        if isinstance(row.get("clockDriftSeconds"), int)
    ]
    gravity = [
        decode_historical_gravity(row.get("rawPayloadHex", ""))
        for row in rows
        if isinstance(row.get("rawPayloadHex"), str)
    ]
    gravity = [item for item in gravity if item is not None]
    gravity_validated = [item for item in gravity if item[4]]
    hist_versions = sorted({
        int(bytes.fromhex(row["rawPayloadHex"])[1])
        for row in rows
        if isinstance(row.get("rawPayloadHex"), str)
        and len(row["rawPayloadHex"]) >= 4
    })

    print(f"rows={len(rows)}")
    print(f"schemas={','.join(schemas)}")
    print(f"layouts={','.join(layouts)}")
    print(f"payload_lengths={','.join(map(str, payload_lengths))}")
    print(f"raw_payload_rows={raw_payloads}")
    print(f"undecodable_rows={undecodable}")
    print(f"metric_usable_rows={metric_usable}")
    print(f"current_session_usable_rows={current_usable}")
    print(f"whoof_rr_values={whoof_rr_values}")
    print(f"k_rr_values={k_rr_values}")
    print(f"candidate_rr_values={candidate_rr_values}")
    print(f"hist_versions={','.join(map(str, hist_versions)) if hist_versions else 'none'}")
    print(f"noop_historical_gravity_rows={len(gravity)}")
    print(f"noop_historical_gravity_validated_rows={len(gravity_validated)}")
    if gravity:
        magnitudes = [item[3] for item in gravity]
        print(f"noop_historical_gravity_validated_percent={round(len(gravity_validated) / len(gravity) * 100)}")
        print(f"noop_historical_gravity_mag_min={min(magnitudes):.3f}")
        print(f"noop_historical_gravity_mag_max={max(magnitudes):.3f}")
    if unix_values:
        print(f"unix_first={min(unix_values)}")
        print(f"unix_last={max(unix_values)}")
    print(f"clock_correlation_rows={len(clock_rows)}")
    print(f"clock_correlation_statuses={','.join(clock_statuses) if clock_statuses else 'none'}")
    if clock_offsets:
        print(f"clock_offset_s={clock_offsets[-1]}")
    if corrected_values:
        print(f"clock_corrected_unix_first={min(corrected_values)}")
        print(f"clock_corrected_unix_last={max(corrected_values)}")
    if args.sessions_json:
        archive_range_values = corrected_values or unix_values
        sessions = session_ranges(args.sessions_json)
        print(f"archive_overlap_basis={'clock_corrected' if corrected_values else 'raw_unix7'}")
        if archive_range_values:
            archive_start = float(min(archive_range_values))
            archive_end = float(max(archive_range_values))
            print(f"archive_overlap_start_unix={round(archive_start, 3)}")
            print(f"archive_overlap_end_unix={round(archive_end, 3)}")
            print(f"archive_overlap_start_iso={iso(archive_start)}")
            print(f"archive_overlap_end_iso={iso(archive_end)}")
            saved = best_session_overlap((archive_start, archive_end), sessions)
            for key, value in saved.items():
                print(f"{key}={value}")
            current_overlap = float(saved["saved_overlap_seconds"]) > 0
            print(f"archive_current_session_overlap={1 if current_overlap else 0}")
            print(f"archive_current_session_ready={1 if current_overlap and current_usable > 0 else 0}")
            if current_overlap and current_usable == 0:
                print("archive_overlap_reason=overlaps_saved_session_but_rows_fail_closed")
            elif current_overlap:
                print("archive_overlap_reason=overlaps_saved_session")
            elif sessions:
                print("archive_overlap_reason=archive_old_or_nonoverlapping_saved_sessions")
            else:
                print("archive_overlap_reason=no_saved_sessions")
        else:
            print(f"saved_sessions={len(sessions)}")
            print("archive_current_session_overlap=0")
            print("archive_current_session_ready=0")
            print("archive_overlap_reason=no_archive_time_range")
    archive_persisted = raw_payloads == len(rows)
    print(f"archive_persisted={1 if archive_persisted else 0}")
    print(f"metric_ready={1 if metric_usable > 0 else 0}")
    print(f"current_session_ready={1 if current_usable > 0 else 0}")
    if args.usability:
        usability = parse_kv_file(args.usability)
        stored_transfer_verified = usability.get("stored_transfer_verified") == "1"
        codec_ok = parse_int(usability.get("codec_ok_frames"))
        codec_bad = parse_int(usability.get("codec_bad_frames"), default=-1)
        current_session_usable = usability.get("current_session_usable") == "1"
        metric_usable = usability.get("metric_usable") == "1"
        codec_clean = codec_ok > 0 and codec_bad == 0
        gate_h_protocol_exit_ready = archive_persisted and stored_transfer_verified and codec_clean
        print(f"stored_transfer_verified={1 if stored_transfer_verified else 0}")
        print(f"codec_ok_frames={codec_ok}")
        print(f"codec_bad_frames={codec_bad}")
        if "clock_correlation_present" in usability:
            print(f"clock_correlation_present={usability.get('clock_correlation_present')}")
            print(f"clock_stale_history_policy={usability.get('clock_stale_history_policy', 'missing')}")
        print(f"gate_h_protocol_exit_ready={1 if gate_h_protocol_exit_ready else 0}")
        print(f"gate_h_current_session_metric_ready={1 if current_session_usable and metric_usable else 0}")
        print(f"gate_h_reason={usability.get('reason', 'missing_usability_reason')}")
    print("ready=0")
    print("interpretation=archive_persisted_fail_closed_rows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
