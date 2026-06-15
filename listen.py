import asyncio, time, sys
from bleak import BleakClient, BleakScanner

TARGET = "837560C0-5B6C-C520-95EF-B1E713358D33"
DURATION = int(sys.argv[1]) if len(sys.argv) > 1 else 45

NAMES = {
    "61080003": "WHOOP-RX/resp",
    "61080004": "WHOOP-stream4",
    "61080005": "WHOOP-stream5",
    "61080007": "WHOOP-stream7",
    "00002a37": "HeartRate",
    "00002a19": "Battery",
}
NOTIFY = [
    "61080003-8d6d-82b8-614a-1c8cb0f8dcc6",
    "61080004-8d6d-82b8-614a-1c8cb0f8dcc6",
    "61080005-8d6d-82b8-614a-1c8cb0f8dcc6",
    "61080007-8d6d-82b8-614a-1c8cb0f8dcc6",
    "00002a37-0000-1000-8000-00805f9b34fb",
    "00002a19-0000-1000-8000-00805f9b34fb",
]
t0 = time.time()
counts = {}

def cb(uuid):
    short = uuid.split("-")[0]
    label = NAMES.get(short, short)
    def handler(_, data: bytearray):
        counts[label] = counts.get(label, 0) + 1
        # parse standard HR measurement (flags byte + uint8/uint16 bpm)
        extra = ""
        if short == "00002a37" and len(data) >= 2:
            flags = data[0]
            bpm = (data[1] | (data[2] << 8)) if (flags & 1) else data[1]
            extra = f"  -> {bpm} bpm"
        if short == "00002a19":
            extra = f"  -> {data[0]}% battery"
        print(f"[{time.time()-t0:6.2f}s] {label:14} ({len(data):3}B) {data.hex()}{extra}", flush=True)
    return handler

async def main():
    print(f"Connecting... will listen {DURATION}s. Wear the strap snugly for live data.\n")
    dev = await BleakScanner.find_device_by_address(TARGET, timeout=15.0)
    if not dev:
        print("Not found (advertising? disconnected from phone?)"); return
    async with BleakClient(dev) as c:
        print("Connected. Subscribing to notify characteristics...\n")
        for u in NOTIFY:
            try:
                await c.start_notify(u, cb(u))
            except Exception as e:
                print(f"  (subscribe failed {u}: {e})")
        await asyncio.sleep(DURATION)
        for u in NOTIFY:
            try: await c.stop_notify(u)
            except Exception: pass
    print("\n--- frame counts ---")
    for k, v in sorted(counts.items()):
        print(f"  {k:14} {v}")
    if not counts:
        print("  (no frames — strap may be idle/not worn, or needs a command to start streaming)")

asyncio.run(main())
