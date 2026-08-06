import Foundation

/// Selects only real, closed missing-data intervals. It never derives request
/// bounds from returned archive rows, archive mtimes, or terminal wall time.
enum AtriaBLEHistoryExactRequestPolicy {
    static func resolve(
        pending: Bool,
        explicitStart: Any?,
        explicitEnd: Any?,
        gapWindows: [AtriaHistoricalGapLedger.Window],
        now: Date,
        maximumAge: TimeInterval = AtriaHistoricalGapLedger.maximumRecoverableAnchorAge
    ) -> AtriaBLEHistoryRequestAuthorityStore.ExactRequest? {
        guard pending else { return nil }
        if let start = date(explicitStart),
           let end = date(explicitEnd),
           valid(start: start, end: end, now: now, maximumAge: maximumAge) {
            return .init(sourceIdentifier: "explicit-recovery-window-v1",
                         requestedStartUnix: start.timeIntervalSince1970,
                         requestedEndUnix: end.timeIntervalSince1970)
        }
        guard let window = gapWindows
            .filter({ window in
                guard let end = window.end else { return false }
                return valid(start: window.start, end: end, now: now, maximumAge: maximumAge)
            })
            .sorted(by: { $0.start < $1.start })
            .first,
              let end = window.end else { return nil }
        return .init(sourceIdentifier: "gap-window-\(window.id.uuidString.lowercased())",
                     requestedStartUnix: window.start.timeIntervalSince1970,
                     requestedEndUnix: end.timeIntervalSince1970)
    }

    private static func date(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw.isFinite else { return nil }
            return Date(timeIntervalSince1970: raw)
        }
        return nil
    }

    private static func valid(start: Date,
                              end: Date,
                              now: Date,
                              maximumAge: TimeInterval) -> Bool {
        let duration = end.timeIntervalSince(start)
        return start.timeIntervalSince1970.isFinite
            && end.timeIntervalSince1970.isFinite
            && start.timeIntervalSince1970 > 0
            && duration >= AtriaHistoricalGapLedger.coverageBucketSeconds
            && duration <= maximumAge
            && end <= now.addingTimeInterval(5)
            && now.timeIntervalSince(start) <= maximumAge
    }
}
