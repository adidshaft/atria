#!/usr/bin/env python3
"""Find Gate-B-ready live RR windows in WHOOPDBG logs.

This evidence tool uses only logged realtime RR/IBI values. It never estimates
RR from HR-only frames.
"""

from __future__ import annotations

import argparse
import datetime as dt
import math
import re
import statistics
from dataclasses import dataclass
from pathlib import Path


RR_RE = re.compile(
    r"^(?P<stamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)"
    r".*WHOOPDBG rr (?P<body>.*) values=(?P<values>[0-9,]+)"
)


@dataclass
class Beat:
    timestamp: float
    stamp: str
    rr_ms: int
    source: str


@dataclass
class Window:
    start: str
    end: str
    span_s: float
    raw: int
    kept: int
    confidence: float
    max_gap_s: float
    rmssd_ms: float
    sdnn_ms: float
    pnn50: float
    lnrmssd: float


def token_value(body: str, key: str) -> str:
    match = re.search(rf"(?:^|\s){re.escape(key)}=([^\s]+)", body)
    return match.group(1) if match else ""


def format_stamp(timestamp: dt.datetime) -> str:
    return timestamp.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


def parse_beats(path: Path, *, source_filter: str, used_only: bool) -> list[Beat]:
    beats: list[Beat] = []
    for line in path.read_text(errors="ignore").splitlines():
        match = RR_RE.match(line)
        if not match:
            continue
        body = match.group("body")
        source = token_value(body, "source") or "unknown"
        normalized_source = source.lower().removeprefix("0x")
        if source_filter != "all" and normalized_source != source_filter:
            continue
        if used_only and token_value(body, "used") == "0":
            continue

        received_at = dt.datetime.fromisoformat(match.group("stamp"))
        values = [int(value) for value in match.group("values").split(",") if value]
        remaining_after_ms = sum(values)
        for value in values:
            remaining_after_ms -= value
            beat_at = received_at - dt.timedelta(milliseconds=remaining_after_ms)
            beats.append(
                Beat(
                    timestamp=beat_at.timestamp(),
                    stamp=format_stamp(beat_at),
                    rr_ms=value,
                    source=source,
                )
            )
    beats.sort(key=lambda beat: beat.timestamp)
    return beats


def corrected(values: list[int]) -> list[int]:
    kept: list[int] = []
    previous: int | None = None
    for value in values:
        if not 300 <= value <= 2000:
            continue
        if previous is not None and abs(value - previous) / previous > 0.20:
            continue
        kept.append(value)
        previous = value
    return kept


def metrics(beats: list[Beat]) -> Window | None:
    values = [beat.rr_ms for beat in beats]
    kept = corrected(values)
    if len(kept) < 2:
        return None

    times = [beat.timestamp for beat in beats]
    gaps = [b - a for a, b in zip(times, times[1:])]
    diffs = [b - a for a, b in zip(kept, kept[1:])]
    rmssd = math.sqrt(sum(diff * diff for diff in diffs) / len(diffs))
    sdnn = statistics.pstdev(kept)
    pnn50 = 100.0 * sum(1 for diff in diffs if abs(diff) > 50) / len(diffs)

    return Window(
        start=beats[0].stamp,
        end=beats[-1].stamp,
        span_s=times[-1] - times[0],
        raw=len(values),
        kept=len(kept),
        confidence=100.0 * len(kept) / len(values),
        max_gap_s=max(gaps) if gaps else 999.0,
        rmssd_ms=rmssd,
        sdnn_ms=sdnn,
        pnn50=pnn50,
        lnrmssd=math.log(rmssd) if rmssd > 0 else float("nan"),
    )


def ready_windows(
    beats: list[Beat],
    *,
    window_s: float,
    max_gap_s: float,
    min_kept: int,
    min_confidence: float,
) -> list[Window]:
    windows: list[Window] = []
    for start_index, start in enumerate(beats):
        end_index = start_index
        while end_index < len(beats) and beats[end_index].timestamp <= start.timestamp + window_s:
            end_index += 1
        candidate = beats[start_index:end_index]
        if not candidate:
            continue
        result = metrics(candidate)
        if result is None:
            continue
        if result.span_s < window_s:
            continue
        if result.max_gap_s > max_gap_s:
            continue
        if result.kept < min_kept:
            continue
        if result.confidence < min_confidence:
            continue
        windows.append(result)
    return windows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--window-s", type=float, default=300.0)
    parser.add_argument("--max-gap-s", type=float, default=3.0)
    parser.add_argument("--min-kept", type=int, default=240)
    parser.add_argument("--min-confidence", type=float, default=75.0)
    parser.add_argument(
        "--source",
        choices=("all", "2a37", "28"),
        default="all",
        help="Restrict analysis to a real RR source. 2a37 is standard BLE Heart Rate Measurement.",
    )
    parser.add_argument(
        "--used-only",
        action="store_true",
        help="Ignore logged diagnostic RR frames marked used=0.",
    )
    parser.add_argument("--limit", type=int, default=5)
    args = parser.parse_args()

    beats = parse_beats(args.log, source_filter=args.source, used_only=args.used_only)
    windows = ready_windows(
        beats,
        window_s=args.window_s,
        max_gap_s=args.max_gap_s,
        min_kept=args.min_kept,
        min_confidence=args.min_confidence,
    )
    windows.sort(key=lambda item: (item.confidence, item.kept, -item.max_gap_s), reverse=True)

    print(f"source={args.source}")
    print(f"used_only={int(args.used_only)}")
    print(f"rr_beats={len(beats)}")
    print(f"ready_windows={len(windows)}")
    for index, window in enumerate(windows[: args.limit], start=1):
        print(
            f"window_{index} "
            f"start={window.start} end={window.end} span_s={window.span_s:.1f} "
            f"raw={window.raw} kept={window.kept} conf={window.confidence:.1f} "
            f"max_gap_s={window.max_gap_s:.3f} rmssd_ms={window.rmssd_ms:.1f} "
            f"sdnn_ms={window.sdnn_ms:.1f} pnn50={window.pnn50:.1f} "
            f"lnrmssd={window.lnrmssd:.3f}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
