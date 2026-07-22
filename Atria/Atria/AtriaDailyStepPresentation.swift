import Foundation

/// One honest value for step surfaces. A verified closed archive day is exact;
/// a live count or a gapped archive subtotal is explicitly partial.
struct AtriaDailyStepPresentation: Equatable, Sendable {
    /// R10 emits one detector-applied coordinate per device second.  A saved
    /// subtotal must never remain the open day's "live" source once that
    /// stream has stopped: it may be an honest historical estimate, but using
    /// it to outrank a fresh phone total makes an old undercount look current.
    /// Keep this aligned with the strap-steps freshness tile.
    static let liveEvidenceMaximumAge: TimeInterval = 15

    enum Completeness: Equatable, Sendable {
        case complete
        case partial
        case unavailable
    }

    enum Source: Equatable, Sendable {
        case live
        case phone
        case verifiedCanonical
        case none
    }

    let day: Date
    let count: Int?
    let completeness: Completeness
    let source: Source
    let isValidated: Bool
    let capturedAt: Date?
    let coverageFraction: Double?

    var valueText: String {
        guard let count else { return "--" }
        switch (source, completeness, isValidated) {
        case (.verifiedCanonical, .partial, _): return "≥\(count)"
        case (_, _, false): return "~\(count)"
        default: return "\(count)"
        }
    }

    var detailText: String {
        switch (source, completeness) {
        case (.verifiedCanonical, .complete):
            return "Verified complete day"
        case (.verifiedCanonical, .partial):
            if let coverageFraction {
                return "Partial archive · \(Int((coverageFraction * 100).rounded()))% covered"
            }
            return "Partial archive coverage"
        case (.live, .partial):
            return isValidated ? "Today so far · live" : "Today so far · estimate"
        case (.phone, .partial):
            return "Today so far · iPhone"
        case (.phone, .complete):
            return "Complete day · iPhone"
        default:
            return "No verified step coverage"
        }
    }

    var accessibilityText: String {
        guard let count else { return "Step count unavailable. No verified step coverage." }
        switch (source, completeness) {
        case (.verifiedCanonical, .complete):
            return "\(count) steps. Verified complete day."
        case (.verifiedCanonical, .partial):
            return "At least \(count) steps. Partial verified archive coverage."
        case (.live, .partial):
            return "\(isValidated ? "\(count)" : "Approximately \(count)") steps today so far."
        case (.phone, .partial):
            return "\(count) steps today so far, measured by iPhone motion."
        case (.phone, .complete):
            return "\(count) steps, measured across the complete day by iPhone motion."
        default:
            return "Step count unavailable."
        }
    }

    static func resolve(
        day: Date,
        now: Date,
        liveCount: Int,
        liveValidationState: String,
        liveCapturedAt: Date?,
        phoneCount: Int? = nil,
        phoneCapturedAt: Date? = nil,
        canonicalDays: [AtriaHistoricalDailyConsumerProjection.StepDay],
        /// Live strap totals are attributed wake-to-wake. When a completed
        /// main sleep has not arrived, this can deliberately begin on the
        /// preceding civil date; a fresh post-midnight sample must still be
        /// eligible to keep the active day visible.
        physiologicalDayStart: Date? = nil,
        calendar: Calendar = .current
    ) -> Self {
        let dayStart = calendar.startOfDay(for: day)
        let isToday = calendar.isDate(dayStart, inSameDayAs: now)
        let activeWindowStart = physiologicalDayStart ?? dayStart
        let usesPhysiologicalOpenWindow = physiologicalDayStart != nil
            && activeWindowStart <= now
        let crossesCivilMidnight = usesPhysiologicalOpenWindow
            && !calendar.isDate(activeWindowStart, inSameDayAs: now)
        let isOpenDay = isToday || usesPhysiologicalOpenWindow
        let liveBelongsToDay = liveCapturedAt.map {
            $0 >= activeWindowStart
                && $0 <= now.addingTimeInterval(5)
                && now.timeIntervalSince($0) <= liveEvidenceMaximumAge
        } ?? false
        let cachedPhone = AtriaPhoneDailyStepStore.cached(day: dayStart, calendar: calendar)
        let resolvedPhoneCount = phoneCount ?? cachedPhone?.count
        let resolvedPhoneCapturedAt = phoneCapturedAt ?? cachedPhone?.capturedAt
        // Both sources are cumulative day totals with unknown overlap, so they
        // must never be added. The iPhone can legitimately report zero (or a
        // small subtotal) while it sits on a bench during a strap-worn walk or
        // workout. For the open day, retain the larger same-day total instead
        // of allowing that stationary-phone result to erase wrist evidence.
        if isOpenDay,
           !crossesCivilMidnight,
           let resolvedPhoneCount,
           let resolvedPhoneCapturedAt,
           resolvedPhoneCapturedAt <= now.addingTimeInterval(5),
           liveBelongsToDay,
           liveCount > resolvedPhoneCount {
            return .init(day: dayStart,
                         count: max(0, liveCount),
                         completeness: .partial,
                         source: .live,
                         isValidated: WidgetSnapshotPublisher.strapStepsAreValidated(
                            state: liveValidationState
                         ),
                         capturedAt: liveCapturedAt,
                         coverageFraction: nil)
        }
        if !crossesCivilMidnight,
           let resolvedPhoneCount, let resolvedPhoneCapturedAt,
           resolvedPhoneCapturedAt <= now.addingTimeInterval(5) {
            return .init(day: dayStart,
                         count: max(0, resolvedPhoneCount),
                         completeness: isOpenDay ? .partial : .complete,
                         source: .phone,
                         isValidated: true,
                         capturedAt: resolvedPhoneCapturedAt,
                         coverageFraction: isOpenDay ? nil : 1)
        }
        // A live strap subtotal is only an open-day source while its
        // detector-applied coordinate is fresh.  A restored prefix is retained
        // in the strap detail view as "Not live", but it cannot silently
        // masquerade as today's current count or mask a fresh phone total.
        if isOpenDay, liveBelongsToDay {
            return .init(day: dayStart,
                         count: max(0, liveCount),
                         completeness: .partial,
                         source: .live,
                         isValidated: WidgetSnapshotPublisher.strapStepsAreValidated(
                            state: liveValidationState
                         ),
                         capturedAt: liveCapturedAt,
                         coverageFraction: nil)
        }

        let matching = canonicalDays.filter {
            calendar.isDate($0.dayStart, inSameDayAs: dayStart)
        }
        let completeCounts = Set(matching.compactMap { candidate -> Int? in
            guard candidate.state == .available || candidate.state == .knownEmpty else {
                return nil
            }
            return candidate.stepCount
        })
        // Conflicting exact generations are withheld instead of selecting a
        // convenient number. A later repaired page can resolve the conflict.
        if completeCounts.count == 1, let exact = completeCounts.first {
            return .init(day: dayStart,
                         count: exact,
                         completeness: .complete,
                         source: .verifiedCanonical,
                         isValidated: true,
                         capturedAt: matching.map(\.dayEnd).max(),
                         coverageFraction: 1)
        }
        if completeCounts.isEmpty,
           let partial = matching
            .filter({ $0.state == .missing && $0.knownCoverageSeconds > 0 })
            .max(by: {
                if $0.knownCoverageSeconds != $1.knownCoverageSeconds {
                    return $0.knownCoverageSeconds < $1.knownCoverageSeconds
                }
                return $0.knownEpochCount < $1.knownEpochCount
            }) {
            let total = partial.knownCoverageSeconds + partial.missingCoverageSeconds
            return .init(day: dayStart,
                         count: partial.knownStepDeltaSum,
                         completeness: .partial,
                         source: .verifiedCanonical,
                         isValidated: true,
                         capturedAt: partial.dayEnd,
                         coverageFraction: total > 0
                            ? Double(partial.knownCoverageSeconds) / Double(total) : nil)
        }
        return .init(day: dayStart,
                     count: nil,
                     completeness: .unavailable,
                     source: .none,
                     isValidated: false,
                     capturedAt: nil,
                     coverageFraction: nil)
    }
}
