#!/usr/bin/env python3
"""Read-only adapter from a BLE capture to CRC-validated WHOOP ATT evidence.

This tool deliberately does not speak Bluetooth or emit/replay commands.  It asks
``tshark`` to decode ATT records from a pcap, pcapng, or btsnoop file, reassembles
fragmented WHOOP frames per ATT direction/handle, and writes a CSV compatible with
``summarize_sniffer_trace.py``.  It fails closed when the capture does not expose
CRC-valid WHOOP frames (for example an encrypted over-air capture without keys).
"""

from __future__ import annotations

import argparse
import csv
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from whoop_codec import decode  # noqa: E402


WRITE_OPCODES = {"0x12", "0x52"}
NOTIFY_OPCODES = {"0x1b", "0x1d"}
MAX_WHOOP_FRAME_BYTES = 8_192


def parse_hex(value: str) -> bytes:
    cleaned = "".join(ch for ch in value if ch in "0123456789abcdefABCDEF")
    if not cleaned or len(cleaned) % 2:
        return b""
    return bytes.fromhex(cleaned)


def direction_for(opcode: str) -> str | None:
    normalized = opcode.lower().strip()
    if normalized in WRITE_OPCODES:
        return "write"
    if normalized in NOTIFY_OPCODES:
        return "notify"
    return None


class WhoopReassembler:
    """Extract valid WHOOP frames while retaining malformed/incomplete evidence."""

    def __init__(self) -> None:
        self.pending = b""
        self.rejected = bytearray()

    def feed(self, chunk: bytes) -> list[bytes]:
        self.pending += chunk
        frames: list[bytes] = []
        while self.pending:
            start = self.pending.find(b"\xaa")
            if start < 0:
                self.rejected.extend(self.pending)
                self.pending = b""
                break
            if start:
                self.rejected.extend(self.pending[:start])
                self.pending = self.pending[start:]
            if len(self.pending) < 4:
                break
            length = int.from_bytes(self.pending[1:3], "little")
            total = length + 4
            if length < 4 or total > MAX_WHOOP_FRAME_BYTES:
                self.rejected.append(self.pending[0])
                self.pending = self.pending[1:]
                continue
            if len(self.pending) < total:
                break
            candidate, self.pending = self.pending[:total], self.pending[total:]
            _payload, valid = decode(candidate)
            if valid:
                frames.append(candidate)
            else:
                # Preserve a complete invalid candidate and resynchronise only
                # after it; it may be encrypted/noise, never a command to replay.
                self.rejected.extend(candidate)
        return frames

    def finish(self) -> bytes:
        leftover = bytes(self.rejected) + self.pending
        self.pending = b""
        return leftover


def tshark_rows(capture: Path, tshark: str) -> list[list[str]]:
    command = [
        tshark, "-n", "-r", str(capture), "-Y", "btatt", "-T", "fields",
        "-E", "separator=\t", "-E", "quote=d",
        "-e", "frame.number", "-e", "frame.time_relative", "-e", "btatt.opcode",
        "-e", "btatt.handle", "-e", "btatt.value",
    ]
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown tshark failure"
        raise RuntimeError(f"tshark failed: {detail}")
    return list(csv.reader(result.stdout.splitlines(), delimiter="\t"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, help="Input .pcap, .pcapng, or .btsnoop capture")
    parser.add_argument("-o", "--output", type=Path, required=True, help="Output CSV for summarize_sniffer_trace.py")
    parser.add_argument("--tshark", default="tshark", help="Read-only tshark executable (default: tshark)")
    args = parser.parse_args()
    if not args.capture.is_file():
        raise SystemExit(f"capture does not exist: {args.capture}")

    try:
        rows = tshark_rows(args.capture, args.tshark)
    except (OSError, RuntimeError) as error:
        raise SystemExit(f"capture not ATT-decodable; no protocol conclusion: {error}")

    reassemblers: dict[tuple[str, str], WhoopReassembler] = defaultdict(WhoopReassembler)
    emitted: list[tuple[str, str, str, str, str]] = []
    for row in rows:
        row = row + [""] * (5 - len(row))
        frame_number, time_s, opcode, handle, value = row[:5]
        direction = direction_for(opcode)
        raw = parse_hex(value)
        if direction is None or not raw:
            continue
        for frame in reassemblers[(direction, handle)].feed(raw):
            emitted.append((time_s, direction, handle, frame.hex(), frame_number))

    rejected: list[str] = []
    for (direction, handle), reassembler in sorted(reassemblers.items()):
        tail = reassembler.finish()
        if tail:
            rejected.append(f"direction={direction} handle={handle} bytes={tail.hex()}")
    if not emitted:
        raise SystemExit("capture not ATT-decodable; no protocol conclusion: no CRC-valid WHOOP frames")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8") as output:
        writer = csv.writer(output)
        writer.writerow(["time_s", "direction", "uuid", "data", "source_frame"])
        writer.writerows(emitted)
    undecoded = args.output.with_suffix(args.output.suffix + ".undecoded.txt")
    undecoded.write_text("\n".join(rejected) + ("\n" if rejected else ""), encoding="utf-8")
    print(f"decoded {len(emitted)} CRC-valid WHOOP frames into {args.output}")
    print(f"preserved {len(rejected)} undecoded stream tails in {undecoded}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
