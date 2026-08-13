import Foundation
import UIKit
import UserNotifications

/// Event-driven notification scheduling added 2026-08-13, extending the
/// existing `LocalNotificationScheduler` (permission flow, attention budget,
/// quiet hours and the per-kind user toggles all stay in one place).
///
/// Everything here only OBSERVES already-published state — the pending
/// same-day sleep choice, the learned sleep window, the durable drain
/// frontier, the terminal park marker — and never drives BLE, drain, or sleep
/// truth logic. Each notification carries a stable event key recorded in
/// `AtriaNotificationEventKeyStore`, so no physical event ever notifies twice
/// across relaunches, BGTask replays, or scene churn.
extension LocalNotificationScheduler {
    enum EventIdentifier {
        static let secondSleepPrimary = "atria.sleep.secondPrimary"
        static let bedtimeWindDownPrefix = "atria.bedtime.windDown."
        static let catchUpComplete = "atria.sync.catchUpComplete"
        static let parkedInterval = "atria.sync.parkedInterval"
    }

    static let catchUpMarkerFrontierKey = "atria.notification.catchup.markerFrontierUnix.v1"
    private static let bedtimeScheduledDayKey = "atria.notification.bedtime.scheduledDay"

    // MARK: - Pass entry points

    /// One observational pass over published event state. Called from the
    /// scene-foreground path and the background review pass — the same
    /// cadence the review notifications already use.
    static func runEventObservationPass(store: SessionStore,
                                        now: Date = Date(),
                                        calendar: Calendar = .current) {
        let applicationIsActive = UIApplication.shared.applicationState == .active
        updateSameDayPrimarySleepPrompt(
            choice: store.pendingSameDayMainSleepChoiceForUI,
            applicationIsActive: applicationIsActive,
            calendar: calendar
        )
        scheduleBedtimeWindDownIfNeeded(
            sleepDebtHours: store.sleepHistorySnapshot.sleepBudgetDebtHours(
                baseNeedHours: SessionStore.configuredSleepBaseNeedHours()
            ),
            now: now,
            calendar: calendar
        )
        runSyncEventObservation(applicationIsActive: applicationIsActive, now: now)
    }

    // MARK: - Same-day second sleep ("which is your main sleep?")

    /// Convenience for call sites outside this file (SessionStore's pending-
    /// choice refresh): reads the application state itself so callers need no
    /// UIKit dependency.
    static func refreshSameDayPrimarySleepPrompt(choice: AtriaSameDayMainSleepChoice?) {
        updateSameDayPrimarySleepPrompt(
            choice: choice,
            applicationIsActive: UIApplication.shared.applicationState == .active
        )
    }

    /// Notification entry point for the existing in-app prompt sheet. When the
    /// app is active the sheet presents itself (Home observes the published
    /// choice), so the notification only covers detection moments the user is
    /// not looking at — and it cancels itself the moment the day is resolved.
    static func updateSameDayPrimarySleepPrompt(choice: AtriaSameDayMainSleepChoice?,
                                                applicationIsActive: Bool,
                                                calendar: Calendar = .current) {
        guard let choice else {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(
                withIdentifiers: [EventIdentifier.secondSleepPrimary]
            )
            return
        }
        guard !applicationIsActive else { return }
        let dayKey = eventDayIdentifier(for: choice.morningDay, calendar: calendar)
        let content = AtriaEventNotificationContent.secondSleepPrompt(
            dayText: choice.morningDay.formatted(date: .abbreviated, time: .omitted)
        )
        scheduleEventNotification(category: .secondSleepPrimary,
                                  identifier: EventIdentifier.secondSleepPrimary,
                                  title: content.title,
                                  body: content.body,
                                  eventKey: "secondSleep.\(dayKey)",
                                  delay: 5,
                                  deepLink: "atria://overview")
    }

    // MARK: - Bedtime wind-down (opt-in, quiet)

    /// Schedules the quiet wind-down reminder for the next learned pre-bedtime
    /// moment. Timing comes ONLY from the user's own learned sleep window; the
    /// debt clause comes only from the same computed sleep-debt the sleep
    /// planner shows. At most one schedule per target day.
    static func scheduleBedtimeWindDownIfNeeded(sleepDebtHours: Double?,
                                                now: Date = Date(),
                                                calendar: Calendar = .current) {
        guard AtriaNotificationSettings.load().allows(kind: AtriaNotificationCategory.bedtimeWindDown.kind) else {
            return
        }
        let windowStart = UserDefaults.standard.integer(
            forKey: AtriaBLEManager.DutyCycleDefaults.sleepWindowStartMin
        )
        guard let minutes = AtriaBedtimeWindDownPolicy.reminderMinutes(
            sleepWindowStartMinutes: windowStart
        ) else {
            AtriaDebugLog("ATRIADBG notification_skip kind=bedtime_reminder reason=sleep_window_unlearned")
            return
        }
        let target = AtriaBedtimeWindDownPolicy.nextTarget(now: now,
                                                           reminderMinutes: minutes,
                                                           calendar: calendar)
        let targetDay = eventDayIdentifier(for: target, calendar: calendar)
        guard UserDefaults.standard.string(forKey: bedtimeScheduledDayKey) != targetDay else {
            return
        }
        let content = AtriaBedtimeWindDownPolicy.content(sleepDebtHours: sleepDebtHours)
        scheduleEventNotification(category: .bedtimeWindDown,
                                  identifier: EventIdentifier.bedtimeWindDownPrefix + targetDay,
                                  title: content.title,
                                  body: content.body,
                                  eventKey: "bedtime.\(targetDay)",
                                  delay: target.timeIntervalSince(now),
                                  deepLink: "atria://overview",
                                  respectQuietHours: false,
                                  onScheduled: {
                                      UserDefaults.standard.set(targetDay,
                                                                forKey: bedtimeScheduledDayKey)
                                  })
    }

    // MARK: - Sync events (catch-up complete, parked interval)

    /// Observes the durable drain frontier and the terminal sequence-gap park
    /// marker. Both notifications stay silent while the app is active — the
    /// Home banner owns those states in the foreground.
    static func runSyncEventObservation(applicationIsActive: Bool,
                                        now: Date = Date(),
                                        defaults: UserDefaults = .standard) {
        let frontier = defaults.object(
            forKey: AtriaBLEManager.OfflineSyncDefaults.drainedThroughUnix
        ) as? Double
        let marker = defaults.object(forKey: catchUpMarkerFrontierKey) as? Double
        switch AtriaCatchUpCompletionPolicy.passAction(markerFrontierUnix: marker,
                                                       frontierUnix: frontier,
                                                       nowUnix: now.timeIntervalSince1970) {
        case .none:
            break
        case .recordMarker(let frontierUnix):
            defaults.set(frontierUnix, forKey: catchUpMarkerFrontierKey)
        case .clearMarker:
            defaults.removeObject(forKey: catchUpMarkerFrontierKey)
        case .notify(_, let eventKey):
            defaults.removeObject(forKey: catchUpMarkerFrontierKey)
            if !applicationIsActive {
                let content = AtriaEventNotificationContent.catchUpComplete()
                scheduleEventNotification(category: .catchUpComplete,
                                          identifier: EventIdentifier.catchUpComplete,
                                          title: content.title,
                                          body: content.body,
                                          eventKey: eventKey,
                                          delay: 3,
                                          deepLink: "atria://overview")
            }
        }

        if let parkedAt = defaults.object(
            forKey: AtriaBLEManager.OfflineSyncDefaults.sequenceGapParkedAt
        ) as? Double {
            guard !applicationIsActive else { return }
            let content = AtriaEventNotificationContent.parkedInterval()
            scheduleEventNotification(category: .parkedInterval,
                                      identifier: EventIdentifier.parkedInterval,
                                      title: content.title,
                                      body: content.body,
                                      eventKey: AtriaEventNotificationContent
                                          .parkedIntervalEventKey(parkedAtUnix: parkedAt),
                                      delay: 3,
                                      deepLink: "atria://overview")
        } else {
            // The park resolved (fresh evidence unparked it, or the user
            // repaired the gap): a still-pending notification is stale truth.
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: [EventIdentifier.parkedInterval]
            )
        }
    }

    // MARK: - Authorization escalation

    /// Provisional authorization is requested silently by every scheduling
    /// path. Escalating to a full (alert-banner) prompt happens ONLY here —
    /// when the user explicitly enables notifications in Atria's own settings.
    static func requestFullAuthorizationForExplicitEnable() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await eventNotificationSettings(center: center)
            guard settings.authorizationStatus == .notDetermined ||
                    settings.authorizationStatus == .provisional else { return }
            let granted = await withCheckedContinuation { continuation in
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        AtriaDebugLog("ATRIADBG notification_auth_error source=explicit_enable error=%@",
                                      String(describing: error))
                    }
                    continuation.resume(returning: granted)
                }
            }
            AtriaDebugLog("ATRIADBG notification_auth source=explicit_enable granted=%d",
                          granted ? 1 : 0)
        }
    }

    // MARK: - Shared plumbing

    /// One delivery path for every event notification: user toggle, event-key
    /// dedup, provisional authorization, quiet hours, the shared attention
    /// budget, then a single `UNNotificationRequest` whose identifier replaces
    /// any stale pending copy of itself.
    private static func scheduleEventNotification(category: AtriaNotificationCategory,
                                                  identifier: String,
                                                  title: String,
                                                  body: String,
                                                  eventKey: String,
                                                  delay: TimeInterval,
                                                  deepLink: String?,
                                                  respectQuietHours: Bool = true,
                                                  now: Date = Date(),
                                                  onScheduled: (() -> Void)? = nil) {
        let kind = category.kind
        guard AtriaNotificationSettings.load().allows(kind: kind) else {
            AtriaDebugLog("ATRIADBG notification_skip kind=%@ reason=user_disabled", kind)
            return
        }
        guard !AtriaNotificationEventKeyStore.hasNotified(eventKey) else {
            AtriaDebugLog("ATRIADBG notification_skip kind=%@ reason=event_already_notified key=%@",
                          kind, eventKey)
            return
        }
        Task {
            let center = UNUserNotificationCenter.current()
            _ = await eventRequestProvisionalAuthorization(center: center)
            let settings = await eventNotificationSettings(center: center)
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional ||
                    settings.authorizationStatus == .ephemeral else {
                AtriaDebugLog("ATRIADBG notification_schedule status=blocked reason=authorization kind=%@",
                              kind)
                return
            }
            // Re-check under the same in-flight ordering as the checks above:
            // two overlapping passes can both pass the synchronous gate.
            guard !AtriaNotificationEventKeyStore.hasNotified(eventKey) else { return }
            let adjustedDelay = respectQuietHours
                ? quietHoursAdjustedDelay(kind: kind, delay: delay, now: now)
                : delay
            guard consumeAttentionBudget(kind: kind, now: now) else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = category.deliversQuietly ? nil : .default
            if let deepLink {
                content.userInfo["deepLink"] = deepLink
            }
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            do {
                try await center.add(UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(
                        timeInterval: max(adjustedDelay, 1),
                        repeats: false
                    )
                ))
                AtriaNotificationEventKeyStore.recordNotified(eventKey)
                onScheduled?()
                AtriaDebugLog("ATRIADBG notification_scheduled kind=%@ id=%@ title=%@ delay_s=%.1f event_key=%@",
                              kind, identifier, title, max(adjustedDelay, 1), eventKey)
            } catch {
                AtriaDebugLog("ATRIADBG notification_error kind=%@ error=%@",
                              kind, String(describing: error))
            }
        }
    }

    private static func eventRequestProvisionalAuthorization(
        center: UNUserNotificationCenter
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge, .provisional]) { granted, error in
                if let error {
                    AtriaDebugLog("ATRIADBG notification_auth_error error=%@",
                                  String(describing: error))
                }
                continuation.resume(returning: granted)
            }
        }
    }

    private static func eventNotificationSettings(
        center: UNUserNotificationCenter
    ) async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private static func eventDayIdentifier(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0,
                      components.month ?? 0,
                      components.day ?? 0)
    }
}
