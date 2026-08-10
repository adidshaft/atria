import Foundation

/// Atria's transparent physiological-stress calibration.
///
/// US20240188865A1 describes the direction of a dynamic HR/HRV weighting,
/// periodic scoring, motion adjustment, and a stress timeline. It does not
/// publish this equation or its production calibration. The constants and
/// equations below are Atria-owned and intentionally kept explicit so live and
/// historical scoring can be reproduced without proprietary code.
enum AtriaPhysiologicalStressModel {
    static let scoringVersion = 3
    static let windowDuration: TimeInterval = 5 * 60
    static let evaluationCadence: TimeInterval = 60
    static let emaHalfLife: TimeInterval = 3 * 60
    /// Raw cardiac evidence may be sampled as slowly as the one-minute scoring
    /// cadence, but a longer interval is missing telemetry and must leave a
    /// graph gap. Keep this distinct from minute-job scheduling jitter below:
    /// permitting that jitter between raw samples would bridge a real outage.
    static let maximumRawHeartRateGap = evaluationCadence
    /// A minute evaluation can arrive late without implying that its complete
    /// raw five-minute window was discontinuous. This tolerance applies only to
    /// EMA succession between already-qualified minute facts.
    static let maximumFactContinuityGap: TimeInterval = 90
    static let minimumQualifiedRRSpan: TimeInterval = 90
    /// Allow only small scheduling jitter around the complete five-minute
    /// horizon; shorter partial windows remain graph gaps.
    static let minimumQualifiedHRSpan = windowDuration - 10
    static let minimumQualifiedHRSamples = 5
    static let fullyQualifiedHRSpan = minimumQualifiedHRSpan
    static let fullyQualifiedHRSamples = 10
    static let minimumPersonalBaselineDays = 14
    /// At most one rolling daily ln-RMSSD observation is retained per day.
    /// Bounding the input before robust-statistic work keeps memory constant.
    static let maximumBaselineObservations = 366

    struct HeartRateSample: Equatable, Sendable {
        let date: Date
        let bpm: Int
        let qualified: Bool

        init(date: Date, bpm: Int, qualified: Bool = true) {
            self.date = date
            self.bpm = bpm
            self.qualified = qualified
        }
    }

    struct RRSample: Equatable, Sendable {
        let date: Date
        let milliseconds: Double
        let qualified: Bool

        init(date: Date, milliseconds: Double, qualified: Bool = true) {
            self.date = date
            self.milliseconds = milliseconds
            self.qualified = qualified
        }
    }

    struct HRVBaseline: Equatable, Sendable {
        let medianLnRMSSD: Double
        let robustScale: Double
        let qualifiedDayCount: Int

        init(medianLnRMSSD: Double,
             robustScale: Double,
             qualifiedDayCount: Int) {
            self.medianLnRMSSD = medianLnRMSSD
            // A narrow or zero MAD must not turn tiny measurement noise into a
            // saturated score. 0.15 is a conservative ln-RMSSD scale floor.
            self.robustScale = max(0.15, robustScale)
            self.qualifiedDayCount = max(0, qualifiedDayCount)
        }
    }

    struct Personalization: Equatable, Sendable {
        let restingHeartRate: Double
        let maximumHeartRate: Double
        let restingBaselineDayCount: Int
        let hrvBaseline: HRVBaseline?

        init(restingHeartRate: Double,
             maximumHeartRate: Double,
             restingBaselineDayCount: Int,
             hrvBaseline: HRVBaseline?) {
            self.restingHeartRate = restingHeartRate
            self.maximumHeartRate = maximumHeartRate
            self.restingBaselineDayCount = max(0, restingBaselineDayCount)
            self.hrvBaseline = hrvBaseline
        }

        var isRestingBaselineLearning: Bool {
            restingBaselineDayCount < minimumPersonalBaselineDays
        }
    }

    enum MotionKind: String, Codable, Equatable, Sendable {
        case unavailable
        case unqualified
        case still
        case activity
    }

    /// Only qualified activity evidence can attenuate an exercise-driven
    /// elevation. Missing or unqualified motion always resolves to M=1, so it
    /// can never invent calm.
    struct MotionContext: Codable, Equatable, Sendable {
        let kind: MotionKind
        let intensity: Double
        let qualified: Bool

        init(kind: MotionKind, intensity: Double = 0, qualified: Bool = false) {
            self.kind = kind
            self.intensity = Self.clamp01(intensity)
            self.qualified = qualified
        }

        static let unavailable = Self(kind: .unavailable)
        static let unqualified = Self(kind: .unqualified)
        static let qualifiedStill = Self(kind: .still, qualified: true)

        static func qualifiedActivity(intensity: Double) -> Self {
            Self(kind: .activity, intensity: intensity, qualified: true)
        }

        /// Exercise is attenuated, never erased. The strongest qualified
        /// activity evidence can reduce the cardiac score by at most 35%.
        var multiplier: Double {
            guard qualified, kind == .activity else { return 1 }
            return max(0.65, 1 - 0.35 * Self.clamp01(intensity))
        }

        var displayName: String {
            switch kind {
            case .unavailable: return "Motion unavailable"
            case .unqualified: return "Motion unqualified"
            case .still: return "Still"
            case .activity: return qualified ? "Activity" : "Motion unqualified"
            }
        }

        /// Codable bypasses the clamping initializer. Persistence callers use
        /// this check before treating restored motion as an attenuation
        /// authority, so a corrupt archive can never manufacture activity.
        var isStructurallyValid: Bool {
            guard intensity.isFinite, (0...1).contains(intensity) else {
                return false
            }
            switch kind {
            case .unavailable:
                return !qualified && intensity == 0
            case .unqualified:
                return !qualified
            case .still:
                return intensity == 0
            case .activity:
                // An unqualified activity hint is still valid provenance; its
                // multiplier remains exactly 1 and therefore cannot attenuate.
                return true
            }
        }

        private static func clamp01(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return min(max(value, 0), 1)
        }
    }

    enum SleepContext: String, Codable, Equatable, Sendable {
        case unavailable
        case awake
        case asleep

        var displayName: String {
            switch self {
            case .unavailable: return "Sleep context unavailable"
            case .awake: return "Awake"
            case .asleep: return "Sleep"
            }
        }
    }

    enum Confidence: String, Codable, Equatable, Sendable {
        case low
        case medium
        case high

        var numericValue: Double {
            switch self {
            case .low: return 0.45
            case .medium: return 0.70
            case .high: return 0.90
            }
        }

        var displayName: String { rawValue.capitalized }
    }

    enum Zone: String, Codable, Equatable, Sendable {
        case calm = "Calm"
        case moderate = "Moderate"
        case high = "High"

        static func resolve(score: Double) -> Self {
            if score < 1 { return .calm }
            if score < 2 { return .moderate }
            return .high
        }
    }

    /// One durable minute-level derived fact. Raw source samples stay in their
    /// existing stores; this bounded record is sufficient to render and audit
    /// the score without per-sample UserDefaults writes.
    struct MinuteFact: Codable, Equatable, Sendable {
        let date: Date
        let score: Double
        let unsmoothedScore: Double
        let meanHeartRate: Double
        let rmssd: Double?
        let hrStress: Double
        let hrvStress: Double?
        let heartRateWeight: Double
        let motionContext: MotionContext
        let sleepContext: SleepContext
        let confidence: Confidence
        let baselineLearning: Bool
        let scoringVersion: Int

        var zone: Zone { Zone.resolve(score: score) }
        var isHROnly: Bool { rmssd == nil || hrvStress == nil }

        /// Persistence boundary validation. Codable can bypass the clamping
        /// initializer, so archives must re-check every numeric/provenance
        /// invariant before a fact is rendered as measured evidence.
        var isStructurallyValid: Bool {
            let hasCompleteHRV = rmssd != nil && hrvStress != nil
            let hasNoHRV = rmssd == nil && hrvStress == nil
            return date.timeIntervalSinceReferenceDate.isFinite
                && score.isFinite && (0...3).contains(score)
                && unsmoothedScore.isFinite && (0...3).contains(unsmoothedScore)
                && meanHeartRate.isFinite && (30...240).contains(meanHeartRate)
                && rmssd.map({ $0.isFinite && $0 > 0 }) ?? true
                && hrStress.isFinite && (0...1).contains(hrStress)
                && hrvStress.map({ $0.isFinite && (0...1).contains($0) }) ?? true
                && heartRateWeight.isFinite && (0.5...1).contains(heartRateWeight)
                && (hasCompleteHRV || hasNoHRV)
                && motionContext.isStructurallyValid
                && (!isHROnly || confidence == .low)
                && scoringVersion == AtriaPhysiologicalStressModel.scoringVersion
        }

        init(date: Date,
             score: Double,
             unsmoothedScore: Double,
             meanHeartRate: Double,
             rmssd: Double?,
             hrStress: Double,
             hrvStress: Double?,
             heartRateWeight: Double,
             motionContext: MotionContext,
             sleepContext: SleepContext,
             confidence: Confidence,
             baselineLearning: Bool,
             scoringVersion: Int = AtriaPhysiologicalStressModel.scoringVersion) {
            self.date = date
            self.score = AtriaPhysiologicalStressModel.clamp(score, 0, 3)
            self.unsmoothedScore = AtriaPhysiologicalStressModel.clamp(unsmoothedScore, 0, 3)
            self.meanHeartRate = meanHeartRate
            self.rmssd = rmssd
            self.hrStress = Self.clamp01(hrStress)
            self.hrvStress = hrvStress.map {
                AtriaPhysiologicalStressModel.clamp01($0)
            }
            self.heartRateWeight = Self.clamp01(heartRateWeight)
            self.motionContext = motionContext
            self.sleepContext = sleepContext
            self.confidence = confidence
            self.baselineLearning = baselineLearning
            self.scoringVersion = scoringVersion
        }

        private static func clamp01(_ value: Double) -> Double {
            AtriaPhysiologicalStressModel.clamp01(value)
        }
    }

    struct WindowInput: Equatable, Sendable {
        let end: Date
        let heartRates: [HeartRateSample]
        let rrIntervals: [RRSample]
        let personalization: Personalization
        let motionContext: MotionContext
        let sleepContext: SleepContext

        init(end: Date,
             heartRates: [HeartRateSample],
             rrIntervals: [RRSample],
             personalization: Personalization,
             motionContext: MotionContext = .unavailable,
             sleepContext: SleepContext = .unavailable) {
            self.end = end
            self.heartRates = heartRates
            self.rrIntervals = rrIntervals
            self.personalization = personalization
            self.motionContext = motionContext
            self.sleepContext = sleepContext
        }
    }

    /// Shared live/batch kernel. A missing qualified HR window returns nil,
    /// which is represented by a graph gap rather than a fabricated baseline.
    static func evaluate(_ input: WindowInput,
                         previous: MinuteFact? = nil) -> MinuteFact? {
        guard input.end.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let start = input.end.addingTimeInterval(-windowDuration)
        var hrTotal = 0.0
        var hrCount = 0
        var firstQualifiedHRDate: Date?
        var lastQualifiedHRDate: Date?
        var previousQualifiedHRDate: Date?
        var maximumQualifiedHRGap: TimeInterval = 0
        var priorHRDate: Date?
        for sample in input.heartRates {
            // Source stores promise chronological input. Reject a malformed
            // replay rather than silently reordering it into a plausible fact.
            if let priorHRDate, sample.date < priorHRDate { return nil }
            priorHRDate = sample.date
            guard sample.qualified,
                  (30...240).contains(sample.bpm),
                  sample.date >= start,
                  sample.date <= input.end else { continue }
            hrTotal += Double(sample.bpm)
            hrCount += 1
            firstQualifiedHRDate = firstQualifiedHRDate ?? sample.date
            if let previousQualifiedHRDate {
                maximumQualifiedHRGap = max(
                    maximumQualifiedHRGap,
                    sample.date.timeIntervalSince(previousQualifiedHRDate)
                )
            }
            previousQualifiedHRDate = sample.date
            lastQualifiedHRDate = sample.date
        }
        guard hrCount >= minimumQualifiedHRSamples,
              let firstQualifiedHRDate,
              let lastQualifiedHRDate,
              lastQualifiedHRDate.timeIntervalSince(firstQualifiedHRDate)
                >= minimumQualifiedHRSpan,
              maximumQualifiedHRGap <= maximumRawHeartRateGap else {
            return nil
        }
        let meanHR = hrTotal / Double(hrCount)
        let hrWindowIsSparse = hrCount < fullyQualifiedHRSamples
            || lastQualifiedHRDate.timeIntervalSince(firstQualifiedHRDate)
                < fullyQualifiedHRSpan

        let rest = input.personalization.restingHeartRate
        let maximum = input.personalization.maximumHeartRate
        guard rest.isFinite, maximum.isFinite, rest > 0, maximum > rest else {
            return nil
        }

        let h = clamp01((meanHR - rest) / max(1, maximum - rest))
        let hrStress = sigmoid(8 * (h - 0.25))
        let weightHR = 0.5 + 0.5 * (1 - smoothstep(edge0: 0.05,
                                                   edge1: 0.35,
                                                   value: h))

        let currentRMSSD = qualifiedRMSSD(input.rrIntervals,
                                          start: start,
                                          end: input.end)
        let rmssd: Double?
        let hrvStress: Double?
        if let currentRMSSD, currentRMSSD > 0,
           let hrvBaseline = input.personalization.hrvBaseline {
            rmssd = currentRMSSD
            let currentLnRMSSD = log(currentRMSSD)
            let standardized = (hrvBaseline.medianLnRMSSD - currentLnRMSSD)
                / hrvBaseline.robustScale
            hrvStress = sigmoid(1.3 * standardized)
        } else {
            // A current tachogram without a comparison baseline cannot
            // contribute the requested HRV term. Keep the fact internally
            // complete and label the score HR-only rather than persisting an
            // RMSSD value that the scoring kernel did not use.
            rmssd = nil
            hrvStress = nil
        }

        let base: Double
        if let hrvStress {
            base = weightHR * hrStress + (1 - weightHR) * hrvStress
        } else {
            // Honest HR-only fallback. It is lower confidence, but missing HRV
            // does not numerically pretend that HRV implied calm.
            base = hrStress
        }
        let unsmoothed = clamp(3 * input.motionContext.multiplier * base, 0, 3)

        let score: Double
        if let previous,
           previous.scoringVersion == scoringVersion {
            let delta = input.end.timeIntervalSince(previous.date)
            if delta > 0, delta <= maximumFactContinuityGap {
                let alpha = 1 - exp(-log(2) * delta / emaHalfLife)
                score = previous.score + alpha * (unsmoothed - previous.score)
            } else {
                // Never bridge a telemetry or clock gap.
                score = unsmoothed
            }
        } else {
            score = unsmoothed
        }

        let hrvMature = input.personalization.hrvBaseline.map {
            $0.qualifiedDayCount >= minimumPersonalBaselineDays
        } ?? false
        let learning = input.personalization.isRestingBaselineLearning
            || (hrvStress != nil && !hrvMature)
        let confidence: Confidence
        if hrvStress == nil || hrWindowIsSparse {
            confidence = .low
        } else if learning || !input.motionContext.qualified {
            confidence = .medium
        } else {
            confidence = .high
        }

        return MinuteFact(date: input.end,
                          score: score,
                          unsmoothedScore: unsmoothed,
                          meanHeartRate: meanHR,
                          rmssd: rmssd,
                          hrStress: hrStress,
                          hrvStress: hrvStress,
                          heartRateWeight: weightHR,
                          motionContext: input.motionContext,
                          sleepContext: input.sleepContext,
                          confidence: confidence,
                          baselineLearning: learning)
    }

    /// Historical replay calls the exact same kernel as the live path. Inputs
    /// are minute-framed by the caller; memory is bounded to the output plus one
    /// previous fact and scoring remains O(number of supplied window samples).
    static func evaluate(_ inputs: [WindowInput],
                         previous seed: MinuteFact? = nil) -> [MinuteFact] {
        var facts: [MinuteFact] = []
        facts.reserveCapacity(inputs.count)
        var previous = seed?.scoringVersion == scoringVersion ? seed : nil
        var priorEnd: Date?
        for input in inputs {
            guard priorEnd.map({ input.end > $0 }) ?? true else {
                // Historical callers must frame inputs in strict chronological
                // order. A replay with ambiguous ordering fails closed.
                return []
            }
            priorEnd = input.end
            guard let fact = evaluate(input, previous: previous) else {
                // A missing HR minute breaks EMA continuity.
                previous = nil
                continue
            }
            facts.append(fact)
            previous = fact
        }
        return facts
    }

    static func robustHRVBaseline(lnRMSSDValues: [Double],
                                  qualifiedDayCount: Int) -> HRVBaseline? {
        // Callers provide daily values oldest-to-newest. Only the bounded
        // rolling suffix participates in the baseline.
        let values = lnRMSSDValues.suffix(maximumBaselineObservations)
            .filter(\.isFinite)
            .sorted()
        guard !values.isEmpty else { return nil }
        let medianValue = median(values)
        let deviations = values.map { abs($0 - medianValue) }.sorted()
        let scaledMAD = 1.4826 * median(deviations)
        return HRVBaseline(medianLnRMSSD: medianValue,
                           robustScale: scaledMAD,
                           qualifiedDayCount: qualifiedDayCount)
    }

    static func qualifiedRMSSD(_ samples: [RRSample],
                               start: Date,
                               end: Date) -> Double? {
        var squaredDifferenceSum = 0.0
        var differenceCount = 0
        var qualifiedCount = 0
        var firstQualifiedDate: Date?
        var lastQualifiedDate: Date?
        var previousQualified: RRSample?
        var priorInputDate: Date?
        for current in samples {
            if let priorInputDate, current.date < priorInputDate { return nil }
            priorInputDate = current.date
            guard current.qualified,
                  current.milliseconds.isFinite,
                  (300...2_000).contains(current.milliseconds),
                  current.date >= start,
                  current.date <= end else {
                previousQualified = nil
                continue
            }
            qualifiedCount += 1
            firstQualifiedDate = firstQualifiedDate ?? current.date
            lastQualifiedDate = current.date
            guard let prior = previousQualified else {
                previousQualified = current
                continue
            }
            let gap = current.date.timeIntervalSince(prior.date)
            // Rejected/non-contiguous beats break succession. Never difference
            // across a telemetry island.
            if gap > 0, gap <= HRVSnapshot.maxReadyRRGapSeconds {
                let difference = current.milliseconds - prior.milliseconds
                squaredDifferenceSum += difference * difference
                differenceCount += 1
            }
            previousQualified = current
        }
        guard qualifiedCount >= 3,
              let firstQualifiedDate,
              let lastQualifiedDate,
              lastQualifiedDate.timeIntervalSince(firstQualifiedDate)
                >= minimumQualifiedRRSpan,
              differenceCount > 0 else { return nil }
        return sqrt(squaredDifferenceSum / Double(differenceCount))
    }

    static func sigmoid(_ value: Double) -> Double {
        1 / (1 + exp(-value))
    }

    static func smoothstep(edge0: Double, edge1: Double, value: Double) -> Double {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = clamp01((value - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    private static func median(_ sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let middle = sortedValues.count / 2
        return sortedValues.count.isMultiple(of: 2)
            ? (sortedValues[middle - 1] + sortedValues[middle]) / 2
            : sortedValues[middle]
    }

    private static func clamp01(_ value: Double) -> Double {
        clamp(value, 0, 1)
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}
