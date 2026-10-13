import Foundation

/// "Usually reached by 21:30" (W3.4): when, on recent days, cumulative day
/// strain first reached that day's Recovery-derived target.
///
/// One record per civil day, written the first time the published strain
/// meets the target, so cost is one small defaults write a day. The typical
/// time is the circular median of the last `windowDays` crossings and only
/// appears with `minimumCrossings` of them — before that, nothing is shown.
enum AtriaStrainPacing {
    static let storageKey = "atria.strainPacing.crossings.v1"
    static let windowDays = 21
    static let minimumCrossings = 5

    /// day key ("yyyy-MM-dd" in the civil calendar) -> minutes after midnight.
    typealias Crossings = [String: Int]

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Returns updated crossings when `strain` has just met `target` for the
    /// first time today, else nil (nothing to write). Old days are trimmed.
    static func recordingCrossing(strain: Double,
                                  target: Double?,
                                  now: Date,
                                  existing: Crossings,
                                  calendar: Calendar = .current) -> Crossings? {
        guard let target, target > 0, strain >= target else { return nil }
        let key = dayKey(now, calendar: calendar)
        guard existing[key] == nil else { return nil }
        var next = existing
        let c = calendar.dateComponents([.hour, .minute], from: now)
        next[key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if let cutoff = calendar.date(byAdding: .day, value: -(windowDays * 2), to: now) {
            let cutoffKey = dayKey(cutoff, calendar: calendar)
            next = next.filter { $0.key >= cutoffKey }
        }
        return next
    }

    /// Circular median crossing minute over the window, excluding today.
    static func typicalCrossingMinute(crossings: Crossings,
                                      now: Date,
                                      calendar: Calendar = .current) -> Int? {
        guard let start = calendar.date(byAdding: .day, value: -windowDays, to: now) else { return nil }
        let startKey = dayKey(start, calendar: calendar)
        let todayKey = dayKey(now, calendar: calendar)
        let minutes = crossings.filter { $0.key >= startKey && $0.key < todayKey }.map(\.value)
        guard minutes.count >= minimumCrossings else { return nil }
        // Unwrap around the circular mean so 23:50 and 00:10 stay 20 min apart.
        let radians = minutes.map { Double($0) / 1440 * 2 * .pi }
        var meanAngle = atan2(radians.map(sin).reduce(0, +), radians.map(cos).reduce(0, +))
        if meanAngle < 0 { meanAngle += 2 * .pi }
        let anchor = Int(meanAngle / (2 * .pi) * 1440)
        let unwrapped = minutes.map { m -> Int in
            var d = m - anchor
            if d > 720 { d -= 1440 } else if d < -720 { d += 1440 }
            return anchor + d
        }.sorted()
        let median = unwrapped[unwrapped.count / 2]
        return ((median % 1440) + 1440) % 1440
    }

    static func timeText(_ minute: Int) -> String {
        String(format: "%d:%02d", minute / 60, minute % 60)
    }

    // MARK: Persistence (UserDefaults, tiny)

    static func load(_ defaults: UserDefaults = .standard) -> Crossings {
        (defaults.dictionary(forKey: storageKey) as? [String: Int]) ?? [:]
    }

    static func save(_ crossings: Crossings, _ defaults: UserDefaults = .standard) {
        defaults.set(crossings, forKey: storageKey)
    }

    /// Call when the hero publishes a new strain value.
    static func noteStrain(_ strain: Double, target: Double?, now: Date = Date(),
                           defaults: UserDefaults = .standard) {
        guard let target, strain >= target else { return }
        if let next = recordingCrossing(strain: strain, target: target, now: now,
                                        existing: load(defaults)) {
            save(next, defaults)
        }
    }
}
