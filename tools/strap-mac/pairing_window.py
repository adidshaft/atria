"""Pairing-window probe: capture adverts, connect, READ every readable char, subscribe, log full payloads.

TX=0: never writes the command characteristic. Reads may make macOS bond if
the strap guards a characteristic with encryption. Logs full hex so stream-7
security text and any stream-5 frame are kept whole.
Usage: pairing_window.py [log] [listen_s]
"""
from __future__ import annotations

import json
import sys
import time

from CoreBluetooth import CBCentralManager, CBManagerStatePoweredOn, CBCharacteristicPropertyRead
from Foundation import NSObject, NSTimer
from PyObjCTools import AppHelper
import objc

OUT_PATH = sys.argv[1] if len(sys.argv) > 1 else "/tmp/atria-ble/pairing-window.jsonl"
LISTEN_S = float(sys.argv[2]) if len(sys.argv) > 2 else 300.0
SCAN_S = 8.0
OUT = open(OUT_PATH, "a", buffering=1)
NOTIFY_SHORT = {"61080003", "61080004", "61080005", "61080007", "2A37"}
STARTED = time.time()


def say(event: dict) -> None:
    event.setdefault("t", round(time.time() - STARTED, 3))
    event.setdefault("wall", time.strftime("%H:%M:%S"))
    line = json.dumps(event, separators=(",", ":"))
    print(line, flush=True)
    OUT.write(line + "\n")


def err_text(error):
    return None if error is None else f"{error.domain()} {error.code()} {error.localizedDescription()}"


def short(uuid) -> str:
    s = str(uuid.UUIDString()).upper().split("-")[0]
    return s[4:] if s.startswith("0000") else s


class Delegate(NSObject):
    def init(self):
        self = objc.super(Delegate, self).init()
        self.central = None
        self.peripheral = None
        self.adv_seen = 0
        return self

    def centralManagerDidUpdateState_(self, central):
        say({"event": "state", "value": int(central.state())})
        if central.state() == CBManagerStatePoweredOn:
            central.scanForPeripheralsWithServices_options_(None, {"kCBScanOptionAllowDuplicates": True})
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                SCAN_S, self, "connectNow:", None, False
            )

    def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(self, central, peripheral, adv, rssi):
        name = str(peripheral.name() or "")
        if "WHO" not in name.upper():
            return
        self.peripheral = peripheral
        self.adv_seen += 1
        uuids = [short(u) for u in (adv.get("kCBAdvDataServiceUUIDs") or [])]
        say({"event": "adv", "name": name, "rssi": int(rssi), "services": uuids,
             "connectable": bool(adv.get("kCBAdvDataIsConnectable"))})

    def connectNow_(self, _timer):
        self.central.stopScan()
        say({"event": "scan_done", "adv_seen": self.adv_seen})
        if self.peripheral is None:
            AppHelper.stopEventLoop()
            return
        self.peripheral.setDelegate_(self)
        self.central.connectPeripheral_options_(self.peripheral, None)
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            LISTEN_S, self, "finish:", None, False
        )

    def finish_(self, _timer):
        say({"event": "finish"})
        self.central.cancelPeripheralConnection_(self.peripheral)
        AppHelper.stopEventLoop()

    def centralManager_didConnectPeripheral_(self, central, peripheral):
        say({"event": "connected", "uuid": str(peripheral.identifier().UUIDString())})
        peripheral.discoverServices_(None)

    def centralManager_didFailToConnectPeripheral_error_(self, central, peripheral, error):
        say({"event": "connect_failed", "error": err_text(error)})

    def centralManager_didDisconnectPeripheral_error_(self, central, peripheral, error):
        say({"event": "disconnected", "error": err_text(error)})

    def peripheral_didDiscoverServices_(self, peripheral, error):
        say({"event": "services", "uuids": [short(s.UUID()) for s in peripheral.services() or []]})
        for service in peripheral.services() or []:
            peripheral.discoverCharacteristics_forService_(None, service)

    def peripheral_didDiscoverCharacteristicsForService_error_(self, peripheral, service, error):
        for char in service.characteristics() or []:
            s = short(char.UUID())
            props = int(char.properties())
            say({"event": "char", "service": short(service.UUID()), "uuid": s, "props": props})
            if props & CBCharacteristicPropertyRead:
                peripheral.readValueForCharacteristic_(char)
            if s in NOTIFY_SHORT:
                peripheral.setNotifyValue_forCharacteristic_(True, char)

    def peripheral_didUpdateNotificationStateForCharacteristic_error_(self, peripheral, char, error):
        say({"event": "notify_state", "uuid": short(char.UUID()), "on": bool(char.isNotifying()),
             "error": err_text(error)})

    def peripheral_didUpdateValueForCharacteristic_error_(self, peripheral, char, error):
        value = bytes(char.value() or b"")
        row = {"uuid": short(char.UUID()), "len": len(value), "hex": value.hex()}
        if error is not None:
            row["error"] = err_text(error)
        if len(value) >= 5 and value[0] == 0xAA:
            row["type"] = value[4]
        if short(char.UUID()) == "61080007":
            row["ascii"] = "".join(chr(b) if 32 <= b < 127 else "." for b in value)
        if len(value) == 152 and value[:5].hex() == "aa9400b533":
            row["compact33"] = True
        say(row)


say({"event": "start", "tx": 0, "listen_s": LISTEN_S})
delegate = Delegate.alloc().init()
delegate.central = CBCentralManager.alloc().initWithDelegate_queue_(delegate, None)
try:
    AppHelper.runConsoleEventLoop()
finally:
    say({"event": "exit"})
