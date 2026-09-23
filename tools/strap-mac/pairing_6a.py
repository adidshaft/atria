"""Pairing-window 6A test: hello 23/00, then ONE 6A/01, listen, log full hex.

Exactly two TX frames, write-with-response, only after all five notifies are
on. No 69/3F/03/9A/34/35/1D/51/60 ever. Compact IMU is only a 152-byte
stream-5 frame AA 94 00 B5 33.
Usage: pairing_6a.py [log] [listen_s]
"""
from __future__ import annotations

import json
import sys
import time
import zlib

import objc
from CoreBluetooth import CBCentralManager, CBCharacteristicWriteWithResponse, CBManagerStatePoweredOn
from Foundation import NSData, NSObject, NSTimer
from PyObjCTools import AppHelper

OUT_PATH = sys.argv[1] if len(sys.argv) > 1 else "/tmp/atria-ble/pairing-6a.jsonl"
LISTEN_S = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
OUT = open(OUT_PATH, "a", buffering=1)
NOTIFY_SHORT = {"61080003", "61080004", "61080005", "61080007", "2A37"}
PLAN = [("hello", 0x23, b"\x00"), ("6a01", 0x6A, b"\x01")]
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


def crc8(data: bytes) -> int:
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


def encode_frame(inner: bytes) -> bytes:
    length = len(inner) + 4
    lb = bytes((length & 0xFF, (length >> 8) & 0xFF))
    return b"\xaa" + lb + bytes((crc8(lb),)) + inner + (zlib.crc32(inner) & 0xFFFFFFFF).to_bytes(4, "little")


class Delegate(NSObject):
    def init(self):
        self = objc.super(Delegate, self).init()
        self.central = None
        self.peripheral = None
        self.tx = None
        self.ready = set()
        self.step = 0
        self.seq = 1
        self.started_tx = False
        self.counts = {}
        return self

    def centralManagerDidUpdateState_(self, central):
        say({"event": "state", "value": int(central.state())})
        if central.state() == CBManagerStatePoweredOn:
            central.scanForPeripheralsWithServices_options_(None, None)

    def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(self, central, peripheral, adv, rssi):
        if "WHO" not in str(peripheral.name() or "").upper():
            return
        uuids = [short(u) for u in (adv.get("kCBAdvDataServiceUUIDs") or [])]
        say({"event": "found", "rssi": int(rssi), "services": uuids})
        central.stopScan()
        self.peripheral = peripheral
        peripheral.setDelegate_(self)
        central.connectPeripheral_options_(peripheral, None)

    def centralManager_didConnectPeripheral_(self, central, peripheral):
        say({"event": "connected"})
        peripheral.discoverServices_(None)

    def centralManager_didFailToConnectPeripheral_error_(self, central, peripheral, error):
        say({"event": "connect_failed", "error": err_text(error)})
        AppHelper.stopEventLoop()

    def centralManager_didDisconnectPeripheral_error_(self, central, peripheral, error):
        say({"event": "disconnected", "error": err_text(error), "counts": self.counts})
        AppHelper.stopEventLoop()

    def peripheral_didDiscoverServices_(self, peripheral, error):
        for service in peripheral.services() or []:
            peripheral.discoverCharacteristics_forService_(None, service)

    def peripheral_didDiscoverCharacteristicsForService_error_(self, peripheral, service, error):
        for char in service.characteristics() or []:
            s = short(char.UUID())
            if s == "61080002":
                self.tx = char
            if s in NOTIFY_SHORT:
                peripheral.setNotifyValue_forCharacteristic_(True, char)

    def peripheral_didUpdateNotificationStateForCharacteristic_error_(self, peripheral, char, error):
        s = short(char.UUID())
        say({"event": "notify_state", "uuid": s, "on": bool(char.isNotifying()), "error": err_text(error)})
        if char.isNotifying():
            self.ready.add(s)
        if len(self.ready) == 5 and self.tx is not None and not self.started_tx:
            self.started_tx = True
            self.send_next()

    def send_next(self):
        name, opcode, payload = PLAN[self.step]
        frame = encode_frame(bytes((0x23, self.seq, opcode)) + payload)
        self.seq += 1
        say({"event": "tx", "name": name, "hex": frame.hex()})
        self.peripheral.writeValue_forCharacteristic_type_(
            NSData.dataWithBytes_length_(frame, len(frame)), self.tx, CBCharacteristicWriteWithResponse
        )

    def peripheral_didWriteValueForCharacteristic_error_(self, peripheral, char, error):
        say({"event": "did_write", "step": PLAN[self.step][0], "error": err_text(error)})
        if error is not None:
            return
        self.step += 1
        if self.step < len(PLAN):
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(1.0, self, "sendNext:", None, False)
        else:
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(LISTEN_S, self, "finish:", None, False)

    def sendNext_(self, _timer):
        self.send_next()

    def finish_(self, _timer):
        say({"event": "finish", "counts": self.counts})
        self.central.cancelPeripheralConnection_(self.peripheral)

    def peripheral_didUpdateValueForCharacteristic_error_(self, peripheral, char, error):
        value = bytes(char.value() or b"")
        s = short(char.UUID())
        row = {"uuid": s, "len": len(value), "hex": value.hex()}
        if len(value) >= 5 and value[0] == 0xAA:
            row["type"] = value[4]
        if s == "61080007":
            row["ascii"] = "".join(chr(b) if 32 <= b < 127 else "." for b in value)
        if len(value) == 152 and value[:5].hex() == "aa9400b533":
            row["compact33"] = True
        key = f"{s}:{row.get('type')}"
        self.counts[key] = self.counts.get(key, 0) + 1
        say(row)


say({"event": "start", "plan": [p[0] for p in PLAN], "listen_s": LISTEN_S})
delegate = Delegate.alloc().init()
delegate.central = CBCentralManager.alloc().initWithDelegate_queue_(delegate, None)
try:
    AppHelper.runConsoleEventLoop()
finally:
    say({"event": "exit"})
