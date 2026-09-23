"""Mac capture + decode of native WHOOP 4 R10 IMU (packet 0x2B, record 0x0A).

R10 layout (ported from Atria/Atria/AtriaR10Motion.swift): payload = frame[4:declared]
(0x2B, 0x0A, ...), device second u32le @7, HR @17, 100 planar int16le samples per axis:
accel x/y/z @85/285/485 (1/4096 g), gyro x/y/z @688/888/1088 (0.06103515625 dps).
Frames are CRC-checked (crc8 header + crc32 payload). Corrupt frames are counted, never decoded.

Flow: connect, subscribe, optional stream-5 CCCD off->on (run C stability), 3F/01 WWR, capture.
On disconnect: reconnect (the 3F latch resumes 2B). At the end: 3F/00.
Outputs: events log (--log) and decoded samples (--samples, one JSON line per R10 frame).
Usage: r10_capture.py [--duration S] [--log P] [--samples P] [--no-cccd]
"""
from __future__ import annotations

import json
import math
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

ARGS = sys.argv[1:]


def opt(name, default):
    if name in ARGS:
        i = ARGS.index(name)
        return ARGS[i + 1]
    return default


DURATION = float(opt("--duration", "300"))
LOG = opt("--log", "/tmp/atria-ble/r10-capture.jsonl")
SAMPLES = opt("--samples", "/tmp/atria-ble/r10-samples.jsonl")
DO_CCCD = "--no-cccd" not in ARGS
OUT = open(LOG, "a", buffering=1)
SOUT = open(SAMPLES, "a", buffering=1)
NOTIFY_SHORT = {"61080003", "61080004", "61080005", "61080007", "2A37"}
STARTED = time.time()

ACC_OFF = (85, 285, 485)
GYR_OFF = (688, 888, 1088)
ACC_SCALE = 1.0 / 4096.0
GYR_SCALE = 0.06103515625
N = 100


def say(event):
    event.setdefault("t", round(time.time() - STARTED, 3))
    event.setdefault("wall", time.strftime("%H:%M:%S"))
    line = json.dumps(event, separators=(",", ":"))
    print(line, flush=True)
    OUT.write(line + "\n")


def short(uuid):
    s = str(uuid.UUIDString()).upper().split("-")[0]
    return s[4:] if s.startswith("0000") else s


def crc8(data):
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


def encode_frame(inner):
    length = len(inner) + 4
    lb = bytes((length & 0xFF, (length >> 8) & 0xFF))
    return b"\xaa" + lb + bytes((crc8(lb),)) + inner + (zlib.crc32(inner) & 0xFFFFFFFF).to_bytes(4, "little")


def validated_payload(frame):
    if len(frame) < 9 or frame[0] != 0xAA:
        return None
    declared = frame[1] | (frame[2] << 8)
    if declared < 5 or declared + 4 > len(frame) or frame[3] != crc8(frame[1:3]):
        return None
    payload = frame[4:declared]
    if zlib.crc32(payload) & 0xFFFFFFFF != int.from_bytes(frame[declared:declared + 4], "little"):
        return None
    return payload


def i16(p, o):
    return int.from_bytes(p[o:o + 2], "little", signed=True)


def planar(p, offs):
    return [[i16(p, offs[a] + 2 * k) for a in range(3)] for k in range(N)]


def mag_stats(vecs, scale):
    mags = [math.sqrt(sum((c * scale) ** 2 for c in v)) for v in vecs]
    mean = sum(mags) / len(mags)
    sd = math.sqrt(sum((m - mean) ** 2 for m in mags) / len(mags))
    return mean, sd


class Delegate(NSObject):
    def init(self):
        self = objc.super(Delegate, self).init()
        self.central = None
        self.peripheral = None
        self.tx = None
        self.stream5 = None
        self.ready = set()
        self.armed = False
        self.seq = 1
        self.buffers = {}
        self.stats = {"r10": 0, "r11": 0, "corrupt": 0, "other": 0, "connects": 0, "disconnects": 0, "missing": 0, "seq_resets": 0}
        self.last_seq = None
        self.win = {"r10": 0, "acc_sd": [], "gyr_mean": [], "hr": None}
        self.last_ts = None
        self.gaps = []
        self.ts_seen = 0
        self.finishing = False
        return self

    # --- link ---------------------------------------------------------------
    def centralManagerDidUpdateState_(self, central):
        if central.state() == CBManagerStatePoweredOn:
            central.scanForPeripheralsWithServices_options_(None, None)

    def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(self, central, peripheral, adv, rssi):
        if "WHO" not in str(peripheral.name() or "").upper():
            return
        central.stopScan()
        self.peripheral = peripheral
        peripheral.setDelegate_(self)
        say({"event": "found", "rssi": int(rssi)})
        central.connectPeripheral_options_(peripheral, None)

    def centralManager_didConnectPeripheral_(self, central, peripheral):
        self.stats["connects"] += 1
        self.ready = set()
        self.buffers = {}
        say({"event": "connected", "n": self.stats["connects"]})
        peripheral.discoverServices_(None)

    def centralManager_didDisconnectPeripheral_error_(self, central, peripheral, error):
        self.stats["disconnects"] += 1
        say({"event": "disconnected", "error": None if error is None else str(error.localizedDescription()),
             "stats": self.stats})
        if self.finishing:
            AppHelper.stopEventLoop()
            return
        central.connectPeripheral_options_(peripheral, None)

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
        if char.isNotifying():
            self.ready.add(short(char.UUID()))
        if len(self.ready) == 5 and self.tx is not None and not self.armed:
            self.armed = True
            say({"event": "subscribed"})
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(5.0, self, "summary:", None, True)
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(DURATION, self, "finish:", None, False)
            if DO_CCCD:
                NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(3.0, self, "cccdOff:", None, False)
            else:
                self.start3F_(None)

    def cccdOff_(self, _t):
        say({"event": "cccd_toggle_off"})
        self.peripheral.setNotifyValue_forCharacteristic_(False, self.stream5)
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(0.4, self, "cccdOn:", None, False)

    def cccdOn_(self, _t):
        say({"event": "cccd_toggle_on"})
        self.peripheral.setNotifyValue_forCharacteristic_(True, self.stream5)
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(3.0, self, "start3F:", None, False)

    def start3F_(self, _t):
        frame = encode_frame(bytes((0x23, self.seq, 0x3F, 0x01)))
        self.seq += 1
        say({"event": "tx", "name": "3f01", "hex": frame.hex()})
        self.peripheral.writeValue_forCharacteristic_type_(
            NSData.dataWithBytes_length_(frame, len(frame)), self.tx, CBCharacteristicWriteWithoutResponse)

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
        s = short(char.UUID())
        value = bytes(char.value() or b"")
        if s == "2A37":
            if len(value) > 1:
                self.win["hr"] = value[1]
            return
        if s != "61080005":
            return
        for frame in self.take_frames(s, value):
            self.on_frame(frame)

    @objc.python_method
    def on_frame(self, frame):
        payload = validated_payload(frame)
        if payload is None:
            if len(frame) >= 5 and frame[4] == 0x2B:
                self.stats["corrupt"] += 1
            else:
                self.stats["other"] += 1
            return
        if payload[0] != 0x2B:
            self.stats["other"] += 1
            return
        if payload[1] == 0x0B:
            self.stats["r11"] += 1
            return
        if payload[1] != 0x0A or len(payload) < 1288:
            self.stats["other"] += 1
            return
        ts = int.from_bytes(payload[7:11], "little")
        seq = int.from_bytes(payload[3:5], "little")
        hr = payload[17]
        acc = planar(payload, ACC_OFF)
        gyr = planar(payload, GYR_OFF)
        self.stats["r10"] += 1
        if self.last_seq is not None:
            delta = (seq - self.last_seq) & 0xFFFF
            if 1 < delta < 0x8000:
                self.stats["missing"] += delta - 1
                say({"event": "missing_frames", "n": delta - 1, "from_seq": self.last_seq, "to_seq": seq,
                     "device_second": ts})
            elif delta == 0 or delta >= 0x8000:
                self.stats["seq_resets"] += 1
                say({"event": "seq_reset", "from_seq": self.last_seq, "to_seq": seq})
        self.last_seq = seq
        gap = None
        if self.last_ts is not None:
            gap = ts - self.last_ts
            self.gaps.append(gap)
        self.last_ts = ts
        a_mean, a_sd = mag_stats(acc, ACC_SCALE)
        g_mean, _ = mag_stats(gyr, GYR_SCALE)
        self.win["r10"] += 1
        self.win["acc_sd"].append(a_sd)
        self.win["gyr_mean"].append(g_mean)
        SOUT.write(json.dumps({"wall": time.time(), "device_second": ts, "seq16": seq, "missing_total": self.stats["missing"], "hr": hr, "gap": gap,
                               "acc_raw": acc, "gyr_raw": gyr, "acc_scale": ACC_SCALE,
                               "gyr_scale": GYR_SCALE}, separators=(",", ":")) + "\n")

    def summary_(self, _t):
        w = self.win
        say({"event": "win5s", "r10": w["r10"],
             "acc_sd_g": round(max(w["acc_sd"]), 4) if w["acc_sd"] else None,
             "gyro_dps": round(sum(w["gyr_mean"]) / len(w["gyr_mean"]), 1) if w["gyr_mean"] else None,
             "hr": w["hr"], "last_device_second": self.last_ts, "stats": self.stats,
             "max_gap": max(self.gaps) if self.gaps else None})
        self.win = {"r10": 0, "acc_sd": [], "gyr_mean": [], "hr": w["hr"]}

    def finish_(self, _t):
        big = [g for g in self.gaps if g is None or g > 1 or g < 0]
        say({"event": "finish", "stats": self.stats, "gaps_total": len(self.gaps),
             "gaps_over_1s_or_negative": len(big), "gap_hist": {str(g): self.gaps.count(g) for g in sorted(set(self.gaps))[:12]}})
        self.finishing = True
        frame = encode_frame(bytes((0x23, self.seq, 0x3F, 0x00)))
        say({"event": "tx", "name": "3f00", "hex": frame.hex()})
        self.peripheral.writeValue_forCharacteristic_type_(
            NSData.dataWithBytes_length_(frame, len(frame)), self.tx, CBCharacteristicWriteWithResponse)
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(2.0, self, "hangup:", None, False)

    def hangup_(self, _t):
        self.central.cancelPeripheralConnection_(self.peripheral)
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(3.0, self, "quit:", None, False)

    def quit_(self, _t):
        AppHelper.stopEventLoop()


say({"event": "start", "duration_s": DURATION, "cccd_toggle": DO_CCCD, "samples": SAMPLES})
delegate = Delegate.alloc().init()
delegate.central = CBCentralManager.alloc().initWithDelegate_queue_(delegate, None)
try:
    AppHelper.runConsoleEventLoop()
finally:
    say({"event": "exit"})
    SOUT.close()
