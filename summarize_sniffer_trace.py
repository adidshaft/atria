#!/usr/bin/env python3
"""Summarize WHOOP BLE sniffer CSV exports for Gate B protocol evidence."""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from whoop_codec import decode


COMMAND = 0x23
CMD_RESP = 0x24
REALTIME = 0x28

TIME_COLUMNS = ("timestamp", "time", "time_s", "seconds", "elapsed_s", "elapsed_ms")
DIRECTION_COLUMNS = ("direction", "dir", "operation", "op", "type")
UUID_COLUMNS = ("uuid", "characteristic", "char_uuid", "handle_uuid", "att_uuid", "handle")
DATA_COLUMNS = ("data", "value", "payload", "bytes", "packet", "hex", "raw")

UUID_LABELS = {
    "61080002": "61080002 tx",
    "61080003": "61080003 cmd-resp",
    "61080004": "61080004 event",
    "61080005": "61080005 realtime",
    "61080007": "61080007",
    "2a37": "2A37 HR",
}


@dataclass(frozen=True)
class TraceEvent:
    row: int
    time_s: float | None
    direction: str
    uuid: str
    raw_hex: str
    payload: bytes
    ok: bool


def norm_key(value: str | None) -> str:
    return "".join(ch for ch in (value or "").lower() if ch.isalnum())


def first_value(row: dict[str, str], names: Iterable[str]) -> str:
    for name in names:
        value = row.get(norm_key(name), "")
        if value:
            return value.strip()
    return ""


def parse_time(value: str) -> float | None:
    if not value:
        return None
    cleaned = value.strip().rstrip("s")
    try:
        parsed = float(cleaned)
    except ValueError:
        return None
    if parsed > 10_000:
        return parsed / 1000.0
    return parsed


def parse_hex(value: str) -> bytes:
    cleaned = value.strip()
    if not cleaned:
        return b""
    for prefix in ("0x", "hex:"):
        cleaned = cleaned.replace(prefix, "")
    for sep in (" ", ":", "-", ",", "\t"):
        cleaned = cleaned.replace(sep, "")
    if len(cleaned) % 2:
        cleaned = "0" + cleaned
    return bytes.fromhex(cleaned)


def extract_whoop_payload(raw: bytes) -> tuple[bytes, bool]:
    if not raw:
        return b"", False
    starts = [index for index, byte in enumerate(raw) if byte == 0xAA]
    if raw and raw[0] != 0xAA and 0 not in starts:
        starts.insert(0, 0)
    if raw and raw[0] == 0xAA:
        starts.insert(0, 0)
    for start in dict.fromkeys(starts):
        candidate = raw[start:]
        payload, ok = decode(candidate)
        if ok:
            return payload, True
    return raw, False


def load_events(path: Path) -> list[TraceEvent]:
    events: list[TraceEvent] = []
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        for index, raw_row in enumerate(reader, start=2):
            normalized = {field: norm_key(field) for field in (reader.fieldnames or [])}
            row = {normalized[key]: value for key, value in raw_row.items() if key is not None}
            raw_value = first_value(row, DATA_COLUMNS)
            if not raw_value:
                continue
            try:
                raw = parse_hex(raw_value)
            except ValueError:
                continue
            payload, ok = extract_whoop_payload(raw)
            if not payload:
                continue
            events.append(
                TraceEvent(
                    row=index,
                    time_s=parse_time(first_value(row, TIME_COLUMNS)),
                    direction=first_value(row, DIRECTION_COLUMNS),
                    uuid=first_value(row, UUID_COLUMNS),
                    raw_hex=raw.hex(),
                    payload=payload,
                    ok=ok,
                )
            )
    return events


def short_uuid(value: str) -> str:
    lowered = value.lower()
    for key, label in UUID_LABELS.items():
        if key in lowered:
            return label
    return value or "unknown-char"


def direction_label(value: str) -> str:
    lowered = value.lower()
    if "write" in lowered:
        return "write"
    if "notify" in lowered or "notification" in lowered:
        return "notify"
    if "read" in lowered:
        return "read"
    return value or "unknown-dir"


def realtime_rr(payload: bytes) -> tuple[int | None, list[int]]:
    if len(payload) < 10 or payload[0] != REALTIME:
        return None, []
    rr_count = payload[9]
    values: list[int] = []
    offset = 10
    while offset + 1 < len(payload) and len(values) < rr_count:
        values.append(payload[offset] | (payload[offset + 1] << 8))
        offset += 2
    return rr_count, values


def fmt_time(value: float | None) -> str:
    if value is None:
        return "n/a"
    return f"{value:.3f}s"


def event_summary(event: TraceEvent) -> str:
    payload = event.payload
    prefix = f"- row {event.row} t={fmt_time(event.time_s)} {direction_label(event.direction)} {short_uuid(event.uuid)}"
    if not event.ok:
        return f"{prefix}: undecoded raw={event.raw_hex}"
    if payload[0] == COMMAND and len(payload) >= 3:
        return f"{prefix}: COMMAND seq={payload[1]} cmd=0x{payload[2]:02x} data={payload[3:].hex() or '-'}"
    if payload[0] == CMD_RESP and len(payload) >= 3:
        return f"{prefix}: CMD_RESP seq={payload[1]} cmd=0x{payload[2]:02x} status={payload[3:].hex() or '-'}"
    if payload[0] == REALTIME:
        hr = payload[8] if len(payload) > 8 else None
        rr_count, rr_values = realtime_rr(payload)
        rr_text = ",".join(str(value) for value in rr_values) if rr_values else "-"
        return f"{prefix}: REALTIME hr={hr} rrnum={rr_count} values={rr_text}"
    return f"{prefix}: type=0x{payload[0]:02x} payload={payload.hex()}"


def build_report(path: Path, events: list[TraceEvent]) -> str:
    decoded = [event for event in events if event.ok]
    commands = [event for event in decoded if event.payload and event.payload[0] == COMMAND]
    responses = [event for event in decoded if event.payload and event.payload[0] == CMD_RESP]
    realtime = [event for event in decoded if event.payload and event.payload[0] == REALTIME]
    rr_bearing: list[TraceEvent] = []
    zero_rr = 0
    rr_values_total = 0
    for event in realtime:
        rr_count, rr_values = realtime_rr(event.payload)
        if rr_count == 0:
            zero_rr += 1
        if rr_values:
            rr_bearing.append(event)
            rr_values_total += len(rr_values)

    lines = [
        "# WHOOP Sniffer Trace Summary",
        "",
        f"- source: `{path}`",
        f"- CSV rows with byte payloads: {len(events)}",
        f"- WHOOP frames decoded by `whoop_codec.py`: {len(decoded)}",
        f"- command writes: {len(commands)}",
        f"- command responses: {len(responses)}",
        f"- realtime frames: {len(realtime)}",
        f"- RR-bearing realtime frames: {len(rr_bearing)}",
        f"- zero-RR realtime frames: {zero_rr}",
        f"- decoded RR values: {rr_values_total}",
        "",
        "## Command Writes",
    ]
    lines.extend(event_summary(event) for event in commands[:40])
    if len(commands) > 40:
        lines.append(f"- ... {len(commands) - 40} more command writes omitted")
    lines.extend(["", "## Command Responses"])
    lines.extend(event_summary(event) for event in responses[:40])
    if len(responses) > 40:
        lines.append(f"- ... {len(responses) - 40} more command responses omitted")
    lines.extend(["", "## First Realtime Frames"])
    lines.extend(event_summary(event) for event in realtime[:20])
    if len(realtime) > 20:
        lines.append(f"- ... {len(realtime) - 20} more realtime frames omitted")
    lines.extend(
        [
            "",
            "## Interpretation Checklist",
            "",
            "- Identify the official app command immediately before RR-bearing realtime frames start.",
            "- Compare command response status bytes against failed iPhone/Mac probe attempts.",
            "- Confirm the trace includes steady RR-bearing frames, not only initial setup bursts.",
            "- Do not treat this report as Gate B validation; it is protocol evidence only.",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv_path", type=Path, help="Sniffer CSV export to summarize")
    parser.add_argument("-o", "--output", type=Path, help="Markdown report path")
    args = parser.parse_args()

    events = load_events(args.csv_path)
    if not events:
        raise SystemExit("no byte payload rows found in sniffer CSV")

    report = build_report(args.csv_path, events)
    if args.output:
        args.output.write_text(report)
    else:
        print(report, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
