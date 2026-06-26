#!/usr/bin/env python3
"""Compare WHOOP heart-rate samples against an external HR reference.

This is a Gate D evidence tool for the "HR +/-2 bpm vs chest strap at rest"
exit. It compares real heart-rate samples only. It does not derive HR from RR
and it does not validate HRV. Inputs can be a WHOOP capture CSV emitted by the
iOS app and a reference CSV with HR samples from a chest strap or comparable
recorder.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import sys
from dataclasses import asdict, dataclass
from pathlib import Path


HR_COLUMNS = ("hr", "heart_rate", "bpm", "value")
TIME_COLUMNS = ("elapsed_ms", "time_ms", "timestamp_ms", "t_ms", "seconds", "time_s", "timestamp", "t")


@dataclass
class HRSample:
    t: float
    bpm: float


@dataclass
class Comparison:
    pairs: int
    mean_delta_bpm: float | None
    median_delta_bpm: float | None
    max_delta_bpm: float | None
    within_tolerance_percent: float | None
    duration_s: float
    ready: bool
    reason: str


def parse_whoop_capture(path: Path) -> list[HRSample]:
    rows = list(csv.DictReader(path.open(newline="")))
    samples: list[HRSample] = []
    for row in rows:
        if row.get("kind") != "hr":
            continue
        elapsed_ms = parse_float(row.get("elapsed_ms"))
        bpm = parse_float(row.get("value"))
        if elapsed_ms is None or bpm is None:
            continue
        samples.append(HRSample(t=elapsed_ms / 1000.0, bpm=bpm))
    return samples


def parse_reference(path: Path) -> list[HRSample]:
    rows = list(csv.DictReader(path.open(newline="")))
    if not rows:
        return []
    headers = [header.strip() for header in (rows[0].keys() or []) if header]
    normalized = {header.lower().strip(): header for header in headers}
    if {"elapsed_ms", "kind", "value"}.issubset(normalized):
        return parse_whoop_capture(path)

    hr_header = first_present(normalized, HR_COLUMNS)
    time_header = first_present(normalized, TIME_COLUMNS)
    if hr_header is None:
        return []

    samples: list[HRSample] = []
    elapsed = 0.0
    for row in rows:
        bpm = parse_float(row.get(hr_header))
        if bpm is None:
            continue
        time_value = parse_float(row.get(time_header)) if time_header else None
        if time_value is None:
            t = elapsed
            elapsed += 1.0
        else:
            t = normalize_time(time_value, time_header or "")
        samples.append(HRSample(t=t, bpm=bpm))
    return samples


def first_present(normalized: dict[str, str], candidates: tuple[str, ...]) -> str | None:
    for candidate in candidates:
        if candidate in normalized:
            return normalized[candidate]
    return None


def parse_float(value: str | None) -> float | None:
    if value is None:
        return None
    try:
        return float(str(value).strip())
    except ValueError:
        return None


def normalize_time(value: float, header: str) -> float:
    lower = header.lower()
    if lower.endswith("_ms") or "elapsed_ms" in lower or "timestamp_ms" in lower:
        return value / 1000.0
    return value


def window(samples: list[HRSample], start_s: float | None, duration_s: float | None) -> list[HRSample]:
    if not samples:
        return []
    ordered = sorted(samples, key=lambda sample: sample.t)
    start = ordered[0].t if start_s is None else start_s
    if duration_s is None:
        return [sample for sample in ordered if sample.t >= start]
    end = start + duration_s
    return [sample for sample in ordered if start <= sample.t <= end]


def pair_samples(
    whoop: list[HRSample],
    reference: list[HRSample],
    max_age_s: float,
) -> list[tuple[HRSample, HRSample, float]]:
    pairs: list[tuple[HRSample, HRSample, float]] = []
    refs = sorted(reference, key=lambda sample: sample.t)
    if not refs:
        return pairs
    for sample in sorted(whoop, key=lambda item: item.t):
        nearest = min(refs, key=lambda ref: abs(ref.t - sample.t))
        age = abs(nearest.t - sample.t)
        if age <= max_age_s:
            pairs.append((sample, nearest, age))
    return pairs


def compare(
    whoop: list[HRSample],
    reference: list[HRSample],
    tolerance_bpm: float,
    max_pair_age_s: float,
    min_pairs: int,
    min_duration_s: float,
) -> Comparison:
    pairs = pair_samples(whoop, reference, max_pair_age_s)
    deltas = [abs(w.bpm - r.bpm) for w, r, _ in pairs]
    duration = 0.0
    if pairs:
        duration = pairs[-1][0].t - pairs[0][0].t
    mean_delta = statistics.mean(deltas) if deltas else None
    median_delta = statistics.median(deltas) if deltas else None
    max_delta = max(deltas) if deltas else None
    within = (
        100.0 * sum(1 for delta in deltas if delta <= tolerance_bpm) / len(deltas)
        if deltas else None
    )

    ready = (
        len(pairs) >= min_pairs
        and duration >= min_duration_s
        and mean_delta is not None
        and max_delta is not None
        and mean_delta <= tolerance_bpm
        and max_delta <= tolerance_bpm
    )
    reason = "ready"
    if len(pairs) < min_pairs:
        reason = "pairs"
    elif duration < min_duration_s:
        reason = "window"
    elif mean_delta is None or max_delta is None:
        reason = "metrics"
    elif mean_delta > tolerance_bpm:
        reason = "mean_delta"
    elif max_delta > tolerance_bpm:
        reason = "max_delta"

    return Comparison(
        pairs=len(pairs),
        mean_delta_bpm=round(mean_delta, 3) if mean_delta is not None else None,
        median_delta_bpm=round(median_delta, 3) if median_delta is not None else None,
        max_delta_bpm=round(max_delta, 3) if max_delta is not None else None,
        within_tolerance_percent=round(within, 3) if within is not None else None,
        duration_s=round(duration, 3),
        ready=ready,
        reason=reason,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("whoop_csv", type=Path)
    parser.add_argument("reference_csv", type=Path)
    parser.add_argument("--tolerance-bpm", type=float, default=2.0)
    parser.add_argument("--max-pair-age-s", type=float, default=5.0)
    parser.add_argument("--min-pairs", type=int, default=30)
    parser.add_argument("--min-duration-s", type=float, default=60.0)
    parser.add_argument("--start-s", type=float)
    parser.add_argument("--duration-s", type=float)
    parser.add_argument(
        "--allow-self-compare",
        action="store_true",
        help="Permit WHOOP-vs-WHOOP parser smoke tests. This never counts as an external Gate D reference.",
    )
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()

    same_file = same_resolved_file(args.whoop_csv, args.reference_csv)
    if same_file and not args.allow_self_compare:
        report = {
            "status": "fail",
            "reason": "same_file_not_external_reference",
            "external_reference": False,
            "gate_d_pass": False,
            "tolerance_bpm": args.tolerance_bpm,
            "max_pair_age_s": args.max_pair_age_s,
            "strap_samples": 0,
            "reference_samples": 0,
            "comparison": asdict(Comparison(0, None, None, None, None, 0.0, False, "same_file_not_external_reference")),
        }
        print(f"status={report['status']}")
        print(f"reason={report['reason']}")
        print("external_reference=0")
        print("gate_d_pass=0")
        print("warning=WHOOP CSV and reference CSV are the same file; provide an independent HR recording or rerun with --allow-self-compare for parser smoke only.")
        if args.json:
            args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
            print(f"json={args.json}")
        return 1

    whoop = window(parse_whoop_capture(args.whoop_csv), args.start_s, args.duration_s)
    reference = window(parse_reference(args.reference_csv), args.start_s, args.duration_s)
    result = compare(
        whoop,
        reference,
        tolerance_bpm=args.tolerance_bpm,
        max_pair_age_s=args.max_pair_age_s,
        min_pairs=args.min_pairs,
        min_duration_s=args.min_duration_s,
    )
    external_reference = not same_file
    passed = result.ready and external_reference
    parser_smoke_passed = bool(same_file and args.allow_self_compare and result.ready)
    status = "pass" if passed else ("parser_smoke_pass" if parser_smoke_passed else "fail")
    reason = "same_file_parser_smoke_only" if result.ready and not external_reference else result.reason
    report = {
        "status": status,
        "reason": reason,
        "external_reference": external_reference,
        "gate_d_pass": passed,
        "metric_passed": result.ready,
        "tolerance_bpm": args.tolerance_bpm,
        "max_pair_age_s": args.max_pair_age_s,
        "strap_samples": len(whoop),
        "reference_samples": len(reference),
        "comparison": asdict(result),
    }

    print(f"status={status}")
    print(f"reason={reason}")
    print(f"external_reference={int(external_reference)}")
    print(f"gate_d_pass={int(passed)}")
    print(f"strap_samples={len(whoop)} reference_samples={len(reference)} pairs={result.pairs}")
    print(f"mean_delta_bpm={fmt(result.mean_delta_bpm)}")
    print(f"median_delta_bpm={fmt(result.median_delta_bpm)}")
    print(f"max_delta_bpm={fmt(result.max_delta_bpm)}")
    print(f"within_tolerance_percent={fmt(result.within_tolerance_percent)}")
    print(f"duration_s={result.duration_s:.1f}")
    if args.json:
        args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(f"json={args.json}")
    if same_file:
        print("warning=self_compare_parser_smoke_only")
    return 0 if passed or parser_smoke_passed else 1


def same_resolved_file(a: Path, b: Path) -> bool:
    try:
        return a.resolve(strict=True) == b.resolve(strict=True)
    except OSError:
        return a.absolute() == b.absolute()


def fmt(value: float | None) -> str:
    if value is None:
        return "learning"
    if math.isfinite(value):
        return f"{value:.3f}"
    return "learning"


if __name__ == "__main__":
    sys.exit(main())
