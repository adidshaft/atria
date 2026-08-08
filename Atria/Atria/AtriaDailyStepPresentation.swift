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
        /// 2026-07-31: the open cycle has no receipt or fresh live sample yet,
        /// but the preceding cycle closed with a verified receipt. The count
        /// stays nil — prior-cycle steps are disclosed in copy only and are
        /// never attributed to today.
        case priorCycleReceiptOnly
        case staleLiveReceipt
        case unvalidatedLiveReceipt
        case motionObservedCountUnresolved
        case conflictingExactReceipts
        case stepModelNotQualified
    }

    /// Disclosure-only summary of the newest receipt that ended at or before
    /// the current wake boundary. Carried alongside a nil `count` so rings,
    /// zones, and widget step values remain honestly empty.
    struct PriorCycleReceipt: Equatable, Sendable {
        let steps: Int
        let endedAt: Date
    }

    let day: Date
    let count: Int?
    let completeness: Completeness
    let source: Source
    let isValidated: Bool
    let capturedAt: Date?
    let coverageFraction: Double?
    var unavailabilityReason: UnavailabilityReason = .none
    /// Coverage can be complete through the current projection boundary while
    /// the physiological day itself is still open. Keep those two facts
    /// separate so an exact "today so far" count is never described as a
    /// completed day.
    var isOpenCycle: Bool = false
    /// A durable exact subtotal remains exact after its collection clock ages,
    /// but it no longer describes the current edge of an open physiological
    /// cycle. Keep the count and make that time boundary explicit in copy.
    var openCycleReceiptIsCurrent: Bool = false
    /// Set only with `unavailabilityReason == .priorCycleReceiptOnly`.
    var priorCycleReceipt: PriorCycleReceipt? = nil

    var valueText: String {
        // Strap steps are ~2% accurate, so the card shows a clean number rather
        // than a "≥"/"~" qualifier. The partial/live/estimate nuance lives in
        // `detailText` (shown when the user taps the metric) and in
        // `accessibilityText`.
        guard let count else { return "--" }
        // A zero observed inside a small archive fragment is not a zero for
        // the day. Showing it as one makes an absence of evidence look like a
        // completed step total (for example "0 · 3% covered").
        guard completeness != .partial || count > 0 else { return "--" }
        return "\(count)"
    }

    var detailText: String {
        switch (source, completeness) {
        case (.verifiedCanonical, .complete):
            if isOpenCycle {
                return openCycleReceiptIsCurrent
                    ? "Today so far · verified"
                    : verifiedThroughText
            }
            return "Verified complete day"
        case (.verifiedCanonical, .partial):
            // Progress framing, not a failure grade (2026-08-08 user note): the
            // strap motion engine IS counting; the day just fills in as more
            // motion syncs off the strap. "Partial · X% covered" read as broken.
            if let coverageFraction {
                let coverage = Int((coverageFraction * 100).rounded())
                if count == 0 {
                    return "Syncing today's steps from your strap · \(coverage)% so far"
                }
                return "Today so far · \(coverage)% synced from strap"
            }
            return "Syncing steps from your strap"
        case (.live, .partial):
            return isValidated ? "Today so far · live" : "Today so far · estimate"
        default:
            switch unavailabilityReason {
            case .priorCycleReceiptOnly:
                guard let priorCycleReceipt else {
                    return "No verified receipt for this cycle"
                }
                // The prior count is a lower bound: its cycle may have ended
                // with unbanked motion. Never present it as today's value.
                // Plain-language pass (2026-08-01): when the prior cycle ended
                // on the previous civil day — or overnight today before 6 AM,
                // which humans still read as "yesterday's total" — say
                // "Yesterday" instead of the technical "Prior cycle … ended".
                if priorCycleReadsAsYesterday(priorCycleReceipt) {
                    return "Yesterday: ≥\(priorCycleReceipt.steps)"
                }
                return "Prior cycle: ≥\(priorCycleReceipt.steps) · ended "
                    + priorCycleReceipt.endedAt.formatted(
                        date: .omitted,
                        time: .shortened
                    )
            case .staleLiveReceipt:
                return "Last strap movement is no longer live"
            case .unvalidatedLiveReceipt:
                return "Strap motion is still validating"
            case .motionObservedCountUnresolved:
                return "Strap motion found · count still resolving"
            case .conflictingExactReceipts:
                return "Conflicting verified strap receipts"
            case .stepModelNotQualified:
                return "Strap step model is still validating"
            case .none, .noCurrentCycleReceipt:
                return "No verified receipt for this cycle"
            }
        }
    }

    var accessibilityText: String {
        guard let count,
              !(completeness == .partial && count == 0) else {
            return "Step count unavailable. \(detailText)."
        }
        switch (source, completeness) {
        case (.verifiedCanonical, .complete):
            if isOpenCycle {
                return openCycleReceiptIsCurrent
                    ? "\(count) verified steps today so far."
                    : "\(count) steps. \(verifiedThroughText)."
            }
            return "\(count) steps. Verified complete day."
        case (.verifiedCanonical, .partial):
            return "At least \(count) steps so far, still syncing from your strap."
        case (.live, .partial):
            return "\(isValidated ? "\(count)" : "Approximately \(count)") steps today so far."
        default:
            return "Step count unavailable."
        }
    }

    /// The prior cycle reads as "yesterday's total" when its END fell on the
    /// previous civil day, or on today's civil day before 6 AM (an overnight
    /// close like 1:44 AM is still last night's total to a human). Any older
    /// or later end keeps the precise "Prior cycle … ended" disclosure.
    /// Pure and calendar-injectable so the boundary is unit-testable.
    func priorCycleReadsAsYesterday(_ receipt: PriorCycleReceipt,
                                    calendar: Calendar = .current) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else {
            return false
        }
        if calendar.isDate(receipt.endedAt, inSameDayAs: yesterday) { return true }
        guard calendar.isDate(receipt.endedAt, inSameDayAs: day),
              let sixAM = calendar.date(byAdding: .hour, value: 6, to: calendar.startOfDay(for: day))
        else { return false }
        return receipt.endedAt < sixAM
    }

    private var verifiedThroughText: String {
        guard let capturedAt else { return "Verified earlier in this cycle" }
        return "Verified through \(capturedAt.formatted(date: .omitted, time: .shortened))"
    }

    static func resolve(
        day: Date,
        now: Date,
        liveCount: Int,
        liveValidationState: String,
        liveCapturedAt: Date?,
        canonicalDays: [AtriaHistoricalDailyConsumerProjection.StepDay],
        /// The connected live detector is a product source only after the same
        /// model has passed autonomous counted walks and arm-motion controls.
        /// Research counters remain available to diagnostics but cannot leak
        /// onto Home or widgets.
        liveAuthorityQualified: Bool = true,
        /// Live strap totals are attributed wake-to-wake. When a completed
        /// main sleep has not arrived, this can deliberately begin on the
        /// preceding civil date; a fresh post-midnight sample must still be
        /// eligible to keep the active day visible.
        physiologicalDayStart: Date? = nil,
        /// 2026-07-31: newest receipt ending before the current wake boundary,
        /// disclosed in copy only when the open cycle has nothing to show.
        priorCycleReceipt: PriorCycleReceipt? = nil,
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
            let capturedAt = matching.map(\.dayEnd).max()
            let capturedAge = capturedAt.map { now.timeIntervalSince($0) }
            let openCycleReceiptIsCurrent = capturedAge.map {
                $0 >= -5 && $0 <= liveEvidenceMaximumAge
            } ?? false
            return .init(day: dayStart,
                         count: exact,
                         completeness: .complete,
                         source: .verifiedCanonical,
                         isValidated: true,
                         capturedAt: capturedAt,
                         coverageFraction: 1,
                         isOpenCycle: isOpenDay,
                         openCycleReceiptIsCurrent: openCycleReceiptIsCurrent)
        }
        if completeCounts.count > 1 {
            return .init(day: dayStart,
                         count: nil,
                         completeness: .unavailable,
                         source: .none,
                         isValidated: false,
                         capturedAt: nil,
                         coverageFraction: nil,
                         unavailabilityReason: .conflictingExactReceipts,
                         isOpenCycle: isOpenDay)
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
        let hasUnresolvedMotionReceipt = matching.contains {
            $0.state == .missing
                && $0.knownEpochCount > 0
                && $0.knownCoverageSeconds == 0
        }
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
                            ? Double(partial.knownCoverageSeconds) / Double(total) : nil,
                         isOpenCycle: isOpenDay)
        }
        // A live strap subtotal is only an open-day source while its
        // detector-applied coordinate is fresh. A restored prefix is retained
        // in the strap detail view as "Not live", but it cannot silently
        // masquerade as today's current count.
        if liveAuthorityQualified,
           isOpenDay,
           liveBelongsToDay,
           liveIsValidated {
            return .init(day: dayStart,
                         count: max(0, liveCount),
                         completeness: .partial,
                         source: .live,
                         isValidated: true,
                         capturedAt: liveCapturedAt,
                         coverageFraction: nil,
                         isOpenCycle: isOpenDay)
        }
        let emptyReason: UnavailabilityReason =
            !liveAuthorityQualified
                ? .stepModelNotQualified
                : (hasUnresolvedMotionReceipt
                ? .motionObservedCountUnresolved
                : (liveCapturedAt == nil
                    ? .noCurrentCycleReceipt
                    : (liveBelongsToDay
                       ? .unvalidatedLiveReceipt
                       : .staleLiveReceipt)))
        // 2026-07-31: when the no-sleep fallback rolls the wake boundary, the
        // fresh cycle legitimately has no receipt and no live sample yet.
        // Disclose the prior cycle's verified subtotal in copy instead of an
        // unexplained "--", while the count itself stays nil so prior steps
        // are never attributed to today. A live sample captured before the
        // boundary is that same prior cycle, not a stale sample of this one.
        let staleLiveIsFromPriorCycle = emptyReason == .staleLiveReceipt
            && liveCapturedAt.map { $0 < activeWindowStart } == true
        let disclosesPriorCycle = priorCycleReceipt != nil
            && (emptyReason == .noCurrentCycleReceipt
                || staleLiveIsFromPriorCycle)
        return .init(day: dayStart,
                     count: nil,
                     completeness: .unavailable,
                     source: .none,
                     isValidated: false,
                     capturedAt: nil,
                     coverageFraction: nil,
                     unavailabilityReason: disclosesPriorCycle
                        ? .priorCycleReceiptOnly
                        : emptyReason,
                     isOpenCycle: isOpenDay,
                     priorCycleReceipt: disclosesPriorCycle
                        ? priorCycleReceipt
                        : nil)
    }
}
