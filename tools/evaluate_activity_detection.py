#!/usr/bin/env python3
"""Batch research-only strap-gait evaluation for explicitly labelled windows.

This tool never promotes an activity decoder. It invokes the authoritative Swift
replay tool for each exact window, requires complete scoreable motion evidence,
and reports only whether the conservative gait challenger emitted a sustained
walking shadow. Production activity labels remain unchanged.
"""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
from pathlib import Path
from typing import Any


SUPPORTED_ACTIVITIES = {
    "walk",
    "run",
    "dance",
    "strength",
    "cycle",
    "rest",
    "handling",
    "typing",
    "driving",
}
LOCOMOTION_ACTIVITIES = {"walk", "run"}
MINIMUM_QUALIFICATION_WINDOW_MS = 34_000
REQUIRED_GAIT_FIELDS = {
    "gait_shadow_overlapping_windows",
    "window_s",
    "stride_s",
    "accepted_overlapping_windows",
    "accepted_ratio",
    "longest_accepted_stride_run_s",
    "accepted_cadence_median_spm",
    "accepted_periodicity_median",
    "accepted_consistency_median",
    "accepted_gyro_median",
    "activity_decoder_validated",
    "production_label",
}


class EvaluationError(ValueError):
    pass


def strict_integer(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise EvaluationError(f"{field} must be an integer")
    return value


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvaluationError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_manifest(path: Path) -> list[dict[str, Any]]:
    try:
        document = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except (OSError, UnicodeError, json.JSONDecodeError, EvaluationError) as exc:
        raise EvaluationError(f"unable to read manifest: {type(exc).__name__}: {exc}") from exc
    if not isinstance(document, dict) or set(document) != {"version", "windows"}:
        raise EvaluationError("manifest must contain exactly version and windows")
    if strict_integer(document["version"], "version") != 1:
        raise EvaluationError("unsupported manifest version")
    windows = document["windows"]
    if not isinstance(windows, list) or not windows:
        raise EvaluationError("windows must be a non-empty array")

    validated: list[dict[str, Any]] = []
    labels: set[str] = set()
    previous_end: int | None = None
    for index, raw in enumerate(windows):
        if not isinstance(raw, dict):
            raise EvaluationError(f"windows[{index}] must be an object")
        allowed = {"label", "activity", "start_ms", "end_ms"}
        if not {"label", "activity", "start_ms", "end_ms"}.issubset(raw) or not set(raw) <= allowed:
            raise EvaluationError(f"windows[{index}] has missing or unknown fields")
        label = raw["label"]
        activity = raw["activity"]
        if not isinstance(label, str) or not label.strip() or label != label.strip():
            raise EvaluationError(f"windows[{index}].label must be a trimmed non-empty string")
        if label in labels:
            raise EvaluationError(f"duplicate window label: {label}")
        labels.add(label)
        if not isinstance(activity, str) or activity not in SUPPORTED_ACTIVITIES:
            raise EvaluationError(f"unsupported activity for {label}: {activity!r}")
        start_ms = strict_integer(raw["start_ms"], f"{label}.start_ms")
        end_ms = strict_integer(raw["end_ms"], f"{label}.end_ms")
        if start_ms < 0 or end_ms <= start_ms:
            raise EvaluationError(f"invalid chronology for {label}")
        if end_ms - start_ms < MINIMUM_QUALIFICATION_WINDOW_MS:
            raise EvaluationError(
                f"window must span at least 34 seconds to exercise the gait gate: {label}"
            )
        if previous_end is not None and start_ms < previous_end:
            raise EvaluationError(f"windows must be chronological and non-overlapping: {label}")
        previous_end = end_ms
        validated.append(
            {
                "label": label,
                "activity": activity,
                "start_ms": start_ms,
                "end_ms": end_ms,
            }
        )

    if not any(window["activity"] in LOCOMOTION_ACTIVITIES for window in validated):
        raise EvaluationError("manifest requires at least one labelled walk or run")
    if not any(window["activity"] not in LOCOMOTION_ACTIVITIES for window in validated):
        raise EvaluationError("manifest requires at least one labelled confuser/control")
    return validated


def parse_key_value_line(line: str, label: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for token in line.split():
        if "=" not in token:
            raise EvaluationError(f"{label} contains a non-key-value token")
        key, value = token.split("=", 1)
        if not key or not value or key in fields:
            raise EvaluationError(f"{label} contains an invalid or duplicate field: {key}")
        fields[key] = value
    return fields


def parse_replay_output(output: str) -> dict[str, str]:
    lines = output.splitlines()
    coverage_lines = [line for line in lines if line.startswith("expected_frames=")]
    gait_lines = [line for line in lines if line.startswith("gait_shadow_overlapping_windows=")]
    if len(coverage_lines) != 1 or len(gait_lines) != 1:
        raise EvaluationError("replay output must contain exactly one coverage and gait summary")
    coverage = parse_key_value_line(coverage_lines[0], "coverage summary")
    fields = parse_key_value_line(gait_lines[0], "gait summary")
    if set(coverage) != {
        "expected_frames", "missing_frames", "coverage_pct", "continuity_breaks",
        "isolated_missing_seconds", "long_breaks", "longest_contiguous_seconds",
        "evidence_scoreable",
    }:
        raise EvaluationError("coverage summary fields do not match the replay contract")
    missing = sorted(REQUIRED_GAIT_FIELDS - fields.keys())
    if missing:
        raise EvaluationError("replay output missing fields: " + ",".join(missing))
    if set(fields) != REQUIRED_GAIT_FIELDS:
        raise EvaluationError("gait summary fields do not match the replay contract")
    fields["evidence_scoreable"] = coverage["evidence_scoreable"]
    if fields["activity_decoder_validated"] != "0" or fields["production_label"] != "none":
        raise EvaluationError("replay violated research-only activity contract")
    if fields["evidence_scoreable"] not in {"0", "1"}:
        raise EvaluationError("replay evidence_scoreable is not boolean")
    expected_frames = replay_integer(coverage, "expected_frames")
    missing_frames = replay_integer(coverage, "missing_frames")
    coverage_percent = finite_number(coverage, "coverage_pct")
    continuity_breaks = replay_integer(coverage, "continuity_breaks")
    isolated_missing = replay_integer(coverage, "isolated_missing_seconds")
    long_breaks = replay_integer(coverage, "long_breaks")
    longest_contiguous = replay_integer(coverage, "longest_contiguous_seconds")
    if fields["evidence_scoreable"] == "1" and (
        expected_frames < 34
        or missing_frames != 0
        or abs(coverage_percent - 100) > 0.000_1
        or continuity_breaks != 0
        or isolated_missing != 0
        or long_breaks != 0
        or longest_contiguous != expected_frames
    ):
        raise EvaluationError("scoreable coverage summary is internally inconsistent")
    total = replay_integer(fields, "gait_shadow_overlapping_windows")
    accepted = replay_integer(fields, "accepted_overlapping_windows")
    longest = replay_integer(fields, "longest_accepted_stride_run_s")
    if replay_integer(fields, "window_s") != 5 or replay_integer(fields, "stride_s") != 1:
        raise EvaluationError("unsupported gait window/stride contract")
    if fields["evidence_scoreable"] == "1" and total != expected_frames - 4:
        raise EvaluationError("gait window count does not match complete replay coverage")
    if accepted > total or longest > accepted:
        raise EvaluationError("gait summary counts are inconsistent")
    ratio = finite_number(fields, "accepted_ratio")
    expected_ratio = accepted / total if total else 0.0
    if not 0 <= ratio <= 1 or abs(ratio - expected_ratio) > 0.000_1:
        raise EvaluationError("gait accepted ratio is inconsistent")
    cadence = finite_number(fields, "accepted_cadence_median_spm")
    periodicity = finite_number(fields, "accepted_periodicity_median")
    consistency = finite_number(fields, "accepted_consistency_median")
    gyro = fields["accepted_gyro_median"]
    if accepted == 0:
        if (cadence, periodicity, consistency) != (-1.0, -1.0, -1.0) or gyro != "unavailable":
            raise EvaluationError("empty gait summary carries accepted metrics")
    else:
        if not (48 <= cadence <= 220 and 0.55 <= periodicity <= 1 and 0.78 <= consistency <= 1):
            raise EvaluationError("accepted gait metrics are outside challenger bounds")
        if gyro != "unavailable" and not 0.72 <= finite_number(fields, "accepted_gyro_median") <= 1:
            raise EvaluationError("accepted gait gyroscope metric is outside challenger bounds")
    return fields


def finite_number(fields: dict[str, str], key: str) -> float:
    try:
        value = float(fields[key])
    except ValueError as exc:
        raise EvaluationError(f"replay field {key} is not numeric") from exc
    if not math.isfinite(value):
        raise EvaluationError(f"replay field {key} is not finite")
    return value


def replay_integer(fields: dict[str, str], key: str) -> int:
    raw = fields[key]
    if not raw.isascii() or not raw.isdecimal():
        raise EvaluationError(f"replay field {key} is not a non-negative integer")
    return int(raw)


def walking_shadow(fields: dict[str, str]) -> bool:
    if fields["evidence_scoreable"] != "1":
        raise EvaluationError("replay evidence is not scoreable")
    accepted = replay_integer(fields, "accepted_overlapping_windows")
    longest = replay_integer(fields, "longest_accepted_stride_run_s")
    cadence = finite_number(fields, "accepted_cadence_median_spm")
    periodicity = finite_number(fields, "accepted_periodicity_median")
    consistency = finite_number(fields, "accepted_consistency_median")
    raw_gyro = fields["accepted_gyro_median"]
    gyro_ok = raw_gyro == "unavailable" or finite_number(fields, "accepted_gyro_median") >= 0.72
    return (
        accepted > 0
        and longest >= 30
        and 48 <= cadence <= 220
        and periodicity >= 0.55
        and consistency >= 0.78
        and gyro_ok
    )


def evaluate(
    archive: Path,
    manifest: Path,
    replay_binary: Path,
    replay_timeout_seconds: float,
) -> dict[str, Any]:
    if not archive.is_dir():
        raise EvaluationError(f"archive is not a directory: {archive}")
    if not replay_binary.is_file():
        raise EvaluationError(f"replay binary is not a file: {replay_binary}")
    windows = load_manifest(manifest)
    results: list[dict[str, Any]] = []
    for window in windows:
        command = [
            str(replay_binary),
            str(archive),
            str(window["start_ms"]),
            str(window["end_ms"]),
        ]
        try:
            completed = subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=replay_timeout_seconds,
            )
        except subprocess.TimeoutExpired as exc:
            raise EvaluationError(
                f"replay timed out for {window['label']} after {replay_timeout_seconds:g}s"
            ) from exc
        except OSError as exc:
            raise EvaluationError(
                f"unable to launch replay for {window['label']}: {type(exc).__name__}: {exc}"
            ) from exc
        if completed.returncode != 0:
            detail = (completed.stderr or completed.stdout).strip()
            raise EvaluationError(f"replay failed for {window['label']}: {detail}")
        fields = parse_replay_output(completed.stdout)
        shadow = walking_shadow(fields)
        expected_locomotion = window["activity"] in LOCOMOTION_ACTIVITIES
        results.append(
            {
                **window,
                "expected_locomotion": expected_locomotion,
                "shadow_candidate": "walking_shadow" if shadow else None,
                "shadow_matches_locomotion_gate": shadow,
                "gait": {
                    "accepted_overlapping_windows": replay_integer(
                        fields, "accepted_overlapping_windows"
                    ),
                    "longest_accepted_stride_run_s": replay_integer(
                        fields, "longest_accepted_stride_run_s"
                    ),
                    "accepted_cadence_median_spm": finite_number(
                        fields, "accepted_cadence_median_spm"
                    ),
                    "accepted_periodicity_median": finite_number(
                        fields, "accepted_periodicity_median"
                    ),
                    "accepted_consistency_median": finite_number(
                        fields, "accepted_consistency_median"
                    ),
                    "accepted_gyro_median": None
                    if fields["accepted_gyro_median"] == "unavailable"
                    else finite_number(fields, "accepted_gyro_median"),
                },
            }
        )

    true_positive = sum(r["expected_locomotion"] and r["shadow_matches_locomotion_gate"] for r in results)
    false_negative = sum(r["expected_locomotion"] and not r["shadow_matches_locomotion_gate"] for r in results)
    false_positive = sum(not r["expected_locomotion"] and r["shadow_matches_locomotion_gate"] for r in results)
    true_negative = sum(not r["expected_locomotion"] and not r["shadow_matches_locomotion_gate"] for r in results)
    correct_walk_shadow = sum(r["activity"] == "walk" and r["shadow_matches_locomotion_gate"] for r in results)
    missed_walk = sum(r["activity"] == "walk" and not r["shadow_matches_locomotion_gate"] for r in results)
    run_as_walk = sum(r["activity"] == "run" and r["shadow_matches_locomotion_gate"] for r in results)
    confuser_as_walk = false_positive
    return {
        "schema_version": 1,
        "research_only": 1,
        "validation_status": "not_validated",
        "activity_decoder_validated": 0,
        "production_promotions": 0,
        "production_label_changes": 0,
        "window_count": len(results),
        "confusion": {
            "locomotion_gate": {
                "true_positive_locomotion": true_positive,
                "false_negative_locomotion": false_negative,
                "false_positive_confuser": false_positive,
                "true_negative_confuser": true_negative,
                "pass": false_negative == 0 and false_positive == 0,
            },
            "walking_subtype": {
                "correct_walk_shadow": correct_walk_shadow,
                "missed_walk": missed_walk,
                "run_misidentified_as_walking_shadow": run_as_walk,
                "confuser_misidentified_as_walking_shadow": confuser_as_walk,
                "pass": missed_walk == 0 and run_as_walk == 0 and confuser_as_walk == 0,
            },
        },
        "windows": results,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--replay-binary", required=True, type=Path)
    parser.add_argument("--replay-timeout-seconds", type=float, default=120.0)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args(argv)
    try:
        if arguments.output is not None and arguments.output.exists():
            raise EvaluationError(f"output already exists: {arguments.output}")
        if not math.isfinite(arguments.replay_timeout_seconds) or arguments.replay_timeout_seconds <= 0:
            raise EvaluationError("replay timeout must be a positive finite number")
        report = evaluate(
            arguments.archive,
            arguments.manifest,
            arguments.replay_binary,
            arguments.replay_timeout_seconds,
        )
        encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
        if arguments.output is not None:
            try:
                arguments.output.parent.mkdir(parents=True, exist_ok=True)
                arguments.output.write_text(encoded, encoding="utf-8")
            except OSError as exc:
                raise EvaluationError(
                    f"unable to write output: {type(exc).__name__}: {exc}"
                ) from exc
        sys.stdout.write(encoded)
        return 0
    except EvaluationError as exc:
        failure = {
            "schema_version": 1,
            "research_only": 1,
            "validation_status": "not_validated",
            "activity_decoder_validated": 0,
            "production_promotions": 0,
            "production_label_changes": 0,
            "error": str(exc),
        }
        sys.stdout.write(json.dumps(failure, sort_keys=True) + "\n")
        print(f"activity_evaluation_error={exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
