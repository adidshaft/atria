import Foundation

enum AtriaFitnessAge {
    struct Inputs: Equatable {
        let chronologicalAge: Int
        let biologicalSex: AthleteProfile.BiologicalSex
        let vo2Max: Double?
        let restingHeartRate: Int?
        let hrvRMSSD: Int?
        let weeklyZone2PlusMinutes: Double?
        let sleepConsistencyPercent: Int?
        let historyDays: Int
    }

    /// One day's persisted fitness-age delta, as stored on
    /// `DailyRollupStoreEntry.fitnessAgeDelta` — the raw input to the
    /// pace-of-aging trend below.
    struct DailyDelta: Codable, Equatable, Sendable {
        let day: Date
        let delta: Int

        init(day: Date, delta: Int) {
            self.day = day
            self.delta = delta
        }
    }

    /// Honest "pace of aging" summary: clock pace plus the slope of the
    /// persisted weekly fitness-age observations over calendar time. Four
    /// weekly checks cover the same initial 28-day calibration window.
    struct PaceOfAging: Codable, Equatable, Sendable {
        let isReady: Bool
        /// Years of biological aging per one calendar year, e.g. `0.8` means
        /// slower than the clock, `1.2` means faster. `nil` while not ready.
        let yearsPerCalendarYear: Double?
        let copyText: String
    }

    /// Persisted, display-ready history for the weekly Healthspan detail.
    ///
    /// This is produced beside the weekly biological-age summary. Opening the
    /// detail screen only maps these bounded values into view rows; it never
    /// re-collapses daily rollups or re-runs the pace regression.
    struct DetailProjection: Codable, Equatable, Sendable {
        let weeklyObservations: [DailyDelta]
        let paceOfAging: PaceOfAging
        let trendChangeText: String?
        let cachedAt: Date?
    }

    static let footnoteText = "Estimate from heart data — not a medical measurement."
    static let paceMinimumEntries = 4
    static let paceCalibratingCopy = "Calibrating 28-day baseline"

    /// Computes the pace-of-aging trend from persisted daily rollup copies.
    /// Requires four distinct weekly observations before leaving calibration.
    static func paceOfAging(deltas: [DailyDelta], calendar: Calendar = .current) -> PaceOfAging {
        let observations = weeklyObservations(from: deltas, calendar: calendar)
        return paceOfAging(weeklyObservations: observations)
    }

    /// Builds the complete Healthspan history projection once, on the same
    /// weekly cadence as biological age.
    static func detailProjection(deltas: [DailyDelta],
                                 calendar: Calendar = .current) -> DetailProjection {
        let observations = weeklyObservations(from: deltas, calendar: calendar)
        let changeText: String?
        if let first = observations.first?.delta,
           let last = observations.last?.delta,
           observations.count >= 2 {
            let change = last - first
            changeText = change == 0 ? "Stable" : "\(change > 0 ? "+" : "")\(change)y"
        } else {
            changeText = nil
        }
        return DetailProjection(weeklyObservations: observations,
                                paceOfAging: paceOfAging(weeklyObservations: observations),
                                trendChangeText: changeText,
                                cachedAt: observations.last?.day)
    }

    private static func paceOfAging(weeklyObservations observations: [DailyDelta]) -> PaceOfAging {
        guard observations.count >= paceMinimumEntries else {
            return PaceOfAging(isReady: false, yearsPerCalendarYear: nil, copyText: paceCalibratingCopy)
        }
        let pace = agingSlopeYearsPerCalendarYear(deltas: observations)
        return PaceOfAging(isReady: true, yearsPerCalendarYear: pace, copyText: paceCopy(forPace: pace))
    }

    /// Fitness age is intentionally computed once per week. Daily rollups can
    /// carry that cached value, so collapse them before readiness or regression.
    static func weeklyObservations(from deltas: [DailyDelta],
                                   calendar: Calendar = .current) -> [DailyDelta] {
        let sorted = deltas.sorted { $0.day < $1.day }
        var latestByWeek: [Date: DailyDelta] = [:]
        for delta in sorted {
            guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: delta.day)?.start else { continue }
            latestByWeek[weekStart] = DailyDelta(day: weekStart, delta: delta.delta)
        }
        return latestByWeek.values.sorted { $0.day < $1.day }
    }

    /// Biological years aged per calendar year: the clock's 1.0 y/year plus
    /// the least-squares slope of fitness-age delta against calendar time.
    /// Sorted ascending by day. Fewer than two distinct days -> 1.
    static func agingSlopeYearsPerCalendarYear(deltas: [DailyDelta]) -> Double {
        let points = deltas.sorted { $0.day < $1.day }
        guard let referenceDay = points.first?.day, points.count >= 2 else { return 1 }
        let secondsPerYear = 365.25 * 24 * 60 * 60
        let xs = points.map { $0.day.timeIntervalSince(referenceDay) / secondsPerYear }
        let ys = points.map(\.delta).map(Double.init)
        let n = Double(points.count)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }
        let denominator = n * sumXX - sumX * sumX
        guard denominator != 0 else { return 1 }
        let deltaSlope = (n * sumXY - sumX * sumY) / denominator
        return 1 + deltaSlope
    }

    static func paceCopy(forPace pace: Double) -> String {
        let rounded = (pace * 10).rounded() / 10
        let magnitudeText = String(format: "%.1f", rounded)
        if rounded == 1 {
            return "Aging ~\(magnitudeText) y per calendar year, same as the clock"
        }
        let direction = rounded < 1 ? "slower" : "faster"
        return "Aging ~\(magnitudeText) y per calendar year \(direction) than the clock"
    }

    static func summary(inputs: Inputs) -> BiologicalAgeSummary {
        var blockers: [String] = []
        if inputs.historyDays < 28 {
            blockers.append("28 days of heart data")
        }
        if inputs.vo2Max == nil {
            blockers.append("VO2 max estimate")
        }
        if inputs.restingHeartRate == nil {
            blockers.append("resting HR baseline")
        }
        if inputs.hrvRMSSD == nil {
            blockers.append("HRV baseline")
        }
        if inputs.weeklyZone2PlusMinutes == nil {
            blockers.append("weekly zone-2+ minutes")
        }
        if inputs.sleepConsistencyPercent == nil {
            blockers.append("sleep consistency")
        }
        guard blockers.isEmpty,
              let vo2Max = inputs.vo2Max,
              let restingHeartRate = inputs.restingHeartRate,
              let hrvRMSSD = inputs.hrvRMSSD,
              let weeklyZone2PlusMinutes = inputs.weeklyZone2PlusMinutes,
              let sleepConsistencyPercent = inputs.sleepConsistencyPercent else {
            return BiologicalAgeSummary(biologicalAge: nil,
                                        chronologicalAge: inputs.chronologicalAge,
                                        ageDelta: nil,
                                        agingPaceText: "Calibrating",
                                        agingPaceDetail: "Needs 28 days before showing a fitness-age estimate.",
                                        factors: [],
                                        blockers: blockers,
                                        footnote: footnoteText)
        }

        let factors = [
            factor(id: "vo2max",
                   label: "VO2 max",
                   offset: vo2MaxOffset(age: inputs.chronologicalAge,
                                        vo2Max: vo2Max,
                                        sex: inputs.biologicalSex),
                   chronologicalAge: inputs.chronologicalAge,
                   detail: String(format: "%.1f ml/kg/min, FRIEND age reference", vo2Max)),
            factor(id: "rhr",
                   label: "Resting HR",
                   offset: restingHeartRateOffset(age: inputs.chronologicalAge,
                                                  restingHeartRate: restingHeartRate),
                   chronologicalAge: inputs.chronologicalAge,
                   detail: "\(restingHeartRate) bpm, age-adjusted percentile band"),
            factor(id: "lnrmssd",
                   label: "HRV",
                   offset: lnRMSSDOffset(age: inputs.chronologicalAge,
                                         rmssd: hrvRMSSD),
                   chronologicalAge: inputs.chronologicalAge,
                   detail: "\(hrvRMSSD) ms HRV, age-adjusted band"),
            factor(id: "zone2",
                   label: "Zone 2+",
                   offset: zone2PlusOffset(minutes: weeklyZone2PlusMinutes),
                   chronologicalAge: inputs.chronologicalAge,
                   detail: "\(Int(weeklyZone2PlusMinutes.rounded())) min in 7 days"),
            factor(id: "sleep_consistency",
                   label: "Sleep consistency",
                   offset: sleepConsistencyOffset(percent: sleepConsistencyPercent),
                   chronologicalAge: inputs.chronologicalAge,
                   detail: "\(sleepConsistencyPercent)% timing consistency")
        ]
        let rawDelta = factors.reduce(0) { $0 + $1.deltaVsChronological }
        let clampedDelta = min(max(rawDelta, -12), 12)
        let fitnessAge = inputs.chronologicalAge + clampedDelta
        let pace = contributorNarrative(factors: factors)
        return BiologicalAgeSummary(biologicalAge: fitnessAge,
                                    chronologicalAge: inputs.chronologicalAge,
                                    ageDelta: clampedDelta,
                                    agingPaceText: "Fitness age",
                                    agingPaceDetail: pace,
                                    factors: factors,
                                    blockers: [],
                                    footnote: footnoteText)
    }

    static func restingHeartRateOffset(age: Int, restingHeartRate: Int) -> Int {
        let expected = interpolatedValue(age: Double(age), anchors: restingHeartRateReference)
        return Int((Double(restingHeartRate) - expected).rounded()).clamped(to: -6...6)
    }

    static func vo2MaxOffset(age: Int,
                             vo2Max: Double,
                             sex: AthleteProfile.BiologicalSex) -> Int {
        guard vo2Max.isFinite else { return 0 }
        let reference: [(Double, Double)]
        switch sex {
        case .male:
            reference = maleVO2MaxReference
        case .female:
            reference = femaleVO2MaxReference
        case .unspecified:
            reference = zip(maleVO2MaxReference, femaleVO2MaxReference).map {
                ($0.0.0, ($0.0.1 + $0.1.1) / 2)
            }
        }
        let equivalentAge = ageEquivalent(value: vo2Max,
                                          higherIsYounger: true,
                                          anchors: reference)
        return (equivalentAge - age).clamped(to: -6...6)
    }

    static func lnRMSSDOffset(age: Int, rmssd: Int) -> Int {
        let expected = interpolatedValue(age: Double(age), anchors: lnRMSSDReference)
        let actual = log(Double(max(1, rmssd)))
        let delta = (expected - actual) * 8.0
        return Int(delta.rounded()).clamped(to: -6...6)
    }

    static func zone2PlusOffset(minutes: Double) -> Int {
        Int(interpolatedValue(age: minutes, anchors: zone2PlusReference).rounded()).clamped(to: -4...4)
    }

    static func sleepConsistencyOffset(percent: Int) -> Int {
        Int(interpolatedValue(age: Double(percent), anchors: sleepConsistencyReference).rounded()).clamped(to: -3...3)
    }

    private static func factor(id: String,
                               label: String,
                               offset: Int,
                               chronologicalAge: Int,
                               detail: String) -> BioAgeFactor {
        BioAgeFactor(id: id,
                     label: label,
                     ageEquivalent: chronologicalAge + offset,
                     deltaVsChronological: offset,
                     direction: offset == 0 ? .neutral : (offset < 0 ? .younger : .older),
                     weight: 1,
                     detail: detail)
    }

    private static func contributorNarrative(factors: [BioAgeFactor]) -> String {
        let helping = factors
            .filter { $0.deltaVsChronological < 0 }
            .min { $0.deltaVsChronological < $1.deltaVsChronological }
        let aging = factors
            .filter { $0.deltaVsChronological > 0 }
            .max { $0.deltaVsChronological < $1.deltaVsChronological }
        switch (helping, aging) {
        case let (helping?, aging?):
            return "Your \(helping.label) is helping · your \(aging.label.lowercased()) is aging you"
        case let (helping?, nil):
            return "Your \(helping.label) is helping"
        case let (nil, aging?):
            return "Your \(aging.label.lowercased()) is aging you"
        default:
            return "All five inputs are close to age baseline"
        }
    }

    private static func interpolatedValue(age x: Double, anchors: [(Double, Double)]) -> Double {
        guard let first = anchors.first else { return 0 }
        if x <= first.0 { return first.1 }
        for pair in zip(anchors, anchors.dropFirst()) where x <= pair.1.0 {
            let span = max(pair.1.0 - pair.0.0, 0.0001)
            let progress = (x - pair.0.0) / span
            return pair.0.1 + (pair.1.1 - pair.0.1) * progress
        }
        return anchors.last?.1 ?? first.1
    }

    private static func ageEquivalent(value: Double,
                                      higherIsYounger: Bool,
                                      anchors: [(Double, Double)]) -> Int {
        guard let youngest = anchors.first, let oldest = anchors.last else { return 90 }
        if higherIsYounger {
            if value >= youngest.1 { return 18 }
            if value <= oldest.1 { return 90 }
        }
        for pair in zip(anchors, anchors.dropFirst()) {
            let upper = pair.0
            let lower = pair.1
            let inside = higherIsYounger
                ? value <= upper.1 && value >= lower.1
                : value >= upper.1 && value <= lower.1
            guard inside else { continue }
            let span = max(abs(upper.1 - lower.1), 0.0001)
            let progress = abs(upper.1 - value) / span
            return Int((upper.0 + (lower.0 - upper.0) * progress).rounded())
                .clamped(to: 18...90)
        }
        return 90
    }

    // FRIEND-I directly measured treadmill CRF medians decline about 9% per
    // decade. These sex-specific decade anchors are intentionally conservative;
    // the resulting contribution is capped to +/-6 years above.
    private static let maleVO2MaxReference: [(Double, Double)] = [
        (25, 49.5), (35, 45.0), (45, 41.0),
        (55, 37.3), (65, 34.0), (75, 30.8)
    ]

    private static let femaleVO2MaxReference: [(Double, Double)] = [
        (25, 40.6), (35, 36.9), (45, 33.6),
        (55, 30.6), (65, 27.8), (75, 25.0)
    ]

    // Resting HR anchors: compact adult percentile bands where lower sleeping
    // resting HR maps younger and higher maps older; used only for local fitness age.
    private static let restingHeartRateReference: [(Double, Double)] = [
        (20, 58), (30, 60), (40, 62), (50, 64), (60, 66), (70, 68), (80, 70)
    ]

    // lnRMSSD anchors: log-transformed RMSSD decade medians adapted from published
    // age-related HRV decline references; higher lnRMSSD maps younger.
    private static let lnRMSSDReference: [(Double, Double)] = [
        (20, log(70)), (30, log(58)), (40, log(46)), (50, log(36)),
        (60, log(28)), (70, log(22)), (80, log(18))
    ]

    // Zone-2+ anchors mirror adult weekly aerobic guidance while rewarding
    // additional sustained minutes without pretending to be VO2max.
    private static let zone2PlusReference: [(Double, Double)] = [
        (0, 4), (75, 2), (150, 0), (225, -2), (300, -4)
    ]

    // Sleep consistency anchors use local schedule regularity. The contribution
    // stays capped because timing consistency is supportive, not diagnostic.
    private static let sleepConsistencyReference: [(Double, Double)] = [
        (50, 3), (65, 2), (80, 0), (90, -2), (95, -3)
    ]
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
