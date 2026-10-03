"""Overnight Mac capture for WHOOP 4 with lossless disconnect handling (2026-09-23 design).

Live: stream-5 CCCD off->on, 3F/01 WWR; every CRC-valid 2B payload (R10 IMU + R11 PPG) and every
2A37 sample is stored whole (--raw JSONL: {"w","k":"r10"|"r11"|"hr"|"hist","hex"}).
Duty-cycled catch-up (every --drain-every seconds): 3F/00 -> 16/00 history drain, ACK every type-31
sub 2 (17/01+token), stop when a v24 row (0x2F, second @inner[7:11]) reaches the drain target
(device time at drain start - 1 s) or --drain-max; then 14/00, 3F/01. No 0x22 polling mid-drain,
no 0x19 trim (trim makes the strap discard pages while live is off).
Disconnect: auto-reconnect; on reconnect the gap is drained the same way before live resumes; the
firmware step counter (R10 u16 @1293) delta across the gap is logged as bridged steps.
Opcodes: 3F, 16, 17, 14 only.
A drain with no row for --drain-stall s (default 20) ends as "stalled"; live resumes and a retry drain
runs after --stall-retry s (default 60).
Usage: night_capture.py [--duration S] [--drain-every S] [--drain-max S] [--drain-stall S] [--log P] [--raw P]
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
DURATION = float(opt("--duration", "36000"))
DRAIN_EVERY = float(opt("--drain-every", "300"))
DRAIN_MAX = float(opt("--drain-max", "90"))
DRAIN_STALL = float(opt("--drain-stall", "20"))
STALL_RETRY = float(opt("--stall-retry", "60"))
LOG = opt("--log", "/tmp/atria-ble/night.jsonl")
RAW = opt("--raw", "/tmp/atria-ble/night-raw.jsonl")
OUT = open(LOG, "a", buffering=1)
ROUT = open(RAW, "a", buffering=1)
NOTIFY = {"61080003", "61080004", "61080005", "61080007", "2A37"}
T0 = time.time()


def say(e):
    e.setdefault("t", round(time.time() - T0, 3))
    e.setdefault("wall", time.strftime("%H:%M:%S"))
    OUT.write(json.dumps(e, separators=(",", ":")) + "\n")
    if e.get("event") not in ("hist_row",):
        print(json.dumps(e, separators=(",", ":")), flush=True)


def raw(k, b):
    ROUT.write(json.dumps({"w": time.time(), "k": k, "hex": b.hex()}, separators=(",", ":")) + "\n")


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


def valid_payload(fr):
    if len(fr) < 9 or fr[0] != 0xAA:
        return None
    n = fr[1] | (fr[2] << 8)
    if n < 5 or n + 4 > len(fr) or fr[3] != crc8(fr[1:3]):
        return None
    p = fr[4:n]
    return p if zlib.crc32(p) & 0xFFFFFFFF == int.from_bytes(fr[n:n + 4], "little") else None


class D(NSObject):
    def init(self):
        self = objc.super(D, self).init()
        self.c = self.p = self.tx = self.s5 = None
        self.ready, self.buf, self.seq = set(), {}, 1
        self.state = "connecting"      # connecting | live | draining
        self.connects = 0
        self.last_r10 = None           # {"seq","sec","fw","wall"}
        self.pre_gap = None
        self.dev_offset = None         # device second - wall
        self.drain = None              # {"target","started","rows","reason"}
        self.stats = {"r10": 0, "r11": 0, "hr": 0, "corrupt": 0, "missing": 0, "hist_rows": 0,
                      "drains": 0, "drain_timeouts": 0, "disconnects": 0, "bridged_fw_steps": 0,
                      "drain_paused_frames": 0}
        self.after_pause = False
        return self

    # ---- link ----------------------------------------------------------------------------------
    def centralManagerDidUpdateState_(self, c):
        if c.state() == CBManagerStatePoweredOn:
            c.scanForPeripheralsWithServices_options_(None, None)

    def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(self, c, p, adv, rssi):
        if "WHO" not in str(p.name() or "").upper():
            return
        c.stopScan()
        self.p = p
        p.setDelegate_(self)
        self.request_connect("discovered", int(rssi))

    @objc.python_method
    def request_connect(self, why, rssi=None):
        self.connect_requested_at = time.time()
        say({"event": "connect_request", "why": why, "rssi": rssi})
        self.c.connectPeripheral_options_(self.p, None)
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(20.0, self, "connectWatchdog:", None, False)

    def connectWatchdog_(self, _t):
        # CoreBluetooth never times out a pending connect; a hung request left the strap
        # advertising unseen for minutes (2026-09-23 22:01). Cancel and rescan.
        if self.state == "connecting" and time.time() - getattr(self, "connect_requested_at", 0) >= 19.5 \
                and (self.p is None or self.p.state() != 2):
            say({"event": "connect_watchdog_rescan"})
            if self.p is not None:
                self.c.cancelPeripheralConnection_(self.p)
            self.p = None
            self.c.scanForPeripheralsWithServices_options_(None, None)

    def centralManager_didFailToConnectPeripheral_error_(self, c, p, err):
        say({"event": "connect_failed", "error": None if err is None else str(err.localizedDescription())})
        self.p = None
        c.scanForPeripheralsWithServices_options_(None, None)

    def centralManager_didConnectPeripheral_(self, c, p):
        self.connects += 1
        self.ready, self.buf = set(), {}
        self.state = "connecting"
        say({"event": "connected", "n": self.connects})
        p.discoverServices_(None)

    def centralManager_didDisconnectPeripheral_error_(self, c, p, err):
        self.stats["disconnects"] += 1
        self.pre_gap = self.last_r10
        self.drain = None
        self.state = "connecting"
        say({"event": "disconnected", "error": None if err is None else str(err.localizedDescription()),
             "stats": self.stats})
        if getattr(self, "finishing", False):
            AppHelper.stopEventLoop()
            return
        if self.p is not None:
            self.request_connect("reconnect")

    def peripheral_didDiscoverServices_(self, p, e):
        for s in p.services() or []:
            p.discoverCharacteristics_forService_(None, s)

    def peripheral_didDiscoverCharacteristicsForService_error_(self, p, s, e):
        for ch in s.characteristics() or []:
            k = short(ch.UUID())
            if k == "61080002":
                self.tx = ch
            if k == "61080005":
                self.s5 = ch
            if k in NOTIFY:
                p.setNotifyValue_forCharacteristic_(True, ch)

    def peripheral_didUpdateNotificationStateForCharacteristic_error_(self, p, ch, e):
        if ch.isNotifying():
            self.ready.add(short(ch.UUID()))
        if len(self.ready) == 5 and self.tx is not None and "go" not in self.ready:
            self.ready.add("go")
            if self.connects == 1:
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(DURATION, self, "finish:", None, False)
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(DRAIN_EVERY, self, "periodicDrain:", None, True)
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(60.0, self, "summary:", None, True)
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(1.0, self, "tick:", None, True)
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(2.0, self, "cccdOff:", None, False)
            else:
                # Reconnect: drain the gap first (live 2B may already be flowing from the 3F latch).
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(4.0, self, "reconnectDrain:", None, False)

    def cccdOff_(self, _t):
        self.p.setNotifyValue_forCharacteristic_(False, self.s5)
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(0.4, self, "cccdOn:", None, False)

    def cccdOn_(self, _t):
        self.p.setNotifyValue_forCharacteristic_(True, self.s5)
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(2.0, self, "liveOn:", None, False)

    def liveOn_(self, _t):
        self.state = "live"
        self.send(0x3F, b"\x01", "3f01", wwr=True)

    # ---- tx ------------------------------------------------------------------------------------
    @objc.python_method
    def send(self, op, payload, name, wwr=False):
        if self.p is None or self.tx is None:
            return
        f = frame(bytes((0x23, self.seq & 0xFF, op)) + payload)
        self.seq += 1
        if name != "hist_ack":
            say({"event": "tx", "name": name})
        self.p.writeValue_forCharacteristic_type_(NSData.dataWithBytes_length_(f, len(f)), self.tx,
                                                  CBCharacteristicWriteWithoutResponse if wwr else CBCharacteristicWriteWithResponse)

    # ---- drains --------------------------------------------------------------------------------
    @objc.python_method
    def device_now(self):
        return None if self.dev_offset is None else time.time() + self.dev_offset

    @objc.python_method
    def start_drain(self, reason):
        if self.state == "draining" or self.p is None or getattr(self, "finishing", False):
            return
        now = self.device_now()
        if now is None:
            return
        self.state = "draining"
        self.stats["drains"] += 1
        self.drain = {"target": int(now) - 1, "started": time.time(), "rows": 0, "reason": reason,
                      "first_row": None, "last_row": None, "progress_at": time.time()}
        say({"event": "drain_start", "reason": reason, "target_device": self.drain["target"]})
        self.send(0x3F, b"\x00", "3f00_pause")
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(1.0, self, "drainGo:", None, False)

    def drainGo_(self, _t):
        if self.state == "draining" and not getattr(self, "finishing", False):
            self.send(0x16, b"\x00", "history_16")

    @objc.python_method
    def end_drain(self, why):
        if self.state != "draining" or self.drain is None:
            return
        d = self.drain
        say({"event": "drain_done", "why": why, "reason": d["reason"], "rows": d["rows"],
             "seconds": round(time.time() - d["started"], 1), "first_row": d["first_row"], "last_row": d["last_row"]})
        if why == "timeout":
            self.stats["drain_timeouts"] += 1
        self.drain = None
        self.after_pause = True
        self.send(0x14, b"\x00", "abort_14")
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(1.0, self, "liveOn:", None, False)

    def periodicDrain_(self, _t):
        if self.state == "live":
            self.start_drain("periodic")

    def reconnectDrain_(self, _t):
        gap = None
        if self.pre_gap and self.last_r10 and self.last_r10 is not self.pre_gap:
            fw = (self.last_r10["fw"] - self.pre_gap["fw"]) & 0xFFFF
            self.stats["bridged_fw_steps"] += fw
            gap = {"from_sec": self.pre_gap["sec"], "to_sec": self.last_r10["sec"], "fw_steps": fw,
                   "frames_skipped": (self.last_r10["seq"] - self.pre_gap["seq"] - 1) & 0xFFFF}
        say({"event": "reconnect_gap", "gap": gap})
        self.state = "live"
        self.start_drain("reconnect")
        if self.state != "draining":
            self.liveOn_(None)

    def tick_(self, _t):
        if self.state == "draining" and self.drain:
            if time.time() - self.drain["progress_at"] > DRAIN_STALL:
                # Nothing served for DRAIN_STALL s (seen after a burst of rapid disconnects):
                # stop waiting, resume live, retry soon. History stays on the strap.
                self.stats["drain_stalls"] = self.stats.get("drain_stalls", 0) + 1
                self.end_drain("stalled")
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(STALL_RETRY, self, "retryDrain:", None, False)
            elif time.time() - self.drain["started"] > DRAIN_MAX:
                self.end_drain("timeout")

    def retryDrain_(self, _t):
        if self.state == "live":
            self.start_drain("stall_retry")

    def summary_(self, _t):
        say({"event": "summary", "state": self.state, "stats": self.stats, "last_r10": self.last_r10})

    def finish_(self, _t):
        self.finishing = True
        say({"event": "finish", "stats": self.stats})
        # Never leave the strap serving history: a transfer left open (16/00
        # without 14/00) stops standard 2A37 HR for the next client
        # (2026-09-24: the iPhone connected and verified but got no HR).
        self.send(0x14, b"\x00", "abort_14_end")
        self.send(0x3F, b"\x00", "3f00_end")
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(2.0, self, "hang:", None, False)

    def hang_(self, _t):
        self.c.cancelPeripheralConnection_(self.p)

    # ---- rx ------------------------------------------------------------------------------------
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
        if k == "2A37":
            self.stats["hr"] += 1
            raw("hr", v)
            return
        if k == "61080007":
            return
        for fr in self.frames_from(k, v):
            pl = valid_payload(fr)
            if pl is None:
                if len(fr) > 4 and fr[4] == 0x2B:
                    self.stats["corrupt"] += 1
                continue
            typ = pl[0]
            if typ == 0x2B and len(pl) > 2:
                if pl[1] == 0x0A and len(pl) >= 1295:
                    raw("r10", pl)
                    self.stats["r10"] += 1
                    seq = int.from_bytes(pl[3:5], "little")
                    sec = int.from_bytes(pl[7:11], "little")
                    if self.last_r10 is not None and self.last_r10 is not self.pre_gap:
                        delta = (seq - self.last_r10["seq"]) & 0xFFFF
                        if 1 < delta < 0x8000:
                            # Frames not sent while live was deliberately paused for a drain are
                            # covered by 1 Hz history rows; only other gaps are real losses.
                            key = "drain_paused_frames" if self.after_pause else "missing"
                            self.stats[key] += delta - 1
                        if self.state == "live":
                            self.after_pause = False
                    self.last_r10 = {"seq": seq, "sec": sec, "fw": int.from_bytes(pl[1293:1295], "little"),
                                     "wall": round(time.time(), 2)}
                    self.dev_offset = sec + int.from_bytes(pl[11:13], "little") / 32768 - time.time()
                elif pl[1] == 0x0B:
                    raw("r11", pl)
                    self.stats["r11"] += 1
                continue
            if typ == 0x24:
                continue
            if self.state == "draining" and self.drain is not None:
                raw("hist", pl)
                if typ == 0x2F and len(pl) >= 11:
                    sec = int.from_bytes(pl[7:11], "little")
                    self.drain["rows"] += 1
                    self.drain["progress_at"] = time.time()
                    self.stats["hist_rows"] += 1
                    self.drain["first_row"] = self.drain["first_row"] or sec
                    self.drain["last_row"] = sec
                    if sec >= self.drain["target"]:
                        self.end_drain("caught_up")
                elif typ == 0x31 and len(pl) >= 21:
                    if pl[2] == 2:
                        self.send(0x17, b"\x01" + pl[13:21], "hist_ack")
                    elif pl[2] == 3:
                        self.end_drain("history_complete")


say({"event": "start", "duration_s": DURATION, "drain_every_s": DRAIN_EVERY, "raw": RAW})
d = D.alloc().init()
d.c = CBCentralManager.alloc().initWithDelegate_queue_(d, None)
try:
    AppHelper.runConsoleEventLoop()
finally:
    say({"event": "exit", "stats": d.stats})
