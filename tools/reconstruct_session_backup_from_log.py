#!/usr/bin/env python3
"""Rebuild a Atria session backup from real ATRIADBG realtimeFrame logs.

This is a recovery tool for physical-device evidence only. It never fabricates
RR intervals or validated HRV; it reconstructs the compact saved HR time series
from logged realtime HR bytes and marks HRV as reference-unvalidated.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import uuid
from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


TIMESTAMP_FMT = "%Y-%m-%d %H:%M:%S.%f"
REALTIME_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}).*"
    r"ATRIADBG realtimeFrame hrByte=(?P<hr>\d+)"
)
CHECKPOINT_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}).*"
    r"ATRIADBG session_checkpoint status=saved "
    r"samples=(?P<samples>\d+) duration_s=(?P<duration>[0-9.]+) "
    r"avg_hr=(?P<avg>\d+) peak_hr=(?P<peak>\d+) resting_hr=(?P<resting>\d+) "
    r"hrv=(?P<hrv>\S+) label=(?P<label>.+?) checkpoint_index=(?P<index>\d+) "
    r"mode=(?P<mode>\S+)"
)


@dataclass(frozen=True)
class Frame:
    timestamp: datetime
    bpm: int


@dataclass(frozen=True)
class Checkpoint:
    timestamp: datetime
    samples: int
    duration_s: float
    avg_hr: int
    peak_hr: int
    resting_hr: int
    hrv: int | None
    label: str
    index: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, type=Path, help="ATRIADBG live-device.log")
    parser.add_argument(
        "--base-backup",
        required=True,
        type=Path,
        help="Existing Atria backup JSON to copy baseline/profile and merge sessions from",
    )
    parser.add_argument("--out", required=True, type=Path, help="Output backup JSON")
    parser.add_argument(
        "--source-timezone",
        default="+05:30",
        help="Timezone of log timestamps, e.g. +05:30. Defaults to Asia/Kolkata offset.",
    )
    parser.add_argument(
        "--label",
        default=None,
        help="Override the reconstructed session label. Defaults to final checkpoint label.",
    )
    parser.add_argument(
        "--keep-checkpoint-hrv",
        action="store_true",
        help="Preserve checkpoint RMSSD value but keep hrvReferenceValidated=false.",
    )
    parser.add_argument(
        "--replace-label",
        action="append",
        default=[],
        help="Drop existing sessions with this label before adding reconstructed session.",
    )
    return parser.parse_args()


def parse_timezone(value: str) -> timezone:
    match = re.fullmatch(r"([+-])(\d{2}):?(\d{2})", value)
    if not match:
        raise SystemExit(f"Invalid --source-timezone {value!r}; expected +HH:MM")
    sign = 1 if match.group(1) == "+" else -1
    hours = int(match.group(2))
    minutes = int(match.group(3))
    return timezone(sign * timedelta(hours=hours, minutes=minutes))


def parse_local_timestamp(value: str, tz: timezone) -> datetime:
    return datetime.strptime(value, TIMESTAMP_FMT).replace(tzinfo=tz)


def parse_log(path: Path, tz: timezone) -> tuple[list[Frame], Checkpoint]:
    frames: list[Frame] = []
    checkpoints: list[Checkpoint] = []

    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            frame_match = REALTIME_RE.search(line)
            if frame_match:
                frames.append(
                    Frame(
                        timestamp=parse_local_timestamp(frame_match.group("ts"), tz),
                        bpm=int(frame_match.group("hr")),
                    )
                )
                continue

            checkpoint_match = CHECKPOINT_RE.search(line)
            if checkpoint_match:
                hrv_text = checkpoint_match.group("hrv")
                checkpoints.append(
                    Checkpoint(
                        timestamp=parse_local_timestamp(checkpoint_match.group("ts"), tz),
                        samples=int(checkpoint_match.group("samples")),
                        duration_s=float(checkpoint_match.group("duration")),
                        avg_hr=int(checkpoint_match.group("avg")),
                        peak_hr=int(checkpoint_match.group("peak")),
                        resting_hr=int(checkpoint_match.group("resting")),
                        hrv=None if hrv_text == "learning" else int(hrv_text),
                        label=checkpoint_match.group("label"),
                        index=int(checkpoint_match.group("index")),
                    )
                )

    if not frames:
        raise SystemExit(f"No ATRIADBG realtimeFrame rows found in {path}")
    if not checkpoints:
        raise SystemExit(f"No saved session_checkpoint rows found in {path}")
    return frames, checkpoints[-1]


def iso_z(value: datetime) -> str:
    utc = value.astimezone(timezone.utc).replace(microsecond=0)
    return utc.isoformat().replace("+00:00", "Z")


def build_points(frames: list[Frame], checkpoint: Checkpoint) -> list[dict[str, Any]]:
    selected = [frame for frame in frames if frame.timestamp <= checkpoint.timestamp]
    if not selected:
        raise SystemExit("No realtimeFrame rows occur before the final checkpoint")

    start = selected[0].timestamp
    points = [
        {"t": round((frame.timestamp - start).total_seconds(), 3), "bpm": frame.bpm}
        for frame in selected
    ]
    return points


def reconstructed_session(
    *,
    frames: list[Frame],
    checkpoint: Checkpoint,
    label: str,
    keep_checkpoint_hrv: bool,
) -> dict[str, Any]:
    selected = [frame for frame in frames if frame.timestamp <= checkpoint.timestamp]
    if not selected:
        raise SystemExit("No realtimeFrame rows occur before the final checkpoint")

    start = selected[0].timestamp
    end = selected[-1].timestamp
    points = build_points(frames, checkpoint)
    duration = (end - start).total_seconds()

    if duration < 3 * 60 * 60:
        raise SystemExit(f"Reconstructed session is too short for sleep fallback: {duration:.1f}s")

    return {
        "end": iso_z(end),
        "hrv": checkpoint.hrv if keep_checkpoint_hrv else None,
        "hrvReferenceValidated": False,
        "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"whoop-log:{label}:{iso_z(start)}:{len(points)}")),
        "label": label,
        "points": points,
        "start": iso_z(start),
    }


def merge_backup(base: dict[str, Any], session: dict[str, Any], replace_labels: list[str]) -> dict[str, Any]:
    merged = deepcopy(base)
    sessions = [
        existing
        for existing in merged.get("sessions", [])
        if existing.get("label") not in set(replace_labels + [session["label"]])
    ]
    sessions.append(session)
    sessions.sort(key=lambda item: item.get("start", ""))
    merged["sessions"] = sessions
    merged["createdAt"] = iso_z(datetime.now(timezone.utc))
    merged["schema"] = 1
    merged["app"] = "Atria.local"
    return merged


def main() -> int:
    args = parse_args()
    tz = parse_timezone(args.source_timezone)
    frames, checkpoint = parse_log(args.log, tz)
    label = args.label or checkpoint.label

    with args.base_backup.open("r", encoding="utf-8") as handle:
        base = json.load(handle)

    session = reconstructed_session(
        frames=frames,
        checkpoint=checkpoint,
        label=label,
        keep_checkpoint_hrv=args.keep_checkpoint_hrv,
    )
    merged = merge_backup(base, session, args.replace_label)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as handle:
        json.dump(merged, handle, indent=2, sort_keys=True)
        handle.write("\n")

    points = session["points"]
    bpms = [point["bpm"] for point in points]
    print(f"output={args.out}")
    print(f"base_sessions={len(base.get('sessions', []))}")
    print(f"merged_sessions={len(merged.get('sessions', []))}")
    print(f"label={session['label']}")
    print(f"start={session['start']}")
    print(f"end={session['end']}")
    print(f"points={len(points)}")
    print(f"duration_s={points[-1]['t']:.3f}")
    print(f"checkpoint_samples={checkpoint.samples}")
    print(f"checkpoint_duration_s={checkpoint.duration_s:.0f}")
    print(f"avg_hr={sum(bpms) // len(bpms)}")
    print(f"peak_hr={max(bpms)}")
    print(f"resting_hr={min(bpms)}")
    print(f"hrv_reference_validated={session['hrvReferenceValidated']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
