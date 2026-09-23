import Foundation

/// Metadata carried by every WHOOP 4 R10 record (packet `0x2B`, record `0x0A`)
/// beyond the 100-sample accel/gyro blocks decoded by `AtriaR10MotionDecoder`.
///
/// Layout reverse-engineered on 2026-09-23 from Mac CoreBluetooth captures
/// (docs/WHOOP4_PROTOCOL_FINDINGS.md, "R10 beyond accel/gyro", "R10 float block
/// and temperatures"). Offsets are relative to the validated inner payload
/// (payload[0] == 0x2B, payload[1] == 0x0A). Fields marked PROVISIONAL are
/// n=1 inferences and must not be surfaced as absolute truth.
struct AtriaWhoop4R10Record: Equatable, Sendable {
    /// u16le frame counter; +1 per R10 frame, shared with the paired R11 frame.
    let frameCounter: UInt16
    /// u32le device second.
    let deviceSecond: UInt32
    /// u16le 32.768 kHz sub-second tick (15-bit). Frame time = second + tick/32768.
    let subsecondTicks: UInt16
    /// Heart rate (bpm) as reported in the frame.
    let heartRate: Int
    /// Beat-to-beat intervals in milliseconds (count byte + u16le each). Verified
    /// against the strap's own bpm field and against 2A37 RR (raw × 1.024).
    let rrIntervalsMilliseconds: [Int]
    /// Firmware motion-intensity scalar (g-like). Exact formula unresolved.
    let motionIntensity: Double
    /// Firmware-calibrated mean acceleration of this frame (gravity vector, g).
    let calibratedGravity: AtriaR10MotionFrame.Vector3
    /// Cumulative on-strap step counter (u16le, wraps). Keeps counting across
    /// BLE disconnects; counts arm gestures too, so it is an input, not truth.
    let firmwareStepCounter: UInt16
    /// PROVISIONAL skin/device temperature, u16le, decidegrees Celsius inferred.
    let skinTemperatureRaw: UInt16
    /// PROVISIONAL battery temperature, u16le, decidegrees Celsius inferred.
    let batteryTemperatureRaw: UInt16
    /// Status byte 2; bit 1 = charging (both edges observed).
    let statusFlags: UInt8
    /// Wear/contact bytes 13 and 14 (128/84 worn, 0/128 off-wrist observed).
    let wearContactPrimary: UInt8
    let wearContactSecondary: UInt8
    /// PROVISIONAL capacitive wear-sense channels (u16le @74/76/78/80).
    let capacitiveSense: [UInt16]

    static let packetType: UInt8 = 0x2B
    static let recordType: UInt8 = 0x0A
    static let minimumPayloadBytes = 1_920
    static let subsecondTicksPerSecond = 32_768.0
    /// Measured frame period: 100 samples per frame → IMU output data rate.
    static let framePeriodSeconds = 0.96143
    static var imuSampleRateHz: Double { 100.0 / framePeriodSeconds }

    var deviceTime: Double {
        Double(deviceSecond) + Double(subsecondTicks) / Self.subsecondTicksPerSecond
    }
    var isCharging: Bool { statusFlags & 0x02 != 0 }
    var skinTemperatureCelsiusProvisional: Double { Double(skinTemperatureRaw) / 10 }
    var batteryTemperatureCelsiusProvisional: Double { Double(batteryTemperatureRaw) / 10 }

    static func decode(payload: [UInt8]) -> AtriaWhoop4R10Record? {
        guard payload.count >= minimumPayloadBytes,
              payload[0] == packetType,
              payload[1] == recordType else { return nil }
        let rrCount = Int(payload[18])
        let rr: [Int] = rrCount <= 4
            ? (0..<rrCount).map { Int(u16(payload, 19 + 2 * $0)) }
            : []
        return AtriaWhoop4R10Record(
            frameCounter: u16(payload, 3),
            deviceSecond: u32(payload, 7),
            subsecondTicks: u16(payload, 11),
            heartRate: Int(payload[17]),
            rrIntervalsMilliseconds: rr,
            motionIntensity: Double(f32(payload, 42)),
            calibratedGravity: AtriaR10MotionFrame.Vector3(
                x: Double(f32(payload, 46)),
                y: Double(f32(payload, 50)),
                z: Double(f32(payload, 54))
            ),
            firmwareStepCounter: u16(payload, 1_293),
            skinTemperatureRaw: u16(payload, 1_917),
            batteryTemperatureRaw: u16(payload, 15),
            statusFlags: payload[2],
            wearContactPrimary: payload[13],
            wearContactSecondary: payload[14],
            capacitiveSense: [74, 76, 78, 80].map { u16(payload, $0) }
        )
    }

    /// Difference between two cumulative firmware step counters (u16 wrap-safe).
    static func firmwareStepDelta(from start: UInt16, to end: UInt16) -> Int {
        Int(end &- start)
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func f32(_ b: [UInt8], _ o: Int) -> Float {
        Float(bitPattern: u32(b, o))
    }
}

/// WHOOP 4 R11 record (packet `0x2B`, record `0x0B`): raw multi-channel PPG.
/// Four slots at 13 + 425·k, each a 25-byte header (header[1] = samples per
/// channel, 0 = empty) followed by two channels of int32le samples (signed
/// 20-bit ADC), ~52 Hz. Headers carry live AGC/drive settings, so levels are
/// only comparable within one header value. Verified: every active channel's
/// dominant frequency equals the heart rate (n=1, 2026-09-23).
struct AtriaWhoop4R11PPGRecord: Equatable, Sendable {
    struct Slot: Equatable, Sendable {
        let index: Int
        let header: [UInt8]
        let channels: [[Int32]]
        var isActive: Bool { !channels.isEmpty }
    }

    let frameCounter: UInt16
    let deviceSecond: UInt32
    let slots: [Slot]

    static let recordType: UInt8 = 0x0B
    static let slotOrigin = 13
    static let slotPitch = 425
    static let slotHeaderBytes = 25
    static let slotCount = 4

    static func decode(payload: [UInt8]) -> AtriaWhoop4R11PPGRecord? {
        guard payload.count >= slotOrigin + slotPitch * slotCount,
              payload[0] == AtriaWhoop4R10Record.packetType,
              payload[1] == recordType else { return nil }
        var slots: [Slot] = []
        for k in 0..<slotCount {
            let headerStart = slotOrigin + slotPitch * k
            let header = Array(payload[headerStart..<(headerStart + slotHeaderBytes)])
            let samples = Int(header[1])
            var channels: [[Int32]] = []
            if samples > 0, samples * 8 <= slotPitch - slotHeaderBytes {
                let base = headerStart + slotHeaderBytes
                for c in 0..<2 {
                    let start = base + 4 * samples * c
                    channels.append((0..<samples).map { i in
                        let o = start + 4 * i
                        return Int32(bitPattern: UInt32(payload[o]) | (UInt32(payload[o + 1]) << 8)
                            | (UInt32(payload[o + 2]) << 16) | (UInt32(payload[o + 3]) << 24))
                    })
                }
            }
            slots.append(Slot(index: k, header: header, channels: channels))
        }
        return AtriaWhoop4R11PPGRecord(
            frameCounter: UInt16(payload[3]) | (UInt16(payload[4]) << 8),
            deviceSecond: UInt32(payload[7]) | (UInt32(payload[8]) << 8)
                | (UInt32(payload[9]) << 16) | (UInt32(payload[10]) << 24),
            slots: slots
        )
    }
}
