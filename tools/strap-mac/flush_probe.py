"""Disconnect → reconnect → graceful-flush experiment (Mac central, WHOOP 4).

Phases:
  A  connect, subscribe, 3F/01 WWR (R10 live), record ~A_S seconds; 0x22 range once.
  B  cancel the connection (controlled out-of-range stand-in) for GAP_S seconds.
  C  reconnect; log the first R10 frames (counter / device-time / firmware-step jumps), then
     3F/00, 0x22 (backlog), 16/00 history drain with ACKs (17/01+token) until W==U, a sub-3
     complete, or DRAIN_MAX_S; every history frame is stored whole; then 3F/01 to resume live.
Opcodes: 3F, 22, 16, 17, 14 (+19 trim with --trim-first). --poll re-enables 0x22 polling during drain. Output: JSONL events + raw frames (--log).
Usage: flush_probe.py [--live S] [--gap S] [--drain-max S] [--log PATH]
"""
from __future__ import annotations

import json
import sys
import time
import zlib

import objc
from CoreBluetooth import (CBCentralManager, CBCharacteristicWriteWithResponse,
                           CBCharacteristicWriteWithoutResponse, CBManagerStatePoweredOn)
from Foundation import NSData, NSObject, NSTimer
from PyObjCTools import AppHelper

A = sys.argv[1:]
opt = lambda n, d: A[A.index(n) + 1] if n in A else d
LIVE_S = float(opt("--live", "30"))
GAP_S = float(opt("--gap", "60"))
DRAIN_MAX_S = float(opt("--drain-max", "120"))
TRIM_FIRST = "--trim-first" in A
POLL = "--poll" in A
PRE_DRAIN = "--pre-drain" in A
LOG = opt("--log", "/tmp/atria-ble/flush.jsonl")
OUT = open(LOG, "a", buffering=1)
NOTIFY = {"61080003", "61080004", "61080005", "61080007", "2A37"}
T0 = time.time()


def say(e):
    e.setdefault("t", round(time.time() - T0, 3))
    e.setdefault("wall", time.strftime("%H:%M:%S"))
    line = json.dumps(e, separators=(",", ":"))
    print(line, flush=True)
    OUT.write(line + "\n")


def short(u):
    s = str(u.UUIDString()).upper().split("-")[0]
    return s[4:] if s.startswith("0000") else s


def crc8(d):
    c = 0
    for b in d:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 7) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


def frame(inner):
    n = len(inner) + 4
    lb = bytes((n & 0xFF, n >> 8))
    return b"\xaa" + lb + bytes((crc8(lb),)) + inner + (zlib.crc32(inner) & 0xFFFFFFFF).to_bytes(4, "little")


class D(NSObject):
    def init(self):
        self = objc.super(D, self).init()
        self.c = self.p = self.tx = None
        self.ready, self.buf, self.seq = set(), {}, 1
        self.phase = "A"
        self.pending = None
        self.last_r10 = None
        self.first_after = []
        self.drain_started = None
        self.hist_counts = {}
        self.ranges = []
        self.connects = 0
        return self

    # link
    def centralManagerDidUpdateState_(self, c):
        if c.state() == CBManagerStatePoweredOn:
            c.scanForPeripheralsWithServices_options_(None, None)

    def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(self, c, p, adv, rssi):
        if "WHO" not in str(p.name() or "").upper():
            return
        c.stopScan()
        self.p = p
        p.setDelegate_(self)
        c.connectPeripheral_options_(p, None)

    def centralManager_didConnectPeripheral_(self, c, p):
        self.connects += 1
        self.ready = set()
        self.buf = {}
        say({"event": "connected", "n": self.connects, "phase": self.phase})
        p.discoverServices_(None)

    def centralManager_didDisconnectPeripheral_error_(self, c, p, err):
        say({"event": "disconnected", "phase": self.phase,
             "error": None if err is None else str(err.localizedDescription())})
        if self.phase == "B":
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(GAP_S, self, "reconnect:", None, False)
        elif self.phase == "done":
            AppHelper.stopEventLoop()
        else:
            c.connectPeripheral_options_(p, None)

    def reconnect_(self, _t):
        self.phase = "C"
        say({"event": "reconnect_attempt"})
        self.c.connectPeripheral_options_(self.p, None)

    def peripheral_didDiscoverServices_(self, p, e):
        for s in p.services() or []:
            p.discoverCharacteristics_forService_(None, s)

    def peripheral_didDiscoverCharacteristicsForService_error_(self, p, s, e):
        for ch in s.characteristics() or []:
            k = short(ch.UUID())
            if k == "61080002":
                self.tx = ch
            if k in NOTIFY:
                p.setNotifyValue_forCharacteristic_(True, ch)

    def peripheral_didUpdateNotificationStateForCharacteristic_error_(self, p, ch, e):
        if ch.isNotifying():
            self.ready.add(short(ch.UUID()))
        if len(self.ready) == 5 and self.tx is not None and "subscribed" not in self.ready:
            self.ready.add("subscribed")
            say({"event": "subscribed", "phase": self.phase})
            if self.phase == "A":
                self.send(0x3F, b"\x01", "3f01", wwr=True)
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(3.0, self, "rangeA:", None, False)
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(LIVE_S, self, "goB:", None, False)
            elif self.phase == "C":
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(6.0, self, "startFlush:", None, False)

    # tx
    @objc.python_method
    def send(self, op, payload, name, wwr=False, cb=None):
        f = frame(bytes((0x23, self.seq & 0xFF, op)) + payload)
        self.seq += 1
        self.pending = (op, cb)
        say({"event": "tx", "name": name, "hex": f.hex()})
        self.p.writeValue_forCharacteristic_type_(NSData.dataWithBytes_length_(f, len(f)), self.tx,
                                                  CBCharacteristicWriteWithoutResponse if wwr else CBCharacteristicWriteWithResponse)

    def rangeA_(self, _t):
        self.send(0x22, b"\x00", "range_A")
        if TRIM_FIRST:
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(1.5, self, "trimA:", None, False)

    def trimA_(self, _t):
        # Live R10 supersedes history while connected: collapse the backlog to the head.
        self.send(0x19, b"\xfe" * 8 + b"\x00", "trim_19")
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(1.5, self, "rangeA2:", None, False)

    def rangeA2_(self, _t):
        self.send(0x22, b"\x00", "range_A_after_trim")

    def goB_(self, _t):
        if PRE_DRAIN and not getattr(self, "pre_drained", False):
            self.pre_drained = True
            self.gap_end_device = self.last_r10["sec"] if self.last_r10 else None
            say({"event": "pre_drain_start", "target_device": self.gap_end_device})
            self.phase = "C_flush"
            self.after_flush = "pre"
            self.send(0x3F, b"\x00", "3f00_pause_live_pre")
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(1.0, self, "drain:", None, False)
            return
        self.phase = "B"
        self.gap_start_device = self.last_r10["sec"] if self.last_r10 else None
        say({"event": "phase_B_disconnect", "last_r10": self.last_r10})
        self.c.cancelPeripheralConnection_(self.p)

    def startFlush_(self, _t):
        self.gap_end_device = self.first_after[0]["sec"] if self.first_after else None
        say({"event": "phase_C_first_frames", "frames": self.first_after[:8],
             "gap_device": [getattr(self, "gap_start_device", None), self.gap_end_device]})
        self.phase = "C_flush"
        self.send(0x3F, b"\x00", "3f00_pause_live")
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(1.5, self, "rangeC:", None, False)

    def rangeC_(self, _t):
        self.send(0x22, b"\x00", "range_C_before_drain")
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(1.0, self, "drain:", None, False)

    def drain_(self, _t):
        self.drain_started = time.time()
        self.drain_timer_phase = self.phase
        self.send(0x16, b"\x00", "history_16")
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(1.0, self, "drainTick:", None, True)

    def drainTick_(self, t):
        if self.phase != "C_flush" or self.drain_started is None:
            t.invalidate()
            return
        if time.time() - self.drain_started > DRAIN_MAX_S:
            say({"event": "drain_timeout", "counts": self.hist_counts})
            self.finishFlush("timeout")
        elif POLL and int(time.time() - self.drain_started) % 5 == 0:
            self.send(0x22, b"\x00", "range_poll")

    @objc.python_method
    def finishFlush(self, why):
        if self.phase != "C_flush":
            return
        self.phase = "C_resume"
        started, self.drain_started = self.drain_started, None
        say({"event": "flush_done", "why": why, "seconds": round(time.time() - started, 1),
             "rows_served": getattr(self, "rows_served", 0),
             "counts": self.hist_counts, "ranges": self.ranges[-3:]})
        self.send(0x14, b"\x00", "abort_history_14")
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(1.0, self, "resume:", None, False)

    def resume_(self, _t):
        self.send(0x3F, b"\x01", "3f01_resume", wwr=True)
        if getattr(self, "after_flush", None) == "pre":
            self.after_flush = None
            self.phase = "A"
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(12.0, self, "goB:", None, False)
            return
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(15.0, self, "end:", None, False)

    def end_(self, _t):
        say({"event": "resume_check", "last_r10": self.last_r10})
        self.phase = "done"
        self.send(0x3F, b"\x00", "3f00_end")
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(2.0, self, "hang:", None, False)

    def hang_(self, _t):
        self.c.cancelPeripheralConnection_(self.p)

    # rx
    @objc.python_method
    def frames_from(self, k, chunk):
        b = self.buf.get(k, b"") + chunk
        out = []
        while len(b) >= 8 and b[0] == 0xAA:
            n = (b[1] | (b[2] << 8)) + 4
            if n < 8 or n > 4096:
                b = b[1:]
                continue
            if len(b) < n:
                break
            out.append(b[:n])
            b = b[n:]
        if b and b[0] != 0xAA:
            b = b""
        self.buf[k] = b
        return out

    def peripheral_didUpdateValueForCharacteristic_error_(self, p, ch, e):
        k = short(ch.UUID())
        v = bytes(ch.value() or b"")
        if k in ("2A37", "61080007"):
            return
        for fr in self.frames_from(k, v):
            if len(fr) < 9:
                continue
            typ = fr[4]
            inner = fr[4:-4]
            if typ == 0x24:
                say({"event": "reply", "cmd": f"{inner[2]:02x}", "hex": fr.hex()})
                if inner[2] == 0x22 and len(inner) >= 66:
                    r = {"W": int.from_bytes(inner[14:18], "little"), "U": int.from_bytes(inner[18:22], "little"),
                         "device_unix": int.from_bytes(inner[62:66], "little"), "phase": self.phase, "wall": time.time()}
                    self.ranges.append(r)
                    say({"event": "range", **r})
                    if self.phase == "C_flush" and self.drain_started and r["W"] == r["U"]:
                        self.finishFlush("caught_up_W_eq_U")
                continue
            if typ == 0x2B and len(inner) > 20 and inner[1] == 0x0A:
                self.last_r10 = {"seq": int.from_bytes(inner[3:5], "little"), "sec": int.from_bytes(inner[7:11], "little"),
                                 "fw_steps": int.from_bytes(inner[1293:1295], "little") if len(inner) > 1295 else None,
                                 "wall": round(time.time(), 2)}
                if self.phase == "C" and len(self.first_after) < 20:
                    self.first_after.append(self.last_r10)
                continue
            if self.phase == "C_flush":
                key = f"{k[-2:]}:{typ:02x}"
                self.hist_counts[key] = self.hist_counts.get(key, 0) + 1
                say({"event": "hist", "uuid": k, "type": f"{typ:02x}", "len": len(fr), "hex": fr.hex()})
                if typ == 0x2F and len(inner) >= 11:
                    row_sec = int.from_bytes(inner[7:11], "little")
                    self.rows_served = getattr(self, "rows_served", 0) + 1
                    end = getattr(self, "gap_end_device", None)
                    if end and row_sec >= end - 1:
                        self.finishFlush("caught_up_to_reconnect_time")
                if typ == 0x31 and len(inner) >= 21:
                    sub = inner[2]
                    if sub == 2:
                        self.send(0x17, b"\x01" + inner[13:21], "hist_ack")
                    elif sub == 3:
                        self.finishFlush("history_complete_sub3")


say({"event": "start", "live_s": LIVE_S, "gap_s": GAP_S, "drain_max_s": DRAIN_MAX_S})
d = D.alloc().init()
d.c = CBCentralManager.alloc().initWithDelegate_queue_(d, None)
try:
    AppHelper.runConsoleEventLoop()
finally:
    say({"event": "exit"})
