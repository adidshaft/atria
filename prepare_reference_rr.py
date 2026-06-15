#!/usr/bin/env python3
"""Normalize external RR/IBI exports for the Gate B HRV reference validator."""

from __future__ import annotations

import argparse
import csv
import math
from pathlib import Path


RR_COLUMNS = [
    "rr_ms",
    "rr",
    "rr interval",
    "rr_interval",
    "rr interval ms",
    "rr_interval_ms",
    "rr interval [ms]",
    "r-r interval",
    "r-r interval ms",
    "r-r interval [ms]",
    "ibi",
    "ibi_ms",
    "ibi [ms]",
    "interval",
    "interval_ms",
]
TIME_MS_COLUMNS = [
    "elapsed_ms",
    "time_ms",
    "timestamp_ms",
]
TIME_S_COLUMNS = [
    "time_s",
    "seconds",
    "second",
    "elapsed_s",
    "timestamp_s",
    "timestamp",
    "time",
    "t",
]


def normalized_name(name: str) -> str:
    return " ".join(name.strip().lower().replace("(", " ").replace(")", " ").split())


def parse_float(value: str | None) -> float | None:
    if value is None:
        return None
    cleaned = value.strip()
    if not cleaned:
        return None
    try:
        parsed = float(cleaned)
    except ValueError:
        return None
    return parsed if math.isfinite(parsed) else None


def find_column(fieldnames: list[str], candidates: list[str]) -> str | None:
    normalized = {normalized_name(name): name for name in fieldnames}
    for candidate in candidates:
        match = normalized.get(normalized_name(candidate))
        if match is not None:
            return match
    return None


def read_samples(path: Path) -> tuple[list[tuple[float, float]], dict[str, str | None]]:
    samples: list[tuple[float, float]] = []
    with path.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames:
            raise SystemExit("Reference export has no CSV header")
        rr_column = find_column(reader.fieldnames, RR_COLUMNS)
        time_ms_column = find_column(reader.fieldnames, TIME_MS_COLUMNS)
        time_s_column = find_column(reader.fieldnames, TIME_S_COLUMNS)
        time_column = time_ms_column or time_s_column
        metadata = {
            "rr_column": rr_column,
            "time_column": time_column,
            "time_unit": "milliseconds" if time_ms_column else ("seconds" if time_s_column else None),
            "timeline_source": "timestamp_column" if time_column else "derived_from_rr",
        }
        if rr_column is None:
            raise SystemExit(
                "Reference export is missing an RR/IBI column. "
                f"Accepted names: {', '.join(RR_COLUMNS)}"
            )
        elapsed_s = 0.0
        previous_t: float | None = None
        for line_number, row in enumerate(reader, start=2):
            rr = parse_float(row.get(rr_column))
            if rr is None:
                raise SystemExit(f"Malformed RR value on line {line_number}: {row.get(rr_column)!r}")
            if time_column:
                raw_t = parse_float(row.get(time_column))
                if raw_t is None:
                    raise SystemExit(f"Malformed timestamp on line {line_number}: {row.get(time_column)!r}")
                t = raw_t / 1000.0 if time_ms_column else raw_t
            else:
                t = elapsed_s
                elapsed_s += rr / 1000.0
            if previous_t is not None and t <= previous_t:
                raise SystemExit(
                    "Reference timestamps must be strictly increasing: "
                    f"line {line_number} has {t:.3f}s after {previous_t:.3f}s"
                )
            previous_t = t
            samples.append((t, rr))
    if not samples:
        raise SystemExit("Reference export contains no RR rows")
    return samples, metadata


def windowed_samples(
    samples: list[tuple[float, float]],
    window_s: float | None,
    window_end_s: float | None,
    trim_start_s: float | None,
    trim_end_s: float | None,
) -> list[tuple[float, float]]:
    selected = samples
    if trim_start_s is not None:
        selected = [(t, rr) for t, rr in selected if t >= trim_start_s]
    if trim_end_s is not None:
        selected = [(t, rr) for t, rr in selected if t <= trim_end_s]
    if window_s is not None:
        end_s = window_end_s if window_end_s is not None else selected[-1][0]
        start_s = end_s - window_s
        selected = [(t, rr) for t, rr in selected if start_s <= t <= end_s]
    if not selected:
        raise SystemExit("Reference window contains no RR rows after trimming")
    return selected


def write_output(path: Path, samples: list[tuple[float, float]], reset_time: bool) -> None:
    start_s = samples[0][0] if reset_time else 0.0
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f, lineterminator="\n")
        writer.writerow(["elapsed_ms", "rr_ms"])
        for t, rr in samples:
            elapsed_ms = int(round((t - start_s) * 1000.0))
            writer.writerow([elapsed_ms, f"{rr:.3f}".rstrip("0").rstrip(".")])


def summary(samples: list[tuple[float, float]]) -> dict[str, float]:
    rrs = [rr for _, rr in samples]
    return {
        "rows": float(len(samples)),
        "duration_s": samples[-1][0] - samples[0][0] if len(samples) > 1 else 0.0,
        "min_rr_ms": min(rrs),
        "max_rr_ms": max(rrs),
        "mean_rr_ms": sum(rrs) / len(rrs),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input_csv", type=Path)
    parser.add_argument("output_csv", type=Path)
    parser.add_argument("--window-s", type=float, help="Keep only the final/matched window length.")
    parser.add_argument("--window-end-s", type=float, help="End time for --window-s; defaults to last row.")
    parser.add_argument("--trim-start-s", type=float, help="Drop rows before this source timestamp.")
    parser.add_argument("--trim-end-s", type=float, help="Drop rows after this source timestamp.")
    parser.add_argument(
        "--keep-source-time",
        action="store_true",
        help="Keep the source elapsed timestamp instead of resetting the output to 0.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.window_end_s is not None and args.window_s is None:
        raise SystemExit("--window-end-s requires --window-s")
    if args.window_s is not None and args.window_s <= 0:
        raise SystemExit("--window-s must be positive")
    if args.trim_start_s is not None and args.trim_end_s is not None and args.trim_end_s < args.trim_start_s:
        raise SystemExit("--trim-end-s must be >= --trim-start-s")

    samples, metadata = read_samples(args.input_csv)
    selected = windowed_samples(samples, args.window_s, args.window_end_s, args.trim_start_s, args.trim_end_s)
    write_output(args.output_csv, selected, reset_time=not args.keep_source_time)
    stats = summary(selected)
    print(
        "Reference RR prepared: "
        f"rows={int(stats['rows'])} duration={stats['duration_s']:.1f}s "
        f"rr_column={metadata['rr_column']} time_column={metadata['time_column'] or ''} "
        f"timeline={metadata['timeline_source']} "
        f"min={stats['min_rr_ms']:.1f} max={stats['max_rr_ms']:.1f} mean={stats['mean_rr_ms']:.1f}"
    )
    print(f"Wrote {args.output_csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
