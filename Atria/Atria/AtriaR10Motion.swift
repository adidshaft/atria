import Foundation

struct AtriaR10MotionFrame: Equatable, Sendable {
    struct Vector3: Equatable, Sendable {
        let x: Double
        let y: Double
        let z: Double

        var magnitude: Double { sqrt(x * x + y * y + z * z) }
    }

    let deviceTimestamp: UInt32
    let heartRate: Int
    let acceleration: [Vector3]
    let rotationRate: [Vector3]
}

/// Fixed-layout decoder for the WHOOP 4 R10 record carried by packet 0x2B.
/// Offsets are relative to the validated inner payload, whose first two bytes
/// are packet 0x2B and record type 0x0A.
enum AtriaR10MotionDecoder {
    static let packetType: UInt8 = 0x2B
    static let recordType: UInt8 = 0x0A
    static let sampleCount = 100
    static let accelerationScale = 1.0 / 4_096.0
    static let gyroscopeScale = 0.061_035_156_25

    private static let timestampOffset = 7
    private static let heartRateOffset = 17
    private static let accelerationOffsets = [85, 285, 485]
    private static let gyroscopeOffsets = [688, 888, 1_088]
    private static let minimumPayloadBytes = 1_288

    static func decode(frame: Data) -> AtriaR10MotionFrame? {
        guard let payload = validatedPayload(from: frame) else { return nil }
        return decode(payload: payload)
    }

    static func decode(payload: [UInt8]) -> AtriaR10MotionFrame? {
        guard payload.count >= minimumPayloadBytes,
              payload[0] == packetType,
              payload[1] == recordType else { return nil }

        let acceleration = vectors(in: payload,
                                   offsets: accelerationOffsets,
                                   scale: accelerationScale)
        let rotationRate = vectors(in: payload,
                                   offsets: gyroscopeOffsets,
                                   scale: gyroscopeScale)
        guard acceleration.count == sampleCount,
              rotationRate.count == sampleCount else { return nil }

        return AtriaR10MotionFrame(deviceTimestamp: u32LE(payload, timestampOffset),
                                   heartRate: Int(payload[heartRateOffset]),
                                   acceleration: acceleration,
                                   rotationRate: rotationRate)
    }

    private static func validatedPayload(from frame: Data) -> [UInt8]? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 9, bytes[0] == 0xAA else { return nil }
        let declaredLength = Int(bytes[1]) | (Int(bytes[2]) << 8)
        let totalLength = declaredLength + 4
        guard declaredLength >= 5,
              totalLength <= bytes.count,
              bytes[3] == crc8([bytes[1], bytes[2]]) else { return nil }
        let payload = Array(bytes[4..<declaredLength])
        let actualCRC = UInt32(bytes[declaredLength])
            | (UInt32(bytes[declaredLength + 1]) << 8)
            | (UInt32(bytes[declaredLength + 2]) << 16)
            | (UInt32(bytes[declaredLength + 3]) << 24)
        guard crc32(payload) == actualCRC else { return nil }
        return payload
    }

    private static func vectors(in payload: [UInt8],
                                offsets: [Int],
                                scale: Double) -> [AtriaR10MotionFrame.Vector3] {
        guard offsets.count == 3 else { return [] }
        var samples: [AtriaR10MotionFrame.Vector3] = []
        samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let byteOffset = index * 2
            samples.append(AtriaR10MotionFrame.Vector3(
                x: Double(i16LE(payload, offsets[0] + byteOffset)) * scale,
                y: Double(i16LE(payload, offsets[1] + byteOffset)) * scale,
                z: Double(i16LE(payload, offsets[2] + byteOffset)) * scale
            ))
        }
        return samples
    }

    private static func i16LE(_ bytes: [UInt8], _ offset: Int) -> Int16 {
        Int16(bitPattern: UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
    }

    private static func u32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

/// Analog Devices AN-2554-style wrist pedometer over a contiguous 100 Hz
/// acceleration-magnitude signal. These production constants are locally
/// calibrated against the retained manually counted 132-step control and its
/// adjacent/later zero-step stillness captures. The six-step regularity gate
/// still rejects short handling and typing bursts. The gain remains explicit.
enum AtriaStrapPedometer {
    static let sampleRateHz = 100
    static let filterLength = 8
    static let peakWindow = 29
    static let sensitivityG = 0.06
    static let thresholdOrder = 4
    static let confirmationSteps = 6
    static let maxToMinTimeoutSamples = 120
    static let referenceGain = 1.11

    /// Incremental form of the production detector. Its bounded filter,
    /// extrema, threshold, and gait-confirmation state belongs to one
    /// physically continuous motion segment and therefore survives arbitrary
    /// frame and scheduling boundaries.
    struct StreamingDetector {
        private let safeFilterLength: Int
        private let safePeakWindow: Int
        private let safeSensitivity: Double
        private let safeConfirmationSteps: Int
        private let halfWindow: Int

        private var filterWindow: [Double] = []
        private var filterSum = 0.0
        private var lowPassWindow: [Double] = []
        private var sampleCount = 0
        private var magnitudeMean = 0.0
        private var recentThresholds: [Double] = []
        private var dynamicThreshold: Double?
        private var possibleSteps = 0
        private var regularGait = false
        private var seekingMaximum = true
        private var currentMaximum = 0.0
        private var currentMaximumIndex = -1

        private(set) var rawSteps = 0

        init(filterLength: Int = AtriaStrapPedometer.filterLength,
             peakWindow: Int = AtriaStrapPedometer.peakWindow,
             sensitivityG: Double = AtriaStrapPedometer.sensitivityG,
             confirmationSteps: Int = AtriaStrapPedometer.confirmationSteps) {
            safeFilterLength = max(2, min(filterLength, 32))
            let clampedPeakWindow = max(9, min(peakWindow, 101))
            safePeakWindow = clampedPeakWindow.isMultiple(of: 2)
                ? clampedPeakWindow + 1
                : clampedPeakWindow
            safeSensitivity = max(0.02, min(sensitivityG, 0.30))
            safeConfirmationSteps = max(1, min(confirmationSteps, 20))
            halfWindow = safePeakWindow / 2
            filterWindow.reserveCapacity(safeFilterLength)
            lowPassWindow.reserveCapacity(safePeakWindow)
            recentThresholds.reserveCapacity(AtriaStrapPedometer.thresholdOrder)
        }

        mutating func ingest<S: Sequence>(_ magnitudes: S) where S.Element == Double {
            for magnitude in magnitudes {
                ingest(magnitude)
            }
        }

        mutating func reset() {
            filterWindow.removeAll(keepingCapacity: true)
            filterSum = 0
            lowPassWindow.removeAll(keepingCapacity: true)
            sampleCount = 0
            magnitudeMean = 0
            recentThresholds.removeAll(keepingCapacity: true)
            dynamicThreshold = nil
            possibleSteps = 0
            regularGait = false
            seekingMaximum = true
            currentMaximum = 0
            currentMaximumIndex = -1
            rawSteps = 0
        }

        /// Starts a new signal segment after exactly one missing R10 frame.
        ///
        /// A discontinuity must never carry filter samples, extrema, adaptive
        /// thresholds, or an incomplete confirmation sequence across its
        /// boundary. Once regular gait has already passed the six-step gate,
        /// however, forcing that same person to re-earn six more steps for one
        /// missing second creates a deterministic undercount. Retain only that
        /// established-gait bit; the new segment must derive its first extrema
        /// entirely from post-gap samples.
        mutating func resetAfterIsolatedMissingSecond() {
            let hadConfirmedRegularGait = regularGait
            reset()
            regularGait = hadConfirmedRegularGait
        }

        private mutating func ingest(_ magnitude: Double) {
            sampleCount += 1
            magnitudeMean += (magnitude - magnitudeMean) / Double(sampleCount)

            filterWindow.append(magnitude)
            filterSum += magnitude
            if filterWindow.count > safeFilterLength {
                filterSum -= filterWindow.removeFirst()
            }
            lowPassWindow.append(filterSum / Double(filterWindow.count))
            guard lowPassWindow.count >= safePeakWindow else { return }

            let center = lowPassWindow[halfWindow]
            var isMaximum = true
            var isMinimum = true
            for value in lowPassWindow {
                if value > center { isMaximum = false }
                if value < center { isMinimum = false }
                if !isMaximum && !isMinimum { break }
            }
            if isMaximum || isMinimum {
                processCandidate(index: sampleCount - halfWindow - 1,
                                 isMaximum: isMaximum,
                                 value: center)
            }
            lowPassWindow.removeFirst()
        }

        private mutating func processCandidate(index: Int,
                                               isMaximum: Bool,
                                               value: Double) {
            if seekingMaximum {
                guard isMaximum else { return }
                currentMaximum = value
                currentMaximumIndex = index
                seekingMaximum = false
                return
            }

            if isMaximum {
                if value > currentMaximum {
                    currentMaximum = value
                    currentMaximumIndex = index
                }
                return
            }
            if index - currentMaximumIndex > AtriaStrapPedometer.maxToMinTimeoutSamples {
                seekingMaximum = true
                possibleSteps = 0
                regularGait = false
                return
            }

            let threshold = dynamicThreshold ?? magnitudeMean
            let crossesThreshold = currentMaximum > threshold + safeSensitivity / 2
                && value < threshold - safeSensitivity / 2
            if crossesThreshold {
                if currentMaximum - value > safeSensitivity {
                    recentThresholds.append((currentMaximum + value) / 2)
                    if recentThresholds.count > AtriaStrapPedometer.thresholdOrder {
                        recentThresholds.removeFirst()
                    }
                    dynamicThreshold = recentThresholds.reduce(0, +)
                        / Double(recentThresholds.count)
                }
                possibleSteps += 1
                if regularGait {
                    rawSteps += 1
                } else if possibleSteps >= safeConfirmationSteps {
                    rawSteps += possibleSteps
                    regularGait = true
                }
            } else {
                possibleSteps = 0
                regularGait = false
            }
            seekingMaximum = true
        }
    }

    static func rawStepCount(magnitudes: [Double],
                             filterLength: Int = AtriaStrapPedometer.filterLength,
                             peakWindow: Int = AtriaStrapPedometer.peakWindow,
                             sensitivityG: Double = AtriaStrapPedometer.sensitivityG,
                             confirmationSteps: Int = AtriaStrapPedometer.confirmationSteps) -> Int {
        var detector = StreamingDetector(filterLength: filterLength,
                                         peakWindow: peakWindow,
                                         sensitivityG: sensitivityG,
                                         confirmationSteps: confirmationSteps)
        detector.ingest(magnitudes)
        return detector.rawSteps
    }
}

/// Keeps R10 decoding and step analysis off the BLE and main queues. Atria only
/// publishes when the displayed count changes, at most once per second.
final class AtriaR10MotionPipeline: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let steps: Int
        let rawSteps: Int
        let frames: Int
        let samples: Int
        let deviceTimestamp: UInt32
        let stillnessRatio: Double
        let movementIntensity: Double
        let activityBursts: Int
        let gravityValidatedFrames: Int
        let state: String
    }

    private let queue = DispatchQueue(label: "com.adidshaft.atria.r10-motion", qos: .utility)
    private let gain: Double
    private var detector = AtriaStrapPedometer.StreamingDetector()
    private var committedRawSteps = 0
    private var totalFrames = 0
    private var totalSamples = 0
    private var stillSamples = 0
    private var movementTotal = 0.0
    private var activityBursts = 0
    private var gravityValidatedFrames = 0
    private var seenTimestamps = Set<UInt32>()
    private var timestampOrder: [UInt32] = []
    private var lastAcceptedDeviceTimestamp: UInt32?
    private var lastAcceptedReceivedAt: Date?
    private var lastObservedRawSteps = 0
    private var lastPublishedSteps = -1
    private var lastSnapshotEvaluationAt: Date?

    init(sampleRateHz: Int = AtriaStrapPedometer.sampleRateHz,
         gain: Double = AtriaStrapPedometer.referenceGain) {
        // R10 framing fixes production input at 100 Hz. Retain this argument
        // for source compatibility with existing callers and test tooling.
        _ = sampleRateHz
        self.gain = max(0.5, min(gain, 2.0))
    }

    func ingest(_ frame: AtriaR10MotionFrame,
                receivedAt: Date,
                onUpdate: @escaping @Sendable (Snapshot) -> Void) {
        queue.async { [self] in
            guard accept(frame, receivedAt: receivedAt) else { return }
            let firstFrame = totalFrames == 1
            guard Self.shouldEvaluateSnapshot(firstFrame: firstFrame,
                                              lastEvaluatedAt: lastSnapshotEvaluationAt,
                                              receivedAt: receivedAt) else { return }
            lastSnapshotEvaluationAt = receivedAt
            let snapshot = makeSnapshot(deviceTimestamp: frame.deviceTimestamp)
            guard firstFrame || snapshot.steps != lastPublishedSteps else { return }
            lastPublishedSteps = snapshot.steps
            onUpdate(snapshot)
        }
    }

    static func shouldEvaluateSnapshot(firstFrame: Bool,
                                       lastEvaluatedAt: Date?,
                                       receivedAt: Date) -> Bool {
        if firstFrame { return true }
        guard let lastEvaluatedAt else { return true }
        return receivedAt.timeIntervalSince(lastEvaluatedAt) >= 1
    }

    func resetSynchronously() {
        queue.sync { [self] in
            detector.reset()
            committedRawSteps = 0
            totalFrames = 0
            totalSamples = 0
            stillSamples = 0
            movementTotal = 0
            activityBursts = 0
            gravityValidatedFrames = 0
            seenTimestamps.removeAll(keepingCapacity: true)
            timestampOrder.removeAll(keepingCapacity: true)
            lastAcceptedDeviceTimestamp = nil
            lastAcceptedReceivedAt = nil
            lastObservedRawSteps = 0
            lastPublishedSteps = -1
            lastSnapshotEvaluationAt = nil
        }
    }

    /// Restores the detector's durable prefix after process relaunch. A journal
    /// cannot reconstruct pre-relaunch filter/gait state without raw samples,
    /// so new frames continue monotonically from the last published raw total.
    func seedSynchronously(committedRawSteps restoredRawSteps: Int) -> (steps: Int, rawSteps: Int) {
        queue.sync { [self] in
            // Journal loading is asynchronous. If fresh R10 frames arrived
            // before restore completed, retain their continuous detector state
            // and add the durable prefix instead of losing post-launch motion.
            committedRawSteps += max(0, restoredRawSteps)
            let rawSteps = max(lastObservedRawSteps, committedRawSteps + detector.rawSteps)
            lastObservedRawSteps = rawSteps
            let steps = Int((Double(rawSteps) * gain).rounded())
            lastPublishedSteps = steps
            return (steps, rawSteps)
        }
    }

    func ingestSynchronouslyForTesting(_ frame: AtriaR10MotionFrame) -> Snapshot? {
        queue.sync { [self] in
            guard accept(frame, receivedAt: nil) else { return nil }
            return makeSnapshot(deviceTimestamp: frame.deviceTimestamp)
        }
    }

    private func accept(_ frame: AtriaR10MotionFrame, receivedAt: Date?) -> Bool {
        guard frame.acceleration.count == AtriaR10MotionDecoder.sampleCount else { return false }
        if frame.deviceTimestamp > 0 {
            guard seenTimestamps.insert(frame.deviceTimestamp).inserted else { return false }
            timestampOrder.append(frame.deviceTimestamp)
            if timestampOrder.count > 512 {
                seenTimestamps.remove(timestampOrder.removeFirst())
            }
        }

        // Each R10 frame contains one second of 100 Hz motion. Device time is
        // the authoritative continuity clock because iOS may deliver valid
        // background frames in a batch. An isolated one-frame hole may retain
        // only already-confirmed gait; filters, extrema, and incomplete gait
        // confirmation always restart. Longer gaps/reconnects still hard-reset
        // the entire segment. Wall time is only a fallback for the rare
        // firmware frame whose device timestamp is zero.
        enum Continuity {
            case continuous
            case isolatedMissingSecond
            case disconnected
        }
        let continuity: Continuity
        if frame.deviceTimestamp > 0, let previous = lastAcceptedDeviceTimestamp {
            switch frame.deviceTimestamp &- previous {
            case 1:
                continuity = .continuous
            case 2:
                continuity = .isolatedMissingSecond
            default:
                continuity = .disconnected
            }
        } else if frame.deviceTimestamp > 0 {
            continuity = .continuous
        } else if let receivedAt, let previous = lastAcceptedReceivedAt {
            continuity = receivedAt.timeIntervalSince(previous) <= 2.5
                ? .continuous
                : .disconnected
        } else {
            continuity = .continuous
        }
        switch continuity {
        case .continuous:
            break
        case .isolatedMissingSecond:
            finalizeCurrentMotionSegment(preservingConfirmedGait: true)
        case .disconnected:
            finalizeCurrentMotionSegment(preservingConfirmedGait: false)
        }
        if frame.deviceTimestamp > 0 {
            lastAcceptedDeviceTimestamp = frame.deviceTimestamp
        } else {
            lastAcceptedDeviceTimestamp = nil
        }
        if let receivedAt {
            lastAcceptedReceivedAt = receivedAt
        }

        totalFrames += 1
        totalSamples += frame.acceleration.count
        let magnitudes = frame.acceleration.map(\.magnitude)
        detector.ingest(magnitudes)
        var frameStillSamples = 0
        var frameMagnitudeTotal = 0.0
        for magnitude in magnitudes {
            let movement = abs(magnitude - 1)
            movementTotal += movement
            frameMagnitudeTotal += magnitude
            if movement <= 0.08 { frameStillSamples += 1 }
            if magnitude >= 1.35 { activityBursts += 1 }
        }
        stillSamples += frameStillSamples
        let frameMeanMagnitude = frameMagnitudeTotal / Double(max(1, magnitudes.count))
        let frameStillness = Double(frameStillSamples) / Double(max(1, magnitudes.count))
        if frameMeanMagnitude >= 0.85,
           frameMeanMagnitude <= 1.15,
           frameStillness >= 0.60 {
            gravityValidatedFrames += 1
        }
        return true
    }

    private func finalizeCurrentMotionSegment(preservingConfirmedGait: Bool = false) {
        committedRawSteps += detector.rawSteps
        if preservingConfirmedGait {
            detector.resetAfterIsolatedMissingSecond()
        } else {
            detector.reset()
        }
        lastObservedRawSteps = max(lastObservedRawSteps, committedRawSteps)
    }

    private func makeSnapshot(deviceTimestamp: UInt32) -> Snapshot {
        let rawSteps = max(lastObservedRawSteps, committedRawSteps + detector.rawSteps)
        lastObservedRawSteps = rawSteps
        return Snapshot(steps: Int((Double(rawSteps) * gain).rounded()),
                        rawSteps: rawSteps,
                        frames: totalFrames,
                        samples: totalSamples,
                        deviceTimestamp: deviceTimestamp,
                        stillnessRatio: Double(stillSamples) / Double(max(1, totalSamples)),
                        movementIntensity: movementTotal / Double(max(1, totalSamples)),
                        activityBursts: activityBursts,
                        gravityValidatedFrames: gravityValidatedFrames,
                        // The detector is fitted to the archived charger-on walk
                        // and stillness negatives. The four later charger-free
                        // walks contain no archived R10 frames, so calling this
                        // calibrated would overstate the evidence.
                        state: "r10_live_preliminary")
    }
}
