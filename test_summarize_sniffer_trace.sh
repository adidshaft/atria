#!/usr/bin/env bash
set -euo pipefail

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

trace="$tmpdir/sniffer.csv"
report="$tmpdir/report.md"

TRACE="$trace" python3 - <<'PY'
import csv
import os

from whoop_codec import encode

rows = [
    ("0.000", "write", "61080002-8d6d-82b8-e7fe-a9b926104d30", encode(bytes([0x23, 0x00, 0x03, 0x01])).hex()),
    ("0.120", "notify", "61080003-8d6d-82b8-e7fe-a9b926104d30", encode(bytes([0x24, 0x51, 0x03, 0x00, 0x02, 0x00, 0x00, 0x00])).hex()),
    ("1.000", "notify", "61080005-8d6d-82b8-e7fe-a9b926104d30", encode(bytes([0x28, 0x02, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 75, 0])).hex()),
    ("2.000", "notify", "61080005-8d6d-82b8-e7fe-a9b926104d30", encode(bytes([0x28, 0x02, 0x11, 0x20, 0x30, 0x40, 0x50, 0x60, 76, 2, 0x20, 0x03, 0x30, 0x03])).hex()),
]

with open(os.environ["TRACE"], "w", newline="") as handle:
    writer = csv.writer(handle)
    writer.writerow(["time_s", "direction", "uuid", "data"])
    writer.writerows(rows)
PY

./summarize_sniffer_trace.py "$trace" --output "$report"

grep -q "# WHOOP Sniffer Trace Summary" "$report"
grep -q -- "- command writes: 1" "$report"
grep -q -- "- command responses: 1" "$report"
grep -q -- "- realtime frames: 2" "$report"
grep -q -- "- RR-bearing realtime frames: 1" "$report"
grep -q -- "- zero-RR realtime frames: 1" "$report"
grep -q -- "- decoded RR values: 2" "$report"
grep -q "COMMAND seq=0 cmd=0x03 data=01" "$report"
grep -q "CMD_RESP seq=81 cmd=0x03 status=0002000000" "$report"
grep -q "REALTIME hr=76 rrnum=2 values=800,816" "$report"

echo "test_summarize_sniffer_trace.sh: pass"
