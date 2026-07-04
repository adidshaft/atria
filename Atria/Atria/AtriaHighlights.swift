import SwiftUI

struct AtriaHighlight: Identifiable, Equatable {
    let id: String
    let systemImage: String
    let valuePhrase: String
    let sentence: String
    let tint: Color
}

enum AtriaHighlights {
    static func topTwo(rollups: [DailyRollupStoreEntry]) -> [AtriaHighlight] {
        Array(rules.compactMap { $0(rollups) }.prefix(2))
    }

    private static let rules: [(Array<DailyRollupStoreEntry>) -> AtriaHighlight?] = [
        sleepNeedStreak,
        lowerRestingHeartRate
    ]

    private static func sleepNeedStreak(rollups: [DailyRollupStoreEntry]) -> AtriaHighlight? {
        let sorted = rollups.sorted { $0.day > $1.day }
        let streak = sorted.prefix { entry in
            guard let performance = entry.sleepPerformance else { return false }
            return performance >= 100
        }.count
        guard streak >= 2 else { return nil }
        return AtriaHighlight(id: "sleep-need-streak",
                              systemImage: "moon.fill",
                              valuePhrase: "\(streak) nights",
                              sentence: "at sleep need",
                              tint: Metrics.electricSleep)
    }

    private static func lowerRestingHeartRate(rollups: [DailyRollupStoreEntry]) -> AtriaHighlight? {
        let sorted = rollups.sorted { $0.day > $1.day }
        guard let latest = sorted.first?.rhr else { return nil }
        let prior = sorted.dropFirst().prefix(7).compactMap(\.rhr)
        guard prior.count >= 3 else { return nil }
        let average = Double(prior.reduce(0, +)) / Double(prior.count)
        guard Double(latest) <= average - 2 else { return nil }
        return AtriaHighlight(id: "lower-rhr",
                              systemImage: "heart.fill",
                              valuePhrase: "↓ RHR",
                              sentence: "lower than usual",
                              tint: Metrics.electricGreen)
    }
}
