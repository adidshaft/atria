import asyncio
from bleak import BleakScanner

# CoreBluetooth peripheral identifier you gave
TARGET = "837560C0-5B6C-C520-95EF-B1E713358D33"

async def main():
    print("Scanning 12s for BLE devices...\n")
    devices = await BleakScanner.discover(timeout=12.0, return_adv=True)
    found = None
    for addr, (dev, adv) in sorted(devices.items(), key=lambda x: -(x[1][1].rssi or -999)):
        name = dev.name or adv.local_name or "?"
        mark = ""
        if addr.upper() == TARGET.upper():
            mark = "  <== TARGET"
            found = dev
        if "whoop" in name.lower() or mark:
            print(f"{addr}  rssi={adv.rssi:>4}  {name}{mark}")
            if adv.service_uuids:
                print("    services:", adv.service_uuids)
    print("\nTarget found:", bool(found))

asyncio.run(main())
