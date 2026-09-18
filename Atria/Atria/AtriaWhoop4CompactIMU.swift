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
/// Ten samples are one 100 Hz slice (0.1 s). Ten packets reconstruct the same
/// 100 Hz second the R10 pipeline already scores. Stretching one packet across
/// a whole second (device 2026-09-17 117) put a 1.23 Hz stroll at ~0.12 Hz.
/// This is not the heuristic `AtriaIMUDecoder` research path.
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

/// Concatenates compact 100 Hz 10-sample slices into R10 seconds. Lock-screen
/// CoreBluetooth often delivers those slices in a burst (device 2026-09-17:
/// 8.5 ms interarrival on 118, 105 steps, 0 gyro). Emitting every slice as
/// soon as 100 samples exist time-compresses a 1.14 Hz stroll out of band.
/// Keep native slices, and admit only about one assembled second per wall
/// second so cadence stays physical.
final class AtriaWhoop4CompactIMUAssembler: @unchecked Sendable {
    /// Live 0x33 on this strap often arrives as one 10-sample packet per
    /// wall second (~10 Hz), not ten 100 Hz slices. Concatenating ten of
    /// those into one R10 second time-compresses gait out of band.
    static let tenHertzPacketMinInterval: TimeInterval = 0.65
    static let tenHertzPacketMaxInterval: TimeInterval = 2.45

    private let lock = NSLock()
    private var outputAccel: [AtriaR10MotionFrame.Vector3] = []
    private var outputGyro: [AtriaR10MotionFrame.Vector3] = []
    private var lastPacketAt: Date?
    private var lastEmittedTimestamp: UInt32 = 0
    private var streamStartedAt: Date?
    private var admittedSampleCount = 0
    private var consecutiveTenHertzIntervals = 0
    private var lastPacketInterval: TimeInterval?

    func push(_ packet: AtriaWhoop4CompactIMUDecoder.Packet,
              receivedAt: Date) -> [AtriaR10MotionFrame] {
        lock.lock()
        defer { lock.unlock() }
        let sampleCount = min(packet.acceleration.count, packet.rotationRate.count)
        guard sampleCount > 0 else { return [] }

        if let previousPacketAt = lastPacketAt {
            let interval = receivedAt.timeIntervalSince(previousPacketAt)
            if interval > 2.5 {
                let lastWasHundredHertzBurst = (lastPacketInterval ?? .infinity) < 0.25
                outputAccel.removeAll(keepingCapacity: true)
                outputGyro.removeAll(keepingCapacity: true)
                lastPacketAt = receivedAt
                lastPacketInterval = interval
                streamStartedAt = nil
                admittedSampleCount = 0
                consecutiveTenHertzIntervals = 0
                if lastEmittedTimestamp > 0 {
                    lastEmittedTimestamp &+= 2
                }
                if !lastWasHundredHertzBurst, sampleCount <= 20 {
                    let needed = AtriaR10MotionDecoder.sampleCount
                    return [makeFrame(
                        acceleration: Self.upsample(
                            Array(packet.acceleration.prefix(sampleCount)),
                            to: needed
                        ),
                        rotationRate: Self.upsample(
                            Array(packet.rotationRate.prefix(sampleCount)),
                            to: needed
                        ),
                        packetTimestamp: packet.deviceTimestamp
                    )]
                }
            } else if interval >= Self.tenHertzPacketMinInterval,
                      interval <= Self.tenHertzPacketMaxInterval {
                consecutiveTenHertzIntervals += 1
                lastPacketInterval = interval
                if consecutiveTenHertzIntervals >= 2, sampleCount <= 20 {
                    outputAccel.removeAll(keepingCapacity: true)
                    outputGyro.removeAll(keepingCapacity: true)
                    admittedSampleCount = 0
                    streamStartedAt = receivedAt
                    lastPacketAt = receivedAt
                    let needed = AtriaR10MotionDecoder.sampleCount
                    return [makeFrame(
                        acceleration: Self.upsample(
                            Array(packet.acceleration.prefix(sampleCount)),
                            to: needed
                        ),
                        rotationRate: Self.upsample(
                            Array(packet.rotationRate.prefix(sampleCount)),
                            to: needed
                        ),
                        packetTimestamp: packet.deviceTimestamp
                    )]
                }
            } else {
                consecutiveTenHertzIntervals = 0
                lastPacketInterval = interval
            }
        }

        let take = min(sampleCount, remainingSampleBudget(receivedAt: receivedAt))
        if take > 0 {
            outputAccel.append(contentsOf: packet.acceleration.prefix(take))
            outputGyro.append(contentsOf: packet.rotationRate.prefix(take))
            admittedSampleCount += take
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
        lastEmittedTimestamp = 0
        streamStartedAt = nil
        admittedSampleCount = 0
        consecutiveTenHertzIntervals = 0
        lastPacketInterval = nil
    }

    /// One assembled R10 second per wall-clock second, plus 1.05 s slack so a
    /// coalesced 10-packet burst can still complete the current second.
    private func remainingSampleBudget(receivedAt: Date) -> Int {
        if streamStartedAt == nil {
            streamStartedAt = receivedAt
        }
        let elapsed = max(0, receivedAt.timeIntervalSince(streamStartedAt ?? receivedAt))
        let budget = Int((elapsed + 1.05) * Double(AtriaR10MotionDecoder.sampleCount))
        return max(0, budget - admittedSampleCount)
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

    /// Stretch a native 10 Hz packet onto the 100-sample R10 second the
    /// gyro cadence scorer already knows. Holds gait frequency; does not
    /// invent extra swings.
    static func upsample(
        _ samples: [AtriaR10MotionFrame.Vector3],
        to count: Int
    ) -> [AtriaR10MotionFrame.Vector3] {
        guard count > 0 else { return [] }
        guard samples.count >= 2, count != samples.count else {
            if samples.count == count { return samples }
            guard let only = samples.first else { return [] }
            return Array(repeating: only, count: count)
        }
        var output: [AtriaR10MotionFrame.Vector3] = []
        output.reserveCapacity(count)
        let lastIndex = samples.count - 1
        let span = Double(count - 1)
        for i in 0..<count {
            let position = Double(i) * Double(lastIndex) / span
            let left = min(Int(position), lastIndex)
            let right = min(left + 1, lastIndex)
            let fraction = position - Double(left)
            let a = samples[left]
            let b = samples[right]
            output.append(.init(
                x: a.x + (b.x - a.x) * fraction,
                y: a.y + (b.y - a.y) * fraction,
                z: a.z + (b.z - a.z) * fraction
            ))
        }
        return output
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
    static let lastAssembledSecondAtKey = "atria.compactIMU.lastAssembledSecondAt"
    static let lastPacketAtKey = "atria.compactIMU.lastPacketAt"
    static let samplesKey = "atria.compactIMU.lastRotationSamples"
    static let lastSecondSkippedKey = "atria.compactIMU.lastSecondSkippedSitting"
    static let lastScoredMeanKey = "atria.compactIMU.lastScoredMeanDps"
    static let skippedSittingCountKey = "atria.compactIMU.skippedSittingSeconds"
    static let scoredSecondsCountKey = "atria.compactIMU.scoredSeconds"
    static let lastGyroCsvKey = "atria.compactIMU.lastRotationCsv"
    static let lastInterarrivalMsKey = "atria.compactIMU.lastInterarrivalMs"
    static let lastDeviceTimestampKey = "atria.compactIMU.lastDeviceTimestamp"
    static let lastEmitCountKey = "atria.compactIMU.lastEmitCount"

    private static let lock = NSLock()
    private static var lastWriteAt: Date?
    private static var lastAssembledSecondAtMemory: Date?
    private static var lastPacketAtMemory: Date?
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
    /// Compact 1 g-still accel plus this gyro mean is phone-in-hand at a
    /// desk. A slower walk can sit in the 40–80 band with gravity-looking
    /// accel, so still-accel must not skip those seconds.
    static let deskHoldGyroSkipMeanCeilingDps = 40.0
    /// Isolated ≤8 MB JSONL can retire during typing. Isolated 24–48 MB
    /// files also may, once those small shards are gone:
    /// `shouldIncludeLargeIdleChunk` keeps a 33 MB parse off the queue while
    /// any isolated ≤8 MB remains. A walk (≥80 dps) stays on the small cap
    /// and `isSafeForOneChunkRetention` refuses the pass entirely.
    static let largeArchiveIOMeanCeilingDps = 8.0
    static let sittingIdleSmallChunkBytes: UInt64 = 8 * 1024 * 1024
    static let sittingIdleLargeChunkBytes: UInt64 = 48 * 1024 * 1024

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

    static func notePacket(deviceTimestamp: UInt32,
                           emitCount: Int,
                           rotationRate: [AtriaR10MotionFrame.Vector3],
                           receivedAt: Date = Date()) {
        lock.lock()
        let previous = lastPacketAtMemory
        lastPacketAtMemory = receivedAt
        lock.unlock()
        let defaults = UserDefaults.standard
        defaults.set(receivedAt.timeIntervalSince1970, forKey: lastPacketAtKey)
        defaults.set(Int(deviceTimestamp), forKey: lastDeviceTimestampKey)
        defaults.set(emitCount, forKey: lastEmitCountKey)
        defaults.set(
            rotationRate.map { String(format: "%.1f", $0.magnitude) }.joined(separator: ","),
            forKey: lastGyroCsvKey
        )
        if let previous {
            defaults.set(
                receivedAt.timeIntervalSince(previous) * 1000,
                forKey: lastInterarrivalMsKey
            )
        }
    }

    /// Assembled compact seconds, not native packets. A 175 dps flick in
    /// one packet must not look like a scored walk second.
    static func noteCompactGyroSecond(
        skippedSitting: Bool,
        meanDps: Double,
        now: Date = Date()
    ) {
        lock.lock()
        lastAssembledSecondAtMemory = now
        lock.unlock()
        let defaults = UserDefaults.standard
        defaults.set(skippedSitting, forKey: lastSecondSkippedKey)
        defaults.set(now.timeIntervalSince1970, forKey: lastAssembledSecondAtKey)
        defaults.set(now.timeIntervalSince1970, forKey: atKey)
        if skippedSitting {
            defaults.set(
                defaults.integer(forKey: skippedSittingCountKey) + 1,
                forKey: skippedSittingCountKey
            )
        } else {
            defaults.set(meanDps, forKey: lastScoredMeanKey)
            defaults.set(
                defaults.integer(forKey: scoredSecondsCountKey) + 1,
                forKey: scoredSecondsCountKey
            )
        }
    }

    /// Foreground overdue retention may run one ≤8 MB chunk only while the
    /// live compact IMU says the wrist is sitting. A walk (≥12 dps gate)
    /// must not compete with archive I/O.
    static func resetDiagnosticsForTests() {
        lock.lock()
        lastWriteAt = nil
        lastAssembledSecondAtMemory = nil
        lastPacketAtMemory = nil
        lastMean = 0
        lastMax = 0
        rotationPeaks.removeAll()
        lock.unlock()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: meanKey)
        defaults.removeObject(forKey: maxKey)
        defaults.removeObject(forKey: peak60Key)
        defaults.removeObject(forKey: atKey)
        defaults.removeObject(forKey: lastAssembledSecondAtKey)
        defaults.removeObject(forKey: lastPacketAtKey)
        defaults.removeObject(forKey: samplesKey)
        defaults.removeObject(forKey: lastSecondSkippedKey)
        defaults.removeObject(forKey: lastScoredMeanKey)
        defaults.removeObject(forKey: skippedSittingCountKey)
        defaults.removeObject(forKey: scoredSecondsCountKey)
        defaults.removeObject(forKey: lastGyroCsvKey)
        defaults.removeObject(forKey: lastInterarrivalMsKey)
        defaults.removeObject(forKey: lastDeviceTimestampKey)
        defaults.removeObject(forKey: lastEmitCountKey)
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

    /// In-process assembled-second clock only. UserDefaults is for pull;
    /// a previous process's timestamp must not 6A/51 a healthy new stream.
    static func lastAssembledSecondAt() -> Date? {
        lock.lock()
        let memory = lastAssembledSecondAtMemory
        lock.unlock()
        return memory
    }

    /// Native 0x33 packet clock. Sitting skip leaves assembled-seconds stale
    /// while type-33 is still flowing (device 2026-09-18: assembled 2437s,
    /// last notify type 33).
    static func lastPacketAt() -> Date? {
        lock.lock()
        let memory = lastPacketAtMemory
        lock.unlock()
        return memory
    }

    static func lastFreshMeanDps(
        now: Date = Date(),
        maxAge: TimeInterval = sittingMaxAge
    ) -> Double? {
        lock.lock()
        let memoryWriteAt = lastWriteAt
        let memoryMean = lastMean
        lock.unlock()
        if let memoryWriteAt, now.timeIntervalSince(memoryWriteAt) <= maxAge {
            return memoryMean
        }
        let defaults = UserDefaults.standard
        let at = defaults.double(forKey: atKey)
        guard at > 0, now.timeIntervalSince1970 - at <= maxAge else {
            return nil
        }
        return defaults.double(forKey: meanKey)
    }

    static func sittingIdleChunkByteCap(now: Date = Date()) -> UInt64 {
        guard let mean = lastFreshMeanDps(now: now) else {
            return sittingIdleLargeChunkBytes
        }
        guard mean < archiveIOMeanCeilingDps else {
            return sittingIdleSmallChunkBytes
        }
        return sittingIdleLargeChunkBytes
    }

    /// Isolated 24–48 MB JSONL may run while compact IMU is under the walk
    /// gate. Lock and Today share this so leftover 33 MB shards keep draining.
    static func shouldUseSittingIdleRetentionLease(now: Date = Date()) -> Bool {
        sittingIdleChunkByteCap(now: now) > sittingIdleSmallChunkBytes
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
