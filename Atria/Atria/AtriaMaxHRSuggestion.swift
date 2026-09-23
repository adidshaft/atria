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
    /// The suggestion learns max HR from what the strap has actually seen, so
    /// it must learn only from evidence that could be a real heartbeat:
    /// - `minimumSessions`: below three sessions the 95th percentile IS the
    ///   maximum, and one session decides the number.
    /// - `sustainedSeconds`: a peak counts only if the heart held it for half
    ///   a minute. A single-sample optical spike (a wrist knock reads 210
    ///   for one second) used to become "Observed peak 210 -- update max HR?"
    ///   and, if accepted, skewed every zone and strain score after it.
    /// - `maximumPlausiblePeak`: above this the reading is an artifact, not a
    ///   heart; it is dropped rather than ranked.
    static let minimumSessions = 3
    static let sustainedSeconds: Double = 30
    static let maximumPlausiblePeak = 225
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
        let plausiblePeaks = sessionPeaks.filter { $0 > 0 && $0 <= maximumPlausiblePeak }
        guard plausiblePeaks.count >= minimumSessions,
              let observedPeak = percentilePeak(plausiblePeaks),
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

    /// The highest heart rate a session held for `sustainedSeconds`: the
    /// maximum over every window of that length of the window's MINIMUM
    /// reading. A lone spike cannot pass; a real climb to a peak can.
    /// `t` is seconds (relative or absolute — only differences matter).
    /// Returns nil when no window has enough samples to say.
    static func sustainedPeak(points: [(t: Double, bpm: Int)],
                              seconds: Double = sustainedSeconds,
                              minimumSamples: Int = 3) -> Int? {
        let sorted = points.filter { $0.bpm > 0 }.sorted { $0.t < $1.t }
        guard sorted.count >= minimumSamples else { return nil }
        var best: Int?
        var end = 0
        for start in sorted.indices {
            let windowEnd = sorted[start].t + seconds
            if end < start { end = start }
            while end + 1 < sorted.count, sorted[end + 1].t <= windowEnd { end += 1 }
            let count = end - start + 1
            guard count >= minimumSamples,
                  sorted[end].t - sorted[start].t >= seconds * 0.8 else { continue }
            let floorOfWindow = sorted[start...end].map(\.bpm).min() ?? 0
            best = max(best ?? 0, floorOfWindow)
        }
        return best
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
