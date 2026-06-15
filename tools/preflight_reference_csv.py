#!/usr/bin/env python3
"""Preflight an external RR/IBI or HR reference CSV before device validation.

This is not a gate validator. Atria on the iPhone remains the authority for
Gate B/D pass bits. The preflight only checks that a Mac-side CSV uses a header
shape the app accepts, counts parseable samples, and reports obvious readiness
blockers before spending a physical-device launch.
"""

from __future__ import annotations

import argparse
import csv
import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path


RR_COLUMNS = ("rr_ms", "rr", "ibi_ms", "ibi", "interval_ms", "interval", "nn_ms", "nn", "value")
HR_COLUMNS = ("hr", "heart_rate", "bpm", "value")
TIME_COLUMNS = ("elapsed_ms", "time_ms", "timestamp_ms", "t_ms", "seconds", "time_s", "timestamp", "t")


@dataclass
class Sample:
    t: float
    value: float


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("rr", "hr"))
    parser.add_argument("csv_path", type=Path)
    args = parser.parse_args()

    try:
        rows = list(csv.DictReader(args.csv_path.open(newline="")))
    except OSError as exc:
        emit_common(args.kind, args.csv_path)
        print("status=error")
        print(f"reason=file_read_failed")
        print(f"error={token(str(exc))}")
        return 2

    headers = [header.strip() for header in (rows[0].keys() if rows else []) if header]
    normalized = {header.lower().strip(): header for header in headers}
    emit_common(args.kind, args.csv_path)
    print(f"rows={len(rows)}")
    print(f"headers={','.join(headers) if headers else 'none'}")

    if not rows:
        print("status=fail")
        print("reason=empty_csv")
        return 2

    if args.kind == "rr":
        samples, rr_header, time_header, skipped = parse_rr(rows, normalized)
        ready, reason, duration, max_gap, kept, confidence = score_rr(samples)
        print(f"status={'ok' if samples else 'fail'}")
        print(f"rr_column={rr_header or 'none'}")
        print(f"time_column={time_header or 'none'}")
        print(f"parsed={len(samples)}")
        print(f"skipped={skipped}")
        print(f"duration_s={duration:.1f}")
        print(f"max_gap_s={max_gap:.1f}")
        print(f"kept={kept}")
        print(f"confidence_percent={confidence}")
        print(f"reference_ready={1 if ready else 0}")
        print(f"reason={reason}")
        return 0 if samples else 2

    samples, hr_header, time_header, skipped = parse_hr(rows, normalized)
    ready, reason, duration = score_hr(samples)
    print(f"status={'ok' if samples else 'fail'}")
    print(f"hr_column={hr_header or 'none'}")
    print(f"time_column={time_header or 'none'}")
    print(f"parsed={len(samples)}")
    print(f"skipped={skipped}")
    print(f"duration_s={duration:.1f}")
    print(f"reference_ready={1 if ready else 0}")
    print(f"reason={reason}")
    return 0 if samples else 2


def emit_common(kind: str, path: Path) -> None:
    print(f"kind={kind}")
    print(f"path={path}")


def parse_rr(rows: list[dict[str, str]], normalized: dict[str, str]) -> tuple[list[Sample], str | None, str | None, int]:
    capture_shape = {"elapsed_ms", "kind", "value"}.issubset(normalized)
    rr_header = first_present(normalized, RR_COLUMNS)
    time_header = first_present(normalized, TIME_COLUMNS)
    samples: list[Sample] = []
    skipped = 0
    elapsed = 0.0
    for row in rows:
        if capture_shape and (row.get(normalized["kind"]) or "").strip().lower() != "rr":
            skipped += 1
            continue
        value = parse_float(row.get(rr_header)) if rr_header else None
        if value is None:
            skipped += 1
            continue
        time_value = parse_float(row.get(time_header)) if time_header else None
        if time_value is None:
            elapsed += value / 1000.0
            t = elapsed
        else:
            t = normalize_time(time_value, time_header or "")
        samples.append(Sample(t=t, value=value))
    return samples, rr_header, time_header, skipped


def parse_hr(rows: list[dict[str, str]], normalized: dict[str, str]) -> tuple[list[Sample], str | None, str | None, int]:
    capture_shape = {"elapsed_ms", "kind", "value"}.issubset(normalized)
    hr_header = first_present(normalized, HR_COLUMNS)
    time_header = first_present(normalized, TIME_COLUMNS)
    samples: list[Sample] = []
    skipped = 0
    elapsed = 0.0
    for row in rows:
        if capture_shape and (row.get(normalized["kind"]) or "").strip().lower() != "hr":
            skipped += 1
            continue
        value = parse_float(row.get(hr_header)) if hr_header else None
        if value is None or value <= 0:
            skipped += 1
            continue
        time_value = parse_float(row.get(time_header)) if time_header else None
        if time_value is None:
            t = elapsed
            elapsed += 1.0
        else:
            t = normalize_time(time_value, time_header or "")
        samples.append(Sample(t=t, value=value))
    return samples, hr_header, time_header, skipped


def score_rr(samples: list[Sample]) -> tuple[bool, str, float, float, int, int]:
    ordered = sorted(samples, key=lambda sample: sample.t)
    if not ordered:
        return False, "no_parseable_rr", 0.0, 0.0, 0, 0
    kept: list[Sample] = []
    for sample in ordered:
        if not 300 <= sample.value <= 2000:
            continue
        if kept and abs(sample.value - kept[-1].value) / kept[-1].value > 0.20:
            continue
        kept.append(sample)
    duration = ordered[-1].t - ordered[0].t if len(ordered) >= 2 else 0.0
    max_gap = max((b.t - a.t for a, b in zip(ordered, ordered[1:])), default=0.0)
    confidence = int(round(len(kept) / len(ordered) * 100)) if ordered else 0
    ready = duration >= 299 and max_gap <= 3 and len(kept) >= 240 and confidence >= 75
    reason = "ready"
    if duration < 299:
        reason = "window"
    elif max_gap > 3:
        reason = "gap"
    elif len(kept) < 240:
        reason = "beats"
    elif confidence < 75:
        reason = "confidence"
    return ready, reason, duration, max_gap, len(kept), confidence


def score_hr(samples: list[Sample]) -> tuple[bool, str, float]:
    ordered = sorted(samples, key=lambda sample: sample.t)
    if not ordered:
        return False, "no_parseable_hr", 0.0
    duration = ordered[-1].t - ordered[0].t if len(ordered) >= 2 else 0.0
    ready = len(ordered) >= 30 and duration >= 60
    if len(ordered) < 30:
        reason = "pairs"
    elif duration < 60:
        reason = "window"
    else:
        reason = "ready"
    return ready, reason, duration


def first_present(normalized: dict[str, str], candidates: tuple[str, ...]) -> str | None:
    for candidate in candidates:
        if candidate in normalized:
            return normalized[candidate]
    return None


def parse_float(value: str | None) -> float | None:
    if value is None:
        return None
    match = re.search(r"-?\d+(?:\.\d+)?", str(value).strip())
    if not match:
        return None
    try:
        return float(match.group(0))
    except ValueError:
        return None


def normalize_time(value: float, header: str) -> float:
    lower = header.lower()
    if lower.endswith("_ms") or "elapsed_ms" in lower or "timestamp_ms" in lower:
        return value / 1000.0
    return value


def token(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.:-]+", "_", value)


if __name__ == "__main__":
    sys.exit(main())
