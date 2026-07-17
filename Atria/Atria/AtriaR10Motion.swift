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

    /// Validates framing and both CRCs, then reads only the embedded device
    /// second. Calibration tools use this fast path to discard unrelated rows
    /// before allocating 600 decoded vector components for each retained R10
    /// frame. A matching row is still fully decoded before it is scored.
    static func validatedDeviceTimestamp(frame: Data) -> UInt32? {
        guard let payload = validatedPayload(from: frame),
              payload.count >= minimumPayloadBytes,
              payload[0] == packetType,
              payload[1] == recordType else { return nil }
        return u32LE(payload, timestampOffset)
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
        private var isolatedGapCarrySamplesRemaining = 0
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
            isolatedGapCarrySamplesRemaining = 0
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
            isolatedGapCarrySamplesRemaining = hadConfirmedRegularGait
                ? AtriaStrapPedometer.sampleRateHz
                : 0
        }

        private mutating func ingest(_ magnitude: Double) {
            defer {
                if isolatedGapCarrySamplesRemaining > 0 {
                    isolatedGapCarrySamplesRemaining -= 1
                    if isolatedGapCarrySamplesRemaining == 0 {
                        regularGait = false
                    }
                }
            }
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
                isolatedGapCarrySamplesRemaining = 0
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
                    isolatedGapCarrySamplesRemaining = 0
                } else if possibleSteps >= safeConfirmationSteps {
                    rawSteps += possibleSteps
                    regularGait = true
                }
            } else {
                possibleSteps = 0
                regularGait = false
                isolatedGapCarrySamplesRemaining = 0
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

/// RESEARCH-ONLY gyroscope-cadence pedometer. Never feeds a production count.
///
/// Physical basis (2026-07-17 card session, exact counted truth): during
/// walking, the wrist's rotation-rate MAGNITUDE oscillates at the true step
/// rate, while acceleration magnitude and individual gyro axes oscillate at
/// the stride rate (half cadence — one arm swing per two steps). Every
/// accelerometer-peak detector in the production family therefore undercounts
/// near 50% at normal/brisk pace. At rest, rotation energy concentrates below
/// ~0.9 Hz (posture sway), which this detector rejects spectrally.
///
/// Algorithm: over each physically contiguous segment, slide a Hann-windowed
/// DFT along the rotation-magnitude signal; windows whose dominant in-band
/// (step band) component is prominent and not sway-dominated become cadence
/// anchors. Consecutive active windows form a bout; a bout containing at
/// least `minAnchorWindows` anchors contributes activeDuration × median
/// anchor cadence (steps continue through turns even when periodicity breaks,
/// proven by the shuttle-walk truth). Bouts without anchors contribute zero,
/// which is what keeps rest-stage transients (wrist adjustments) at exactly
/// zero steps.
///
/// Offline evaluation, never promoted without the full fitter gates.
/// Card session (shuttle, 0/100/100/100/200/0 truth), with parabolic peak
/// interpolation and the 0.6 turn discount: 100.5 / 93.1 / 102.6 / 198.8
/// steps → mean walk error 2.6%, max 6.9%, rest false steps 0.
/// Leave-one-out cross-validation (turn discount fitted on three stages,
/// evaluated on the held-out fourth): LOO mean 3.2%, LOO max 6.9%.
/// An anchor-density-adaptive discount was tried and rejected: LOO 5.2%/9.5%
/// (shuttle bouts are anchor-rich, so it degenerates to no discount).
/// Treadmill whole-window direction check reads −26%, but that window holds
/// a ~60 s in-window stand, five continuity breaks, and a uniformity
/// assumption in its coverage-scaled truth — it cannot arbitrate finer than
/// roughly ±15%. Final arbitration is the steady-gait card session.
enum AtriaGyroCadenceResearchPedometer {
    static let sampleRateHz = 100
    static let windowSeconds = 4.0
    static let hopSeconds = 0.5
    static let stepBandLoHz = 1.3
    static let stepBandHiHz = 3.0
    static let spectrumFloorHz = 0.3
    static let spectrumCeilingHz = 4.0
    static let rotationLevelGate = 35.0
    static let prominenceGate = 1.6
    static let swayRatio = 1.4
    static let minAnchorWindows = 2
    /// Active-but-unanchored windows inside a bout are dominated by direction
    /// changes, where stepping fractionally pauses; counting them at full
    /// cadence produced a systematic +7…+14% overshoot on counted truth.
    static let turnWindowDiscount = 0.6

    /// Steps for ONE physically contiguous rotation-magnitude segment.
    /// Callers must split at device-time discontinuities; concatenating
    /// across a gap would fabricate motion evidence. The gate parameters are
    /// exposed so the strict fitter can sweep this family against a guided
    /// manifest under the same promotion gates as the production family.
    static func steps(contiguousRotationMagnitudes samples: [Double],
                      sampleRateHz: Int = sampleRateHz,
                      rotationLevelGate: Double = rotationLevelGate,
                      prominenceGate: Double = prominenceGate,
                      turnWindowDiscount: Double = turnWindowDiscount) -> Double {
        let win = Int(windowSeconds * Double(sampleRateHz))
        let hop = Int(hopSeconds * Double(sampleRateHz))
        guard samples.count >= win, win > 0, hop > 0 else { return 0 }

        struct WindowVerdict {
            let active: Bool
            let anchorCadenceHz: Double?
        }
        var verdicts: [WindowVerdict] = []
        var start = 0
        let hann = (0..<win).map { i in
            0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(win - 1)))
        }
        while start + win <= samples.count {
            let window = Array(samples[start..<(start + win)])
            let mean = window.reduce(0, +) / Double(win)
            guard mean >= rotationLevelGate else {
                verdicts.append(WindowVerdict(active: false, anchorCadenceHz: nil))
                start += hop
                continue
            }
            let tapered = (0..<win).map { (window[$0] - mean) * hann[$0] }
            let binHz = Double(sampleRateHz) / Double(win)
            let floorBin = Int((spectrumFloorHz / binHz).rounded(.up))
            let ceilBin = Int((spectrumCeilingHz / binHz).rounded(.down))
            var magnitudesByBin: [Int: Double] = [:]
            for bin in floorBin...ceilBin {
                var real = 0.0, imag = 0.0
                let omega = -2 * Double.pi * Double(bin) / Double(win)
                for n in 0..<win {
                    let angle = omega * Double(n)
                    real += tapered[n] * cos(angle)
                    imag += tapered[n] * sin(angle)
                }
                magnitudesByBin[bin] = (real * real + imag * imag).squareRoot()
            }
            let inBand = magnitudesByBin.filter {
                let f = Double($0.key) * binHz
                return f >= stepBandLoHz && f <= stepBandHiHz
            }
            let belowBand = magnitudesByBin.filter {
                let f = Double($0.key) * binHz
                return f > spectrumFloorHz && f < stepBandLoHz
            }
            let sortedAll = magnitudesByBin.values.sorted()
            let median = sortedAll.isEmpty ? 0 : sortedAll[sortedAll.count / 2]
            guard let peak = inBand.max(by: { $0.value < $1.value }),
                  median > 0,
                  peak.value / median >= prominenceGate,
                  (belowBand.values.max() ?? 0) <= swayRatio * peak.value else {
                verdicts.append(WindowVerdict(active: true, anchorCadenceHz: nil))
                start += hop
                continue
            }
            // Parabolic interpolation over adjacent bins: the raw 0.25 Hz bin
            // width alone is a ±7% cadence quantization error at gait rates.
            var cadence = Double(peak.key) * binHz
            if let lower = magnitudesByBin[peak.key - 1],
               let upper = magnitudesByBin[peak.key + 1] {
                let denominator = lower - 2 * peak.value + upper
                if abs(denominator) > 1e-12 {
                    let delta = min(0.5, max(-0.5, 0.5 * (lower - upper) / denominator))
                    cadence += delta * binHz
                }
            }
            verdicts.append(WindowVerdict(active: true, anchorCadenceHz: cadence))
            start += hop
        }

        var total = 0.0
        var index = 0
        while index < verdicts.count {
            guard verdicts[index].active else { index += 1; continue }
            var end = index
            while end < verdicts.count, verdicts[end].active { end += 1 }
            let anchors = verdicts[index..<end].compactMap(\.anchorCadenceHz).sorted()
            if anchors.count >= minAnchorWindows {
                let medianCadence = anchors[anchors.count / 2]
                let turnWindows = Double(end - index) - Double(anchors.count)
                let effectiveWindows = Double(anchors.count)
                    + turnWindowDiscount * turnWindows
                total += effectiveWindows * hopSeconds * medianCadence
            }
            index = end
        }
        return total
    }
}

/// A strap-only gait classifier that can shadow the production pedometer
/// without changing its published count. The challenger deliberately waits
/// for four seconds of evidence after each candidate step, then releases or
/// rejects it against a five-second contiguous R10 motion window.
///
/// This is not connected to `AtriaR10MotionPipeline` yet. The retained field
/// captures do not include enough charger-free, manually labelled walking and
/// handling windows to choose a safe operating point, and the production
/// detector does not currently expose candidate sample timestamps. Keeping the
/// classifier as a challenger lets replay tooling measure both before it can
/// affect a user's count.
struct AtriaStrapGaitQualityChallenger: Sendable {
    static let sampleRateHz = AtriaStrapPedometer.sampleRateHz
    static let windowSeconds = 5
    static let windowSamples = sampleRateHz * windowSeconds
    static let evaluationStrideSamples = sampleRateHz
    static let evidenceAfterCandidateSamples = 4 * sampleRateHz

    enum Verdict: Equatable, Sendable {
        case accepted
        case rejected
    }

    struct Assessment: Equatable, Sendable {
        let verdict: Verdict
        let cadenceStepsPerMinute: Double
        let periodicity: Double
        let walkingBandEnergyRatio: Double
        let cadenceConsistency: Double
        let gyroscopeAgreement: Double?
    }

    struct Update: Equatable, Sendable {
        let releasedCandidateSteps: Int
        let rejectedCandidateSteps: Int
        let pendingCandidateSteps: Int
        let assessment: Assessment?
    }

    private var accelerationMagnitudes = [Double](
        repeating: 0,
        count: AtriaStrapGaitQualityChallenger.windowSamples
    )
    private var rotationRates = [AtriaR10MotionFrame.Vector3](
        repeating: .init(x: 0, y: 0, z: 0),
        count: AtriaStrapGaitQualityChallenger.windowSamples
    )
    private var gyroscopeAvailable = [Bool](
        repeating: false,
        count: AtriaStrapGaitQualityChallenger.windowSamples
    )
    private var writeIndex = 0
    private var validSampleCount = 0
    private var samplesSinceEvaluation = 0
    private var nextSampleIndex: Int64 = 0
    private var pendingCandidateIndices: [Int64] = []

    /// Candidate offsets are relative to this chunk. Chunking is otherwise
    /// invisible, so a live stream and replay of the same samples resolve the
    /// same candidates.
    mutating func ingest(acceleration: [AtriaR10MotionFrame.Vector3],
                         rotationRate: [AtriaR10MotionFrame.Vector3]? = nil,
                         candidateStepOffsets: [Int] = []) -> Update {
        let candidateOffsets = Set(candidateStepOffsets.filter {
            acceleration.indices.contains($0)
        })
        let hasAlignedGyroscope = rotationRate?.count == acceleration.count
        var released = 0
        var rejected = 0
        var latestAssessment: Assessment?

        for offset in acceleration.indices {
            if candidateOffsets.contains(offset) {
                pendingCandidateIndices.append(nextSampleIndex)
            }
            accelerationMagnitudes[writeIndex] = acceleration[offset].magnitude
            if hasAlignedGyroscope, let rotationRate {
                rotationRates[writeIndex] = rotationRate[offset]
                gyroscopeAvailable[writeIndex] = true
            } else {
                rotationRates[writeIndex] = .init(x: 0, y: 0, z: 0)
                gyroscopeAvailable[writeIndex] = false
            }
            writeIndex = (writeIndex + 1) % Self.windowSamples
            validSampleCount = min(Self.windowSamples, validSampleCount + 1)
            samplesSinceEvaluation += 1
            nextSampleIndex += 1

            guard validSampleCount == Self.windowSamples,
                  samplesSinceEvaluation >= Self.evaluationStrideSamples else { continue }
            samplesSinceEvaluation = 0
            let assessment = assessCurrentWindow()
            latestAssessment = assessment
            let lastEligibleIndex = nextSampleIndex
                - Int64(Self.evidenceAfterCandidateSamples)
                - 1
            var unresolved: [Int64] = []
            unresolved.reserveCapacity(pendingCandidateIndices.count)
            for candidateIndex in pendingCandidateIndices {
                guard candidateIndex <= lastEligibleIndex else {
                    unresolved.append(candidateIndex)
                    continue
                }
                if assessment.verdict == .accepted {
                    released += 1
                } else {
                    rejected += 1
                }
            }
            pendingCandidateIndices = unresolved
        }

        return Update(releasedCandidateSteps: released,
                      rejectedCandidateSteps: rejected,
                      pendingCandidateSteps: pendingCandidateIndices.count,
                      assessment: latestAssessment)
    }

    /// No classifier state crosses missing motion. Both an isolated R10 hole
    /// and a reconnect therefore reject unresolved challenger candidates and
    /// require a new contiguous five-second window. Production detector gap
    /// behavior remains untouched.
    mutating func resetForGap() -> Update {
        let rejected = pendingCandidateIndices.count
        pendingCandidateIndices.removeAll(keepingCapacity: true)
        writeIndex = 0
        validSampleCount = 0
        samplesSinceEvaluation = 0
        return Update(releasedCandidateSteps: 0,
                      rejectedCandidateSteps: rejected,
                      pendingCandidateSteps: 0,
                      assessment: nil)
    }

    private func assessCurrentWindow() -> Assessment {
        let magnitudes = chronologicalAccelerationMagnitudes()
        let centered = Self.centered(magnitudes)
        let standardDeviation = Self.rootMeanSquare(centered)
        let full = Self.periodicity(of: centered)
        let halfCount = centered.count / 2
        let firstHalf = Self.periodicity(of: Array(centered[..<halfCount]))
        let secondHalf = Self.periodicity(of: Array(centered[halfCount...]))
        let consistency = Self.cadenceConsistency(firstLag: firstHalf.lag,
                                                  secondLag: secondHalf.lag)
        let bandRatio = Self.walkingBandEnergyRatio(centered)
        let crestFactor = centered.map(abs).max() ?? 0
        let normalizedCrest = crestFactor / max(0.000_001, standardDeviation)
        let gyroAgreement = gyroscopeCadenceAgreement(accelerationLag: full.lag)

        let hasWalkingAmplitude = standardDeviation >= 0.025 && standardDeviation <= 0.40
        let isPeriodic = full.correlation >= 0.55
        let isWalkingBandDominant = bandRatio >= 0.58
        let isCadenceConsistent = consistency >= 0.78
        let isNotImpulseDominated = normalizedCrest <= 5.5
        let gyroDoesNotContradict = gyroAgreement.map { $0 >= 0.72 } ?? true
        let accepted = hasWalkingAmplitude
            && isPeriodic
            && isWalkingBandDominant
            && isCadenceConsistent
            && isNotImpulseDominated
            && gyroDoesNotContradict

        return Assessment(
            verdict: accepted ? .accepted : .rejected,
            cadenceStepsPerMinute: full.lag > 0
                ? 60 * Double(Self.sampleRateHz) / Double(full.lag)
                : 0,
            periodicity: full.correlation,
            walkingBandEnergyRatio: bandRatio,
            cadenceConsistency: consistency,
            gyroscopeAgreement: gyroAgreement
        )
    }

    private func chronologicalAccelerationMagnitudes() -> [Double] {
        Array(accelerationMagnitudes[writeIndex...])
            + Array(accelerationMagnitudes[..<writeIndex])
    }

    private func chronologicalRotationRates() -> ([AtriaR10MotionFrame.Vector3], [Bool]) {
        (Array(rotationRates[writeIndex...]) + Array(rotationRates[..<writeIndex]),
         Array(gyroscopeAvailable[writeIndex...]) + Array(gyroscopeAvailable[..<writeIndex]))
    }

    private func gyroscopeCadenceAgreement(accelerationLag: Int) -> Double? {
        guard accelerationLag > 0 else { return nil }
        let (rotation, availability) = chronologicalRotationRates()
        guard availability.filter({ $0 }).count >= Int(Double(Self.windowSamples) * 0.9) else {
            return nil
        }
        let axes = [rotation.map(\.x), rotation.map(\.y), rotation.map(\.z)]
        let centeredAxes = axes.map(Self.centered)
        guard let dominantAxis = centeredAxes.max(by: {
            Self.rootMeanSquare($0) < Self.rootMeanSquare($1)
        }), Self.rootMeanSquare(dominantAxis) >= 0.5 else { return nil }
        let gyro = Self.periodicity(of: dominantAxis)
        guard gyro.lag > 0, gyro.correlation >= 0.30 else { return 0 }
        let lagAgreement = 1 - min(1, abs(Double(gyro.lag - accelerationLag))
            / Double(max(gyro.lag, accelerationLag)))
        return min(1, 0.65 * lagAgreement + 0.35 * gyro.correlation)
    }

    private static func centered(_ signal: [Double]) -> [Double] {
        guard !signal.isEmpty else { return [] }
        let mean = signal.reduce(0, +) / Double(signal.count)
        return signal.map { $0 - mean }
    }

    private static func rootMeanSquare(_ signal: [Double]) -> Double {
        guard !signal.isEmpty else { return 0 }
        return sqrt(signal.reduce(0) { $0 + $1 * $1 } / Double(signal.count))
    }

    private static func periodicity(of signal: [Double]) -> (lag: Int, correlation: Double) {
        guard signal.count >= 100 else { return (0, 0) }
        let minimumLag = sampleRateHz * 60 / 200
        let maximumLag = min(sampleRateHz * 60 / 48, signal.count / 2)
        guard minimumLag < maximumLag else { return (0, 0) }
        var correlations: [(lag: Int, value: Double)] = []
        correlations.reserveCapacity(maximumLag - minimumLag + 1)
        for lag in minimumLag...maximumLag {
            var cross = 0.0
            var leadingEnergy = 0.0
            var trailingEnergy = 0.0
            for index in lag..<signal.count {
                let leading = signal[index]
                let trailing = signal[index - lag]
                cross += leading * trailing
                leadingEnergy += leading * leading
                trailingEnergy += trailing * trailing
            }
            let denominator = sqrt(leadingEnergy * trailingEnergy)
            let correlation = denominator > 0 ? cross / denominator : 0
            correlations.append((lag, correlation))
        }
        guard let strongest = correlations.max(by: { $0.value < $1.value }) else {
            return (0, 0)
        }
        // Periodic signals commonly have equally strong peaks at the
        // fundamental and its multiples. Prefer the earliest near-maximum
        // local peak so acceleration and gyroscope agree on cadence instead
        // of arbitrarily selecting different harmonics due to rounding noise.
        let nearMaximum = max(0.45, strongest.value * 0.95)
        let fundamental = correlations.enumerated().first { offset, candidate in
            guard candidate.value >= nearMaximum else { return false }
            let previous = offset > 0 ? correlations[offset - 1].value : -1
            let next = offset + 1 < correlations.count
                ? correlations[offset + 1].value
                : -1
            return candidate.value >= previous && candidate.value >= next
        }?.element ?? strongest
        return (fundamental.lag, max(0, min(1, fundamental.value)))
    }

    private static func cadenceConsistency(firstLag: Int, secondLag: Int) -> Double {
        guard firstLag > 0, secondLag > 0 else { return 0 }
        return 1 - min(1, abs(Double(firstLag - secondLag))
            / Double(max(firstLag, secondLag)))
    }

    /// Small fixed-bin DFT. It runs once per second, not for every 100 Hz
    /// sample, and confines the score to the 48–195 steps/min walking band.
    private static func walkingBandEnergyRatio(_ signal: [Double]) -> Double {
        guard !signal.isEmpty else { return 0 }
        var walkingEnergy = 0.0
        var consideredEnergy = 0.0
        for bin in 2...20 { // 0.5 ... 5 Hz in 0.25 Hz bins
            let frequency = Double(bin) * 0.25
            var real = 0.0
            var imaginary = 0.0
            for (index, value) in signal.enumerated() {
                let angle = 2 * Double.pi * frequency * Double(index) / Double(sampleRateHz)
                real += value * cos(angle)
                imaginary -= value * sin(angle)
            }
            let energy = real * real + imaginary * imaginary
            consideredEnergy += energy
            if frequency >= 0.8, frequency <= 3.25 {
                walkingEnergy += energy
            }
        }
        return consideredEnergy > 0 ? walkingEnergy / consideredEnergy : 0
    }
}

/// Keeps R10 decoding and step analysis off the BLE and main queues. Atria only
/// publishes cadence-limited detector snapshots at most once per second. A
/// trailing evaluation guarantees that a final/batched frame cannot leave a
/// newer internal state stranded behind the cadence gate.
final class AtriaR10MotionPipeline: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        /// Identifies the pipeline accounting segment that produced this
        /// snapshot. Main-actor consumers must reject snapshots from an older
        /// generation after a session roll/reset.
        let generation: UInt64
        let steps: Int
        let rawSteps: Int
        let frames: Int
        let samples: Int
        let deviceTimestamp: UInt32
        /// Host receipt time of the newest frame whose samples have actually
        /// been applied to this detector snapshot. Transport receipt alone is
        /// not step-count freshness until the serial detector catches up.
        let receivedAt: Date?
        let stillnessRatio: Double
        let movementIntensity: Double
        let activityBursts: Int
        let gravityValidatedFrames: Int
        let state: String
    }

    struct SegmentTransition: Equatable, Sendable {
        /// Final detector state from the segment being closed, before its
        /// persisted prefix is rebased.
        let finalSnapshot: Snapshot?
        /// Motion accepted after the persisted snapshot was captured. This is
        /// carried into the new accounting segment instead of being dropped.
        let carriedSnapshot: Snapshot?
        let generation: UInt64
    }

    struct BoundaryToken: Equatable, Sendable {
        let id: UUID
        let finalSnapshot: Snapshot?
        let generation: UInt64
        let markerRawSteps: Int
    }

    /// A FIFO marker is enqueued synchronously at the caller's logical edge,
    /// while its result remains asynchronously awaitable. This closes the gap
    /// where the main actor had already started buffering HR/RR but a newly
    /// arriving R10 frame could still enter the old segment before an async
    /// task got around to calling `prepareBoundary()`.
    final class BoundaryPreparation: @unchecked Sendable {
        let enqueuedAt: Date
        private let lock = NSLock()
        private var token: BoundaryToken?
        private var waiters: [CheckedContinuation<BoundaryToken, Never>] = []

        fileprivate init(enqueuedAt: Date) {
            self.enqueuedAt = enqueuedAt
        }

        fileprivate func resolve(_ token: BoundaryToken) {
            lock.lock()
            guard self.token == nil else {
                lock.unlock()
                return
            }
            self.token = token
            let continuations = waiters
            waiters.removeAll(keepingCapacity: false)
            lock.unlock()
            continuations.forEach { $0.resume(returning: token) }
        }

        func value() async -> BoundaryToken {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let token {
                    lock.unlock()
                    continuation.resume(returning: token)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }

    private let queue = DispatchQueue(label: "com.adidshaft.atria.r10-motion", qos: .utility)
    private let gain: Double
    private let snapshotMinimumInterval: TimeInterval
    private var detector = AtriaStrapPedometer.StreamingDetector()
    private var committedRawSteps = 0
    /// Largest durable prefix already merged by `seed`. Journal restoration
    /// can be requested more than once across foreground/restoration races;
    /// only a newly larger prefix may advance accounting a second time.
    private var restoredRawStepPrefix = 0
    /// A resident journal is bounded to 18 hours. If CoreBluetooth replays a
    /// few pre-checkpoint frames before that first restore finishes, their
    /// older device seconds can be identified without confusing a genuine
    /// firmware clock reset (whose backwards jump is much larger).
    private static let maximumPreRestoreReplayGapSeconds: UInt32 = 18 * 60 * 60
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
    private var segmentRawStepBaseline = 0
    private var generation: UInt64 = 0
    private var pendingSnapshotWorkItem: DispatchWorkItem?
    private var pendingSnapshotDeviceTimestamp: UInt32?
    private var pendingSnapshotUpdate: (@Sendable (Snapshot) -> Void)?
    private struct BufferedFrame {
        let frame: AtriaR10MotionFrame
        let receivedAt: Date
        let onUpdate: @Sendable (Snapshot) -> Void
    }
    private var preparedBoundary: BoundaryToken?
    private var committedBoundaryAwaitingRelease: (id: UUID, generation: UInt64)?
    private var bufferedBoundaryFrames: [BufferedFrame] = []

    init(sampleRateHz: Int = AtriaStrapPedometer.sampleRateHz,
         gain: Double = AtriaStrapPedometer.referenceGain,
         snapshotMinimumInterval: TimeInterval = 1) {
        // R10 framing fixes production input at 100 Hz. Retain this argument
        // for source compatibility with existing callers and test tooling.
        _ = sampleRateHz
        self.gain = max(0.5, min(gain, 2.0))
        self.snapshotMinimumInterval = max(0.01, snapshotMinimumInterval)
    }

    func ingest(_ frame: AtriaR10MotionFrame,
                receivedAt: Date,
                onUpdate: @escaping @Sendable (Snapshot) -> Void) {
        queue.async { [self] in
            if preparedBoundary != nil || committedBoundaryAwaitingRelease != nil {
                bufferedBoundaryFrames.append(BufferedFrame(frame: frame,
                                                            receivedAt: receivedAt,
                                                            onUpdate: onUpdate))
                return
            }
            ingestLocked(frame, receivedAt: receivedAt, onUpdate: onUpdate)
        }
    }

    private func ingestLocked(
        _ frame: AtriaR10MotionFrame,
        receivedAt: Date,
        onUpdate: @escaping @Sendable (Snapshot) -> Void
    ) {
        guard accept(frame, receivedAt: receivedAt) else { return }
        let firstFrame = totalFrames == 1
        guard Self.shouldEvaluateSnapshot(firstFrame: firstFrame,
                                          lastEvaluatedAt: lastSnapshotEvaluationAt,
                                          receivedAt: receivedAt,
                                          minimumInterval: snapshotMinimumInterval) else {
            scheduleTrailingSnapshot(deviceTimestamp: frame.deviceTimestamp,
                                     receivedAt: receivedAt,
                                     onUpdate: onUpdate)
            return
        }
        cancelTrailingSnapshot()
        publishSnapshot(deviceTimestamp: frame.deviceTimestamp,
                        evaluatedAt: receivedAt,
                        onUpdate: onUpdate)
    }

    static func shouldEvaluateSnapshot(firstFrame: Bool,
                                       lastEvaluatedAt: Date?,
                                       receivedAt: Date,
                                       minimumInterval: TimeInterval = 1) -> Bool {
        if firstFrame { return true }
        guard let lastEvaluatedAt else { return true }
        return receivedAt.timeIntervalSince(lastEvaluatedAt) >= max(0.01, minimumInterval)
    }

    /// RFC-1982-style ordering for the strap's UInt32 seconds clock. A delta
    /// in the lower half of the serial space is forward (including a genuine
    /// UInt32 wrap); zero is a duplicate and the upper half is stale/replayed.
    static func forwardDeviceTimestampDelta(from previous: UInt32,
                                            to current: UInt32) -> UInt32? {
        let delta = current &- previous
        guard delta > 0, delta < (UInt32.max / 2 + 1) else { return nil }
        return delta
    }

    @discardableResult
    func resetSynchronously() -> UInt64 {
        queue.sync { [self] in
            precondition(preparedBoundary == nil && committedBoundaryAwaitingRelease == nil,
                         "testing reset must not invalidate an active async boundary")
            cancelTrailingSnapshot()
            generation &+= 1
            detector.reset()
            committedRawSteps = 0
            restoredRawStepPrefix = 0
            segmentRawStepBaseline = 0
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
            return generation
        }
    }

    /// Drains all already-enqueued detector work and returns its current state.
    /// The trailing cadence callback remains armed; callers use this to make a
    /// persistence snapshot authoritative without disturbing live delivery.
    func currentSnapshotSynchronously() -> Snapshot? {
        queue.sync { [self] in
            guard totalFrames > 0 else { return nil }
            return makeSnapshot(deviceTimestamp: lastAcceptedDeviceTimestamp ?? 0,
                                receivedAt: lastAcceptedReceivedAt)
        }
    }

    /// Inserts a FIFO marker after every frame already submitted to the motion
    /// queue. Preparing is non-mutating, so failed session persistence can leave
    /// the live detector and its accounting segment completely untouched.
    func enqueueBoundaryPreparation(at enqueuedAt: Date = Date()) -> BoundaryPreparation {
        let preparation = BoundaryPreparation(enqueuedAt: enqueuedAt)
        queue.async { [self] in
            if let preparedBoundary {
                preparation.resolve(preparedBoundary)
                return
            }
            precondition(committedBoundaryAwaitingRelease == nil,
                         "a committed boundary must be released before preparing another")
            cancelTrailingSnapshot()
            let markerRawSteps = currentRawSteps()
            let snapshot = (totalFrames > 0 || markerRawSteps > 0)
                ? makeSnapshot(deviceTimestamp: lastAcceptedDeviceTimestamp ?? 0,
                               receivedAt: lastAcceptedReceivedAt)
                : nil
            let token = BoundaryToken(
                id: UUID(),
                finalSnapshot: snapshot,
                generation: generation,
                markerRawSteps: markerRawSteps
            )
            preparedBoundary = token
            preparation.resolve(token)
        }
        return preparation
    }

    func prepareBoundary() async -> BoundaryToken {
        await enqueueBoundaryPreparation().value()
    }

    /// Commits a previously prepared boundary only after its SavedSession is
    /// durable. Frames accepted after the marker remain in the new segment;
    /// detector filters, confirmed gait and device-time continuity are kept.
    func commitBoundary(
        _ token: BoundaryToken,
        handedOffRawSteps: Int? = nil,
        nextGeneration: UInt64
    ) async -> SegmentTransition? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard preparedBoundary?.id == token.id,
                      generation == token.generation,
                      nextGeneration == generation &+ 1,
                      (handedOffRawSteps == token.markerRawSteps || handedOffRawSteps == 0),
                      currentRawSteps() >= token.markerRawSteps else {
                    continuation.resume(returning: nil)
                    return
                }
                let transition = transitionSegmentLocked(
                    handedOffRawSteps: handedOffRawSteps ?? token.markerRawSteps,
                    nextGeneration: nextGeneration
                )
                preparedBoundary = nil
                committedBoundaryAwaitingRelease = (token.id, nextGeneration)
                continuation.resume(returning: transition)
            }
        }
    }

    /// Releases post-marker frames only after the main actor has installed the
    /// new generation and reset HR/RR state. Until then, both already-buffered
    /// and newly submitted R10 frames remain behind the committed fence.
    func releaseCommittedBoundaryFrames(
        _ token: BoundaryToken,
        generation expectedGeneration: UInt64
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard generation == expectedGeneration else {
                    continuation.resume(returning: false)
                    return
                }
                guard let committedBoundaryAwaitingRelease else {
                    // A repeated manager completion after a successful release
                    // is harmless and must not turn into a false failure.
                    continuation.resume(returning: true)
                    return
                }
                guard committedBoundaryAwaitingRelease.id == token.id,
                      committedBoundaryAwaitingRelease.generation == expectedGeneration else {
                    continuation.resume(returning: false)
                    return
                }
                releaseBufferedBoundaryFramesLocked()
                continuation.resume(returning: true)
            }
        }
    }

    /// Recovery for the only possible normal-release rejection: the manager
    /// has the installed generation but its token identity was lost/corrupted.
    /// There can be only one committed fence, so generation matching makes this
    /// safe, bounded and idempotent without accepting frames into a wrong epoch.
    func forceReleaseCommittedBoundaryFrames(generation expectedGeneration: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard generation == expectedGeneration else {
                    continuation.resume(returning: false)
                    return
                }
                guard let committedBoundaryAwaitingRelease else {
                    continuation.resume(returning: true)
                    return
                }
                guard committedBoundaryAwaitingRelease.generation == expectedGeneration else {
                    continuation.resume(returning: false)
                    return
                }
                releaseBufferedBoundaryFramesLocked()
                continuation.resume(returning: true)
            }
        }
    }

    private func releaseBufferedBoundaryFramesLocked() {
        committedBoundaryAwaitingRelease = nil
        let buffered = bufferedBoundaryFrames
        bufferedBoundaryFrames.removeAll(keepingCapacity: true)
        for item in buffered {
            ingestLocked(item.frame,
                         receivedAt: item.receivedAt,
                         onUpdate: item.onUpdate)
        }
    }

    func abortBoundary(_ token: BoundaryToken) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard preparedBoundary?.id == token.id,
                      generation == token.generation else {
                    continuation.resume(returning: false)
                    return
                }
                preparedBoundary = nil
                let buffered = bufferedBoundaryFrames
                bufferedBoundaryFrames.removeAll(keepingCapacity: true)
                for item in buffered {
                    ingestLocked(item.frame,
                                 receivedAt: item.receivedAt,
                                 onUpdate: item.onUpdate)
                }
                continuation.resume(returning: true)
            }
        }
    }

    /// Closes only the current accounting segment. Filter, confirmed-gait and
    /// device-timestamp continuity remain live because a journal/HR roll is not
    /// a physical strap disconnect. Raw steps accepted after the caller's
    /// persisted snapshot are rebased into `carriedSnapshot` for the next
    /// segment, making the persistence/reset boundary lossless.
    func rollSegmentSynchronously(persistedRawSteps: Int) -> SegmentTransition {
        queue.sync { [self] in
            precondition(preparedBoundary == nil && committedBoundaryAwaitingRelease == nil,
                         "testing roll must not invalidate an active async boundary")
            return transitionSegmentLocked(
                handedOffRawSteps: persistedRawSteps,
                nextGeneration: generation &+ 1
            )
        }
    }

    private func transitionSegmentLocked(
        handedOffRawSteps: Int,
        nextGeneration: UInt64
    ) -> SegmentTransition {
        cancelTrailingSnapshot()
        let currentSegmentRawSteps = currentRawSteps()
        let finalSnapshot = (totalFrames > 0 || currentSegmentRawSteps > 0)
            ? makeSnapshot(deviceTimestamp: lastAcceptedDeviceTimestamp ?? 0,
                           receivedAt: lastAcceptedReceivedAt)
            : nil
        precondition(handedOffRawSteps >= 0 && handedOffRawSteps <= currentSegmentRawSteps)
        segmentRawStepBaseline += handedOffRawSteps
        let carriedRawSteps = currentRawSteps()

        generation = nextGeneration
        totalFrames = 0
        totalSamples = 0
        stillSamples = 0
        movementTotal = 0
        activityBursts = 0
        gravityValidatedFrames = 0
        lastObservedRawSteps = carriedRawSteps
        lastPublishedSteps = -1
        lastSnapshotEvaluationAt = nil

        let carriedSnapshot: Snapshot?
        if carriedRawSteps > 0 {
            carriedSnapshot = makeSnapshot(
                deviceTimestamp: lastAcceptedDeviceTimestamp ?? 0,
                receivedAt: lastAcceptedReceivedAt
            )
        } else {
            carriedSnapshot = nil
        }
        return SegmentTransition(finalSnapshot: finalSnapshot,
                                 carriedSnapshot: carriedSnapshot,
                                 generation: generation)
    }

    /// Restores the detector's durable prefix after process relaunch. A journal
    /// cannot reconstruct pre-relaunch filter/gait state without raw samples,
    /// so new frames continue monotonically from the last published raw total.
    func seed(
        committedRawSteps restoredRawSteps: Int,
        lastAcceptedDeviceTimestamp restoredDeviceTimestamp: UInt32? = nil
    ) async -> (steps: Int, rawSteps: Int) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: seedLocked(
                    committedRawSteps: restoredRawSteps,
                    lastAcceptedDeviceTimestamp: restoredDeviceTimestamp
                ))
            }
        }
    }

    func seedSynchronously(
        committedRawSteps restoredRawSteps: Int,
        lastAcceptedDeviceTimestamp restoredDeviceTimestamp: UInt32? = nil
    ) -> (steps: Int, rawSteps: Int) {
        queue.sync { [self] in
            seedLocked(committedRawSteps: restoredRawSteps,
                       lastAcceptedDeviceTimestamp: restoredDeviceTimestamp)
        }
    }

    private func seedLocked(
        committedRawSteps restoredRawSteps: Int,
        lastAcceptedDeviceTimestamp restoredDeviceTimestamp: UInt32?
    ) -> (steps: Int, rawSteps: Int) {
        guard preparedBoundary == nil && committedBoundaryAwaitingRelease == nil else {
            let rawSteps = max(lastObservedRawSteps, currentRawSteps())
            return (Int((Double(rawSteps) * gain).rounded()), rawSteps)
        }
        // Journal loading is asynchronous. If fresh R10 frames arrived before
        // restore completed, retain their detector state and add the durable
        // prefix instead of losing post-launch motion. Merge only the delta
        // above an already-restored prefix so repeated restore requests cannot
        // duplicate the same durable steps.
        let boundedRestoredRawSteps = max(0, restoredRawSteps)
        if boundedRestoredRawSteps > 0 {
            discardPreRestoreReplayIfNeeded(restoredDeviceTimestamp)
        }
        let newlyRestoredRawSteps = max(0, boundedRestoredRawSteps - restoredRawStepPrefix)
        committedRawSteps += newlyRestoredRawSteps
        restoredRawStepPrefix = max(restoredRawStepPrefix, boundedRestoredRawSteps)
        installRestoredDeviceTimestampWatermark(restoredDeviceTimestamp)
        let rawSteps = max(lastObservedRawSteps, currentRawSteps())
        lastObservedRawSteps = rawSteps
        let steps = Int((Double(rawSteps) * gain).rounded())
        lastPublishedSteps = steps
        return (steps, rawSteps)
    }

    /// Drops only frames that raced ahead of the first journal restore and are
    /// provably an older prefix within the journal's retention horizon. This
    /// prevents replayed gait from being added to the durable prefix. Large
    /// backwards jumps remain intact because they can be a strap clock reset.
    private func discardPreRestoreReplayIfNeeded(_ restored: UInt32?) {
        guard restoredRawStepPrefix == 0,
              generation == 0,
              let restored, restored > 0,
              let current = lastAcceptedDeviceTimestamp, current > 0 else { return }
        let replayGap = restored &- current
        guard replayGap > 0,
              replayGap < (UInt32.max / 2 + 1),
              replayGap <= Self.maximumPreRestoreReplayGapSeconds else { return }

        cancelTrailingSnapshot()
        detector.reset()
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
        lastObservedRawSteps = max(0, committedRawSteps - segmentRawStepBaseline)
        lastPublishedSteps = -1
        lastSnapshotEvaluationAt = nil
    }

    /// A durable R10 second is a replay watermark, not live freshness. Keep a
    /// genuinely newer frame that won the async restore race, but otherwise
    /// install the checkpoint so subsequent equal/older CoreBluetooth replay
    /// is rejected before it can enter gait confirmation.
    private func installRestoredDeviceTimestampWatermark(_ restored: UInt32?) {
        guard let restored, restored > 0 else { return }
        if let current = lastAcceptedDeviceTimestamp {
            if current == restored
                || Self.forwardDeviceTimestampDelta(from: restored, to: current) != nil {
                return
            }
        }
        lastAcceptedDeviceTimestamp = restored
        if seenTimestamps.insert(restored).inserted {
            timestampOrder.append(restored)
            if timestampOrder.count > 512 {
                seenTimestamps.remove(timestampOrder.removeFirst())
            }
        }
    }

    func ingestSynchronouslyForTesting(_ frame: AtriaR10MotionFrame) -> Snapshot? {
        queue.sync { [self] in
            guard accept(frame, receivedAt: nil) else { return nil }
            return makeSnapshot(deviceTimestamp: frame.deviceTimestamp,
                                receivedAt: nil)
        }
    }

    private func accept(_ frame: AtriaR10MotionFrame, receivedAt: Date?) -> Bool {
        guard frame.acceleration.count == AtriaR10MotionDecoder.sampleCount else { return false }
        var forwardDeviceTimestampDelta: UInt32?
        if frame.deviceTimestamp > 0 {
            if let previous = lastAcceptedDeviceTimestamp {
                guard let delta = Self.forwardDeviceTimestampDelta(
                    from: previous,
                    to: frame.deviceTimestamp
                ) else {
                    return false
                }
                forwardDeviceTimestampDelta = delta
            }
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
        if let forwardDeviceTimestampDelta {
            switch forwardDeviceTimestampDelta {
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

    private func scheduleTrailingSnapshot(deviceTimestamp: UInt32,
                                          receivedAt: Date,
                                          onUpdate: @escaping @Sendable (Snapshot) -> Void) {
        pendingSnapshotDeviceTimestamp = deviceTimestamp
        pendingSnapshotUpdate = onUpdate
        guard pendingSnapshotWorkItem == nil else { return }
        let elapsed = lastSnapshotEvaluationAt.map { receivedAt.timeIntervalSince($0) } ?? 0
        let delay = max(0.001, snapshotMinimumInterval - max(0, elapsed))
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSnapshotWorkItem = nil
            guard let onUpdate = self.pendingSnapshotUpdate else { return }
            let deviceTimestamp = self.pendingSnapshotDeviceTimestamp
                ?? self.lastAcceptedDeviceTimestamp
                ?? 0
            self.pendingSnapshotUpdate = nil
            self.pendingSnapshotDeviceTimestamp = nil
            self.publishSnapshot(deviceTimestamp: deviceTimestamp,
                                 evaluatedAt: Date(),
                                 onUpdate: onUpdate)
        }
        pendingSnapshotWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelTrailingSnapshot() {
        pendingSnapshotWorkItem?.cancel()
        pendingSnapshotWorkItem = nil
        pendingSnapshotDeviceTimestamp = nil
        pendingSnapshotUpdate = nil
    }

    private func publishSnapshot(deviceTimestamp: UInt32,
                                 evaluatedAt: Date,
                                 onUpdate: @escaping @Sendable (Snapshot) -> Void) {
        lastSnapshotEvaluationAt = evaluatedAt
        let snapshot = makeSnapshot(deviceTimestamp: deviceTimestamp,
                                    receivedAt: lastAcceptedReceivedAt)
        lastPublishedSteps = snapshot.steps
        // Publish every cadence-limited detector evaluation, including an
        // unchanged count. Stationary samples still advance the authoritative
        // detector-snapshot clock used by workout action boundaries.
        onUpdate(snapshot)
    }

    private func finalizeCurrentMotionSegment(preservingConfirmedGait: Bool = false) {
        committedRawSteps += detector.rawSteps
        if preservingConfirmedGait {
            detector.resetAfterIsolatedMissingSecond()
        } else {
            detector.reset()
        }
        lastObservedRawSteps = max(lastObservedRawSteps, currentRawSteps())
    }

    private func currentRawSteps() -> Int {
        max(0, committedRawSteps + detector.rawSteps - segmentRawStepBaseline)
    }

    private func makeSnapshot(deviceTimestamp: UInt32,
                              receivedAt: Date?) -> Snapshot {
        let rawSteps = max(lastObservedRawSteps, currentRawSteps())
        lastObservedRawSteps = rawSteps
        return Snapshot(generation: generation,
                        steps: Int((Double(rawSteps) * gain).rounded()),
                        rawSteps: rawSteps,
                        frames: totalFrames,
                        samples: totalSamples,
                        deviceTimestamp: deviceTimestamp,
                        receivedAt: receivedAt,
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
