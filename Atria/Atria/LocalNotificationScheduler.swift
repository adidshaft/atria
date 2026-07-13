import Foundation
import UserNotifications

@MainActor
enum LocalNotificationScheduler {
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
    private static let workoutReviewLastCandidateIDKey = "atria.notification.workoutReview.lastCandidateID"
    private static let workoutReviewDismissedIDKey = "atria.workoutReview.dismissedID"
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
        guard AtriaNotificationSettings.load().allows(kind: "morning_summary") else {
            AtriaDebugLog("ATRIADBG notification_schedule status=skipped_toggle kind=morning_checkin")
            return
        }
        // 14-day (not 7-day) re-engage window: a journal reminder must survive a
        // typical lapse to help rebuild the habit — a 7-day gate drops it exactly
        // when the user has stopped and most needs the nudge (user 2026-07-08 #1/#7).
        guard let lastJournalActivity,
              now.timeIntervalSince(lastJournalActivity) <= 14 * 24 * 60 * 60 else {
            AtriaDebugLog("ATRIADBG notification_skip kind=morning_checkin reason=journal_inactive")
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
            } catch {
                AtriaDebugLog("ATRIADBG notification_error kind=morning_checkin error=%@",
                              String(describing: error))
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
        let productionCadence = !debugMetricRequest && !debugDiagnosticRequest && !debugHealthDeviationRequest
        let includeSleepReviewDecisions = productionCadence || debugMetricRequest
        let includeWorkoutReviewDecisions = productionCadence || debugMetricRequest
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
                let current = AtriaBLEManager.cachedBattery(maxAge: 10 * 60)
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
            decisions.append(makeSleepReviewDecision(store: store))
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
        let validatedHRV = store.latestReferenceValidatedHRV
        let latestSleep = store.sleepHistorySnapshot.latestMainSleep
        let recovery = Metrics.recoveryV2(hrvSnapshot: ble.recoveryHRVSnapshot,
                                          fallbackRMSSD: validatedHRV ?? store.latestLocalRMSSD,
                                          restingNow: ble.restingHR ?? store.sessions.first?.restingStable,
                                          baseline: store.baseline,
                                          hrvReferenceValidated: validatedHRV != nil,
                                          sleepEfficiency: latestSleep?.sleepEfficiency,
                                          sleepDurationHours: latestSleep?.durationHours,
                                          respiratoryRate: latestSleep?.respiratoryRate,
                                          respiratoryBaseline: store.sleepHistorySnapshot.respiratoryBaselineStats)
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
        let calendar = Calendar.current
        let now = Date()
        let physiologicalCycle = AtriaPhysiologicalCycle.current(now: now,
                                                                 confirmedSleeps: store.confirmedSleeps,
                                                                 calendar: calendar)
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
            attributedRecovery = 1
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

    private static func makeSleepReviewDecision(store: SessionStore) -> NotificationDecision {
        let snapshot = store.sleepHistorySnapshot
        let defaults = UserDefaults.standard
        let latestReviewNight = store.latestSleepReviewNightForUI(rest: store.baseline.restingInt ?? 60,
                                                                  source: "notification_sleep_review")

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
            userInfo: ["deepLink": "atria://sleep-review"]
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
            now: now
        )
        if cached.usable {
            let liveMatchesAcceptedProjection = liveLevel == cached.level
            let chargeStatus = liveMatchesAcceptedProjection && liveChargeStatus != .levelOnly
                ? liveChargeStatus
                : cached.chargeStatus
            let source = liveMatchesAcceptedProjection ? "live_2A19_fresh" : cached.source
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
                                        userInfo: decision.userInfo)
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
        let resolvedDeepLink = response.actionIdentifier == "atria.action.logJournal" ? "atria://journal" : deepLink
        AtriaDebugLog("ATRIADBG notification_response kind=%@ id=%@ action=%@",
              kind(for: request.identifier),
              request.identifier,
              response.actionIdentifier)
        if let deepLink = resolvedDeepLink,
           let url = URL(string: deepLink) {
            AtriaDebugLog("ATRIADBG notification_deeplink status=posted kind=%@ url=%@",
                          kind(for: request.identifier),
                          deepLink)
            await MainActor.run {
                NotificationCenter.default.post(name: Self.deepLinkNotification, object: url)
            }
        }
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
