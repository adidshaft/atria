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
        lowerRestingHeartRate
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

    private static func lowerRestingHeartRate(rollups: [DailyRollupStoreEntry]) -> AtriaHighlight? {
        guard let latest = rollups.first?.rhr else { return nil }
        let prior = rollups.dropFirst().prefix(7).compactMap(\.rhr)
        guard prior.count >= 3 else { return nil }
        let average = Double(prior.reduce(0, +)) / Double(prior.count)
        guard Double(latest) <= average - 2 else { return nil }
        return AtriaHighlight(id: "lower-rhr",
                              systemImage: "heart.fill",
                              // Spelled out (2026-08-04): "↓ RHR" read as
                              // jargon on a first-open row; the arrow glyph
                              // also spoke poorly. WHOOP writes the metric
                              // name in prose on equivalent rows.
                              valuePhrase: "Resting HR",
                              sentence: "lower than usual",
                              tint: Metrics.electricGreen,
                              metric: .restingHeartRate)
    }
}
