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
    /// The civil date turned over but the wearer has not slept yet, so the live
    /// cycle's values are still the ones they are living in. Primary, but the
    /// surface MUST date them to the cycle rather than call them "today".
    case currentCycleAcrossMidnight
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

    /// How long past the anchoring wake the live cycle may still be the primary
    /// value once the civil date has turned over. A normal waking day is 16-18 h;
    /// 18 h covers "it is 00:30 and I have not gone to bed yet" for any wake
    /// before 06:30, while the Aug-12/13 incident (23 h 16 min awake) falls
    /// safely outside it.
    static let maximumWakingDayHeldAcrossMidnight: TimeInterval = 18 * 60 * 60

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

        // Midnight is a calendar event, not a physiological one. Before this,
        // the civil rollover alone demoted the live cycle: at 00:01 the rings
        // the wearer had been looking at all evening went blank mid-evening,
        // with no new sleep and no new evidence — the whole complaint in field
        // report item 4.
        //
        // The obvious fix ("keep it primary while `now < cycleEnd`") is WRONG
        // and would reintroduce the Aug-12/13 incident this file exists to
        // prevent: that fixture is 14:43 on the following day, still inside
        // wake + 24 h + 30 min, and showing the previous cycle's 92 / 9h12 / 3.3
        // there is exactly the lie the module was built to stop.
        //
        // What separates the two is elapsed WAKING time, not the rollover.
        // 00:30 after an 08:00 wake is 16.5 h — still the same evening, and the
        // night simply has not happened yet. 14:43 after a 15:27 wake is 23 h —
        // the night has been and gone. Hold the live cycle across midnight only
        // for a plausible waking day; past that, fall through to today's own
        // partial evidence or a terminal awaiting state exactly as before.
        let wakingAge = now.timeIntervalSince(cycleStart)
        let holdsAcrossMidnight = anchorSleepID != nil
            && wakingAge >= 0
            && wakingAge < maximumWakingDayHeldAcrossMidnight
            && (cycleEnd.map { now < $0 } ?? false)

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

        if holdsAcrossMidnight {
            // Primary values, but NOT wearing today's label: `sourceCivilDay`
            // stays the cycle's own day and `priorCycle` remains populated so
            // the surface can date what it is showing.
            return Resolution(
                identity: .init(
                    displayCivilDay: displayCivilDay,
                    cycleStart: cycleStart,
                    cycleEnd: cycleEnd,
                    sourceSleepID: anchorSleepID,
                    sourceCivilDay: cycleValueSourceDay,
                    valueState: .currentCycleAcrossMidnight,
                    calculatedAt: now
                ),
                recoveryOverride: nil,
                strainOverride: nil,
                sleepIsAwaitingCurrentSleep: false,
                priorCycle: priorCycle
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
        cycleStart: Date? = nil,
        cycleEnd: Date? = nil,
        calendar: Calendar = .current
    ) -> Bool {
        guard let sleepEnd else { return false }
        if calendar.isDate(sleepEnd, inSameDayAs: calendar.startOfDay(for: now)) {
            return true
        }
        // Same cross-midnight hold as `resolve`, so the sleep ring cannot blank
        // on its own while recovery and strain are still showing the cycle.
        guard let cycleStart, let cycleEnd, now < cycleEnd else { return false }
        let wakingAge = now.timeIntervalSince(cycleStart)
        guard wakingAge >= 0, wakingAge < maximumWakingDayHeldAcrossMidnight else {
            return false
        }
        return sleepEnd <= now && sleepEnd >= cycleStart.addingTimeInterval(-24 * 60 * 60)
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
