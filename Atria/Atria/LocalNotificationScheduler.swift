import Foundation
import UserNotifications

@MainActor
enum LocalNotificationScheduler {
    struct LaunchDecisionScope: Equatable {
        let productionCadence: Bool
        let includeSleepReviewDecisions: Bool
        let includeWorkoutReviewDecisions: Bool
    }

    nonisolated static func launchDecisionScope(arguments: [String]) -> LaunchDecisionScope {
        let debugMetricRequest = arguments.contains("--atria-schedule-notifications")
        let debugDiagnosticRequest = arguments.contains("--atria-test-notification")
        let debugHealthDeviationRequest = arguments.contains("--atria-test-health-deviation-notification")
        let productionCadence = !debugMetricRequest && !debugDiagnosticRequest && !debugHealthDeviationRequest
        return LaunchDecisionScope(productionCadence: productionCadence,
                                   includeSleepReviewDecisions: productionCadence || debugMetricRequest,
                                   includeWorkoutReviewDecisions: productionCadence || debugMetricRequest)
    }

    nonisolated static func workoutReviewDeliveryCanReserve(
        candidateID: String,
        lastNotifiedCandidateID: String?,
        inFlightCandidateIDs: Set<String>
    ) -> Bool {
        !candidateID.isEmpty
            && candidateID != lastNotifiedCandidateID
            && !inFlightCandidateIDs.contains(candidateID)
    }

    private nonisolated static let actionableBatteryThreshold = 25
    private static let actionableDiagnosisCooldown: TimeInterval = 6 * 60 * 60
    private static let actionableDiagnosisLastScheduledPrefix = "atria.notification.actionableDiagnosis.lastScheduled."
    private static let batteryWarningDrainCycleScheduledKey = "atria.notification.battery.warningDrainCycleScheduled"
    private static let batteryShutoffDrainCycleScheduledKey = "atria.notification.battery.shutoffDrainCycleScheduled"
    private static let batteryDrainCycleClearedAtKey = "atria.notification.battery.drainCycleClearedAt"
    private static let sleepReviewLastCandidateIDKey = "atria.notification.sleepReview.lastCandidateID"
    private static let sleepReviewCandidateScheduledAtPrefix = "atria.notification.sleepReview.scheduledAt."
    private static let sleepReviewCandidateScheduleCountPrefix = "atria.notification.sleepReview.scheduleCount."
    private static let sleepReviewReminderCooldown: TimeInterval = 4 * 60 * 60
    private static let sleepReviewMaximumSchedulesPerCandidate = 2
    private static let sleepReviewDismissedIDKey = "atria.sleepReview.dismissedID"
    /// Window-start debounce (2026-08-01): [startKey: lastNotifiedEnd-unix].
    /// A growing sleep candidate keeps its start while the end jitters by a
    /// few minutes; each jitter used to mint a new candidate id and re-fire
    /// (observed 04:50/04:56/04:57 triple). See
    /// `AtriaSleepReviewNotificationDebounce`.
    static let sleepReviewNotifiedEndByStartKey =
        "atria.notification.sleepReview.notifiedEndByStart.v1"
    private static let workoutReviewLastCandidateIDKey = "atria.notification.workoutReview.lastCandidateID"
    private static let workoutReviewDismissedIDKey = "atria.workoutReview.dismissedID"
    /// One process-wide reservation covers both launch maintenance and the
    /// review-cache publication retry. Without it, two authorization tasks can
    /// spend the attention budget for the same candidate before either write
    /// records `workoutReviewLastCandidateIDKey`.
    private static var workoutReviewCandidateIDsInFlight = Set<String>()
    private static let healthDeviationLastScheduledKey = "atria.notification.healthDeviation.lastScheduledAt"
    private static let healthDeviationCooldown: TimeInterval = 48 * 60 * 60
    private static let strapChargeReminderLastScheduledKey = "atria.notification.strapCharge.lastScheduled"
    private static let strapChargeReminderCooldown: TimeInterval = 20 * 60 * 60
    private static let strapChargeReminderLowBatteryThreshold = 30
    private static let strapChargeReminderMinLearnedHours = 5
    private static let strapChargeReminderHourTolerance = 1
    private static let sleepEventDedupDayKey = "atria.notification.sleepEvent.lastDay"
    private static let sleepEventDedupMinutesKey = "atria.notification.sleepEvent.lastDurationMinutes"
    private static let sleepEventDedupKindKey = "atria.notification.sleepEvent.lastKind"
    private static let sleepEventDedupToleranceMinutes = 3

    private enum Identifier {
        static let morningSummaryPrefix = "atria.morningSummary."
        static let weeklyReportPrefix = "atria.weeklyReport."
        static let eveningJournalPrefix = "atria.eveningJournal."
        static let morningJournalPrefix = "atria.morningJournal."
        static let healthDeviation = "atria.health.deviation"
        static let syncNudge = "atria.sync.nudge"
        static let recovery = "atria.recovery.ready"
        static let strain = "atria.strain.target"
        static let sleepReview = "atria.sleep.review"
        static let sleepLogged = "atria.sleep.logged"
        static let workoutReview = "atria.workout.review"
        static let battery = "atria.battery.low"
        static let bluetoothOff = "atria.bluetooth.off"
        static let fitCheck = "atria.fitcheck.needed"
        static let strapChargeReminder = "atria.strap.chargeReminder"
        static let diagnostic = "atria.diagnostic.delivery"
        static let logJournalAction = "atria.action.logJournal"
        static let legacyRecovery = "atria.recovery.ready"
        static let legacyStrain = "atria.strain.target"
        static let legacySleepReview = "atria.sleep.review"
        static let legacyWorkoutReview = "atria.workout.review"
        static let legacyBattery = "atria.battery.low"
        static let legacyBluetoothOff = "atria.bluetooth.off"
        static let legacyDiagnostic = "atria.diagnostic.delivery"

        static let active = [recovery, strain, sleepReview, sleepLogged, workoutReview, battery, bluetoothOff, fitCheck, healthDeviation]
        static let diagnosticOnly = [diagnostic]
        static let legacy = [legacyRecovery, legacyStrain, legacySleepReview, legacyWorkoutReview, legacyBattery, legacyBluetoothOff, legacyDiagnostic]
        static let removable = active + diagnosticOnly + legacy
    }

    // MARK: - Sync nudge (2026-08-05 user directive: graceful measures when
    // data is lagging — app closed a while, strap away, Low Power Mode, or
    // background catch-up simply not progressing).

    struct SyncNudgeContent: Equatable {
        let title: String
        let body: String
    }

    /// Pure decision. Nudge ONLY when opening the app would actually help:
    /// - foregroundHelps: a fresh strap backlog is observed (strap reachable)
    ///   but no durable flush progress for ≥2h — foreground drains fastest.
    /// - strapAway: a deep backlog was last observed hours ago and the link
    ///   has been down since — bringing the strap close is the fix.
    /// - lowPower: Low Power Mode is throttling background sync.
    /// Never fires while the app is active (the in-app banner owns that).
    /// No time-of-day gate (2026-08-05 user decision: "sync should happen
    /// whenever possible" — a significant miss is worth knowing at any hour;
    /// iOS delivers it quietly under the user's own Focus/notification
    /// settings). Threshold: ≥30 minutes of missed strap data
    /// (pendingRecords at the ~1Hz banking cadence).
    nonisolated static let syncNudgeMinimumPendingRecords = 30 * 60

    nonisolated static func syncNudgeContent(
        flushDebtPendingRecords: Int?,
        debtObservedAgeSeconds: TimeInterval?,
        lastDurableFlushAgeSeconds: TimeInterval?,
        linkConnected: Bool,
        lowPowerMode: Bool,
        applicationIsActive: Bool
    ) -> SyncNudgeContent? {
        guard !applicationIsActive else { return nil }
        guard let pending = flushDebtPendingRecords,
              pending >= syncNudgeMinimumPendingRecords else { return nil }
        let progressing = lastDurableFlushAgeSeconds.map { $0 < 2 * 3600 } ?? false
        guard !progressing else { return nil }
        let debtFresh = debtObservedAgeSeconds.map { $0 <= 2 * 3600 } ?? false
        if !linkConnected, !debtFresh {
            return SyncNudgeContent(
                title: "Strap out of range",
                body: "Hours of strap data are waiting. Bring your strap near your phone and open Atria to catch up."
            )
        }
        if lowPowerMode {
            return SyncNudgeContent(
                title: "Sync limited by Low Power Mode",
                body: "Strap data is waiting. Open Atria for a few minutes — foreground sync runs at full speed."
            )
        }
        guard debtFresh else { return nil }
        return SyncNudgeContent(
            title: "Strap data waiting to sync",
            body: "Background catch-up hasn't kept pace. Open Atria for a few minutes — sync runs fastest in the foreground."
        )
    }

    static let syncNudgeCooldown: TimeInterval = 6 * 3600
    private static let syncNudgeLastScheduledKey = "atria.notification.syncNudge.lastAt"

    static func scheduleSyncNudgeIfNeeded(
        flushDebtPendingRecords: Int?,
        debtObservedAgeSeconds: TimeInterval?,
        lastDurableFlushAgeSeconds: TimeInterval?,
        linkConnected: Bool,
        applicationIsActive: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        guard AtriaNotificationSettings.load().allows(kind: "sync_nudge") else { return }
        guard let content = syncNudgeContent(
            flushDebtPendingRecords: flushDebtPendingRecords,
            debtObservedAgeSeconds: debtObservedAgeSeconds,
            lastDurableFlushAgeSeconds: lastDurableFlushAgeSeconds,
            linkConnected: linkConnected,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            applicationIsActive: applicationIsActive
        ) else { return }
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: syncNudgeLastScheduledKey)
        if last > 0,
           now.timeIntervalSince(Date(timeIntervalSince1970: last)) < syncNudgeCooldown {
            return
        }
        configureDeliveryLogger()
        Task {
            let center = UNUserNotificationCenter.current()
            _ = await requestProvisionalAuthorization(center: center)
            let settings = await notificationSettings(center: center)
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else { return }
            let notification = UNMutableNotificationContent()
            notification.title = content.title
            notification.body = content.body
            notification.sound = nil
            center.removePendingNotificationRequests(withIdentifiers: [Identifier.syncNudge])
            do {
                try await center.add(UNNotificationRequest(
                    identifier: Identifier.syncNudge,
                    content: notification,
                    trigger: nil
                ))
                defaults.set(now.timeIntervalSince1970, forKey: syncNudgeLastScheduledKey)
                AtriaDebugLog("ATRIADBG notification_schedule kind=sync_nudge title=%@", content.title)
            } catch {
                AtriaDebugLog("ATRIADBG notification_error kind=sync_nudge error=%@",
                              String(describing: error))
            }
        }
    }

    static func scheduleHealthDeviationIfNeeded(rollups: [DailyRollupStoreEntry],
                                                now: Date = Date(),
                                                calendar: Calendar = .current) {
        guard AtriaNotificationSettings.load().allows(kind: "health_deviation") else {
            AtriaDebugLog("ATRIADBG notification_skip kind=health_deviation reason=user_disabled")
            return
        }
        guard let decision = healthDeviationDecision(rollups: rollups, now: now, calendar: calendar) else {
            AtriaDebugLog("ATRIADBG notification_skip kind=health_deviation reason=no_two_day_deviation")
            return
        }

        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: healthDeviationLastScheduledKey)
        if last > 0, now.timeIntervalSince(Date(timeIntervalSince1970: last)) < healthDeviationCooldown {
            AtriaDebugLog("ATRIADBG notification_skip kind=health_deviation reason=cooldown")
            return
        }

        configureDeliveryLogger()
        Task {
            let center = UNUserNotificationCenter.current()
            _ = await requestProvisionalAuthorization(center: center)
            let settings = await notificationSettings(center: center)
            let status = statusName(settings.authorizationStatus)
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else {
                AtriaDebugLog("ATRIADBG notification_schedule status=blocked reason=authorization_%@ kind=health_deviation",
                              status)
                return
            }

            center.removePendingNotificationRequests(withIdentifiers: [Identifier.healthDeviation])
            do {
                try await add(decision: decision, center: center)
                defaults.set(now.timeIntervalSince1970, forKey: healthDeviationLastScheduledKey)
            } catch {
                AtriaDebugLog("ATRIADBG notification_error kind=health_deviation error=%@",
                              String(describing: error))
            }
        }
    }

    static func scheduleMorningSummary(recovery: Int,
                                       sleepText: String,
                                       hrvText: String,
                                       sleepDurationSeconds: TimeInterval? = nil,
                                       now: Date = Date(),
                                       calendar: Calendar = .current) {
        guard AtriaNotificationSettings.load().allows(kind: "morning_summary") else {
            AtriaDebugLog("ATRIADBG notification_schedule status=skipped_toggle kind=morning_summary")
            return
        }

        let day = localDayIdentifier(for: now, calendar: calendar)
        if let sleepDurationSeconds,
           shouldSkipRedundantSleepEvent(kind: "morning_summary",
                                        durationMinutes: Int(sleepDurationSeconds / 60),
                                        day: day) {
            AtriaDebugLog("ATRIADBG notification_skip kind=morning_summary reason=redundant_sleep_event day=%@", day)
            return
        }

        configureDeliveryLogger()
        Task {
            let center = UNUserNotificationCenter.current()
            _ = await requestProvisionalAuthorization(center: center)
            let settings = await notificationSettings(center: center)
            let status = statusName(settings.authorizationStatus)
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else {
                AtriaDebugLog("ATRIADBG notification_schedule status=blocked reason=authorization_%@ kind=morning_summary",
                              status)
                return
            }

            let identifier = Identifier.morningSummaryPrefix + day
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            // The rich summary carries the journal nudge itself, so cancel the
            // plain pre-scheduled morning check-in for this day — no double nudge.
            center.removePendingNotificationRequests(withIdentifiers: [Identifier.morningJournalPrefix + day])
            // Adaptive timing (docs/24 §14.2): deliver no earlier than YOUR
            // learned wake + 15 min; metrics landing later fire immediately.
            let windowEnd = UserDefaults.standard.integer(forKey: AtriaBLEManager.DutyCycleDefaults.sleepWindowEndMin)
            var morningDelay: TimeInterval = 1
            if windowEnd > 0 {
                let wakePlus15 = ((windowEnd + 1440 - 60) % 1440) + 15
                let nowComponents = calendar.dateComponents([.hour, .minute], from: now)
                let nowMinutes = (nowComponents.hour ?? 0) * 60 + (nowComponents.minute ?? 0)
                if nowMinutes < wakePlus15, wakePlus15 - nowMinutes < 6 * 60 {
                    morningDelay = TimeInterval((wakePlus15 - nowMinutes) * 60)
                }
            }
            // Journal nudge is folded into this one notification as the
            // "atria.action.logJournal" action on category "atria.morningSummary"
            // (registered in registerNotificationCategoriesIfNeeded) rather than
            // a second notification — the trailing clause below covers users who
            // never long-press for the action.
            let decision = NotificationDecision(kind: "morning_summary",
                                                identifier: identifier,
                                                title: "Morning summary",
                                                body: "Recovery \(recovery)% \u{00B7} Slept \(sleepText) \u{00B7} HRV \(hrvText) \u{2014} log how you feel",
                                                reason: "morning_summary_ready",
                                                shouldSchedule: true,
                                                delay: morningDelay,
                                                categoryIdentifier: "atria.morningSummary",
                                                userInfo: ["deepLink": "atria://overview"])
            do {
                try await add(decision: decision, center: center)
                if let sleepDurationSeconds {
                    recordSleepEvent(kind: "morning_summary",
                                     durationMinutes: Int(sleepDurationSeconds / 60),
                                     day: day)
                }
                await logMorningSummaryPendingProof(identifier: identifier, center: center)
            } catch {
                AtriaDebugLog("ATRIADBG notification_error kind=morning_summary error=%@",
                              String(describing: error))
            }
        }
    }

    /// Evening journal check-in (Journal P4 hook): one gentle nudge at ~21:30
    /// local, deep-linking to the Journal tab. Only scheduled for people who
    /// actually use the journal (activity within the last 7 days) — an unused
    /// feature never notifies.
    static func scheduleEveningJournalCheckIn(lastJournalActivity: Date?,
                                              now: Date = Date(),
                                              calendar: Calendar = .current) {
        guard AtriaNotificationSettings.load().allows(kind: "evening_checkin") else {
            AtriaDebugLog("ATRIADBG notification_schedule status=skipped_toggle kind=evening_checkin")
            return
        }
        // 14-day (not 7-day) re-engage window — see scheduleMorningJournalCheckIn:
        // the reminder must outlast a typical lapse to rebuild the journal habit.
        guard let lastJournalActivity,
              now.timeIntervalSince(lastJournalActivity) <= 14 * 24 * 60 * 60 else {
            AtriaDebugLog("ATRIADBG notification_skip kind=evening_checkin reason=journal_inactive")
            return
        }
        // Scene foregrounds fire this many times a day; schedule (and consume
        // budget) at most once per target day.
        let scheduledDayKey = "atria.notification.eveningJournal.scheduledDay"

        // Adaptive wind-down (docs/24 §14.2): the duty-cycle sleep window start
        // is the learned median bedtime minus 1 h; nudge 15 min after it (~45 min
        // before typical bedtime). Falls back to 21:30 until the window is
        // learned from >=3 confirmed sleeps.
        let windowStartMinutes = UserDefaults.standard.integer(forKey: AtriaBLEManager.DutyCycleDefaults.sleepWindowStartMin)
        let nudgeMinutes = windowStartMinutes > 0 ? (windowStartMinutes + 15) % 1440 : 21 * 60 + 30
        var target = calendar.date(bySettingHour: nudgeMinutes / 60,
                                   minute: nudgeMinutes % 60,
                                   second: 0,
                                   of: now) ?? now
        if target.timeIntervalSince(now) < 60 {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target
        }
        let delay = target.timeIntervalSince(now)
        let targetDay = localDayIdentifier(for: target, calendar: calendar)
        guard UserDefaults.standard.string(forKey: scheduledDayKey) != targetDay else { return }

        configureDeliveryLogger()
        Task {
            let center = UNUserNotificationCenter.current()
            _ = await requestProvisionalAuthorization(center: center)
            let settings = await notificationSettings(center: center)
            let status = statusName(settings.authorizationStatus)
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else {
                AtriaDebugLog("ATRIADBG notification_schedule status=blocked reason=authorization_%@ kind=evening_checkin",
                              status)
                return
            }

            let identifier = Identifier.eveningJournalPrefix + targetDay
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            let decision = NotificationDecision(kind: "evening_checkin",
                                                identifier: identifier,
                                                title: "Evening check-in",
                                                body: "30 seconds now sharpens tomorrow's recovery insights.",
                                                reason: "evening_journal_checkin",
                                                shouldSchedule: true,
                                                delay: delay,
                                                categoryIdentifier: "atria.eveningJournal",
                                                userInfo: ["deepLink": "atria://journal"])
            do {
                try await add(decision: decision, center: center)
                UserDefaults.standard.set(targetDay, forKey: scheduledDayKey)
            } catch {
                AtriaDebugLog("ATRIADBG notification_error kind=evening_checkin error=%@",
                              String(describing: error))
            }
        }
    }

    /// Minutes-past-midnight for the morning journal nudge: learned wake + 15
    /// (the duty-cycle window end is median wake + 1 h, so `windowEnd - 60` is
    /// wake), or 08:00 until the window is learned. Pure + wraps across midnight,
    /// so it's unit-testable.
    /// Attempt-store key for the morning journal nudge. Named once so the
    /// scheduler and the in-app fallback cannot disagree about which record
    /// they are reading.
    static let morningCheckInKind = "morning_checkin"

    /// Attempt-store key for the RICH morning summary -- the one that asserts
    /// recovery, HRV and sleep numbers.
    ///
    /// The two morning notifications are split by what they CLAIM, and the split
    /// is deliberate. The rich summary requires a persisted, sleep-derived daily
    /// metric before it will fire, because it states measurements. The plain
    /// check-in claims nothing and carries no metrics, so it stays unconditional
    /// -- gating it too would reproduce the silent morning reported 2026-07-08,
    /// on exactly the mornings where confirmation is late or never arrives.
    ///
    /// Kept as separate attempt records so "no rich summary" and "no nudge at
    /// all" are answerable independently rather than collapsing into one silence.
    static let morningSummaryKind = "morning_summary"

    nonisolated static func morningNudgeMinutes(windowEnd: Int) -> Int {
        windowEnd > 0 ? ((((windowEnd + 1440 - 60) % 1440) + 15) % 1440) : 8 * 60
    }

    /// Morning journal check-in — the peer of scheduleEveningJournalCheckIn.
    /// The rich morning summary (scheduleMorningSummary) only fires when a full
    /// recovery+HRV+sleep metric is ready, and it folds the journal nudge into
    /// itself. On a strict-gate morning where last night's sleep isn't confirmed,
    /// that summary is skipped and the user got NO wake nudge at all (user
    /// 2026-07-08). This pre-schedules a plain, honest journal nudge for the
    /// learned wake time so the ask survives whether or not the night was
    /// confirmed — it carries NO fabricated metrics. scheduleMorningSummary
    /// cancels this one for the day when the rich summary does fire, so they
    /// never both land.
    static func scheduleMorningJournalCheckIn(lastJournalActivity: Date?,
                                              now: Date = Date(),
                                              calendar: Calendar = .current) {
        // Every exit below now leaves a durable record as well as a log line.
        // Logs are not readable by the UI, so a morning with no notification
        // could not say why -- toggle off, journal inactive, authorization
        // denied and outright failure all looked identical to silence.
        guard AtriaNotificationSettings.load().allows(kind: "morning_summary") else {
            AtriaDebugLog("ATRIADBG notification_schedule status=skipped_toggle kind=morning_checkin")
            AtriaNotificationAttemptStore.record(kind: Self.morningCheckInKind,
                                                 outcome: .blockedByToggle,
                                                 reason: "toggle_off")
            return
        }
        // 14-day (not 7-day) re-engage window: a journal reminder must survive a
        // typical lapse to help rebuild the habit — a 7-day gate drops it exactly
        // when the user has stopped and most needs the nudge (user 2026-07-08 #1/#7).
        guard let lastJournalActivity,
              now.timeIntervalSince(lastJournalActivity) <= 14 * 24 * 60 * 60 else {
            AtriaDebugLog("ATRIADBG notification_skip kind=morning_checkin reason=journal_inactive")
            AtriaNotificationAttemptStore.record(kind: Self.morningCheckInKind,
                                                 outcome: .skippedInactive,
                                                 reason: "journal_inactive",
                                                 at: now)
            return
        }
        // Scene foregrounds fire this many times a day; schedule at most once per
        // target day.
        let scheduledDayKey = "atria.notification.morningJournal.scheduledDay"

        // Deliver at YOUR learned wake + 15 min — the same anchor the rich summary
        // uses (the duty-cycle window end is median wake + 1 h). Falls back to
        // 08:00 until the window is learned from confirmed sleeps.
        let windowEnd = UserDefaults.standard.integer(forKey: AtriaBLEManager.DutyCycleDefaults.sleepWindowEndMin)
        let nudgeMinutes = morningNudgeMinutes(windowEnd: windowEnd)
        var target = calendar.date(bySettingHour: nudgeMinutes / 60,
                                   minute: nudgeMinutes % 60,
                                   second: 0,
                                   of: now) ?? now
        if target.timeIntervalSince(now) < 60 {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target
        }
        let delay = target.timeIntervalSince(now)
        let targetDay = localDayIdentifier(for: target, calendar: calendar)
        guard UserDefaults.standard.string(forKey: scheduledDayKey) != targetDay else { return }

        configureDeliveryLogger()
        Task {
            let center = UNUserNotificationCenter.current()
            _ = await requestProvisionalAuthorization(center: center)
            let settings = await notificationSettings(center: center)
            let status = statusName(settings.authorizationStatus)
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else {
                AtriaDebugLog("ATRIADBG notification_schedule status=blocked reason=authorization_%@ kind=morning_checkin",
                              status)
                // The one outcome that obliges an in-app equivalent: the system
                // route cannot deliver, and the user did not choose that.
                AtriaNotificationAttemptStore.record(kind: Self.morningCheckInKind,
                                                     outcome: .blockedByAuthorization,
                                                     reason: "authorization_\(status)")
                return
            }

            let identifier = Identifier.morningJournalPrefix + targetDay
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            let decision = NotificationDecision(kind: "morning_summary",
                                                identifier: identifier,
                                                title: "Morning check-in",
                                                body: "A minute now sharpens today's recovery insights.",
                                                reason: "morning_journal_checkin",
                                                shouldSchedule: true,
                                                delay: delay,
                                                categoryIdentifier: "atria.morningSummary",
                                                userInfo: ["deepLink": "atria://journal"])
            do {
                try await add(decision: decision, center: center)
                UserDefaults.standard.set(targetDay, forKey: scheduledDayKey)
                AtriaDebugLog("ATRIADBG notification_schedule status=scheduled kind=morning_checkin target_day=%@ delay_s=%.0f",
                              targetDay, delay)
                AtriaNotificationAttemptStore.record(kind: Self.morningCheckInKind,
                                                     outcome: .scheduled,
                                                     reason: "target_day_\(targetDay)")
            } catch {
                AtriaDebugLog("ATRIADBG notification_error kind=morning_checkin error=%@",
                              String(describing: error))
                AtriaNotificationAttemptStore.record(kind: Self.morningCheckInKind,
                                                     outcome: .failed,
                                                     reason: String(describing: error))
            }
        }
    }

    static func scheduleWeeklyReport(_ report: WeeklyReport) {
        guard AtriaNotificationSettings.load().allows(kind: "weekly_report") else {
            AtriaDebugLog("ATRIADBG notification_schedule status=skipped_toggle kind=weekly_report")
            return
        }

        guard let recovery = report.recoveryAvg else {
            AtriaDebugLog("ATRIADBG notification_skip kind=weekly_report reason=no_recovery_average")
            return
        }

        configureDeliveryLogger()
        Task {
            let center = UNUserNotificationCenter.current()
            _ = await requestProvisionalAuthorization(center: center)
            let settings = await notificationSettings(center: center)
            let status = statusName(settings.authorizationStatus)
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else {
                AtriaDebugLog("ATRIADBG notification_schedule status=blocked reason=authorization_%@ kind=weekly_report",
                              status)
                return
            }

            let identifier = Identifier.weeklyReportPrefix + "\(report.isoYear)-W\(report.isoWeek)"
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            let recoveryDelta = report.recoveryDeltaVsPriorWeek.map { delta in
                delta >= 0 ? "+\(delta)%" : "\(delta)%"
            } ?? "\(recovery)%"
            let consistency = report.sleepConsistencyPct.map { "Sleep consistency \($0)%" } ?? "Sleep consistency building"
            let decision = NotificationDecision(kind: "weekly_report",
                                                identifier: identifier,
                                                title: "Your week on Atria",
                                                body: "Recovery \(recoveryDelta) · \(consistency)",
                                                reason: "weekly_report_\(report.isoYear)_W\(report.isoWeek)",
                                                shouldSchedule: true,
                                                delay: 1,
                                                categoryIdentifier: "atria.weeklyReport",
                                                userInfo: ["deepLink": "atria://overview"])
            do {
                try await add(decision: decision, center: center)
            } catch {
                AtriaDebugLog("ATRIADBG notification_error kind=weekly_report error=%@",
                              String(describing: error))
            }
        }
    }

    static func scheduleFromLaunchIfRequested(store: SessionStore,
                                              ble: AtriaBLEManager,
                                              arguments: [String] = ProcessInfo.processInfo.arguments) {
        configureDeliveryLogger()
        let debugMetricRequest = arguments.contains("--atria-schedule-notifications")
        let debugDiagnosticRequest = arguments.contains("--atria-test-notification")
        let debugHealthDeviationRequest = arguments.contains("--atria-test-health-deviation-notification")
        let scope = launchDecisionScope(arguments: arguments)
        let productionCadence = scope.productionCadence
        let includeSleepReviewDecisions = scope.includeSleepReviewDecisions
        let includeWorkoutReviewDecisions = scope.includeWorkoutReviewDecisions
        let delay = launchDelay(arguments: arguments)
        AtriaDebugLog("ATRIADBG notification_schedule requested=1 mode=%@ delay_s=%.1f",
              productionCadence ? "production" : "debug",
              delay)

        Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            if debugHealthDeviationRequest {
                scheduleHealthDeviationDebugFixture()
            }
            await schedule(store: store,
                           ble: ble,
                           includeMetricDecisions: debugMetricRequest,
                           includeSleepReviewDecisions: includeSleepReviewDecisions,
                           includeWorkoutReviewDecisions: includeWorkoutReviewDecisions,
                           includeActionableConnectionDecisions: productionCadence || debugMetricRequest,
                           includeDiagnostic: debugDiagnosticRequest,
                           productionCadence: productionCadence)
        }
    }

    /// Background review-notification pass (2026-08-08, audit §1 #4). The
    /// overnight BGAppRefresh/Processing handler must run the SAME production
    /// notification decisions the foreground launch path runs — critically the
    /// sleep-review banner. A suspended app gets no scene-active pass, so
    /// `makeSleepReviewDecision` never ran until the user next opened the app,
    /// and the "review last night's sleep" nudge "only appears after opening."
    ///
    /// The flags mirror the production launch cadence EXACTLY (the same
    /// `Identifier.removable` rebuild inside `schedule`), so nothing scheduled
    /// at launch is orphaned — a trimmed sleep-review-only pass would wipe the
    /// pending workout-review / connection notifications that `schedule` clears
    /// but would then not re-add. The sleep-review debounce keys
    /// (`sleepReviewNotifiedEndByStart`, per-candidate schedule cap, cooldown)
    /// keep a repeated background pass from re-firing an already-notified
    /// candidate. No launch delay — the background execution window is short.
    ///
    /// Runtime efficacy depends on the overnight sleep candidate actually being
    /// materialized before this runs (audit §5); when no candidate exists this
    /// pass is a harmless no-op that reschedules the same pending set.
    static func scheduleBackgroundReviewPass(store: SessionStore, ble: AtriaBLEManager) async {
        await schedule(store: store,
                       ble: ble,
                       includeMetricDecisions: false,
                       includeSleepReviewDecisions: true,
                       includeWorkoutReviewDecisions: true,
                       includeActionableConnectionDecisions: true,
                       includeDiagnostic: false,
                       productionCadence: true)
    }

    static func scheduleFastLaunchHealthDeviationDebugFixtureIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--atria-test-health-deviation-notification") else { return }
        configureDeliveryLogger()
        scheduleHealthDeviationDebugFixture()
    }

    static func scheduleFastLaunchWeeklyReportDebugFixtureIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--atria-test-weekly-report-notification") else { return }
        configureDeliveryLogger()
        scheduleWeeklyReportDebugFixture()
    }

    static func scheduleFastLaunchMorningSummaryDebugFixtureIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--atria-test-morning-summary-notification")
                || arguments.contains("--atria-test-morning-summary-toggle-off") else { return }
        configureDeliveryLogger()
        scheduleMorningSummaryDebugFixture(toggleOff: arguments.contains("--atria-test-morning-summary-toggle-off"))
    }

#if DEBUG
    private static func scheduleMorningSummaryDebugFixture(now: Date = Date(),
                                                          calendar: Calendar = .current,
                                                          toggleOff: Bool) {
        let previousSettings = AtriaNotificationSettings.load()
        if toggleOff {
            var disabled = previousSettings
            disabled.morningSummary = false
            disabled.save()
        }

        AtriaDebugLog("ATRIADBG notification_fixture kind=morning_summary status=scheduled_input toggle_off=%d recovery=64 sleep=7h42m hrv=58ms",
                      toggleOff ? 1 : 0)
        scheduleMorningSummary(recovery: 64,
                               sleepText: "7 h 42 m",
                               hrvText: "58 ms",
                               now: now,
                               calendar: calendar)

        if toggleOff {
            previousSettings.save()
        }
    }

    private static func scheduleHealthDeviationDebugFixture(now: Date = Date(),
                                                           calendar: Calendar = .current) {
        UserDefaults.standard.removeObject(forKey: healthDeviationLastScheduledKey)
        let today = calendar.startOfDay(for: now)
        let stat = DailyRollupVitals.Stat(mean: 16.0, sd: 0.4, n: 14)
        let vitals = DailyRollupVitals(rhr: nil, hrv: nil, resp: stat)
        let rollups = [
            DailyRollupStoreEntry(day: calendar.date(byAdding: .day, value: -3, to: today)!,
                                  respiratoryRate: 16.1,
                                  vitals: vitals,
                                  calendar: calendar),
            DailyRollupStoreEntry(day: calendar.date(byAdding: .day, value: -2, to: today)!,
                                  respiratoryRate: 16.0,
                                  vitals: vitals,
                                  calendar: calendar),
            DailyRollupStoreEntry(day: calendar.date(byAdding: .day, value: -1, to: today)!,
                                  respiratoryRate: 17.0,
                                  vitals: vitals,
                                  calendar: calendar),
            DailyRollupStoreEntry(day: today,
                                  respiratoryRate: 17.1,
                                  vitals: vitals,
                                  calendar: calendar)
        ]
        AtriaDebugLog("ATRIADBG notification_fixture kind=health_deviation status=scheduled_input vital=respiratory_rate days=2 direction=above")
        scheduleHealthDeviationIfNeeded(rollups: rollups, now: now, calendar: calendar)
    }

    private static func scheduleWeeklyReportDebugFixture(now: Date = Date(),
                                                        calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let rollups = (0..<14).map { offset in
            DailyRollupStoreEntry(day: calendar.date(byAdding: .day, value: -offset, to: today) ?? today,
                                  recovery: offset < 7 ? 69 - (offset % 3) : 64 - (offset % 2),
                                  sleepSeconds: 7.5 * 3_600,
                                  bedtimeMinutes: 23 * 60 + (offset % 2) * 10,
                                  strain: offset == 1 ? 12.4 : 7.0 + Double(offset % 3),
                                  calendar: calendar)
        }
        let report = WeeklyReport(rollups: rollups, now: now, calendar: calendar)
        AtriaDebugLog("ATRIADBG weekly_report_generation status=generated source=debug_fixture isoYear=%d isoWeek=%d recovery_avg=%d sleep_consistency=%d notification_requested=1",
                      report.isoYear,
                      report.isoWeek,
                      report.recoveryAvg ?? -1,
                      report.sleepConsistencyPct ?? -1)
        AtriaDebugLog("ATRIADBG notification_fixture kind=weekly_report status=scheduled_input isoYear=%d isoWeek=%d recovery_avg=%d",
                      report.isoYear,
                      report.isoWeek,
                      report.recoveryAvg ?? -1)
        scheduleWeeklyReport(report)
    }
#else
    private static func scheduleMorningSummaryDebugFixture(toggleOff: Bool) {}
    private static func scheduleHealthDeviationDebugFixture() {}
    private static func scheduleWeeklyReportDebugFixture() {}
#endif

    static func scheduleActionableConnectionDiagnosis(title: String,
                                                      body: String,
                                                      reason: String,
                                                      now: Date = Date()) {
        guard let decision = actionableConnectionDiagnosisDecision(title: title,
                                                                  body: body,
                                                                  reason: reason) else {
            AtriaDebugLog("ATRIADBG notification_skip kind=actionable_connection reason=diagnosis_%@", title)
            return
        }

        guard AtriaNotificationSettings.load().allows(kind: decision.kind) else {
            AtriaDebugLog("ATRIADBG notification_skip kind=%@ reason=user_disabled", decision.kind)
            return
        }

        configureDeliveryLogger()
        Task {
            let center = UNUserNotificationCenter.current()
            _ = await requestProvisionalAuthorization(center: center)
            let settings = await notificationSettings(center: center)
            let status = statusName(settings.authorizationStatus)
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else {
                AtriaDebugLog("ATRIADBG notification_schedule status=blocked reason=authorization_%@ kind=%@",
                              status,
                              decision.kind)
                return
            }

            let pending = await pendingRequests(center: center)
            if pending.contains(where: { $0.identifier == decision.identifier }) {
                AtriaDebugLog("ATRIADBG notification_skip kind=%@ reason=pending_request", decision.kind)
                return
            }

            let defaults = UserDefaults.standard
            if decision.kind == "battery" {
                // Authorization/pending-request checks are asynchronous. The
                // battery value that created this decision may have been
                // quarantined while they were in flight, so revalidate against
                // the latest accepted cache immediately before scheduling.
                let current = AtriaBLEManager.cachedBattery(
                    maxAge: 10 * 60,
                    permitActiveNotificationLease: true
                )
                let charging = current.chargeStatus == .charging || current.chargeStatus == .full
                guard Self.batteryAlertStillValid(level: current.level,
                                                  usable: current.usable,
                                                  isCharging: charging) else {
                    invalidateDisputedBatterySideEffects(reason: "stale_async_battery_decision",
                                                         defaults: defaults,
                                                         center: center)
                    AtriaDebugLog("ATRIADBG notification_skip kind=battery reason=stale_async_decision level=%d usable=%d charge=%@",
                                  current.level,
                                  current.usable ? 1 : 0,
                                  current.chargeStatus.rawValue)
                    return
                }
                if batteryDrainCycleAlreadyScheduled(title: decision.title, defaults: defaults) {
                    AtriaDebugLog("ATRIADBG notification_skip kind=battery reason=drain_cycle_already_scheduled title=%@",
                                  decision.title)
                    return
                }
            }
            let cooldownKey = actionableDiagnosisLastScheduledPrefix + decision.identifier
            let last = defaults.double(forKey: cooldownKey)
            if last > 0, now.timeIntervalSince(Date(timeIntervalSince1970: last)) < actionableDiagnosisCooldown {
                AtriaDebugLog("ATRIADBG notification_skip kind=%@ reason=cooldown", decision.kind)
                return
            }

            do {
                try await add(decision: decision, center: center)
                defaults.set(now.timeIntervalSince1970, forKey: cooldownKey)
                if decision.kind == "battery" {
                    markBatteryDrainCycleScheduled(title: decision.title, defaults: defaults)
                }
            } catch {
                AtriaDebugLog("ATRIADBG notification_error kind=%@ error=%@",
                              decision.kind,
                              String(describing: error))
            }
        }
    }

    nonisolated static func batteryAlertStillValid(level: Int,
                                                    usable: Bool,
                                                    isCharging: Bool) -> Bool {
        usable && level >= 0 && level <= actionableBatteryThreshold && !isCharging
    }

    static func cancelActionableConnectionDiagnosis(title: String? = nil, reason: String) {
        let identifiers: [String]
        if let title,
           let decision = actionableConnectionDiagnosisDecision(title: title,
                                                               body: "",
                                                               reason: reason) {
            identifiers = [decision.identifier]
        } else {
            identifiers = [Identifier.battery, Identifier.bluetoothOff, Identifier.fitCheck]
        }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        AtriaDebugLog("ATRIADBG notification_cancel kind=actionable_connection reason=%@ identifiers=%@",
                      reason,
                      identifiers.joined(separator: ","))
    }

    static func refreshActionableConnectionMaintenance(ble: AtriaBLEManager, reason: String) {
        _ = makeActionableConnectionDecisions(ble: ble)
        AtriaDebugLog("ATRIADBG notification_battery_maintenance status=evaluated reason=%@",
                      reason)
    }

    static func scheduleSleepLogged(_ sleep: UserConfirmedSleep, calendar: Calendar = .current) {
        guard AtriaNotificationSettings.load().allows(kind: "sleep_logged") else {
            AtriaDebugLog("ATRIADBG notification_skip kind=sleep_logged reason=user_disabled")
            return
        }
        // Wake-boundary saves and the wake+15 morning summary land minutes
        // apart for the same sleep event and share the same 6/day attention
        // budget — if the morning summary already announced this duration
        // today, don't spend a second slot re-announcing it here.
        let day = localDayIdentifier(for: sleep.end, calendar: calendar)
        let durationMinutes = Int(sleep.duration / 60)
        if shouldSkipRedundantSleepEvent(kind: "sleep_logged", durationMinutes: durationMinutes, day: day) {
            AtriaDebugLog("ATRIADBG notification_skip kind=sleep_logged reason=redundant_sleep_event day=%@", day)
            return
        }
        configureDeliveryLogger()
        Task {
            let center = UNUserNotificationCenter.current()
            _ = await requestProvisionalAuthorization(center: center)
            let settings = await notificationSettings(center: center)
            let status = statusName(settings.authorizationStatus)
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else {
                AtriaDebugLog("ATRIADBG notification_schedule status=blocked reason=authorization_%@ kind=sleep_logged",
                              status)
                return
            }
            do {
                try await add(decision: sleepLoggedDecision(for: sleep), center: center)
                recordSleepEvent(kind: "sleep_logged", durationMinutes: durationMinutes, day: day)
            } catch {
                AtriaDebugLog("ATRIADBG notification_error kind=sleep_logged error=%@",
                              String(describing: error))
            }
        }
    }

    /// The first launch/foreground workout-review lookup intentionally returns
    /// nil while SessionStore builds its review cache off-main. Dashboard
    /// publication is the completion signal for that build; retry this one
    /// notification only after Home has read the now-cached candidate.
    ///
    /// This path never clears unrelated pending requests. Candidate identity is
    /// reserved again inside `add`, shared with ordinary launch maintenance, so
    /// repeated dashboard publications cannot schedule or charge attention for
    /// the same physical effort twice.
    static func scheduleWorkoutReviewAfterCachePublicationIfNeeded(
        _ candidate: WorkoutReviewCandidate,
        ble: AtriaBLEManager
    ) {
        guard !reviewNotificationsProtectedByLiveCapture(ble: ble),
              candidate.isReviewPromptWorthy else { return }
        let defaults = UserDefaults.standard
        guard candidate.id != defaults.string(forKey: workoutReviewDismissedIDKey),
              candidate.id != defaults.string(forKey: workoutReviewLastCandidateIDKey),
              AtriaNotificationSettings.load().allows(kind: "workout_review") else {
            return
        }

        configureDeliveryLogger()
        let decision = NotificationDecision(
            kind: "workout_review",
            identifier: Identifier.workoutReview,
            title: workoutReviewNotificationTitle(for: candidate),
            body: workoutReviewNotificationBody(for: candidate),
            reason: "candidate_\(candidate.id)",
            shouldSchedule: true,
            delay: 6,
            userInfo: ["deepLink": "atria://overview"]
        )
        Task {
            let center = UNUserNotificationCenter.current()
            _ = await requestProvisionalAuthorization(center: center)
            let settings = await notificationSettings(center: center)
            let status = statusName(settings.authorizationStatus)
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else {
                AtriaDebugLog(
                    "ATRIADBG notification_schedule status=blocked reason=authorization_%@ kind=workout_review source=cache_publication",
                    status
                )
                return
            }
            do {
                try await add(decision: decision, center: center)
            } catch {
                AtriaDebugLog(
                    "ATRIADBG notification_error kind=workout_review source=cache_publication error=%@",
                    String(describing: error)
                )
            }
        }
    }

    /// Charge-pattern nudge (docs/24 §14.2 deferred item): once Atria has
    /// learned at least `strapChargeReminderMinLearnedHours` charge-start hours
    /// from AtriaBLEManager's rolling history, remind the user near their usual
    /// charge time whenever the strap is low and not currently charging. Reuses
    /// the "battery" kind so it inherits the existing budget/quiet-hours
    /// exemption for actionable device-health alerts.
    static func scheduleStrapChargeReminder(batteryLevel: Int,
                                            isCharging: Bool,
                                            now: Date = Date(),
                                            calendar: Calendar = .current) {
        guard AtriaNotificationSettings.load().allows(kind: "battery") else {
            AtriaDebugLog("ATRIADBG notification_skip kind=strap_charge reason=user_disabled")
            return
        }
        guard batteryLevel >= 0, batteryLevel < strapChargeReminderLowBatteryThreshold, !isCharging else {
            AtriaDebugLog("ATRIADBG notification_skip kind=strap_charge reason=not_low_or_charging level=%d charging=%d",
                          batteryLevel,
                          isCharging ? 1 : 0)
            return
        }

        let hours = UserDefaults.standard.array(forKey: AtriaBLEManager.ChargePatternDefaults.hours) as? [Int] ?? []
        guard hours.count >= strapChargeReminderMinLearnedHours else {
            AtriaDebugLog("ATRIADBG notification_skip kind=strap_charge reason=insufficient_learned_hours count=%d needed=%d",
                          hours.count,
                          strapChargeReminderMinLearnedHours)
            return
        }

        let medianHour = medianChargeHour(hours)
        let currentHour = calendar.component(.hour, from: now)
        let rawDelta = abs(currentHour - medianHour)
        let hourDelta = min(rawDelta, 24 - rawDelta)
        guard hourDelta <= strapChargeReminderHourTolerance else {
            AtriaDebugLog("ATRIADBG notification_skip kind=strap_charge reason=outside_learned_window current_hour=%d median_hour=%d",
                          currentHour,
                          medianHour)
            return
        }

        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: strapChargeReminderLastScheduledKey)
        if last > 0, now.timeIntervalSince(Date(timeIntervalSince1970: last)) < strapChargeReminderCooldown {
            AtriaDebugLog("ATRIADBG notification_skip kind=strap_charge reason=cooldown")
            return
        }

        configureDeliveryLogger()
        Task {
            let center = UNUserNotificationCenter.current()
            _ = await requestProvisionalAuthorization(center: center)
            let settings = await notificationSettings(center: center)
            let status = statusName(settings.authorizationStatus)
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else {
                AtriaDebugLog("ATRIADBG notification_schedule status=blocked reason=authorization_%@ kind=strap_charge",
                              status)
                return
            }

            center.removePendingNotificationRequests(withIdentifiers: [Identifier.strapChargeReminder])
            let decision = NotificationDecision(kind: "battery",
                                                identifier: Identifier.strapChargeReminder,
                                                title: "Strap charge window",
                                                body: "Battery at \(batteryLevel)% — you usually charge around \(medianHour):00. Top up before tonight sleep tracking.",
                                                reason: "learned_charge_hour_\(medianHour)_battery_\(batteryLevel)",
                                                shouldSchedule: true,
                                                delay: 5,
                                                userInfo: ["deepLink": "atria://strap"])
            do {
                try await add(decision: decision, center: center)
                defaults.set(now.timeIntervalSince1970, forKey: strapChargeReminderLastScheduledKey)
            } catch {
                AtriaDebugLog("ATRIADBG notification_error kind=strap_charge error=%@",
                              String(describing: error))
            }
        }
    }

    private static func medianChargeHour(_ hours: [Int]) -> Int {
        let sorted = hours.sorted()
        let mid = sorted.count / 2
        guard sorted.count % 2 == 0 else { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// True when a *different* kind ("morning_summary" vs. "sleep_logged")
    /// already announced a sleep of essentially the same duration on the same
    /// local day — the two land minutes apart for the same wake event and
    /// would otherwise burn two of the shared 6/day attention-budget slots.
    private static func shouldSkipRedundantSleepEvent(kind: String, durationMinutes: Int, day: String) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: sleepEventDedupDayKey) == day,
              let lastKind = defaults.string(forKey: sleepEventDedupKindKey),
              lastKind != kind else { return false }
        let lastMinutes = defaults.integer(forKey: sleepEventDedupMinutesKey)
        return abs(lastMinutes - durationMinutes) <= sleepEventDedupToleranceMinutes
    }

    private static func recordSleepEvent(kind: String, durationMinutes: Int, day: String) {
        let defaults = UserDefaults.standard
        defaults.set(day, forKey: sleepEventDedupDayKey)
        defaults.set(durationMinutes, forKey: sleepEventDedupMinutesKey)
        defaults.set(kind, forKey: sleepEventDedupKindKey)
    }

    private static var categoriesRegistered = false

    /// Notification responses can arrive during a cold launch, before the
    /// SwiftUI hierarchy has rendered or subscribed to its route publisher.
    /// Install the delegate from `UIApplicationDelegate` instead of waiting
    /// for a later scheduling pass, so the user's tap is never dropped.
    static func configureForApplicationLaunch() {
        configureDeliveryLogger()
    }

    private static func configureDeliveryLogger() {
        UNUserNotificationCenter.current().delegate = NotificationDeliveryLogger.shared
        registerNotificationCategoriesIfNeeded()
    }

    /// Registers the "log how you feel" action on the morning summary category
    /// once per process launch. Folds the wake-time journal nudge into the
    /// single morning notification (as an action button) instead of a second
    /// notification, so the shared attention budget only ever spends one slot
    /// on the wake moment.
    private static func registerNotificationCategoriesIfNeeded() {
        guard !categoriesRegistered else { return }
        categoriesRegistered = true
        let logJournalAction = UNNotificationAction(identifier: Identifier.logJournalAction,
                                                    title: "Log how you feel",
                                                    options: [.foreground])
        let morningSummaryCategory = UNNotificationCategory(identifier: "atria.morningSummary",
                                                             actions: [logJournalAction],
                                                             intentIdentifiers: [],
                                                             options: [])
        UNUserNotificationCenter.current().setNotificationCategories([morningSummaryCategory])
    }

    private static func schedule(store: SessionStore,
                                 ble: AtriaBLEManager,
                                 includeMetricDecisions: Bool,
                                 includeSleepReviewDecisions: Bool,
                                 includeWorkoutReviewDecisions: Bool,
                                 includeActionableConnectionDecisions: Bool,
                                 includeDiagnostic: Bool,
                                 productionCadence: Bool) async {
        let center = UNUserNotificationCenter.current()
        let granted = await requestProvisionalAuthorization(center: center)
        let settings = await notificationSettings(center: center)
        let status = statusName(settings.authorizationStatus)
        AtriaDebugLog("ATRIADBG notification_auth status=%@ granted=%d", status, granted ? 1 : 0)
        AtriaDebugLog("ATRIADBG notification_readiness status=%@ authorization=%@ metric_decisions=%d actionable_connection_decisions=%d diagnostic=%d production_cadence=%d action=%@",
              productionCadence ? "production_cadence" : "debug_trigger",
              status,
              includeMetricDecisions ? 1 : 0,
              includeActionableConnectionDecisions ? 1 : 0,
              includeDiagnostic ? 1 : 0,
              productionCadence ? 1 : 0,
              productionCadence ? "monitor_actionable_connection_triggers" : "debug_delivery_probe")

        guard settings.authorizationStatus == .authorized ||
                settings.authorizationStatus == .provisional ||
                settings.authorizationStatus == .ephemeral else {
            AtriaDebugLog("ATRIADBG notification_schedule status=blocked reason=authorization_%@", status)
            await logPendingRequests(center: center)
            return
        }

        center.removePendingNotificationRequests(withIdentifiers: Identifier.removable)

        var decisions: [NotificationDecision] = []
        if includeMetricDecisions {
            decisions.append(contentsOf: makeMetricDecisions(store: store, ble: ble))
        }
        if includeSleepReviewDecisions {
            decisions.append(await makeSleepReviewDecision(store: store))
        }
        if includeWorkoutReviewDecisions {
            decisions.append(makeWorkoutReviewDecision(store: store, ble: ble))
        }
        if includeActionableConnectionDecisions {
            decisions.append(contentsOf: makeActionableConnectionDecisions(ble: ble))
        }
        if includeDiagnostic {
            decisions.append(NotificationDecision(
                kind: "diagnostic",
                identifier: Identifier.diagnostic,
                title: "Atria notification test",
                body: "Local notification delivery is working.",
                reason: "debug_delivery_probe",
                shouldSchedule: true,
                delay: 3
            ))
        }
        let preferences = AtriaNotificationSettings.load()
        var scheduled = 0
        let defaults = UserDefaults.standard
        for decision in decisions where decision.shouldSchedule {
            guard preferences.allows(kind: decision.kind) else {
                AtriaDebugLog("ATRIADBG notification_skip kind=%@ reason=user_disabled", decision.kind)
                continue
            }
            if decision.kind == "battery",
               batteryDrainCycleAlreadyScheduled(title: decision.title, defaults: defaults) {
                AtriaDebugLog("ATRIADBG notification_skip kind=battery reason=drain_cycle_already_scheduled title=%@",
                              decision.title)
                continue
            }
            do {
                try await add(decision: decision, center: center)
                scheduled += 1
                if decision.kind == "battery" {
                    markBatteryDrainCycleScheduled(title: decision.title, defaults: defaults)
                }
            } catch {
                AtriaDebugLog("ATRIADBG notification_error kind=%@ error=%@",
                      decision.kind,
                      String(describing: error))
            }
        }
        for decision in decisions where !decision.shouldSchedule {
            AtriaDebugLog("ATRIADBG notification_skip kind=%@ reason=%@",
                  decision.kind,
                  decision.reason)
        }
        AtriaDebugLog("ATRIADBG notification_schedule status=scheduled count=%d", scheduled)
        await logPendingRequests(center: center)
    }

    private static func makeMetricDecisions(store: SessionStore,
                                            ble: AtriaBLEManager) -> [NotificationDecision] {
        let now = Date()
        let calendar = Calendar.current
        let latestSleep = store.currentPhysiologicalMainSleep(on: now)
        let physiologicalCycle = AtriaPhysiologicalCycle.current(now: now,
                                                                 confirmedSleeps: store.confirmedSleeps,
                                                                 calendar: calendar)
        let recovery = store.recoveryProjection(
            now: now,
            calendar: calendar,
            initialFallbackHRVSnapshot: ble.recoveryHRVSnapshot,
            liveRestingHeartRate: ble.restingHR
        )
        let recoveryDecision: NotificationDecision
        if let percent = recovery.percent {
            recoveryDecision = NotificationDecision(
                kind: "recovery",
                identifier: Identifier.recovery,
                title: "Recovery ready",
                body: recoveryNotificationBody(percent: percent,
                                               detail: recovery.detail),
                reason: "percent_\(percent)_confidence_\(recovery.confidence.rawValue)",
                shouldSchedule: true,
                delay: 5,
                userInfo: ["deepLink": "atria://overview"]
            )
        } else {
            let reason = recovery.percent == nil
                ? recovery.detail.replacingOccurrences(of: " ", with: "_")
                : "recovery_confidence_\(recovery.confidence.rawValue)"
            recoveryDecision = NotificationDecision(
                kind: "recovery",
                identifier: Identifier.recovery,
                title: "",
                body: "",
                reason: reason,
                shouldSchedule: false,
                delay: 0
            )
        }

        let rest = store.baseline.restingInt ?? ble.restingHR ?? store.sessions.first?.restingStable ?? 60
        let savedTRIMP = store.homeSavedAggregate(rest: rest,
                                                   maxHR: store.profile.maxHR,
                                                   activeSessionID: ble.currentLiveSessionID)
        // Perf (2026-07-08 audit): reuse the incremental accumulator (integrates
        // only NEW samples) instead of re-mapping + re-integrating the whole
        // live session (up to ~80k samples) on every notification evaluation.
        // Same TRIMP math (consecutive dt is identical); both are @MainActor.
        let liveTRIMP = WidgetSnapshotPublisher.incrementalLiveTRIMP(samples: ble.session,
                                                                     rest: rest,
                                                                     max: store.profile.maxHR,
                                                                     sex: store.profile.biologicalSex,
                                                                     cycleStart: savedTRIMP.day)
        let totalTRIMP = SessionStore.mergedTodayTRIMP(
            savedToday: savedTRIMP.savedTodayTRIMP,
            savedActiveSession: savedTRIMP.savedActiveSessionTRIMP,
            liveActiveSession: liveTRIMP
        )
        let strain = Metrics.strain(fromTRIMP: totalTRIMP)
        // Notifications must use the same sleep-to-sleep attribution as Home
        // and widgets. Civil-date matching made late/shift sleepers receive a
        // target derived from a different recovery than the ring displayed.
        let storedCycleRecovery = store.dailyRollupHistory.first {
            physiologicalCycle.boundaryKind == .mainSleep
                && calendar.isDate($0.day, inSameDayAs: physiologicalCycle.start)
                && $0.recovery != nil
        }?.recovery
        let attributedRecovery: Int?
        if physiologicalCycle.boundaryKind == .noSleepFallback {
            attributedRecovery = nil
        } else {
            attributedRecovery = storedCycleRecovery
                ?? (latestSleep.map { ($0.end ?? $0.day) == physiologicalCycle.start } == true
                    ? recovery.percent
                    : nil)
        }
        let frozenTarget = AtriaDailyStrainTargetStore.resolve(recovery: attributedRecovery,
                                                               load: store.trainingLoadSummarySnapshot,
                                                               recoveryIsAttributedToCurrentDay: attributedRecovery != nil,
                                                               loadIsPrepared: store.hasLoadedSavedSessions && store.trainingLoadSummaryIsPrepared,
                                                               cycleStart: physiologicalCycle.start,
                                                               now: now,
                                                               calendar: calendar)
        let guideRecovery = attributedRecovery ?? frozenTarget?.recovery
        let guide = guideRecovery.map {
            Coach.guide(recovery: $0,
                        strain: strain,
                        frozenTarget: frozenTarget?.target ?? Coach.baseStrainTarget(recovery: $0))
        }
        let strainDecision: NotificationDecision
        if guideRecovery == nil {
            strainDecision = NotificationDecision(
                kind: "strain",
                identifier: Identifier.strain,
                title: "",
                body: "",
                reason: "recovery_learning_\(recovery.confidence.rawValue)",
                shouldSchedule: false,
                delay: 0
            )
        } else if let target = guide?.target, strain >= target {
            strainDecision = NotificationDecision(
                kind: "strain",
                identifier: Identifier.strain,
                title: "Strain target reached",
                body: String(format: "Nice work. You reached today's strain target with %.1f strain against a %.1f goal.", strain, target),
                reason: String(format: "strain_%.1f_target_%.1f", strain, target),
                shouldSchedule: true,
                delay: 7,
                userInfo: ["deepLink": "atria://overview"]
            )
        } else {
            strainDecision = NotificationDecision(
                kind: "strain",
                identifier: Identifier.strain,
                title: "",
                body: "",
                reason: String(format: "not_at_target_strain_%.1f", strain),
                shouldSchedule: false,
                delay: 0
            )
        }

        return [recoveryDecision, strainDecision]
    }

    private static func healthDeviationDecision(rollups: [DailyRollupStoreEntry],
                                                now: Date,
                                                calendar: Calendar) -> NotificationDecision? {
        let recent = rollups
            .sorted { $0.day > $1.day }
            .prefix(7)
        guard recent.count >= 2 else { return nil }
        let latestTwo = Array(recent.prefix(2))

        let candidates: [(kind: String, value: (DailyRollupStoreEntry) -> Double?, stat: (DailyRollupVitals) -> DailyRollupVitals.Stat?)] = [
            ("resting heart rate", { $0.rhr.map(Double.init) }, { $0.rhr }),
            ("HRV", { $0.lnRMSSD.map(exp) }, { $0.hrv }),
            ("respiratory rate", { $0.respiratoryRate }, { $0.resp }),
        ]

        for candidate in candidates {
            let deviations = latestTwo.compactMap { entry -> Int? in
                guard let value = candidate.value(entry),
                      let stat = entry.vitals.flatMap(candidate.stat),
                      stat.n >= 3,
                      stat.sd > 0 else { return nil }
                let z = (value - stat.mean) / stat.sd
                guard abs(z) >= 2 else { return nil }
                return z > 0 ? 1 : -1
            }
            guard deviations.count == 2,
                  let first = deviations.first,
                  deviations.allSatisfy({ $0 == first }) else {
                continue
            }
            let direction = first > 0 ? "above" : "below"
            return NotificationDecision(kind: "health_deviation",
                                        identifier: Identifier.healthDeviation,
                                        title: "Health Monitor",
                                        body: "Your \(candidate.kind) has been \(direction) your typical range for 2 days. Worth keeping an eye on.",
                                        reason: "two_day_\(candidate.kind.replacingOccurrences(of: " ", with: "_"))_\(direction)_typical",
                                        shouldSchedule: true,
                                        delay: 1,
                                        categoryIdentifier: "atria.healthDeviation",
                                        userInfo: ["deepLink": "atria://vitals"])
        }

        return nil
    }

    private static func makeActionableConnectionDecisions(ble: AtriaBLEManager) -> [NotificationDecision] {
        let bluetoothDecision: NotificationDecision
        if ble.status == .poweredOff {
            if ble.bluetoothPermissionDenied {
                return [NotificationDecision(
                    kind: "bluetooth_off",
                    identifier: Identifier.bluetoothOff,
                    title: "",
                    body: "",
                    reason: "bluetooth_permission_inline_only",
                    shouldSchedule: false,
                    delay: 0
                )]
            }
            bluetoothDecision = NotificationDecision(
                kind: "bluetooth_off",
                identifier: Identifier.bluetoothOff,
                title: "Bluetooth is off",
                body: "Turn on Bluetooth in Settings so Atria can read your strap.",
                reason: "bluetooth_powered_off",
                shouldSchedule: true,
                delay: 9
            )
            return [bluetoothDecision]
        }

        let battery = batterySnapshot(liveLevel: ble.batteryLevel, liveChargeStatus: ble.batteryChargeStatus)
        if !battery.usable, battery.source == "disputed_rapid_transition" {
            invalidateDisputedBatterySideEffects(reason: "disputed_rapid_transition")
        }
        let effectiveChargeStatus = battery.chargeStatus
        let batteryIsCharging = effectiveChargeStatus == .charging || effectiveChargeStatus == .full
        if battery.usable,
           batteryIsCharging || battery.level > Self.actionableBatteryThreshold {
            clearBatteryDrainCycleState(reason: batteryIsCharging ? "charging" : "above_threshold")
        }
        AtriaDebugLog("ATRIADBG notification_battery_decision level=%d source=%@ age_s=%.0f usable=%d threshold=%d charge=%@ drop_recent=%d",
              battery.level,
              battery.source,
              battery.age,
              battery.usable ? 1 : 0,
              Self.actionableBatteryThreshold,
              effectiveChargeStatus.rawValue,
              battery.recentDrop ? 1 : 0)
        let batteryDecision: NotificationDecision
        if battery.usable && battery.level <= Self.actionableBatteryThreshold && battery.recentDrop && !batteryIsCharging {
            batteryDecision = NotificationDecision(
                kind: "battery",
                identifier: Identifier.battery,
                title: "Strap battery low",
                body: "Charge your strap before a workout or overnight wear. Battery is \(battery.level)%.",
                reason: "battery_\(battery.level)_drop_source_\(battery.source)",
                shouldSchedule: true,
                delay: 9
            )
        } else {
            let reason: String
            if battery.usable && batteryIsCharging {
                reason = "battery_\(battery.level)_charging_\(effectiveChargeStatus.rawValue)_source_\(battery.source)"
            } else if battery.usable && battery.level <= Self.actionableBatteryThreshold && !battery.recentDrop {
                reason = "battery_\(battery.level)_low_no_recent_drop_source_\(battery.source)"
            } else {
                reason = battery.usable
                    ? "battery_\(battery.level)_not_low_source_\(battery.source)"
                    : "battery_learning_source_\(battery.source)"
            }
            batteryDecision = NotificationDecision(
                kind: "battery",
                identifier: Identifier.battery,
                title: "",
                body: "",
                reason: reason,
                shouldSchedule: false,
                delay: 0
            )
        }

        bluetoothDecision = NotificationDecision(
            kind: "bluetooth_off",
            identifier: Identifier.bluetoothOff,
            title: "",
            body: "",
            reason: "status_\(ble.status.rawValue.replacingOccurrences(of: " ", with: "_"))",
            shouldSchedule: false,
            delay: 0
        )

        return [batteryDecision, bluetoothDecision]
    }

    private static func makeSleepReviewDecision(store: SessionStore) async -> NotificationDecision {
        let snapshot = store.sleepHistorySnapshot
        let defaults = UserDefaults.standard
        let rest = store.baseline.restingInt ?? 60
        var latestReviewNight: SleepHistorySnapshot.Night?
        for attempt in 0..<250 {
            switch store.sleepReviewResolutionForUI(rest: rest,
                                                    source: "notification_sleep_review") {
            case .ready(let night):
                latestReviewNight = night
                break
            case .loading:
                if attempt < 249 {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                continue
            }
            break
        }

        let reviewableSnapshotNight = snapshot.latestReviewable?.confirmed == false ? snapshot.latestReviewable : nil
        guard let latest = latestReviewNight ?? reviewableSnapshotNight,
              latest.confirmed == false else {
            let reason = sleepReviewUnavailableReason(snapshot: snapshot, store: store)
            defaults.removeObject(forKey: sleepReviewLastCandidateIDKey)
            return NotificationDecision(
                kind: "sleep_review",
                identifier: Identifier.sleepReview,
                title: "",
                body: "",
                reason: reason,
                shouldSchedule: false,
                delay: 0
            )
        }

        // The notification scheduler can legitimately see a reviewable daily
        // snapshot while the heavier foreground cache is still rebuilding.
        // Persist the exact candidate before scheduling/deduplication so a
        // relaunch, projection refresh, or reminder cooldown cannot erase the
        // review the user was just told about.
        AtriaPendingSleepReviewStore.save(latest)

        guard latest.id != defaults.string(forKey: sleepReviewDismissedIDKey) else {
            return NotificationDecision(
                kind: "sleep_review",
                identifier: Identifier.sleepReview,
                title: "",
                body: "",
                reason: "candidate_dismissed_locally",
                shouldSchedule: false,
                delay: 0
            )
        }

        // Window-start debounce (2026-08-01): a NEW candidate id whose start
        // matches an already-notified window is the same physical episode
        // with a jittering end — never re-fire unless the end grew >= 30 min
        // beyond what the user was already told. Same-id reminders below keep
        // their existing count/cooldown gates unchanged; a different start is
        // a separate episode and stays independent.
        if latest.id != defaults.string(forKey: sleepReviewLastCandidateIDKey),
           let candidateStart = latest.start,
           let candidateEnd = latest.end {
            let notifiedEnds = (defaults.dictionary(
                forKey: sleepReviewNotifiedEndByStartKey
            ) as? [String: Double]) ?? [:]
            guard AtriaSleepReviewNotificationDebounce.shouldNotify(
                start: candidateStart,
                end: candidateEnd,
                lastNotifiedEndByStart: notifiedEnds
            ) else {
                return NotificationDecision(
                    kind: "sleep_review",
                    identifier: Identifier.sleepReview,
                    title: "",
                    body: "",
                    reason: "window_end_jitter_debounced",
                    shouldSchedule: false,
                    delay: 0
                )
            }
        }

        if latest.id == defaults.string(forKey: sleepReviewLastCandidateIDKey) {
            let count = defaults.integer(forKey: sleepReviewCandidateScheduleCountPrefix + latest.id)
            let lastScheduledAt = defaults.double(forKey: sleepReviewCandidateScheduledAtPrefix + latest.id)
            let elapsed = lastScheduledAt > 0 ? Date().timeIntervalSince(Date(timeIntervalSince1970: lastScheduledAt)) : sleepReviewReminderCooldown
            guard count < sleepReviewMaximumSchedulesPerCandidate else {
                return NotificationDecision(
                    kind: "sleep_review",
                    identifier: Identifier.sleepReview,
                    title: "",
                    body: "",
                    reason: "candidate_reminder_limit_reached",
                    shouldSchedule: false,
                    delay: 0
                )
            }
            guard elapsed >= sleepReviewReminderCooldown else {
                return NotificationDecision(
                    kind: "sleep_review",
                    identifier: Identifier.sleepReview,
                    title: "",
                    body: "",
                    reason: "candidate_reminder_cooldown",
                    shouldSchedule: false,
                    delay: 0
                )
            }
        }

        let title = sleepReviewNotificationTitle(for: latest)
        let body = sleepReviewNotificationBody(for: latest)

        return NotificationDecision(
            kind: "sleep_review",
            identifier: Identifier.sleepReview,
            title: title,
            body: body,
            reason: "candidate_\(latest.id)",
            shouldSchedule: true,
            delay: 6,
            userInfo: ["deepLink": "atria://sleep-review"],
            sleepReviewWindowStart: latest.start,
            sleepReviewWindowEnd: latest.end
        )
    }

    private static func sleepReviewNotificationTitle(for night: SleepHistorySnapshot.Night) -> String {
        night.isNapEvidence ? "Review your nap" : "Review last night"
    }

    private static func sleepReviewNotificationBody(for night: SleepHistorySnapshot.Night) -> String {
        let action = night.isNapEvidence
            ? "Confirm, adjust, or keep it separate."
            : "Confirm or adjust the timing."
        if let start = night.start, let end = night.end {
            let startText = start.formatted(date: .omitted, time: .shortened)
            let endText = end.formatted(date: .omitted, time: .shortened)
            return "\(night.durationText), \(startText)-\(endText). \(action)"
        }
        if let end = night.end {
            let endText = end.formatted(date: .omitted, time: .shortened)
            return "\(night.durationText), ending \(endText). \(action)"
        }
        return "\(night.durationText). \(action)"
    }

    private static func sleepLoggedDecision(for sleep: UserConfirmedSleep) -> NotificationDecision {
        NotificationDecision(kind: "sleep_logged",
                             identifier: Identifier.sleepLogged,
                             title: "Sleep logged",
                             body: "\(SleepHistorySnapshot.formatDuration(sleep.duration)) · \(sleep.start.formatted(date: .omitted, time: .shortened))-\(sleep.end.formatted(date: .omitted, time: .shortened)). Edit in Atria.",
                             reason: "auto_confirmed_\(sleep.id)",
                             shouldSchedule: true,
                             delay: 3)
    }

    private static func makeWorkoutReviewDecision(store: SessionStore, ble: AtriaBLEManager) -> NotificationDecision {
        let defaults = UserDefaults.standard
        guard !reviewNotificationsProtectedByLiveCapture(ble: ble) else {
            defaults.removeObject(forKey: workoutReviewLastCandidateIDKey)
            return NotificationDecision(
                kind: "workout_review",
                identifier: Identifier.workoutReview,
                title: "",
                body: "",
                reason: "live_capture_protected_range_loss_backfill",
                shouldSchedule: false,
                delay: 0
            )
        }

        let rest = store.baseline.restingInt ?? 60
        guard let candidate = store.latestWorkoutReviewCandidate(rest: rest,
                                                                 maxHR: store.profile.maxHR,
                                                                 source: "notification") else {
            defaults.removeObject(forKey: workoutReviewLastCandidateIDKey)
            return NotificationDecision(
                kind: "workout_review",
                identifier: Identifier.workoutReview,
                title: "",
                body: "",
                reason: "no_reviewable_workout_candidate",
                shouldSchedule: false,
                delay: 0
            )
        }

        guard candidate.id != defaults.string(forKey: workoutReviewDismissedIDKey) else {
            return NotificationDecision(
                kind: "workout_review",
                identifier: Identifier.workoutReview,
                title: "",
                body: "",
                reason: "candidate_dismissed_locally",
                shouldSchedule: false,
                delay: 0
            )
        }

        guard candidate.id != defaults.string(forKey: workoutReviewLastCandidateIDKey) else {
            return NotificationDecision(
                kind: "workout_review",
                identifier: Identifier.workoutReview,
                title: "",
                body: "",
                reason: "candidate_already_notified",
                shouldSchedule: false,
                delay: 0
            )
        }

        guard workoutReviewCandidateIsPushWorthy(candidate) else {
            return NotificationDecision(
                kind: "workout_review",
                identifier: Identifier.workoutReview,
                title: "",
                body: "",
                reason: "candidate_visible_in_app_not_push_worthy",
                shouldSchedule: false,
                delay: 0
            )
        }

        return NotificationDecision(
            kind: "workout_review",
            identifier: Identifier.workoutReview,
            title: workoutReviewNotificationTitle(for: candidate),
            body: workoutReviewNotificationBody(for: candidate),
            reason: "candidate_\(candidate.id)",
            shouldSchedule: true,
            delay: 6,
            userInfo: ["deepLink": "atria://overview"]
        )
    }

    private static func workoutReviewNotificationTitle(for candidate: WorkoutReviewCandidate) -> String {
        candidate.kind == .workout ? "Workout found" : "Effort found"
    }

    private static func workoutReviewNotificationBody(for candidate: WorkoutReviewCandidate) -> String {
        let startText = candidate.start.formatted(date: .omitted, time: .shortened)
        let endText = candidate.end.formatted(date: .omitted, time: .shortened)
        let reviewHint = workoutReviewReviewHint(for: candidate)
        let action = candidate.kind == .workout
            ? "Confirm type or dismiss."
            : "Label it if it was training."
        return "Strap heart-rate window \(candidate.durationMinutes)m, \(startText)-\(endText). \(reviewHint) \(action)"
    }

    private static func workoutReviewReviewHint(for candidate: WorkoutReviewCandidate) -> String {
        if candidate.streamCoveragePercent >= 75, candidate.gapCount == 0 {
            return "Looks complete."
        }
        if candidate.streamCoveragePercent >= 60 {
            return "Adjust if the timing is off."
        }
        return "Review the window before saving."
    }

    private static func workoutReviewCandidateIsPushWorthy(_ candidate: WorkoutReviewCandidate) -> Bool {
        candidate.isReviewPromptWorthy
    }

    private static func reviewNotificationsProtectedByLiveCapture(ble: AtriaBLEManager) -> Bool {
        ble.status == .connected
            && ble.rangeLossBackfillPending
            && ble.sessionSampleCount > 0
    }

    private static func sleepReviewUnavailableReason(snapshot: SleepHistorySnapshot,
                                                     store: SessionStore) -> String {
        let rest = store.baseline.restingInt ?? 60
        let evidence = store.sleepEvidenceStatusFast(rest: rest)
        if evidence.candidates > 0 {
            if evidence.readyCandidates > 0 {
                return "sleep_candidate_waiting_history_snapshot"
            }
            return "sleep_candidate_pending_validation_\(evidence.blocker)"
        }
        if evidence.fallbackAvailable {
            return "sleep_candidate_pending_validation_\(evidence.blocker)"
        }
        if snapshot.candidateCount > 0 {
            return "sleep_candidate_not_reviewable"
        }
        return "no_unconfirmed_sleep_candidate"
    }

    private static func actionableConnectionDiagnosisDecision(title: String,
                                                              body: String,
                                                              reason: String) -> NotificationDecision? {
        switch title {
        case "Strap battery low", "Strap battery too low":
            return NotificationDecision(kind: "battery",
                                        identifier: Identifier.battery,
                                        title: title,
                                        body: body,
                                        reason: "visible_diagnosis_\(reason)",
                                        shouldSchedule: true,
                                        delay: 9)
        case "Bluetooth is off":
            return NotificationDecision(kind: "bluetooth_off",
                                        identifier: Identifier.bluetoothOff,
                                        title: title,
                                        body: body,
                                        reason: "visible_diagnosis_\(reason)",
                                        shouldSchedule: true,
                                        delay: 11)
        case "Fit check needed":
            return NotificationDecision(kind: "fit_check",
                                        identifier: Identifier.fitCheck,
                                        title: title,
                                        body: body,
                                        reason: "visible_diagnosis_\(reason)",
                                        shouldSchedule: true,
                                        delay: 9)
        default:
            return nil
        }
    }

    private static func batteryDrainCycleKey(title: String) -> String? {
        switch title {
        case "Strap battery low":
            return batteryWarningDrainCycleScheduledKey
        case "Strap battery too low":
            return batteryShutoffDrainCycleScheduledKey
        default:
            return nil
        }
    }

    private static func batteryDrainCycleAlreadyScheduled(title: String,
                                                          defaults: UserDefaults = .standard) -> Bool {
        guard let key = batteryDrainCycleKey(title: title) else { return false }
        return defaults.bool(forKey: key)
    }

    private static func markBatteryDrainCycleScheduled(title: String,
                                                       defaults: UserDefaults = .standard) {
        guard let key = batteryDrainCycleKey(title: title) else { return }
        defaults.set(true, forKey: key)
        AtriaDebugLog("ATRIADBG notification_battery_drain_cycle status=marked title=%@", title)
    }

    private static func clearBatteryDrainCycleState(reason: String,
                                                    defaults: UserDefaults = .standard,
                                                    now: Date = Date()) {
        let hadDrainCycle = defaults.bool(forKey: batteryWarningDrainCycleScheduledKey) ||
            defaults.bool(forKey: batteryShutoffDrainCycleScheduledKey)
        defaults.set(false, forKey: batteryWarningDrainCycleScheduledKey)
        defaults.set(false, forKey: batteryShutoffDrainCycleScheduledKey)
        defaults.set(now.timeIntervalSince1970, forKey: batteryDrainCycleClearedAtKey)
        defaults.removeObject(forKey: actionableDiagnosisLastScheduledPrefix + Identifier.battery)
        AtriaDebugLog("ATRIADBG notification_battery_drain_cycle status=cleared reason=%@ had_cycle=%d",
                      reason,
                      hadDrainCycle ? 1 : 0)
    }

    /// A quarantined battery transition is not merely "unknown"—any alert
    /// derived from it is false evidence. Remove pending/delivered warnings and
    /// reset the drain-cycle cooldown so a later genuinely low stable series
    /// can notify normally.
    static func invalidateDisputedBatterySideEffects(
        reason: String,
        defaults: UserDefaults = .standard,
        center: UNUserNotificationCenter = .current()
    ) {
        clearBatteryDrainCycleState(reason: reason, defaults: defaults)
        let identifiers = [Identifier.battery, Identifier.strapChargeReminder]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        defaults.removeObject(forKey: strapChargeReminderLastScheduledKey)
        AtriaDebugLog("ATRIADBG notification_battery_disputed action=cancel_all reason=%@", reason)
    }

    static func batterySnapshot(liveLevel: Int,
        liveChargeStatus: AtriaBLEManager.BatteryChargeStatus,
        defaults: UserDefaults = .standard,
        now: Date = Date()) -> (level: Int, source: String, age: TimeInterval, chargeStatus: AtriaBLEManager.BatteryChargeStatus, usable: Bool, recentDrop: Bool) {
        let drop = AtriaBLEManager.cachedBatteryDrop()
        let cached = AtriaBLEManager.cachedBattery(
            maxAge: AtriaBLEManager.batteryDisplayFreshnessLimit,
            defaults: defaults,
            now: now,
            permitActiveNotificationLease: true
        )
        if cached.usable {
            let liveMatchesAcceptedProjection = liveLevel == cached.level
            let chargeStatus = liveMatchesAcceptedProjection && liveChargeStatus != .levelOnly
                ? liveChargeStatus
                : cached.chargeStatus
            let source: String
            if liveMatchesAcceptedProjection {
                source = cached.age <= AtriaBLEManager.batteryDisplayFreshnessLimit
                    ? "live_2A19_fresh"
                    : "live_2A19_active_lease"
            } else {
                source = cached.source
            }
            return (cached.level, source, cached.age, chargeStatus, true, drop.recent)
        }
        return (cached.level, cached.source == "none" ? "learning" : "\(cached.source)_stale", cached.age, cached.chargeStatus, false, false)
    }

    private static func recoveryNotificationBody(percent: Int,
                                                 detail: String) -> String {
        "Recovery is \(percent)% today. \(detail) Use it to choose whether to push, hold, or recover."
    }

    // Attention budget + ledger (docs/24 §14.2): user-facing kinds are capped
    // per local day so the app never feels naggy, and every scheduled/skipped
    // decision leaves a receipt the user (and debugging) can audit.
    static let attentionBudgetPerDay = 6
    private static let budgetExemptKinds: Set<String> = ["diagnostic", "battery", "bluetooth_off"]
    private static let budgetCountKeyPrefix = "atria.notification.budget."
    private static let ledgerKey = "atria.notification.ledger.v1"
    private static let ledgerCapacity = 60

    private static func recordLedgerEntry(kind: String, action: String, detail: String) {
        let defaults = UserDefaults.standard
        var ledger = defaults.stringArray(forKey: ledgerKey) ?? []
        let stamp = ISO8601DateFormatter().string(from: Date())
        ledger.append("\(stamp)|\(kind)|\(action)|\(detail)")
        if ledger.count > ledgerCapacity {
            ledger.removeFirst(ledger.count - ledgerCapacity)
        }
        defaults.set(ledger, forKey: ledgerKey)
    }

    static func consumeAttentionBudget(kind: String,
                                       now: Date = Date(),
                                       defaults: UserDefaults = .standard) -> Bool {
        guard !budgetExemptKinds.contains(kind) else { return true }
        let day = localDayIdentifier(for: now, calendar: .current)
        let key = budgetCountKeyPrefix + day
        let used = defaults.integer(forKey: key)
        guard used < attentionBudgetPerDay else {
            AtriaDebugLog("ATRIADBG notification_budget status=exhausted kind=%@ used=%d cap=%d",
                          kind,
                          used,
                          attentionBudgetPerDay)
            recordLedgerEntry(kind: kind, action: "suppressed_budget", detail: "\(used)/\(attentionBudgetPerDay)")
            return false
        }
        defaults.set(used + 1, forKey: key)
        // Keep the defaults tidy: drop the counter from two days ago.
        if let staleDay = Calendar.current.date(byAdding: .day, value: -2, to: now) {
            defaults.removeObject(forKey: budgetCountKeyPrefix + localDayIdentifier(for: staleDay, calendar: .current))
        }
        return true
    }

    /// Learned quiet hours = actual sleep span (the duty-cycle window minus its
    /// 1 h padding on each side). Non-exempt notifications landing inside it are
    /// deferred to wake; device-health alerts still get through.
    static func quietHoursAdjustedDelay(kind: String,
                                        delay: TimeInterval,
                                        now: Date = Date(),
                                        calendar: Calendar = .current,
                                        defaults: UserDefaults = .standard) -> TimeInterval {
        guard !budgetExemptKinds.contains(kind) else { return delay }
        let windowStart = defaults.integer(forKey: AtriaBLEManager.DutyCycleDefaults.sleepWindowStartMin)
        let windowEnd = defaults.integer(forKey: AtriaBLEManager.DutyCycleDefaults.sleepWindowEndMin)
        guard windowStart > 0 || windowEnd > 0 else { return delay }
        let quietStart = (windowStart + 60) % 1440
        let quietEnd = (windowEnd + 1440 - 60) % 1440
        let delivery = now.addingTimeInterval(delay)
        let components = calendar.dateComponents([.hour, .minute], from: delivery)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let insideQuiet: Bool
        if quietStart <= quietEnd {
            insideQuiet = minutes >= quietStart && minutes < quietEnd
        } else {
            insideQuiet = minutes >= quietStart || minutes < quietEnd
        }
        guard insideQuiet else { return delay }
        let minutesUntilWake = (quietEnd - minutes + 1440) % 1440
        let adjusted = delay + TimeInterval(minutesUntilWake * 60)
        AtriaDebugLog("ATRIADBG notification_quiet_hours kind=%@ deferred_min=%d wake_min=%d",
                      kind,
                      minutesUntilWake,
                      quietEnd)
        recordLedgerEntry(kind: kind, action: "deferred_quiet_hours", detail: "\(minutesUntilWake)m")
        return adjusted
    }

    /// fit_check nudges repeat while the underlying condition persists, so
    /// left ungated they can drain the whole shared attention budget in one
    /// loose-strap evening (observed 2026-07-05: used=6 cap=6, silencing the
    /// journal check-in and morning summary). Own cap: 2/day, 4 h apart.
    private static func fitCheckAllowed(now: Date = Date()) -> Bool {
        let defaults = UserDefaults.standard
        let lastKey = "atria.notification.fitcheck.lastAt"
        let dayKey = "atria.notification.fitcheck.day"
        let countKey = "atria.notification.fitcheck.dayCount"
        let day = localDayIdentifier(for: now, calendar: .current)
        let count = defaults.string(forKey: dayKey) == day ? defaults.integer(forKey: countKey) : 0
        let last = defaults.object(forKey: lastKey) as? Date ?? .distantPast
        guard count < 2, now.timeIntervalSince(last) >= 4 * 60 * 60 else {
            AtriaDebugLog("ATRIADBG notification_skip kind=fit_check reason=own_cap count=%d since_last_s=%.0f",
                          count, now.timeIntervalSince(last))
            return false
        }
        defaults.set(day, forKey: dayKey)
        defaults.set(count + 1, forKey: countKey)
        defaults.set(now, forKey: lastKey)
        return true
    }

    private static func add(decision: NotificationDecision,
                            center: UNUserNotificationCenter) async throws {
        let workoutCandidateID = decision.kind == "workout_review"
            ? decision.reason.split(separator: "_", maxSplits: 1).dropFirst().first.map(String.init)
            : nil
        if let workoutCandidateID {
            guard workoutReviewDeliveryCanReserve(
                candidateID: workoutCandidateID,
                lastNotifiedCandidateID: UserDefaults.standard.string(
                    forKey: workoutReviewLastCandidateIDKey
                ),
                inFlightCandidateIDs: workoutReviewCandidateIDsInFlight
            ),
                  workoutReviewCandidateIDsInFlight.insert(workoutCandidateID).inserted else {
                AtriaDebugLog(
                    "ATRIADBG notification_skip kind=workout_review reason=candidate_already_scheduled_or_inflight candidate=%@",
                    workoutCandidateID
                )
                return
            }
        }
        defer {
            if let workoutCandidateID {
                workoutReviewCandidateIDsInFlight.remove(workoutCandidateID)
            }
        }
        if decision.kind == "fit_check", !fitCheckAllowed() { return }
        guard consumeAttentionBudget(kind: decision.kind) else { return }
        var decision = decision
        decision = NotificationDecision(kind: decision.kind,
                                        identifier: decision.identifier,
                                        title: decision.title,
                                        body: decision.body,
                                        reason: decision.reason,
                                        shouldSchedule: decision.shouldSchedule,
                                        delay: quietHoursAdjustedDelay(kind: decision.kind, delay: decision.delay),
                                        categoryIdentifier: decision.categoryIdentifier,
                                        userInfo: decision.userInfo,
                                        sleepReviewWindowStart: decision.sleepReviewWindowStart,
                                        sleepReviewWindowEnd: decision.sleepReviewWindowEnd)
        recordLedgerEntry(kind: decision.kind, action: "scheduled", detail: decision.identifier)
        let content = UNMutableNotificationContent()
        content.title = decision.title
        content.body = decision.body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: decision.delay,
                                                        repeats: false)
        if let categoryIdentifier = decision.categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        for (key, value) in decision.userInfo {
            content.userInfo[key] = value
        }
        let request = UNNotificationRequest(identifier: decision.identifier,
                                            content: content,
                                            trigger: trigger)
        try await center.add(request)
        if decision.kind == "sleep_review",
           let candidateID = decision.reason.split(separator: "_", maxSplits: 1).dropFirst().first {
            let id = String(candidateID)
            let defaults = UserDefaults.standard
            defaults.set(id, forKey: sleepReviewLastCandidateIDKey)
            defaults.set(Date().timeIntervalSince1970, forKey: sleepReviewCandidateScheduledAtPrefix + id)
            let countKey = sleepReviewCandidateScheduleCountPrefix + id
            defaults.set(defaults.integer(forKey: countKey) + 1, forKey: countKey)
            // Window-start debounce ledger (2026-08-01): record the end the
            // user was actually notified about, keyed by the window START,
            // bounded to the newest eight windows.
            if let windowStart = decision.sleepReviewWindowStart,
               let windowEnd = decision.sleepReviewWindowEnd {
                let stored = (defaults.dictionary(
                    forKey: sleepReviewNotifiedEndByStartKey
                ) as? [String: Double]) ?? [:]
                defaults.set(
                    AtriaSleepReviewNotificationDebounce.recordingNotifiedEnd(
                        start: windowStart,
                        end: windowEnd,
                        in: stored
                    ),
                    forKey: sleepReviewNotifiedEndByStartKey
                )
            }
        }
        if decision.kind == "workout_review",
           let candidateID = decision.reason.split(separator: "_", maxSplits: 1).dropFirst().first {
            UserDefaults.standard.set(String(candidateID), forKey: workoutReviewLastCandidateIDKey)
        }
        AtriaDebugLog("ATRIADBG notification_scheduled kind=%@ id=%@ title=%@ delay_s=%.1f reason=%@",
              decision.kind,
              decision.identifier,
              decision.title,
              decision.delay,
              decision.reason)
    }

    private static func requestProvisionalAuthorization(center: UNUserNotificationCenter) async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge, .provisional]) { granted, error in
                if let error {
                    AtriaDebugLog("ATRIADBG notification_auth_error error=%@", String(describing: error))
                }
                continuation.resume(returning: granted)
            }
        }
    }

    private static func notificationSettings(center: UNUserNotificationCenter) async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private static func logPendingRequests(center: UNUserNotificationCenter) async {
        let requests = await pendingRequests(center: center)
        let recovery = requests.filter { [Identifier.recovery, Identifier.legacyRecovery].contains($0.identifier) }.count
        let strain = requests.filter { [Identifier.strain, Identifier.legacyStrain].contains($0.identifier) }.count
        let sleepReview = requests.filter { [Identifier.sleepReview, Identifier.legacySleepReview].contains($0.identifier) }.count
        let workoutReview = requests.filter { [Identifier.workoutReview, Identifier.legacyWorkoutReview].contains($0.identifier) }.count
        let battery = requests.filter { [Identifier.battery, Identifier.legacyBattery].contains($0.identifier) }.count
        let bluetoothOff = requests.filter { [Identifier.bluetoothOff, Identifier.legacyBluetoothOff].contains($0.identifier) }.count
        let diagnostic = requests.filter { [Identifier.diagnostic, Identifier.legacyDiagnostic].contains($0.identifier) }.count
        let morningSummary = requests.filter { $0.identifier.hasPrefix(Identifier.morningSummaryPrefix) }.count
        let healthDeviation = requests.filter { $0.identifier == Identifier.healthDeviation }.count
        let known = recovery + strain + sleepReview + workoutReview + battery + bluetoothOff + diagnostic + morningSummary + healthDeviation
        AtriaDebugLog("ATRIADBG notification_pending total=%d recovery=%d strain=%d sleep_review=%d workout_review=%d battery=%d bluetooth_off=%d diagnostic=%d morning_summary=%d health_deviation=%d unknown=%d",
              requests.count,
              recovery,
              strain,
              sleepReview,
              workoutReview,
              battery,
              bluetoothOff,
              diagnostic,
              morningSummary,
              healthDeviation,
              max(0, requests.count - known))
    }

    private static func logMorningSummaryPendingProof(identifier: String,
                                                      center: UNUserNotificationCenter) async {
        let request = await pendingRequests(center: center)
            .first { $0.identifier == identifier }
        let deepLink = request?.content.userInfo["deepLink"] as? String ?? "missing"
        let category = request?.content.categoryIdentifier ?? "missing"
        AtriaDebugLog("ATRIADBG notification_pending_detail kind=morning_summary id=%@ present=%d category=%@ deepLink=%@",
                      identifier,
                      request == nil ? 0 : 1,
                      category,
                      deepLink)
    }

    private static func pendingRequests(center: UNUserNotificationCenter) async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }

    private static func launchDelay(arguments: [String]) -> TimeInterval {
        guard let index = arguments.firstIndex(of: "--atria-notification-delay"),
              arguments.indices.contains(arguments.index(after: index)),
              let delay = Double(arguments[arguments.index(after: index)]) else {
            return 8
        }
        return min(max(delay, 0), 120)
    }

    private static func statusName(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private static func localDayIdentifier(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0,
                      components.month ?? 0,
                      components.day ?? 0)
    }

    private struct NotificationDecision {
        let kind: String
        let identifier: String
        let title: String
        let body: String
        let reason: String
        let shouldSchedule: Bool
        let delay: TimeInterval
        var categoryIdentifier: String?
        var userInfo: [String: String] = [:]
        /// Sleep-review only (2026-08-01): the candidate window carried to the
        /// actual delivery site so the start-keyed debounce ledger records the
        /// end the user was genuinely told about — never a decision that a
        /// later budget/quiet-hours gate dropped.
        var sleepReviewWindowStart: Date?
        var sleepReviewWindowEnd: Date?
    }
}

/// User-specified sleep-review dedupe semantics (2026-08-01): the durable key
/// is the candidate WINDOW START, not the start-end candidate id. A growing
/// sleep episode keeps its start while the detector's end jitters by a few
/// minutes; each jitter minted a fresh start-end id and re-fired the review
/// notification (observed 04:50/04:56/04:57 triple-fire). Policy:
///  - first offer for a start always notifies;
///  - afterwards only a material end extension (>= 30 min beyond the end the
///    user was last notified about) re-notifies;
///  - end jitter below that stays silent;
///  - a separate later episode has a different start and is fully independent.
/// Pure and persisted as a bounded [startKey: lastNotifiedEnd-unix] ledger.
enum AtriaSleepReviewNotificationDebounce {
    static let minimumEndGrowth: TimeInterval = 30 * 60
    static let maximumTrackedStarts = 8

    /// Starts are keyed to the minute so sub-minute detector float noise
    /// cannot mint a fresh key for the same physical window.
    static func startKey(for start: Date) -> String {
        String(Int((start.timeIntervalSince1970 / 60).rounded(.down)))
    }

    static func shouldNotify(start: Date,
                             end: Date,
                             lastNotifiedEndByStart: [String: Double],
                             minimumGrowth: TimeInterval = minimumEndGrowth) -> Bool {
        guard let lastNotifiedEnd = lastNotifiedEndByStart[startKey(for: start)] else {
            return true
        }
        return end.timeIntervalSince1970 - lastNotifiedEnd >= minimumGrowth
    }

    /// Bounded ledger update after a real delivery: keeps the newest
    /// `maximumTrackedStarts` windows by start, and never lets a stale
    /// shorter end overwrite a longer one already notified for this start.
    static func recordingNotifiedEnd(start: Date,
                                     end: Date,
                                     in lastNotifiedEndByStart: [String: Double]) -> [String: Double] {
        var updated = lastNotifiedEndByStart
        let key = startKey(for: start)
        updated[key] = max(updated[key] ?? 0, end.timeIntervalSince1970)
        guard updated.count > maximumTrackedStarts else { return updated }
        let keep = Set(updated.keys
            .sorted { (Double($0) ?? 0) > (Double($1) ?? 0) }
            .prefix(maximumTrackedStarts))
        return updated.filter { keep.contains($0.key) }
    }
}

/// A one-item, thread-safe inbox bridges UIKit notification responses into the
/// SwiftUI tab shell. `NotificationCenter` alone is not sufficient here: its
/// delivery is transient, so a cold-launch response posted before Home mounts
/// disappears. Retaining the route until Home consumes it makes foreground,
/// background and cold-launch delivery follow the same idempotent path.
///
/// This deliberately does not require the main actor. UIKit waits for the
/// notification-response delegate to return, and a cold launch can otherwise
/// block on the first (and most expensive) SwiftUI mount before it records the
/// route. The notification used to wake an already-mounted Home view is posted
/// asynchronously on the main actor; the durable inbox mutation is immediate.
final class AtriaNotificationDeepLinkInbox: @unchecked Sendable {
    static let shared = AtriaNotificationDeepLinkInbox()
    static let didEnqueueNotification = NotificationDeliveryLogger.deepLinkNotification
    private static let retainedResponseKeyLimit = 64

    private let notificationCenter: NotificationCenter
    private let lock = NSLock()
    private var pendingURL: URL?
    // Notification response delegates can be replayed around scene restoration.
    // Remember more than only the last response: A, B, then a replay of A must
    // still be idempotent. The bounded FIFO keeps that protection for a whole
    // burst without turning a long-running process into an unbounded log.
    private var retainedResponseKeys: [String] = []
    private var retainedResponseKeySet: Set<String> = []

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    @discardableResult
    func enqueue(_ url: URL, responseKey: String) -> Bool {
        guard url.scheme?.lowercased() == "atria" else { return false }
        lock.lock()
        guard !retainedResponseKeySet.contains(responseKey) else {
            lock.unlock()
            return false
        }
        retainedResponseKeys.append(responseKey)
        retainedResponseKeySet.insert(responseKey)
        if retainedResponseKeys.count > Self.retainedResponseKeyLimit {
            let expiredKey = retainedResponseKeys.removeFirst()
            retainedResponseKeySet.remove(expiredKey)
        }
        pendingURL = url
        lock.unlock()

        Task { @MainActor [notificationCenter] in
            notificationCenter.post(name: Self.didEnqueueNotification, object: url)
        }
        return true
    }

    func consume() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let pendingURL else { return nil }
        self.pendingURL = nil
        return pendingURL
    }

    /// The route stays durable while UIKit/SwiftUI is still transitioning the
    /// scene. Consuming only once the scene is active avoids changing the root
    /// TabView in the launch transaction that previously produced a blank view.
    func consume(sceneIsActive: Bool) -> URL? {
        guard AtriaNotificationDeepLinkActivationPolicy.shouldConsume(
            sceneIsActive: sceneIsActive
        ) else { return nil }
        return consume()
    }
}

enum AtriaNotificationDeepLinkActivationPolicy {
    /// Navigation changes during the background-to-active handoff can race the
    /// root TabView's first transaction and leave a blank presentation. Keep
    /// the retained URL in the inbox until Home is actually interactive.
    static func shouldConsume(sceneIsActive: Bool) -> Bool {
        sceneIsActive
    }
}

final class NotificationDeliveryLogger: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDeliveryLogger()
    static let deepLinkNotification = Notification.Name("atria.notification.deepLink")

    private enum Identifier {
        static let recovery = "atria.recovery.ready"
        static let strain = "atria.strain.target"
        static let sleepReview = "atria.sleep.review"
        static let workoutReview = "atria.workout.review"
        static let battery = "atria.battery.low"
        static let bluetoothOff = "atria.bluetooth.off"
        static let healthDeviation = "atria.health.deviation"
        static let fitCheck = "atria.fitcheck.needed"
        static let diagnostic = "atria.diagnostic.delivery"
        static let legacyRecovery = "atria.recovery.ready"
        static let legacyStrain = "atria.strain.target"
        static let legacySleepReview = "atria.sleep.review"
        static let legacyWorkoutReview = "atria.workout.review"
        static let legacyBattery = "atria.battery.low"
        static let legacyBluetoothOff = "atria.bluetooth.off"
        static let legacyDiagnostic = "atria.diagnostic.delivery"
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let request = notification.request
        AtriaDebugLog("ATRIADBG notification_delivered kind=%@ id=%@ foreground=1",
              kind(for: request.identifier),
              request.identifier)
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        let deepLink = request.content.userInfo["deepLink"] as? String
        // "Log how you feel" on the morning summary is folded into the same
        // notification as an action button, not a second notification — the
        // default tap still goes to atria://overview (via `deepLink` above),
        // but this action overrides the destination to the journal.
        let resolvedDeepLink = Self.resolvedDeepLink(deepLink: deepLink,
                                                     actionIdentifier: response.actionIdentifier,
                                                     requestIdentifier: request.identifier)
        AtriaDebugLog("ATRIADBG notification_response kind=%@ id=%@ action=%@",
              kind(for: request.identifier),
              request.identifier,
              response.actionIdentifier)
        if let url = resolvedDeepLink {
            AtriaDebugLog("ATRIADBG notification_deeplink status=posted kind=%@ url=%@",
                          kind(for: request.identifier),
                          url.absoluteString)
            // Do not await the main actor here. UIKit keeps the notification
            // launch transaction open until this delegate returns, so waiting
            // behind the initial SwiftUI mount can present as a black screen.
            // `enqueue` is thread-safe and wakes Home on the main actor after
            // the route is already durable.
            _ = AtriaNotificationDeepLinkInbox.shared.enqueue(
                url,
                responseKey: "\(request.identifier)|\(response.notification.date.timeIntervalSince1970)|\(response.actionIdentifier)"
            )
        }
    }

    static func resolvedDeepLink(deepLink: String?,
                                 actionIdentifier: String,
                                 requestIdentifier: String = "") -> URL? {
        let isJournalReminder = requestIdentifier.hasPrefix("atria.morningJournal.")
            || requestIdentifier.hasPrefix("atria.eveningJournal.")
        let destination: String?
        if actionIdentifier == "atria.action.logJournal" || isJournalReminder {
            // Identifier fallback keeps already-pending reminders actionable
            // even if an older installed build omitted or malformed userInfo.
            destination = "atria://journal"
        } else {
            destination = deepLink
        }
        guard let destination,
              let url = URL(string: destination),
              url.scheme?.lowercased() == "atria" else { return nil }
        return url
    }

    private func kind(for identifier: String) -> String {
        switch identifier {
        case Identifier.recovery, Identifier.legacyRecovery: return "recovery"
        case Identifier.strain, Identifier.legacyStrain: return "strain"
        case Identifier.sleepReview, Identifier.legacySleepReview: return "sleep_review"
        case Identifier.workoutReview, Identifier.legacyWorkoutReview: return "workout_review"
        case Identifier.battery, Identifier.legacyBattery: return "battery"
        case Identifier.bluetoothOff, Identifier.legacyBluetoothOff: return "bluetooth_off"
        case Identifier.healthDeviation: return "health_deviation"
        case Identifier.fitCheck: return "fit_check"
        case Identifier.diagnostic, Identifier.legacyDiagnostic: return "diagnostic"
        default: return "unknown"
        }
    }
}
