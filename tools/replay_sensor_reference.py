#!/usr/bin/env python3
"""Replay WHOOP historical frames against synchronized sensor references.

This is research tooling, not a metric decoder. The three exported u16 fields
are named only by payload offset. No field is interpreted as SpO2 or degrees C,
and every report remains fail-closed (`decoder_validated=0`).
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import math
import re
import statistics
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from whoop_codec import decode as decode_whoop_frame  # noqa: E402


FRAME_RE = re.compile(
    r"^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)"
    r".*?ATRIADBG frame ch=(?P<channel>[0-9A-Fa-f-]+)"
    r" len=(?P<length>\d+) hex=(?P<hex>[0-9A-Fa-f]+)"
)
BARE_RE = re.compile(
    r"^(?P<timestamp>\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)"
    r"(?:,(?P<channel>[0-9A-Fa-f-]+))?,(?P<hex>[0-9A-Fa-f]+)$"
)
SUPPORTED_RECORD_VERSIONS = frozenset((12, 24))
REFERENCE_FIELDS = ("reference_spo2_percent", "reference_skin_temp_c")


@dataclass(frozen=True)
class CandidateFrame:
    timestamp: datetime
    timestamp_text: str
    source_char: str
    record_version: int
    payload_length: int
    raw_u16_64: int
    raw_u16_66: int
    raw_u16_68: int
    payload_sha256_prefix: str
    transport_validated: bool

    @property
    def ratio_64_66(self) -> float | None:
        return self.raw_u16_64 / self.raw_u16_66 if self.raw_u16_66 else None


@dataclass(frozen=True)
class ReferenceRow:
    timestamp: datetime
    spo2_percent: float | None
    skin_temp_c: float | None
    label: str


@dataclass(frozen=True)
class MatchedRow:
    frame: CandidateFrame
    reference: ReferenceRow
    age_s: float


def parse_timestamp(value: str) -> datetime:
    normalized = value.strip().replace("Z", "+00:00")
    parsed = datetime.fromisoformat(normalized)
    # Naive device-log and CSV times are intentionally compared as wall-clock
    # values. Assigning UTC avoids dependence on the Mac's configured timezone.
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def u16le(payload: bytes, offset: int) -> int:
    return int.from_bytes(payload[offset : offset + 2], "little")


def candidate_from_payload(
    payload: bytes,
    timestamp_text: str,
    source_char: str,
    transport_validated: bool,
) -> CandidateFrame | None:
    if len(payload) < 70 or payload[0] != 0x2F:
        return None
    version = payload[1]
    if version not in SUPPORTED_RECORD_VERSIONS:
        return None
    try:
        timestamp = parse_timestamp(timestamp_text)
    except ValueError:
        return None
    return CandidateFrame(
        timestamp=timestamp,
        timestamp_text=timestamp_text.replace(" ", "T", 1),
        source_char=source_char.lower(),
        record_version=version,
        payload_length=len(payload),
        raw_u16_64=u16le(payload, 64),
        raw_u16_66=u16le(payload, 66),
        raw_u16_68=u16le(payload, 68),
        payload_sha256_prefix=hashlib.sha256(payload).hexdigest()[:16],
        transport_validated=transport_validated,
    )


def parse_frame_line(line: str) -> CandidateFrame | None:
    match = FRAME_RE.search(line)
    if match:
        try:
            raw = bytes.fromhex(match.group("hex"))
        except ValueError:
            return None
        declared_length = int(match.group("length"))
        if declared_length != len(raw):
            return None
        payload, codec_ok = decode_whoop_frame(raw)
        if not codec_ok:
            return None
        return candidate_from_payload(
            payload,
            match.group("timestamp"),
            match.group("channel"),
            transport_validated=True,
        )

    bare = BARE_RE.search(line.strip())
    if not bare:
        return None
    try:
        payload = bytes.fromhex(bare.group("hex"))
    except ValueError:
        return None
    return candidate_from_payload(
        payload,
        bare.group("timestamp"),
        bare.group("channel") or "bare",
        transport_validated=False,
    )


def parse_log(path: Path) -> list[CandidateFrame]:
    frames = [
        frame
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines()
        if (frame := parse_frame_line(line)) is not None
    ]
    return sorted(frames, key=lambda frame: frame.timestamp)


def export_frames(path: Path, frames: list[CandidateFrame]) -> None:
    fields = (
        "timestamp",
        "source_char",
        "record_version",
        "payload_length",
        "raw_u16_64",
        "raw_u16_66",
        "raw_u16_68",
        "ratio_64_66",
        "payload_sha256_prefix",
        "transport_validated",
    )
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for frame in frames:
            writer.writerow(
                {
                    "timestamp": frame.timestamp_text,
                    "source_char": frame.source_char,
                    "record_version": frame.record_version,
                    "payload_length": frame.payload_length,
                    "raw_u16_64": frame.raw_u16_64,
                    "raw_u16_66": frame.raw_u16_66,
                    "raw_u16_68": frame.raw_u16_68,
                    "ratio_64_66": format_optional(frame.ratio_64_66),
                    "payload_sha256_prefix": frame.payload_sha256_prefix,
                    "transport_validated": int(frame.transport_validated),
                }
            )


def optional_float(value: str | None) -> float | None:
    if value is None or not value.strip():
        return None
    try:
        parsed = float(value)
    except ValueError:
        return None
    return parsed if math.isfinite(parsed) else None


def parse_reference(path: Path) -> list[ReferenceRow]:
    rows: list[ReferenceRow] = []
    with path.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            try:
                timestamp = parse_timestamp(row.get("timestamp", ""))
            except ValueError:
                continue
            spo2 = optional_float(row.get("reference_spo2_percent"))
            temp = optional_float(row.get("reference_skin_temp_c"))
            if spo2 is None and temp is None:
                continue
            rows.append(ReferenceRow(timestamp, spo2, temp, row.get("label", "").strip()))
    return sorted(rows, key=lambda row: row.timestamp)


def pair_nearest(
    frames: list[CandidateFrame], references: list[ReferenceRow], max_age_s: float
) -> list[MatchedRow]:
    matches: list[MatchedRow] = []
    for frame in frames:
        if not references:
            break
        nearest = min(references, key=lambda row: abs((row.timestamp - frame.timestamp).total_seconds()))
        age = abs((nearest.timestamp - frame.timestamp).total_seconds())
        if age <= max_age_s:
            matches.append(MatchedRow(frame, nearest, age))
    return matches


def pearson(xs: list[float], ys: list[float]) -> float | None:
    if len(xs) < 3 or len(xs) != len(ys):
        return None
    mean_x, mean_y = statistics.mean(xs), statistics.mean(ys)
    numerator = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys))
    denominator = math.sqrt(
        sum((x - mean_x) ** 2 for x in xs) * sum((y - mean_y) ** 2 for y in ys)
    )
    return numerator / denominator if denominator else None


def correlation(matches: list[MatchedRow], metric: str, channel: str) -> float | None:
    pairs: list[tuple[float, float]] = []
    for match in matches:
        reference = (
            match.reference.spo2_percent
            if metric == "spo2"
            else match.reference.skin_temp_c
        )
        candidate = (
            match.frame.ratio_64_66
            if channel == "ratio_64_66"
            else float(getattr(match.frame, channel))
        )
        if reference is not None and candidate is not None:
            pairs.append((candidate, reference))
    return pearson([pair[0] for pair in pairs], [pair[1] for pair in pairs])


def value_range(frames: list[CandidateFrame], field: str) -> str:
    values = [getattr(frame, field) for frame in frames]
    return f"{min(values)}..{max(values)}" if values else "none"


def format_optional(value: float | None) -> str:
    return "none" if value is None else f"{value:.6f}"


def summarize(
    frames: list[CandidateFrame], references: list[ReferenceRow], max_pair_age_s: float
) -> dict[str, str]:
    matches = pair_nearest(frames, references, max_pair_age_s)
    summary = {
        "status": "research_unvalidated",
        "decoder_validated": "0",
        "metric_promotions": "0",
        "candidate_frames": str(len(frames)),
        "transport_validated_frames": str(sum(frame.transport_validated for frame in frames)),
        "record_versions": ",".join(map(str, sorted({frame.record_version for frame in frames}))) or "none",
        "payload_lengths": ",".join(map(str, sorted({frame.payload_length for frame in frames}))) or "none",
        "raw_u16_64_range": value_range(frames, "raw_u16_64"),
        "raw_u16_66_range": value_range(frames, "raw_u16_66"),
        "raw_u16_68_range": value_range(frames, "raw_u16_68"),
        "reference_rows": str(len(references)),
        "nearest_reference_matches": str(len(matches)),
        "max_pair_age_s": format_optional(max_pair_age_s),
    }
    for metric in ("spo2", "skin_temp"):
        for channel in ("raw_u16_64", "raw_u16_66", "raw_u16_68", "ratio_64_66"):
            summary[f"candidate_corr_{channel}_vs_{metric}"] = format_optional(
                correlation(matches, metric, channel)
            )
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, help="ATRIADBG log or timestamp[,channel],payload-hex file")
    parser.add_argument("--export-csv", type=Path)
    parser.add_argument("--reference-csv", type=Path)
    parser.add_argument("--max-pair-age-s", type=float, default=2.0)
    args = parser.parse_args()
    if args.max_pair_age_s < 0:
        parser.error("--max-pair-age-s must be non-negative")

    try:
        frames = parse_log(args.log)
        references = parse_reference(args.reference_csv) if args.reference_csv else []
    except OSError as error:
        print("status=error")
        print("decoder_validated=0")
        print("metric_promotions=0")
        print(f"reason=file_read_failed:{type(error).__name__}")
        return 2
    if not frames:
        print("status=fail")
        print("decoder_validated=0")
        print("metric_promotions=0")
        print("reason=no_crc_valid_supported_historical_frames")
        return 2
    if args.export_csv:
        export_frames(args.export_csv, frames)
    for key, value in summarize(frames, references, args.max_pair_age_s).items():
        print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
