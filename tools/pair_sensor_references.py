#!/usr/bin/env python3
"""Pair research-only external sensor references with clock-qualified raw frames.

This tool never validates a decoder and never emits a health metric. It creates a
deterministic evidence bundle that can later be inspected while preserving the raw
payload, exact reference reading, clock delta, layout identity, and fail-closed gates.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


REFERENCE_KINDS = {
    "oxygen_reference",
    "skin_temperature_reference",
    "clock_marker",
}
RAW_SOURCES = {"0x2f", "0x31", "61080007"}


class EvidenceError(ValueError):
    pass


@dataclass(frozen=True)
class Reference:
    index: int
    timestamp: datetime
    kind: str
    spo2: float | None
    skin_temperature_c: float | None
    label: str
    reference_device: str
    measurement_site: str
    contact_state: str
    input_value: float | None
    input_unit: str
    notes: str


@dataclass(frozen=True)
class RawFrame:
    timestamp_ms: int
    source: str
    layout_version: str
    payload_length: int
    raw_payload_hex: str
    archive_file: str
    archive_line: int
    schema: int
    captured_at: str
    sequence: int
    command: int
    unix7: int
    subsec11: int
    flash13: int
    clock_device_ref: int
    clock_wall_ref: int
    clock_drift_seconds: int
    current_session_usable: bool
    metric_usable: bool
    usability_reason: str


@dataclass(frozen=True)
class ArchiveAudit:
    total_lines: int
    blank_lines: int
    parsed_json_rows: int
    unsupported_source_rows: int
    clock_unqualified_rows: int
    rejected_rows: dict[str, int]
    duplicate_rows: int


def _parse_iso8601(value: str) -> datetime:
    cleaned = value.strip()
    if cleaned.endswith("Z"):
        cleaned = cleaned[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(cleaned)
    except ValueError as error:
        raise EvidenceError(f"invalid reference timestamp: {value}") from error
    if parsed.tzinfo is None:
        raise EvidenceError(f"reference timestamp lacks timezone: {value}")
    return parsed.astimezone(timezone.utc)


def _optional_finite(row: dict[str, str], key: str) -> float | None:
    value = (row.get(key) or "").strip()
    if not value:
        return None
    try:
        result = float(value)
    except ValueError as error:
        raise EvidenceError(f"invalid numeric {key}: {value}") from error
    if not math.isfinite(result):
        raise EvidenceError(f"non-finite numeric {key}: {value}")
    return result


def read_references(path: Path) -> list[Reference]:
    try:
        handle = path.open(newline="", encoding="utf-8")
    except OSError as error:
        raise EvidenceError(f"cannot read reference CSV: {path}") from error
    with handle:
        reader = csv.DictReader(handle)
        required = {
            "timestamp",
            "reference_spo2_percent",
            "reference_skin_temp_c",
            "event_kind",
            "reference_device",
            "measurement_site",
            "local_only",
            "research_only",
            "decoder_validated",
            "metric_promotions",
        }
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise EvidenceError(
                "reference CSV missing columns: " + ",".join(sorted(missing))
            )
        references: list[Reference] = []
        for index, row in enumerate(reader, start=1):
            kind = (row.get("event_kind") or "").strip()
            if kind not in REFERENCE_KINDS:
                raise EvidenceError(f"row {index}: unsupported event_kind {kind}")
            if (row.get("local_only") or "").strip() != "1":
                raise EvidenceError(f"row {index}: local_only must be 1")
            if (row.get("research_only") or "").strip() != "1":
                raise EvidenceError(f"row {index}: research_only must be 1")
            if (row.get("decoder_validated") or "").strip() != "0":
                raise EvidenceError(f"row {index}: decoder_validated must remain 0")
            if (row.get("metric_promotions") or "").strip() != "0":
                raise EvidenceError(f"row {index}: metric_promotions must remain 0")

            spo2 = _optional_finite(row, "reference_spo2_percent")
            temperature = _optional_finite(row, "reference_skin_temp_c")
            input_value = _optional_finite(row, "input_value")
            input_unit = (row.get("input_unit") or "").strip()
            if kind == "oxygen_reference":
                if spo2 is None or not 50 <= spo2 <= 100 or temperature is not None:
                    raise EvidenceError(f"row {index}: invalid oxygen reference")
                if input_value is None or abs(input_value - spo2) > 0.000_001:
                    raise EvidenceError(f"row {index}: oxygen input/canonical mismatch")
                if input_unit != "percent":
                    raise EvidenceError(f"row {index}: oxygen input_unit must be percent")
            elif kind == "skin_temperature_reference":
                if temperature is None or not 15 <= temperature <= 45 or spo2 is not None:
                    raise EvidenceError(f"row {index}: invalid skin-temperature reference")
                if input_value is None or input_unit not in {"degC", "degF"}:
                    raise EvidenceError(f"row {index}: invalid skin-temperature input/unit")
                input_celsius = input_value if input_unit == "degC" else (input_value - 32) * 5 / 9
                if abs(input_celsius - temperature) > 0.001:
                    raise EvidenceError(f"row {index}: skin-temperature input/canonical mismatch")
            elif (spo2 is not None or temperature is not None
                  or input_value is not None or input_unit):
                raise EvidenceError(f"row {index}: clock marker must not contain a reading")

            device = (row.get("reference_device") or "").strip()
            site = (row.get("measurement_site") or "").strip()
            if kind != "clock_marker" and (not device or not site):
                raise EvidenceError(f"row {index}: measured reference lacks device/site")
            contact_state = (row.get("contact_state") or "").strip()
            if kind != "clock_marker" and not contact_state:
                raise EvidenceError(f"row {index}: measured reference lacks contact_state")
            references.append(
                Reference(
                    index=index,
                    timestamp=_parse_iso8601(row["timestamp"]),
                    kind=kind,
                    spo2=spo2,
                    skin_temperature_c=temperature,
                    label=(row.get("label") or "").strip(),
                    reference_device=device,
                    measurement_site=site,
                    contact_state=contact_state,
                    input_value=input_value,
                    input_unit=input_unit,
                    notes=(row.get("notes") or "").strip(),
                )
            )
    if not references:
        raise EvidenceError("reference CSV contains no rows")
    return references


def _archive_files(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    if path.is_dir():
        return sorted(candidate for candidate in path.rglob("*.jsonl") if candidate.is_file())
    raise EvidenceError(f"archive path does not exist: {path}")


def _valid_hex(value: str, payload_length: int) -> bool:
    if payload_length <= 0 or len(value) != payload_length * 2:
        return False
    try:
        bytes.fromhex(value)
    except ValueError:
        return False
    return True


def _strict_int(row: dict[str, Any], key: str) -> int | None:
    value = row.get(key)
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def _strict_bool(row: dict[str, Any], key: str) -> bool | None:
    value = row.get(key)
    return value if isinstance(value, bool) else None


def read_raw_frames(path: Path) -> tuple[list[RawFrame], ArchiveAudit]:
    files = _archive_files(path)
    if not files:
        raise EvidenceError(f"archive contains no JSONL files: {path}")
    frames: dict[tuple[Any, ...], RawFrame] = {}
    total_lines = 0
    blank_lines = 0
    parsed_json_rows = 0
    unsupported_source_rows = 0
    clock_unqualified_rows = 0
    duplicate_rows = 0
    rejected_rows: dict[str, int] = {}

    def reject(reason: str) -> None:
        rejected_rows[reason] = rejected_rows.get(reason, 0) + 1
    for file in files:
        try:
            lines = file.open(encoding="utf-8")
        except OSError as error:
            raise EvidenceError(f"cannot read archive file: {file}") from error
        with lines:
            for line_number, line in enumerate(lines, start=1):
                total_lines += 1
                if not line.strip():
                    blank_lines += 1
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError as error:
                    raise EvidenceError(f"malformed archive JSON: {file}:{line_number}") from error
                if not isinstance(row, dict):
                    raise EvidenceError(f"archive row is not an object: {file}:{line_number}")
                parsed_json_rows += 1
                source = str(row.get("source") or "")
                if source not in RAW_SOURCES:
                    unsupported_source_rows += 1
                    continue
                if row.get("clockCorrectionStatus") != "clock_ref_present":
                    clock_unqualified_rows += 1
                    continue
                corrected = _strict_int(row, "clockCorrectedUnix7")
                payload_length = _strict_int(row, "payloadLength")
                schema = _strict_int(row, "schema")
                sequence = _strict_int(row, "sequence")
                command = _strict_int(row, "command")
                unix7 = _strict_int(row, "unix7")
                subsec11 = _strict_int(row, "subsec11")
                flash13 = _strict_int(row, "flash13")
                clock_device_ref = _strict_int(row, "clockDeviceRef")
                clock_wall_ref = _strict_int(row, "clockWallRef")
                clock_drift_seconds = _strict_int(row, "clockDriftSeconds")
                current_session_usable = _strict_bool(row, "currentSessionUsable")
                metric_usable = _strict_bool(row, "metricUsable")
                raw_hex = str(row.get("rawPayloadHex") or "").lower()
                layout = str(row.get("layoutVersion") or "").strip()
                captured_at = str(row.get("capturedAt") or "").strip()
                usability_reason = str(row.get("usabilityReason") or "").strip()
                required_ints = (
                    corrected, payload_length, schema, sequence, command, unix7,
                    subsec11, flash13, clock_device_ref, clock_wall_ref,
                    clock_drift_seconds,
                )
                if any(value is None for value in required_ints):
                    reject("missing_or_noninteger_provenance")
                    continue
                if current_session_usable is None or metric_usable is None:
                    reject("missing_or_nonboolean_usability")
                    continue
                if not layout or not captured_at or not usability_reason:
                    reject("missing_text_provenance")
                    continue
                if not _valid_hex(raw_hex, payload_length):
                    reject("invalid_raw_payload")
                    continue
                timestamp_ms = corrected * 1_000
                key = (timestamp_ms, source, layout, payload_length, raw_hex)
                if key in frames:
                    duplicate_rows += 1
                    continue
                frames[key] = RawFrame(
                    timestamp_ms=timestamp_ms,
                    source=source,
                    layout_version=layout,
                    payload_length=payload_length,
                    raw_payload_hex=raw_hex,
                    archive_file=str(file),
                    archive_line=line_number,
                    schema=schema,
                    captured_at=captured_at,
                    sequence=sequence,
                    command=command,
                    unix7=unix7,
                    subsec11=subsec11,
                    flash13=flash13,
                    clock_device_ref=clock_device_ref,
                    clock_wall_ref=clock_wall_ref,
                    clock_drift_seconds=clock_drift_seconds,
                    current_session_usable=current_session_usable,
                    metric_usable=metric_usable,
                    usability_reason=usability_reason,
                )
    ordered = sorted(frames.values(), key=lambda item: (item.timestamp_ms, item.raw_payload_hex))
    if not ordered:
        raise EvidenceError("archive contains no clock-qualified raw frames")
    return ordered, ArchiveAudit(
        total_lines=total_lines,
        blank_lines=blank_lines,
        parsed_json_rows=parsed_json_rows,
        unsupported_source_rows=unsupported_source_rows,
        clock_unqualified_rows=clock_unqualified_rows,
        rejected_rows=dict(sorted(rejected_rows.items())),
        duplicate_rows=duplicate_rows,
    )


def pair(
    references: Iterable[Reference],
    frames: list[RawFrame],
    window_seconds: float,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], int]:
    window_ms = int(round(window_seconds * 1_000))
    pairs: list[dict[str, Any]] = []
    summaries: list[dict[str, Any]] = []
    frame_use_counts: dict[tuple[Any, ...], int] = {}
    for reference in references:
        reference_ms = int(round(reference.timestamp.timestamp() * 1_000))
        matched = [frame for frame in frames if abs(frame.timestamp_ms - reference_ms) <= window_ms]
        layout_counts: dict[str, int] = {}
        for frame in matched:
            layout_key = f"{frame.source}:{frame.layout_version}:{frame.payload_length}"
            layout_counts[layout_key] = layout_counts.get(layout_key, 0) + 1
        selected = min(
            matched,
            key=lambda frame: (
                abs(frame.timestamp_ms - reference_ms),
                frame.timestamp_ms,
                frame.raw_payload_hex,
            ),
            default=None,
        )
        if selected is not None:
            frame = selected
            frame_key = (
                frame.timestamp_ms, frame.source, frame.layout_version,
                frame.payload_length, frame.raw_payload_hex,
            )
            frame_use_counts[frame_key] = frame_use_counts.get(frame_key, 0) + 1
            pairs.append(
                {
                    "reference_index": reference.index,
                    "reference_timestamp": reference.timestamp.isoformat().replace("+00:00", "Z"),
                    "event_kind": reference.kind,
                    "reference_spo2_percent": reference.spo2,
                    "reference_skin_temp_c": reference.skin_temperature_c,
                    "label": reference.label,
                    "reference_device": reference.reference_device,
                    "measurement_site": reference.measurement_site,
                    "contact_state": reference.contact_state,
                    "input_value": reference.input_value,
                    "input_unit": reference.input_unit,
                    "notes": reference.notes,
                    "raw_timestamp_ms": frame.timestamp_ms,
                    "clock_delta_ms": frame.timestamp_ms - reference_ms,
                    "source": frame.source,
                    "layout_version": frame.layout_version,
                    "payload_length": frame.payload_length,
                    "raw_payload_hex": frame.raw_payload_hex,
                    "archive_file": frame.archive_file,
                    "archive_line": frame.archive_line,
                    "archive_schema": frame.schema,
                    "archive_captured_at": frame.captured_at,
                    "sequence": frame.sequence,
                    "command": frame.command,
                    "unix7": frame.unix7,
                    "subsec11": frame.subsec11,
                    "flash13": frame.flash13,
                    "clock_device_ref": frame.clock_device_ref,
                    "clock_wall_ref": frame.clock_wall_ref,
                    "clock_drift_seconds": frame.clock_drift_seconds,
                    "clock_correction_status": "clock_ref_present",
                    "current_session_usable": frame.current_session_usable,
                    "source_metric_usable": frame.metric_usable,
                    "source_usability_reason": frame.usability_reason,
                    "selection_policy": "nearest_single_frame_within_window",
                    "local_only": True,
                    "research_only": True,
                    "decoder_validated": False,
                    "metric_promotions": 0,
                }
            )
        summaries.append(
            {
                "reference_index": reference.index,
                "event_kind": reference.kind,
                "reference_timestamp": reference.timestamp.isoformat().replace("+00:00", "Z"),
                "candidate_frame_count": len(matched),
                "layout_counts": dict(sorted(layout_counts.items())),
                "selected_frame_count": 1 if selected is not None else 0,
                "pairing_status": "nearest_frame_research_only" if selected is not None else "no_clock_qualified_frame",
                "decoder_validated": False,
                "metric_promotions": 0,
            }
        )
    reused_assignments = sum(count - 1 for count in frame_use_counts.values() if count > 1)
    return pairs, summaries, reused_assignments


def _write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    with path.open("x", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("references", type=Path)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--window-seconds", type=float, default=2.0)
    args = parser.parse_args(argv)
    if not math.isfinite(args.window_seconds) or not 0 < args.window_seconds <= 300:
        raise EvidenceError("window-seconds must be finite and in (0, 300]")
    if args.output_dir.exists():
        if not args.output_dir.is_dir():
            raise EvidenceError(f"output path must be a directory: {args.output_dir}")
        if any(args.output_dir.iterdir()):
            raise EvidenceError(f"output directory must be empty: {args.output_dir}")
    args.output_dir.mkdir(parents=True, exist_ok=True)

    references = read_references(args.references)
    frames, archive_audit = read_raw_frames(args.archive)
    pairs, reference_summaries, reused_assignments = pair(
        references, frames, args.window_seconds
    )
    pairs_path = args.output_dir / "sensor-reference-pairs.jsonl"
    summary_path = args.output_dir / "sensor-reference-summary.json"
    _write_jsonl(pairs_path, pairs)
    summary = {
        "schema": 1,
        "references": len(references),
        "clock_qualified_raw_frames": len(frames),
        "paired_rows": len(pairs),
        "selection_policy": "nearest_single_frame_within_window",
        "reused_raw_frame_assignments": reused_assignments,
        "window_seconds": args.window_seconds,
        "archive_time_min_utc": datetime.fromtimestamp(
            frames[0].timestamp_ms / 1_000, tz=timezone.utc
        ).isoformat().replace("+00:00", "Z"),
        "archive_time_max_utc": datetime.fromtimestamp(
            frames[-1].timestamp_ms / 1_000, tz=timezone.utc
        ).isoformat().replace("+00:00", "Z"),
        "archive_audit": {
            "total_lines": archive_audit.total_lines,
            "blank_lines": archive_audit.blank_lines,
            "parsed_json_rows": archive_audit.parsed_json_rows,
            "unsupported_source_rows": archive_audit.unsupported_source_rows,
            "clock_unqualified_rows": archive_audit.clock_unqualified_rows,
            "rejected_rows": archive_audit.rejected_rows,
            "duplicate_rows": archive_audit.duplicate_rows,
        },
        "reference_summaries": reference_summaries,
        "research_only": True,
        "decoder_validated": False,
        "metric_promotions": 0,
        "validation_status": "not_validated",
        "required_next_step": "collect_multiple_levels_and_users_then_validate_a_versioned_decoder_against_independent_references",
    }
    with summary_path.open("x", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(
        "ATRIA_SENSOR_REFERENCE_PAIRING "
        f"references={len(references)} frames={len(frames)} pairs={len(pairs)} "
        "decoder_validated=0 metric_promotions=0"
    )
    print(f"summary={summary_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except EvidenceError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
