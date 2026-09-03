import Foundation

/// Typed catalog of every user-facing local-notification category Atria can
/// post. Each case maps 1:1 onto a scheduler `kind` string (the value
/// `LocalNotificationScheduler` passes to `AtriaNotificationSettings.allows`)
/// and onto one toggle in `AtriaNotificationSettings`, so the settings card,
/// the persistence model, and the scheduler can never disagree about which
/// categories exist.
///
/// Honesty contract (mirrors the in-app rules): every `honestDescription` and
/// every notification body built from the content builders below describes
/// only what the app truthfully detects. No medical/fever/illness claims, no
/// coaching promises, no fabricated precision — numeric values appear only
/// where the underlying value is actually measured.
enum AtriaNotificationCategory: String, CaseIterable, Identifiable, Sendable {
    // Long-shipped categories. Their defaults are preserved as shipped.
    case recoveryReady
    case strainTarget
    case sleepReview
    case workoutReview
    case morningSummary
    case weeklyReport
    case healthDeviation
    case strapBattery
    case bluetoothOff
    case fitCheck
    // Previously implicitly-enabled kinds (they fell through the settings
    // switch to `true`); now individually toggleable, defaults preserved.
    case sleepLogged
    case eveningCheckIn
    case syncNudge
    // New categories (2026-08-13). Default OFF — the user opts in.
    case secondSleepPrimary
    case bedtimeWindDown
    case catchUpComplete
    case parkedInterval

    var id: String { rawValue }

    /// The scheduler `kind` string checked via `AtriaNotificationSettings.allows`.
    var kind: String {
        switch self {
        case .recoveryReady: return "recovery"
        case .strainTarget: return "strain"
        case .sleepReview: return "sleep_review"
        case .workoutReview: return "workout_review"
        case .morningSummary: return "morning_summary"
        case .weeklyReport: return "weekly_report"
        case .healthDeviation: return "health_deviation"
        case .strapBattery: return "battery"
        case .bluetoothOff: return "bluetooth_off"
        case .fitCheck: return "fit_check"
        case .sleepLogged: return "sleep_logged"
        case .eveningCheckIn: return "evening_checkin"
        case .syncNudge: return "sync_nudge"
        case .secondSleepPrimary: return "second_sleep_primary"
        case .bedtimeWindDown: return "bedtime_reminder"
        case .catchUpComplete: return "catchup_complete"
        case .parkedInterval: return "parked_interval"
        }
    }

    var displayName: String {
        switch self {
        case .recoveryReady: return "Recovery check-ins"
        case .strainTarget: return "Strain milestones"
        case .sleepReview: return "Sleep review"
        case .workoutReview: return "Workout review"
        case .morningSummary: return "Morning summary"
        case .weeklyReport: return "Weekly report"
        case .healthDeviation: return "Health monitor"
        case .strapBattery: return "Strap battery"
        case .bluetoothOff: return "Bluetooth help"
        case .fitCheck: return "Fit check reminders"
        case .sleepLogged: return "Sleep confirmed"
        case .eveningCheckIn: return "Evening check-in"
        case .syncNudge: return "Strap out of range"
        case .secondSleepPrimary: return "Two sleeps in one day"
        case .bedtimeWindDown: return "Bedtime wind-down"
        case .catchUpComplete: return "Catch-up complete"
        case .parkedInterval: return "Unrecoverable interval"
        }
    }

    /// One line, honest: says only what the app truthfully detects.
    var honestDescription: String {
        switch self {
        case .recoveryReady:
            // Never "recovery score": the app publishes a recovery it can
            // stand behind, not a score it claims to have measured.
            return "When today's recovery is trusted enough to show."
        case .strainTarget:
            return "When today's measured strain reaches its target."
        case .sleepReview:
            return "When a detected sleep window needs your confirmation."
        case .workoutReview:
            return "When a detected heart-rate effort awaits your review."
        case .morningSummary:
            return "Measured hours and metrics after a confirmed night."
        case .weeklyReport:
            return "A short weekly summary of your measured trends."
        case .healthDeviation:
            return "When a vital runs outside your typical range for 2 days."
        case .strapBattery:
            return "When the strap battery runs low."
        case .bluetoothOff:
            return "When Bluetooth is off and strap capture stops."
        case .fitCheck:
            return "When the strap needs adjusting to read reliably."
        case .sleepLogged:
            return "When an overnight sleep is confirmed and saved."
        case .eveningCheckIn:
            return "A journal nudge near your usual bedtime, if you journal."
        case .syncNudge:
            return "When strap data is waiting and opening Atria would help."
        case .secondSleepPrimary:
            return "Asks which sleep is your main one when two share a day."
        case .bedtimeWindDown:
            return "A quiet nudge before your learned usual bedtime."
        case .catchUpComplete:
            return "When a long strap-history catch-up finishes."
        case .parkedInterval:
            return "If an older history interval could not be recovered."
        }
    }

    /// Shipped defaults are preserved for pre-existing categories; every new
    /// category starts OFF so the user explicitly opts in.
    var defaultEnabled: Bool {
        switch self {
        case .secondSleepPrimary, .bedtimeWindDown, .catchUpComplete, .parkedInterval:
            return false
        default:
            return true
        }
    }

    /// Categories delivered without a sound. The bedtime wind-down is quiet by
    /// design; the two sync-truth categories are informational, not urgent.
    var deliversQuietly: Bool {
        switch self {
        case .bedtimeWindDown, .catchUpComplete, .parkedInterval:
            return true
        default:
            return false
        }
    }

    /// The settings toggle backing this category.
    var settingKeyPath: WritableKeyPath<AtriaNotificationSettings, Bool> {
        switch self {
        case .recoveryReady: return \.recoveryReady
        case .strainTarget: return \.strainTarget
        case .sleepReview: return \.sleepReview
        case .workoutReview: return \.workoutReview
        case .morningSummary: return \.morningSummary
        case .weeklyReport: return \.weeklyReport
        case .healthDeviation: return \.healthDeviation
        case .strapBattery: return \.strapBattery
        case .bluetoothOff: return \.bluetoothOff
        case .fitCheck: return \.fitCheck
        case .sleepLogged: return \.sleepLogged
        case .eveningCheckIn: return \.eveningCheckIn
        case .syncNudge: return \.syncNudge
        case .secondSleepPrimary: return \.secondSleepPrimary
        case .bedtimeWindDown: return \.bedtimeWindDown
        case .catchUpComplete: return \.catchUpComplete
        case .parkedInterval: return \.parkedInterval
        }
    }

    static func category(forKind kind: String) -> AtriaNotificationCategory? {
        allCases.first { $0.kind == kind }
    }
}

/// Exact ownership map for pending local-notification requests. Turning one
/// category off removes only requests owned by that category; turning the
/// master switch off removes every Atria-owned pending request except the
/// explicit developer-only diagnostic. Category switches never use a broad
/// prefix, while the master switch intentionally covers future Atria request
/// identifiers without touching requests owned by another app/system path.
enum AtriaPendingNotificationCancellationPolicy {
    enum IdentifierRule: Equatable, Sendable {
        case exact(String)
        case prefix(String)

        func matches(_ identifier: String) -> Bool {
            switch self {
            case .exact(let expected):
                return identifier == expected
            case .prefix(let expected):
                return identifier.hasPrefix(expected)
            }
        }
    }

    static func rules(for category: AtriaNotificationCategory) -> [IdentifierRule] {
        switch category {
        case .recoveryReady:
            return [.exact("atria.recovery.ready")]
        case .strainTarget:
            return [.exact("atria.strain.target")]
        case .sleepReview:
            return [.exact("atria.sleep.review")]
        case .workoutReview:
            return [.exact("atria.workout.review")]
        case .morningSummary:
            return [
                .prefix("atria.morningSummary."),
                .prefix("atria.morningJournal."),
            ]
        case .weeklyReport:
            return [.prefix("atria.weeklyReport.")]
        case .healthDeviation:
            return [.exact("atria.health.deviation")]
        case .strapBattery:
            return [
                .exact("atria.battery.low"),
                .exact("atria.strap.chargeReminder"),
            ]
        case .bluetoothOff:
            return [.exact("atria.bluetooth.off")]
        case .fitCheck:
            return [.exact("atria.fitcheck.needed")]
        case .sleepLogged:
            return [.exact("atria.sleep.logged")]
        case .eveningCheckIn:
            return [.prefix("atria.eveningJournal.")]
        case .syncNudge:
            return [.exact("atria.sync.nudge")]
        case .secondSleepPrimary:
            return [.exact("atria.sleep.secondPrimary")]
        case .bedtimeWindDown:
            return [.prefix("atria.bedtime.windDown.")]
        case .catchUpComplete:
            return [.exact("atria.sync.catchUpComplete")]
        case .parkedInterval:
            return [.exact("atria.sync.parkedInterval")]
        }
    }

    static func identifiersToCancel(
        from pendingIdentifiers: [String],
        category: AtriaNotificationCategory
    ) -> [String] {
        identifiersToCancel(from: pendingIdentifiers, rules: rules(for: category))
    }

    static func allUserFacingIdentifiersToCancel(
        from pendingIdentifiers: [String]
    ) -> [String] {
        pendingIdentifiers.filter {
            $0.hasPrefix("atria.") && $0 != "atria.diagnostic.delivery"
        }
    }

    private static func identifiersToCancel(
        from pendingIdentifiers: [String],
        rules: [IdentifierRule]
    ) -> [String] {
        pendingIdentifiers.filter { identifier in
            rules.contains { $0.matches(identifier) }
        }
    }
}

/// Durable "never notify twice for the same event identity" ledger. Each
/// notification derived from a discrete physical event records a stable event
/// key here after a successful schedule; a replayed pass (relaunch, BGTask,
/// scene foreground) then stays silent for the same event. Bounded FIFO so a
/// long-lived install never grows an unbounded blob.
enum AtriaNotificationEventKeyStore {
    static let defaultsKey = "atria.notification.eventKeys.v1"
    static let capacity = 128

    static func hasNotified(_ eventKey: String,
                            defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: defaultsKey) ?? []).contains(eventKey)
    }

    static func recordNotified(_ eventKey: String,
                               defaults: UserDefaults = .standard) {
        var keys = defaults.stringArray(forKey: defaultsKey) ?? []
        guard !keys.contains(eventKey) else { return }
        keys.append(eventKey)
        if keys.count > capacity {
            keys.removeFirst(keys.count - capacity)
        }
        defaults.set(keys, forKey: defaultsKey)
    }
}

/// Pure timing policy for the opt-in bedtime wind-down reminder. Derived ONLY
/// from the user's own learned sleep schedule (the duty-cycle sleep window,
/// which is learned from confirmed sleeps): there is no generic fallback hour,
/// so the reminder never fires before the schedule is actually learned.
enum AtriaBedtimeWindDownPolicy {
    /// Minutes-past-midnight for the reminder, or nil while the sleep window
    /// is unlearned. The duty-cycle window start is the learned median bedtime
    /// minus 1 h, so reminding AT the window start lands about an hour before
    /// the user's usual bedtime (and deliberately does not collide with the
    /// evening journal check-in at windowStart + 15).
    static func reminderMinutes(sleepWindowStartMinutes: Int) -> Int? {
        guard sleepWindowStartMinutes > 0, sleepWindowStartMinutes < 1440 else { return nil }
        return sleepWindowStartMinutes
    }

    /// Next delivery date for the reminder: today at `reminderMinutes`, or
    /// tomorrow when that moment is already (nearly) past.
    static func nextTarget(now: Date,
                           reminderMinutes: Int,
                           calendar: Calendar = .current) -> Date {
        var target = calendar.date(bySettingHour: reminderMinutes / 60,
                                   minute: reminderMinutes % 60,
                                   second: 0,
                                   of: now) ?? now
        if target.timeIntervalSince(now) < 60 {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target
        }
        return target
    }

    /// Recent sleep debt (hours) at or above this includes the debt clause.
    static let debtMentionThresholdHours = 1.0

    /// Copy is deliberately non-numeric: the schedule is learned and the debt
    /// is computed, but neither is precise enough to quote to the minute/hour.
    static func content(sleepDebtHours: Double?) -> (title: String, body: String) {
        let base = "About an hour before your usual bedtime."
        guard let sleepDebtHours, sleepDebtHours >= debtMentionThresholdHours else {
            return ("Wind-down",
                    base + " A consistent bedtime keeps your sleep data steady.")
        }
        return ("Wind-down",
                base + " Recent nights came in under your sleep need — tonight is a chance to catch up.")
    }
}

/// Pure decision for the opt-in "long catch-up finished" notification. The
/// scheduler only OBSERVES the durable drain frontier
/// (`atria.offlineSync.drainedThroughUnix.v1`) across its normal passes: when
/// a pass sees the frontier far behind, it records a marker; when a later pass
/// sees the frontier current again, the span between marker and frontier
/// decides whether the catch-up was long enough to be worth a notification.
/// It never drives, retries, or reorders the drain itself.
enum AtriaCatchUpCompletionPolicy {
    /// The frontier must have been at least this far behind for a completion
    /// to count as a "long" catch-up worth announcing.
    static let minimumSpanSeconds: TimeInterval = 4 * 3600
    /// A pass this far behind records the marker.
    static let behindThresholdSeconds: TimeInterval = 4 * 3600
    /// The frontier counts as "current" within this window (a caught-up strap
    /// tracks the ~1 Hz live capture, so current means seconds behind; this is
    /// generous because passes run at scene/BGTask moments, not continuously).
    static let frontierCurrencyWindowSeconds: TimeInterval = 120

    enum Action: Equatable {
        case none
        case recordMarker(frontierUnix: Double)
        case clearMarker
        case notify(caughtUpSpanSeconds: TimeInterval, eventKey: String)
    }

    static func passAction(markerFrontierUnix: Double?,
                           frontierUnix: Double?,
                           nowUnix: Double) -> Action {
        guard let frontierUnix,
              frontierUnix.isFinite,
              frontierUnix > 0,
              frontierUnix <= nowUnix else { return .none }
        let behind = nowUnix - frontierUnix
        if behind > behindThresholdSeconds {
            // Keep the EARLIEST marker for this backlog so the measured span
            // covers the whole catch-up, not just its tail.
            if let markerFrontierUnix, markerFrontierUnix <= frontierUnix {
                return .none
            }
            return .recordMarker(frontierUnix: frontierUnix)
        }
        guard behind <= frontierCurrencyWindowSeconds else { return .none }
        guard let markerFrontierUnix else { return .none }
        let span = frontierUnix - markerFrontierUnix
        guard span >= minimumSpanSeconds else { return .clearMarker }
        return .notify(caughtUpSpanSeconds: span,
                       eventKey: "catchup.\(Int(markerFrontierUnix))")
    }
}

/// Copy for the event notifications introduced 2026-08-13. Pure and centrally
/// defined so the honesty tests can scan every string the user can receive.
enum AtriaEventNotificationContent {
    static func secondSleepPrompt(dayText: String) -> (title: String, body: String) {
        ("Two sleeps in one day",
         "You slept more than once on \(dayText). Tell Atria which one is your main sleep — it drives Recovery; the other still counts.")
    }

    /// No numbers: the caught-up span is a time window, not a proven quantity
    /// of data, so the body claims only what is certain — the frontier is
    /// current again.
    static func catchUpComplete() -> (title: String, body: String) {
        ("Catch-up complete",
         "Strap history finished syncing and is current through now.")
    }

    /// Mirrors the in-app banner truth exactly: terminal for the automatic
    /// lane, reopenable on new evidence, never softened into "syncing".
    static func parkedInterval() -> (title: String, body: String) {
        ("Older interval unavailable",
         "One older stretch of strap history could not be recovered after repeated attempts. The gap stays visible in Atria; new strap data can reopen recovery.")
    }

    static func parkedIntervalEventKey(parkedAtUnix: Double) -> String {
        "parkedInterval.\(Int(parkedAtUnix))"
    }
}
