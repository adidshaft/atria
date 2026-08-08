import asyncio
import os
from bleak import BleakScanner

# Optional identifier to highlight. CoreBluetooth identifiers are host-specific.
TARGET = os.environ.get("WHOOP_TARGET")

async def main():
    print("Scanning 12s for BLE devices...\n")
    devices = await BleakScanner.discover(timeout=12.0, return_adv=True)
    found = None
    for addr, (dev, adv) in sorted(devices.items(), key=lambda x: -(x[1][1].rssi or -999)):
        name = dev.name or adv.local_name or "?"
        mark = ""
        if TARGET and addr.upper() == TARGET.upper():
            mark = "  <== TARGET"
            found = dev
        if "whoop" in name.lower() or mark:
            print(f"{addr}  rssi={adv.rssi:>4}  {name}{mark}")
            if adv.service_uuids:
                print("    services:", adv.service_uuids)
    if TARGET:
        print("\nTarget found:", bool(found))
    else:
        print("\nSet WHOOP_TARGET to highlight a discovered identifier.")

asyncio.run(main())
