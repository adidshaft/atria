import Foundation

/// Fixed-layout decoder for the live WHOOP 4 compact IMU packet (`0x33`).
///
/// Physical stream-5 frames on 2026-09-15 were 152-byte Harvard packets whose
/// inner payload is:
///   type `0x33` | 3-byte flags | u32le device time | 12-byte reserved |
///   u16le accelCount | u16le gyroCount |
///   planar int16 LE accel (X block, Y block, Z block) |
///   planar int16 LE gyro (X, Y, Z)
///
/// Ten samples at ~10 Hz reconstruct the same 100 Hz second the R10 pipeline
/// already scores. This is not the heuristic `AtriaIMUDecoder` research path.
enum AtriaWhoop4CompactIMUDecoder {
    static let packetType: UInt8 = AtriaBLEManager.Packet.imu
    static let headerBytes = 24
    static let accelerationScale = AtriaR10MotionDecoder.accelerationScale
    static let gyroscopeScale = AtriaR10MotionDecoder.gyroscopeScale

    struct Packet: Equatable, Sendable {
        let deviceTimestamp: UInt32
        let acceleration: [AtriaR10MotionFrame.Vector3]
        let rotationRate: [AtriaR10MotionFrame.Vector3]
    }

    static func decode(frame: Data) -> Packet? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 8, bytes[0] == 0xAA else { return nil }
        let declaredLength = Int(bytes[1]) | (Int(bytes[2]) << 8)
        guard bytes[3] == crc8([bytes[1], bytes[2]]),
              declaredLength >= headerBytes + 1,
              declaredLength + 4 <= bytes.count else { return nil }
        return decode(payload: Array(bytes[4..<declaredLength]))
    }

    static func decode(payload: [UInt8]) -> Packet? {
        guard payload.count >= headerBytes,
              payload[0] == packetType else { return nil }
        let accelCount = Int(u16LE(payload, 20))
        let gyroCount = Int(u16LE(payload, 22))
        guard accelCount > 0,
              gyroCount > 0,
              accelCount <= AtriaR10MotionDecoder.sampleCount,
              gyroCount <= AtriaR10MotionDecoder.sampleCount else { return nil }
        let accelBytes = accelCount * 6
        let gyroBytes = gyroCount * 6
        guard payload.count >= headerBytes + accelBytes + gyroBytes else { return nil }
        let acceleration = planarVectors(
            in: payload,
            start: headerBytes,
            count: accelCount,
            scale: accelerationScale
        )
        let rotation = planarVectors(
            in: payload,
            start: headerBytes + accelBytes,
            count: gyroCount,
            scale: gyroscopeScale
        )
        guard acceleration.count == accelCount,
              rotation.count == gyroCount else { return nil }
        return Packet(
            deviceTimestamp: u32LE(payload, 4),
            acceleration: acceleration,
            rotationRate: rotation
        )
    }

    private static func planarVectors(
        in payload: [UInt8],
        start: Int,
        count: Int,
        scale: Double
    ) -> [AtriaR10MotionFrame.Vector3] {
        let axisStride = count * 2
        guard payload.count >= start + axisStride * 3 else { return [] }
        var samples: [AtriaR10MotionFrame.Vector3] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            let byteOffset = index * 2
            samples.append(AtriaR10MotionFrame.Vector3(
                x: Double(i16LE(payload, start + byteOffset)) * scale,
                y: Double(i16LE(payload, start + axisStride + byteOffset)) * scale,
                z: Double(i16LE(payload, start + axisStride * 2 + byteOffset)) * scale
            ))
        }
        return samples
    }

    private static func i16LE(_ bytes: [UInt8], _ offset: Int) -> Int16 {
        Int16(bitPattern: UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
    }

    private static func u16LE(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func u32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

/// Batches compact IMU packets onto a 100 Hz R10 second so gyro-cadence
/// frequencies stay physically honest. Same-callback bursts keep the native
/// 10-sample slices; paced live packets are interpolated across wall time.
final class AtriaWhoop4CompactIMUAssembler: @unchecked Sendable {
    private let lock = NSLock()
    private var outputAccel: [AtriaR10MotionFrame.Vector3] = []
    private var outputGyro: [AtriaR10MotionFrame.Vector3] = []
    private var lastPacketAt: Date?
    private var lastGridTime: Date?
    private var lastEmittedTimestamp: UInt32 = 0

    func push(_ packet: AtriaWhoop4CompactIMUDecoder.Packet,
              receivedAt: Date) -> [AtriaR10MotionFrame] {
        lock.lock()
        defer { lock.unlock() }
        let sampleCount = min(packet.acceleration.count, packet.rotationRate.count)
        guard sampleCount > 0 else { return [] }

        if let previousPacketAt = lastPacketAt,
           receivedAt.timeIntervalSince(previousPacketAt) > 2.5 {
            outputAccel.removeAll(keepingCapacity: true)
            outputGyro.removeAll(keepingCapacity: true)
            lastGridTime = nil
            lastPacketAt = nil
            if lastEmittedTimestamp > 0 {
                lastEmittedTimestamp &+= 2
            }
        }

        let intervalStart = lastPacketAt
            ?? receivedAt.addingTimeInterval(-Double(sampleCount) / 100.0)
        let duration = max(1e-4, receivedAt.timeIntervalSince(intervalStart))
        if duration < 0.015 {
            outputAccel.append(contentsOf: packet.acceleration)
            outputGyro.append(contentsOf: packet.rotationRate)
            let nativeEnd = (lastGridTime ?? receivedAt)
                .addingTimeInterval(Double(sampleCount) / 100.0)
            lastGridTime = max(nativeEnd, receivedAt)
        } else {
            var cursor = lastGridTime ?? intervalStart
            if cursor < intervalStart { cursor = intervalStart }
            var tick = cursor.addingTimeInterval(0.01)
            while tick <= receivedAt.addingTimeInterval(1e-9) {
                let u = min(
                    1,
                    max(0, tick.timeIntervalSince(intervalStart) / duration)
                )
                outputAccel.append(Self.interpolated(packet.acceleration, u: u))
                outputGyro.append(Self.interpolated(packet.rotationRate, u: u))
                lastGridTime = tick
                tick = tick.addingTimeInterval(0.01)
            }
        }
        lastPacketAt = receivedAt

        var frames: [AtriaR10MotionFrame] = []
        let needed = AtriaR10MotionDecoder.sampleCount
        while outputAccel.count >= needed, outputGyro.count >= needed {
            frames.append(makeFrame(
                acceleration: Array(outputAccel.prefix(needed)),
                rotationRate: Array(outputGyro.prefix(needed)),
                packetTimestamp: packet.deviceTimestamp
            ))
            outputAccel.removeFirst(needed)
            outputGyro.removeFirst(needed)
        }
        return frames
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        outputAccel.removeAll(keepingCapacity: true)
        outputGyro.removeAll(keepingCapacity: true)
        lastPacketAt = nil
        lastGridTime = nil
        lastEmittedTimestamp = 0
    }

    private func makeFrame(
        acceleration: [AtriaR10MotionFrame.Vector3],
        rotationRate: [AtriaR10MotionFrame.Vector3],
        packetTimestamp: UInt32
    ) -> AtriaR10MotionFrame {
        let timestamp: UInt32
        if lastEmittedTimestamp == 0 {
            timestamp = packetTimestamp == 0 ? 1 : packetTimestamp
        } else {
            timestamp = lastEmittedTimestamp &+ 1
        }
        lastEmittedTimestamp = timestamp
        return AtriaR10MotionFrame(
            deviceTimestamp: timestamp,
            heartRate: 0,
            acceleration: acceleration,
            rotationRate: rotationRate,
            deviceClock: .compactAssembled
        )
    }

    private static func interpolated(
        _ samples: [AtriaR10MotionFrame.Vector3],
        u: Double
    ) -> AtriaR10MotionFrame.Vector3 {
        guard let first = samples.first else {
            return AtriaR10MotionFrame.Vector3(x: 0, y: 0, z: 0)
        }
        guard samples.count >= 2 else { return first }
        let scaled = min(1, max(0, u)) * Double(samples.count - 1)
        let index = min(samples.count - 2, max(0, Int(scaled.rounded(.down))))
        let fraction = min(1, max(0, scaled - Double(index)))
        let a = samples[index]
        let b = samples[index + 1]
        return AtriaR10MotionFrame.Vector3(
            x: a.x + (b.x - a.x) * fraction,
            y: a.y + (b.y - a.y) * fraction,
            z: a.z + (b.z - a.z) * fraction
        )
    }
}

/// Pull-visible wrist rotation from live compact `0x33` packets. Sitting is
/// ~1 dps; the compact walk gate is 12. A real walk that does not move Today
/// can be diagnosed from these keys without decoding notify hex.
enum AtriaCompactIMULiveDiagnostics {
    static let meanKey = "atria.compactIMU.lastRotationMeanDps"
    static let maxKey = "atria.compactIMU.lastRotationMaxDps"
    static let peak60Key = "atria.compactIMU.lastRotationPeak60Dps"
    static let atKey = "atria.compactIMU.lastRotationAt"
    static let samplesKey = "atria.compactIMU.lastRotationSamples"

    private static let lock = NSLock()
    private static var lastWriteAt: Date?
    private static var lastMean = 0.0
    private static var lastMax = 0.0
    private static var rotationPeaks: [(at: Date, peak: Double)] = []
    private static let minimumWriteInterval: TimeInterval = 2
    static let sittingMeanCeilingDps = 2.0
    static let sittingMaxCeilingDps = 6.0
    static let sittingMaxAge: TimeInterval = 24
    /// Desk typing is ~10–40 dps mean with occasional flicks. A walk that
    /// should not compete with archive I/O is sustained ~80+ dps.
    static let archiveIOMeanCeilingDps = 80.0

    static func note(rotationRate: [AtriaR10MotionFrame.Vector3],
                     now: Date = Date(),
                     force: Bool = false) {
        guard !rotationRate.isEmpty else { return }
        var total = 0.0
        var peak = 0.0
        for vector in rotationRate {
            let magnitude = vector.magnitude
            total += magnitude
            if magnitude > peak { peak = magnitude }
        }
        let mean = total / Double(rotationRate.count)
        lock.lock()
        defer { lock.unlock() }
        if !force,
           let lastWriteAt,
           now.timeIntervalSince(lastWriteAt) < minimumWriteInterval {
            return
        }
        lastWriteAt = now
        lastMean = mean
        lastMax = peak
        rotationPeaks.append((now, peak))
        rotationPeaks.removeAll { now.timeIntervalSince($0.at) > 60 }
        let peak60 = rotationPeaks.map(\.peak).max() ?? peak
        let defaults = UserDefaults.standard
        defaults.set(mean, forKey: meanKey)
        defaults.set(peak, forKey: maxKey)
        defaults.set(peak60, forKey: peak60Key)
        defaults.set(now.timeIntervalSince1970, forKey: atKey)
        defaults.set(rotationRate.count, forKey: samplesKey)
    }

    /// Foreground overdue retention may run one ≤8 MB chunk only while the
    /// live compact IMU says the wrist is sitting. A walk (≥12 dps gate)
    /// must not compete with archive I/O.
    static func resetDiagnosticsForTests() {
        lock.lock()
        lastWriteAt = nil
        lastMean = 0
        lastMax = 0
        rotationPeaks.removeAll()
        lock.unlock()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: meanKey)
        defaults.removeObject(forKey: maxKey)
        defaults.removeObject(forKey: peak60Key)
        defaults.removeObject(forKey: atKey)
        defaults.removeObject(forKey: samplesKey)
    }

    static func isFreshSitting(
        now: Date = Date(),
        maxAge: TimeInterval = sittingMaxAge,
        meanCeiling: Double = sittingMeanCeilingDps,
        maxCeiling: Double = sittingMaxCeilingDps
    ) -> Bool {
        lock.lock()
        let memoryWriteAt = lastWriteAt
        let memoryMean = lastMean
        let memoryMax = lastMax
        lock.unlock()
        if let memoryWriteAt, now.timeIntervalSince(memoryWriteAt) <= maxAge {
            return memoryMean < meanCeiling && memoryMax < maxCeiling
        }
        let defaults = UserDefaults.standard
        let at = defaults.double(forKey: atKey)
        guard at > 0, now.timeIntervalSince1970 - at <= maxAge else {
            return false
        }
        return defaults.double(forKey: meanKey) < meanCeiling
            && defaults.double(forKey: maxKey) < maxCeiling
    }

    /// One-chunk overdue retention may run while the wrist is at a desk.
    /// `isFreshSitting` is too strict: a 28 dps typing mean and a 380 dps
    /// flick look like a walk. Stale IMU is also safe — nothing to fight.
    static func isSafeForOneChunkRetention(
        now: Date = Date(),
        maxAge: TimeInterval = sittingMaxAge,
        meanCeiling: Double = archiveIOMeanCeilingDps
    ) -> Bool {
        lock.lock()
        let memoryWriteAt = lastWriteAt
        let memoryMean = lastMean
        lock.unlock()
        if let memoryWriteAt, now.timeIntervalSince(memoryWriteAt) <= maxAge {
            return memoryMean < meanCeiling
        }
        let defaults = UserDefaults.standard
        let at = defaults.double(forKey: atKey)
        guard at > 0, now.timeIntervalSince1970 - at <= maxAge else {
            return true
        }
        return defaults.double(forKey: meanKey) < meanCeiling
    }
}
