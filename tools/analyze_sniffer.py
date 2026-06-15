#!/usr/bin/env python3
"""Analyze a BLE sniffer capture of the official WHOOP app to find what we're missing.

Goal: learn (a) the exact command sequence the official app writes to the TX
characteristic before sustained RR begins, and (b) the historical-transfer request
that produces 0x2f data frames — neither of which our app currently knows.

Input: a tshark JSON export of the ATT layer. Produce it from a .pcapng like:

    tshark -r whoop_official.pcapng -Y btatt -T json \
        -e frame.time_relative -e btatt.opcode -e btatt.handle \
        -e btatt.value > att.json

Then:  ./tools/analyze_sniffer.py att.json

This decodes WHOOP frames with whoop_codec, prints the write/notify timeline, the
exact command bytes the official app sent, and the RR-bearing fraction over time.
It never fabricates — frames that don't validate are shown as raw.
"""
import json, sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from whoop_codec import decode

# ATT opcodes
WRITE_REQ, WRITE_CMD, NOTIFY, INDICATE = 0x12, 0x52, 0x1B, 0x1D
TYPE = {0x23: "COMMAND", 0x24: "CMD_RESP", 0x28: "REALTIME",
        0x2f: "HISTORICAL", 0x30: "EVENT", 0x31: "META", 0x33: "IMU"}

def hexval(v):
    if v is None: return b""
    return bytes.fromhex(v.replace(":", "").strip())

def field(layers, name):
    x = layers.get(name)
    return x[0] if isinstance(x, list) else x

def main(path):
    pkts = json.load(open(path))
    writes, notifs = [], []
    rr_frames = total_rt = 0
    print(f"{'t(s)':>8}  {'dir':<6} {'handle':<7} type        bytes")
    print("-" * 78)
    for p in pkts:
        L = p.get("_source", {}).get("layers", {})
        op = field(L, "btatt.opcode");
        if op is None: continue
        op = int(op, 16) if isinstance(op, str) and op.startswith("0x") else int(op)
        t = float(field(L, "frame.time_relative") or 0)
        handle = field(L, "btatt.handle") or "?"
        raw = hexval(field(L, "btatt.value"))
        if not raw: continue
        payload, ok = decode(raw)
        ptype = TYPE.get(payload[0], f"0x{payload[0]:02x}") if (ok and payload) else "raw"
        direction = "WRITE" if op in (WRITE_REQ, WRITE_CMD) else ("NOTIFY" if op in (NOTIFY, INDICATE) else f"op{op:#x}")
        if direction == "WRITE":
            writes.append((t, handle, raw, payload if ok else None))
        if ok and payload and payload[0] == 0x28:
            total_rt += 1
            # RR present if rrnum byte (payload[9]) > 0
            if len(payload) > 9 and payload[9] > 0:
                rr_frames += 1
        if ok and payload and payload[0] == 0x2f:
            notifs.append((t, handle, raw))
        print(f"{t:8.2f}  {direction:<6} {str(handle):<7} {ptype:<11} {raw.hex()}")

    print("\n=== COMMANDS the official app WROTE (the sequence we need) ===")
    for t, h, raw, pl in writes:
        dec = f"  payload={pl.hex()}" if pl else "  (unframed)"
        print(f"  {t:8.2f}  handle={h}  {raw.hex()}{dec}")
    print(f"\n=== REALTIME RR coverage: {rr_frames}/{total_rt} frames carried RR "
          f"({100*rr_frames/total_rt if total_rt else 0:.1f}%) ===")
    print(f"=== HISTORICAL 0x2f data frames seen: {len(notifs)} ===")
    if total_rt and rr_frames / max(total_rt,1) >= 0.9:
        print(">>> Official app achieves CONTINUOUS RR — replicate its write sequence above.")
    if notifs:
        print(">>> Official app pulled historical data — replicate the request sequence that preceded it.")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: analyze_sniffer.py att.json"); sys.exit(1)
    main(sys.argv[1])
