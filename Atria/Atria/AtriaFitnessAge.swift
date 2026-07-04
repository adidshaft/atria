import Foundation

enum AtriaFitnessAge {
    struct Inputs: Equatable {
        let chronologicalAge: Int
        let restingHeartRate: Int?
        let hrvRMSSD: Int?
        let weeklyZone2PlusMinutes: Double?
        let sleepConsistencyPercent: Int?
        let historyDays: Int
    }

    static let footnoteText = "Estimate from heart data — not a medical measurement."

    static func summary(inputs: Inputs) -> BiologicalAgeSummary {
        var blockers: [String] = []
        if inputs.historyDays < 28 {
            blockers.append("28 days of heart data")
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
            return "All four inputs are close to age baseline"
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
