import Foundation

/// Atria's independent cardiovascular-load model.
///
/// The interval kernel is based on the heart-rate-reserve form of Banister
/// TRIMP: duration x HRR x a x exp(k x HRR). Heart-rate reserve personalizes
/// the same observed BPM to the athlete's resting and maximum heart rates, and
/// the exponential term gives sustained high intensity more weight than the
/// same duration at low intensity.
///
/// Sex-specific Banister parameter references: PMCID PMC10944953 and
/// PMCID PMC13287160 (0.64/1.92 male; 0.86/1.67 female).
///
/// This is not WHOOP's proprietary Strain formula. The continuous-day mode is
/// also not an implementation of Fitbit Cardio Load: Atria does not yet have
/// time-aligned movement evidence at this layer. It adopts only the published
/// 30% HRR floor and 30...40% transition as an explicit, conservative HR-only
/// policy. Workout mode always uses the full validated TRIMP kernel.
enum AtriaStrainLoadModel {
    enum Mode: Equatable, Sendable {
        /// Full cardiovascular load inside an explicit workout window.
        case workout
        /// Conservative load from continuous wear outside workout semantics.
        case continuousDay
    }

    struct Configuration: Equatable, Sendable {
        let restingBPM: Double
        let maximumBPM: Double
        let intensityMultiplier: Double
        let intensityCoefficient: Double
        let mode: Mode
        let maximumGap: TimeInterval

        init(restingBPM: Double,
             maximumBPM: Double,
             intensityMultiplier: Double = 0.64,
             intensityCoefficient: Double,
             mode: Mode,
             maximumGap: TimeInterval = 15) {
            self.restingBPM = restingBPM
            self.maximumBPM = maximumBPM
            self.intensityMultiplier = intensityMultiplier
            self.intensityCoefficient = intensityCoefficient
            self.mode = mode
            self.maximumGap = maximumGap
        }
    }

    struct Sample: Equatable, Sendable {
        let timestamp: TimeInterval
        let bpm: Double

        init(timestamp: TimeInterval, bpm: Double) {
            self.timestamp = timestamp
            self.bpm = bpm
        }
    }

    enum RejectionReason: Equatable, Sendable {
        case invalidConfiguration
        case nonFiniteSample
        case nonIncreasingTimestamp
        case telemetryGap
        case implausibleBPM
    }

    struct IntervalEvaluation: Equatable, Sendable {
        let load: Double
        let acceptedDuration: TimeInterval
        let droppedGapDuration: TimeInterval
        let rejectionReason: RejectionReason?

        var isAccepted: Bool { rejectionReason == nil }

        fileprivate static func accepted(load: Double, duration: TimeInterval) -> Self {
            Self(load: load,
                 acceptedDuration: duration,
                 droppedGapDuration: 0,
                 rejectionReason: nil)
        }

        fileprivate static func rejected(_ reason: RejectionReason,
                                         droppedGapDuration: TimeInterval = 0) -> Self {
            Self(load: 0,
                 acceptedDuration: 0,
                 droppedGapDuration: droppedGapDuration,
                 rejectionReason: reason)
        }
    }

    struct Result: Equatable, Sendable {
        let load: Double
        let acceptedDuration: TimeInterval
        let droppedGapDuration: TimeInterval
        let rejectedIntervalCount: Int
    }

    /// Broad defensive limits for load evidence, not diagnostic boundaries.
    /// This matches the metric-usable historical and compact-fact ingress
    /// contract so live, replayed, and raw-retired calculations stay identical.
    static let plausibleBPMRange = 35.0...240.0

    /// Continuous-wear policy reference: Phillips et al., arXiv:2508.11613v2,
    /// doi:10.48550/arXiv.2508.11613. That movement-aware work floors load at
    /// 30% HRR and down-weights 30...40% HRR. Atria independently uses a
    /// transparent linear HR-only ramp between those points; it is not an
    /// implementation of Google's Cardio Load transition.
    static let continuousDayLoadFloorHRR = 0.30
    static let continuousDayFullWeightHRR = 0.40

    static let maximumDisplayScore = 21.0
    static let displayLoadScale = 150.0

    /// O(1)-memory streaming integration. Batch calculation below is defined
    /// in terms of this same accumulator, so replay and live ingestion cannot
    /// silently drift to different formulas.
    struct Accumulator: Sendable {
        let configuration: Configuration
        private(set) var totalLoad = 0.0
        private(set) var acceptedDuration: TimeInterval = 0
        private(set) var droppedGapDuration: TimeInterval = 0
        private(set) var rejectedIntervalCount = 0
        private var previous: Sample?

        init(configuration: Configuration) {
            self.configuration = configuration
        }

        mutating func append(_ sample: Sample) {
            guard let previous else {
                self.previous = sample.timestamp.isFinite ? sample : nil
                return
            }

            let evaluation = evaluateInterval(from: previous,
                                              to: sample,
                                              configuration: configuration)
            totalLoad += evaluation.load
            acceptedDuration += evaluation.acceptedDuration
            droppedGapDuration += evaluation.droppedGapDuration
            if !evaluation.isAccepted {
                rejectedIntervalCount += 1
            }

            // Never bridge across malformed or out-of-order timestamps. A bad
            // BPM remains the adjacent sample so both sides of the invalid
            // reading are rejected rather than interpolated through it.
            switch evaluation.rejectionReason {
            case .nonFiniteSample where !sample.timestamp.isFinite,
                 .nonIncreasingTimestamp:
                self.previous = nil
            default:
                self.previous = sample
            }
        }

        mutating func append<S: Sequence>(contentsOf samples: S) where S.Element == Sample {
            for sample in samples {
                append(sample)
            }
        }

        var result: Result {
            Result(load: totalLoad,
                   acceptedDuration: acceptedDuration,
                   droppedGapDuration: droppedGapDuration,
                   rejectedIntervalCount: rejectedIntervalCount)
        }
    }

    static func calculate<S: Sequence>(_ samples: S,
                                       configuration: Configuration) -> Result
    where S.Element == Sample {
        var accumulator = Accumulator(configuration: configuration)
        accumulator.append(contentsOf: samples)
        return accumulator.result
    }

    /// The single interval authority shared by batch and live workout paths.
    static func evaluateInterval(from previous: Sample,
                                 to current: Sample,
                                 configuration: Configuration) -> IntervalEvaluation {
        guard configuration.restingBPM.isFinite,
              configuration.maximumBPM.isFinite,
              configuration.intensityMultiplier.isFinite,
              configuration.intensityCoefficient.isFinite,
              configuration.maximumGap.isFinite,
              configuration.maximumBPM > configuration.restingBPM,
              configuration.intensityMultiplier > 0,
              configuration.maximumGap > 0 else {
            return .rejected(.invalidConfiguration)
        }
        guard previous.timestamp.isFinite,
              current.timestamp.isFinite,
              previous.bpm.isFinite,
              current.bpm.isFinite else {
            return .rejected(.nonFiniteSample)
        }

        let duration = current.timestamp - previous.timestamp
        guard duration > 0 else {
            return .rejected(.nonIncreasingTimestamp)
        }
        guard duration <= configuration.maximumGap else {
            return .rejected(.telemetryGap, droppedGapDuration: duration)
        }
        guard plausibleBPMRange.contains(previous.bpm),
              plausibleBPMRange.contains(current.bpm) else {
            return .rejected(.implausibleBPM)
        }

        let meanBPM = (previous.bpm + current.bpm) / 2
        let load = load(forQualifiedMeanBPM: meanBPM,
                        duration: duration,
                        configuration: configuration)
        return .accepted(load: load, duration: duration)
    }

    /// Integrates duration that has already passed adjacency, ordering, gap,
    /// and endpoint-quality checks. Compact historical facts retain precisely
    /// this trapezoidal mean-BPM/duration basis, so they can use the same load
    /// authority without reconstructing fictional samples or reapplying a gap
    /// rule to the sum of many independently accepted intervals.
    ///
    /// Isolated jump artifacts are held or discarded at realtime ingress. This
    /// kernel deliberately does not reclassify an in-range accepted transition:
    /// compact facts retain its mean and duration but not both endpoints. Any
    /// future second-stage spike rule therefore requires a versioned compact
    /// acceptance field and rebuild path before it can be applied here.
    static func load(forQualifiedMeanBPM meanBPM: Double,
                     duration: TimeInterval,
                     configuration: Configuration) -> Double {
        guard configuration.restingBPM.isFinite,
              configuration.maximumBPM.isFinite,
              configuration.intensityMultiplier.isFinite,
              configuration.intensityCoefficient.isFinite,
              configuration.maximumBPM > configuration.restingBPM,
              configuration.intensityMultiplier > 0,
              duration.isFinite,
              duration > 0,
              meanBPM.isFinite,
              plausibleBPMRange.contains(meanBPM) else { return 0 }

        let reserve = configuration.maximumBPM - configuration.restingBPM
        let hrr = min(max((meanBPM - configuration.restingBPM) / reserve, 0), 1)
        let multiplier = min(configuration.intensityMultiplier, 2)
        let coefficient = min(max(configuration.intensityCoefficient, 1), 2.5)
        let contextWeight = continuousDayWeight(forHRR: hrr, mode: configuration.mode)
        let load = (duration / 60) * hrr * multiplier * exp(coefficient * hrr) * contextWeight
        return load.isFinite ? load : 0
    }

    static func continuousDayWeight(forHRR hrr: Double, mode: Mode) -> Double {
        guard hrr.isFinite else { return 0 }
        guard mode == .continuousDay else { return 1 }
        guard hrr > continuousDayLoadFloorHRR else { return 0 }
        guard hrr < continuousDayFullWeightHRR else { return 1 }
        return (hrr - continuousDayLoadFloorHRR)
            / (continuousDayFullWeightHRR - continuousDayLoadFloorHRR)
    }

    /// Atria-specific, monotonic display calibration over cardiovascular load.
    /// It is deliberately separate from the evidence model and is not a
    /// validated or proprietary WHOOP 0...21 equation.
    static func displayScore(fromLoad load: Double) -> Double {
        guard load.isFinite, load > 0 else { return 0 }
        let score = maximumDisplayScore * (1 - exp(-load / displayLoadScale))
        return min(max(score, 0), maximumDisplayScore)
    }
}
