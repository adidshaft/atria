#!/usr/bin/env python3
"""Compare WHOOP history ACK-mode experiment logs.

This is an evidence summarizer for Gate B protocol work. It does not validate
historical RR or produce clinical HRV.
"""

from __future__ import annotations

import argparse
import re
import statistics
from pathlib import Path

import analyze_historical_2f as hist


ACK_MODE_RE = re.compile(r"history_ack_mode=([a-z]+)")
CMD_STATUS_RE = re.compile(r"cmd_response_statuses=(.*)")
HISTORY_ACK_RE = re.compile(r"historyAck mode=([a-z]+).*?cursor=(\d+)")


def summary_value(lines: list[str], key: str) -> str:
    prefix = f"{key}="
    for line in lines:
        if line.startswith(prefix):
            return line[len(prefix):].strip()
    return ""


def ack_mode(lines: list[str], path: Path) -> str:
    for line in lines:
        match = ACK_MODE_RE.search(line)
        if match:
            return match.group(1)
    name = path.name.lower()
    for candidate in ("trim", "index", "unix", "zero", "none"):
        if candidate in name:
            return candidate
    return "unknown"


def ack_status_count(lines: list[str]) -> int:
    statuses = summary_value(lines, "cmd_response_statuses")
    if not statuses:
        return 0
    return statuses.count("cmd=0x17:status=0001000000")


def ack_cursor_span(lines: list[str]) -> str:
    cursors = [int(match.group(2)) for line in lines for match in [HISTORY_ACK_RE.search(line)] if match]
    if not cursors:
        return ""
    unique = sorted(set(cursors))
    return f"{unique[0]}..{unique[-1]} ({len(unique)} unique)"


def hr_agreement(frames: list[hist.HistoricalFrame], offset: int, hr_offset: int = 17) -> str:
    pairs: list[tuple[int, float]] = []
    for frame in frames:
        payload = frame.payload
        if offset + 1 >= len(payload) or hr_offset >= len(payload):
            continue
        rr = hist.u16le(payload, offset)
        hr = payload[hr_offset]
        if 300 <= rr <= 2000 and hr > 0:
            pairs.append((hr, 60000 / rr))
    if not pairs:
        return ""
    errors = [abs(hr - implied) for hr, implied in pairs]
    within_10 = sum(1 for error in errors if error <= 10) / len(errors) * 100
    return (
        f"samples={len(pairs)} "
        f"mae={statistics.mean(errors):.1f} "
        f"within10={within_10:.0f}%"
    )


def summarize(path: Path) -> dict[str, str]:
    lines = path.read_text(errors="ignore").splitlines()
    frames = hist.extract_frames(path)
    realtime = hist.extract_realtime_frames(path)
    overlap = hist.live_overlap_report(frames, realtime)
    return {
        "path": str(path),
        "mode": ack_mode(lines, path),
        "hrv_ready": summary_value(lines, "hrv_ready"),
        "rt_rr_fraction": summary_value(lines, "realtime_rr_fraction"),
        "hist_frames": str(len(frames)),
        "hist_start": str(overlap.get("historical_start_unix", "")),
        "hist_end": str(overlap.get("historical_end_unix", "")),
        "hist_span_s": str(overlap.get("historical_span_s", "")),
        "rt_start": str(overlap.get("realtime_start_unix", "")),
        "rt_end": str(overlap.get("realtime_end_unix", "")),
        "overlap_s": str(overlap.get("overlap_seconds", "")),
        "separation_s": str(overlap.get("separation_seconds", "")),
        "ack_ok": str(ack_status_count(lines)),
        "ack_cursor_span": ack_cursor_span(lines),
        "offset19": hr_agreement(frames, 19),
        "offset68": hr_agreement(frames, 68),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+", type=Path, help="ATRIADBG log files")
    args = parser.parse_args()

    rows = [summarize(path) for path in args.logs]
    headers = [
        "mode",
        "hist_frames",
        "hist_start",
        "hist_end",
        "hist_span_s",
        "rt_start",
        "rt_end",
        "overlap_s",
        "separation_s",
        "ack_ok",
        "ack_cursor_span",
        "rt_rr_fraction",
        "hrv_ready",
        "offset19",
        "offset68",
        "path",
    ]
    print("\t".join(headers))
    for row in rows:
        print("\t".join(row.get(header, "") for header in headers))
    print("warning=provisional_protocol_evidence_not_clinical_hrv")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
