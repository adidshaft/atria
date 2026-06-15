#!/usr/bin/env python3
"""Analyze WHOOP 0x2f historical frames captured in WHOOPDBG logs.

This is an evidence tool, not a production decoder. It finds fixed payload
offsets that look like RR/IBI u16 little-endian values and evaluates explicit
offset sets with the Gate B artifact rules. Do not use its output as HRV until
the frame layout is externally validated.
"""

from __future__ import annotations

import argparse
import csv
import os
import sys
import math
import re
import statistics
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from whoop_codec import decode as decode_whoop_frame  # noqa: E402


FRAME_RE = re.compile(r"frame ch=(6108000[3457]) len=(\d+) hex=([0-9a-fA-F]+)")
REALTIME_RE = re.compile(r"realtimeFrame .*payload=([0-9a-fA-F]+)")


@dataclass
class OffsetStats:
    offset: int
    fraction: float
    mean: float
    stdev: float
    min_value: int
    max_value: int


def u16le(payload: bytes, offset: int) -> int:
    return payload[offset] | (payload[offset + 1] << 8)


@dataclass
class HistoricalFrame:
    channel: str
    declared_len: int
    payload: bytes
    raw: bytes
    codec_ok: bool

    @property
    def seq(self) -> int | None:
        return self.payload[1] if len(self.payload) > 1 else None

    @property
    def cmd(self) -> int | None:
        return self.payload[2] if len(self.payload) > 2 else None

    @property
    def body(self) -> bytes:
        return self.payload[3:]


@dataclass
class RealtimeFrame:
    payload: bytes

    @property
    def unix(self) -> int | None:
        if len(self.payload) < 6:
            return None
        return int.from_bytes(self.payload[2:6], "little")

    @property
    def hr(self) -> int | None:
        return self.payload[8] if len(self.payload) > 8 else None

    @property
    def rrnum(self) -> int:
        return self.payload[9] if len(self.payload) > 9 else 0

    @property
    def rr_values(self) -> list[int]:
        values: list[int] = []
        for index in range(self.rrnum):
            offset = 10 + index * 2
            if offset + 1 >= len(self.payload):
                break
            value = u16le(self.payload, offset)
            if 300 <= value <= 2000:
                values.append(value)
        return values


def extract_frames(path: Path) -> list[HistoricalFrame]:
    frames: list[HistoricalFrame] = []
    for line in path.read_text(errors="ignore").splitlines():
        match = FRAME_RE.search(line)
        if not match:
            continue
        channel = match.group(1)
        declared_len = int(match.group(2))
        raw = bytes.fromhex(match.group(3))
        if len(raw) < 8:
            continue
        decoded_payload, codec_ok = decode_whoop_frame(raw)
        payload = decoded_payload if codec_ok else raw[4:-4]
        if payload[:1] == b"\x2f":
            frames.append(HistoricalFrame(channel, declared_len, payload, raw, codec_ok))
    return frames


def codec_summary(frames: list[HistoricalFrame]) -> dict[str, int]:
    return {
        "codec_checked_frames": len(frames),
        "codec_ok_frames": sum(1 for frame in frames if frame.codec_ok),
        "codec_bad_frames": sum(1 for frame in frames if not frame.codec_ok),
        "declared_len_mismatches": sum(
            1 for frame in frames if frame.declared_len != len(frame.raw)
        ),
    }


def print_codec_summary(frames: list[HistoricalFrame]) -> None:
    for key, value in codec_summary(frames).items():
        print(f"{key}={value}")


def extract_realtime_frames(path: Path) -> list[RealtimeFrame]:
    frames: list[RealtimeFrame] = []
    for line in path.read_text(errors="ignore").splitlines():
        match = REALTIME_RE.search(line)
        if not match:
            continue
        payload = bytes.fromhex(match.group(1))
        if payload[:1] == b"\x28":
            frames.append(RealtimeFrame(payload))
    return frames


def plausible_offsets(frames: list[HistoricalFrame]) -> list[OffsetStats]:
    if not frames:
        return []
    payloads = [frame.payload for frame in frames]
    limit = min(len(payload) for payload in payloads) - 1
    stats: list[OffsetStats] = []
    for offset in range(limit):
        values = [u16le(payload, offset) for payload in payloads]
        plausible = [value for value in values if 300 <= value <= 2000]
        fraction = len(plausible) / len(values)
        if fraction >= 0.50:
            stats.append(
                OffsetStats(
                    offset=offset,
                    fraction=fraction,
                    mean=statistics.mean(plausible),
                    stdev=statistics.pstdev(plausible),
                    min_value=min(plausible),
                    max_value=max(plausible),
                )
            )
    return stats


def rmssd(values: list[int]) -> float:
    diffs = [b - a for a, b in zip(values, values[1:])]
    if not diffs:
        return math.nan
    return math.sqrt(sum(diff * diff for diff in diffs) / len(diffs))


def evaluate_offsets(frames: list[HistoricalFrame], offsets: list[int]) -> dict[str, float | int]:
    raw: list[int] = []
    for frame in frames:
        payload = frame.payload
        for offset in offsets:
            if offset + 1 < len(payload):
                raw.append(u16le(payload, offset))

    in_range = [value for value in raw if 300 <= value <= 2000]
    kept: list[int] = []
    rejected_delta = 0
    previous: int | None = None
    for value in in_range:
        if previous is not None and abs(value - previous) / previous > 0.20:
            rejected_delta += 1
            continue
        kept.append(value)
        previous = value

    return {
        "raw": len(raw),
        "in_range": len(in_range),
        "kept": len(kept),
        "rejected_out_of_range": len(raw) - len(in_range),
        "rejected_delta_over_20_percent": rejected_delta,
        "confidence_percent": round((len(kept) / len(raw)) * 100) if raw else 0,
        "mean_rr_ms": round(statistics.mean(kept), 1) if kept else math.nan,
        "implied_bpm": round(60000 / statistics.mean(kept), 1) if kept else math.nan,
        "rmssd_ms": round(rmssd(kept), 1) if len(kept) > 1 else math.nan,
    }


@dataclass
class TimedRR:
    t: float
    ms: int


def frame_time_seconds(frame: HistoricalFrame) -> float | None:
    payload = frame.payload
    if len(payload) < 13:
        return None
    unix = int.from_bytes(payload[7:11], "little")
    subsec = u16le(payload, 11)
    # WHOOP stores a 15-bit-ish subsecond counter in observed frames.
    return unix + (subsec / 32768.0)


def reconstruct_timed_rr(frames: list[HistoricalFrame], offsets: list[int]) -> list[TimedRR]:
    samples: list[TimedRR] = []
    for frame in frames:
        end_time = frame_time_seconds(frame)
        if end_time is None:
            continue
        values: list[int] = []
        for offset in offsets:
            if offset + 1 < len(frame.payload):
                value = u16le(frame.payload, offset)
                if 300 <= value <= 2000:
                    values.append(value)
        if not values:
            continue
        cursor = end_time
        frame_samples: list[TimedRR] = []
        for value in reversed(values):
            frame_samples.append(TimedRR(t=cursor, ms=value))
            cursor -= value / 1000.0
        samples.extend(reversed(frame_samples))
    return sorted(samples, key=lambda sample: sample.t)


def reconstruct_live_timed_rr(realtime: list[RealtimeFrame]) -> list[TimedRR]:
    """Reconstruct live RR samples from realtime frames in strap time.

    This is layout-validation evidence only. It uses real RR/IBI values carried
    by live 0x28 frames and never derives RR from HR-only frames.
    """
    samples: list[TimedRR] = []
    for frame in realtime:
        end_time = frame.unix
        if end_time is None:
            continue
        values = frame.rr_values
        if not values:
            continue
        cursor = float(end_time)
        frame_samples: list[TimedRR] = []
        for value in reversed(values):
            frame_samples.append(TimedRR(t=cursor, ms=value))
            cursor -= value / 1000.0
        samples.extend(reversed(frame_samples))
    return sorted(samples, key=lambda sample: sample.t)


def sample_range(samples: list[TimedRR]) -> tuple[float, float] | None:
    if not samples:
        return None
    return (samples[0].t, samples[-1].t)


def overlap_range(lhs: list[TimedRR], rhs: list[TimedRR]) -> tuple[float, float, float]:
    lhs_range = sample_range(lhs)
    rhs_range = sample_range(rhs)
    if lhs_range is None or rhs_range is None:
        return (0.0, 0.0, 0.0)
    start = max(lhs_range[0], rhs_range[0])
    end = min(lhs_range[1], rhs_range[1])
    return (start, end, max(0.0, end - start))


def corrected_window(values: list[TimedRR]) -> dict[str, float | int | bool]:
    kept: list[int] = []
    rejected_delta = 0
    previous: int | None = None
    for sample in values:
        value = sample.ms
        if not 300 <= value <= 2000:
            continue
        if previous is not None and abs(value - previous) / previous > 0.20:
            rejected_delta += 1
            continue
        kept.append(value)
        previous = value
    gaps = [b.t - a.t for a, b in zip(values, values[1:])]
    max_gap = max(gaps) if gaps else math.inf
    confidence = round((len(kept) / len(values)) * 100) if values else 0
    duration_s = values[-1].t - values[0].t if len(values) > 1 else 0
    rr_sum_s = sum(kept) / 1000.0
    duration_ratio = rr_sum_s / duration_s if duration_s > 0 else math.inf
    duration_consistent = 0.75 <= duration_ratio <= 1.25
    return {
        "raw": len(values),
        "kept": len(kept),
        "rejected_delta_over_20_percent": rejected_delta,
        "confidence_percent": confidence,
        "max_rr_gap_s": round(max_gap, 3) if math.isfinite(max_gap) else math.inf,
        "rr_sum_s": round(rr_sum_s, 1),
        "duration_ratio": round(duration_ratio, 2) if math.isfinite(duration_ratio) else math.inf,
        "duration_consistent": duration_consistent,
        "rmssd_ms": round(rmssd(kept), 1) if len(kept) > 1 else math.nan,
        "ready": len(kept) >= 240 and confidence >= 75 and max_gap <= 3.0 and duration_consistent,
    }


def best_windows(frames: list[HistoricalFrame], offsets: list[int], seconds: float) -> list[dict[str, float | int | bool]]:
    samples = reconstruct_timed_rr(frames, offsets)
    windows: list[dict[str, float | int | bool]] = []
    left = 0
    for right, sample in enumerate(samples):
        while sample.t - samples[left].t > seconds:
            left += 1
        window_samples = samples[left : right + 1]
        if len(window_samples) < 2:
            continue
        result = corrected_window(window_samples)
        result["start_unix"] = round(window_samples[0].t, 3)
        result["end_unix"] = round(window_samples[-1].t, 3)
        result["duration_s"] = round(window_samples[-1].t - window_samples[0].t, 1)
        windows.append(result)
    return sorted(
        windows,
        key=lambda item: (
            bool(item["ready"]),
            int(item["kept"]),
            -float(item["max_rr_gap_s"]) if math.isfinite(float(item["max_rr_gap_s"])) else -9999,
            int(item["confidence_percent"]),
        ),
        reverse=True,
    )


def score_hr_agreement(frames: list[HistoricalFrame], offsets: list[int], hr_offset: int) -> list[dict[str, float | int]]:
    scores: list[dict[str, float | int]] = []
    for offset in offsets:
        rows: list[tuple[int, int, float]] = []
        for frame in frames:
            payload = frame.payload
            if hr_offset >= len(payload) or offset + 1 >= len(payload):
                continue
            hr = payload[hr_offset]
            rr = u16le(payload, offset)
            if not 35 <= hr <= 220 or not 300 <= rr <= 2000:
                continue
            implied = 60000 / rr
            rows.append((hr, rr, abs(implied - hr)))
        if not rows:
            scores.append({
                "offset": offset,
                "samples": 0,
                "mean_hr": math.nan,
                "mean_rr": math.nan,
                "mean_implied_bpm": math.nan,
                "mae_bpm": math.nan,
                "median_abs_error_bpm": math.nan,
                "within_5_bpm_percent": 0,
                "within_10_bpm_percent": 0,
            })
            continue
        errors = [row[2] for row in rows]
        hrs = [row[0] for row in rows]
        rrs = [row[1] for row in rows]
        implied_bpms = [60000 / rr for rr in rrs]
        scores.append({
            "offset": offset,
            "samples": len(rows),
            "mean_hr": round(statistics.mean(hrs), 1),
            "mean_rr": round(statistics.mean(rrs), 1),
            "mean_implied_bpm": round(statistics.mean(implied_bpms), 1),
            "mae_bpm": round(statistics.mean(errors), 2),
            "median_abs_error_bpm": round(statistics.median(errors), 2),
            "within_5_bpm_percent": round((sum(1 for error in errors if error <= 5) / len(errors)) * 100),
            "within_10_bpm_percent": round((sum(1 for error in errors if error <= 10) / len(errors)) * 100),
        })
    return sorted(
        scores,
        key=lambda score: (
            int(score["samples"]),
            -float(score["mae_bpm"]) if math.isfinite(float(score["mae_bpm"])) else -9999,
            int(score["within_5_bpm_percent"]),
        ),
        reverse=True,
    )


def whoof_rr_values(frame: HistoricalFrame, max_rr: int = 4) -> list[int]:
    payload = frame.payload
    if len(payload) <= 19:
        return []
    rrnum = min(payload[18], max_rr)
    values: list[int] = []
    for index in range(rrnum):
        offset = 19 + index * 2
        if offset + 1 >= len(payload):
            break
        value = u16le(payload, offset)
        if 300 <= value <= 2000:
            values.append(value)
    return values


def reconstruct_whoof_timed_rr(frames: list[HistoricalFrame]) -> list[TimedRR]:
    samples: list[TimedRR] = []
    for frame in frames:
        end_time = frame_time_seconds(frame)
        if end_time is None:
            continue
        values = whoof_rr_values(frame)
        if not values:
            continue
        cursor = end_time
        frame_samples: list[TimedRR] = []
        for value in reversed(values):
            frame_samples.append(TimedRR(t=cursor, ms=value))
            cursor -= value / 1000.0
        samples.extend(reversed(frame_samples))
    return sorted(samples, key=lambda sample: sample.t)


def best_windows_from_samples(samples: list[TimedRR], seconds: float) -> list[dict[str, float | int | bool]]:
    windows: list[dict[str, float | int | bool]] = []
    left = 0
    for right, sample in enumerate(samples):
        while sample.t - samples[left].t > seconds:
            left += 1
        window_samples = samples[left : right + 1]
        if len(window_samples) < 2:
            continue
        result = corrected_window(window_samples)
        result["start_unix"] = round(window_samples[0].t, 3)
        result["end_unix"] = round(window_samples[-1].t, 3)
        result["duration_s"] = round(window_samples[-1].t - window_samples[0].t, 1)
        windows.append(result)
    return sorted(
        windows,
        key=lambda item: (
            bool(item["ready"]),
            int(item["kept"]),
            -float(item["max_rr_gap_s"]) if math.isfinite(float(item["max_rr_gap_s"])) else -9999,
            int(item["confidence_percent"]),
        ),
        reverse=True,
    )


def samples_in_range(samples: list[TimedRR], start: float, end: float) -> list[TimedRR]:
    return [sample for sample in samples if start <= sample.t <= end]


def validate_against_live_rr(
    historical_samples: list[TimedRR],
    live_samples: list[TimedRR],
    window_seconds: float,
    tolerance_ms: float,
) -> dict[str, object]:
    overlap_start, overlap_end, overlap_seconds = overlap_range(historical_samples, live_samples)
    if overlap_seconds <= 0:
        hist_range = sample_range(historical_samples)
        live_range = sample_range(live_samples)
        separation: float | None = None
        if hist_range is not None and live_range is not None:
            if hist_range[1] < live_range[0]:
                separation = live_range[0] - hist_range[1]
            elif live_range[1] < hist_range[0]:
                separation = hist_range[0] - live_range[1]
        return {
            "historical_rr_values": len(historical_samples),
            "live_rr_values": len(live_samples),
            "overlap": False,
            "overlap_seconds": 0.0,
            "separation_seconds": None if separation is None else round(separation, 1),
            "compared_windows": 0,
            "matching_windows": 0,
            "layout_live_validated": False,
            "best_delta_rmssd_ms": math.nan,
            "reason": "no_live_historical_overlap",
        }

    historical_overlap = samples_in_range(historical_samples, overlap_start, overlap_end)
    live_overlap = samples_in_range(live_samples, overlap_start, overlap_end)
    historical_windows = [
        window for window in best_windows_from_samples(historical_overlap, window_seconds)
        if bool(window["ready"])
    ]
    compared: list[dict[str, float | int | bool]] = []
    for hist_window in historical_windows:
        start = float(hist_window["start_unix"])
        end = float(hist_window["end_unix"])
        live_window_samples = samples_in_range(live_overlap, start, end)
        if len(live_window_samples) < 2:
            continue
        live_window = corrected_window(live_window_samples)
        hist_rmssd = float(hist_window["rmssd_ms"])
        live_rmssd = float(live_window["rmssd_ms"])
        if not math.isfinite(hist_rmssd) or not math.isfinite(live_rmssd):
            continue
        delta = abs(hist_rmssd - live_rmssd)
        compared.append({
            "start_unix": start,
            "end_unix": end,
            "historical_rmssd_ms": hist_rmssd,
            "live_rmssd_ms": live_rmssd,
            "delta_rmssd_ms": round(delta, 2),
            "historical_kept": int(hist_window["kept"]),
            "live_kept": int(live_window["kept"]),
            "historical_confidence_percent": int(hist_window["confidence_percent"]),
            "live_confidence_percent": int(live_window["confidence_percent"]),
            "historical_max_rr_gap_s": float(hist_window["max_rr_gap_s"]),
            "live_max_rr_gap_s": float(live_window["max_rr_gap_s"]),
            "live_ready": bool(live_window["ready"]),
            "match": bool(live_window["ready"] and delta <= tolerance_ms),
        })

    matches = [item for item in compared if bool(item["match"])]
    best = sorted(
        compared,
        key=lambda item: (
            bool(item["match"]),
            -float(item["delta_rmssd_ms"]),
            int(item["live_kept"]),
        ),
        reverse=True,
    )[:5]
    best_delta = min((float(item["delta_rmssd_ms"]) for item in compared), default=math.nan)
    reason = "match" if matches else ("no_comparable_ready_windows" if not compared else "rmssd_delta_or_live_quality")
    return {
        "historical_rr_values": len(historical_samples),
        "live_rr_values": len(live_samples),
        "overlap": True,
        "overlap_start_unix": round(overlap_start, 3),
        "overlap_end_unix": round(overlap_end, 3),
        "overlap_seconds": round(overlap_seconds, 1),
        "compared_windows": len(compared),
        "matching_windows": len(matches),
        "layout_live_validated": bool(matches),
        "best_delta_rmssd_ms": best_delta,
        "best_windows": best,
        "reason": reason,
    }


def analyze_whoof_layout(
    frames: list[HistoricalFrame],
    realtime: list[RealtimeFrame],
    window_seconds: float,
) -> dict[str, object]:
    rrnum_counts: dict[int, int] = {}
    hr_values: list[int] = []
    rr_values: list[int] = []
    hr_errors: list[float] = []
    frames_with_rr = 0
    for frame in frames:
        payload = frame.payload
        if len(payload) <= 18:
            continue
        hr = payload[17]
        rrnum = payload[18]
        rrnum_counts[rrnum] = rrnum_counts.get(rrnum, 0) + 1
        values = whoof_rr_values(frame)
        if values:
            frames_with_rr += 1
        if 35 <= hr <= 220:
            hr_values.append(hr)
            for value in values:
                rr_values.append(value)
                hr_errors.append(abs((60000 / value) - hr))

    samples = reconstruct_whoof_timed_rr(frames)
    windows = best_windows_from_samples(samples, window_seconds)
    ready_windows = [window for window in windows if window["ready"]]
    overlap = live_overlap_report(frames, realtime)
    raw_values = [sample.ms for sample in samples]
    corrected = corrected_window(samples)
    return {
        "historical_2f_frames": len(frames),
        "frames_with_rr": frames_with_rr,
        "rrnum_counts": rrnum_counts,
        "rr_values": len(rr_values),
        "timed_rr_values": len(samples),
        "mean_hr": round(statistics.mean(hr_values), 1) if hr_values else math.nan,
        "mean_rr_ms": round(statistics.mean(raw_values), 1) if raw_values else math.nan,
        "implied_bpm": round(60000 / statistics.mean(raw_values), 1) if raw_values else math.nan,
        "hr_mae_bpm": round(statistics.mean(hr_errors), 2) if hr_errors else math.nan,
        "hr_within_10_bpm_percent": round((sum(1 for error in hr_errors if error <= 10) / len(hr_errors)) * 100) if hr_errors else 0,
        "all_corrected": corrected,
        "window_count": len(windows),
        "ready_windows": len(ready_windows),
        "best_windows": windows[:5],
        "live_history_overlap": bool(overlap.get("overlap")),
        "live_history_separation_seconds": overlap.get("separation_seconds"),
        "gate_b_ready": False,
    }


def parse_offsets(raw: str) -> list[int]:
    return [int(part.strip(), 0) for part in raw.split(",") if part.strip()]


def payload_len_counts(frames: list[HistoricalFrame]) -> str:
    lengths = sorted({len(frame.payload) for frame in frames})
    return ",".join(f"{length}:{sum(1 for frame in frames if len(frame.payload) == length)}" for length in lengths)


def header_counts(frames: list[HistoricalFrame]) -> str:
    pairs = sorted({(frame.seq, frame.cmd) for frame in frames})
    return ",".join(
        f"seq=0x{seq:02x}:cmd=0x{cmd:02x}:{sum(1 for frame in frames if frame.seq == seq and frame.cmd == cmd)}"
        for seq, cmd in pairs
        if seq is not None and cmd is not None
    )


def known_time_fields(frames: list[HistoricalFrame]) -> dict[str, int | float]:
    unix_values = []
    subsec_values = []
    for frame in frames:
        if len(frame.payload) >= 10:
            unix_values.append(int.from_bytes(frame.payload[7:11], "little"))
            subsec_values.append(u16le(frame.payload, 11))
    if not unix_values:
        return {}
    return {
        "first_unix_offset_7": unix_values[0],
        "last_unix_offset_7": unix_values[-1],
        "unix_span_s": unix_values[-1] - unix_values[0],
        "unique_unix_values": len(set(unix_values)),
        "subsec_min": min(subsec_values),
        "subsec_max": max(subsec_values),
    }


def live_overlap_report(historical: list[HistoricalFrame], realtime: list[RealtimeFrame]) -> dict[str, int | float | bool]:
    historical_times = [frame_time_seconds(frame) for frame in historical]
    historical_times = [time for time in historical_times if time is not None]
    realtime_unix = [frame.unix for frame in realtime]
    realtime_unix = [time for time in realtime_unix if time is not None]
    realtime_rr_values = sum(len(frame.rr_values) for frame in realtime)
    if not historical_times or not realtime_unix:
        return {
            "historical_frames": len(historical),
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
    overlap_seconds = max(0.0, overlap_end - overlap_start)
    if overlap_seconds > 0:
        separation_seconds = 0.0
    elif hist_end < rt_start:
        separation_seconds = rt_start - hist_end
    else:
        separation_seconds = hist_start - rt_end
    return {
        "historical_frames": len(historical),
        "historical_start_unix": round(hist_start, 3),
        "historical_end_unix": round(hist_end, 3),
        "historical_span_s": round(hist_end - hist_start, 1),
        "realtime_frames": len(realtime),
        "realtime_rr_values": realtime_rr_values,
        "realtime_start_unix": int(rt_start),
        "realtime_end_unix": int(rt_end),
        "realtime_span_s": int(rt_end - rt_start),
        "overlap": overlap_seconds > 0,
        "overlap_seconds": round(overlap_seconds, 1),
        "separation_seconds": round(separation_seconds, 1),
    }


def rank_candidate_offsets(
    frames: list[HistoricalFrame],
    realtime: list[RealtimeFrame],
    hr_offset: int,
    window_seconds: float,
) -> list[dict[str, int | float | bool]]:
    candidates = [stat.offset for stat in plausible_offsets(frames)]
    if not candidates:
        return []

    hr_scores = {int(score["offset"]): score for score in score_hr_agreement(frames, candidates, hr_offset)}
    overlap = live_overlap_report(frames, realtime)
    has_overlap = bool(overlap.get("overlap"))
    ranked: list[dict[str, int | float | bool]] = []

    for stat in plausible_offsets(frames):
        offset = stat.offset
        windows = best_windows(frames, [offset], window_seconds)
        ready_windows = [window for window in windows if window["ready"]]
        best = windows[0] if windows else {}
        hr_score = hr_scores.get(offset, {})
        ready_shape = bool(ready_windows)
        hr_within_10 = int(hr_score.get("within_10_bpm_percent", 0) or 0)
        coverage_score = round(stat.fraction * 100)
        window_score = min(len(ready_windows), 1000) / 10
        hr_score_value = hr_within_10
        # This is only a triage ranking. Gate B readiness remains false without
        # live/history overlap plus an external RR/IBI reference comparison.
        rank_score = round(coverage_score + window_score + hr_score_value, 1)
        ranked.append({
            "offset": offset,
            "body_offset": offset - 3 if offset >= 3 else -1,
            "plausible_fraction_percent": coverage_score,
            "mean_rr_ms": round(stat.mean, 1),
            "ready_shape": ready_shape,
            "ready_windows": len(ready_windows),
            "best_kept": int(best.get("kept", 0) or 0),
            "best_confidence_percent": int(best.get("confidence_percent", 0) or 0),
            "best_max_rr_gap_s": float(best.get("max_rr_gap_s", math.inf)),
            "best_duration_ratio": float(best.get("duration_ratio", math.nan)),
            "best_rmssd_ms": float(best.get("rmssd_ms", math.nan)),
            "hr_samples": int(hr_score.get("samples", 0) or 0),
            "hr_within_10_bpm_percent": hr_within_10,
            "hr_mae_bpm": float(hr_score.get("mae_bpm", math.nan)),
            "live_history_overlap": has_overlap,
            "gate_b_ready": False,
            "rank_score": rank_score,
        })

    return sorted(
        ranked,
        key=lambda item: (
            float(item["rank_score"]),
            bool(item["ready_shape"]),
            int(item["hr_within_10_bpm_percent"]),
            int(item["plausible_fraction_percent"]),
        ),
        reverse=True,
    )


def emit_csv(frames: list[HistoricalFrame], offsets: list[int]) -> None:
    writer = csv.writer(sys.stdout)
    writer.writerow([
        "index",
        "channel",
        "declared_len",
        "payload_len",
        "seq",
        "cmd",
        "unix_offset_7",
        "subsec_offset_11",
        *[f"payload_{offset}_u16le" for offset in offsets],
    ])
    for index, frame in enumerate(frames):
        payload = frame.payload
        unix = int.from_bytes(payload[7:11], "little") if len(payload) >= 11 else ""
        subsec = u16le(payload, 11) if len(payload) >= 13 else ""
        writer.writerow([
            index,
            frame.channel,
            frame.declared_len,
            len(payload),
            "" if frame.seq is None else frame.seq,
            "" if frame.cmd is None else frame.cmd,
            unix,
            subsec,
            *[u16le(payload, offset) if offset + 1 < len(payload) else "" for offset in offsets],
        ])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument(
        "--offsets",
        default="64,66,68,70",
        help="comma-separated payload offsets to evaluate as u16le RR candidates",
    )
    parser.add_argument(
        "--csv",
        action="store_true",
        help="emit per-frame candidate rows instead of the text summary",
    )
    parser.add_argument(
        "--windows",
        action="store_true",
        help="evaluate reconstructed 300-second candidate windows with Gate B rules",
    )
    parser.add_argument(
        "--window-seconds",
        type=float,
        default=300.0,
        help="window size for --windows",
    )
    parser.add_argument(
        "--hr-agreement",
        action="store_true",
        help="score candidate offsets against the historical HR byte",
    )
    parser.add_argument(
        "--hr-offset",
        type=int,
        default=17,
        help="payload offset containing historical HR for --hr-agreement",
    )
    parser.add_argument(
        "--live-overlap",
        action="store_true",
        help="report whether 0x2f history and live 0x28 realtime frames overlap in strap time",
    )
    parser.add_argument(
        "--rank-candidates",
        action="store_true",
        help="rank single-offset historical RR hypotheses with explicit non-ready Gate B verdicts",
    )
    parser.add_argument(
        "--whoof-layout",
        action="store_true",
        help="evaluate the whoof-derived layout: HR offset 17, rrnum offset 18, RR u16le from offset 19",
    )
    parser.add_argument(
        "--live-rr-reference",
        action="store_true",
        help="compare a historical RR hypothesis against overlapping live 0x28 RR in strap time",
    )
    parser.add_argument(
        "--live-reference-layout",
        choices=("offsets", "whoof"),
        default="offsets",
        help="historical layout to test with --live-rr-reference",
    )
    parser.add_argument(
        "--live-reference-tolerance-ms",
        type=float,
        default=5.0,
        help="RMSSD agreement threshold for live-vs-history layout validation",
    )
    args = parser.parse_args()

    frames = extract_frames(args.log)
    offsets = parse_offsets(args.offsets)
    if args.live_rr_reference:
        realtime = extract_realtime_frames(args.log)
        historical_samples = (
            reconstruct_whoof_timed_rr(frames)
            if args.live_reference_layout == "whoof"
            else reconstruct_timed_rr(frames, offsets)
        )
        live_samples = reconstruct_live_timed_rr(realtime)
        report = validate_against_live_rr(
            historical_samples,
            live_samples,
            args.window_seconds,
            args.live_reference_tolerance_ms,
        )
        print(f"historical_2f_frames={len(frames)}")
        print_codec_summary(frames)
        print(f"layout={args.live_reference_layout}")
        if args.live_reference_layout == "offsets":
            print("candidate_set offsets=" + ",".join(map(str, offsets)))
        else:
            print("candidate_set=whoof_hr17_rrnum18_rr19_u16le")
        print(f"window_seconds={args.window_seconds:g}")
        print(f"tolerance_ms={args.live_reference_tolerance_ms:g}")
        print(f"historical_rr_values={report['historical_rr_values']}")
        print(f"live_rr_values={report['live_rr_values']}")
        print(f"live_history_overlap={int(bool(report['overlap']))}")
        if report.get("overlap_start_unix") is not None:
            print(f"overlap_start_unix={report['overlap_start_unix']}")
            print(f"overlap_end_unix={report['overlap_end_unix']}")
        print(f"overlap_seconds={report['overlap_seconds']}")
        if report.get("separation_seconds") is not None:
            print(f"live_history_separation_seconds={report['separation_seconds']}")
        print(f"compared_windows={report['compared_windows']}")
        print(f"matching_windows={report['matching_windows']}")
        print(f"layout_live_validated={int(bool(report['layout_live_validated']))}")
        print(f"best_delta_rmssd_ms={report['best_delta_rmssd_ms']}")
        for index, window in enumerate(report.get("best_windows", []) if isinstance(report.get("best_windows"), list) else []):
            print(
                "window_%d start_unix=%s end_unix=%s historical_rmssd_ms=%s "
                "live_rmssd_ms=%s delta_rmssd_ms=%s historical_kept=%s live_kept=%s "
                "historical_conf=%s live_conf=%s historical_max_gap_s=%s "
                "live_max_gap_s=%s live_ready=%d match=%d"
                % (
                    index,
                    window["start_unix"],
                    window["end_unix"],
                    window["historical_rmssd_ms"],
                    window["live_rmssd_ms"],
                    window["delta_rmssd_ms"],
                    window["historical_kept"],
                    window["live_kept"],
                    window["historical_confidence_percent"],
                    window["live_confidence_percent"],
                    window["historical_max_rr_gap_s"],
                    window["live_max_rr_gap_s"],
                    int(bool(window["live_ready"])),
                    int(bool(window["match"])),
                )
            )
        print(f"reason={report['reason']}")
        print("gate_b_ready=0")
        print("interpretation=historical_layout_live_rr_cross_check_only")
        print("warning=live_rr_is_same_strap_not_external_reference")
        print("warning=external_rr_reference_still_required_for_gate_b")
        print("warning=do_not_feed_hrv_until_layout_and_external_reference_are_validated")
        return 0

    if args.whoof_layout:
        report = analyze_whoof_layout(frames, extract_realtime_frames(args.log), args.window_seconds)
        print(f"historical_2f_frames={report['historical_2f_frames']}")
        print_codec_summary(frames)
        print("layout=whoof_hr17_rrnum18_rr19_u16le")
        print(f"window_seconds={args.window_seconds:g}")
        print(f"frames_with_rr={report['frames_with_rr']}")
        counts = report["rrnum_counts"]
        if isinstance(counts, dict):
            print("rrnum_counts=" + ",".join(f"{key}:{counts[key]}" for key in sorted(counts)))
        print(f"rr_values={report['rr_values']}")
        print(f"timed_rr_values={report['timed_rr_values']}")
        print(f"mean_hr={report['mean_hr']}")
        print(f"mean_rr_ms={report['mean_rr_ms']}")
        print(f"implied_bpm={report['implied_bpm']}")
        print(f"hr_mae_bpm={report['hr_mae_bpm']}")
        print(f"hr_within_10_bpm_percent={report['hr_within_10_bpm_percent']}")
        corrected = report["all_corrected"]
        if isinstance(corrected, dict):
            print(
                "all_corrected raw=%s kept=%s conf=%s max_rr_gap_s=%s "
                "duration_ratio=%s rmssd_ms=%s ready=%d"
                % (
                    corrected["raw"],
                    corrected["kept"],
                    corrected["confidence_percent"],
                    corrected["max_rr_gap_s"],
                    corrected["duration_ratio"],
                    corrected["rmssd_ms"],
                    int(bool(corrected["ready"])),
                )
            )
        print(f"window_count={report['window_count']}")
        print(f"ready_windows={report['ready_windows']}")
        for index, window in enumerate(report["best_windows"] if isinstance(report["best_windows"], list) else []):
            print(
                "window_%d start_unix=%s end_unix=%s duration_s=%s raw=%s kept=%s "
                "conf=%s max_rr_gap_s=%s duration_ratio=%s rmssd_ms=%s ready=%d"
                % (
                    index,
                    window["start_unix"],
                    window["end_unix"],
                    window["duration_s"],
                    window["raw"],
                    window["kept"],
                    window["confidence_percent"],
                    window["max_rr_gap_s"],
                    window["duration_ratio"],
                    window["rmssd_ms"],
                    int(bool(window["ready"])),
                )
            )
        print(f"live_history_overlap={int(bool(report['live_history_overlap']))}")
        if report["live_history_separation_seconds"] is not None:
            print(f"live_history_separation_seconds={report['live_history_separation_seconds']}")
        print("gate_b_ready=0")
        print("interpretation=whoof_layout_plausible_but_unvalidated_historical_rr")
        print("warning=historical_region_old_or_nonoverlapping_do_not_feed_hrv")
        print("warning=external_rr_reference_still_required")
        return 0

    if args.rank_candidates:
        realtime = extract_realtime_frames(args.log)
        ranked = rank_candidate_offsets(frames, realtime, args.hr_offset, args.window_seconds)
        overlap = live_overlap_report(frames, realtime)
        print(f"historical_2f_frames={len(frames)}")
        print_codec_summary(frames)
        print(f"window_seconds={args.window_seconds:g}")
        print(f"hr_offset={args.hr_offset}")
        print(f"live_history_overlap={int(bool(overlap.get('overlap')))}")
        if "separation_seconds" in overlap:
            print(f"live_history_separation_seconds={overlap['separation_seconds']}")
        print("ranked_single_offset_hypotheses:")
        for index, item in enumerate(ranked[:10]):
            print(
                "  rank=%d offset=%02d body_offset=%s score=%s plausible=%s%% "
                "ready_shape=%d ready_windows=%d kept=%d conf=%d max_gap_s=%s "
                "duration_ratio=%s rmssd_ms=%s hr_samples=%d "
                "hr_within_10_bpm=%s%% hr_mae_bpm=%s overlap=%d gate_b_ready=0"
                % (
                    index + 1,
                    item["offset"],
                    item["body_offset"],
                    item["rank_score"],
                    item["plausible_fraction_percent"],
                    int(bool(item["ready_shape"])),
                    item["ready_windows"],
                    item["best_kept"],
                    item["best_confidence_percent"],
                    item["best_max_rr_gap_s"],
                    item["best_duration_ratio"],
                    item["best_rmssd_ms"],
                    item["hr_samples"],
                    item["hr_within_10_bpm_percent"],
                    item["hr_mae_bpm"],
                    int(bool(item["live_history_overlap"])),
                )
            )
        print("interpretation=single_offset_rr_hypotheses_ranked_for_next_experiment")
        print("warning=gate_b_ready_forced_false_without_external_rr_reference")
        print("warning=provisional_not_clinical_do_not_feed_hrv")
        return 0

    if args.live_overlap:
        report = live_overlap_report(frames, extract_realtime_frames(args.log))
        print_codec_summary(frames)
        for key, value in report.items():
            if isinstance(value, bool):
                value = int(value)
            print(f"{key}={value}")
        if report.get("overlap"):
            print("interpretation=live_and_historical_clock_ranges_overlap")
        else:
            print("interpretation=no_live_historical_overlap_for_rr_validation")
        print("warning=overlap_only_not_external_reference")
        return 0

    if args.csv:
        try:
            emit_csv(frames, offsets)
        except BrokenPipeError:
            try:
                sys.stdout.close()
            finally:
                os._exit(0)
        return 0

    if args.windows:
        windows = best_windows(frames, offsets, args.window_seconds)
        print(f"historical_2f_frames={len(frames)}")
        print_codec_summary(frames)
        print("candidate_set offsets=" + ",".join(map(str, offsets)))
        print(f"timed_rr_values={len(reconstruct_timed_rr(frames, offsets))}")
        print(f"window_seconds={args.window_seconds:g}")
        print(f"window_count={len(windows)}")
        ready = [window for window in windows if window["ready"]]
        print(f"ready_windows={len(ready)}")
        for index, window in enumerate(windows[:5]):
            print(
                "window_%d start_unix=%s end_unix=%s duration_s=%s raw=%s kept=%s "
                "conf=%s max_rr_gap_s=%s rr_sum_s=%s duration_ratio=%s "
                "duration_consistent=%s rmssd_ms=%s ready=%s"
                % (
                    index,
                    window["start_unix"],
                    window["end_unix"],
                    window["duration_s"],
                    window["raw"],
                    window["kept"],
                    window["confidence_percent"],
                    window["max_rr_gap_s"],
                    window["rr_sum_s"],
                    window["duration_ratio"],
                    int(bool(window["duration_consistent"])),
                    window["rmssd_ms"],
                    int(bool(window["ready"])),
                )
            )
        print("interpretation=reconstructed_candidate_windows_not_validated")
        print("warning=provisional_not_clinical_do_not_feed_hrv")
        return 0

    if args.hr_agreement:
        print(f"historical_2f_frames={len(frames)}")
        print_codec_summary(frames)
        print(f"hr_offset={args.hr_offset}")
        print("candidate_set offsets=" + ",".join(map(str, offsets)))
        print("hr_agreement_scores:")
        for score in score_hr_agreement(frames, offsets, args.hr_offset):
            print(
                "  offset=%02d samples=%d mean_hr=%s mean_rr_ms=%s "
                "mean_implied_bpm=%s mae_bpm=%s median_abs_error_bpm=%s "
                "within_5_bpm_percent=%s within_10_bpm_percent=%s"
                % (
                    score["offset"],
                    score["samples"],
                    score["mean_hr"],
                    score["mean_rr"],
                    score["mean_implied_bpm"],
                    score["mae_bpm"],
                    score["median_abs_error_bpm"],
                    score["within_5_bpm_percent"],
                    score["within_10_bpm_percent"],
                )
            )
        print("interpretation=historical_hr_agreement_not_external_reference")
        print("warning=provisional_not_clinical_do_not_feed_hrv")
        return 0

    print(f"historical_2f_frames={len(frames)}")
    print_codec_summary(frames)
    if not frames:
        return 1
    print("payload_len_counts=" + payload_len_counts(frames))
    print("header_counts=" + header_counts(frames))
    for key, value in known_time_fields(frames).items():
        print(f"{key}={value}")

    print("plausible_offsets:")
    for stat in plausible_offsets(frames):
        print(
            f"  offset={stat.offset:02d} fraction={stat.fraction:.3f} "
            f"mean={stat.mean:.1f} stdev={stat.stdev:.1f} "
            f"range={stat.min_value}-{stat.max_value} "
            f"body_offset={stat.offset - 3 if stat.offset >= 3 else 'header'}"
        )

    result = evaluate_offsets(frames, offsets)
    print("candidate_set offsets=" + ",".join(map(str, offsets)))
    print("candidate_set_body_offsets=" + ",".join(str(offset - 3) for offset in offsets))
    for key, value in result.items():
        print(f"{key}={value}")
    print("interpretation=raw_candidate_k_revision_layout_not_validated")
    print("warning=provisional_not_clinical_do_not_feed_hrv")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
