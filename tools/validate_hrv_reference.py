#!/usr/bin/env python3
"""Compare a WHOOP RR capture against an external RR/IBI reference.

This is a Gate B evidence tool. It never estimates HRV from heart-rate samples:
both inputs must contain real RR/IBI intervals. The same artifact contract used
by the app is applied to each side: keep 300-2000 ms, drop |delta RR| > 20%,
confidence = kept/raw, and require a 5-minute clean window before comparing
RMSSD. Gate B passes only when WHOOP and reference RMSSD differ by <= 5 ms.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable


RR_COLUMN_CANDIDATES = (
    "rr_ms",
    "rr",
    "ibi_ms",
    "ibi",
    "interval_ms",
    "interval",
    "nn_ms",
    "nn",
    "value",
)
TIME_COLUMN_CANDIDATES = (
    "elapsed_ms",
    "time_ms",
    "timestamp_ms",
    "t_ms",
    "seconds",
    "time_s",
    "timestamp",
    "t",
)


@dataclass
class RRPoint:
    t: float
    ms: float


@dataclass
class Metrics:
    raw: int
    kept: int
    rejected_out_of_range: int
    rejected_delta_over_20_percent: int
    confidence_percent: int
    duration_s: float
    max_gap_s: float
    rmssd_ms: float | None
    sdnn_ms: float | None
    pnn50_percent: float | None
    lnrmssd: float | None
    ready: bool
    reason: str


def parse_capture_csv(path: Path) -> list[RRPoint]:
    rows = list(csv.DictReader(path.open(newline="")))
    points: list[RRPoint] = []
    for row in rows:
        if row.get("kind") != "rr":
            continue
        value = parse_float(row.get("value"))
        elapsed_ms = parse_float(row.get("elapsed_ms"))
        if value is None or elapsed_ms is None:
            continue
        points.append(RRPoint(t=elapsed_ms / 1000.0, ms=value))
    return points


def parse_reference_csv(path: Path) -> list[RRPoint]:
    rows = list(csv.DictReader(path.open(newline="")))
    if not rows:
        return []

    headers = [header.strip() for header in (rows[0].keys() or []) if header]
    normalized = {header.lower().strip(): header for header in headers}
    if {"elapsed_ms", "kind", "value"}.issubset(normalized):
        return parse_capture_csv(path)

    rr_header = first_present(normalized, RR_COLUMN_CANDIDATES)
    time_header = first_present(normalized, TIME_COLUMN_CANDIDATES)

    # Headered generic reference file.
    if rr_header is not None:
        points: list[RRPoint] = []
        elapsed = 0.0
        for row in rows:
            ms = parse_float(row.get(rr_header))
            if ms is None:
                continue
            t_value = parse_float(row.get(time_header)) if time_header else None
            if t_value is None:
                elapsed += ms / 1000.0
                t = elapsed
            else:
                t = normalize_time(t_value, time_header or "")
            points.append(RRPoint(t=t, ms=ms))
        return points

    # Single-column CSV without a useful header: treat every numeric cell as RR.
    raw_values: list[float] = []
    for row in rows:
        for value in row.values():
            parsed = parse_float(value)
            if parsed is not None:
                raw_values.append(parsed)
                break
    return points_from_rr_values(raw_values)


def first_present(normalized: dict[str, str], candidates: Iterable[str]) -> str | None:
    for candidate in candidates:
        if candidate in normalized:
            return normalized[candidate]
    return None


def parse_float(value: str | None) -> float | None:
    if value is None:
        return None
    match = re.search(r"-?\d+(?:\.\d+)?", str(value))
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


def points_from_rr_values(values: Iterable[float]) -> list[RRPoint]:
    points: list[RRPoint] = []
    elapsed = 0.0
    for ms in values:
        elapsed += ms / 1000.0
        points.append(RRPoint(t=elapsed, ms=ms))
    return points


def select_window(points: list[RRPoint], start_s: float | None, window_s: float) -> list[RRPoint]:
    if not points:
        return []
    ordered = sorted(points, key=lambda point: point.t)
    start = ordered[0].t if start_s is None else start_s
    end = start + window_s
    return [point for point in ordered if start <= point.t <= end]


def correct_and_score(points: list[RRPoint], window_s: float) -> Metrics:
    ordered = sorted(points, key=lambda point: point.t)
    kept: list[RRPoint] = []
    rejected_range = 0
    rejected_delta = 0
    for point in ordered:
        if not 300 <= point.ms <= 2000:
            rejected_range += 1
            continue
        if kept and abs(point.ms - kept[-1].ms) / kept[-1].ms > 0.20:
            rejected_delta += 1
            continue
        kept.append(point)

    confidence = int(round((len(kept) / len(ordered)) * 100)) if ordered else 0
    duration = (ordered[-1].t - ordered[0].t) if len(ordered) >= 2 else 0.0
    max_gap = max(
        (b.t - a.t for a, b in zip(ordered, ordered[1:])),
        default=0.0,
    )
    rmssd_value = rmssd([point.ms for point in kept])
    sdnn_value = sdnn([point.ms for point in kept])
    pnn50_value = pnn50([point.ms for point in kept])
    lnrmssd_value = math.log(rmssd_value) if rmssd_value and rmssd_value > 0 else None

    ready = (
        duration >= window_s - 1
        and max_gap <= 3
        and len(kept) >= 240
        and confidence >= 75
        and rmssd_value is not None
    )
    reason = "ready"
    if duration < window_s - 1:
        reason = "window"
    elif max_gap > 3:
        reason = "gap"
    elif len(kept) < 240:
        reason = "beats"
    elif confidence < 75:
        reason = "confidence"
    elif rmssd_value is None:
        reason = "metrics"

    return Metrics(
        raw=len(ordered),
        kept=len(kept),
        rejected_out_of_range=rejected_range,
        rejected_delta_over_20_percent=rejected_delta,
        confidence_percent=confidence,
        duration_s=round(duration, 3),
        max_gap_s=round(max_gap, 3),
        rmssd_ms=round(rmssd_value, 3) if rmssd_value is not None else None,
        sdnn_ms=round(sdnn_value, 3) if sdnn_value is not None else None,
        pnn50_percent=round(pnn50_value, 3) if pnn50_value is not None else None,
        lnrmssd=round(lnrmssd_value, 6) if lnrmssd_value is not None else None,
        ready=ready,
        reason=reason,
    )


def rmssd(values: list[float]) -> float | None:
    if len(values) < 2:
        return None
    diffs = [b - a for a, b in zip(values, values[1:])]
    return math.sqrt(sum(diff * diff for diff in diffs) / len(diffs))


def sdnn(values: list[float]) -> float | None:
    if len(values) < 2:
        return None
    return statistics.stdev(values)


def pnn50(values: list[float]) -> float | None:
    if len(values) < 2:
        return None
    diffs = [abs(b - a) for a, b in zip(values, values[1:])]
    return 100.0 * sum(1 for diff in diffs if diff > 50) / len(diffs)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("whoop_csv", type=Path)
    parser.add_argument("reference_csv", type=Path)
    parser.add_argument("--window-s", type=float, default=300.0)
    parser.add_argument("--start-s", type=float)
    parser.add_argument("--tolerance-ms", type=float, default=5.0)
    parser.add_argument(
        "--allow-self-compare",
        action="store_true",
        help="Permit WHOOP-vs-WHOOP parser smoke tests. This never counts as an external Gate B reference.",
    )
    parser.add_argument("--json", type=Path, help="Write machine-readable report")
    args = parser.parse_args()

    same_file = same_resolved_file(args.whoop_csv, args.reference_csv)
    if same_file and not args.allow_self_compare:
        report = {
            "status": "fail",
            "reason": "same_file_not_external_reference",
            "external_reference": False,
            "gate_b_pass": False,
            "tolerance_ms": args.tolerance_ms,
            "rmssd_delta_ms": None,
        }
        print_report_header(report)
        print("warning=WHOOP CSV and reference CSV are the same file; provide an independent RR/IBI recording or rerun with --allow-self-compare for parser smoke only.")
        if args.json:
            args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
            print(f"json={args.json}")
        return 1

    whoop_points = select_window(parse_capture_csv(args.whoop_csv), args.start_s, args.window_s)
    reference_points = select_window(parse_reference_csv(args.reference_csv), args.start_s, args.window_s)
    whoop = correct_and_score(whoop_points, args.window_s)
    reference = correct_and_score(reference_points, args.window_s)

    rmssd_delta = None
    if whoop.rmssd_ms is not None and reference.rmssd_ms is not None:
        rmssd_delta = abs(whoop.rmssd_ms - reference.rmssd_ms)
    metric_passed = bool(
        whoop.ready
        and reference.ready
        and rmssd_delta is not None
        and rmssd_delta <= args.tolerance_ms
    )
    external_reference = not same_file
    passed = metric_passed and external_reference
    parser_smoke_passed = bool(same_file and args.allow_self_compare and metric_passed)
    status = "pass" if passed else ("parser_smoke_pass" if parser_smoke_passed else "fail")
    if metric_passed and not external_reference:
        reason = "same_file_parser_smoke_only"
    else:
        reason = "ready" if passed else failure_reason(whoop, reference, rmssd_delta, args.tolerance_ms)
    report = {
        "status": status,
        "reason": reason,
        "external_reference": external_reference,
        "gate_b_pass": passed,
        "metric_passed": metric_passed,
        "tolerance_ms": args.tolerance_ms,
        "rmssd_delta_ms": round(rmssd_delta, 3) if rmssd_delta is not None else None,
        "whoop": asdict(whoop),
        "reference": asdict(reference),
    }

    print_report_header(report)
    print_metrics("whoop", whoop)
    print_metrics("reference", reference)
    if same_file:
        print("warning=self_compare_parser_smoke_only")
    if args.json:
        args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(f"json={args.json}")
    return 0 if passed or parser_smoke_passed else 1


def same_resolved_file(a: Path, b: Path) -> bool:
    try:
        return a.resolve(strict=True) == b.resolve(strict=True)
    except OSError:
        return a.absolute() == b.absolute()


def print_report_header(report: dict[str, object]) -> None:
    print(f"status={report['status']}")
    print(f"reason={report['reason']}")
    print(f"external_reference={int(bool(report.get('external_reference')))}")
    print(f"gate_b_pass={int(bool(report.get('gate_b_pass')))}")
    print(f"rmssd_delta_ms={report['rmssd_delta_ms']}")


def failure_reason(whoop: Metrics, reference: Metrics, delta: float | None, tolerance: float) -> str:
    if not whoop.ready:
        return f"whoop_{whoop.reason}"
    if not reference.ready:
        return f"reference_{reference.reason}"
    if delta is None:
        return "missing_rmssd"
    if delta > tolerance:
        return "rmssd_delta_over_tolerance"
    return "unknown"


def print_metrics(prefix: str, metrics: Metrics) -> None:
    print(
        f"{prefix}_ready={int(metrics.ready)} {prefix}_reason={metrics.reason} "
        f"{prefix}_raw={metrics.raw} {prefix}_kept={metrics.kept} "
        f"{prefix}_conf={metrics.confidence_percent} "
        f"{prefix}_duration_s={metrics.duration_s:.1f} "
        f"{prefix}_max_gap_s={metrics.max_gap_s:.3f} "
        f"{prefix}_rmssd_ms={fmt(metrics.rmssd_ms)} "
        f"{prefix}_sdnn_ms={fmt(metrics.sdnn_ms)} "
        f"{prefix}_pnn50={fmt(metrics.pnn50_percent)} "
        f"{prefix}_lnrmssd={fmt(metrics.lnrmssd)}"
    )


def fmt(value: float | None) -> str:
    return "learning" if value is None else f"{value:.3f}"


if __name__ == "__main__":
    sys.exit(main())
