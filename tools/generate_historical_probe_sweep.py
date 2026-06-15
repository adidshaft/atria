#!/usr/bin/env python3
"""Emit retired WHOOP 0x06 historical-transfer probe candidates.

These candidates were transfer-shaped hypotheses for the existing iPhone
harness. Physical-device evidence showed only fixed 0x06 status responses and no
0x2f frames. A later cross-check of madhursatija/whoof indicates the real
historical start path is command 0x16 with 0x31 metadata and 0x17 ACKs, so this
tool is retained only to reproduce/understand the retired negative-evidence
batches.
"""

from __future__ import annotations

import argparse
import struct
from dataclasses import dataclass


@dataclass(frozen=True)
class Candidate:
    label: str
    payload: bytes
    note: str


def le16(value: int) -> bytes:
    return struct.pack("<H", value)


def le32(value: int) -> bytes:
    return struct.pack("<I", value)


def candidates() -> list[Candidate]:
    items: list[Candidate] = []

    # Baseline status selectors, repeated here so a run can compare known ACKs
    # against transfer-shaped variants without mixing separate evidence folders.
    for selector in range(0x00, 0x04):
        items.append(
            Candidate(
                label=f"selector-{selector:02x}",
                payload=bytes([0x06, selector]),
                note="known selector/status shape; expected no 0x2f",
            )
        )

    # Common request idioms: subcommand + offset + count/window.
    for subcmd in (0x01, 0x02, 0x03):
        for count in (1, 16, 64):
            items.append(
                Candidate(
                    label=f"sub{subcmd:02x}-off0-count{count}",
                    payload=bytes([0x06, subcmd]) + le32(0) + le16(count),
                    note="subcommand plus little-endian offset/count",
                )
            )

    # Same idea with an explicit stream/type byte before offset/count.
    for stream in (0x00, 0x01, 0x02):
        for count in (1, 16):
            items.append(
                Candidate(
                    label=f"stream{stream:02x}-off0-count{count}",
                    payload=bytes([0x06, 0x01, stream]) + le32(0) + le16(count),
                    note="subcommand plus stream/type byte, offset, count",
                )
            )

    # Range-shaped requests. Zero start/end sometimes means "latest" in embedded
    # protocols; the 300s/24h ranges test whether the strap interprets timestamps.
    ranges = (
        ("zero-range", 0, 0),
        ("last-300s", 300, 0),
        ("last-24h", 86_400, 0),
    )
    for label, start, end in ranges:
        items.append(
            Candidate(
                label=label,
                payload=bytes([0x06, 0x04]) + le32(start) + le32(end),
                note="range-shaped request",
            )
        )

    return items


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--batch-size",
        type=int,
        default=8,
        help="number of payloads per --probe-sweep batch (default: 8)",
    )
    parser.add_argument(
        "--format",
        choices=("sweeps", "table"),
        default="sweeps",
        help="output format",
    )
    args = parser.parse_args()

    if args.batch_size <= 0:
        parser.error("--batch-size must be positive")

    items = candidates()

    if args.format == "table":
        print("label\thex\tnote")
        for item in items:
            print(f"{item.label}\t{item.payload.hex()}\t{item.note}")
        return 0

    for index in range(0, len(items), args.batch_size):
        batch = items[index : index + args.batch_size]
        labels = ", ".join(item.label for item in batch)
        sweep = ",".join(item.payload.hex() for item in batch)
        print(f"# batch {index // args.batch_size + 1}: {labels}")
        print(sweep)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
