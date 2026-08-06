#!/usr/bin/env python3
"""Offline regression test for fragmented WHOOP ATT capture decoding."""

from __future__ import annotations

import csv
import os
import subprocess
import tempfile
from pathlib import Path

from whoop_codec import encode


ROOT = Path(__file__).resolve().parent


def main() -> int:
    with tempfile.TemporaryDirectory() as temp:
        directory = Path(temp)
        capture = directory / "fixture.pcapng"
        capture.touch()
        tshark = directory / "fake-tshark"
        first = encode(bytes([0x23, 1, 0x16, 0]))
        second = encode(bytes([0x2F, 2, 3, 4]))
        # Deliberately split frame one and concatenate frame two into a later ATT value.
        rows = [
            f'1\t0.000\t0x12\t0x0025\t{first[:5].hex()}',
            f'2\t0.010\t0x12\t0x0025\t{(first[5:] + second).hex()}',
        ]
        tshark.write_text("#!/bin/sh\nprintf '%b\\n' " + " ".join(repr(row) for row in rows) + "\n", encoding="utf-8")
        tshark.chmod(0o755)
        output = directory / "out.csv"
        result = subprocess.run(
            ["python3", str(ROOT / "tools/decode_whoop_att_capture.py"), str(capture), "-o", str(output), "--tshark", str(tshark)],
            text=True,
            capture_output=True,
            check=False,
        )
        assert result.returncode == 0, result.stderr
        with output.open(newline="", encoding="utf-8") as handle:
            output_rows = list(csv.DictReader(handle))
        assert [row["data"] for row in output_rows] == [first.hex(), second.hex()], output_rows
        assert output.with_suffix(".csv.undecoded.txt").read_text(encoding="utf-8") == ""
        no_att_tshark = directory / "no-att-tshark"
        no_att_tshark.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        no_att_tshark.chmod(0o755)
        failed = subprocess.run(
            ["python3", str(ROOT / "tools/decode_whoop_att_capture.py"), str(capture), "-o", str(directory / "empty.csv"), "--tshark", str(no_att_tshark)],
            text=True,
            capture_output=True,
            check=False,
        )
        assert failed.returncode != 0
        assert "capture not ATT-decodable; no protocol conclusion" in failed.stderr
    print("test_decode_whoop_att_capture.py: pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
