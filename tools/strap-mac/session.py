"""Mac session: Harvard init, wait for history complete, then one 6A/01.

Compact IMU is only a 152-byte stream-5 frame AA 94 00 B5 33. Type 2B and
type 0x28 are recorded and are not treated as that stream.

Never sends 0x9A, 0x34, 0x35, or 0x1D.
"""
import json
import sys
import time
import zlib

import objc
from CoreBluetooth import (
    CBCentralManager,
    CBCharacteristicWriteWithResponse,
    CBManagerStatePoweredOn,
)
from Foundation import NSData, NSObject, NSTimer
from PyObjCTools import AppHelper

OUT_PATH = sys.argv[1] if len(sys.argv) > 1 else "/tmp/atria-ble/history-complete-6a.jsonl"
OUT = open(OUT_PATH, "w")
TX = "61080002-8D6D-82B8-614A-1C8CB0F8DCC6"
NOTIFY = {
    "61080003-8D6D-82B8-614A-1C8CB0F8DCC6",
    "61080004-8D6D-82B8-614A-1C8CB0F8DCC6",
    "61080005-8D6D-82B8-614A-1C8CB0F8DCC6",
    "61080007-8D6D-82B8-614A-1C8CB0F8DCC6",
    "2A37",
}
INIT = [
    ("hello", 0x23, b"\x00"),
    ("name", 0x4C, b"\x00"),
    ("range", 0x22, b"\x00"),
    ("alarm", 0x43, b"\x01"),
    ("history", 0x16, b"\x00"),
]
HISTORY_WAIT_S = 180.0
HISTORY_STALL_S = 45.0
LISTEN_AFTER_6A_S = 20.0
COMPACT_EXTEND_S = 60.0
STARTED = time.time()
SEQ = 1


def crc8(data: bytes) -> int:
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


def encode_frame(payload: bytes) -> bytes:
    length = len(payload) + 4
    length_bytes = bytes((length & 0xFF, (length >> 8) & 0xFF))
    crc = zlib.crc32(payload) & 0xFFFFFFFF
    return b"\xaa" + length_bytes + bytes((crc8(length_bytes),)) + payload + crc.to_bytes(4, "little")


def say(event):
    event["t"] = round(time.time() - STARTED, 3)
    line = json.dumps(event)
    print(line, flush=True)
    OUT.write(line + "\n")
    OUT.flush()


def err_text(error):
    if error is None:
        return None
    return f"{error.domain()} {error.code()} {error.localizedDescription()}"


def transmit(delegate, opcode, payload, name):
    global SEQ
    body = bytes((0x23, SEQ & 0xFF, opcode)) + payload
    SEQ = (SEQ + 1) & 0xFF
    frame = encode_frame(body)
    data = NSData.dataWithBytes_length_(frame, len(frame))
    say({"event": "tx", "name": name, "opcode": f"{opcode:02x}", "frame": frame.hex()})
    delegate.peripheral.writeValue_forCharacteristic_type_(
        data, delegate.tx, CBCharacteristicWriteWithResponse
    )


def ack_history(delegate, token: bytes):
    global SEQ
    body = bytes((0x23, SEQ & 0xFF, 0x17, 0x01)) + token
    SEQ = (SEQ + 1) & 0xFF
    frame = encode_frame(body)
    data = NSData.dataWithBytes_length_(frame, len(frame))
    say({"event": "tx", "name": "history_ack", "frame": frame.hex(), "token": token.hex()})
    delegate.peripheral.writeValue_forCharacteristic_type_(
        data, delegate.tx, CBCharacteristicWriteWithResponse
    )


def parse_type24(frame: bytes):
    if len(frame) < 12 or frame[0] != 0xAA or frame[4] != 0x24:
        return None
    inner = frame[4:-4]
    if len(inner) < 4:
        return None
    return {
        "resp_seq": inner[1],
        "cmd_echo": inner[2],
        "req_seq": inner[3],
        "data": inner[4:].hex(),
        "status": inner[4] if len(inner) > 4 else None,
    }


class Delegate(NSObject):
    def init(self):
        self = objc.super(Delegate, self).init()
        self.central = None
        self.peripheral = None
        self.tx = None
        self.ready = set()
        self.phase = "subscribe"
        self.init_index = 0
        self.counts = {}
        self.compact = []
        self.hr = []
        self.history_done = False
        self.history_started_at = None
        self.last_history_rx_at = None
        self.imu_sent = False
        self.imu_sent_at = None
        self.aborted = False
        self.stalled = False
        self.saw_2b = False
        self.sent_3f00 = False
        self.six_a_replies = []
        self.followup_69_done = False
        self.followup_pending = False
        self.listen_deadline = None
        self.buffers = {}
        self.finished = False
        return self

    def centralManagerDidUpdateState_(self, central):
        if central.state() == CBManagerStatePoweredOn:
            say({"event": "scanning"})
            central.scanForPeripheralsWithServices_options_(None, None)

    def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(
        self, central, peripheral, adv, rssi
    ):
        name = str(peripheral.name() or "")
        if "WHO" not in name.upper():
            return
        say({"event": "found", "name": name, "rssi": int(rssi)})
        central.stopScan()
        self.peripheral = peripheral
        peripheral.setDelegate_(self)
        central.connectPeripheral_options_(peripheral, None)

    def centralManager_didFailToConnectPeripheral_error_(self, central, peripheral, error):
        say({"event": "connect_failed", "error": err_text(error)})
        AppHelper.stopEventLoop()

    def centralManager_didConnectPeripheral_(self, central, peripheral):
        say({"event": "connected"})
        peripheral.discoverServices_(None)

    def centralManager_didDisconnectPeripheral_error_(self, central, peripheral, error):
        say({
            "event": "disconnected",
            "error": err_text(error),
            "counts": self.counts,
            "compact": len(self.compact),
            "hr": len(self.hr),
            "history_done": self.history_done,
            "six_a_replies": self.six_a_replies,
        })
        AppHelper.stopEventLoop()

    def peripheral_didDiscoverServices_(self, peripheral, error):
        for service in peripheral.services() or []:
            peripheral.discoverCharacteristics_forService_(None, service)

    def peripheral_didDiscoverCharacteristicsForService_error_(self, peripheral, service, error):
        for char in service.characteristics() or []:
            uuid = str(char.UUID().UUIDString()).upper()
            if uuid == TX:
                self.tx = char
            short = uuid.split("-")[0]
            if short.startswith("0000"):
                short = short[4:]
            if uuid in NOTIFY or short in NOTIFY:
                peripheral.setNotifyValue_forCharacteristic_(True, char)

    def peripheral_didUpdateNotificationStateForCharacteristic_error_(
        self, peripheral, characteristic, error
    ):
        if not characteristic.isNotifying():
            say({
                "event": "notify_off",
                "uuid": str(characteristic.UUID().UUIDString())[:8],
                "error": err_text(error),
            })
            return
        self.ready.add(str(characteristic.UUID().UUIDString()).upper())
        if self.phase == "subscribe" and self.tx is not None and len(self.ready) >= 5:
            self.phase = "init"
            name, opcode, payload = INIT[0]
            transmit(self, opcode, payload, name)

    def beginImuWithReason_(self, reason):
        if self.imu_sent or self.tx is None:
            return
        say({"event": "start_imu", "reason": reason, "counts": self.counts})
        self.imu_sent = True
        self.imu_sent_at = time.time()
        self.phase = "imu"
        self.listen_deadline = time.time() + LISTEN_AFTER_6A_S
        transmit(self, 0x6A, b"\x01", "6a01")

    def peripheral_didWriteValueForCharacteristic_error_(self, peripheral, characteristic, error):
        say({"event": "did_write", "phase": self.phase, "error": err_text(error)})
        if error is not None:
            return
        if self.phase == "init":
            self.init_index += 1
            if self.init_index < len(INIT):
                name, opcode, payload = INIT[self.init_index]
                transmit(self, opcode, payload, name)
            else:
                self.phase = "history"
                self.history_started_at = time.time()
                self.last_history_rx_at = time.time()
                say({"event": "history_wait_begin", "wait_s": HISTORY_WAIT_S})
        elif self.phase == "abort":
            self.beginImuWithReason_("after_abort")
        elif self.phase == "history_done":
            self.beginImuWithReason_("history_complete")
        elif self.phase == "followup_69":
            self.phase = "followup_6a"
            self.followup_pending = False
            self.listen_deadline = time.time() + LISTEN_AFTER_6A_S
            transmit(self, 0x6A, b"\x01", "6a01_after_69")

    def take_frames(self, uuid, chunk: bytes):
        buf = self.buffers.get(uuid, b"") + chunk
        frames = []
        while len(buf) >= 8 and buf[0] == 0xAA:
            declared = buf[1] | (buf[2] << 8)
            total = declared + 4
            if total < 8 or total > 4096:
                buf = buf[1:]
                continue
            if len(buf) < total:
                break
            frames.append(buf[:total])
            buf = buf[total:]
        if buf and buf[0] != 0xAA:
            if uuid.endswith("2A37") or not buf.startswith(b"\xaa"):
                frames.append(buf)
                buf = b""
        self.buffers[uuid] = buf
        return frames

    def maybe_followup_69(self):
        if self.followup_69_done or self.followup_pending or self.tx is None:
            return False
        if self.compact or not self.six_a_replies:
            return False
        # Required path: first 6A yielded status 00 and zero 0x33.
        if not any(r.get("status") == 0 for r in self.six_a_replies):
            return False
        self.followup_69_done = True
        self.followup_pending = True
        self.phase = "followup_69"
        say({
            "event": "followup_69",
            "reason": "6a_status_00_no_compact",
            "six_a_replies": self.six_a_replies,
        })
        transmit(self, 0x69, b"\x00", "6900")
        return True

    def note_frame(self, uuid, frame: bytes):
        kind = "raw"
        if len(frame) >= 5 and frame[0] == 0xAA:
            kind = f"{frame[4]:02x}"
        self.counts[kind] = self.counts.get(kind, 0) + 1
        if uuid.endswith("2A37") and len(frame) >= 2:
            self.hr.append(frame[1])
            if len(self.hr) == 1 or len(self.hr) % 10 == 0:
                say({"event": "hr", "bpm": frame[1], "n": len(self.hr)})
            return

        detail = None
        if kind in ("30", "31", "32"):
            self.last_history_rx_at = time.time()

        if kind == "33" and len(frame) == 152:
            payload = frame[4:-4]
            if len(payload) >= 24 and payload[0] == 0x33:
                device_time = int.from_bytes(payload[4:8], "little")
                accel_n = int.from_bytes(payload[20:22], "little")
                gyro_n = int.from_bytes(payload[22:24], "little")
                gap = None
                if self.compact:
                    gap = device_time - self.compact[-1]
                self.compact.append(device_time)
                detail = {
                    "device_time": device_time,
                    "accel": accel_n,
                    "gyro": gyro_n,
                    "gap": gap,
                    "n": len(self.compact),
                }
                # Keep counting while compact is flowing.
                self.listen_deadline = max(
                    self.listen_deadline or 0, time.time() + COMPACT_EXTEND_S
                )

        if kind == "2b" and not self.saw_2b:
            self.saw_2b = True
            say({"event": "saw_2b", "hex": frame[:24].hex(), "len": len(frame)})
            if not self.sent_3f00 and self.tx is not None:
                self.sent_3f00 = True
                transmit(self, 0x3F, b"\x00", "3f00")

        if kind == "24":
            parsed = parse_type24(frame)
            say({
                "event": "rx",
                "uuid": uuid[:8],
                "kind": kind,
                "len": len(frame),
                "hex": frame.hex(),
                "parsed": parsed,
            })
            if parsed and parsed.get("cmd_echo") == 0x6A:
                self.six_a_replies.append(parsed)
                say({"event": "type24_6a", "parsed": parsed, "full_hex": frame.hex()})
            return

        interesting = kind in ("31", "33", "34") or (
            kind not in ("28", "2b", "2f", "30", "32") and self.counts[kind] <= 3
        )
        if interesting or (kind == "2b" and self.counts[kind] <= 3):
            say({
                "event": "rx",
                "uuid": uuid[:8],
                "kind": kind,
                "len": len(frame),
                "hex": frame.hex() if kind in ("31", "33", "34") or len(frame) <= 64 else frame[:40].hex(),
                "detail": detail,
            })

        if kind == "31" and len(frame) >= 8:
            inner = frame[4:-4]
            if len(inner) >= 3 and inner[0] == 0x31:
                sub = inner[2]
                say({"event": "meta", "sub": sub, "inner_len": len(inner)})
                if sub == 2 and len(inner) >= 21 and self.tx is not None:
                    ack_history(self, inner[13:21])
                if sub == 3 and not self.imu_sent:
                    self.history_done = True
                    self.phase = "history_done"
                    say({"event": "history_complete", "counts": self.counts})
                    self.imu_sent = True
                    self.imu_sent_at = time.time()
                    self.listen_deadline = time.time() + LISTEN_AFTER_6A_S
                    transmit(self, 0x6A, b"\x01", "6a01")

    def peripheral_didUpdateValueForCharacteristic_error_(self, peripheral, characteristic, error):
        uuid = str(characteristic.UUID().UUIDString()).upper()
        value = bytes(characteristic.value() or b"")
        if error is not None:
            say({"event": "rx_error", "uuid": uuid[:8], "error": err_text(error)})
            return
        if uuid.endswith("2A37") or not value.startswith(b"\xaa"):
            self.note_frame(uuid, value)
            return
        for frame in self.take_frames(uuid, value):
            self.note_frame(uuid, frame)

    def tick_(self, _timer):
        if self.finished:
            return
        now = time.time()

        # History wait: complete, stall, or timeout.
        if self.phase == "history" and not self.imu_sent and self.tx is not None:
            idle = None
            if self.last_history_rx_at is not None:
                idle = now - self.last_history_rx_at
            waited = now - (self.history_started_at or now)
            if idle is not None and idle >= HISTORY_STALL_S:
                say({
                    "event": "history_stall",
                    "idle_s": round(idle, 3),
                    "waited_s": round(waited, 3),
                    "counts": self.counts,
                })
                self.stalled = True
                self.aborted = True
                self.phase = "abort"
                transmit(self, 0x14, b"\x00", "1400")
            elif waited >= HISTORY_WAIT_S:
                say({
                    "event": "abort_history",
                    "waited_s": round(waited, 3),
                    "counts": self.counts,
                })
                self.aborted = True
                self.phase = "abort"
                transmit(self, 0x14, b"\x00", "1400")

        # After first 6A listen window: optional 69/00 then second 6A, or finish.
        if self.phase in ("imu", "followup_6a") and self.listen_deadline is not None:
            if now >= self.listen_deadline:
                if self.phase == "imu" and not self.followup_69_done:
                    if not self.six_a_replies:
                        # Wait a bit more for the type-24 if it has not arrived.
                        self.listen_deadline = now + 5.0
                        return
                    if self.maybe_followup_69():
                        return
                self.finish_(None)

    def finish_(self, _timer):
        if self.finished:
            return
        self.finished = True
        gaps = []
        for i in range(1, len(self.compact)):
            gaps.append(self.compact[i] - self.compact[i - 1])
        say({
            "event": "finish",
            "phase": self.phase,
            "counts": self.counts,
            "compact": len(self.compact),
            "compact_times": self.compact[:20],
            "compact_gaps_head": gaps[:20],
            "hr_n": len(self.hr),
            "hr_last": self.hr[-1] if self.hr else None,
            "history_done": self.history_done,
            "aborted": self.aborted,
            "stalled": self.stalled,
            "saw_2b": self.saw_2b,
            "followup_69_done": self.followup_69_done,
            "six_a_replies": self.six_a_replies,
        })
        if self.central is not None and self.peripheral is not None:
            self.central.cancelPeripheralConnection_(self.peripheral)
        AppHelper.stopEventLoop()


delegate = Delegate.alloc().init()
delegate.central = CBCentralManager.alloc().initWithDelegate_queue_(delegate, None)
# Hard ceiling: history wait + two 20s listens + margins.
NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
    0.5, delegate, "tick:", None, True
)
NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
    HISTORY_WAIT_S + LISTEN_AFTER_6A_S * 2 + 90.0, delegate, "finish:", None, False
)
AppHelper.runConsoleEventLoop()
OUT.close()
