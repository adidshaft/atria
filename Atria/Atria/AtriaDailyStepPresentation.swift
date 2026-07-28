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
        case verifiedCanonical
        case none
    }

    enum UnavailabilityReason: Equatable, Sendable {
        case none
        case noCurrentCycleReceipt
        case staleLiveReceipt
        case unvalidatedLiveReceipt
        case conflictingExactReceipts
    }

    let day: Date
    let count: Int?
    let completeness: Completeness
    let source: Source
    let isValidated: Bool
    let capturedAt: Date?
    let coverageFraction: Double?
    var unavailabilityReason: UnavailabilityReason = .none

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
        default:
            switch unavailabilityReason {
            case .staleLiveReceipt:
                return "Last strap movement is no longer live"
            case .unvalidatedLiveReceipt:
                return "Strap motion is still validating"
            case .conflictingExactReceipts:
                return "Conflicting verified strap receipts"
            case .none, .noCurrentCycleReceipt:
                return "No verified receipt for this cycle"
            }
        }
    }

    var accessibilityText: String {
        guard let count else { return "Step count unavailable. \(detailText)." }
        switch (source, completeness) {
        case (.verifiedCanonical, .complete):
            return "\(count) steps. Verified complete day."
        case (.verifiedCanonical, .partial):
            return "At least \(count) steps. Partial verified archive coverage."
        case (.live, .partial):
            return "\(isValidated ? "\(count)" : "Approximately \(count)") steps today so far."
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
        let isOpenDay = isToday || usesPhysiologicalOpenWindow
        let liveBelongsToDay = liveCapturedAt.map {
            $0 >= activeWindowStart
                && $0 <= now.addingTimeInterval(5)
                && now.timeIntervalSince($0) <= liveEvidenceMaximumAge
        } ?? false
        let liveIsValidated = WidgetSnapshotPublisher.strapStepsAreValidated(
            state: liveValidationState
        )
        let physiologicalMatching = usesPhysiologicalOpenWindow
            ? canonicalDays.filter {
                abs($0.dayStart.timeIntervalSince(activeWindowStart)) < 1
            }
            : []

        let civilMatching = canonicalDays.filter {
            calendar.isDate($0.dayStart, inSameDayAs: dayStart)
        }
        // A current wake-to-wake v24 projection is more specific than a civil
        // archive day. Prefer its exact boundary instead of mixing two
        // differently bounded subtotals and selecting whichever is larger.
        let matching = physiologicalMatching.isEmpty
            ? civilMatching
            : physiologicalMatching
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
        if completeCounts.count > 1 {
            return .init(day: dayStart,
                         count: nil,
                         completeness: .unavailable,
                         source: .none,
                         isValidated: false,
                         capturedAt: nil,
                         coverageFraction: nil,
                         unavailabilityReason: .conflictingExactReceipts)
        }
        let partial = completeCounts.isEmpty
            ? matching
            .filter({ $0.state == .missing && $0.knownCoverageSeconds > 0 })
            .max(by: {
                if $0.knownCoverageSeconds != $1.knownCoverageSeconds {
                    return $0.knownCoverageSeconds < $1.knownCoverageSeconds
                }
                return $0.knownEpochCount < $1.knownEpochCount
            })
            : nil
        // A durable receipt, including a partial lower bound, remains the
        // authority wherever one exists. Live detector state is considered
        // only when no receipt has been published for the active cycle.
        if let partial {
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
        // A live strap subtotal is only an open-day source while its
        // detector-applied coordinate is fresh. A restored prefix is retained
        // in the strap detail view as "Not live", but it cannot silently
        // masquerade as today's current count.
        if isOpenDay, liveBelongsToDay, liveIsValidated {
            return .init(day: dayStart,
                         count: max(0, liveCount),
                         completeness: .partial,
                         source: .live,
                         isValidated: true,
                         capturedAt: liveCapturedAt,
                         coverageFraction: nil)
        }
        return .init(day: dayStart,
                     count: nil,
                     completeness: .unavailable,
                     source: .none,
                     isValidated: false,
                     capturedAt: nil,
                     coverageFraction: nil,
                     unavailabilityReason:
                        liveCapturedAt == nil
                            ? .noCurrentCycleReceipt
                            : (liveBelongsToDay
                               ? .unvalidatedLiveReceipt : .staleLiveReceipt))
    }
}
