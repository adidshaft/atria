#!/usr/bin/env python3
"""Summarize CRC-valid R10 sample coverage for explicitly supplied windows.

This tool is read-only and does not run the step detector or suggest constants.
Rows copied across multiple device pulls are deduplicated before accounting.
"""

from __future__ import annotations

import argparse
import csv
import zlib
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo


R10_MINIMUM_PAYLOAD_BYTES = 1_288
R10_SAMPLE_COUNT = 100
R10_SAMPLE_RATE_HZ = 100


@dataclass(frozen=True)
class ArchiveRow:
    received_ms: int
    raw_hex: str


@dataclass(frozen=True)
class DecodedFrame:
    received_ms: int
    device_timestamp: int
    raw_hex: str


@dataclass(frozen=True)
class Window:
    label: str
    start_ms: int
    end_ms: int
    expected_steps: int | None = None
    timing_precision: str = "unknown"

    @property
    def duration_s(self) -> float:
        return (self.end_ms - self.start_ms) / 1000


def crc8(data: bytes, poly: int = 0x07) -> int:
    value = 0
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = ((value << 1) ^ poly) & 0xFF if value & 0x80 else (value << 1) & 0xFF
    return value


def decode_r10(received_ms: int, raw_hex: str) -> DecodedFrame | None:
    try:
        raw = bytes.fromhex(raw_hex)
    except ValueError:
        return None
    if len(raw) < 9 or raw[0] != 0xAA:
        return None
    declared = int.from_bytes(raw[1:3], "little")
    total_length = declared + 4
    if declared < 5 or total_length > len(raw) or raw[3] != crc8(raw[1:3]):
        return None
    payload = raw[4:declared]
    if len(payload) < R10_MINIMUM_PAYLOAD_BYTES or payload[:2] != b"\x2b\x0a":
        return None
    expected_crc = int.from_bytes(raw[declared : declared + 4], "little")
    if zlib.crc32(payload) & 0xFFFFFFFF != expected_crc:
        return None
    return DecodedFrame(
        received_ms=received_ms,
        device_timestamp=int.from_bytes(payload[7:11], "little"),
        raw_hex=raw[:total_length].hex(),
    )


def load_rows(root: Path) -> tuple[list[ArchiveRow], int, int]:
    paths = [root] if root.is_file() else sorted(root.rglob("*.csv"))
    unique: dict[tuple[int, str], ArchiveRow] = {}
    parsed_rows = 0
    for path in paths:
        try:
            handle = path.open(newline="", encoding="utf-8")
        except OSError:
            continue
        with handle:
            reader = csv.DictReader(handle)
            required = {"received_at_unix_ms", "raw_frame_hex"}
            if not required.issubset(reader.fieldnames or []):
                continue
            for row in reader:
                try:
                    received_ms = int(row["received_at_unix_ms"])
                except (KeyError, TypeError, ValueError):
                    continue
                raw_hex = (row.get("raw_frame_hex") or "").strip().lower()
                parsed_rows += 1
                unique[(received_ms, raw_hex)] = ArchiveRow(received_ms, raw_hex)
    rows = sorted(unique.values(), key=lambda row: row.received_ms)
    return rows, parsed_rows, parsed_rows - len(rows)


def decoded_unique_frames(rows: list[ArchiveRow]) -> tuple[list[DecodedFrame], int]:
    decoded = [frame for row in rows if (frame := decode_r10(row.received_ms, row.raw_hex))]
    unique: dict[tuple[str, int | str], DecodedFrame] = {}
    for frame in decoded:
        # Mirrors production: a nonzero device timestamp identifies a duplicate.
        key = ("timestamp", frame.device_timestamp) if frame.device_timestamp else ("raw", frame.raw_hex)
        unique.setdefault(key, frame)
    return sorted(unique.values(), key=lambda frame: frame.received_ms), len(decoded) - len(unique)


def parse_time(value: str, timezone: ZoneInfo) -> int:
    stripped = value.strip()
    if stripped.isdigit():
        return int(stripped)
    parsed = datetime.fromisoformat(stripped.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone)
    return round(parsed.timestamp() * 1000)


def parse_window(value: str, timezone: ZoneInfo) -> Window:
    columns = [column.strip() for column in value.split(",")]
    if len(columns) < 3 or len(columns) > 5:
        raise ValueError("window must be label,start,end[,expected_steps[,timing_precision]]")
    expected = None
    if len(columns) >= 4 and columns[3]:
        expected = int(columns[3])
        if expected < 0:
            raise ValueError("expected_steps must be nonnegative")
    precision = columns[4].lower() if len(columns) == 5 and columns[4] else "unknown"
    if precision not in {"second", "minute", "unknown"}:
        raise ValueError("timing_precision must be second, minute, or unknown")
    window = Window(columns[0], parse_time(columns[1], timezone), parse_time(columns[2], timezone), expected, precision)
    if not window.label or window.end_ms <= window.start_ms:
        raise ValueError("window label must be nonempty and end must follow start")
    return window


def overlaps(window: Window, others: list[Window]) -> bool:
    return any(
        other is not window
        and window.start_ms < other.end_ms
        and other.start_ms < window.end_ms
        for other in others
    )


def summarize_window(window: Window, frames: list[DecodedFrame], windows: list[Window]) -> dict[str, str]:
    selected = [
        frame for frame in frames
        if window.start_ms <= frame.device_timestamp * 1000 < window.end_ms
    ]
    selected.sort(key=lambda frame: (frame.device_timestamp, frame.received_ms))
    frame_count = len(selected)
    samples = frame_count * R10_SAMPLE_COUNT
    sample_seconds = samples / R10_SAMPLE_RATE_HZ
    sample_coverage = min(100.0, 100 * sample_seconds / window.duration_s)
    received = [frame.received_ms for frame in selected]
    device_ms = [frame.device_timestamp * 1000 for frame in selected]
    receive_gaps = [(b - a) / 1000 for a, b in zip(received, received[1:])]
    uncovered_device_gaps = [
        max(0.0, (b - a) / 1000 - 1.0)
        for a, b in zip(device_ms, device_ms[1:])
    ]
    boundary_gaps = (
        [
            max(0.0, (device_ms[0] - window.start_ms) / 1000),
            max(0.0, (window.end_ms - (device_ms[-1] + 1_000)) / 1000),
        ]
        if device_ms else [window.duration_s]
    )
    max_device_gap = max(uncovered_device_gaps + boundary_gaps)
    segment_lengths: list[int] = []
    if selected:
        current_length = 1
        for previous, current in zip(selected, selected[1:]):
            if current.device_timestamp == previous.device_timestamp + 1:
                current_length += 1
            else:
                segment_lengths.append(current_length)
                current_length = 1
        segment_lengths.append(current_length)
    continuity_breaks = max(0, len(segment_lengths) - 1)
    longest_segment_frames = max(segment_lengths, default=0)
    longest_segment_coverage = min(
        100.0,
        100 * longest_segment_frames * R10_SAMPLE_COUNT / R10_SAMPLE_RATE_HZ / window.duration_s,
    )
    has_overlap = overlaps(window, windows)
    reasons: list[str] = []
    if window.expected_steps is None:
        reasons.append("missing_counted_steps")
    if window.timing_precision != "second":
        reasons.append("timing_not_second_precision")
    if has_overlap:
        reasons.append("overlaps_supplied_window")
    if sample_coverage < 95:
        reasons.append("sample_coverage_below_95_percent")
    if max_device_gap > 0:
        reasons.append("uncovered_device_sample_time")
    if continuity_breaks:
        reasons.append("device_timestamp_discontinuity")
    return {
        "label": window.label,
        "start_ms": str(window.start_ms),
        "end_ms_exclusive": str(window.end_ms),
        "duration_s": f"{window.duration_s:.3f}",
        "expected_steps": str(window.expected_steps) if window.expected_steps is not None else "none",
        "timing_precision": window.timing_precision,
        "decoded_unique_frames": str(frame_count),
        "decoded_samples": str(samples),
        "sample_payload_seconds": f"{sample_seconds:.3f}",
        "sample_coverage_percent": f"{sample_coverage:.3f}",
        "first_device_timestamp": str(selected[0].device_timestamp) if selected else "none",
        "last_device_timestamp": str(selected[-1].device_timestamp) if selected else "none",
        "first_received_ms": str(received[0]) if received else "none",
        "last_received_ms": str(received[-1]) if received else "none",
        "max_uncovered_device_sample_gap_s": f"{max_device_gap:.3f}",
        "max_receive_gap_s": f"{max(receive_gaps, default=0.0):.3f}",
        "min_receive_lag_s": (
            f"{min((frame.received_ms - frame.device_timestamp * 1000) / 1000 for frame in selected):.3f}"
            if selected else "none"
        ),
        "max_receive_lag_s": (
            f"{max((frame.received_ms - frame.device_timestamp * 1000) / 1000 for frame in selected):.3f}"
            if selected else "none"
        ),
        "device_contiguous_segments": str(len(segment_lengths)),
        "device_timestamp_continuity_breaks": str(continuity_breaks),
        "longest_contiguous_frames": str(longest_segment_frames),
        "longest_contiguous_samples": str(longest_segment_frames * R10_SAMPLE_COUNT),
        "longest_contiguous_coverage_percent": f"{longest_segment_coverage:.3f}",
        "overlaps_supplied_window": str(int(has_overlap)),
        "step_calibration_ready": str(int(not reasons)),
        "reason": ";".join(reasons) if reasons else "ready",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--timezone", default="Asia/Kolkata")
    parser.add_argument(
        "--window",
        action="append",
        default=[],
        help="label,start,end[,expected_steps[,timing_precision]]; end is exclusive",
    )
    args = parser.parse_args()
    try:
        timezone = ZoneInfo(args.timezone)
        windows = [parse_window(value, timezone) for value in args.window]
        rows, parsed_rows, copied_rows = load_rows(args.archive)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    frames, duplicate_device_frames = decoded_unique_frames(rows)
    print(f"csv_rows_parsed={parsed_rows}")
    print(f"copied_rows_deduplicated={copied_rows}")
    print(f"unique_archive_rows={len(rows)}")
    print(f"crc_valid_decoded_r10_rows={len(frames) + duplicate_device_frames}")
    print(f"duplicate_device_frames_deduplicated={duplicate_device_frames}")
    print(f"decoded_unique_frames={len(frames)}")
    print(f"decoded_unique_samples={len(frames) * R10_SAMPLE_COUNT}")
    if frames:
        print(f"first_decoded_received_ms={frames[0].received_ms}")
        print(f"last_decoded_received_ms={frames[-1].received_ms}")
    for index, window in enumerate(windows, start=1):
        summary = summarize_window(window, frames, windows)
        for key, value in summary.items():
            print(f"window_{index}_{key}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
