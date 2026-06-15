import asyncio
from bleak import BleakClient, BleakScanner

TARGET = "837560C0-5B6C-C520-95EF-B1E713358D33"

async def main():
    print(f"Connecting to {TARGET} ...")
    dev = await BleakScanner.find_device_by_address(TARGET, timeout=15.0)
    if dev is None:
        print("Device not found in scan. Is it advertising / disconnected from phone?")
        return
    async with BleakClient(dev) as client:
        print(f"Connected: {client.is_connected}\n")
        for svc in client.services:
            print(f"[service] {svc.uuid}  {svc.description}")
            for ch in svc.characteristics:
                props = ",".join(ch.properties)
                val = ""
                if "read" in ch.properties:
                    try:
                        raw = await client.read_gatt_char(ch.uuid)
                        val = f"  = {raw.hex()}  {raw[:40]!r}"
                    except Exception as e:
                        val = f"  (read err: {e})"
                print(f"   [char] {ch.uuid}  ({props}){val}")
                for d in ch.descriptors:
                    print(f"        [desc] {d.uuid} ({d.handle})")
        print("\nDone.")

asyncio.run(main())
