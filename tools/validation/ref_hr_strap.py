#!/usr/bin/env python3
"""Record a reference chest strap (any standard BLE heart-rate strap) on the Mac.

Works with the standard Heart Rate profile (service 0x180D, measurement 0x2A37),
so Polar H10/H9, Garmin HRM, Wahoo TRACKR/TICKR, Coros and Suunto straps all
work. RR intervals are recorded when the strap sends them (Polar H10 does).
Never connects to a WHOOP (it also exposes 0x180D) so the iPhone keeps the strap.

Output CSV (wall clock, for alignment with Atria): unix_time,bpm,rr_ms
One row per RR interval; a row with an empty rr_ms when a packet has none.
Keep the file outside the repo (~/atria-validation/...). Validation plan §2.

Requires: pip install pyobjc-framework-CoreBluetooth
Usage: python3 ref_hr_strap.py OUT.csv [--name "Polar H10"] [--seconds 1800]
Run it from a terminal that has Bluetooth permission (the Claude Code
Terminal panel works; a sandboxed shell does not).
"""
from __future__ import annotations

import csv
import sys
import time

import objc
from CoreBluetooth import (
    CBCentralManager,
    CBUUID,
    CBManagerStatePoweredOn,
)
from Foundation import NSObject
from PyObjCTools import AppHelper

HR_SERVICE = CBUUID.UUIDWithString_("180D")
HR_MEASUREMENT = CBUUID.UUIDWithString_("2A37")


def parse_measurement(data: bytes) -> tuple[int, list[float]]:
    """Heart Rate Measurement (Bluetooth SIG): flags, HR (8/16-bit),
    optional energy expended, then RR intervals in 1/1024 s."""
    flags = data[0]
    i = 1
    if flags & 0x01:
        bpm = int.from_bytes(data[i:i + 2], "little")
        i += 2
    else:
        bpm = data[i]
        i += 1
    if flags & 0x08:
        i += 2  # energy expended
    rr = []
    if flags & 0x10:
        while i + 1 < len(data):
            rr.append(int.from_bytes(data[i:i + 2], "little") * 1000.0 / 1024.0)
            i += 2
    return bpm, rr


class Recorder(NSObject):
    def initWithPath_name_seconds_(self, path, name, seconds):
        self = objc.super(Recorder, self).init()
        self.file = open(path, "w", newline="")
        self.out = csv.writer(self.file)
        self.out.writerow(["unix_time", "bpm", "rr_ms"])
        self.name = (name or "").lower()
        self.deadline = time.time() + seconds
        self.peripheral = None
        self.rows = 0
        self.central = CBCentralManager.alloc().initWithDelegate_queue_(self, None)
        return self

    def centralManagerDidUpdateState_(self, central):
        if central.state() == CBManagerStatePoweredOn:
            print("scanning for a heart-rate strap…")
            central.scanForPeripheralsWithServices_options_([HR_SERVICE], None)

    def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(self, central, peripheral, adv, rssi):
        name = (peripheral.name() or adv.get("kCBAdvDataLocalName") or "").lower()
        if "whoo" in name:
            return  # never take the WHOOP away from the phone
        if self.name and self.name not in name:
            return
        print(f"connecting to {name or 'unnamed strap'} (RSSI {rssi})")
        self.peripheral = peripheral
        central.stopScan()
        peripheral.setDelegate_(self)
        central.connectPeripheral_options_(peripheral, None)

    def centralManager_didConnectPeripheral_(self, central, peripheral):
        peripheral.discoverServices_([HR_SERVICE])

    def centralManager_didDisconnectPeripheral_error_(self, central, peripheral, error):
        print(f"disconnected ({error}); reconnecting")
        central.connectPeripheral_options_(peripheral, None)

    def peripheral_didDiscoverServices_(self, peripheral, error):
        for service in peripheral.services() or []:
            peripheral.discoverCharacteristics_forService_([HR_MEASUREMENT], service)

    def peripheral_didDiscoverCharacteristicsForService_error_(self, peripheral, service, error):
        for ch in service.characteristics() or []:
            if ch.UUID() == HR_MEASUREMENT:
                peripheral.setNotifyValue_forCharacteristic_(True, ch)
                print("recording… (Ctrl-C to stop)")

    def peripheral_didUpdateValueForCharacteristic_error_(self, peripheral, ch, error):
        now = time.time()
        bpm, rr = parse_measurement(bytes(ch.value()))
        if rr:
            for value in rr:
                self.out.writerow([f"{now:.3f}", bpm, f"{value:.1f}"])
                self.rows += 1
        else:
            self.out.writerow([f"{now:.3f}", bpm, ""])
            self.rows += 1
        if self.rows % 60 == 0:
            self.file.flush()
            print(f"{self.rows} rows · {bpm} bpm")
        if now >= self.deadline:
            self.file.close()
            print(f"done: {self.rows} rows")
            AppHelper.stopEventLoop()


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1].startswith("-"):
        print(__doc__)
        return 2
    opt = lambda k, d: argv[argv.index(k) + 1] if k in argv else d
    Recorder.alloc().initWithPath_name_seconds_(argv[1], opt("--name", ""), float(opt("--seconds", "1800")))
    AppHelper.runConsoleEventLoop(installInterrupt=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
