#!/usr/bin/env python3
"""Extract candidate fields from WHOOP GET_DATA_RANGE (0x22) responses.

This is an evidence tool, not a decoder contract. The 0x22 layout is not
validated yet, so we print overlapping little-endian fields and highlight
Unix-looking values for follow-up SET_READ_POINTER experiments.
"""

from __future__ import annotations

import argparse
import datetime as dt
import pathlib
import re
import struct

import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from whoop_codec import decode as decode_whoop_frame  # noqa: E402


SUMMARY_CMD22_RE = re.compile(r"cmd=0x22:status=([0-9a-fA-F]+)")
DATA_RANGE_RE = re.compile(r"data_range_response .*? status=([0-9a-fA-F]+)")
DATA_RANGE_DETAIL_RE = re.compile(
    r"data_range_response .*? request_index=(-?\d+) request_data=([0-9a-fA-F]+|unknown) .*? status=([0-9a-fA-F]+)"
)
CMDRESP_PAYLOAD_RE = re.compile(r"cmdResp .*? payload=24[0-9a-fA-F]{2}22([0-9a-fA-F]+)")
FRAME_RE = re.compile(r"frame ch=(6108000[3457]) len=(\d+) hex=([0-9a-fA-F]+)")


def u32le(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def u16le(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def looks_like_unix(value: int) -> bool:
    # Broad enough for strap clocks and historical captures in current evidence.
    return 1_500_000_000 <= value <= 2_200_000_000


def iso(value: int) -> str:
    return dt.datetime.fromtimestamp(value, tz=dt.UTC).isoformat()


def historical_unix_range(text: str) -> tuple[int | None, int | None, int]:
    values: list[int] = []
    for match in FRAME_RE.finditer(text):
        raw = bytes.fromhex(match.group(3))
        if len(raw) < 8:
            continue
        payload, ok = decode_whoop_frame(raw)
        if not ok or len(payload) < 11 or payload[0] != 0x2f:
            continue
        unix = struct.unpack_from("<I", payload, 7)[0]
        if looks_like_unix(unix):
            values.append(unix)
    if not values:
        return None, None, 0
    return min(values), max(values), len(values)


def analyze_status(
    hex_status: str,
    historical_first: int | None,
    historical_last: int | None,
) -> list[str]:
    raw = bytes.fromhex(hex_status)
    lines = [
        f"status_hex={raw.hex()}",
        f"status_len={len(raw)}",
        f"lead={raw[:3].hex() if len(raw) >= 3 else raw.hex()}",
    ]
    body = raw[3:] if len(raw) >= 3 else b""
    lines.append(f"body_len={len(body)}")
    nearest_first: tuple[int, int, int] | None = None
    nearest_last: tuple[int, int, int] | None = None
    for offset in range(0, max(0, len(body) - 3), 2):
        value = u32le(body, offset)
        suffix = f" unix={iso(value)}" if looks_like_unix(value) else ""
        lines.append(f"u32_body_offset_{offset}={value}{suffix}")
        if looks_like_unix(value) and historical_first is not None:
            delta = abs(value - historical_first)
            if nearest_first is None or delta < nearest_first[2]:
                nearest_first = (offset, value, delta)
        if looks_like_unix(value) and historical_last is not None:
            delta = abs(value - historical_last)
            if nearest_last is None or delta < nearest_last[2]:
                nearest_last = (offset, value, delta)
    u16_pairs = []
    for offset in range(0, max(0, len(body) - 1), 2):
        u16_pairs.append(f"{offset}:{u16le(body, offset)}")
    lines.append(f"u16_body_offsets={','.join(u16_pairs)}")
    if nearest_first is not None:
        offset, value, delta = nearest_first
        lines.append(
            f"nearest_historical_first_u32_offset={offset} value={value} "
            f"delta_s={delta}"
        )
    if nearest_last is not None:
        offset, value, delta = nearest_last
        lines.append(
            f"nearest_historical_last_u32_offset={offset} value={value} "
            f"delta_s={delta}"
        )
    return lines


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=pathlib.Path)
    args = parser.parse_args()

    text = args.log.read_text(errors="replace")
    historical_first, historical_last, historical_count = historical_unix_range(text)
    if historical_count:
        print(f"historical_2f_unix_count={historical_count}")
        print(f"historical_2f_unix_first={historical_first} unix={iso(historical_first)}")
        print(f"historical_2f_unix_last={historical_last} unix={iso(historical_last)}")
    else:
        print("historical_2f_unix_count=0")

    matches: list[tuple[str, str, str | None, str | None]] = []
    seen: set[str] = set()
    for request_index, request_data, status in DATA_RANGE_DETAIL_RE.findall(text):
        normalized = status.lower()
        if normalized in seen:
            continue
        seen.add(normalized)
        matches.append(("data_range_log", normalized, request_index, request_data.lower()))
    for source, pattern in (
        ("summary", SUMMARY_CMD22_RE),
        ("data_range_log", DATA_RANGE_RE),
        ("cmdresp_payload", CMDRESP_PAYLOAD_RE),
    ):
        for status in pattern.findall(text):
            normalized = status.lower()
            if normalized in seen:
                continue
            seen.add(normalized)
            matches.append((source, normalized, None, None))
    if not matches:
        print("cmd22_responses=0")
        return 1

    print(f"cmd22_responses={len(matches)}")
    for index, (source, status, request_index, request_data) in enumerate(matches):
        print(f"response_index={index}")
        print(f"source={source}")
        if request_index is not None:
            print(f"request_index={request_index}")
        if request_data is not None:
            print(f"request_data={request_data}")
        for line in analyze_status(status, historical_first, historical_last):
            print(line)
    print("interpretation=layout_unvalidated_do_not_use_as_set_read_pointer_without_device_test")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
