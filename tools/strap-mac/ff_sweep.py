"""WHOOP 4 feature-flag sweep for compact IMU 0x33 (user-authorized; strap expendable).

Modes:
  read               enumerate keys (75/01, 76/01) and GET every value (0x80). No writes.
  trial KEY [VALUE]  read v0, SET v1 (default: raw "1"<->"2"), read back, 3F/01 WWR stimulus,
                     listen, 3F/00, restore v0 unless 0x33 was seen, read back.
  restore            only restore a pending journal entry.
  setreboot KEY      read v0, journal, SET v1, read back, then 1D/00 (reboot applies it).
  checkrestore       after a reboot: read the journaled key, 3F/01 WWR stimulus, listen,
                     3F/00, restore v0, read back (applied by the next reboot).
  reboot             1D/00 only.
  clock              GET_CLOCK 0B/00; SET_CLOCK 0A only if the strap clock is outside 2025-2027.
  trim3f             test D: 22/00 range -> 19 trim (FE*8+00, Jul 30 proven) -> 22/00 verify W==U
                     -> 3F/01 WWR -> listen (0x33 leaves 3F on; else 3F/00).

Opcodes used: 75, 76, 80, 78, 3F, 1D (user-authorized reboot pass), 0B/0A (clock repair). 0x78 body = 01 | key[32] | value[32] (Jul 30 proven).
0x80 body = 01 | key[32] (inferred; validated in `read` against Jul 30 values).
A journal is written before every 0x78 and cleared only after a verified restore.
Usage: ff_sweep.py MODE [KEY] [VALUE] [--log PATH] [--listen S]
"""
from __future__ import annotations

import json
import os
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

ARGS = [a for a in sys.argv[1:]]
LOG = "/tmp/atria-ble/ff-sweep.jsonl"
LISTEN_S = 20.0
if "--log" in ARGS:
    i = ARGS.index("--log"); LOG = ARGS[i + 1]; del ARGS[i:i + 2]
if "--listen" in ARGS:
    i = ARGS.index("--listen"); LISTEN_S = float(ARGS[i + 1]); del ARGS[i:i + 2]
MODE = ARGS[0] if ARGS else "read"
assert MODE in ("read", "trial", "restore", "setreboot", "checkrestore", "reboot", "clock", "trim3f"), MODE
TRIAL_KEY = ARGS[1] if MODE in ("trial", "setreboot") else None
TRIAL_VALUE = ARGS[2] if MODE == "trial" and len(ARGS) > 2 else None
JOURNAL = "/tmp/atria-ble/ff-journal.json"
OUT = open(LOG, "a", buffering=1)
NOTIFY_SHORT = {"61080003", "61080004", "61080005", "61080007", "2A37"}
STARTED = time.time()
FIELD = 32


def say(event: dict) -> None:
    event.setdefault("t", round(time.time() - STARTED, 3))
    event.setdefault("wall", time.strftime("%H:%M:%S"))
    line = json.dumps(event, separators=(",", ":"))
    print(line, flush=True)
    OUT.write(line + "\n")


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


def field(text: str) -> bytes:
    raw = text.encode("ascii")
    assert len(raw) <= FIELD, text
    return raw.ljust(FIELD, b"\x00")


def ascii_fields(record: bytes) -> list[str]:
    out, cur = [], b""
    for b in record:
        if 32 <= b < 127:
            cur += bytes((b,))
        else:
            if cur:
                out.append(cur.decode())
            cur = b""
    if cur:
        out.append(cur.decode())
    return out


def journal_read():
    try:
        with open(JOURNAL) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def journal_write(entry):
    tmp = JOURNAL + ".tmp"
    with open(tmp, "w") as f:
        json.dump(entry, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, JOURNAL)


def journal_clear():
    try:
        os.remove(JOURNAL)
    except OSError:
        pass


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
        self.pending = None      # (opcode, name, callback)
        self.pending_at = None
        self.keys = []
        self.key_count = None
        self.values = {}
        self.counts = {}
        self.compact = 0
        self.listening = False
        self.hr_n = 0
        self.steps = []
        return self

    # --- link ---------------------------------------------------------------
    def centralManagerDidUpdateState_(self, central):
        if central.state() == CBManagerStatePoweredOn:
            central.scanForPeripheralsWithServices_options_(None, None)

    def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(self, central, peripheral, adv, rssi):
        if "WHO" not in str(peripheral.name() or "").upper():
            return
        say({"event": "found", "rssi": int(rssi)})
        central.stopScan()
        self.peripheral = peripheral
        peripheral.setDelegate_(self)
        central.connectPeripheral_options_(peripheral, None)

    def centralManager_didConnectPeripheral_(self, central, peripheral):
        say({"event": "connected"})
        peripheral.discoverServices_(None)

    def centralManager_didDisconnectPeripheral_error_(self, central, peripheral, error):
        say({"event": "disconnected", "error": None if error is None else str(error.localizedDescription()),
             "journal_pending": journal_read() is not None, "counts": self.counts, "compact": self.compact})
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
        if char.isNotifying():
            self.ready.add(short(char.UUID()))
        if len(self.ready) == 5 and self.tx is not None and not self.started:
            self.started = True
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(0.5, self, "tick:", None, True)
            self.begin()

    # --- command channel ----------------------------------------------------
    @objc.python_method
    def send(self, opcode, payload, name, callback, wwr=False):
        frame = encode_frame(bytes((0x23, self.seq & 0xFF, opcode)) + payload)
        self.seq = (self.seq + 1) & 0xFF
        say({"event": "tx", "name": name, "hex": frame.hex(), "wwr": wwr})
        self.pending = (opcode, name, callback)
        self.pending_at = time.time()
        self.peripheral.writeValue_forCharacteristic_type_(
            NSData.dataWithBytes_length_(frame, len(frame)), self.tx,
            CBCharacteristicWriteWithoutResponse if wwr else CBCharacteristicWriteWithResponse)

    def tick_(self, _timer):
        if self.pending and time.time() - self.pending_at > 6.0:
            opcode, name, callback = self.pending
            self.pending = None
            say({"event": "reply_timeout", "name": name})
            callback(None)

    @objc.python_method
    def on_reply(self, inner: bytes):
        if not self.pending or len(inner) < 4 or inner[2] != self.pending[0]:
            say({"event": "type24_unmatched", "hex": inner.hex()})
            return
        opcode, name, callback = self.pending
        self.pending = None
        data = inner[4:]
        say({"event": "reply", "name": name, "data": data.hex(), "ascii": ascii_fields(data)})
        callback(data)

    # --- RX -----------------------------------------------------------------
    @objc.python_method
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
            buf = b""
        self.buffers[uuid] = buf
        return frames

    def peripheral_didUpdateValueForCharacteristic_error_(self, peripheral, char, error):
        value = bytes(char.value() or b"")
        s = short(char.UUID())
        if s == "2A37":
            self.hr_n += 1
            return
        if s == "61080007":
            return
        for frame in self.take_frames(s, value):
            kind = f"{frame[4]:02x}" if len(frame) >= 5 else "raw"
            key = f"{s[-2:]}:{kind}"
            self.counts[key] = self.counts.get(key, 0) + 1
            if kind == "24":
                self.on_reply(frame[4:-4])
            elif kind == "33" and len(frame) == 152 and frame[:5].hex() == "aa9400b533":
                self.compact += 1
                if self.compact <= 20 or self.compact % 100 == 0:
                    inner = frame[4:-4]
                    say({"event": "compact33", "n": self.compact,
                         "device_time": int.from_bytes(inner[4:8], "little"), "hex": frame.hex()})

    # --- flows --------------------------------------------------------------
    @objc.python_method
    def begin(self):
        pending = journal_read()
        if MODE == "checkrestore":
            if not pending:
                say({"event": "checkrestore_no_journal"})
                self.hangup(); return
            self.check_flow(pending); return
        if MODE in ("reboot", "clock", "trim3f"):
            self.main_flow(); return
        if pending:
            say({"event": "journal_restore_first", "journal": pending})
            self.set_value(pending["key"], pending["original"], lambda ok: self.after_restore(ok, pending))
            return
        self.main_flow()

    @objc.python_method
    def after_restore(self, ok, pending):
        def verify(value):
            good = value == pending["original"]
            say({"event": "restore_verified" if good else "restore_unverified",
                 "key": pending["key"], "observed": value, "want": pending["original"]})
            if good:
                journal_clear()
            if MODE == "restore" or not good:
                self.hangup()
            else:
                self.main_flow()
        self.get_value(pending["key"], verify)

    @objc.python_method
    def main_flow(self):
        if MODE == "restore":
            say({"event": "nothing_to_restore"})
            self.hangup()
        elif MODE == "read":
            self.enumerate(lambda: self.read_all(0))
        elif MODE == "setreboot":
            self.setreboot_flow()
        elif MODE == "reboot":
            self.reboot_now("final_reboot")
        elif MODE == "clock":
            self.clock_flow()
        elif MODE == "trim3f":
            self.trim_flow()
        else:
            self.trial_flow()

    @objc.python_method
    def enumerate(self, done):
        def on_start(data):
            if not data or data[0] != 0x01 or len(data) < 4:
                say({"event": "enumerate_failed", "data": None if data is None else data.hex()})
                self.hangup(); return
            self.key_count = int.from_bytes(data[2:4], "little")
            say({"event": "key_count", "revision": data[1], "count": self.key_count})
            self.next_key(done)
        self.send(0x75, b"\x01", "ff_start", on_start)

    @objc.python_method
    def next_key(self, done):
        def on_next(data):
            if data and data[0] == 0x01 and len(data) >= 5 and data[3] != 0:
                names = ascii_fields(data[4:])
                if names:
                    self.keys.append(names[0])
            if len(self.keys) < (self.key_count or 0) and data is not None:
                self.next_key(done)
            else:
                say({"event": "keys", "keys": self.keys})
                done()
        self.send(0x76, b"\x01", "ff_next", on_next)

    @objc.python_method
    def get_value(self, key, callback):
        def on_get(data):
            value = None
            if data and data[0] == 0x01:
                names = [f for f in ascii_fields(data[1:]) if f != key]
                value = names[0] if names else None
            callback(value)
        self.send(0x80, b"\x01" + field(key), f"get:{key}", on_get)

    @objc.python_method
    def set_value(self, key, value, callback):
        def on_set(data):
            callback(bool(data) and data[0] == 0x01)
        self.send(0x78, b"\x01" + field(key) + field(value), f"set:{key}={value}", on_set)

    @objc.python_method
    def read_all(self, i):
        if i >= len(self.keys):
            say({"event": "values", "values": self.values})
            self.hangup(); return
        key = self.keys[i]
        def got(value):
            self.values[key] = value
            self.read_all(i + 1)
        self.get_value(key, got)

    @objc.python_method
    def trial_flow(self):
        key = TRIAL_KEY
        def got_v0(v0):
            if v0 not in ("1", "2") and TRIAL_VALUE is None:
                say({"event": "trial_refused", "key": key, "v0": v0, "reason": "v0 not raw 1/2"})
                self.hangup(); return
            v1 = TRIAL_VALUE or ("1" if v0 == "2" else "2")
            journal_write({"key": key, "original": v0, "trial": v1, "at": time.time()})
            say({"event": "journal_written", "key": key, "original": v0, "trial": v1})
            def set_done(ok):
                self.get_value(key, lambda v: self.after_set(key, v0, v1, v))
            self.set_value(key, v1, set_done)
        self.get_value(key, got_v0)

    @objc.python_method
    def after_set(self, key, v0, v1, observed):
        say({"event": "trial_value", "key": key, "v0": v0, "v1": v1, "observed": observed})
        self.trial = (key, v0, v1)
        self.counts = {}
        self.compact = 0
        self.send(0x3F, b"\x01", "3f01_stimulus", lambda d: None, wwr=True)
        self.pending = None  # WWR: the type-24 still arrives; do not block on it
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(LISTEN_S, self, "endListen:", None, False)

    def endListen_(self, _timer):
        key, v0, v1 = self.trial
        say({"event": "trial_result", "key": key, "v0": v0, "v1": v1, "compact33": self.compact,
             "counts": self.counts, "hr_n": self.hr_n})
        def stopped(_):
            if self.compact:
                say({"event": "compact_found_leaving_flag", "key": key, "value": v1})
                journal_clear()
                self.hangup(); return
            self.set_value(key, v0, lambda ok: self.get_value(key, lambda v: self.final_restore(key, v0, v)))
        self.send(0x3F, b"\x00", "3f00", stopped)

    @objc.python_method
    def final_restore(self, key, v0, observed):
        good = observed == v0
        say({"event": "restore_verified" if good else "restore_unverified", "key": key,
             "observed": observed, "want": v0})
        if good:
            journal_clear()
        self.hangup()

    @objc.python_method
    def reboot_now(self, reason):
        say({"event": "reboot", "reason": reason})
        self.send(0x1D, b"\x00", "reboot_1d00", lambda d: self.hangup())

    @objc.python_method
    def setreboot_flow(self):
        key = TRIAL_KEY
        def got_v0(v0):
            if v0 not in ("1", "2"):
                say({"event": "trial_refused", "key": key, "v0": v0}); self.hangup(); return
            v1 = "1" if v0 == "2" else "2"
            journal_write({"key": key, "original": v0, "trial": v1, "phase": "set_before_reboot", "at": time.time()})
            say({"event": "journal_written", "key": key, "original": v0, "trial": v1})
            def set_done(ok):
                def readback(v):
                    say({"event": "trial_value", "key": key, "v0": v0, "v1": v1, "observed": v})
                    self.reboot_now(f"apply:{key}={v1}")
                self.get_value(key, readback)
            self.set_value(key, v1, set_done)
        self.get_value(key, got_v0)

    @objc.python_method
    def check_flow(self, j):
        key, v0, v1 = j["key"], j["original"], j["trial"]
        def post_reboot(v):
            say({"event": "post_reboot_value", "key": key, "observed": v, "expected": v1})
            self.trial = (key, v0, v1)
            self.counts = {}
            self.compact = 0
            self.send(0x3F, b"\x01", "3f01_stimulus", lambda d: None, wwr=True)
            self.pending = None
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(LISTEN_S, self, "endListen:", None, False)
        self.get_value(key, post_reboot)

    @objc.python_method
    def clock_flow(self):
        def got(data):
            unix = int.from_bytes(data[1:5], "little") if data and data[0] == 0x01 and len(data) >= 5 else None
            say({"event": "clock", "device_unix": unix, "wall_unix": int(time.time())})
            if unix is not None and 1735689600 <= unix <= 1830297600:
                self.hangup(); return
            now = int(time.time())
            self.send(0x0A, now.to_bytes(4, "little") + b"\x00\x00\x00\x00", "set_clock",
                      lambda d: self.send(0x0B, b"\x00", "get_clock_after", lambda d2: self.hangup()))
        self.send(0x0B, b"\x00", "get_clock", got)

    @objc.python_method
    def get_range(self, label, callback):
        def got(data):
            inner = b"\x24\x00\x22\x00" + (data or b"")
            r = None
            if data and len(inner) >= 66:
                r = {"W": int.from_bytes(inner[14:18], "little"), "U": int.from_bytes(inner[18:22], "little"),
                     "capacity": int.from_bytes(inner[26:30], "little"),
                     "device_unix": int.from_bytes(inner[62:66], "little")}
                r["pending"] = (r["W"] - r["U"]) % r["capacity"] if r["capacity"] else None
            say({"event": "data_range", "label": label, "range": r})
            callback(r)
        self.send(0x22, b"\x00", f"range_{label}", got)

    @objc.python_method
    def trim_flow(self):
        def after_pre(r0):
            def after_trim(_):
                def after_post(r1):
                    say({"event": "fifo_state", "empty": bool(r1) and r1["W"] == r1["U"], "pre": r0, "post": r1})
                    self.counts = {}
                    self.compact = 0
                    self.send(0x3F, b"\x01", "3f01_stimulus", lambda d: None, wwr=True)
                    self.pending = None
                    NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                        LISTEN_S, self, "endTrim:", None, False)
                self.get_range("post_trim", after_post)
            self.send(0x19, b"\xfe" * 8 + b"\x00", "trim_19", after_trim)
        self.get_range("pre_trim", after_pre)

    def endTrim_(self, _timer):
        say({"event": "trim3f_result", "compact33": self.compact, "counts": self.counts, "hr_n": self.hr_n})
        if self.compact:
            say({"event": "compact_found_leaving_3f_on"})
            self.hangup(); return
        self.send(0x3F, b"\x00", "3f00", lambda d: self.hangup())

    @objc.python_method
    def hangup(self):
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(0.5, self, "cancelLink:", None, False)

    def cancelLink_(self, _timer):
        self.central.cancelPeripheralConnection_(self.peripheral)


say({"event": "start", "mode": MODE, "key": TRIAL_KEY, "value": TRIAL_VALUE, "listen_s": LISTEN_S,
     "journal_pending": journal_read()})
delegate = Delegate.alloc().init()
delegate.central = CBCentralManager.alloc().initWithDelegate_queue_(delegate, None)


class Watchdog(NSObject):
    def fire_(self, _timer):
        if not delegate.started:
            say({"event": "watchdog_no_link_120s"})
            AppHelper.stopEventLoop()


_wd = Watchdog.alloc().init()
NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(120.0, _wd, "fire:", None, False)
try:
    AppHelper.runConsoleEventLoop()
finally:
    say({"event": "exit"})
