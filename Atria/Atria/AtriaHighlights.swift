import SwiftUI

struct AtriaHighlight: Identifiable, Equatable {
    let id: String
    let systemImage: String
    let valuePhrase: String
    let sentence: String
    let tint: Color
    /// Detail sheet this insight opens (2026-07-07 design handoff: rows are
    /// real routes, not fake chevrons). nil renders a plain, chevron-free row.
    var metric: AtriaMetricDetailKind? = nil
}

enum AtriaHighlights {
    static func topTwo(rollups: [DailyRollupStoreEntry]) -> [AtriaHighlight] {
        let ordered = rollups.sorted { $0.day > $1.day }
        return Array(rules.compactMap { $0(ordered) }.prefix(2))
    }

    private static let rules: [(Array<DailyRollupStoreEntry>) -> AtriaHighlight?] = [
        sleepNeedStreak,
        lowerRestingHeartRate,
        // 2026-09-02: the two rules only ever praised. A resting HR above
        // usual is the warning wearers most want to see, and an HRV above
        // usual is the other real signal the rollups carry. Same gates:
        // three prior mornings, whole-beat and whole-millisecond deltas.
        higherRestingHeartRate,
        higherHRV
    ]

    private static func sleepNeedStreak(rollups: [DailyRollupStoreEntry]) -> AtriaHighlight? {
        let streak = rollups.prefix { entry in
            guard let performance = entry.sleepPerformance else { return false }
            return performance >= 100
        }.count
        guard streak >= 2 else { return nil }
        return AtriaHighlight(id: "sleep-need-streak",
                              systemImage: "moon.fill",
                              valuePhrase: "\(streak) nights",
                              sentence: "at sleep need",
                              tint: Metrics.electricSleep,
                              metric: .sleep)
    }

    private static func higherRestingHeartRate(rollups: [DailyRollupStoreEntry]) -> AtriaHighlight? {
        guard let latest = rollups.first?.rhr else { return nil }
        let prior = rollups.dropFirst().prefix(7).compactMap(\.rhr)
        guard prior.count >= 3 else { return nil }
        let average = Double(prior.reduce(0, +)) / Double(prior.count)
        guard Double(latest) >= average + 2 else { return nil }
        let above = Int((Double(latest) - average).rounded())
        return AtriaHighlight(id: "higher-rhr",
                              systemImage: "heart.fill",
                              valuePhrase: "Resting HR \(latest)",
                              sentence: "\(above) bpm above usual",
                              // Recovery's amber: a caution, not an alarm.
                              tint: Metrics.electricYellow,
                              metric: .restingHeartRate)
    }

    private static func higherHRV(rollups: [DailyRollupStoreEntry]) -> AtriaHighlight? {
        guard let latestLn = rollups.first?.lnRMSSD else { return nil }
        let prior = rollups.dropFirst().prefix(7).compactMap(\.lnRMSSD).map { exp($0) }
        guard prior.count >= 3 else { return nil }
        let latest = exp(latestLn)
        let average = prior.reduce(0, +) / Double(prior.count)
        // A tenth above the prior week's mean: HRV is noisier than RHR. The
        // hundredth of a millisecond absorbs log/exp round-trip noise.
        guard latest >= average * 1.10 - 0.01 else { return nil }
        let above = Int((latest - average).rounded())
        return AtriaHighlight(id: "higher-hrv",
                              systemImage: "waveform.path.ecg",
                              valuePhrase: "HRV \(Int(latest.rounded())) ms",
                              sentence: "\(above) ms above usual",
                              tint: Metrics.electricGreen,
                              metric: .hrv)
    }

    private static func lowerRestingHeartRate(rollups: [DailyRollupStoreEntry]) -> AtriaHighlight? {
        guard let latest = rollups.first?.rhr else { return nil }
        let prior = rollups.dropFirst().prefix(7).compactMap(\.rhr)
        guard prior.count >= 3 else { return nil }
        let average = Double(prior.reduce(0, +)) / Double(prior.count)
        guard Double(latest) <= average - 2 else { return nil }
        // The reading and its distance from the prior week ride in the row
        // (phone 2026-09-02: "Resting HR lower than usual" said neither the
        // number nor how far). Rounded to whole beats; the gate above
        // guarantees at least two.
        let below = Int((average - Double(latest)).rounded())
        return AtriaHighlight(id: "lower-rhr",
                              systemImage: "heart.fill",
                              // Spelled out (2026-08-04): "↓ RHR" read as
                              // jargon on a first-open row; the arrow glyph
                              // also spoke poorly. WHOOP writes the metric
                              // name in prose on equivalent rows.
                              valuePhrase: "Resting HR \(latest)",
                              sentence: "\(below) bpm below usual",
                              tint: Metrics.electricGreen,
                              metric: .restingHeartRate)
    }
}
