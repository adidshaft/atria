import Foundation

struct AtriaMaxHRSuggestion: Equatable {
    let observedPeak: Int
    let currentMaxHR: Int

    var title: String {
        "Observed peak \(observedPeak) -- update max HR?"
    }

    var detail: String {
        "Zones and strain use this."
    }
}

enum AtriaMaxHRSuggestionEngine {
    static let lookbackDays = 180
    static let percentile = 0.95
    static let triggerDelta = 3
    static let suppressDays = 60
    private static let dismissedKey = "atria.maxHRSuggestion.dismissed.v1"

    struct Dismissal: Codable, Equatable {
        let observedPeak: Int
        let dismissedAt: Date
    }

    static func suggestion(sessionPeaks: [Int],
                           currentMaxHR: Int,
                           dismissed: Dismissal? = nil,
                           now: Date = Date(),
                           calendar: Calendar = .current) -> AtriaMaxHRSuggestion? {
        guard let observedPeak = percentilePeak(sessionPeaks),
              observedPeak >= currentMaxHR + triggerDelta else {
            return nil
        }
        if let dismissed,
           dismissed.observedPeak >= observedPeak,
           let suppressUntil = calendar.date(byAdding: .day, value: suppressDays, to: dismissed.dismissedAt),
           now < suppressUntil {
            return nil
        }
        return AtriaMaxHRSuggestion(observedPeak: observedPeak, currentMaxHR: currentMaxHR)
    }

    static func percentilePeak(_ peaks: [Int]) -> Int? {
        let values = peaks.filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return nil }
        let index = min(values.count - 1, max(0, Int((Double(values.count - 1) * percentile).rounded(.up))))
        return values[index]
    }

    static func loadDismissal() -> Dismissal? {
        guard let data = UserDefaults.standard.data(forKey: dismissedKey) else { return nil }
        return try? JSONDecoder().decode(Dismissal.self, from: data)
    }

    static func saveDismissal(observedPeak: Int, now: Date = Date()) {
        guard let data = try? JSONEncoder().encode(Dismissal(observedPeak: observedPeak, dismissedAt: now)) else {
            return
        }
        UserDefaults.standard.set(data, forKey: dismissedKey)
    }

    static func clearDismissal() {
        UserDefaults.standard.removeObject(forKey: dismissedKey)
    }
}
