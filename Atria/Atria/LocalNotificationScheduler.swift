import Foundation
import UserNotifications

@MainActor
enum LocalNotificationScheduler {
    private static let actionableBatteryThreshold = 20
    private static let actionableDiagnosisCooldown: TimeInterval = 6 * 60 * 60
    private static let actionableDiagnosisLastScheduledPrefix = "atria.notification.actionableDiagnosis.lastScheduled."

    private enum Identifier {
        static let recovery = "atria.recovery.ready"
        static let strain = "atria.strain.target"
        static let battery = "atria.battery.low"
        static let bluetoothOff = "atria.bluetooth.off"
        static let diagnostic = "atria.diagnostic.delivery"
        static let legacyRecovery = "atria.recovery.ready"
        static let legacyStrain = "atria.strain.target"
        static let legacyBattery = "atria.battery.low"
        static let legacyBluetoothOff = "atria.bluetooth.off"
        static let legacyDiagnostic = "atria.diagnostic.delivery"

        static let active = [recovery, strain, battery, bluetoothOff]
        static let diagnosticOnly = [diagnostic]
        static let legacy = [legacyRecovery, legacyStrain, legacyBattery, legacyBluetoothOff, legacyDiagnostic]
        static let removable = active + diagnosticOnly + legacy
    }

    static func scheduleFromLaunchIfRequested(store: SessionStore,
                                              ble: AtriaBLEManager,
                                              arguments: [String] = ProcessInfo.processInfo.arguments) {
        configureDeliveryLogger()
        let debugMetricRequest = arguments.contains("--atria-schedule-notifications")
        let debugDiagnosticRequest = arguments.contains("--atria-test-notification")
        let productionCadence = !debugMetricRequest && !debugDiagnosticRequest
        let delay = launchDelay(arguments: arguments)
        AtriaDebugLog("ATRIADBG notification_schedule requested=1 mode=%@ delay_s=%.1f",
              productionCadence ? "production" : "debug",
              delay)

        Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await schedule(store: store,
                           ble: ble,
                           includeMetricDecisions: debugMetricRequest,
                           includeActionableConnectionDecisions: productionCadence || debugMetricRequest,
                           includeDiagnostic: debugDiagnosticRequest,
                           productionCadence: productionCadence)
        }
    }

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
            let cooldownKey = actionableDiagnosisLastScheduledPrefix + decision.identifier
            let last = defaults.double(forKey: cooldownKey)
            if last > 0, now.timeIntervalSince(Date(timeIntervalSince1970: last)) < actionableDiagnosisCooldown {
                AtriaDebugLog("ATRIADBG notification_skip kind=%@ reason=cooldown", decision.kind)
                return
            }

            do {
                try await add(decision: decision, center: center)
                defaults.set(now.timeIntervalSince1970, forKey: cooldownKey)
            } catch {
                AtriaDebugLog("ATRIADBG notification_error kind=%@ error=%@",
                              decision.kind,
                              String(describing: error))
            }
        }
    }

    static func cancelActionableConnectionDiagnosis(title: String? = nil, reason: String) {
        let identifiers: [String]
        if let title,
           let decision = actionableConnectionDiagnosisDecision(title: title,
                                                               body: "",
                                                               reason: reason) {
            identifiers = [decision.identifier]
        } else {
            identifiers = [Identifier.battery, Identifier.bluetoothOff]
        }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        AtriaDebugLog("ATRIADBG notification_cancel kind=actionable_connection reason=%@ identifiers=%@",
                      reason,
                      identifiers.joined(separator: ","))
    }

    private static func configureDeliveryLogger() {
        UNUserNotificationCenter.current().delegate = NotificationDeliveryLogger.shared
    }

    private static func schedule(store: SessionStore,
                                 ble: AtriaBLEManager,
                                 includeMetricDecisions: Bool,
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
        var scheduled = 0
        for decision in decisions where decision.shouldSchedule {
            do {
                try await add(decision: decision, center: center)
                scheduled += 1
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
        let latestSleep = store.sleepHistorySnapshot.latest
        let recovery = Metrics.recoveryV2(hrvSnapshot: ble.hrvSnapshot,
                                          fallbackRMSSD: validatedHRV ?? store.latestLocalRMSSD,
                                          restingNow: ble.restingHR ?? store.sessions.first?.restingStable,
                                          baseline: store.baseline,
                                          hrvReferenceValidated: validatedHRV != nil,
                                          sleepEfficiency: latestSleep?.sleepEfficiency,
                                          sleepDurationHours: latestSleep?.durationHours)
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

        return [recoveryDecision, strainDecision]
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
        let effectiveChargeStatus = battery.chargeStatus
        let batteryIsCharging = effectiveChargeStatus == .charging || effectiveChargeStatus == .full
        AtriaDebugLog("ATRIADBG notification_battery_decision level=%d source=%@ age_s=%.0f usable=%d threshold=%d charge=%@",
              battery.level,
              battery.source,
              battery.age,
              battery.usable ? 1 : 0,
              Self.actionableBatteryThreshold,
              effectiveChargeStatus.rawValue)
        let batteryDecision: NotificationDecision
        if battery.usable && battery.level <= Self.actionableBatteryThreshold && !batteryIsCharging {
            batteryDecision = NotificationDecision(
                kind: "battery",
                identifier: Identifier.battery,
                title: "Strap battery low",
                body: "Charge your strap before a workout or overnight wear. Battery is \(battery.level)%.",
                reason: "battery_\(battery.level)_source_\(battery.source)",
                shouldSchedule: true,
                delay: 9
            )
        } else {
            let reason: String
            if battery.usable && batteryIsCharging {
                reason = "battery_\(battery.level)_charging_\(effectiveChargeStatus.rawValue)_source_\(battery.source)"
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

    private static func actionableConnectionDiagnosisDecision(title: String,
                                                              body: String,
                                                              reason: String) -> NotificationDecision? {
        switch title {
        case "Strap battery low":
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
        default:
            return nil
        }
    }

    private static func batterySnapshot(liveLevel: Int,
        liveChargeStatus: AtriaBLEManager.BatteryChargeStatus) -> (level: Int, source: String, age: TimeInterval, chargeStatus: AtriaBLEManager.BatteryChargeStatus, usable: Bool) {
        if liveLevel >= 0 {
            let cached = AtriaBLEManager.cachedBattery(maxAge: 10 * 60)
            let chargeStatus = liveChargeStatus == .levelOnly && cached.usable ? cached.chargeStatus : liveChargeStatus
            let source = chargeStatus == liveChargeStatus ? "live_2A19" : "live_2A19_cached_charge"
            return (liveLevel, source, 0, chargeStatus, true)
        }
        let cached = AtriaBLEManager.cachedBattery()
        if cached.usable {
            return (cached.level, cached.source, cached.age, cached.chargeStatus, true)
        }
        return (cached.level, cached.source == "none" ? "learning" : "\(cached.source)_stale", cached.age, cached.chargeStatus, false)
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
        let battery = requests.filter { [Identifier.battery, Identifier.legacyBattery].contains($0.identifier) }.count
        let bluetoothOff = requests.filter { [Identifier.bluetoothOff, Identifier.legacyBluetoothOff].contains($0.identifier) }.count
        let diagnostic = requests.filter { [Identifier.diagnostic, Identifier.legacyDiagnostic].contains($0.identifier) }.count
        let known = recovery + strain + battery + bluetoothOff + diagnostic
        AtriaDebugLog("ATRIADBG notification_pending total=%d recovery=%d strain=%d battery=%d bluetooth_off=%d diagnostic=%d unknown=%d",
              requests.count,
              recovery,
              strain,
              battery,
              bluetoothOff,
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
        static let bluetoothOff = "atria.bluetooth.off"
        static let diagnostic = "atria.diagnostic.delivery"
        static let legacyRecovery = "atria.recovery.ready"
        static let legacyStrain = "atria.strain.target"
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
        AtriaDebugLog("ATRIADBG notification_response kind=%@ id=%@ action=%@",
              kind(for: request.identifier),
              request.identifier,
              response.actionIdentifier)
    }

    private func kind(for identifier: String) -> String {
        switch identifier {
        case Identifier.recovery, Identifier.legacyRecovery: return "recovery"
        case Identifier.strain, Identifier.legacyStrain: return "strain"
        case Identifier.battery, Identifier.legacyBattery: return "battery"
        case Identifier.bluetoothOff, Identifier.legacyBluetoothOff: return "bluetooth_off"
        case Identifier.diagnostic, Identifier.legacyDiagnostic: return "diagnostic"
        default: return "unknown"
        }
    }
}
