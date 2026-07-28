import Foundation

/// Fail-closed conversion of WHOOP 4 v24 motion ticks into strap-only steps.
///
/// The firmware counter at payload bytes 88...89 is physical motion evidence,
/// but counted walks prove that one tick is not one step. This model therefore
/// has no unvalidated fallback: a controlled walk fits the scale and a separate
/// held-out walk must pass before any count can be published.
enum AtriaWhoop4MotionTickStepModel {
    static let algorithmVersion = "whoop4-motion-ticks-to-steps-v1"
    static let maximumHeldOutRelativeError = 0.05

    enum Kind: String, Codable, Equatable, Sendable {
        case walk
        case rest
    }

    struct Point: Codable, Equatable, Sendable {
        let id: String
        let kind: Kind
        let durationSeconds: TimeInterval
        let motionTicks: Int
        let countedSteps: Int
        /// True only when start and stop were durably marked independently of
        /// workout UI render/save latency.
        let exactBoundaries: Bool
    }

    struct Model: Codable, Equatable, Sendable {
        let algorithmVersion: String
        let ticksPerStep: Double
        let trainingPointIDs: [String]
        let fittedAt: Date
    }

    struct Validation: Codable, Equatable, Sendable {
        let algorithmVersion: String
        let model: Model
        let heldOutPointIDs: [String]
        let maximumRelativeError: Double
        let meanRelativeError: Double
        let restFalseSteps: Int
        let validatedAt: Date
        let passed: Bool
    }

    /// Hardware-family receipt produced by the physical 2026-07-27 Gate 4
    /// acceptance. The fit used a 132-step training walk (155 ticks) plus a
    /// zero-tick rest; the independent 136-step walk produced 160 ticks and
    /// predicted 136, with another zero-tick rest. This is a decoder
    /// calibration for the WHOOP 4 v24 firmware counter, not a phone-derived
    /// estimate and not a user-entered workout total.
    static let physicallyValidatedWhoop4V24 = Validation(
        algorithmVersion: algorithmVersion,
        model: Model(
            algorithmVersion: algorithmVersion,
            ticksPerStep: 155.0 / 132.0,
            trainingPointIDs: [
                "2026-07-27-prearmed-rest-60s",
                "1785091772-1785091863-live_workout_window",
            ],
            fittedAt: Date(timeIntervalSince1970: 1_785_091_863)
        ),
        heldOutPointIDs: [
            "2026-07-27-heldout-rest-60s",
            "1785092820-1785092913-live_workout_window",
        ],
        maximumRelativeError: 0,
        meanRelativeError: 0,
        restFalseSteps: 0,
        validatedAt: Date(timeIntervalSince1970: 1_785_093_071),
        passed: true
    )

    static func fit(
        training: [Point],
        now: Date = Date()
    ) -> Model? {
        guard validIndependentPoints(training),
              training.contains(where: { $0.kind == .rest }),
              training.allSatisfy({ $0.kind != .rest || $0.motionTicks == 0 }) else {
            return nil
        }
        let walks = training.filter { $0.kind == .walk }
        guard !walks.isEmpty else { return nil }
        let weightedRatios = walks.map {
            (
                ratio: Double($0.motionTicks) / Double($0.countedSteps),
                weight: $0.countedSteps
            )
        }
        guard let scale = weightedMedian(weightedRatios),
              scale.isFinite,
              scale >= 0.5,
              scale <= 4 else {
            return nil
        }
        return Model(
            algorithmVersion: algorithmVersion,
            ticksPerStep: scale,
            trainingPointIDs: training.map(\.id).sorted(),
            fittedAt: now
        )
    }

    static func validate(
        model: Model,
        heldOut: [Point],
        now: Date = Date()
    ) -> Validation? {
        guard model.algorithmVersion == algorithmVersion,
              model.ticksPerStep.isFinite,
              model.ticksPerStep > 0,
              validIndependentPoints(heldOut),
              Set(model.trainingPointIDs).isDisjoint(with: Set(heldOut.map(\.id))),
              heldOut.contains(where: { $0.kind == .walk }),
              heldOut.contains(where: { $0.kind == .rest }) else {
            return nil
        }

        var errors: [Double] = []
        var restFalseSteps = 0
        for point in heldOut {
            let predicted = rawPrediction(
                motionTicks: point.motionTicks,
                ticksPerStep: model.ticksPerStep
            )
            switch point.kind {
            case .rest:
                restFalseSteps += predicted
            case .walk:
                errors.append(
                    abs(Double(predicted - point.countedSteps))
                        / Double(point.countedSteps)
                )
            }
        }
        guard let maximumError = errors.max(), !errors.isEmpty else { return nil }
        let meanError = errors.reduce(0, +) / Double(errors.count)
        return Validation(
            algorithmVersion: algorithmVersion,
            model: model,
            heldOutPointIDs: heldOut.map(\.id).sorted(),
            maximumRelativeError: maximumError,
            meanRelativeError: meanError,
            restFalseSteps: restFalseSteps,
            validatedAt: now,
            passed: restFalseSteps == 0
                && maximumError <= maximumHeldOutRelativeError
        )
    }

    /// The sole publication entry point. Unvalidated fits and failed holdouts
    /// cannot produce a user-facing step count.
    static func publishedSteps(
        motionTicks: Int,
        validation: Validation?
    ) -> Int? {
        guard motionTicks >= 0,
              let validation,
              validation.algorithmVersion == algorithmVersion,
              validation.model.algorithmVersion == algorithmVersion,
              validation.passed,
              validation.restFalseSteps == 0,
              validation.maximumRelativeError <= maximumHeldOutRelativeError,
              validation.model.ticksPerStep.isFinite,
              validation.model.ticksPerStep > 0 else {
            return nil
        }
        return rawPrediction(
            motionTicks: motionTicks,
            ticksPerStep: validation.model.ticksPerStep
        )
    }

    private static func validIndependentPoints(_ points: [Point]) -> Bool {
        guard !points.isEmpty,
              Set(points.map(\.id)).count == points.count else {
            return false
        }
        return points.allSatisfy {
            !$0.id.isEmpty
                && $0.exactBoundaries
                && $0.durationSeconds.isFinite
                && $0.durationSeconds >= 30
                && $0.durationSeconds <= 10 * 60
                && $0.motionTicks >= 0
                && $0.countedSteps >= 0
                && ($0.kind == .walk
                    ? ($0.motionTicks > 0 && $0.countedSteps > 0)
                    : $0.countedSteps == 0)
        }
    }

    private static func rawPrediction(
        motionTicks: Int,
        ticksPerStep: Double
    ) -> Int {
        guard motionTicks > 0 else { return 0 }
        return max(0, Int((Double(motionTicks) / ticksPerStep).rounded()))
    }

    private static func weightedMedian(
        _ values: [(ratio: Double, weight: Int)]
    ) -> Double? {
        let sorted = values
            .filter { $0.ratio.isFinite && $0.ratio > 0 && $0.weight > 0 }
            .sorted { $0.ratio < $1.ratio }
        let totalWeight = sorted.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }
        var cumulative = 0
        for value in sorted {
            cumulative += value.weight
            if cumulative * 2 >= totalWeight {
                return value.ratio
            }
        }
        return sorted.last?.ratio
    }
}

/// Strap-only cadence estimator for WHOOP 4 v24 banked motion.
///
/// Physical daily-walking acceptance disproved a cadence-independent
/// tick-to-step scale: the firmware counter is an excellent motion/stillness
/// gate, but its increments are not footfalls. During a sustained walk the
/// approximately 1.04 Hz stored gravity vector aliases normal walking cadence
/// into a stable high-frequency orientation component. Reconstructing cadence
/// from that component counts the physical walks that defeated the fixed scale
/// without using phone motion, distance, GPS, or heart rate.
enum AtriaWhoop4GravityCadenceStepModel {
    static let algorithmVersion = "whoop4-impact-gait-ensemble-v13"

    struct Point: Hashable, Sendable {
        let timestamp: TimeInterval
        let flash: UInt32
        let tick: Int
        let gravityX: Double
        let gravityY: Double
        let gravityZ: Double
        let unknownMotionScalar32: Double?
        let identity: String

        init(
            timestamp: TimeInterval,
            flash: UInt32,
            tick: Int,
            gravityX: Double,
            gravityY: Double,
            gravityZ: Double,
            unknownMotionScalar32: Double? = nil,
            identity: String
        ) {
            self.timestamp = timestamp
            self.flash = flash
            self.tick = tick
            self.gravityX = gravityX
            self.gravityY = gravityY
            self.gravityZ = gravityZ
            self.unknownMotionScalar32 = unknownMotionScalar32
            self.identity = identity
        }
    }

    struct Estimate: Equatable, Sendable {
        let steps: Int
        let durationSeconds: TimeInterval
        let sampleRateHz: Double
        let aliasFrequencyHz: Double
        let cadenceHz: Double
        let peakDominance: Double
        let motionTicks: Int
        let motionVolume: Double
        let cadenceOnlySteps: Int
        let motionVolumeSteps: Int
        /// Counter-active time which could not support a defensible cadence
        /// estimate. Daily totals remain a lower bound while this is nonzero.
        let unresolvedMotionSeconds: TimeInterval
    }

    struct AlignedEstimate: Equatable, Sendable {
        let clockOffsetSeconds: Int
        let first: Point
        let last: Point
        let estimate: Estimate
        let coverageFraction: Double
        let decodedRows: Int
    }

    private static let minimumDurationSeconds: TimeInterval = 30
    private static let minimumSampleRateHz = 0.8
    private static let maximumSampleRateHz = 1.25
    private static let minimumAliasFrequencyHz = 0.35
    private static let maximumAliasFrequencyHz = 0.50
    private static let minimumPeakDominance = 1.25
    // Frozen after the first planted-feet rhythmic-arm control disproved v4.
    // These strap-only gates distinguish the gait-like gravity-difference
    // spectrum in four physical counted walks from that control. They are
    // classification gates only; the full bounded interval remains the count
    // interval so ordinary start/stop latency is not silently discarded.
    private static let minimumGaitTickRate = 1.55
    private static let minimumGaitSpectralEntropy = 0.75
    private static let minimumRegularPositiveIncrementCount = 55
    private static let minimumRegularPositiveIncrementMean = 1.60
    private static let maximumGravityDeltaMagnitudeMAD = 0.060
    private static let highImpactScalarMean = 0.13
    private static let minimumHighImpactAliasFrequencyHz = 0.08
    private static let maximumHighImpactAliasFrequencyHz = 0.20
    /// The 2026-07-27 100-step physical holdout exposed a moderate-impact,
    /// slow-cadence regime where the lower alias carried 1.52x the power of
    /// the ordinary alias while the scalar remained below the high-impact
    /// threshold. Prior preserved walks remain below 1.09x. This comparison
    /// selects between two strap-observed aliases; it does not use HR, phone
    /// motion, distance, or the user's counted total.
    private static let minimumLowAliasToOrdinaryPowerRatio = 1.25
    /// A second, independently calibrated strap signal arbitrates aliases when
    /// the ordinary cadence/amplitude ensemble materially outruns the firmware
    /// motion counter. The counter is never published directly here; it only
    /// rejects an inflated alias choice. Eleven counted walks keep a stable
    /// boundary around 1.20 under one-row perturbation, while all arm controls
    /// continue to fail the locomotion classifier before this quantity stage.
    private static let minimumOrdinaryEstimateToCounterRatio = 1.20
    /// Physical V11 acceptance found a second slow-walk subharmonic: its
    /// ordinary-band peak was stronger, but the firmware motion coordinate
    /// advanced at nearly two ticks per second. Preserved ordinary-alias walks
    /// stay below 1.90 ticks/s unless their lower peak is already stronger.
    private static let minimumHighRateSubharmonicTickRate = 1.90
    private static let minimumHighRateSubharmonicPowerRatio = 0.40
    /// A lower-alias cadence may omit cycles at the interval boundary. Only a
    /// counter projection at least 20% above cadence has enough separation to
    /// replace it; otherwise cadence remains primary and the counter damps it.
    private static let minimumCounterToLowAliasCadenceRatio = 1.20
    /// The final 110-step slow walk exposed a low-amplitude regime whose
    /// ordinary alias and amplitude estimate both over-counted by 23%, while
    /// the lower strap-only cadence was within 3%. It is separated from the
    /// preserved 150-step ordinary-alias walk by independent firmware tick
    /// rate, gravity MAD, band share and scalar-amplitude margins.
    private static let minimumSoftGaitTickRate = 2.00
    private static let maximumSoftGaitGravityMAD = 0.030
    private static let minimumSoftGaitBandPowerShare = 0.28
    private static let maximumSoftGaitScalarMean = 0.105
    private static let maximumSoftGaitLowAliasPowerRatio = 1.10
    private static let maximumTickDeltaPerTransition = 16
    private static let maximumContinuousSampleGap: TimeInterval = 3
    private static let ordinaryGaitIdleGap: TimeInterval = 10
    private static let maximumGaitIdleGap: TimeInterval = 12
    private static let minimumResumeBatchFlatSeconds: TimeInterval = 5
    private static let minimumDominantBurstTickShare = 0.80
    /// Frozen from the two exact-boundary calibration walks. Motion volume is
    /// an independent strap-only estimate which damps cadence alias outliers.
    private static let stepsPerMotionVolume = 9.69448197

    /// Aligns one phone-wall workout to one continuous raw strap timeline.
    /// A single observed clock offset must govern the complete candidate;
    /// page-local corrections are never spliced together.
    static func estimateAlignedWindow(
        points: [Point],
        requestedStart: TimeInterval,
        requestedEnd: TimeInterval,
        clockOffsetByIdentity: [String: Int],
        boundaryTolerance: TimeInterval = 3
    ) -> AlignedEstimate? {
        guard requestedEnd > requestedStart,
              boundaryTolerance >= 0 else { return nil }
        let ordered = canonical(points)
        guard ordered.count >= 2 else { return nil }
        let offsets = Set(clockOffsetByIdentity.values)
        guard !offsets.isEmpty else { return nil }
        typealias Alignment = (
            offset: Int,
            first: Point,
            last: Point,
            firstIndex: Int,
            lastIndex: Int,
            coverage: Double,
            boundaryError: TimeInterval,
            support: Int
        )
        var candidates: [Alignment] = []
        for offset in offsets.sorted() {
            let rawStart = requestedStart - Double(offset)
            let rawEnd = requestedEnd - Double(offset)
            guard let first = ordered.min(by: {
                abs($0.timestamp - rawStart) < abs($1.timestamp - rawStart)
            }),
            let last = ordered.min(by: {
                abs($0.timestamp - rawEnd) < abs($1.timestamp - rawEnd)
            }),
            last.timestamp > first.timestamp,
            abs(first.timestamp - rawStart) <= boundaryTolerance,
            abs(last.timestamp - rawEnd) <= boundaryTolerance,
            let firstIndex = ordered.firstIndex(of: first),
            let lastIndex = ordered.firstIndex(of: last),
            lastIndex > firstIndex else {
                continue
            }
            let coverage = min(
                1,
                (last.timestamp - first.timestamp)
                    / (requestedEnd - requestedStart)
            )
            guard coverage >= 0.9 else { continue }
            candidates.append((
                offset,
                first,
                last,
                firstIndex,
                lastIndex,
                coverage,
                abs(first.timestamp - rawStart) + abs(last.timestamp - rawEnd),
                ordered[firstIndex...lastIndex].reduce(into: 0) {
                    count, point in
                    if clockOffsetByIdentity[point.identity] == offset {
                        count += 1
                    }
                }
            ))
        }
        guard let strongestSupport = candidates.map(\.support).max() else {
            return nil
        }
        let supported = candidates.filter { $0.support == strongestSupport }
        guard let bestBoundaryError = supported.map(\.boundaryError).min() else {
            return nil
        }
        let boundaryMatched = supported.filter {
            abs($0.boundaryError - bestBoundaryError) < 0.001
        }
        // Clock metadata must identify the physical window. If equally
        // supported offsets align distinct windows equally well, fail closed
        // rather than inspecting their motion to break the tie.
        guard boundaryMatched.count == 1,
              let selected = boundaryMatched.first,
              let estimate = estimateWindow(
                points: Array(ordered[selected.firstIndex...selected.lastIndex])
              ) else {
            return nil
        }
        return .init(
            clockOffsetSeconds: selected.offset,
            first: selected.first,
            last: selected.last,
            estimate: estimate,
            coverageFraction: selected.coverage,
            decodedRows: selected.lastIndex - selected.firstIndex + 1
        )
    }

    /// Estimates one already-bounded sustained walking interval. A flat counter
    /// returns zero; ambiguous/sparse motion returns nil rather than a number.
    static func estimateWindow(points: [Point]) -> Estimate? {
        var ordered = canonical(points)
        guard ordered.count >= 30,
              let first = ordered.first,
              let last = ordered.last else {
            return nil
        }
        let duration = last.timestamp - first.timestamp
        guard duration >= minimumDurationSeconds,
              duration.isFinite else {
            return nil
        }

        var motionTicks = 0
        var hasMotion = false
        for pair in zip(ordered, ordered.dropFirst()) {
            guard pair.1.timestamp - pair.0.timestamp
                    <= maximumContinuousSampleGap else {
                return nil
            }
            guard let delta = admittedTickDelta(from: pair.0, to: pair.1) else {
                return nil
            }
            motionTicks += delta
            hasMotion = hasMotion || delta > 0
        }
        guard hasMotion else {
            return .init(
                steps: 0,
                durationSeconds: duration,
                sampleRateHz: Double(ordered.count - 1) / duration,
                aliasFrequencyHz: 0,
                cadenceHz: 0,
                peakDominance: .infinity,
                motionTicks: 0,
                motionVolume: 0,
                cadenceOnlySteps: 0,
                motionVolumeSteps: 0,
                unresolvedMotionSeconds: 0
            )
        }

        guard let selected = dominantMotionWindow(from: ordered),
              let selectedFirst = selected.first,
              let selectedLast = selected.last else {
            return nil
        }
        ordered = selected
        let selectedDuration = selectedLast.timestamp - selectedFirst.timestamp
        guard selectedDuration >= minimumDurationSeconds,
              selectedDuration.isFinite else {
            return nil
        }
        motionTicks = 0
        for pair in zip(ordered, ordered.dropFirst()) {
            guard let delta = admittedTickDelta(
                from: pair.0,
                to: pair.1
            ) else {
                return nil
            }
            motionTicks += delta
        }

        let sampleRate = Double(ordered.count - 1) / selectedDuration
        guard sampleRate.isFinite,
              (minimumSampleRateHz...maximumSampleRateHz).contains(sampleRate) else {
            return nil
        }
        guard let gaitQualification =
                qualifiedOrdinaryBandPowerShare(points: ordered) else {
            return nil
        }
        let qualifiedOrdinaryBandPowerShare =
            gaitQualification.ordinaryBandPowerShare
        let scalarValues = ordered.compactMap(\.unknownMotionScalar32)
        guard scalarValues.count == ordered.count else { return nil }
        let meanScalar = scalarValues.reduce(0, +)
            / Double(scalarValues.count)
        let highImpactGait = meanScalar >= highImpactScalarMean
        let differences = zip(ordered, ordered.dropFirst()).map {
            (
                $1.gravityX - $0.gravityX,
                $1.gravityY - $0.gravityY,
                $1.gravityZ - $0.gravityZ
            )
        }
        let motionVolume = differences.reduce(0.0) { partial, value in
            partial + sqrt(
                value.0 * value.0
                    + value.1 * value.1
                    + value.2 * value.2
            )
        }
        let count = differences.count
        guard count >= 29 else { return nil }
        var spectrum: [(frequency: Double, power: Double)] = []
        for bin in 1...(count / 2) {
            let frequency = Double(bin) * sampleRate / Double(count)
            var power = 0.0
            for axis in 0..<3 {
                var real = 0.0
                var imaginary = 0.0
                for (index, difference) in differences.enumerated() {
                    let value: Double
                    switch axis {
                    case 0: value = difference.0
                    case 1: value = difference.1
                    default: value = difference.2
                    }
                    let phase = 2 * Double.pi * Double(bin)
                        * Double(index) / Double(count)
                    real += value * cos(phase)
                    imaginary -= value * sin(phase)
                }
                power += real * real + imaginary * imaginary
            }
            if power.isFinite {
                spectrum.append((frequency, power))
            }
        }
        let lowAliasCandidates = spectrum.filter {
            $0.frequency >= minimumHighImpactAliasFrequencyHz
                && $0.frequency <= min(
                    maximumHighImpactAliasFrequencyHz,
                    sampleRate / 2
                )
        }
        let ordinaryAliasCandidates = spectrum.filter {
            $0.frequency >= minimumAliasFrequencyHz
                && $0.frequency <= min(
                    maximumAliasFrequencyHz,
                    sampleRate / 2
                )
        }
        guard let lowAliasPeak = lowAliasCandidates.max(
            by: { $0.power < $1.power }
        ),
        let ordinaryAliasPeak = ordinaryAliasCandidates.max(
            by: { $0.power < $1.power }
        ),
        ordinaryAliasPeak.power > 0 else {
            return nil
        }
        let spectralLowAlias = shouldUseLowAlias(
            lowPower: lowAliasPeak.power,
            ordinaryPower: ordinaryAliasPeak.power
        )
        let ordinaryAliasCadenceSteps = Int(
            (
                (sampleRate + ordinaryAliasPeak.frequency)
                    * selectedDuration
            ).rounded()
        )
        let motionVolumeSteps = Int(
            (motionVolume * stepsPerMotionVolume).rounded()
        )
        let counterArbitratedLowAlias =
            shouldUseLowAliasForCounterConsistency(
                ordinaryCadenceSteps: ordinaryAliasCadenceSteps,
                motionVolumeSteps: motionVolumeSteps,
                motionTicks: motionTicks
            )
        let highRateSubharmonicLowAlias =
            shouldUseLowAliasForHighRateSubharmonic(
                lowPower: lowAliasPeak.power,
                ordinaryPower: ordinaryAliasPeak.power,
                gaitTickRate: Double(motionTicks) / selectedDuration
            )
        let lowAliasPowerRatio =
            lowAliasPeak.power / ordinaryAliasPeak.power
        let softGaitLowAlias = shouldUseLowAliasForSoftGait(
            lowAliasPowerRatio: lowAliasPowerRatio,
            gaitTickRate: gaitQualification.gaitTickRate,
            gravityDeltaMagnitudeMAD:
                gaitQualification.gravityDeltaMagnitudeMAD,
            ordinaryBandPowerShare:
                gaitQualification.ordinaryBandPowerShare,
            meanScalar: gaitQualification.meanScalar
        )
        let totalSpectrumPower = spectrum.reduce(0) { $0 + $1.power }
        guard totalSpectrumPower.isFinite,
              totalSpectrumPower > 0 else {
            return nil
        }
        let ordinaryBandPower = ordinaryAliasCandidates.reduce(0) {
            $0 + $1.power
        }
        _ = ordinaryBandPower
        let ordinaryAliasOverconcentrated =
            qualifiedOrdinaryBandPowerShare > 0.65
        let candidates = (
            highImpactGait
                || spectralLowAlias
                || ordinaryAliasOverconcentrated
                || counterArbitratedLowAlias
                || highRateSubharmonicLowAlias
                || softGaitLowAlias
        )
            ? lowAliasCandidates
            : ordinaryAliasCandidates
        guard let peak = candidates.max(by: { $0.power < $1.power }),
              peak.power > 0 else {
            return nil
        }
        let sortedPowers = candidates.map(\.power).sorted()
        let medianPower = sortedPowers[sortedPowers.count / 2]
        guard medianPower > 0 else { return nil }
        let dominance = peak.power / medianPower
        guard dominance.isFinite,
              dominance >= minimumPeakDominance else {
            return nil
        }

        // Normal walking cadence lies above the stored-vector sample rate. Its
        // first alias is therefore `sampleRate + observedFrequency` for the
        // physically qualified cadence range represented by this model.
        let cadence = sampleRate + peak.frequency
        let cadenceOnlySteps = Int((cadence * selectedDuration).rounded())
        // High-impact wrist motion makes gravity amplitude a poor step-count
        // input and can place the largest orientation peak in the ordinary
        // alias band. Once the independent v24 scalar proves that regime,
        // use its lower gait alias and cadence only; never reward amplitude.
        let steps: Int
        if highImpactGait || ordinaryAliasOverconcentrated {
            steps = cadenceOnlySteps
        } else if softGaitLowAlias
                    && !spectralLowAlias
                    && !counterArbitratedLowAlias
                    && !highRateSubharmonicLowAlias {
            // In this low-amplitude high-rate regime both the firmware counter
            // and motion volume are inflated. The independently selected lower
            // spectral cadence is the only accepted quantity.
            steps = cadenceOnlySteps
        } else if spectralLowAlias
                    || counterArbitratedLowAlias
                    || highRateSubharmonicLowAlias
                    || softGaitLowAlias {
            guard let corrected = spectralLowAliasSteps(
                cadenceSteps: cadenceOnlySteps,
                motionTicks: motionTicks
            ) else {
                return nil
            }
            steps = corrected
        } else {
            steps = Int(
                (
                    Double(cadenceOnlySteps) * 2 / 3
                        + Double(motionVolumeSteps) / 3
                ).rounded()
            )
        }
        guard steps > 0,
              Double(steps) <= selectedDuration * 3.5 else {
            return nil
        }
        return .init(
            steps: steps,
            durationSeconds: selectedDuration,
            sampleRateHz: sampleRate,
            aliasFrequencyHz: peak.frequency,
            cadenceHz: cadence,
            peakDominance: dominance,
            motionTicks: motionTicks,
            motionVolume: motionVolume,
            cadenceOnlySteps: cadenceOnlySteps,
            motionVolumeSteps: motionVolumeSteps,
            unresolvedMotionSeconds: 0
        )
    }

    static func shouldUseLowAlias(
        lowPower: Double,
        ordinaryPower: Double
    ) -> Bool {
        lowPower.isFinite
            && ordinaryPower.isFinite
            && ordinaryPower > 0
            && lowPower / ordinaryPower
                >= minimumLowAliasToOrdinaryPowerRatio
    }

    static func shouldUseLowAliasForCounterConsistency(
        ordinaryCadenceSteps: Int,
        motionVolumeSteps: Int,
        motionTicks: Int
    ) -> Bool {
        guard ordinaryCadenceSteps > 0,
              motionVolumeSteps >= 0,
              let counterSteps =
                AtriaWhoop4MotionTickStepModel.publishedSteps(
                    motionTicks: motionTicks,
                    validation:
                        AtriaWhoop4MotionTickStepModel
                            .physicallyValidatedWhoop4V24
                ),
              counterSteps > 0 else {
            return false
        }
        let ordinaryEstimate = Int(
            (
                Double(ordinaryCadenceSteps) * 2 / 3
                    + Double(motionVolumeSteps) / 3
            ).rounded()
        )
        return Double(ordinaryEstimate)
            >= Double(counterSteps) * minimumOrdinaryEstimateToCounterRatio
    }

    static func shouldUseLowAliasForHighRateSubharmonic(
        lowPower: Double,
        ordinaryPower: Double,
        gaitTickRate: Double
    ) -> Bool {
        lowPower.isFinite
            && ordinaryPower.isFinite
            && gaitTickRate.isFinite
            && lowPower >= 0
            && ordinaryPower > 0
            && lowPower < ordinaryPower
            && lowPower / ordinaryPower
                >= minimumHighRateSubharmonicPowerRatio
            && gaitTickRate >= minimumHighRateSubharmonicTickRate
    }

    static func shouldUseLowAliasForSoftGait(
        lowAliasPowerRatio: Double,
        gaitTickRate: Double,
        gravityDeltaMagnitudeMAD: Double,
        ordinaryBandPowerShare: Double,
        meanScalar: Double
    ) -> Bool {
        lowAliasPowerRatio.isFinite
            && gaitTickRate.isFinite
            && gravityDeltaMagnitudeMAD.isFinite
            && ordinaryBandPowerShare.isFinite
            && meanScalar.isFinite
            && gaitTickRate >= minimumSoftGaitTickRate
            && gravityDeltaMagnitudeMAD <= maximumSoftGaitGravityMAD
            && ordinaryBandPowerShare >= minimumSoftGaitBandPowerShare
            && meanScalar <= maximumSoftGaitScalarMean
            && lowAliasPowerRatio
                >= minimumHighRateSubharmonicPowerRatio
            && lowAliasPowerRatio
                <= maximumSoftGaitLowAliasPowerRatio
    }

    static func spectralLowAliasSteps(
        cadenceSteps: Int,
        motionTicks: Int
    ) -> Int? {
        guard cadenceSteps > 0,
              let tickSteps =
                AtriaWhoop4MotionTickStepModel.publishedSteps(
                    motionTicks: motionTicks,
                    validation:
                        AtriaWhoop4MotionTickStepModel
                            .physicallyValidatedWhoop4V24
        ) else {
            return nil
        }
        // The lower spectral alias is a lower-bound cadence candidate. When
        // the independently calibrated firmware motion coordinate projects
        // above it, the cadence alias demonstrably omitted cycles; retain the
        // counter projection instead of averaging the miss back in.
        if Double(tickSteps) / Double(cadenceSteps)
                >= minimumCounterToLowAliasCadenceRatio {
            return tickSteps
        }
        // Cadence remains the primary quantity. The cumulative strap counter
        // damps the lower alias's boundary error without letting wrist
        // amplitude inflate the result.
        return Int(
            (
                Double(cadenceSteps) * 2 / 3
                    + Double(tickSteps) / 3
            ).rounded()
        )
    }

    /// Qualifies the counter-active portion as gait without phone motion,
    /// location, distance, HR, or a user-entered step total. A rhythmic arm
    /// swing has a narrow, strongly repeating difference spectrum; physical
    /// walking is less concentrated and has low lag-two correlation.
    private struct GaitQualification {
        let ordinaryBandPowerShare: Double
        let gravityDeltaMagnitudeMAD: Double
        let meanScalar: Double
        let gaitTickRate: Double
    }

    private static func qualifiedOrdinaryBandPowerShare(
        points: [Point]
    ) -> GaitQualification? {
        guard points.count >= 4 else { return nil }
        var positiveIndices: [Int] = []
        var motionTicks = 0
        var regularPositiveIncrements: [Int] = []
        var lastPositiveTimestamp: TimeInterval?
        for index in 1..<points.count {
            let gap = points[index].timestamp - points[index - 1].timestamp
            guard gap > 0,
                  gap <= maximumContinuousSampleGap,
                  let delta = admittedTickDelta(
                    from: points[index - 1],
                    to: points[index]
                  ) else {
                return nil
            }
            if delta > 0 {
                let flatSeconds = points[index].timestamp
                    - (lastPositiveTimestamp ?? points[0].timestamp)
                if (1...4).contains(delta) {
                    regularPositiveIncrements.append(delta)
                } else if !(
                    isResumeBatch(
                        delta: delta,
                        flatSeconds: flatSeconds
                    )
                    || (
                        lastPositiveTimestamp == nil
                            && (11...13).contains(delta)
                    )
                ) {
                    return nil
                }
                positiveIndices.append(index)
                motionTicks += delta
                lastPositiveTimestamp = points[index].timestamp
            }
        }
        guard let firstPositive = positiveIndices.first,
              let lastPositive = positiveIndices.last,
              regularPositiveIncrements.count
                >= minimumRegularPositiveIncrementCount else {
            return nil
        }
        for pair in zip(positiveIndices, positiveIndices.dropFirst()) {
            let gap = points[pair.1].timestamp
                - points[pair.0].timestamp
            let resumedDelta = admittedTickDelta(
                from: points[pair.1 - 1],
                to: points[pair.1]
            )
            guard motionBurstContinues(
                gap: gap,
                resumedDelta: resumedDelta
            ) else {
                return nil
            }
        }
        let regularPositiveIncrementMean =
            Double(regularPositiveIncrements.reduce(0, +))
                / Double(regularPositiveIncrements.count)
        guard regularPositiveIncrementMean
                >= minimumRegularPositiveIncrementMean else {
            return nil
        }
        let active = Array(points[max(0, firstPositive - 1)...lastPositive])
        guard let first = active.first,
              let last = active.last else { return nil }
        let duration = last.timestamp - first.timestamp
        guard duration >= minimumDurationSeconds,
              duration.isFinite else {
            return nil
        }
        let sampleRate = Double(active.count - 1) / duration
        let tickRate = Double(motionTicks) / duration
        guard (minimumSampleRateHz...maximumSampleRateHz).contains(sampleRate),
              tickRate >= minimumGaitTickRate else {
            return nil
        }

        let differences = zip(active, active.dropFirst()).map {
            [
                $1.gravityX - $0.gravityX,
                $1.gravityY - $0.gravityY,
                $1.gravityZ - $0.gravityZ,
            ]
        }
        let count = differences.count
        guard count > 3 else { return nil }
        let scalars = active.compactMap(\.unknownMotionScalar32)
        guard scalars.count == active.count,
              scalars.allSatisfy({
                  $0.isFinite && (0...8).contains($0)
              }) else {
            return nil
        }
        let meanScalar = scalars.reduce(0, +) / Double(scalars.count)
        let meanGravityDelta = differences.reduce(0.0) {
            $0 + sqrt(
                $1[0] * $1[0] + $1[1] * $1[1] + $1[2] * $1[2]
            )
        } / Double(differences.count)
        guard meanScalar.isFinite,
              meanGravityDelta.isFinite,
              meanGravityDelta > 0 else {
            return nil
        }
        let gravityDeltaMagnitudes = differences.map {
            sqrt($0[0] * $0[0] + $0[1] * $0[1] + $0[2] * $0[2])
        }
        let gravityDeltaMedian = median(gravityDeltaMagnitudes)
        let gravityDeltaMagnitudeMAD = median(
            gravityDeltaMagnitudes.map { abs($0 - gravityDeltaMedian) }
        )
        guard gravityDeltaMagnitudeMAD.isFinite,
              gravityDeltaMagnitudeMAD
                <= maximumGravityDeltaMagnitudeMAD else {
            return nil
        }
        let binCount = count / 2
        guard binCount > 1 else { return nil }
        var powers: [(frequency: Double, power: Double)] = []
        for bin in 1...binCount {
            var power = 0.0
            for axis in 0..<3 {
                var real = 0.0
                var imaginary = 0.0
                for (index, difference) in differences.enumerated() {
                    let phase = 2 * Double.pi * Double(bin)
                        * Double(index) / Double(count)
                    real += difference[axis] * cos(phase)
                    imaginary -= difference[axis] * sin(phase)
                }
                power += real * real + imaginary * imaginary
            }
            guard power.isFinite else { return nil }
            powers.append((
                Double(bin) * sampleRate / Double(count),
                power
            ))
        }
        let totalPower = powers.reduce(0) { $0 + $1.power }
        guard totalPower.isFinite, totalPower > 0 else { return nil }
        let upperBand = min(maximumAliasFrequencyHz, sampleRate / 2)
        let bandPower = powers.reduce(0.0) {
            guard $1.frequency >= minimumAliasFrequencyHz,
                  $1.frequency <= upperBand else {
                return $0
            }
            return $0 + $1.power
        }
        let bandPowerShare = bandPower / totalPower
        let entropy = -powers.reduce(0.0) {
            let probability = $1.power / totalPower
            guard probability > 0 else { return $0 }
            return $0 + probability * log(probability)
        } / log(Double(binCount))

        let lag = 2
        let pairedCount = differences.count - lag
        guard pairedCount > 0 else { return nil }
        var firstMeans = [Double](repeating: 0, count: 3)
        var secondMeans = [Double](repeating: 0, count: 3)
        for index in 0..<pairedCount {
            for axis in 0..<3 {
                firstMeans[axis] += differences[index][axis]
                secondMeans[axis] += differences[index + lag][axis]
            }
        }
        firstMeans = firstMeans.map { $0 / Double(pairedCount) }
        secondMeans = secondMeans.map { $0 / Double(pairedCount) }
        var covariance = 0.0
        var firstEnergy = 0.0
        var secondEnergy = 0.0
        for index in 0..<pairedCount {
            for axis in 0..<3 {
                let firstValue = differences[index][axis] - firstMeans[axis]
                let secondValue =
                    differences[index + lag][axis] - secondMeans[axis]
                covariance += firstValue * secondValue
                firstEnergy += firstValue * firstValue
                secondEnergy += secondValue * secondValue
            }
        }
        let denominator = sqrt(firstEnergy * secondEnergy)
        guard denominator.isFinite, denominator > 0 else { return nil }
        let lagTwoAutocorrelation = covariance / denominator
        // The firmware-counter transition texture is the physically observed
        // locomotion discriminator. Band concentration, lag-two correlation,
        // and scalar amplitude are retained above for cadence/impact
        // diagnostics, but real counted walks disproved them as mandatory
        // gait gates.
        _ = bandPowerShare
        _ = lagTwoAutocorrelation
        guard entropy >= minimumGaitSpectralEntropy else { return nil }
        return .init(
            ordinaryBandPowerShare: bandPowerShare,
            gravityDeltaMagnitudeMAD: gravityDeltaMagnitudeMAD,
            meanScalar: meanScalar,
            gaitTickRate: tickRate
        )
    }

    /// Splits a covered day into sustained motion bursts. Any counter-active
    /// burst which cannot support cadence estimation makes the subtotal
    /// unavailable; silently dropping short walks would under-count the day.
    static func estimateCoveredActivity(points: [Point]) -> Estimate? {
        let ordered = canonical(points)
        guard ordered.count >= 2 else { return nil }
        var activeTransitionIndices: [Int] = []
        var unresolvedMotionSeconds: TimeInterval = 0
        for index in 1..<ordered.count {
            let sampleGap = ordered[index].timestamp
                - ordered[index - 1].timestamp
            guard sampleGap > 0 else { return nil }
            if sampleGap > maximumContinuousSampleGap {
                if ordered[index].tick != ordered[index - 1].tick {
                    unresolvedMotionSeconds += sampleGap
                }
                continue
            }
            guard let delta = admittedTickDelta(
                from: ordered[index - 1],
                to: ordered[index]
            ) else {
                return nil
            }
            if delta > 0 {
                activeTransitionIndices.append(index)
            }
        }
        guard !activeTransitionIndices.isEmpty else {
            let duration = ordered.last!.timestamp - ordered.first!.timestamp
            return .init(
                steps: 0,
                durationSeconds: duration,
                sampleRateHz: Double(ordered.count - 1) / max(1, duration),
                aliasFrequencyHz: 0,
                cadenceHz: 0,
                peakDominance: .infinity,
                motionTicks: 0,
                motionVolume: 0,
                cadenceOnlySteps: 0,
                motionVolumeSteps: 0,
                unresolvedMotionSeconds: 0
            )
        }

        var ranges: [ClosedRange<Int>] = []
        var rangeStart = max(0, activeTransitionIndices[0] - 1)
        var lastActive = activeTransitionIndices[0]
        for index in activeTransitionIndices.dropFirst() {
            let gap = ordered[index].timestamp
                - ordered[lastActive].timestamp
            let resumedDelta = admittedTickDelta(
                from: ordered[index - 1],
                to: ordered[index]
            )
            if !motionBurstContinues(
                gap: gap,
                resumedDelta: resumedDelta
            ) {
                ranges.append(rangeStart...lastActive)
                rangeStart = max(0, index - 1)
            }
            lastActive = index
        }
        ranges.append(rangeStart...lastActive)

        var estimates: [Estimate] = []
        for range in ranges {
            guard let estimate = estimateWindow(
                points: Array(ordered[range])
            ) else {
                unresolvedMotionSeconds += max(
                    0,
                    ordered[range.upperBound].timestamp
                        - ordered[range.lowerBound].timestamp
                )
                continue
            }
            estimates.append(estimate)
        }
        // An interval with only short or otherwise unqualified motion bursts
        // is still useful day evidence: its stationary seconds prove zero
        // steps, while only the counter-active burst remains unresolved.
        // Returning nil here previously made the daily projector mark the
        // complete bank interval unresolved, reducing qualified coverage to
        // zero and preventing an honest partial receipt from being saved.
        guard !estimates.isEmpty else {
            let duration = ordered.last!.timestamp - ordered.first!.timestamp
            guard duration > 0, duration.isFinite else { return nil }
            return .init(
                steps: 0,
                durationSeconds: duration,
                sampleRateHz: Double(ordered.count - 1) / duration,
                aliasFrequencyHz: 0,
                cadenceHz: 0,
                peakDominance: 0,
                motionTicks: 0,
                motionVolume: 0,
                cadenceOnlySteps: 0,
                motionVolumeSteps: 0,
                unresolvedMotionSeconds: min(
                    duration,
                    unresolvedMotionSeconds
                )
            )
        }
        let totalDuration = estimates.reduce(0) { $0 + $1.durationSeconds }
        let totalSteps = estimates.reduce(0) { $0 + $1.steps }
        let totalTicks = estimates.reduce(0) { $0 + $1.motionTicks }
        let totalMotionVolume = estimates.reduce(0) {
            $0 + $1.motionVolume
        }
        let totalCadenceOnlySteps = estimates.reduce(0) {
            $0 + $1.cadenceOnlySteps
        }
        let totalMotionVolumeSteps = estimates.reduce(0) {
            $0 + $1.motionVolumeSteps
        }
        guard totalDuration > 0 else { return nil }
        return .init(
            steps: totalSteps,
            durationSeconds: totalDuration,
            sampleRateHz: estimates.reduce(0) {
                $0 + $1.sampleRateHz * $1.durationSeconds
            } / totalDuration,
            aliasFrequencyHz: estimates.reduce(0) {
                $0 + $1.aliasFrequencyHz * $1.durationSeconds
            } / totalDuration,
            cadenceHz: Double(totalSteps) / totalDuration,
            peakDominance: estimates.map(\.peakDominance).min() ?? 0,
            motionTicks: totalTicks,
            motionVolume: totalMotionVolume,
            cadenceOnlySteps: totalCadenceOnlySteps,
            motionVolumeSteps: totalMotionVolumeSteps,
            unresolvedMotionSeconds: unresolvedMotionSeconds
        )
    }

    private static func canonical(_ points: [Point]) -> [Point] {
        var byFlash: [UInt32: Point] = [:]
        for point in points where point.timestamp.isFinite
            && point.gravityX.isFinite
            && point.gravityY.isFinite
            && point.gravityZ.isFinite
            && point.tick >= 0
            && point.tick < 65_536 {
            if let existing = byFlash[point.flash],
               existing != point {
                return []
            }
            byFlash[point.flash] = point
        }
        return byFlash.values.sorted {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            if $0.flash != $1.flash { return $0.flash < $1.flash }
            return $0.identity < $1.identity
        }
    }

    /// A manual workout can begin before the active screen is visible. A tiny
    /// setup-motion cluster followed by rest must not invalidate the sustained
    /// walk that owns nearly all counter movement. Retain the exact workout for
    /// clock/coverage proof, but score one uniquely dominant counter burst with
    /// at most ten seconds of strap-only pre/post roll. Balanced stop/start
    /// efforts still fail closed instead of silently dropping activity.
    private static func dominantMotionWindow(
        from points: [Point]
    ) -> [Point]? {
        struct Transition {
            let index: Int
            let ticks: Int
        }
        var positive: [Transition] = []
        for index in 1..<points.count {
            guard let delta = admittedTickDelta(
                from: points[index - 1],
                to: points[index]
            ) else {
                return nil
            }
            if delta > 0 {
                positive.append(.init(index: index, ticks: delta))
            }
        }
        guard !positive.isEmpty else { return nil }
        var clusters: [[Transition]] = [[positive[0]]]
        for transition in positive.dropFirst() {
            guard let prior = clusters.last?.last else { return nil }
            let gap = points[transition.index].timestamp
                - points[prior.index].timestamp
            if !motionBurstContinues(
                gap: gap,
                resumedDelta: transition.ticks
            ) {
                clusters.append([transition])
            } else {
                clusters[clusters.count - 1].append(transition)
            }
        }
        guard clusters.count > 1 else { return points }
        let totals = clusters.map { cluster in
            cluster.reduce(0) { $0 + $1.ticks }
        }
        guard let maximum = totals.max(),
              totals.filter({ $0 == maximum }).count == 1,
              let dominantIndex = totals.firstIndex(of: maximum) else {
            return nil
        }
        let total = totals.reduce(0, +)
        guard total > 0,
              Double(maximum) / Double(total)
                >= minimumDominantBurstTickShare,
              let firstTransition = clusters[dominantIndex].first,
              let lastTransition = clusters[dominantIndex].last else {
            return nil
        }

        let startTarget = points[firstTransition.index].timestamp
            - maximumGaitIdleGap
        let endTarget = points[lastTransition.index].timestamp
            + maximumGaitIdleGap
        var lower = max(0, firstTransition.index - 1)
        while lower > 0,
              points[lower - 1].timestamp >= startTarget {
            lower -= 1
        }
        var upper = lastTransition.index
        while upper + 1 < points.count,
              points[upper + 1].timestamp <= endTarget {
            upper += 1
        }
        return Array(points[lower...upper])
    }

    private static func isResumeBatch(
        delta: Int,
        flatSeconds: TimeInterval
    ) -> Bool {
        (11...13).contains(delta)
            && flatSeconds >= minimumResumeBatchFlatSeconds
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let ordered = values.sorted()
        let middle = ordered.count / 2
        if ordered.count.isMultiple(of: 2) {
            return (ordered[middle - 1] + ordered[middle]) / 2
        }
        return ordered[middle]
    }

    private static func motionBurstContinues(
        gap: TimeInterval,
        resumedDelta: Int?
    ) -> Bool {
        guard gap <= maximumGaitIdleGap else { return false }
        if gap <= ordinaryGaitIdleGap { return true }
        guard let resumedDelta else { return false }
        return isResumeBatch(
            delta: resumedDelta,
            flatSeconds: gap
        )
    }

    private static func admittedTickDelta(
        from previous: Point,
        to current: Point
    ) -> Int? {
        let flashDelta = current.flash >= previous.flash
            ? UInt64(current.flash - previous.flash)
            : UInt64(current.flash) + UInt64(UInt32.max)
                - UInt64(previous.flash) + 1
        guard flashDelta > 0,
              current.timestamp > previous.timestamp else {
            return nil
        }
        let delta = current.tick >= previous.tick
            ? current.tick - previous.tick
            : current.tick + 65_536 - previous.tick
        guard delta <= maximumTickDeltaPerTransition else { return nil }
        return delta
    }
}
