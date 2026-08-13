import Foundation

// Handoff-10 CP1: one explicit presentation identity for every surface that
// labels itself "Today". The physiological wake-to-wake cycle stays the math
// authority — this layer only decides WHAT a Today-labelled surface may show
// as its primary value, and forces prior-cycle values into a clearly dated
// disclosure instead of silently wearing today's label.

enum AtriaMetricPresentationValueState: String, Codable, Equatable, Sendable {
    /// The value's source civil day IS the displayed civil day.
    case current
    /// Today's own partial evidence (e.g. the RHR-only limited recovery row).
    case currentPartial
    /// A prior cycle's value, permitted ONLY as a dated secondary line.
    case priorCycleDisclosure
    /// No current-day value exists yet.
    case awaitingCurrentSleep
}

struct AtriaMetricPresentationIdentity: Equatable, Sendable {
    let displayCivilDay: Date
    let cycleStart: Date
    let cycleEnd: Date?
    let sourceSleepID: String?
    let sourceCivilDay: Date?
    let valueState: AtriaMetricPresentationValueState
    let calculatedAt: Date
}

/// The last confirmed cycle's triple, shown only as a dated secondary line —
/// never as a primary ring value or fill.
struct AtriaPriorCycleDisclosure: Equatable, Sendable {
    let civilDay: Date
    let recoveryPercent: Int?
    let sleepSeconds: TimeInterval?
    let strain: Double?

    var dateText: String {
        civilDay.formatted(.dateTime.month(.abbreviated).day())
    }
}

enum AtriaCurrentDayPresentation {
    static let awaitingCurrentSleepDetail = "Awaiting current sleep"

    struct Resolution: Equatable, Sendable {
        let identity: AtriaMetricPresentationIdentity
        /// Non-nil replaces the cycle projection as the PRIMARY recovery.
        let recoveryOverride: Metrics.RecoveryEstimate?
        /// Non-nil replaces the cycle-windowed strain as the PRIMARY strain.
        let strainOverride: Double?
        /// True when the sleep ring must show `--` / awaiting instead of a
        /// prior night's hours and fill.
        let sleepIsAwaitingCurrentSleep: Bool
        let priorCycle: AtriaPriorCycleDisclosure?
    }

    /// Decides the Today-labelled primary values. `cycleValueSourceDay` is the
    /// civil day the current cycle's frozen values belong to (the anchoring
    /// wake's civil day for `.mainSleep`, the fallback boundary's civil day
    /// otherwise). When it differs from the displayed civil day, the cycle's
    /// values may not be today's primary — regardless of whether the
    /// wake-to-wake rollover has fired yet.
    static func resolve(
        now: Date,
        cycleStart: Date,
        cycleEnd: Date?,
        anchorSleepID: String?,
        cycleValueSourceDay: Date?,
        currentDayPartialRecovery: Metrics.RecoveryEstimate?,
        currentDayPartialStrain: Double?,
        priorCycle: AtriaPriorCycleDisclosure?,
        calendar: Calendar = .current
    ) -> Resolution {
        let displayCivilDay = calendar.startOfDay(for: now)
        let sourceIsToday = cycleValueSourceDay.map {
            calendar.isDate($0, inSameDayAs: displayCivilDay)
        } ?? false

        if sourceIsToday {
            return Resolution(
                identity: .init(
                    displayCivilDay: displayCivilDay,
                    cycleStart: cycleStart,
                    cycleEnd: cycleEnd,
                    sourceSleepID: anchorSleepID,
                    sourceCivilDay: cycleValueSourceDay,
                    valueState: .current,
                    calculatedAt: now
                ),
                recoveryOverride: nil,
                strainOverride: nil,
                sleepIsAwaitingCurrentSleep: false,
                priorCycle: nil
            )
        }

        // The displayed day is NOT the day the cycle's values belong to.
        // Today's own partial evidence (with its real limited confidence) is
        // the only number allowed; otherwise the rings are terminal awaiting
        // states. The prior cycle survives only as a dated disclosure.
        let hasPartial = currentDayPartialRecovery?.percent != nil
        return Resolution(
            identity: .init(
                displayCivilDay: displayCivilDay,
                cycleStart: cycleStart,
                cycleEnd: cycleEnd,
                sourceSleepID: nil,
                sourceCivilDay: hasPartial ? displayCivilDay : nil,
                valueState: hasPartial ? .currentPartial : .awaitingCurrentSleep,
                calculatedAt: now
            ),
            recoveryOverride: currentDayPartialRecovery ?? Metrics.RecoveryEstimate(
                percent: nil,
                confidence: .learning,
                usesHRV: false,
                detail: awaitingCurrentSleepDetail,
                contributors: []
            ),
            strainOverride: currentDayPartialStrain ?? 0,
            sleepIsAwaitingCurrentSleep: true,
            priorCycle: priorCycle
        )
    }

    /// True when a display sleep may be today's PRIMARY ring value/fill: its
    /// wake (end) must fall on the displayed civil day. A prior night keeps
    /// rendering only through the dated disclosure.
    static func sleepIsCurrentDayPrimary(
        sleepEnd: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let sleepEnd else { return false }
        return calendar.isDate(sleepEnd, inSameDayAs: calendar.startOfDay(for: now))
    }

    /// Today's own limited partial recovery row, admitted only with its real
    /// structural honesty: no HRV, no sleep authority, a numeric percent, and
    /// non-verified confidence. Anything else is not a current-day partial.
    static func currentDayPartialRecovery(
        fromRollupSummary summary: FrozenRecoverySummary?,
        rollupDay: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> Metrics.RecoveryEstimate? {
        guard let summary,
              let rollupDay,
              calendar.isDate(rollupDay, inSameDayAs: calendar.startOfDay(for: now)) else {
            return nil
        }
        let estimate = summary.recoveryEstimate
        guard estimate.percent != nil,
              !estimate.usesHRV,
              estimate.confidence == .unverified || estimate.confidence == .learning
        else { return nil }
        return estimate
    }
}
