"""3F (SEND_R10_R11_REALTIME) replay of the Sep 15 conditions that preceded compact 0x33.

Modes (one variable per run):
  3f_wwr       subscribe all, one 3F/01 write-WITHOUT-response, listen.
  history_3f   16/00, ACK every type-31 sub 2, then 3F/01 WWR mid-serve, keep ACKing, listen.
  passive      subscribe all, TX=0, listen (what does a latched strap send on reconnect?).
  stop3f       one 3F/00 with response, listen.
  hello_3f     pairing-window bond attempt: hello 23/00 (with response), 12 s watching stream-7
               for security/bond text, then 3F/01 WWR, listen.
  late_hello   wait 40 s (past a ~30 s failed security procedure), then hello 23/00, 12 s, 3F/01 WWR.
  cccd_3f      Sep 15 "zombie" repair: 10 s silent stream-5, stream-5 CCCD off -> 400 ms -> on
               (2A37 untouched), 20 s, then 3F/01 WWR, listen.

TX is limited to 3F/01 (WWR), 16/00, history ACK 17/01+token, and a final 3F/00
only when no 0x33 was seen. Never 6A/69/51/1D/9A/60/34/35.
Compact IMU = 152-byte frame AA 94 00 B5 33 on 61080005; every one is stored whole.
Usage: r10r11_probe.py MODE [log] [listen_s] [history_lead_s]
"""
from __future__ import annotations

import json
import sys
import time
import zlib

import objc
from CoreBluetooth import (
    CBCentralManager,
    CBCharacteristicWriteWithResponse,
    CBCharacteristicWriteWithoutResponse,
    CBManagerStatePoweredOn,
)
from Foundation import NSData, NSObject, NSTimer
from PyObjCTools import AppHelper

MODE = sys.argv[1] if len(sys.argv) > 1 else "3f_wwr"
assert MODE in ("3f_wwr", "history_3f", "passive", "stop3f", "cccd_3f", "hello_3f", "late_hello"), MODE
OUT_PATH = sys.argv[2] if len(sys.argv) > 2 else f"/tmp/atria-ble/r10r11-{MODE}.jsonl"
LISTEN_S = float(sys.argv[3]) if len(sys.argv) > 3 else 300.0
HISTORY_LEAD_S = float(sys.argv[4]) if len(sys.argv) > 4 else 30.0
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
        self.started = False
        self.seq = 1
        self.buffers = {}
        self.counts = {}
        self.window = {}
        self.compact_times = []
        self.sent_3f = False
        self.history_started_at = None
        self.hr_n = 0
        self.hr_last = None
        self.stream5 = None
        return self

    # --- link ---------------------------------------------------------------
    def centralManagerDidUpdateState_(self, central):
        say({"event": "state", "value": int(central.state())})
        if central.state() == CBManagerStatePoweredOn:
            central.scanForPeripheralsWithServices_options_(None, None)

    def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(self, central, peripheral, adv, rssi):
        if "WHO" not in str(peripheral.name() or "").upper():
            return
        say({"event": "found", "rssi": int(rssi),
             "services": [short(u) for u in (adv.get("kCBAdvDataServiceUUIDs") or [])]})
        central.stopScan()
        self.peripheral = peripheral
        peripheral.setDelegate_(self)
        central.connectPeripheral_options_(peripheral, None)

    def centralManager_didConnectPeripheral_(self, central, peripheral):
        say({"event": "connected", "mtu_wwr": int(peripheral.maximumWriteValueLengthForType_(1))})
        peripheral.discoverServices_(None)

    def centralManager_didFailToConnectPeripheral_error_(self, central, peripheral, error):
        say({"event": "connect_failed", "error": err_text(error)})
        AppHelper.stopEventLoop()

    def centralManager_didDisconnectPeripheral_error_(self, central, peripheral, error):
        say({"event": "disconnected", "error": err_text(error), "counts": self.counts,
             "compact": len(self.compact_times)})
        AppHelper.stopEventLoop()

    def peripheral_didDiscoverServices_(self, peripheral, error):
        for service in peripheral.services() or []:
            peripheral.discoverCharacteristics_forService_(None, service)

    def peripheral_didDiscoverCharacteristicsForService_error_(self, peripheral, service, error):
        for char in service.characteristics() or []:
            s = short(char.UUID())
            if s == "61080002":
                self.tx = char
            if s == "61080005":
                self.stream5 = char
            if s in NOTIFY_SHORT:
                peripheral.setNotifyValue_forCharacteristic_(True, char)

    def peripheral_didUpdateNotificationStateForCharacteristic_error_(self, peripheral, char, error):
        s = short(char.UUID())
        say({"event": "notify_state", "uuid": s, "on": bool(char.isNotifying()), "error": err_text(error)})
        if char.isNotifying():
            self.ready.add(s)
        if len(self.ready) == 5 and self.tx is not None and not self.started:
            self.started = True
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(10.0, self, "summary:", None, True)
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(LISTEN_S, self, "finish:", None, False)
            if MODE == "3f_wwr":
                self.send_3f_wwr("fresh_link")
            elif MODE == "stop3f":
                self.send_with_response(0x3F, b"\x00", "3f00")
            elif MODE == "passive":
                say({"event": "passive_tx0"})
            elif MODE == "hello_3f":
                self.send_with_response(0x23, b"\x00", "hello_2300")
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(12.0, self, "after3F:", None, False)
            elif MODE == "late_hello":
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(40.0, self, "lateHello:", None, False)
            elif MODE == "cccd_3f":
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(10.0, self, "cccdOff:", None, False)
            else:
                self.history_started_at = time.time()
                self.send_with_response(0x16, b"\x00", "history_1600")
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                    HISTORY_LEAD_S, self, "midServe3F:", None, False)

    # --- TX -----------------------------------------------------------------
    def frame_for(self, opcode, payload):
        frame = encode_frame(bytes((0x23, self.seq & 0xFF, opcode)) + payload)
        self.seq = (self.seq + 1) & 0xFF
        return frame

    def send_with_response(self, opcode, payload, name):
        frame = self.frame_for(opcode, payload)
        say({"event": "tx", "name": name, "type": "with_response", "hex": frame.hex()})
        self.peripheral.writeValue_forCharacteristic_type_(
            NSData.dataWithBytes_length_(frame, len(frame)), self.tx, CBCharacteristicWriteWithResponse)

    def send_3f_wwr(self, reason):
        if self.sent_3f:
            return
        self.sent_3f = True
        frame = self.frame_for(0x3F, b"\x01")
        say({"event": "tx", "name": "3f01", "type": "without_response", "reason": reason, "hex": frame.hex()})
        self.peripheral.writeValue_forCharacteristic_type_(
            NSData.dataWithBytes_length_(frame, len(frame)), self.tx, CBCharacteristicWriteWithoutResponse)

    def cccdOff_(self, _timer):
        s5 = sum(v for k, v in self.counts.items() if k.startswith("05:"))
        say({"event": "cccd_toggle_off", "uuid": "61080005", "stream5_frames_before": s5})
        self.peripheral.setNotifyValue_forCharacteristic_(False, self.stream5)
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(0.4, self, "cccdOn:", None, False)

    def cccdOn_(self, _timer):
        say({"event": "cccd_toggle_on", "uuid": "61080005"})
        self.peripheral.setNotifyValue_forCharacteristic_(True, self.stream5)
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(20.0, self, "after3F:", None, False)

    def lateHello_(self, _timer):
        self.send_with_response(0x23, b"\x00", "hello_2300_late")
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(12.0, self, "after3F:", None, False)

    def after3F_(self, _timer):
        self.send_3f_wwr("after_stream5_cccd_toggle")

    def midServe3F_(self, _timer):
        self.send_3f_wwr(f"mid_history_{HISTORY_LEAD_S:.0f}s")

    def peripheral_didWriteValueForCharacteristic_error_(self, peripheral, char, error):
        say({"event": "did_write", "error": err_text(error)})

    # --- RX -----------------------------------------------------------------
    def take_frames(self, uuid, chunk):
        buf = self.buffers.get(uuid, b"") + chunk
        frames = []
        while len(buf) >= 8 and buf[0] == 0xAA:
            total = (buf[1] | (buf[2] << 8)) + 4
            if total < 8 or total > 4096:
                buf = buf[1:]
                continue
            if len(buf) < total:
                break
            frames.append(buf[:total])
            buf = buf[total:]
        if buf and buf[0] != 0xAA:
            frames.append(buf)
            buf = b""
        self.buffers[uuid] = buf
        return frames

    def peripheral_didUpdateValueForCharacteristic_error_(self, peripheral, char, error):
        value = bytes(char.value() or b"")
        s = short(char.UUID())
        if s == "2A37":
            self.hr_n += 1
            self.hr_last = value[1] if len(value) > 1 else None
            return
        if s == "61080007":
            say({"uuid": s, "len": len(value), "hex": value.hex(),
                 "ascii": "".join(chr(b) if 32 <= b < 127 else "." for b in value)})
            return
        for frame in self.take_frames(s, value):
            self.note_frame(s, frame)

    def note_frame(self, uuid, frame):
        kind = f"{frame[4]:02x}" if len(frame) >= 5 and frame[0] == 0xAA else "raw"
        key = f"{uuid[-2:]}:{kind}"
        self.counts[key] = self.counts.get(key, 0) + 1
        self.window[key] = self.window.get(key, 0) + 1
        first = self.counts[key] <= 3
        if kind == "33":
            inner = frame[4:-4]
            dev_t = int.from_bytes(inner[4:8], "little") if len(inner) >= 8 else None
            gap = dev_t - self.compact_times[-1] if self.compact_times and dev_t is not None else None
            self.compact_times.append(dev_t)
            say({"event": "compact33", "uuid": uuid, "len": len(frame), "device_time": dev_t,
                 "gap": gap, "n": len(self.compact_times), "hex": frame.hex()})
            return
        if kind == "24":
            inner = frame[4:-4]
            say({"event": "type24", "cmd": f"{inner[2]:02x}" if len(inner) > 2 else None,
                 "data": inner[4:].hex(), "hex": frame.hex()})
            return
        if kind == "31":
            inner = frame[4:-4]
            sub = inner[2] if len(inner) > 2 else None
            say({"event": "meta31", "sub": sub, "hex": frame.hex()})
            if sub == 2 and len(inner) >= 21:
                token = inner[13:21]
                ack = self.frame_for(0x17, b"\x01" + token)
                say({"event": "tx", "name": "history_ack", "type": "with_response", "hex": ack.hex()})
                self.peripheral.writeValue_forCharacteristic_type_(
                    NSData.dataWithBytes_length_(ack, len(ack)), self.tx, CBCharacteristicWriteWithResponse)
            return
        if first or kind in ("34", "2f"):
            say({"event": "rx", "uuid": uuid, "kind": kind, "len": len(frame),
                 "hex": frame.hex() if len(frame) <= 160 else frame[:48].hex()})

    def summary_(self, _timer):
        say({"event": "window10s", "types": self.window, "hr_n": self.hr_n, "hr_last": self.hr_last,
             "compact": len(self.compact_times)})
        self.window = {}

    def finish_(self, _timer):
        gaps = [b - a for a, b in zip(self.compact_times, self.compact_times[1:]) if a is not None and b is not None]
        say({"event": "finish", "counts": self.counts, "compact": len(self.compact_times),
             "max_gap": max(gaps) if gaps else None, "hr_n": self.hr_n})
        if not self.compact_times and self.sent_3f:
            self.send_with_response(0x3F, b"\x00", "3f00_cleanup")
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(2.0, self, "hangup:", None, False)
        else:
            self.hangup_(None)

    def hangup_(self, _timer):
        self.central.cancelPeripheralConnection_(self.peripheral)


say({"event": "start", "mode": MODE, "listen_s": LISTEN_S, "history_lead_s": HISTORY_LEAD_S})
delegate = Delegate.alloc().init()
delegate.central = CBCentralManager.alloc().initWithDelegate_queue_(delegate, None)
try:
    AppHelper.runConsoleEventLoop()
finally:
    say({"event": "exit"})
