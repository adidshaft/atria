"""Empirical command probe: find the exact START_REALTIME command our strap wants.

Listens to all notify characteristics, decodes every frame (printing the packet
TYPE byte), and tries several safe command variants spaced apart so we can see
which one makes the strap emit REALTIME_DATA (0x28). Only read/realtime commands
(0x03 start, 0x04 stop, 0x05 hello) — nothing that writes config/firmware.

NOTE: the iPhone app must be force-quit first so the Mac can hold the strap.
Run via Terminal: echo "probe.py" > which_script.txt && open whoop_run.command
"""
import argparse
import asyncio
import time
from bleak import BleakClient, BleakScanner
from whoop_codec import encode, decode

TARGET = "837560C0-5B6C-C520-95EF-B1E713358D33"
TX  = "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
HR_UUID = "00002a37-0000-1000-8000-00805f9b34fb"
NOTIFY = [HR_UUID,                                  # subscribe HR too — may gate the rest
          "61080003-8d6d-82b8-614a-1c8cb0f8dcc6",
          "61080004-8d6d-82b8-614a-1c8cb0f8dcc6",
          "61080005-8d6d-82b8-614a-1c8cb0f8dcc6",
          "61080007-8d6d-82b8-614a-1c8cb0f8dcc6"]
TYPE = {0x23:"COMMAND",0x24:"CMD_RESP",0x28:"REALTIME",0x2f:"HISTORICAL",0x30:"EVENT",0x31:"METADATA",0x33:"IMU"}
t0 = time.time()
seq = 0
stats = {
    "frames": 0,
    "realtime_frames": 0,
    "rr_frames": 0,
    "rr_zero_frames": 0,
    "rr_values": 0,
    "rr_hr_mismatch_values": 0,
    "first_realtime_s": None,
    "first_rr_s": None,
    "last_rr_s": None,
    "max_rr_log_gap_s": 0.0,
}

def on_notify(sender, raw):
    global frames_seen
    frames_seen += 1
    stats["frames"] += 1
    uuid = str(getattr(sender, "uuid", sender))
    src = uuid.split("-")[0][-2:]
    if uuid.lower().startswith("00002a37"):
        b = bytes(raw)
        bpm = b[1] if len(b) >= 2 else 0
        print(f"[{time.time()-t0:5.1f}] HR   {bpm} bpm", flush=True); return
    payload, ok = decode(bytes(raw))
    tag = "ok " if ok else "BAD"
    if ok and payload:
        ptype = payload[0]
        name = TYPE.get(ptype, f"0x{ptype:02x}")
        extra = ""
        if ptype == 0x28 and len(payload) >= 10:
            now_s = time.time() - t0
            hr = payload[8]
            rrnum = payload[9]
            rr_values = []
            truncated = 0
            for i in range(rrnum):
                off = 10 + i * 2
                if off + 1 >= len(payload):
                    truncated = 1
                    break
                rr_values.append(payload[off] | (payload[off + 1] << 8))
            mismatch = sum(
                1 for rr in rr_values
                if rr <= 0 or abs((60000.0 / rr) - hr) > 30
            )
            stats["realtime_frames"] += 1
            if stats["first_realtime_s"] is None:
                stats["first_realtime_s"] = now_s
            if rr_values or truncated:
                stats["rr_frames"] += 1
                stats["rr_values"] += len(rr_values)
                stats["rr_hr_mismatch_values"] += mismatch
                if stats["first_rr_s"] is None:
                    stats["first_rr_s"] = now_s
                if stats["last_rr_s"] is not None:
                    stats["max_rr_log_gap_s"] = max(
                        stats["max_rr_log_gap_s"],
                        now_s - stats["last_rr_s"],
                    )
                stats["last_rr_s"] = now_s
            else:
                stats["rr_zero_frames"] += 1
            implied = ",".join(f"{60000.0 / rr:.0f}" if rr > 0 else "inf" for rr in rr_values)
            values = ",".join(str(rr) for rr in rr_values)
            extra = (
                f"  HR={hr} rrnum={rrnum} decoded={len(rr_values)} "
                f"truncated={truncated} hr_mismatch={mismatch} "
                f"implied_bpm={implied} values={values}"
            )
        print(f"[{time.time()-t0:5.1f}] ch{src} {tag} {name:9} len={len(payload):3} {payload[:14].hex()}{extra}", flush=True)
    else:
        print(f"[{time.time()-t0:5.1f}] ch{src} {tag} raw={bytes(raw)[:16].hex()}", flush=True)

def cmd(code, data=b""):
    global seq
    p = bytes([0x23, seq, code]) + data
    seq = (seq+1) & 0xFF
    return encode(p)

frames_seen = 0

async def send(c, label, frame):
    print(f"\n>>> {label}: {frame.hex()}", flush=True)
    for rt in (True, False):            # try ACKed write first
        try:
            await c.write_gatt_char(TX, frame, response=rt)
            print(f"    written (response={rt})", flush=True); break
        except Exception as e:
            print(f"    write response={rt} failed: {e}", flush=True)

async def listen(label, secs):
    """Sleep in 2s ticks, printing a heartbeat with running frame count."""
    print(f"--- {label} ({secs}s) ---", flush=True)
    for _ in range(0, secs, 2):
        await asyncio.sleep(2)
        print(
            f"    .. {time.time()-t0:5.1f}s  frames={frames_seen} "
            f"rt={stats['realtime_frames']} rr_frames={stats['rr_frames']} "
            f"rr0={stats['rr_zero_frames']} rr_values={stats['rr_values']}",
            flush=True,
        )

def fmt(value):
    return "" if value is None else f"{value:.1f}"

def print_summary():
    first_realtime = stats["first_realtime_s"]
    first_rr = stats["first_rr_s"]
    rr_start_delay = (
        None if first_realtime is None or first_rr is None
        else first_rr - first_realtime
    )
    print("WHOOP_PROBE_SUMMARY_START", flush=True)
    print(f"frames={stats['frames']}", flush=True)
    print(f"realtime_frames={stats['realtime_frames']}", flush=True)
    print(f"rr_frames={stats['rr_frames']}", flush=True)
    print(f"rr_zero_frames={stats['rr_zero_frames']}", flush=True)
    print(f"rr_values={stats['rr_values']}", flush=True)
    print(f"rr_hr_mismatch_values={stats['rr_hr_mismatch_values']}", flush=True)
    print(f"first_realtime_s={fmt(first_realtime)}", flush=True)
    print(f"first_rr_s={fmt(first_rr)}", flush=True)
    print(f"rr_start_delay_s={fmt(rr_start_delay)}", flush=True)
    print(f"last_rr_s={fmt(stats['last_rr_s'])}", flush=True)
    print(f"max_rr_log_gap_s={stats['max_rr_log_gap_s']:.1f}", flush=True)
    print("WHOOP_PROBE_SUMMARY_END", flush=True)

def args():
    parser = argparse.ArgumentParser(description="Safe WHOOP realtime command probe")
    parser.add_argument("--target", default=TARGET)
    parser.add_argument("--baseline-seconds", type=int, default=12)
    parser.add_argument("--after-start-seconds", type=int, default=12)
    parser.add_argument("--after-alt-start-seconds", type=int, default=12)
    parser.add_argument("--after-hello-seconds", type=int, default=8)
    parser.add_argument("--after-stop-seconds", type=int, default=4)
    parser.add_argument(
        "--start-only-seconds",
        type=int,
        default=0,
        help="Send only the validated 0x03 enable command, then listen this long.",
    )
    return parser.parse_args()

async def main():
    options = args()
    dev = await BleakScanner.find_device_by_address(options.target, timeout=15.0)
    if not dev:
        print("NOT FOUND — is the iPhone app still holding the strap? Force-quit it."); return
    try:
        async with BleakClient(dev) as c:
            for u in NOTIFY:
                try: await c.start_notify(u, on_notify)
                except Exception as e: print("sub fail", u, e)
            await listen("baseline", options.baseline_seconds)
            await send(c, "A start [0x23,seq,0x03,0x01]", cmd(0x03, b"\x01"))
            await listen("after A", options.start_only_seconds or options.after_start_seconds)
            if not options.start_only_seconds:
                await send(c, "B start [0x23,seq,0x03]", cmd(0x03))
                await listen("after B", options.after_alt_start_seconds)
                await send(c, "C hello [0x23,seq,0x05]", cmd(0x05))
                await listen("after C", options.after_hello_seconds)
                await send(c, "D stop  [0x23,seq,0x04]", cmd(0x04))
                await listen("after D", options.after_stop_seconds)
            print(f"\ndone. total frames={frames_seen}", flush=True)
            print_summary()
    except Exception as exc:
        print(f"CONNECT_FAILED {type(exc).__name__}: {exc}", flush=True)
        print_summary()
        raise SystemExit(2)

asyncio.run(main())
