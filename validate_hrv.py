#!/usr/bin/env python3
"""Replay WHOOP iOS RR captures and compare RMSSD against a reference file."""

from __future__ import annotations

import argparse
import csv
import json
import math
from dataclasses import dataclass
from pathlib import Path


MIN_RESPIRATORY_BPM = 6.0
MAX_RESPIRATORY_BPM = 30.0
MAX_RESPIRATORY_MATCH_DELTA_BPM = 0.05
ALLOWED_HRV_REASONS = {"window", "gap", "beats", "confidence", "ready"}


def parse_snapshot_value(value: str) -> dict[str, float]:
    parsed: dict[str, float] = {}
    for part in value.split():
        if "=" not in part:
            continue
        key, raw = part.split("=", 1)
        try:
            parsed_value = float(raw)
        except ValueError:
            continue
        if math.isfinite(parsed_value):
            parsed[key.lower()] = parsed_value
    if "lnrmssd" not in parsed and "ln" in parsed:
        parsed["lnrmssd"] = parsed["ln"]
    return parsed


def parse_key_values(value: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for part in value.split():
        if "=" not in part:
            continue
        key, raw = part.split("=", 1)
        parsed[key.lower()] = raw
    return parsed


def metric_status(tokens: dict[str, str], key: str) -> str | None:
    raw = tokens.get(key)
    if raw is None:
        return None
    return "numeric" if parse_float(raw) is not None else raw.lower()


def respiratory_value(tokens: dict[str, str]) -> float | None:
    return parse_float(tokens.get("resp"))


def respiratory_in_range(value: float | None) -> bool:
    return value is None or MIN_RESPIRATORY_BPM <= value <= MAX_RESPIRATORY_BPM


def readiness_reason(tokens: dict[str, str]) -> str | None:
    raw = tokens.get("reason")
    return raw.lower() if raw is not None else None


def parse_float(value: str | None) -> float | None:
    if value is None:
        return None
    try:
        parsed = float(value)
    except ValueError:
        return None
    return parsed if math.isfinite(parsed) else None


@dataclass
class RRReadResult:
    samples: list[tuple[float, float]]
    errors: list[dict[str, object]]
    metadata: dict[str, object] | None = None


def read_whoop_rr(path: Path) -> RRReadResult:
    samples: list[tuple[float, float]] = []
    errors: list[dict[str, object]] = []
    with path.open(newline="") as f:
        for line_number, row in enumerate(csv.DictReader(f), start=2):
            if row.get("kind") != "rr":
                continue
            elapsed = parse_float(row.get("elapsed_ms"))
            rr = parse_float(row.get("value"))
            if elapsed is None or rr is None:
                errors.append({
                    "line": line_number,
                    "kind": "rr",
                    "elapsed_ms": row.get("elapsed_ms"),
                    "value": row.get("value"),
                })
                continue
            t = elapsed / 1000.0
            samples.append((t, rr))
    return RRReadResult(samples, errors)


def read_whoop_hrv_snapshots(path: Path) -> list[dict[str, float]]:
    snapshots: list[dict[str, float]] = []
    with path.open(newline="") as f:
        for row in csv.DictReader(f):
            if row.get("kind") != "hrv":
                continue
            snapshot = parse_snapshot_value(row.get("value", ""))
            elapsed = parse_float(row.get("elapsed_ms"))
            if elapsed is not None:
                snapshot["row_elapsed_s"] = elapsed / 1000.0
            if snapshot:
                snapshots.append(snapshot)
    return snapshots


def read_whoop_hrv_snapshot_tokens(path: Path) -> list[dict[str, str]]:
    snapshots: list[dict[str, str]] = []
    with path.open(newline="") as f:
        for row in csv.DictReader(f):
            if row.get("kind") != "hrv":
                continue
            snapshot = parse_key_values(row.get("value", ""))
            if snapshot:
                snapshots.append(snapshot)
    return snapshots


def read_capture_summaries(path: Path) -> list[dict[str, float]]:
    summaries: list[dict[str, float]] = []
    with path.open(newline="") as f:
        for row in csv.DictReader(f):
            if row.get("kind") != "capture_summary":
                continue
            summary = parse_snapshot_value(row.get("value", ""))
            elapsed = parse_float(row.get("elapsed_ms"))
            if elapsed is not None:
                summary["row_elapsed_s"] = elapsed / 1000.0
            if summary:
                summaries.append(summary)
    return summaries


def read_capture_summary_tokens(path: Path) -> list[dict[str, str]]:
    summaries: list[dict[str, str]] = []
    with path.open(newline="") as f:
        for row in csv.DictReader(f):
            if row.get("kind") != "capture_summary":
                continue
            summary = parse_key_values(row.get("value", ""))
            if summary:
                summaries.append(summary)
    return summaries


def read_capture_metadata(path: Path) -> list[dict[str, str]]:
    metadata: list[dict[str, str]] = []
    with path.open(newline="") as f:
        for row in csv.DictReader(f):
            if row.get("kind") != "capture_meta":
                continue
            meta = parse_key_values(row.get("value", ""))
            if meta:
                metadata.append(meta)
    return metadata


def read_quality_markers(path: Path) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
    markers: list[dict[str, object]] = []
    errors: list[dict[str, object]] = []
    with path.open(newline="") as f:
        for line_number, row in enumerate(csv.DictReader(f), start=2):
            if row.get("kind") == "hrv_quality":
                elapsed = parse_float(row.get("elapsed_ms"))
                if elapsed is None:
                    errors.append({
                        "line": line_number,
                        "kind": "hrv_quality",
                        "elapsed_ms": row.get("elapsed_ms"),
                        "value": row.get("value", ""),
                    })
                    continue
                markers.append({
                    "elapsed_s": elapsed / 1000.0,
                    "value": row.get("value", ""),
                })
    return markers, errors


def read_reference_rr(path: Path) -> RRReadResult:
    samples: list[tuple[float, float]] = []
    errors: list[dict[str, object]] = []
    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames:
            return RRReadResult([], [], {"fieldnames": []})
        names = {name.lower().strip(): name for name in reader.fieldnames}
        rr_name = (
            names.get("rr_ms")
            or names.get("rr")
            or names.get("ibi")
            or names.get("ibi_ms")
            or names.get("interval_ms")
        )
        time_name = names.get("elapsed_ms") or names.get("time_s") or names.get("seconds") or names.get("t")
        metadata = {
            "fieldnames": reader.fieldnames,
            "rr_column": rr_name,
            "time_column": time_name,
            "timeline_source": "derived_from_rr" if time_name is None else "timestamp_column",
            "time_unit": (
                "derived_from_rr"
                if time_name is None
                else ("milliseconds" if time_name == names.get("elapsed_ms") else "seconds")
            ),
        }
        if rr_name is None:
            errors.append({
                "line": 1,
                "kind": "header",
                "failure": "missing_rr_column",
                "fieldnames": reader.fieldnames,
                "expected_columns": ["rr_ms", "rr", "ibi", "ibi_ms", "interval_ms"],
            })
            return RRReadResult(samples, errors, metadata)
        elapsed = 0.0
        for line_number, row in enumerate(reader, start=2):
            rr = parse_float(row.get(rr_name))
            if rr is None:
                errors.append({
                    "line": line_number,
                    "column": rr_name,
                    "value": row.get(rr_name),
                })
                continue
            if time_name:
                raw_t = parse_float(row.get(time_name))
                if raw_t is None:
                    errors.append({
                        "line": line_number,
                        "column": time_name,
                        "value": row.get(time_name),
                    })
                    continue
                t = raw_t / 1000.0 if time_name == names.get("elapsed_ms") else raw_t
            else:
                elapsed += rr / 1000.0
                t = elapsed
            samples.append((t, rr))
    return RRReadResult(samples, errors, metadata)


def corrected(samples: list[tuple[float, float]]) -> list[tuple[float, float]]:
    kept, interpolated, _ = correction_summary(samples)
    return metric_series(kept, interpolated)


def correction_summary(
    samples: list[tuple[float, float]],
) -> tuple[list[tuple[float, float]], list[tuple[float, float]], dict[str, int]]:
    kept: list[tuple[float, float]] = []
    annotated: list[tuple[float, float, bool]] = []
    artifacts = {
        "out_of_range": 0,
        "delta_over_20_percent": 0,
    }
    for t, rr in samples:
        if rr < 300 or rr > 2000:
            artifacts["out_of_range"] += 1
            annotated.append((t, rr, False))
            continue
        if kept:
            previous = kept[-1][1]
            if abs(rr - previous) / previous > 0.20:
                artifacts["delta_over_20_percent"] += 1
                annotated.append((t, rr, False))
                continue
        kept.append((t, rr))
        annotated.append((t, rr, True))
    return kept, interpolated_samples(annotated), artifacts


def interpolated_samples(samples: list[tuple[float, float, bool]]) -> list[tuple[float, float]]:
    interpolated: list[tuple[float, float]] = []
    for index, (t, _rr, accepted) in enumerate(samples):
        if accepted:
            continue
        previous = next((s for s in reversed(samples[:index]) if s[2]), None)
        following = next((s for s in samples[index + 1 :] if s[2]), None)
        if previous is None or following is None:
            continue
        prev_t, prev_rr, _ = previous
        next_t, next_rr, _ = following
        span = next_t - prev_t
        if span <= 0:
            continue
        fraction = (t - prev_t) / span
        interpolated.append((t, prev_rr + (next_rr - prev_rr) * fraction))
    return interpolated


def metric_series(
    kept: list[tuple[float, float]],
    interpolated: list[tuple[float, float]],
) -> list[tuple[float, float]]:
    return sorted(kept + interpolated, key=lambda sample: sample[0])


def final_window(samples: list[tuple[float, float]], window_s: float) -> list[tuple[float, float]]:
    if not samples:
        return []
    end_s = samples[-1][0]
    start_s = end_s - window_s
    return [(t, rr) for t, rr in samples if t >= start_s]


def metrics(samples: list[tuple[float, float]]) -> dict[str, float]:
    if len(samples) < 2:
        raise SystemExit("Need at least two corrected RR intervals")
    diffs = [samples[i][1] - samples[i - 1][1] for i in range(1, len(samples))]
    rmssd = math.sqrt(sum(d * d for d in diffs) / len(diffs))
    mean = sum(rr for _, rr in samples) / len(samples)
    sdnn = math.sqrt(sum((rr - mean) ** 2 for _, rr in samples) / (len(samples) - 1))
    pnn50 = sum(1 for d in diffs if abs(d) > 50) / len(diffs) * 100
    return {
        "rmssd": rmssd,
        "sdnn": sdnn,
        "pnn50": pnn50,
        "lnrmssd": math.log(rmssd) if rmssd > 0 else 0.0,
        "beats": float(len(samples)),
    }


def fmt(m: dict[str, float]) -> str:
    return (
        f"beats={m['beats']:.0f} rmssd={m['rmssd']:.1f} sdnn={m['sdnn']:.1f} "
        f"pnn50={m['pnn50']:.1f} lnrmssd={m['lnrmssd']:.2f}"
    )


def metric_value(snapshot: dict[str, float], key: str) -> float | None:
    if key == "lnrmssd":
        if "lnrmssd" in snapshot:
            return snapshot["lnrmssd"]
        return snapshot.get("ln")
    return snapshot.get(key)


def metric_deltas(
    observed: dict[str, float],
    expected: dict[str, float],
    keys: list[str],
) -> dict[str, float]:
    deltas: dict[str, float] = {}
    for key in keys:
        value = metric_value(observed, key)
        if value is not None:
            deltas[key] = abs(value - expected[key])
    return deltas


def missing_metrics(snapshot: dict[str, float], keys: list[str]) -> list[str]:
    return [key for key in keys if metric_value(snapshot, key) is None]


def artifact_value(snapshot: dict[str, float], key: str) -> float | None:
    return snapshot.get(f"rejected_{key}")


def artifact_deltas(
    observed: dict[str, float],
    expected: dict[str, int],
) -> dict[str, float]:
    deltas: dict[str, float] = {}
    for key, expected_value in expected.items():
        value = artifact_value(observed, key)
        if value is not None:
            deltas[f"rejected_{key}"] = abs(value - expected_value)
    return deltas


def missing_artifacts(snapshot: dict[str, float], keys: list[str]) -> list[str]:
    return [f"rejected_{key}" for key in keys if artifact_value(snapshot, key) is None]


def missing_fields(snapshot: dict[str, float], keys: list[str]) -> list[str]:
    return [key for key in keys if snapshot.get(key) is None]


def duration(samples: list[tuple[float, float]]) -> float:
    if len(samples) < 2:
        return 0
    return samples[-1][0] - samples[0][0]


def max_gap(samples: list[tuple[float, float]]) -> float:
    if len(samples) < 2:
        return 0
    return max(samples[index][0] - samples[index - 1][0] for index in range(1, len(samples)))


def first_time(samples: list[tuple[float, float]]) -> float | None:
    return samples[0][0] if samples else None


def last_time(samples: list[tuple[float, float]]) -> float | None:
    return samples[-1][0] if samples else None


def window_alignment(
    strap_samples: list[tuple[float, float]],
    reference_samples: list[tuple[float, float]],
) -> dict[str, float | None]:
    whoop_start = first_time(strap_samples)
    whoop_end = last_time(strap_samples)
    reference_start = first_time(reference_samples)
    reference_end = last_time(reference_samples)
    start_delta = (
        abs(whoop_start - reference_start)
        if whoop_start is not None and reference_start is not None
        else None
    )
    end_delta = (
        abs(whoop_end - reference_end)
        if whoop_end is not None and reference_end is not None
        else None
    )
    return {
        "whoop_window_start_s": whoop_start,
        "whoop_window_end_s": whoop_end,
        "reference_window_start_s": reference_start,
        "reference_window_end_s": reference_end,
        "window_start_delta_s": start_delta,
        "window_end_delta_s": end_delta,
    }


def first_nonmonotonic_index(samples: list[tuple[float, float]]) -> int | None:
    for index in range(1, len(samples)):
        if samples[index][0] <= samples[index - 1][0]:
            return index
    return None


def fail_nonmonotonic(
    label: str,
    samples: list[tuple[float, float]],
    report: dict[str, object],
    report_path: Path | None,
) -> bool:
    index = first_nonmonotonic_index(samples)
    if index is None:
        return False
    previous_t = samples[index - 1][0]
    current_t = samples[index][0]
    report["status"] = "fail"
    report["exit_code"] = 8
    report["failure"] = f"{label} RR timestamps are not strictly increasing"
    report["nonmonotonic_sample"] = {
        "label": label,
        "index": index,
        "previous_time_s": previous_t,
        "time_s": current_t,
    }
    print(
        f"FAIL: {label} RR timestamps are not strictly increasing "
        f"at sample {index}: {current_t:.3f}s <= {previous_t:.3f}s"
    )
    write_report(report_path, report)
    return True


def fail_parse_errors(
    label: str,
    errors: list[dict[str, object]],
    report: dict[str, object],
    report_path: Path | None,
) -> bool:
    if not errors:
        return False
    report["status"] = "fail"
    report["exit_code"] = 9
    report["failure"] = f"{label} RR CSV contains malformed rows"
    report["malformed_rows"] = {
        "label": label,
        "count": len(errors),
        "examples": errors[:5],
    }
    print(f"FAIL: {label} RR CSV contains {len(errors)} malformed row(s)")
    for error in errors[:5]:
        print(f"FAIL: {label} malformed row {error}")
    write_report(report_path, report)
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("whoop_csv", type=Path, help="iOS export with kind=rr rows")
    parser.add_argument("--reference", type=Path, help="Reference RR CSV from Polar/H10/etc.")
    parser.add_argument("--max-delta-ms", type=float, default=5.0)
    parser.add_argument("--max-sdnn-delta-ms", type=float, default=5.0)
    parser.add_argument("--max-pnn50-delta-pct", type=float, default=5.0)
    parser.add_argument("--max-lnrmssd-delta", type=float, default=0.2)
    parser.add_argument("--max-app-replay-delta-ms", type=float, default=0.6)
    parser.add_argument("--min-duration-s", type=float, default=300.0)
    parser.add_argument("--min-kept", type=int, default=240)
    parser.add_argument("--min-confidence", type=float, default=75.0)
    parser.add_argument("--max-rr-gap-s", type=float, default=3.0)
    parser.add_argument("--max-window-alignment-s", type=float, default=3.0)
    parser.add_argument("--report", type=Path, help="Write a JSON validation report.")
    return parser.parse_args()


def readiness_failures(
    label: str,
    raw: list[tuple[float, float]],
    kept: list[tuple[float, float]],
    coverage_duration_s: float,
    min_duration_s: float,
    min_kept: int,
    min_confidence: float,
    max_rr_gap_s: float,
) -> list[str]:
    failures: list[str] = []
    confidence = len(kept) / len(raw) * 100 if raw else 0
    largest_gap = max_gap(raw)
    if coverage_duration_s < min_duration_s:
        failures.append(f"{label} coverage {coverage_duration_s:.0f}s < {min_duration_s:.0f}s")
    if largest_gap > max_rr_gap_s:
        failures.append(f"{label} max RR gap {largest_gap:.1f}s > {max_rr_gap_s:.1f}s")
    if len(kept) < min_kept:
        failures.append(f"{label} corrected beats {len(kept)} < {min_kept}")
    if confidence < min_confidence:
        failures.append(f"{label} confidence {confidence:.0f}% < {min_confidence:.0f}%")
    return failures


def report_capture(
    raw: list[tuple[float, float]],
    kept: list[tuple[float, float]],
    interpolated: list[tuple[float, float]],
    coverage_duration_s: float,
    artifacts: dict[str, int],
    metric_values: dict[str, float] | None = None,
) -> dict[str, float | int | None]:
    confidence = len(kept) / len(raw) * 100 if raw else 0
    report: dict[str, float | int | None] = {
        "raw": len(raw),
        "kept": len(kept),
        "rejected": len(raw) - len(kept),
        "interpolated": len(interpolated),
        "rejected_out_of_range": artifacts["out_of_range"],
        "rejected_delta_over_20_percent": artifacts["delta_over_20_percent"],
        "confidence_percent": confidence,
        "coverage_duration_s": coverage_duration_s,
        "window_start_s": first_time(raw),
        "window_end_s": last_time(raw),
        "raw_duration_s": duration(raw),
        "max_raw_gap_s": max_gap(raw),
        "corrected_start_s": first_time(metric_series(kept, interpolated)),
        "corrected_end_s": last_time(metric_series(kept, interpolated)),
        "corrected_duration_s": duration(metric_series(kept, interpolated)),
    }
    if metric_values:
        report.update(metric_values)
    return report


def write_report(path: Path | None, report: dict[str, object]) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    report: dict[str, object] = {
        "whoop_csv": str(args.whoop_csv),
        "reference_csv": str(args.reference) if args.reference else None,
        "thresholds": {
            "max_delta_ms": args.max_delta_ms,
            "max_sdnn_delta_ms": args.max_sdnn_delta_ms,
            "max_pnn50_delta_pct": args.max_pnn50_delta_pct,
            "max_lnrmssd_delta": args.max_lnrmssd_delta,
            "max_app_replay_delta_ms": args.max_app_replay_delta_ms,
            "min_duration_s": args.min_duration_s,
            "validation_window_s": args.min_duration_s,
            "min_kept": args.min_kept,
            "min_confidence": args.min_confidence,
            "max_rr_gap_s": args.max_rr_gap_s,
            "max_window_alignment_s": args.max_window_alignment_s,
            "min_resp_bpm": MIN_RESPIRATORY_BPM,
            "max_resp_bpm": MAX_RESPIRATORY_BPM,
            "max_resp_match_delta_bpm": MAX_RESPIRATORY_MATCH_DELTA_BPM,
        },
        "checks": [],
    }
    whoop_read = read_whoop_rr(args.whoop_csv)
    raw_total = whoop_read.samples
    metadata = read_capture_metadata(args.whoop_csv)
    quality_markers, quality_marker_errors = read_quality_markers(args.whoop_csv)
    snapshots = read_whoop_hrv_snapshots(args.whoop_csv)
    snapshot_tokens = read_whoop_hrv_snapshot_tokens(args.whoop_csv)
    summaries = read_capture_summaries(args.whoop_csv)
    summary_tokens = read_capture_summary_tokens(args.whoop_csv)
    hrv_reasons = [
        reason for reason in (readiness_reason(tokens) for tokens in snapshot_tokens)
        if reason is not None
    ]
    invalid_reasons = sorted({reason for reason in hrv_reasons if reason not in ALLOWED_HRV_REASONS})
    report["hrv_readiness_reasons"] = sorted(set(hrv_reasons))
    report["last_hrv_readiness_reason"] = hrv_reasons[-1] if hrv_reasons else None
    if invalid_reasons:
        report["status"] = "fail"
        report["exit_code"] = 5
        report["failure"] = "app hrv snapshot has invalid readiness reason"
        report["invalid_readiness_reasons"] = invalid_reasons
        print("FAIL: app hrv snapshot has invalid reason=" + ", ".join(invalid_reasons))
        write_report(args.report, report)
        return 5
    if fail_parse_errors("WHOOP quality marker", quality_marker_errors, report, args.report):
        return 9
    if fail_parse_errors("WHOOP", whoop_read.errors, report, args.report):
        return 9
    if fail_nonmonotonic("WHOOP", raw_total, report, args.report):
        return 8
    raw = final_window(raw_total, args.min_duration_s)
    kept, interpolated, artifacts = correction_summary(raw)
    whoop_metric_samples = metric_series(kept, interpolated)
    capture_schema = parse_float(metadata[-1].get("schema")) if metadata else None
    report["capture_metadata_rows"] = metadata
    report["capture_context"] = metadata[0] if len(metadata) > 1 else None
    report["capture_contract"] = metadata[-1] if metadata else None
    report["capture_metadata"] = metadata[-1] if metadata else None
    report["quality_markers"] = quality_markers
    if capture_schema is None or capture_schema < 2:
        report["status"] = "fail"
        report["exit_code"] = 7
        report["failure"] = "capture schema is missing or stale"
        print("FAIL: capture schema is missing or stale; record a fresh schema=2 capture")
        write_report(args.report, report)
        return 7
    expected_correction = "drop_300_2000_delta20_interpolate"
    expected_confidence = "kept_over_raw"
    actual_correction = metadata[-1].get("correction")
    actual_confidence = metadata[-1].get("confidence")
    if actual_correction != expected_correction or actual_confidence != expected_confidence:
        report["status"] = "fail"
        report["exit_code"] = 7
        report["failure"] = "capture correction contract mismatch"
        print(
            "FAIL: capture correction contract mismatch "
            f"correction={actual_correction} confidence={actual_confidence}"
        )
        write_report(args.report, report)
        return 7
    clean_markers = [marker for marker in quality_markers if marker.get("value") == "clean_rr_window_started"]
    if not clean_markers:
        report["status"] = "fail"
        report["exit_code"] = 7
        report["failure"] = "clean RR window marker missing"
        print("FAIL: clean RR window marker missing; recapture with the current iOS app")
        write_report(args.report, report)
        return 7
    first_rr_s = first_time(raw_total)
    marker_before_rr = [
        marker for marker in clean_markers
        if first_rr_s is None or marker["elapsed_s"] <= first_rr_s
    ]
    if not marker_before_rr:
        report["status"] = "fail"
        report["exit_code"] = 7
        report["failure"] = "clean RR window marker occurs after first RR"
        print("FAIL: clean RR window marker occurs after first RR; recapture with the current iOS app")
        write_report(args.report, report)
        return 7
    if not raw_total:
        report["status"] = "fail"
        report["exit_code"] = 1
        report["failure"] = "no WHOOP kind=rr rows found"
        write_report(args.report, report)
        raise SystemExit(f"{args.whoop_csv}: no kind=rr rows found")
    whoop_coverage = min(args.min_duration_s, duration(raw_total))
    report["whoop_total"] = {
        "raw": len(raw_total),
        "raw_duration_s": duration(raw_total),
    }
    failures = readiness_failures(
        "WHOOP", raw, kept, whoop_coverage, args.min_duration_s, args.min_kept,
        args.min_confidence, args.max_rr_gap_s
    )
    if len(kept) < 2:
        failures.append("WHOOP corrected beats < 2, cannot compute HRV metrics")
    if failures:
        raw_duration = duration(raw)
        confidence = len(kept) / len(raw) * 100 if raw else 0
        report["whoop"] = report_capture(raw, kept, interpolated, whoop_coverage, artifacts)
        report["status"] = "fail"
        report["exit_code"] = 2
        report["failures"] = failures
        print(
            f"WHOOP window raw={len(raw)} kept={len(kept)} confidence={confidence:.0f}% "
            f"coverage={whoop_coverage:.0f}s raw_duration={raw_duration:.0f}s "
            f"corrected_duration={duration(metric_series(kept, interpolated)):.0f}s"
        )
        for failure in failures:
            print(f"FAIL: {failure}")
        write_report(args.report, report)
        return 2
    whoop = metrics(whoop_metric_samples)
    confidence = len(kept) / len(raw) * 100
    raw_duration = duration(raw)
    corrected_duration = duration(whoop_metric_samples)
    report["whoop"] = report_capture(raw, kept, interpolated, whoop_coverage, artifacts, whoop)
    print(
        f"WHOOP window raw={len(raw)} kept={len(kept)} confidence={confidence:.0f}% "
        f"coverage={whoop_coverage:.0f}s raw_duration={raw_duration:.0f}s "
        f"corrected_duration={corrected_duration:.0f}s {fmt(whoop)}"
    )
    ready_snapshots = [s for s in snapshots if s.get("ready") == 1]
    ready_snapshot_tokens = [
        tokens for tokens in snapshot_tokens
        if parse_float(tokens.get("ready")) == 1
    ]
    if ready_snapshots:
        app_snapshot = ready_snapshots[-1]
        app_snapshot_tokens = ready_snapshot_tokens[-1] if ready_snapshot_tokens else {}
        app_readiness_reason = readiness_reason(app_snapshot_tokens)
        report["app_ready_snapshot_reason"] = app_readiness_reason
        if app_readiness_reason is not None and app_readiness_reason != "ready":
            report["status"] = "fail"
            report["exit_code"] = 5
            report["failure"] = "ready app hrv snapshot has non-ready reason"
            print(f"FAIL: ready app hrv snapshot has reason={app_readiness_reason}")
            write_report(args.report, report)
            return 5
        app_rmssd = app_snapshot.get("rmssd")
        if app_rmssd is None:
            report["status"] = "fail"
            report["exit_code"] = 5
            report["failure"] = "ready app hrv snapshot is missing rmssd"
            print("FAIL: ready app hrv snapshot is missing rmssd")
            write_report(args.report, report)
            return 5
        missing_app = missing_metrics(app_snapshot, ["rmssd", "sdnn", "pnn50", "lnrmssd"])
        if missing_app:
            report["status"] = "fail"
            report["exit_code"] = 5
            report["failure"] = "ready app hrv snapshot is missing clinical metrics"
            report["missing_metrics"] = missing_app
            print("FAIL: ready app hrv snapshot is missing " + ", ".join(missing_app))
            write_report(args.report, report)
            return 5
        missing_app_counts = missing_fields(app_snapshot, ["raw", "kept", "conf", "window", "max_rr_gap_s"])
        if missing_app_counts:
            report["status"] = "fail"
            report["exit_code"] = 5
            report["failure"] = "ready app hrv snapshot is missing count/confidence/window fields"
            report["missing_count_fields"] = missing_app_counts
            print("FAIL: ready app hrv snapshot is missing " + ", ".join(missing_app_counts))
            write_report(args.report, report)
            return 5
        app_resp_status = metric_status(app_snapshot_tokens, "resp")
        app_resp_value = respiratory_value(app_snapshot_tokens)
        report["app_ready_resp_status"] = app_resp_status
        report["app_ready_resp_bpm"] = app_resp_value
        if app_resp_status not in ("numeric", "learning"):
            report["status"] = "fail"
            report["exit_code"] = 5
            report["failure"] = "ready app hrv snapshot is missing respiratory status"
            print("FAIL: ready app hrv snapshot is missing resp=learning or numeric resp")
            write_report(args.report, report)
            return 5
        if not respiratory_in_range(app_resp_value):
            report["status"] = "fail"
            report["exit_code"] = 5
            report["failure"] = "ready app hrv snapshot respiratory rate out of range"
            print(f"FAIL: ready app hrv snapshot resp={app_resp_value:.1f} outside 6-30/min")
            write_report(args.report, report)
            return 5
        app_deltas = metric_deltas(app_snapshot, whoop, ["rmssd", "sdnn", "pnn50", "lnrmssd"])
        app_delta = app_deltas.get("rmssd", abs(whoop["rmssd"] - app_rmssd))
        report["app_ready_snapshot"] = app_snapshot
        report["app_replay_metric_deltas"] = app_deltas
        report["app_replay_delta_rmssd"] = app_delta
        app_count_deltas = {
            "raw": abs(app_snapshot["raw"] - len(raw)),
            "kept": abs(app_snapshot["kept"] - len(kept)),
            "conf": abs(app_snapshot["conf"] - confidence),
            "window": abs(app_snapshot["window"] - whoop_coverage),
            "max_rr_gap_s": abs(app_snapshot["max_rr_gap_s"] - max_gap(raw)),
        }
        report["app_replay_count_deltas"] = app_count_deltas
        failed_app_counts = {
            key: value for key, value in app_count_deltas.items()
            if (value > 1 if key in ("conf", "window", "max_rr_gap_s") else value != 0)
        }
        if failed_app_counts:
            report["status"] = "fail"
            report["exit_code"] = 5
            report["failure"] = "ready app hrv snapshot count/confidence/window mismatch"
            print(
                "FAIL: ready app hrv snapshot count/confidence/window mismatch "
                + " ".join(f"{key}={value:.0f}" for key, value in sorted(failed_app_counts.items()))
            )
            write_report(args.report, report)
            return 5
        missing_app_artifacts = missing_artifacts(app_snapshot, ["out_of_range", "delta_over_20_percent"])
        if missing_app_artifacts:
            report["status"] = "fail"
            report["exit_code"] = 5
            report["failure"] = "ready app hrv snapshot is missing rejection counters"
            report["missing_rejection_counters"] = missing_app_artifacts
            print("FAIL: ready app hrv snapshot is missing " + ", ".join(missing_app_artifacts))
            write_report(args.report, report)
            return 5
        app_artifact_deltas = artifact_deltas(app_snapshot, artifacts)
        report["app_replay_rejection_deltas"] = app_artifact_deltas
        app_interpolated = app_snapshot.get("interpolated")
        if app_interpolated is None:
            report["status"] = "fail"
            report["exit_code"] = 5
            report["failure"] = "ready app hrv snapshot is missing interpolation count"
            print("FAIL: ready app hrv snapshot is missing interpolated")
            write_report(args.report, report)
            return 5
        if app_interpolated is not None:
            app_interpolated_delta = abs(app_interpolated - len(interpolated))
            report["app_replay_interpolated_delta"] = app_interpolated_delta
            if app_interpolated_delta != 0:
                report["status"] = "fail"
                report["exit_code"] = 5
                report["failure"] = "app exported interpolation count does not match replay"
                print(
                    "FAIL: app exported interpolated="
                    f"{int(app_interpolated)} but replay interpolated={len(interpolated)}"
                )
                write_report(args.report, report)
                return 5
        print(
            "app_replay_deltas "
            + " ".join(f"{key}={value:.2f}" for key, value in sorted(app_deltas.items()))
        )
        failed_app_metrics = {
            key: value for key, value in app_deltas.items()
            if value > args.max_app_replay_delta_ms
        }
        if failed_app_metrics:
            report["status"] = "fail"
            report["exit_code"] = 5
            report["failure"] = "app exported HRV does not match replay"
            print(
                "FAIL: app exported HRV does not match replay "
                f"(>{args.max_app_replay_delta_ms:.1f} tolerance)"
            )
            write_report(args.report, report)
            return 5
        failed_app_artifacts = {
            key: value for key, value in app_artifact_deltas.items()
            if value != 0
        }
        if failed_app_artifacts:
            report["status"] = "fail"
            report["exit_code"] = 5
            report["failure"] = "app exported rejection counters do not match replay"
            print(
                "FAIL: app exported rejection counters do not match replay "
                + " ".join(f"{key}={value:.0f}" for key, value in sorted(failed_app_artifacts.items()))
            )
            write_report(args.report, report)
            return 5
    elif args.reference is not None:
        report["status"] = "fail"
        report["exit_code"] = 5
        report["failure"] = "no ready app hrv snapshot found"
        print("FAIL: no ready app hrv snapshot found; cannot trust reference comparison")
        write_report(args.report, report)
        return 5
    else:
        print("WARN: no ready app hrv snapshot found; replay used RR rows only")
    if args.reference is None:
        report["status"] = "replay_ok"
        report["exit_code"] = 0
        report["accuracy_comparison"] = "skipped"
        print("REPLAY OK: no reference supplied, so accuracy comparison was skipped")
        write_report(args.report, report)
        return 0

    if not summaries:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "no capture_summary row found"
        print("FAIL: no capture_summary row found; stop the iOS capture before exporting")
        write_report(args.report, report)
        return 6
    final_summary = summaries[-1]
    final_summary_tokens = summary_tokens[-1] if summary_tokens else {}
    summary_readiness_reason = readiness_reason(final_summary_tokens)
    report["capture_summary"] = final_summary
    report["capture_summary_reason"] = summary_readiness_reason
    if summary_readiness_reason is not None and summary_readiness_reason not in ALLOWED_HRV_REASONS:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary has invalid readiness reason"
        print(f"FAIL: capture_summary has reason={summary_readiness_reason}")
        write_report(args.report, report)
        return 6
    if summary_readiness_reason is not None and app_readiness_reason is not None and summary_readiness_reason != app_readiness_reason:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary readiness reason does not match ready app snapshot"
        print(
            "FAIL: capture_summary reason "
            f"{summary_readiness_reason} != app hrv reason {app_readiness_reason}"
        )
        write_report(args.report, report)
        return 6
    report["app_ready_snapshot_row_elapsed_s"] = app_snapshot.get("row_elapsed_s")
    report["capture_summary_row_elapsed_s"] = final_summary.get("row_elapsed_s")
    report["whoop_last_rr_row_elapsed_s"] = last_time(raw_total)
    report["whoop_last_hrv_row_elapsed_s"] = snapshots[-1].get("row_elapsed_s") if snapshots else None
    summary_after_ready = (
        final_summary.get("row_elapsed_s") is not None
        and app_snapshot.get("row_elapsed_s") is not None
        and final_summary["row_elapsed_s"] >= app_snapshot["row_elapsed_s"]
    )
    report["capture_summary_after_ready_snapshot"] = summary_after_ready
    if not summary_after_ready:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary occurs before ready app hrv snapshot"
        print("FAIL: capture_summary row does not occur after the ready app hrv snapshot")
        write_report(args.report, report)
        return 6
    summary_after_last_rr = (
        final_summary.get("row_elapsed_s") is not None
        and last_time(raw_total) is not None
        and final_summary["row_elapsed_s"] >= last_time(raw_total)
    )
    report["capture_summary_after_last_rr"] = summary_after_last_rr
    if not summary_after_last_rr:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary occurs before final RR row"
        print("FAIL: capture_summary row occurs before the final RR row")
        write_report(args.report, report)
        return 6
    summary_after_last_hrv = (
        final_summary.get("row_elapsed_s") is not None
        and report["whoop_last_hrv_row_elapsed_s"] is not None
        and final_summary["row_elapsed_s"] >= report["whoop_last_hrv_row_elapsed_s"]
    )
    report["capture_summary_after_last_hrv"] = summary_after_last_hrv
    if not summary_after_last_hrv:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary occurs before final HRV row"
        print("FAIL: capture_summary row occurs before the final HRV row")
        write_report(args.report, report)
        return 6
    if final_summary.get("ready") != 1:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary is not validation-ready"
        print("FAIL: capture_summary is not validation-ready")
        write_report(args.report, report)
        return 6
    missing_summary_counts = missing_fields(final_summary, ["elapsed", "raw", "kept", "conf", "window", "max_rr_gap_s"])
    if missing_summary_counts:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary is missing count/confidence/window fields"
        report["missing_count_fields"] = missing_summary_counts
        print("FAIL: capture_summary is missing " + ", ".join(missing_summary_counts))
        write_report(args.report, report)
        return 6
    for key, expected in (("raw", len(raw)), ("kept", len(kept))):
        value = final_summary[key]
        if int(value) != expected:
            report["status"] = "fail"
            report["exit_code"] = 6
            report["failure"] = f"capture_summary {key} mismatch"
            print(f"FAIL: capture_summary {key}={int(value)} but replay {key}={expected}")
            write_report(args.report, report)
            return 6
    summary_conf = final_summary["conf"]
    if abs(summary_conf - confidence) > 1:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary confidence mismatch"
        print(f"FAIL: capture_summary conf={summary_conf:.0f}% but replay conf={confidence:.0f}%")
        write_report(args.report, report)
        return 6
    summary_window = final_summary["window"]
    if abs(summary_window - whoop_coverage) > 1:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary window mismatch"
        print(f"FAIL: capture_summary window={summary_window:.0f}s but replay coverage={whoop_coverage:.0f}s")
        write_report(args.report, report)
        return 6
    summary_max_gap = final_summary["max_rr_gap_s"]
    replay_max_gap = max_gap(raw)
    report["capture_summary_max_rr_gap_delta_s"] = abs(summary_max_gap - replay_max_gap)
    if report["capture_summary_max_rr_gap_delta_s"] > 1:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary max RR gap mismatch"
        print(f"FAIL: capture_summary max_rr_gap_s={summary_max_gap:.1f}s but replay max gap={replay_max_gap:.1f}s")
        write_report(args.report, report)
        return 6
    summary_elapsed = final_summary["elapsed"]
    if summary_elapsed + 1 < summary_window or summary_elapsed + 1 < args.min_duration_s:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary elapsed is shorter than validation window"
        print(
            f"FAIL: capture_summary elapsed={summary_elapsed:.0f}s "
            f"window={summary_window:.0f}s min={args.min_duration_s:.0f}s"
        )
        write_report(args.report, report)
        return 6
    missing_summary_artifacts = missing_artifacts(final_summary, ["out_of_range", "delta_over_20_percent"])
    if missing_summary_artifacts:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary is missing rejection counters"
        report["missing_rejection_counters"] = missing_summary_artifacts
        print("FAIL: capture_summary is missing " + ", ".join(missing_summary_artifacts))
        write_report(args.report, report)
        return 6
    summary_artifact_deltas = artifact_deltas(final_summary, artifacts)
    report["capture_summary_rejection_deltas"] = summary_artifact_deltas
    summary_interpolated = final_summary.get("interpolated")
    if summary_interpolated is None:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary is missing interpolation count"
        print("FAIL: capture_summary is missing interpolated")
        write_report(args.report, report)
        return 6
    summary_interpolated_delta = abs(summary_interpolated - len(interpolated))
    report["capture_summary_interpolated_delta"] = summary_interpolated_delta
    if summary_interpolated_delta != 0:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary interpolation count mismatch"
        print(
            "FAIL: capture_summary interpolated="
            f"{int(summary_interpolated)} but replay interpolated={len(interpolated)}"
        )
        write_report(args.report, report)
        return 6
    failed_summary_artifacts = {
        key: value for key, value in summary_artifact_deltas.items()
        if value != 0
    }
    if failed_summary_artifacts:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary rejection counter mismatch"
        print(
            "FAIL: capture_summary rejection counters do not match replay "
            + " ".join(f"{key}={value:.0f}" for key, value in sorted(failed_summary_artifacts.items()))
        )
        write_report(args.report, report)
        return 6
    summary_deltas = metric_deltas(final_summary, whoop, ["rmssd", "sdnn", "pnn50", "lnrmssd"])
    missing_summary = missing_metrics(final_summary, ["rmssd", "sdnn", "pnn50", "lnrmssd"])
    if missing_summary:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary is missing clinical metrics"
        report["missing_metrics"] = missing_summary
        print("FAIL: capture_summary is missing " + ", ".join(missing_summary))
        write_report(args.report, report)
        return 6
    summary_resp_status = metric_status(final_summary_tokens, "resp")
    summary_resp_value = respiratory_value(final_summary_tokens)
    report["capture_summary_resp_status"] = summary_resp_status
    report["capture_summary_resp_bpm"] = summary_resp_value
    if summary_resp_status not in ("numeric", "learning"):
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary is missing respiratory status"
        print("FAIL: capture_summary is missing resp=learning or numeric resp")
        write_report(args.report, report)
        return 6
    if not respiratory_in_range(summary_resp_value):
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary respiratory rate out of range"
        print(f"FAIL: capture_summary resp={summary_resp_value:.1f} outside 6-30/min")
        write_report(args.report, report)
        return 6
    resp_status_match = summary_resp_status == app_resp_status
    report["resp_status_match"] = resp_status_match
    resp_bpm_delta = (
        abs(summary_resp_value - app_resp_value)
        if summary_resp_value is not None and app_resp_value is not None
        else None
    )
    report["resp_bpm_delta"] = resp_bpm_delta
    if not resp_status_match:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary respiratory status does not match ready app snapshot"
        print(
            "FAIL: capture_summary respiratory status "
            f"{summary_resp_status} does not match ready app hrv {app_resp_status}"
        )
        write_report(args.report, report)
        return 6
    if resp_bpm_delta is not None and resp_bpm_delta > MAX_RESPIRATORY_MATCH_DELTA_BPM:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary respiratory rate does not match ready app snapshot"
        print(
            "FAIL: capture_summary resp delta "
            f"{resp_bpm_delta:.2f}/min > {MAX_RESPIRATORY_MATCH_DELTA_BPM:.2f}/min"
        )
        write_report(args.report, report)
        return 6
    report["capture_summary_metric_deltas"] = summary_deltas
    failed_summary_metrics = {
        key: value for key, value in summary_deltas.items()
        if value > args.max_app_replay_delta_ms
    }
    if failed_summary_metrics:
        report["status"] = "fail"
        report["exit_code"] = 6
        report["failure"] = "capture_summary metric mismatch"
        print(
            "FAIL: capture_summary metrics do not match replay "
            + " ".join(f"{key}={value:.2f}" for key, value in sorted(failed_summary_metrics.items()))
        )
        write_report(args.report, report)
        return 6

    reference_read = read_reference_rr(args.reference)
    ref_raw_total = reference_read.samples
    report["reference_metadata"] = reference_read.metadata
    if fail_parse_errors("REF", reference_read.errors, report, args.report):
        return 9
    if fail_nonmonotonic("REF", ref_raw_total, report, args.report):
        return 8
    ref_raw = final_window(ref_raw_total, args.min_duration_s)
    ref_kept, ref_interpolated, ref_artifacts = correction_summary(ref_raw)
    ref_metric_samples = metric_series(ref_kept, ref_interpolated)
    if not ref_raw_total:
        report["status"] = "fail"
        report["exit_code"] = 1
        report["failure"] = "no reference RR rows found"
        write_report(args.report, report)
        raise SystemExit(f"{args.reference}: no reference RR rows found")
    ref_coverage = min(args.min_duration_s, duration(ref_raw_total))
    report["reference_total"] = {
        "raw": len(ref_raw_total),
        "raw_duration_s": duration(ref_raw_total),
    }
    failures = readiness_failures(
        "REF", ref_raw, ref_kept, ref_coverage, args.min_duration_s, args.min_kept,
        args.min_confidence, args.max_rr_gap_s
    )
    if len(ref_kept) < 2:
        failures.append("REF corrected beats < 2, cannot compute HRV metrics")
    if failures:
        report["reference"] = report_capture(ref_raw, ref_kept, ref_interpolated, ref_coverage, ref_artifacts)
        report["status"] = "fail"
        report["exit_code"] = 4
        report["failures"] = failures
        print(
            f"REF   window raw={len(ref_raw)} kept={len(ref_kept)} "
            f"confidence={len(ref_kept)/len(ref_raw)*100:.0f}% "
            f"coverage={ref_coverage:.0f}s raw_duration={duration(ref_raw):.0f}s "
            f"corrected_duration={duration(metric_series(ref_kept, ref_interpolated)):.0f}s"
        )
        for failure in failures:
            print(f"FAIL: {failure}")
        write_report(args.report, report)
        return 4
    ref = metrics(ref_metric_samples)
    delta = abs(whoop["rmssd"] - ref["rmssd"])
    reference_deltas = metric_deltas(whoop, ref, ["rmssd", "sdnn", "pnn50", "lnrmssd"])
    reference_metric_tolerances = {
        "rmssd": args.max_delta_ms,
        "sdnn": args.max_sdnn_delta_ms,
        "pnn50": args.max_pnn50_delta_pct,
        "lnrmssd": args.max_lnrmssd_delta,
    }
    reference_metric_within_tolerance = {
        key: reference_deltas.get(key, math.inf) <= tolerance
        for key, tolerance in reference_metric_tolerances.items()
    }
    report["reference"] = report_capture(ref_raw, ref_kept, ref_interpolated, ref_coverage, ref_artifacts, ref)
    alignment = window_alignment(raw, ref_raw)
    report["window_alignment"] = alignment
    report["delta_rmssd_ms"] = delta
    report["reference_metric_deltas"] = reference_deltas
    report["reference_metric_tolerances"] = reference_metric_tolerances
    report["reference_metric_within_tolerance"] = reference_metric_within_tolerance
    report["rmssd_within_tolerance"] = delta <= args.max_delta_ms
    print(
        f"REF   window raw={len(ref_raw)} kept={len(ref_kept)} confidence={len(ref_kept)/len(ref_raw)*100:.0f}% "
        f"coverage={ref_coverage:.0f}s raw_duration={duration(ref_raw):.0f}s "
        f"corrected_duration={duration(ref_metric_samples):.0f}s {fmt(ref)}"
    )
    print(
        "reference_deltas "
        + " ".join(f"{key}={value:.2f}" for key, value in sorted(reference_deltas.items()))
    )
    alignment_failures = []
    for key in ("window_start_delta_s", "window_end_delta_s"):
        value = alignment.get(key)
        if value is None or value > args.max_window_alignment_s:
            alignment_failures.append(key)
    if alignment_failures:
        report["status"] = "fail"
        report["exit_code"] = 3
        report["failure"] = "reference final window is not time-aligned"
        report["alignment_failures"] = alignment_failures
        print(
            "FAIL: reference final window is not time-aligned "
            f"start_delta={alignment.get('window_start_delta_s')}s "
            f"end_delta={alignment.get('window_end_delta_s')}s "
            f"max={args.max_window_alignment_s:.1f}s"
        )
        write_report(args.report, report)
        return 3
    failed_reference_metrics = {
        key: reference_deltas[key]
        for key, within in reference_metric_within_tolerance.items()
        if not within and key in reference_deltas
    }
    if failed_reference_metrics:
        report["status"] = "fail"
        report["exit_code"] = 3
        report["failure"] = "reference HRV metric delta exceeds tolerance"
        print(
            "FAIL: reference HRV metric delta exceeds tolerance "
            + " ".join(
                f"{key}={value:.2f}>{reference_metric_tolerances[key]:.2f}"
                for key, value in sorted(failed_reference_metrics.items())
            )
        )
        write_report(args.report, report)
        return 3
    report["status"] = "pass"
    report["exit_code"] = 0
    print("PASS: clinical HRV metrics are within reference tolerances")
    write_report(args.report, report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
