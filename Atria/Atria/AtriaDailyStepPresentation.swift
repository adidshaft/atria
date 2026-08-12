import Foundation

/// Typed, pure motion-availability authority. Distinguishes a terminal pure-HR
/// fallback (motion genuinely unavailable in the current transport) from
/// protected-R10 modes that still carry, or can still qualify, motion — so no
/// surface labels motion "unavailable" merely because the HR-minimal radio flag
/// is set. Resolved from a plain input snapshot so it is unit-testable with no
/// BLE state. `unavailableInCurrentTransport` requires the exact terminal
/// conjunction; anything short of that fails closed to `stale`/`unknown`.
enum AtriaStrapMotionAvailability: Equatable, Sendable {
    /// Fresh validated R10/IMU/live-motion evidence exists.
    case live
    /// A legitimate motion-bank/compact offload is active or pending.
    case catchingUp
    /// Protected owner is launch-pending/proving; qualification not yet failed.
    case qualifying
    /// Prior verified motion exists but is no longer current; no proof yet that
    /// the transport is terminally motionless.
    case stale
    /// Exact evidence proves a pure-HR fallback cannot deliver motion now.
    case unavailableInCurrentTransport
    /// Evidence insufficient — fail closed rather than invent a motion blocker.
    case unknown

    /// Motion is "fresh" within this window (seconds). Aligns with the
    /// protected-R10 missing-frame timeout that already governs the transport.
    static let motionFreshnessWindow: TimeInterval = 20

    struct Input: Equatable, Sendable {
        var cleanOwner: AtriaBLEManager.ProtectedR10CleanOwner
        var cleanOwnerState: AtriaBLEManager.ProtectedR10CleanOwnerState
        var streamSuppressed: Bool
        /// Age (s) of the freshest validated R10/IMU/live-motion frame; nil = none.
        var freshMotionAge: TimeInterval?
        /// A legitimate app-owned motion-bank offload is active or pending.
        var hasActiveMotionBankOffload: Bool
        /// Any prior verified motion/step evidence exists (coverage or steps > 0).
        var hasPriorVerifiedMotion: Bool
        var freshnessWindow: TimeInterval = AtriaStrapMotionAvailability.motionFreshnessWindow
    }

    static func resolve(_ input: Input) -> AtriaStrapMotionAvailability {
        // 1. Fresh validated motion wins regardless of an older fallback marker.
        if let age = input.freshMotionAge, age >= 0, age <= input.freshnessWindow {
            return .live
        }
        // 2. A legitimate motion-bank offload catching up is not "unavailable".
        if input.hasActiveMotionBankOffload {
            return .catchingUp
        }
        // 3. Protected owner still launch-pending/proving: bounded qualification
        //    has not terminally failed, so motion may still arrive.
        switch input.cleanOwnerState {
        case .protectedLaunchPending, .proving:
            return .qualifying
        default:
            break
        }
        // 4. Terminal pure-HR fallback — the ONLY unavailable state: a pure-HR
        //    owner in a terminal fallback state with the R10 stream suppressed,
        //    no fresh motion, no active qualification, and no catching-up offload
        //    (2 and 3 above already excluded those). protectedV9 + qualified can
        //    never reach here.
        let isPureHROwner = input.cleanOwner == .pureHRV8 || input.cleanOwner == .pureHRV10
        let isTerminalFallback = input.cleanOwnerState == .fallbackActive
            || input.cleanOwnerState == .fallbackPending
        if isPureHROwner, isTerminalFallback, input.streamSuppressed {
            return .unavailableInCurrentTransport
        }
        // 5. Prior verified motion but no proof the transport is terminally
        //    motionless: stale, not terminal.
        if input.hasPriorVerifiedMotion {
            return .stale
        }
        // 6. Insufficient evidence: fail closed.
        return .unknown
    }
}

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
    /// Typed strap-motion authority for the forward-looking step copy. `nil`
    /// (default) preserves the existing progress wording for every caller that
    /// does not classify motion; the call site sets it from the BLE snapshot.
    var motionAvailability: AtriaStrapMotionAvailability? = nil

    /// Overrides the forward-looking "fills in as your strap syncs" line when the
    /// exact motion authority proves it will not. The verified count/coverage are
    /// untouched — only the progress promise changes. Returns nil to keep the
    /// existing copy for live/catchingUp/qualifying/stale and unclassified.
    var motionAvailabilityFootnote: String? {
        switch motionAvailability {
        case .unavailableInCurrentTransport:
            return "Strap motion is unavailable in the current connection mode. "
                + "Live heart rate is still connected."
        case .unknown:
            return "Counted so far — updates when strap motion syncs."
        case .live, .catchingUp, .qualifying, .stale, .none:
            return nil
        }
    }

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
            // 2026-08-12 user decision: the glance line must NOT lead with a
            // coverage percent. The number is honest (how much of the elapsed
            // day the strap actually recorded step-motion for — a data-
            // coverage figure, not a sync grade and not an activity level),
            // but "32% covered/tracked" reliably reads as "the strap is
            // detecting my steps wrong". On the HR-only radio mode the strap
            // only banks motion in short windows, so a fully-synced day
            // legitimately reads low (~1h of motion over a 14h day). The
            // frontier timestamp says the same true thing — this count is
            // what's known up to that time — without the failure connotation.
            // The explained percent stays available in `accessibilityText`.
            // Never say "synced" (reads as "barely uploaded") and never say
            // "moving" (reads as "you were only active N%").
            if let capturedAt {
                return "Counted through "
                    + capturedAt.formatted(date: .omitted, time: .shortened)
            }
            return coverageFraction != nil ? "Partial day so far" : "Syncing steps"
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
            let coverage = coverageFraction.map {
                "motion tracked for \(Int(($0 * 100).rounded())) percent of your day"
            } ?? "partially tracked"
            let frontier = capturedAt.map {
                ", through \($0.formatted(date: .omitted, time: .shortened))"
            } ?? ""
            return "At least \(count) steps, \(coverage)\(frontier)."
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
        // A live strap subtotal is only an open-day source while its
        // detector-applied coordinate is fresh. A restored prefix is retained
        // in the strap detail view as "Not live", but it cannot silently
        // masquerade as today's current count. Once validated, this exact
        // current-cycle coordinate outranks an older partial archive lower
        // bound (without summing them); a complete canonical receipt and an
        // exact-receipt conflict still retain precedence above.
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
        // Without a fresh validated live coordinate, the best durable partial
        // remains the honest lower bound for the active cycle.
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
