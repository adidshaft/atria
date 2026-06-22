import Foundation
import UserNotifications

@MainActor
enum LocalNotificationScheduler {
    private enum Identifier {
        static let recovery = "atria.recovery.ready"
        static let strain = "atria.strain.target"
        static let battery = "atria.battery.low"
        static let diagnostic = "atria.diagnostic.delivery"
        static let legacyRecovery = "whoop.recovery.ready"
        static let legacyStrain = "whoop.strain.target"
        static let legacyBattery = "whoop.battery.low"
        static let legacyDiagnostic = "whoop.diagnostic.delivery"

        static let active = [recovery, strain, battery, diagnostic]
        static let legacy = [legacyRecovery, legacyStrain, legacyBattery, legacyDiagnostic]
        static let removable = active + legacy
    }

    static func scheduleFromLaunchIfRequested(store: SessionStore,
                                              ble: WhoopBLEManager,
                                              arguments: [String] = ProcessInfo.processInfo.arguments) {
        configureDeliveryLogger()
        let debugMetricRequest = arguments.contains("--whoop-schedule-notifications")
        let debugDiagnosticRequest = arguments.contains("--whoop-test-notification")
        let productionCadence = !debugMetricRequest && !debugDiagnosticRequest
        let delay = launchDelay(arguments: arguments)
        WHOOPDebugLog("WHOOPDBG notification_schedule requested=1 mode=%@ delay_s=%.1f",
              productionCadence ? "production" : "debug",
              delay)

        Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await schedule(store: store,
                           ble: ble,
                           includeMetricDecisions: productionCadence || debugMetricRequest,
                           includeDiagnostic: debugDiagnosticRequest,
                           productionCadence: productionCadence)
        }
    }

    private static func configureDeliveryLogger() {
        UNUserNotificationCenter.current().delegate = NotificationDeliveryLogger.shared
    }

    private static func schedule(store: SessionStore,
                                 ble: WhoopBLEManager,
                                 includeMetricDecisions: Bool,
                                 includeDiagnostic: Bool,
                                 productionCadence: Bool) async {
        let center = UNUserNotificationCenter.current()
        let granted = await requestProvisionalAuthorization(center: center)
        let settings = await notificationSettings(center: center)
        let status = statusName(settings.authorizationStatus)
        WHOOPDebugLog("WHOOPDBG notification_auth status=%@ granted=%d", status, granted ? 1 : 0)
        WHOOPDebugLog("WHOOPDBG notification_readiness status=%@ authorization=%@ metric_decisions=%d diagnostic=%d production_cadence=%d action=%@",
              productionCadence ? "production_cadence" : "debug_trigger",
              status,
              includeMetricDecisions ? 1 : 0,
              includeDiagnostic ? 1 : 0,
              productionCadence ? 1 : 0,
              productionCadence ? "monitor_confidence_gated_metric_triggers" : "debug_delivery_probe")

        guard settings.authorizationStatus == .authorized ||
                settings.authorizationStatus == .provisional ||
                settings.authorizationStatus == .ephemeral else {
            WHOOPDebugLog("WHOOPDBG notification_schedule status=blocked reason=authorization_%@", status)
            await logPendingRequests(center: center)
            return
        }

        center.removePendingNotificationRequests(withIdentifiers: Identifier.removable)

        var decisions = includeMetricDecisions ? makeDecisions(store: store, ble: ble) : []
        if includeDiagnostic {
            decisions.append(NotificationDecision(
                kind: "diagnostic",
                identifier: Identifier.diagnostic,
                title: "Atria diagnostic",
                body: "Local notification delivery test.",
                reason: "debug_delivery_probe",
                shouldSchedule: true,
                delay: 3
            ))
        }
        var scheduled = 0
        for decision in decisions where decision.shouldSchedule {
            do {
                try await add(decision: decision, center: center)
                scheduled += 1
            } catch {
                WHOOPDebugLog("WHOOPDBG notification_error kind=%@ error=%@",
                      decision.kind,
                      String(describing: error))
            }
        }
        for decision in decisions where !decision.shouldSchedule {
            WHOOPDebugLog("WHOOPDBG notification_skip kind=%@ reason=%@",
                  decision.kind,
                  decision.reason)
        }
        WHOOPDebugLog("WHOOPDBG notification_schedule status=scheduled count=%d", scheduled)
        await logPendingRequests(center: center)
    }

    private static func makeDecisions(store: SessionStore,
                                      ble: WhoopBLEManager) -> [NotificationDecision] {
        let recovery = Metrics.recoveryV2(hrvSnapshot: ble.hrvSnapshot,
                                          fallbackRMSSD: store.latestReferenceValidatedHRV,
                                          restingNow: ble.restingHR ?? store.sessions.first?.restingStable,
                                          baseline: store.baseline)
        let recoveryDecision: NotificationDecision
        if let percent = recovery.percent {
            recoveryDecision = NotificationDecision(
                kind: "recovery",
                identifier: Identifier.recovery,
                title: "Recovery ready",
                body: "Recovery \(percent)% (\(recovery.confidence.rawValue)): \(recovery.detail)",
                reason: "percent_\(percent)_confidence_\(recovery.confidence.rawValue)",
                shouldSchedule: true,
                delay: 5
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
        let savedTRIMP = store.todayTRIMP(rest: rest, max: store.profile.maxHR)
        let liveTRIMP = ble.session.first.map { first in
            Metrics.trimp(ble.session.map { (t: $0.t.timeIntervalSince(first.t), bpm: $0.bpm) },
                          rest: rest,
                          max: store.profile.maxHR)
        } ?? 0
        let strain = Metrics.strain(fromTRIMP: savedTRIMP + liveTRIMP)
        let guide = Coach.guide(recovery: recovery.percent, strain: strain)
        let strainDecision: NotificationDecision
        if recovery.percent == nil {
            strainDecision = NotificationDecision(
                kind: "strain",
                identifier: Identifier.strain,
                title: "",
                body: "",
                reason: "recovery_learning_\(recovery.confidence.rawValue)",
                shouldSchedule: false,
                delay: 0
            )
        } else if let target = guide.target, strain >= target {
            strainDecision = NotificationDecision(
                kind: "strain",
                identifier: Identifier.strain,
                title: "Strain target reached",
                body: String(format: "Day strain %.1f reached today's %.1f target.", strain, target),
                reason: String(format: "strain_%.1f_target_%.1f", strain, target),
                shouldSchedule: true,
                delay: 7
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

        let battery = batterySnapshot(liveLevel: ble.batteryLevel)
        WHOOPDebugLog("WHOOPDBG notification_battery_decision level=%d source=%@ age_s=%.0f usable=%d threshold=20",
              battery.level,
              battery.source,
              battery.age,
              battery.usable ? 1 : 0)
        let batteryDecision: NotificationDecision
        if battery.usable && battery.level <= 20 {
            batteryDecision = NotificationDecision(
                kind: "battery",
                identifier: Identifier.battery,
                title: "Strap battery low",
                body: "Strap battery is \(battery.level)%.",
                reason: "battery_\(battery.level)_source_\(battery.source)",
                shouldSchedule: true,
                delay: 9
            )
        } else {
            let reason = battery.usable
                ? "battery_\(battery.level)_not_low_source_\(battery.source)"
                : "battery_learning_source_\(battery.source)"
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

        return [recoveryDecision, strainDecision, batteryDecision]
    }

    private static func batterySnapshot(liveLevel: Int) -> (level: Int, source: String, age: TimeInterval, usable: Bool) {
        if liveLevel >= 0 {
            return (liveLevel, "live_2A19", 0, true)
        }
        let cached = WhoopBLEManager.cachedBattery()
        if cached.usable {
            return cached
        }
        return (cached.level, cached.source == "none" ? "learning" : "\(cached.source)_stale", cached.age, false)
    }

    private static func add(decision: NotificationDecision,
                            center: UNUserNotificationCenter) async throws {
        let content = UNMutableNotificationContent()
        content.title = decision.title
        content.body = decision.body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: decision.delay,
                                                        repeats: false)
        let request = UNNotificationRequest(identifier: decision.identifier,
                                            content: content,
                                            trigger: trigger)
        try await center.add(request)
        WHOOPDebugLog("WHOOPDBG notification_scheduled kind=%@ id=%@ title=%@ delay_s=%.1f reason=%@",
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
                    WHOOPDebugLog("WHOOPDBG notification_auth_error error=%@", String(describing: error))
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
        let battery = requests.filter { [Identifier.battery, Identifier.legacyBattery].contains($0.identifier) }.count
        let diagnostic = requests.filter { [Identifier.diagnostic, Identifier.legacyDiagnostic].contains($0.identifier) }.count
        let known = recovery + strain + battery + diagnostic
        WHOOPDebugLog("WHOOPDBG notification_pending total=%d recovery=%d strain=%d battery=%d diagnostic=%d unknown=%d",
              requests.count,
              recovery,
              strain,
              battery,
              diagnostic,
              max(0, requests.count - known))
    }

    private static func pendingRequests(center: UNUserNotificationCenter) async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }

    private static func launchDelay(arguments: [String]) -> TimeInterval {
        guard let index = arguments.firstIndex(of: "--whoop-notification-delay"),
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

    private struct NotificationDecision {
        let kind: String
        let identifier: String
        let title: String
        let body: String
        let reason: String
        let shouldSchedule: Bool
        let delay: TimeInterval
    }
}

private final class NotificationDeliveryLogger: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDeliveryLogger()

    private enum Identifier {
        static let recovery = "atria.recovery.ready"
        static let strain = "atria.strain.target"
        static let battery = "atria.battery.low"
        static let diagnostic = "atria.diagnostic.delivery"
        static let legacyRecovery = "whoop.recovery.ready"
        static let legacyStrain = "whoop.strain.target"
        static let legacyBattery = "whoop.battery.low"
        static let legacyDiagnostic = "whoop.diagnostic.delivery"
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let request = notification.request
        WHOOPDebugLog("WHOOPDBG notification_delivered kind=%@ id=%@ foreground=1",
              kind(for: request.identifier),
              request.identifier)
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        WHOOPDebugLog("WHOOPDBG notification_response kind=%@ id=%@ action=%@",
              kind(for: request.identifier),
              request.identifier,
              response.actionIdentifier)
    }

    private func kind(for identifier: String) -> String {
        switch identifier {
        case Identifier.recovery, Identifier.legacyRecovery: return "recovery"
        case Identifier.strain, Identifier.legacyStrain: return "strain"
        case Identifier.battery, Identifier.legacyBattery: return "battery"
        case Identifier.diagnostic, Identifier.legacyDiagnostic: return "diagnostic"
        default: return "unknown"
        }
    }
}
