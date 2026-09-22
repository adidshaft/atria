"""Long Mac ↔ WHOOP recorder: subscribe only, TX=0, append durable JSONL.

Subscribes 2A37 + 61080003/04/05/07. Never writes to the strap TX char.
Log: /tmp/atria-ble/overnight.jsonl
"""
from __future__ import annotations

import json
import os
import time

import objc
from CoreBluetooth import (
    CBCentralManager,
    CBManagerStatePoweredOn,
)
from Foundation import NSObject
from PyObjCTools import AppHelper

OUT_PATH = os.environ.get("ATRIA_OVERNIGHT_LOG", "/tmp/atria-ble/overnight.jsonl")
os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
OUT = open(OUT_PATH, "a", buffering=1)

TARGET_UUID = "837560C0-5B6C-C520-95EF-B1E713358D33"
NOTIFY = {
    "61080003-8D6D-82B8-614A-1C8CB0F8DCC6",
    "61080004-8D6D-82B8-614A-1C8CB0F8DCC6",
    "61080005-8D6D-82B8-614A-1C8CB0F8DCC6",
    "61080007-8D6D-82B8-614A-1C8CB0F8DCC6",
    "2A37",
}
STARTED = time.time()


def say(event: dict) -> None:
    event.setdefault("t", round(time.time() - STARTED, 3))
    line = json.dumps(event, separators=(",", ":"))
    print(line, flush=True)
    OUT.write(line + "\n")
    OUT.flush()


def err_text(error) -> str | None:
    if error is None:
        return None
    return f"{error.domain()} {error.code()} {error.localizedDescription()}"


def char_short(uuid: str) -> str:
    uuid = uuid.upper()
    short = uuid.split("-")[0]
    if short.startswith("0000"):
        short = short[4:]
    return short


def char_key(uuid: str) -> str:
    uuid = uuid.upper()
    short = char_short(uuid)
    if uuid in NOTIFY or short in NOTIFY:
        return short if short in NOTIFY else uuid
    return short


def is_hr(uuid: str) -> bool:
    return char_short(uuid).endswith("2A37")


def is_compact_33(value: bytes) -> bool:
    if value[:5].hex() == "aa9400b533":
        return True
    return len(value) == 152 and len(value) >= 5 and value[0] == 0xAA and value[4] == 0x33


class Delegate(NSObject):
    def init(self):
        self = objc.super(Delegate, self).init()
        self.central = None
        self.peripheral = None
        self.ready = set()
        self.connected = False
        self.hr_n = 0
        return self

    def centralManagerDidUpdateState_(self, central):
        say({"event": "state", "value": int(central.state())})
        if central.state() == CBManagerStatePoweredOn:
            central.scanForPeripheralsWithServices_options_(None, None)
            say({"event": "scanning", "tx": 0})

    def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(
        self, central, peripheral, adv, rssi
    ):
        name = str(peripheral.name() or "")
        ident = str(peripheral.identifier().UUIDString()).upper()
        if "WHO" not in name.upper() and ident != TARGET_UUID:
            return
        say({"event": "found", "name": name, "uuid": ident, "rssi": int(rssi)})
        central.stopScan()
        self.peripheral = peripheral
        peripheral.setDelegate_(self)
        central.connectPeripheral_options_(peripheral, None)

    def centralManager_didFailToConnectPeripheral_error_(self, central, peripheral, error):
        say({"event": "connect_failed", "error": err_text(error)})

    def centralManager_didConnectPeripheral_(self, central, peripheral):
        self.connected = True
        self.ready.clear()
        say({"event": "connected", "uuid": str(peripheral.identifier().UUIDString()), "tx": 0})
        peripheral.discoverServices_(None)

    def centralManager_didDisconnectPeripheral_error_(self, central, peripheral, error):
        self.connected = False
        self.ready.clear()
        say({"event": "disconnected", "error": err_text(error)})
        say({"event": "reconnect_attempt"})
        central.connectPeripheral_options_(peripheral, None)

    def peripheral_didDiscoverServices_(self, peripheral, error):
        if error is not None:
            say({"event": "services_error", "error": err_text(error)})
            return
        for service in peripheral.services() or []:
            peripheral.discoverCharacteristics_forService_(None, service)

    def peripheral_didDiscoverCharacteristicsForService_error_(self, peripheral, service, error):
        for char in service.characteristics() or []:
            uuid = str(char.UUID().UUIDString()).upper()
            key = char_key(uuid)
            if key in NOTIFY or uuid in NOTIFY or char_short(uuid) in NOTIFY:
                # Subscribe only — never writeValue / no strap commands.
                peripheral.setNotifyValue_forCharacteristic_(True, char)

    def peripheral_didUpdateNotificationStateForCharacteristic_error_(
        self, peripheral, characteristic, error
    ):
        uuid = str(characteristic.UUID().UUIDString()).upper()
        short = char_short(uuid)
        say(
            {
                "event": "notify_state",
                "uuid": short,
                "on": bool(characteristic.isNotifying()),
                "error": err_text(error),
            }
        )
        if characteristic.isNotifying():
            self.ready.add(short)
            if len(self.ready) >= 5:
                say({"event": "subscribed", "count": len(self.ready), "chars": sorted(self.ready), "tx": 0})

    def peripheral_didUpdateValueForCharacteristic_error_(self, peripheral, characteristic, error):
        uuid = str(characteristic.UUID().UUIDString()).upper()
        short = char_short(uuid)
        value = bytes(characteristic.value() or b"")
        row = {
            "t": round(time.time() - STARTED, 3),
            "uuid": short,
            "len": len(value),
            "hex16": value[:16].hex(),
        }
        if error is not None:
            row["error"] = err_text(error)
        if len(value) >= 5 and value[0] == 0xAA:
            row["type"] = value[4]
        if is_hr(uuid) and len(value) >= 2:
            self.hr_n += 1
            row["bpm"] = value[1]
            row["hr_n"] = self.hr_n
        say(row)
        if is_compact_33(value):
            say({"event": "compact33", "uuid": short, "len": len(value), "hex16": value[:16].hex()})


delegate = Delegate.alloc().init()
delegate.central = CBCentralManager.alloc().initWithDelegate_queue_(delegate, None)
say(
    {
        "event": "start",
        "target": TARGET_UUID,
        "log": OUT_PATH,
        "tx": 0,
        "subs": sorted(char_short(u) for u in NOTIFY),
    }
)
try:
    AppHelper.runConsoleEventLoop()
finally:
    say({"event": "exit"})
    OUT.close()
