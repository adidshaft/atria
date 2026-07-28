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
    static let algorithmVersion = "whoop4-impact-gait-ensemble-v15"

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
    /// A daily walk is commonly split into short firmware-counter bursts even
    /// when the person never starts a workout. Two independently counted
    /// charger-free walks and a planted-feet arm-swing control provide a
    /// conservative short-burst lane. It is deliberately a lower bound: the
    /// 1 Hz v24 bank cannot resolve every footfall, so only low-scalar,
    /// gait-textured bursts are admitted and their counter is divided by a
    /// ratio above every accepted calibration walk.
    private static let minimumShortBurstDurationSeconds: TimeInterval = 10
    private static let maximumShortBurstDurationSeconds: TimeInterval = 30
    private static let minimumShortBurstSampleCount = 10
    private static let minimumShortBurstGaitTickRate = 1.40
    private static let minimumShortBurstRegularIncrementCount = 6
    private static let minimumShortBurstRegularIncrementMean = 1.40
    private static let maximumShortBurstGravityDeltaMagnitudeMAD = 0.120
    private static let maximumShortBurstScalarMean = 0.140
    private static let conservativeShortBurstTicksPerStep = 1.30
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
        estimateQualifiedWindow(
            points: points,
            policy: .sustained,
            selectDominantMotionWindow: true
        )
    }

    /// Shared cadence/alias quantity path. Autonomous day reconstruction may
    /// supply a gait-qualified bout assembled from overlapping strap-only
    /// anchors; exact workout scoring retains the stricter sustained policy.
    private static func estimateQualifiedWindow(
        points: [Point],
        policy: GaitQualificationPolicy,
        selectDominantMotionWindow: Bool
    ) -> Estimate? {
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

        let selected: [Point]
        if selectDominantMotionWindow {
            guard let dominant = dominantMotionWindow(from: ordered) else {
                return nil
            }
            selected = dominant
        } else {
            selected = ordered
        }
        guard let selectedFirst = selected.first,
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
                qualifiedOrdinaryBandPowerShare(
                    points: ordered,
                    policy: policy
                ) else {
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
                gaitTickRate: gaitQualification.gaitTickRate
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
        let motionTicks: Int
        let durationSeconds: TimeInterval
        let motionVolume: Double
        let spectralEntropy: Double
    }

    private struct GaitQualificationPolicy {
        let minimumDurationSeconds: TimeInterval
        let maximumDurationSeconds: TimeInterval?
        let minimumRegularPositiveIncrementCount: Int
        let minimumRegularPositiveIncrementMean: Double
        let minimumGaitTickRate: Double
        let maximumGravityDeltaMagnitudeMAD: Double
        let minimumSpectralEntropy: Double
        let maximumScalarMean: Double?
        let includeFullWindow: Bool
        let maximumPositiveTransitionGap: TimeInterval
        let maximumStationaryGravityRunSeconds: TimeInterval?
        let requiresResumeBatchAfterOrdinaryGap: Bool
        let requiresValidatedIncrementTexture: Bool

        static let sustained = Self(
            minimumDurationSeconds:
                AtriaWhoop4GravityCadenceStepModel.minimumDurationSeconds,
            maximumDurationSeconds: nil,
            minimumRegularPositiveIncrementCount:
                AtriaWhoop4GravityCadenceStepModel
                    .minimumRegularPositiveIncrementCount,
            minimumRegularPositiveIncrementMean:
                AtriaWhoop4GravityCadenceStepModel
                    .minimumRegularPositiveIncrementMean,
            minimumGaitTickRate:
                AtriaWhoop4GravityCadenceStepModel.minimumGaitTickRate,
            maximumGravityDeltaMagnitudeMAD:
                AtriaWhoop4GravityCadenceStepModel
                    .maximumGravityDeltaMagnitudeMAD,
            minimumSpectralEntropy:
                AtriaWhoop4GravityCadenceStepModel
                    .minimumGaitSpectralEntropy,
            maximumScalarMean: nil,
            includeFullWindow: false,
            maximumPositiveTransitionGap:
                AtriaWhoop4GravityCadenceStepModel.maximumGaitIdleGap,
            maximumStationaryGravityRunSeconds: nil,
            requiresResumeBatchAfterOrdinaryGap: true,
            requiresValidatedIncrementTexture: true
        )

        static let short = Self(
            minimumDurationSeconds:
                AtriaWhoop4GravityCadenceStepModel
                    .minimumShortBurstDurationSeconds,
            maximumDurationSeconds:
                AtriaWhoop4GravityCadenceStepModel
                    .maximumShortBurstDurationSeconds,
            minimumRegularPositiveIncrementCount:
                AtriaWhoop4GravityCadenceStepModel
                    .minimumShortBurstRegularIncrementCount,
            minimumRegularPositiveIncrementMean:
                AtriaWhoop4GravityCadenceStepModel
                    .minimumShortBurstRegularIncrementMean,
            minimumGaitTickRate:
                AtriaWhoop4GravityCadenceStepModel
                    .minimumShortBurstGaitTickRate,
            maximumGravityDeltaMagnitudeMAD:
                AtriaWhoop4GravityCadenceStepModel
                    .maximumShortBurstGravityDeltaMagnitudeMAD,
            minimumSpectralEntropy:
                AtriaWhoop4GravityCadenceStepModel
                    .minimumGaitSpectralEntropy,
            maximumScalarMean:
                AtriaWhoop4GravityCadenceStepModel
                    .maximumShortBurstScalarMean,
            includeFullWindow: true,
            maximumPositiveTransitionGap:
                AtriaWhoop4GravityCadenceStepModel.maximumGaitIdleGap,
            maximumStationaryGravityRunSeconds: nil,
            requiresResumeBatchAfterOrdinaryGap: true,
            requiresValidatedIncrementTexture: true
        )

        /// Local day-only gait proof. A 32-second overlapping anchor needs
        /// enough regular firmware transitions to prove locomotion, while
        /// retaining the physical walk/control gravity and entropy margins.
        static let autonomousAnchor = Self(
            minimumDurationSeconds: 36,
            maximumDurationSeconds: 50,
            minimumRegularPositiveIncrementCount: 3,
            minimumRegularPositiveIncrementMean:
                AtriaWhoop4GravityCadenceStepModel
                    .minimumRegularPositiveIncrementMean,
            minimumGaitTickRate: 0.15,
            maximumGravityDeltaMagnitudeMAD:
                AtriaWhoop4GravityCadenceStepModel
                    .maximumShortBurstGravityDeltaMagnitudeMAD,
            minimumSpectralEntropy: 0.65,
            maximumScalarMean: nil,
            includeFullWindow: true,
            maximumPositiveTransitionGap: 48,
            maximumStationaryGravityRunSeconds: 10,
            requiresResumeBatchAfterOrdinaryGap: false,
            requiresValidatedIncrementTexture: false
        )

        /// Whole-bout proof after overlapping anchors establish continuous
        /// gait on both sides of a firmware batching pause. This widens only
        /// the positive-transition cadence, never the raw sample continuity.
        static let autonomousBout = Self(
            minimumDurationSeconds:
                AtriaWhoop4GravityCadenceStepModel.minimumDurationSeconds,
            maximumDurationSeconds: nil,
            minimumRegularPositiveIncrementCount: 3,
            minimumRegularPositiveIncrementMean:
                AtriaWhoop4GravityCadenceStepModel
                    .minimumRegularPositiveIncrementMean,
            minimumGaitTickRate: 0.15,
            maximumGravityDeltaMagnitudeMAD:
                AtriaWhoop4GravityCadenceStepModel
                    .maximumShortBurstGravityDeltaMagnitudeMAD,
            minimumSpectralEntropy: 0.65,
            maximumScalarMean: nil,
            includeFullWindow: true,
            maximumPositiveTransitionGap: 48,
            maximumStationaryGravityRunSeconds: 10,
            requiresResumeBatchAfterOrdinaryGap: false,
            requiresValidatedIncrementTexture: false
        )
    }

    private static func qualifiedOrdinaryBandPowerShare(
        points: [Point],
        policy: GaitQualificationPolicy
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
                    guard !policy.requiresValidatedIncrementTexture else {
                        return nil
                    }
                    regularPositiveIncrements.append(delta)
                }
                positiveIndices.append(index)
                motionTicks += delta
                lastPositiveTimestamp = points[index].timestamp
            }
        }
        guard let firstPositive = positiveIndices.first,
              let lastPositive = positiveIndices.last,
              regularPositiveIncrements.count
                >= policy.minimumRegularPositiveIncrementCount else {
            return nil
        }
        for pair in zip(positiveIndices, positiveIndices.dropFirst()) {
            let gap = points[pair.1].timestamp
                - points[pair.0].timestamp
            let resumedDelta = admittedTickDelta(
                from: points[pair.1 - 1],
                to: points[pair.1]
            )
            guard gap <= policy.maximumPositiveTransitionGap else {
                return nil
            }
            if policy.requiresResumeBatchAfterOrdinaryGap,
               !motionBurstContinues(
                   gap: gap,
                   resumedDelta: resumedDelta
               ) {
                return nil
            }
        }
        let regularPositiveIncrementMean =
            Double(regularPositiveIncrements.reduce(0, +))
                / Double(regularPositiveIncrements.count)
        guard regularPositiveIncrementMean
                >= policy.minimumRegularPositiveIncrementMean else {
            return nil
        }
        let active = policy.includeFullWindow
            ? points
            : Array(points[max(0, firstPositive - 1)...lastPositive])
        guard let first = active.first,
              let last = active.last else { return nil }
        let duration = last.timestamp - first.timestamp
        guard duration >= policy.minimumDurationSeconds,
              policy.maximumDurationSeconds.map({
                  duration < $0
              }) ?? true,
              duration.isFinite else {
            return nil
        }
        let sampleRate = Double(active.count - 1) / duration
        let tickRate = Double(motionTicks) / duration
        guard (minimumSampleRateHz...maximumSampleRateHz).contains(sampleRate),
              tickRate >= policy.minimumGaitTickRate else {
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
        guard policy.maximumScalarMean.map({
            meanScalar <= $0
        }) ?? true else {
            return nil
        }
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
        if let maximumStationaryGravityRunSeconds =
            policy.maximumStationaryGravityRunSeconds {
            var stationaryRun: TimeInterval = 0
            for index in 1..<active.count {
                let gap = active[index].timestamp
                    - active[index - 1].timestamp
                if gravityDeltaMagnitudes[index - 1] <= 0.005 {
                    stationaryRun += gap
                    guard stationaryRun
                            <= maximumStationaryGravityRunSeconds else {
                        return nil
                    }
                } else {
                    stationaryRun = 0
                }
            }
        }
        let motionVolume = gravityDeltaMagnitudes.reduce(0, +)
        let gravityDeltaMedian = median(gravityDeltaMagnitudes)
        let gravityDeltaMagnitudeMAD = median(
            gravityDeltaMagnitudes.map { abs($0 - gravityDeltaMedian) }
        )
        guard gravityDeltaMagnitudeMAD.isFinite,
              gravityDeltaMagnitudeMAD
                <= policy.maximumGravityDeltaMagnitudeMAD else {
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
        guard entropy >= policy.minimumSpectralEntropy else { return nil }
        return .init(
            ordinaryBandPowerShare: bandPowerShare,
            gravityDeltaMagnitudeMAD: gravityDeltaMagnitudeMAD,
            meanScalar: meanScalar,
            gaitTickRate: tickRate,
            motionTicks: motionTicks,
            durationSeconds: duration,
            motionVolume: motionVolume,
            spectralEntropy: entropy
        )
    }

    /// Conservative lower-bound estimator for ordinary all-day walking bursts
    /// that are too short for cadence-frequency selection. The count remains
    /// WHOOP-only: no phone motion, distance, GPS, HR, or extrapolation enters
    /// this path. Rejected motion stays unresolved and therefore visible as
    /// partial coverage.
    static func estimateShortQualifiedBurst(points: [Point]) -> Estimate? {
        let ordered = canonical(points)
        guard ordered.count >= minimumShortBurstSampleCount,
              let first = ordered.first,
              let last = ordered.last else {
            return nil
        }
        let duration = last.timestamp - first.timestamp
        guard duration >= minimumShortBurstDurationSeconds,
              duration < maximumShortBurstDurationSeconds,
              duration.isFinite,
              let qualification = qualifiedOrdinaryBandPowerShare(
                  points: ordered,
                  policy: .short
              ) else {
            return nil
        }
        let steps = Int(
            floor(
                Double(qualification.motionTicks)
                    / conservativeShortBurstTicksPerStep
            )
        )
        guard steps > 0 else { return nil }
        return .init(
            steps: steps,
            durationSeconds: qualification.durationSeconds,
            sampleRateHz: Double(ordered.count - 1) / duration,
            aliasFrequencyHz: 0,
            cadenceHz: Double(steps) / qualification.durationSeconds,
            peakDominance: qualification.spectralEntropy,
            motionTicks: qualification.motionTicks,
            motionVolume: qualification.motionVolume,
            cadenceOnlySteps: 0,
            motionVolumeSteps: 0,
            unresolvedMotionSeconds: 0
        )
    }

    /// Reconstructs ordinary day walking from overlapping v24 gait anchors.
    ///
    /// The firmware may batch its motion coordinate for 10–18 seconds while
    /// gravity continues at the normal one-second cadence. Treating every
    /// positive-counter pause as an activity boundary destroys an otherwise
    /// complete walk. Local anchors first prove gait independently, then only
    /// overlapping anchors may form a bout. Raw sample gaps are never crossed,
    /// and the existing cadence/alias estimator owns the resulting quantity.
    private static func autonomousGaitBouts(
        in ordered: [Point]
    ) -> [(range: ClosedRange<Int>, estimate: Estimate)] {
        let anchorDuration: TimeInterval = 48
        let anchorStride: TimeInterval = 8
        let boundarySearch: TimeInterval = 12
        guard ordered.count >= 25,
              let first = ordered.first,
              let last = ordered.last,
              last.timestamp > first.timestamp else {
            return []
        }

        var anchors: [ClosedRange<Int>] = []
        var lower = 0
        while lower < ordered.count - 1 {
            let start = ordered[lower].timestamp
            var upper = lower
            while upper + 1 < ordered.count,
                  ordered[upper + 1].timestamp - start <= anchorDuration {
                upper += 1
            }
            if upper > lower,
               qualifiedOrdinaryBandPowerShare(
                   points: Array(ordered[lower...upper]),
                   policy: .autonomousAnchor
               ) != nil {
                anchors.append(lower...upper)
            }
            let nextStart = start + anchorStride
            repeat {
                lower += 1
            } while lower < ordered.count
                && ordered[lower].timestamp < nextStart
        }
        guard !anchors.isEmpty else { return [] }

        func expandedToObservedMotion(
            _ range: ClosedRange<Int>
        ) -> ClosedRange<Int> {
            var expandedLower = range.lowerBound
            let lowerLimit = ordered[expandedLower].timestamp - boundarySearch
            var probe = expandedLower
            while probe > 0,
                  ordered[probe - 1].timestamp >= lowerLimit {
                if admittedTickDelta(
                    from: ordered[probe - 1],
                    to: ordered[probe]
                ).map({ $0 > 0 }) == true {
                    expandedLower = probe - 1
                }
                probe -= 1
            }
            var expandedUpper = range.upperBound
            let upperLimit = ordered[expandedUpper].timestamp + boundarySearch
            probe = expandedUpper + 1
            while probe < ordered.count,
                  ordered[probe].timestamp <= upperLimit {
                if admittedTickDelta(
                    from: ordered[probe - 1],
                    to: ordered[probe]
                ).map({ $0 > 0 }) == true {
                    expandedUpper = probe
                }
                probe += 1
            }
            return expandedLower...expandedUpper
        }
        anchors = anchors.map(expandedToObservedMotion)

        // Overlap is sufficient continuity proof. A small separation is
        // admitted only when every intervening raw sample is present and its
        // gravity vector remains physically active. Wall-time proximity alone
        // can never bridge a radio gap or two stationary-separated walks.
        var merged: [ClosedRange<Int>] = []
        var current = anchors[0]
        for anchor in anchors.dropFirst() {
            if anchor.lowerBound <= current.upperBound
                || strapMotionContinues(
                    in: ordered,
                    from: current.upperBound,
                    through: anchor.lowerBound,
                    maximumDuration: 18
                ) {
                current = current.lowerBound...max(
                    current.upperBound,
                    anchor.upperBound
                )
            } else {
                merged.append(current)
                current = anchor
            }
        }
        merged.append(current)

        var results: [(ClosedRange<Int>, Estimate)] = []
        for anchorRange in merged {
            let range = expandedToObservedMotion(anchorRange)
            guard let estimate = estimateQualifiedWindow(
                points: Array(ordered[range]),
                policy: .autonomousBout,
                selectDominantMotionWindow: false
            ) else {
                continue
            }
            results.append((range, estimate))
        }
        return results
    }

    /// Read-only diagnostics for physical replay tooling and regression tests.
    /// Production publication still flows exclusively through
    /// `estimateCoveredActivity`.
    static func autonomousGaitBoutEstimates(
        points: [Point]
    ) -> [Estimate] {
        autonomousGaitBouts(in: canonical(points)).map(\.estimate)
    }

    private static func strapMotionContinues(
        in points: [Point],
        from lower: Int,
        through upper: Int,
        maximumDuration: TimeInterval
    ) -> Bool {
        guard lower >= 0,
              upper < points.count,
              upper > lower else {
            return false
        }
        let duration = points[upper].timestamp - points[lower].timestamp
        guard duration > 0,
              duration <= maximumDuration else {
            return false
        }
        var magnitudes: [Double] = []
        for index in (lower + 1)...upper {
            let gap = points[index].timestamp - points[index - 1].timestamp
            guard gap > 0,
                  gap <= maximumContinuousSampleGap else {
                return false
            }
            let dx = points[index].gravityX - points[index - 1].gravityX
            let dy = points[index].gravityY - points[index - 1].gravityY
            let dz = points[index].gravityZ - points[index - 1].gravityZ
            magnitudes.append(sqrt(dx * dx + dy * dy + dz * dz))
        }
        guard magnitudes.count >= 4 else { return false }
        let mean = magnitudes.reduce(0, +) / Double(magnitudes.count)
        let center = median(magnitudes)
        let mad = median(magnitudes.map { abs($0 - center) })
        return mean.isFinite
            && mad.isFinite
            && mean >= 0.02
            && mad <= maximumShortBurstGravityDeltaMagnitudeMAD
    }

    /// Splits a covered day into sustained motion bursts. Any counter-active
    /// burst which cannot support cadence estimation makes the subtotal
    /// unavailable; silently dropping short walks would under-count the day.
    static func estimateCoveredActivity(points: [Point]) -> Estimate? {
        let ordered = canonical(points)
        guard ordered.count >= 2 else { return nil }
        // Preserve the physically validated exact-window result whenever the
        // complete input already qualifies. Autonomous reconstruction exists
        // only for an otherwise fragmented day and must not replace a stronger
        // bounded cadence estimate with a looser anchor boundary.
        if let qualified = estimateWindow(points: ordered) {
            return qualified
        }
        let autonomousBouts = autonomousGaitBouts(in: ordered)
        let autonomouslyOwnedIndices = autonomousBouts.reduce(
            into: Set<Int>()
        ) { owned, bout in
            owned.formUnion(bout.range)
        }
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
            if delta > 0, !autonomouslyOwnedIndices.contains(index) {
                activeTransitionIndices.append(index)
            }
        }
        guard !activeTransitionIndices.isEmpty || !autonomousBouts.isEmpty else {
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
        if let firstActive = activeTransitionIndices.first {
            var rangeStart = max(0, firstActive - 1)
            var lastActive = firstActive
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
        }

        var estimates = autonomousBouts.map(\.estimate)
        for range in ranges {
            let rangePoints = Array(ordered[range])
            guard let estimate = estimateWindow(points: rangePoints)
                ?? estimateShortQualifiedBurst(points: rangePoints) else {
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

    /// Reassembles cadence evidence which was split only by durable bank
    /// bookkeeping. A WHOOP walk can cross several adjacent 0x69 coverage
    /// receipts; scoring each receipt independently turns one qualified walk
    /// into short, uncountable fragments. Payload identity is deduplicated
    /// first, while true radio/sample gaps remain separate runs and are never
    /// interpolated or extrapolated.
    static func estimateCoveredActivityFragments(
        _ fragments: [[Point]]
    ) -> Estimate? {
        let ordered = canonical(fragments.flatMap { $0 })
        guard ordered.count >= 2 else { return nil }

        var runs: [[Point]] = []
        var current: [Point] = []
        for point in ordered {
            if let previous = current.last {
                let gap = point.timestamp - previous.timestamp
                if gap <= 0 || gap > maximumContinuousSampleGap {
                    if current.count >= 2 {
                        runs.append(current)
                    }
                    current = []
                }
            }
            current.append(point)
        }
        if current.count >= 2 {
            runs.append(current)
        }
        guard !runs.isEmpty else { return nil }

        var estimates: [Estimate] = []
        var unresolvedMotionSeconds: TimeInterval = 0
        for run in runs {
            if let estimate = estimateCoveredActivity(points: run) {
                estimates.append(estimate)
                continue
            }
            guard let first = run.first, let last = run.last else { continue }
            let duration = max(0, last.timestamp - first.timestamp)
            let hasMotion = zip(run, run.dropFirst()).contains {
                guard let delta = admittedTickDelta(from: $0.0, to: $0.1)
                else { return true }
                return delta > 0
            }
            if hasMotion {
                unresolvedMotionSeconds += duration
            }
        }
        guard !estimates.isEmpty else { return nil }

        let totalDuration = estimates.reduce(0) {
            $0 + $1.durationSeconds
        }
        guard totalDuration > 0 else { return nil }
        let totalSteps = estimates.reduce(0) { $0 + $1.steps }
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
            motionTicks: estimates.reduce(0) { $0 + $1.motionTicks },
            motionVolume: estimates.reduce(0) { $0 + $1.motionVolume },
            cadenceOnlySteps: estimates.reduce(0) {
                $0 + $1.cadenceOnlySteps
            },
            motionVolumeSteps: estimates.reduce(0) {
                $0 + $1.motionVolumeSteps
            },
            unresolvedMotionSeconds: estimates.reduce(
                unresolvedMotionSeconds
            ) {
                $0 + $1.unresolvedMotionSeconds
            }
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
