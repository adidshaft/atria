#!/usr/bin/env python3
"""Bind exact physical-session notes to CRC-valid R10 device-time manifests.

This is a conversion and evidence-gating tool. It does not run a detector,
infer an activity, estimate a step count, or alter the guided calibration
manifest. Wall-clock boundaries are aligned inward to complete strap seconds;
every emitted second must be backed by one unambiguous CRC-valid R10 frame.
"""

from __future__ import annotations

import argparse
import calendar
import hashlib
import json
import os
import re
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import summarize_step_archive_coverage as archive_contract


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
SUPPORTED_USES = {"holdout", "activity"}
POSITIVE_HOLDOUT_ACTIVITIES = {"walk", "run"}
ZERO_HOLDOUT_ACTIVITIES = {
    "rest",
    "handling",
    "typing",
    "cycle",
    "driving",
    "strength",
}
MINIMUM_ACTIVITY_MS = 34_000
ISO_OFFSET_PATTERN = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})"
    r"(?:\.(\d{1,3}))?(Z|[+-]\d{2}:\d{2})$"
)
GUIDED_CONTRACT = (
    ("Rest before", "rest", 0),
    ("Slow 100", "walk", 100),
    ("Normal 100", "walk", 100),
    ("Brisk 100", "walk", 100),
    ("Normal 200", "walk", 200),
    ("Rest after", "rest", 0),
)


class ManifestBuildError(ValueError):
    """The supplied evidence cannot safely produce strict manifests."""


@dataclass(frozen=True)
class SourceWindow:
    label: str
    activity: str
    start: str
    end: str
    start_epoch_ms: int
    end_epoch_ms: int
    start_ms: int
    end_ms: int
    use_for: tuple[str, ...]
    expected_steps: int | None

    @property
    def duration_ms(self) -> int:
        return self.end_ms - self.start_ms

    @property
    def start_trim_ms(self) -> int:
        return self.start_ms - self.start_epoch_ms

    @property
    def end_trim_ms(self) -> int:
        return self.end_epoch_ms - self.end_ms


@dataclass(frozen=True)
class GuidedWindow:
    label: str
    start_ms: int
    end_ms: int


def strict_integer(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ManifestBuildError(f"{field} must be an integer")
    return value


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ManifestBuildError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_strict_json(path: Path, description: str) -> tuple[dict[str, Any], bytes]:
    try:
        raw = path.read_bytes()
        document = json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError, ManifestBuildError) as exc:
        raise ManifestBuildError(
            f"unable to read {description}: {type(exc).__name__}: {exc}"
        ) from exc
    if not isinstance(document, dict):
        raise ManifestBuildError(f"{description} must be a JSON object")
    return document, raw


def parse_explicit_offset_iso(value: Any, field: str) -> int:
    if not isinstance(value, str) or value != value.strip():
        raise ManifestBuildError(f"{field} must be a trimmed ISO-8601 string")
    match = ISO_OFFSET_PATTERN.fullmatch(value)
    if match is None:
        raise ManifestBuildError(
            f"{field} must include seconds and an explicit UTC offset (Z or ±HH:MM)"
        )
    year, month, day, hour, minute, second = (int(part) for part in match.groups()[:6])
    fraction = match.group(7) or ""
    milliseconds = int(fraction.ljust(3, "0")) if fraction else 0
    offset_text = match.group(8)
    if offset_text == "Z":
        offset = timedelta(0)
    else:
        sign = 1 if offset_text[0] == "+" else -1
        offset_hours = int(offset_text[1:3])
        offset_minutes = int(offset_text[4:6])
        if offset_hours > 23 or offset_minutes > 59:
            raise ManifestBuildError(f"{field} has an invalid UTC offset")
        offset = sign * timedelta(hours=offset_hours, minutes=offset_minutes)
    try:
        local = datetime(
            year,
            month,
            day,
            hour,
            minute,
            second,
            milliseconds * 1_000,
            tzinfo=timezone(offset),
        )
    except ValueError as exc:
        raise ManifestBuildError(f"{field} is not a valid ISO-8601 timestamp: {exc}") from exc
    utc = local.astimezone(timezone.utc)
    epoch_seconds = calendar.timegm(utc.utctimetuple())
    epoch_ms = epoch_seconds * 1_000 + utc.microsecond // 1_000
    if epoch_ms < 0:
        raise ManifestBuildError(f"{field} must not precede the Unix epoch")
    return epoch_ms


def inward_start(epoch_ms: int) -> int:
    return ((epoch_ms + 999) // 1_000) * 1_000


def inward_end(epoch_ms: int) -> int:
    return (epoch_ms // 1_000) * 1_000


def load_notes(path: Path) -> tuple[list[SourceWindow], bytes]:
    document, raw_bytes = read_strict_json(path, "notes manifest")
    if set(document) != {"version", "windows"}:
        raise ManifestBuildError("notes manifest must contain exactly version and windows")
    if strict_integer(document["version"], "version") != 1:
        raise ManifestBuildError("unsupported notes manifest version")
    raw_windows = document["windows"]
    if not isinstance(raw_windows, list) or not raw_windows:
        raise ManifestBuildError("notes windows must be a non-empty array")

    windows: list[SourceWindow] = []
    labels: set[str] = set()
    previous_end_epoch_ms: int | None = None
    required = {"label", "activity", "start", "end", "use_for"}
    allowed = required | {"expected_steps"}
    for index, item in enumerate(raw_windows):
        if not isinstance(item, dict):
            raise ManifestBuildError(f"windows[{index}] must be an object")
        if not required.issubset(item) or not set(item) <= allowed:
            raise ManifestBuildError(f"windows[{index}] has missing or unknown fields")

        label = item["label"]
        if not isinstance(label, str) or not label or label != label.strip():
            raise ManifestBuildError(
                f"windows[{index}].label must be a trimmed non-empty string"
            )
        if label in labels:
            raise ManifestBuildError(f"duplicate window label: {label}")
        labels.add(label)

        activity = item["activity"]
        if not isinstance(activity, str) or activity not in SUPPORTED_ACTIVITIES:
            raise ManifestBuildError(f"unsupported activity for {label}: {activity!r}")

        raw_uses = item["use_for"]
        if not isinstance(raw_uses, list) or not raw_uses:
            raise ManifestBuildError(f"{label}.use_for must be a non-empty array")
        uses: list[str] = []
        for use in raw_uses:
            if not isinstance(use, str) or use not in SUPPORTED_USES:
                raise ManifestBuildError(f"unsupported use_for value for {label}: {use!r}")
            if use in uses:
                raise ManifestBuildError(f"duplicate use_for value for {label}: {use}")
            uses.append(use)

        has_expected_steps = "expected_steps" in item
        expected_steps = (
            strict_integer(item["expected_steps"], f"{label}.expected_steps")
            if has_expected_steps
            else None
        )
        if expected_steps is not None and expected_steps < 0:
            raise ManifestBuildError(f"{label}.expected_steps must be nonnegative")
        if "holdout" in uses:
            if expected_steps is None:
                raise ManifestBuildError(f"holdout window {label} requires expected_steps")
            if activity in POSITIVE_HOLDOUT_ACTIVITIES:
                if expected_steps <= 0:
                    raise ManifestBuildError(
                        f"holdout {activity} window {label} requires expected_steps > 0"
                    )
            elif activity in ZERO_HOLDOUT_ACTIVITIES:
                if expected_steps != 0:
                    raise ManifestBuildError(
                        f"holdout control {label} requires expected_steps = 0"
                    )
            else:
                raise ManifestBuildError(
                    f"activity {activity} cannot be used as holdout evidence: {label}"
                )
        elif has_expected_steps:
            raise ManifestBuildError(
                f"activity-only window {label} must not contain expected_steps"
            )

        start_text = item["start"]
        end_text = item["end"]
        start_epoch_ms = parse_explicit_offset_iso(start_text, f"{label}.start")
        end_epoch_ms = parse_explicit_offset_iso(end_text, f"{label}.end")
        if end_epoch_ms <= start_epoch_ms:
            raise ManifestBuildError(f"end must follow start for {label}")
        if previous_end_epoch_ms is not None and start_epoch_ms < previous_end_epoch_ms:
            raise ManifestBuildError(
                f"notes windows must be chronological and non-overlapping: {label}"
            )
        previous_end_epoch_ms = end_epoch_ms

        start_ms = inward_start(start_epoch_ms)
        end_ms = inward_end(end_epoch_ms)
        if end_ms <= start_ms:
            raise ManifestBuildError(f"inward alignment leaves no complete device second: {label}")
        if "activity" in uses and end_ms - start_ms < MINIMUM_ACTIVITY_MS:
            raise ManifestBuildError(
                f"aligned activity window must span at least 34 seconds: {label}"
            )
        windows.append(
            SourceWindow(
                label=label,
                activity=activity,
                start=start_text,
                end=end_text,
                start_epoch_ms=start_epoch_ms,
                end_epoch_ms=end_epoch_ms,
                start_ms=start_ms,
                end_ms=end_ms,
                use_for=tuple(uses),
                expected_steps=expected_steps,
            )
        )

    for previous, current in zip(windows, windows[1:]):
        if current.start_ms < previous.end_ms:
            raise ManifestBuildError(
                f"aligned windows overlap: {previous.label}, {current.label}"
            )
    return windows, raw_bytes


def load_guided_manifest(path: Path) -> tuple[list[GuidedWindow], bytes]:
    document, raw_bytes = read_strict_json(path, "guided calibration manifest")
    if set(document) != {"windows"}:
        raise ManifestBuildError("guided calibration manifest must contain exactly windows")
    raw_windows = document["windows"]
    if not isinstance(raw_windows, list) or len(raw_windows) != len(GUIDED_CONTRACT):
        raise ManifestBuildError(
            "guided calibration manifest must contain the exact six-stage sequence"
        )
    result: list[GuidedWindow] = []
    previous_end: int | None = None
    for index, (item, contract) in enumerate(zip(raw_windows, GUIDED_CONTRACT)):
        if not isinstance(item, dict) or set(item) != {
            "label", "kind", "start_ms", "end_ms", "expected_steps"
        }:
            raise ManifestBuildError(
                f"guided calibration windows[{index}] has missing or unknown fields"
            )
        label, kind, expected = contract
        if (
            item["label"] != label
            or item["kind"] != kind
            or strict_integer(item["expected_steps"], f"guided {label}.expected_steps")
            != expected
        ):
            raise ManifestBuildError(
                "guided calibration manifest must contain the exact six-stage sequence"
            )
        start_ms = strict_integer(item["start_ms"], f"guided {label}.start_ms")
        end_ms = strict_integer(item["end_ms"], f"guided {label}.end_ms")
        if start_ms < 0 or end_ms <= start_ms:
            raise ManifestBuildError(f"invalid guided calibration window: {label}")
        if kind == "rest" and end_ms - start_ms < 60_000:
            raise ManifestBuildError(f"guided rest must span at least 60 seconds: {label}")
        if previous_end is not None and start_ms < previous_end:
            raise ManifestBuildError(
                f"guided calibration windows overlap or are out of order: {label}"
            )
        previous_end = end_ms
        result.append(GuidedWindow(label, start_ms, end_ms))
    return result, raw_bytes


def overlaps(start_ms: int, end_ms: int, other_start: int, other_end: int) -> bool:
    return start_ms < other_end and other_start < end_ms


def validate_no_calibration_overlap(
    windows: list[SourceWindow], guided: list[GuidedWindow]
) -> None:
    for window in windows:
        for calibration in guided:
            if overlaps(window.start_ms, window.end_ms, calibration.start_ms, calibration.end_ms):
                raise ManifestBuildError(
                    f"physical window overlaps guided calibration evidence: "
                    f"{window.label}, {calibration.label}"
                )


def archive_files(root: Path) -> list[Path]:
    if root.is_symlink():
        raise ManifestBuildError("archive path must not be a symlink")
    if root.is_file():
        return [root]
    if not root.is_dir():
        raise ManifestBuildError(f"archive does not exist or is not readable: {root}")
    files = sorted(path for path in root.rglob("*") if path.is_file())
    if any(path.is_symlink() for path in files):
        raise ManifestBuildError("archive files must not be symlinks")
    if not files:
        raise ManifestBuildError("archive contains no files")
    return files


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def hash_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    total = 0
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
                total += len(chunk)
    except OSError as exc:
        raise ManifestBuildError(f"unable to hash archive file {path}: {exc}") from exc
    return digest.hexdigest(), total


def archive_hashes(root: Path, files: list[Path]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for path in files:
        relative = path.name if root.is_file() else path.relative_to(root).as_posix()
        digest, byte_count = hash_file(path)
        result.append({"path": relative, "bytes": byte_count, "sha256": digest})
    return result


def load_unambiguous_frames(root: Path) -> tuple[dict[int, str], dict[str, int]]:
    rows, parsed_rows, copied_rows = archive_contract.load_rows(root)
    if parsed_rows == 0:
        raise ManifestBuildError(
            "archive contains no rows using the summarize/replay received_at_unix_ms/raw_frame_hex contract"
        )
    by_second: dict[int, str] = {}
    crc_valid_rows = 0
    identical_duplicates = 0
    zero_timestamp_rows = 0
    for row in rows:
        frame = archive_contract.decode_r10(row.received_ms, row.raw_hex)
        if frame is None:
            continue
        crc_valid_rows += 1
        if frame.device_timestamp <= 0:
            zero_timestamp_rows += 1
            continue
        timestamp_ms = frame.device_timestamp * 1_000
        normalized = frame.raw_hex.lower()
        existing = by_second.get(timestamp_ms)
        if existing is None:
            by_second[timestamp_ms] = normalized
        elif existing == normalized:
            identical_duplicates += 1
        else:
            raise ManifestBuildError(
                f"ambiguous CRC-valid R10 frames for device second {frame.device_timestamp}"
            )
    if not by_second:
        raise ManifestBuildError("archive contains no bindable CRC-valid R10 device seconds")
    return by_second, {
        "csv_rows_parsed": parsed_rows,
        "byte_identical_csv_rows_deduplicated": copied_rows,
        "crc_valid_r10_rows": crc_valid_rows,
        "byte_identical_device_second_duplicates": identical_duplicates,
        "zero_device_timestamp_rows_ignored": zero_timestamp_rows,
        "unique_crc_valid_device_seconds": len(by_second),
    }


def bind_window(window: SourceWindow, frames: dict[int, str]) -> dict[str, Any]:
    expected_timestamps = list(range(window.start_ms, window.end_ms, 1_000))
    present = [timestamp for timestamp in expected_timestamps if timestamp in frames]
    if len(present) != len(expected_timestamps):
        missing = [timestamp for timestamp in expected_timestamps if timestamp not in frames]
        first = missing[0]
        raise ManifestBuildError(
            f"missing CRC-valid R10 boundary/continuity evidence for {window.label}: "
            f"{len(missing)} missing device second(s), first={first}"
        )
    if not present or present[0] != window.start_ms or present[-1] + 1_000 != window.end_ms:
        raise ManifestBuildError(f"uncovered device-time boundary for {window.label}")
    if any(current != previous + 1_000 for previous, current in zip(present, present[1:])):
        raise ManifestBuildError(f"device-time discontinuity for {window.label}")
    expected_frames = window.duration_ms // 1_000
    if len(present) != expected_frames:
        raise ManifestBuildError(f"ambiguous device-time coverage for {window.label}")

    audit: dict[str, Any] = {
        "label": window.label,
        "activity": window.activity,
        "use_for": list(window.use_for),
        "source_start": window.start,
        "source_end": window.end,
        "source_start_epoch_ms": window.start_epoch_ms,
        "source_end_epoch_ms": window.end_epoch_ms,
        "aligned_start_ms": window.start_ms,
        "aligned_end_ms_exclusive": window.end_ms,
        "start_trim_ms": window.start_trim_ms,
        "end_trim_ms": window.end_trim_ms,
        "aligned_duration_ms": window.duration_ms,
        "expected_device_frames": expected_frames,
        "crc_valid_device_frames": len(present),
        "first_device_timestamp_ms": present[0],
        "last_device_timestamp_ms": present[-1],
        "coverage_percent": 100.0,
        "device_timestamp_continuity_breaks": 0,
        "maximum_uncovered_boundary_gap_ms": 0,
        "evidence_scoreable": 1,
    }
    if window.expected_steps is not None:
        audit["expected_steps"] = window.expected_steps
    return audit


def holdout_kind(activity: str) -> str:
    if activity in POSITIVE_HOLDOUT_ACTIVITIES:
        return activity
    if activity == "rest":
        return "rest"
    return "negative"


def build_manifests(windows: list[SourceWindow]) -> tuple[dict[str, Any], dict[str, Any]]:
    holdout_windows = [window for window in windows if "holdout" in window.use_for]
    activity_windows = [window for window in windows if "activity" in window.use_for]
    if not any(window.activity in POSITIVE_HOLDOUT_ACTIVITIES for window in holdout_windows):
        raise ManifestBuildError("holdout output requires at least one counted walk or run")
    if not any(window.activity in ZERO_HOLDOUT_ACTIVITIES for window in holdout_windows):
        raise ManifestBuildError("holdout output requires at least one explicit zero-step control")
    if not activity_windows:
        raise ManifestBuildError("activity output requires at least one window")
    if not any(window.activity in POSITIVE_HOLDOUT_ACTIVITIES for window in activity_windows):
        raise ManifestBuildError("activity output requires at least one labelled walk or run")
    if not any(window.activity not in POSITIVE_HOLDOUT_ACTIVITIES for window in activity_windows):
        raise ManifestBuildError("activity output requires at least one labelled confuser/control")

    holdout = {
        "windows": [
            {
                "label": window.label,
                "kind": holdout_kind(window.activity),
                "start_ms": window.start_ms,
                "end_ms": window.end_ms,
                "expected_steps": window.expected_steps,
            }
            for window in holdout_windows
        ]
    }
    activity = {
        "version": 1,
        "windows": [
            {
                "label": window.label,
                "activity": window.activity,
                "start_ms": window.start_ms,
                "end_ms": window.end_ms,
            }
            for window in activity_windows
        ],
    }
    return holdout, activity


def encoded_json(document: dict[str, Any]) -> bytes:
    return (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")


def refuse_existing_outputs(paths: list[Path]) -> None:
    resolved = [path.resolve(strict=False) for path in paths]
    if len(set(resolved)) != len(resolved):
        raise ManifestBuildError("output paths must be distinct")
    for path in paths:
        if path.exists() or path.is_symlink():
            raise ManifestBuildError(f"refusing existing output: {path}")


def refuse_archive_output_locations(archive: Path, paths: list[Path]) -> None:
    archive_resolved = archive.resolve(strict=False)
    archive_root = archive_resolved.parent if archive.is_file() else archive_resolved
    for path in paths:
        output = path.resolve(strict=False)
        if output == archive_resolved or archive_root in output.parents:
            raise ManifestBuildError(
                f"output must not be written inside the copied archive: {path}"
            )


def publish_outputs(outputs: list[tuple[Path, bytes]]) -> None:
    staged: list[tuple[Path, Path]] = []
    published: list[Path] = []
    try:
        for destination, data in outputs:
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary = destination.parent / f".{destination.name}.tmp-{uuid.uuid4().hex}"
            with temporary.open("xb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            staged.append((temporary, destination))
        for temporary, destination in staged:
            os.link(temporary, destination)
            published.append(destination)
    except OSError as exc:
        for destination in published:
            try:
                destination.unlink()
            except OSError:
                pass
        raise ManifestBuildError(f"unable to publish outputs atomically: {exc}") from exc
    finally:
        for temporary, _ in staged:
            try:
                temporary.unlink()
            except OSError:
                pass


def build(arguments: argparse.Namespace) -> None:
    outputs = [arguments.holdout_output, arguments.activity_output, arguments.audit_output]
    refuse_existing_outputs(outputs)
    refuse_archive_output_locations(arguments.archive, outputs)
    windows, notes_bytes = load_notes(arguments.notes)
    guided, calibration_bytes = load_guided_manifest(arguments.calibration_manifest)
    validate_no_calibration_overlap(windows, guided)

    files = archive_files(arguments.archive)
    file_hashes = archive_hashes(arguments.archive, files)
    frames, archive_summary = load_unambiguous_frames(arguments.archive)
    bindings = [bind_window(window, frames) for window in windows]
    holdout, activity = build_manifests(windows)
    holdout_bytes = encoded_json(holdout)
    activity_bytes = encoded_json(activity)
    audit = {
        "version": 1,
        "conversion_only": 1,
        "detector_executed": 0,
        "detector_counts_inferred": 0,
        "activity_labels_inferred": 0,
        "alignment": "inward_complete_device_seconds",
        "end_semantics": "exclusive_epoch_milliseconds",
        "inputs": {
            "archive_files": file_hashes,
            "notes": {"sha256": sha256_bytes(notes_bytes), "bytes": len(notes_bytes)},
            "guided_calibration_manifest": {
                "sha256": sha256_bytes(calibration_bytes),
                "bytes": len(calibration_bytes),
            },
        },
        "archive_summary": archive_summary,
        "windows": bindings,
        "outputs": {
            "holdout_manifest": {
                "sha256": sha256_bytes(holdout_bytes),
                "bytes": len(holdout_bytes),
            },
            "activity_manifest": {
                "sha256": sha256_bytes(activity_bytes),
                "bytes": len(activity_bytes),
            },
        },
    }
    audit_bytes = encoded_json(audit)
    # Recheck immediately before the all-or-rollback publication boundary.
    refuse_existing_outputs(outputs)
    publish_outputs(
        [
            (arguments.holdout_output, holdout_bytes),
            (arguments.activity_output, activity_bytes),
            (arguments.audit_output, audit_bytes),
        ]
    )


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="copied atria-step-calibration archive")
    parser.add_argument("notes", type=Path, help="strict version-1 physical-window notes JSON")
    parser.add_argument("--calibration-manifest", required=True, type=Path)
    parser.add_argument("--holdout-output", required=True, type=Path)
    parser.add_argument("--activity-output", required=True, type=Path)
    parser.add_argument("--audit-output", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        build(parse_arguments(sys.argv[1:] if argv is None else argv))
    except ManifestBuildError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
