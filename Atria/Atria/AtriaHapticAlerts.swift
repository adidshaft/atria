import CallKit
import Foundation
import SwiftUI
import UIKit

struct AtriaStrainTargetHapticLatch {
    private var firedDay: Date?

    mutating func shouldFire(strain: Double,
                             target: Double?,
                             now: Date = Date(),
                             calendar: Calendar = .current) -> Bool {
        guard let target, strain >= target else { return false }
        let day = calendar.startOfDay(for: now)
        if let firedDay, calendar.isDate(firedDay, inSameDayAs: day) {
            return false
        }
        firedDay = day
        return true
    }
}

struct AtriaHapticAlertSettings: Codable, Equatable {
    var incomingCalls = true
    var heartRateZones = true
    var recoveryReady = true
    var strainTarget = true
    var lowBattery = true

    var enabledCount: Int {
        [incomingCalls, heartRateZones, recoveryReady, strainTarget, lowBattery].filter { $0 }.count
    }

    var glanceValueText: String {
        "\(enabledCount)/5"
    }

    var glanceDetailText: String {
        if enabledCount == 0 { return "Off" }
        if heartRateZones { return "Zones on" }
        return "Zones off"
    }

    private static let key = "atria.hapticAlertSettings.v1"

    static func load() -> AtriaHapticAlertSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AtriaHapticAlertSettings.self, from: data) else {
            return AtriaHapticAlertSettings()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

/// User choice for which LOCAL notifications Atria may post. All notifications are
/// on-device only (UNUserNotificationCenter); there is no cloud/push. Read by
/// LocalNotificationScheduler at schedule time so the user is always in control.
struct AtriaNotificationSettings: Codable, Equatable {
    var allowNotifications = true
    var recoveryReady = true
    var strainTarget = true
    var sleepReview = true
    var workoutReview = true
    var morningSummary = true
    var weeklyReport = true
    var healthDeviation = true
    var strapBattery = true
    var bluetoothOff = true
    var fitCheck = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowNotifications = try container.decodeIfPresent(Bool.self, forKey: .allowNotifications) ?? true
        recoveryReady = try container.decodeIfPresent(Bool.self, forKey: .recoveryReady) ?? true
        strainTarget = try container.decodeIfPresent(Bool.self, forKey: .strainTarget) ?? true
        sleepReview = try container.decodeIfPresent(Bool.self, forKey: .sleepReview) ?? true
        workoutReview = try container.decodeIfPresent(Bool.self, forKey: .workoutReview) ?? true
        morningSummary = try container.decodeIfPresent(Bool.self, forKey: .morningSummary) ?? true
        weeklyReport = try container.decodeIfPresent(Bool.self, forKey: .weeklyReport) ?? true
        healthDeviation = try container.decodeIfPresent(Bool.self, forKey: .healthDeviation) ?? true
        strapBattery = try container.decodeIfPresent(Bool.self, forKey: .strapBattery) ?? true
        bluetoothOff = try container.decodeIfPresent(Bool.self, forKey: .bluetoothOff) ?? true
        fitCheck = try container.decodeIfPresent(Bool.self, forKey: .fitCheck) ?? true
    }

    var enabledCount: Int {
        guard allowNotifications else { return 0 }
        return [recoveryReady, strainTarget, sleepReview, workoutReview, morningSummary, weeklyReport, healthDeviation, strapBattery, bluetoothOff, fitCheck].filter { $0 }.count
    }

    /// Whether a scheduler decision of the given `kind` is permitted by the user.
    /// `diagnostic` is a developer-only delivery probe and is never user-gated.
    func allows(kind: String) -> Bool {
        if kind == "diagnostic" { return true }
        guard allowNotifications else { return false }
        switch kind {
        case "recovery": return recoveryReady
        case "strain": return strainTarget
        case "sleep_review": return sleepReview
        case "workout_review": return workoutReview
        case "morning_summary": return morningSummary
        case "weekly_report": return weeklyReport
        case "health_deviation": return healthDeviation
        case "battery": return strapBattery
        case "bluetooth_off": return bluetoothOff
        case "fit_check": return fitCheck
        default: return true
        }
    }

    private static let key = "atria.notificationSettings.v1"

    static func load() -> AtriaNotificationSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AtriaNotificationSettings.self, from: data) else {
            return AtriaNotificationSettings()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

@MainActor
final class AtriaHapticAlertCoordinator: NSObject, CXCallObserverDelegate {
    private static let heartRateZoneHapticCooldown: TimeInterval = 30
    static let debugStrainTargetStatusKey = "atria.debug.strainTargetHaptic.status"
    static let debugStrainTargetCountKey = "atria.debug.strainTargetHaptic.count"
    static let debugStrainTargetStrainKey = "atria.debug.strainTargetHaptic.strain"
    static let debugStrainTargetTargetKey = "atria.debug.strainTargetHaptic.target"

    struct Snapshot {
        let status: AtriaBLEManager.Status
        let isRecording: Bool
        let heartRate: Int
        let maxHR: Int
        let batteryLevel: Int
        let recoveryPercent: Int?
        /// A numeric early estimate remains useful in the UI, but only a
        /// baseline-qualified recovery should announce itself as "ready".
        let recoveryIsReadyForAlert: Bool
        let strain: Double
        let strainTarget: Double?
        let settings: AtriaHapticAlertSettings
    }

    private let callObserver = CXCallObserver()
    private var settings = AtriaHapticAlertSettings()
    private var activeCollection = false
    private var lastZone: HRZone?
    private var lastZoneHapticAt: Date?
    private var lastBatteryLow = false
    private var recoveryWasReady = false
    private var strainTargetLatch = AtriaStrainTargetHapticLatch()

    override init() {
        super.init()
        callObserver.setDelegate(self, queue: .main)
    }

    func update(_ snapshot: Snapshot) {
        settings = snapshot.settings
        activeCollection = snapshot.isRecording || snapshot.status == .connected

        updateHeartRateZone(heartRate: snapshot.heartRate,
                            maxHR: snapshot.maxHR,
                            settings: snapshot.settings)
        updateLowBattery(level: snapshot.batteryLevel,
                         settings: snapshot.settings)
        updateRecoveryReady(percent: snapshot.recoveryPercent,
                            isReadyForAlert: snapshot.recoveryIsReadyForAlert,
                            settings: snapshot.settings)
        updateStrainTarget(strain: snapshot.strain,
                           target: snapshot.strainTarget,
                           settings: snapshot.settings)
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        Task { @MainActor in
            let isRinging = !call.hasConnected && !call.hasEnded
            guard settings.incomingCalls, activeCollection, isRinging else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            AtriaDebugLog("ATRIADBG haptic_alert kind=incoming_call active_collection=1 phone_side=1 strap_write=0")
        }
    }

    private func updateHeartRateZone(heartRate: Int, maxHR: Int, settings: AtriaHapticAlertSettings) {
        guard settings.heartRateZones, heartRate > 0, maxHR > 0, activeCollection else {
            lastZone = nil
            return
        }
        let zone = HRZone.zone(for: heartRate, maxHR: maxHR)
        defer { lastZone = zone }
        guard let lastZone, lastZone != zone else { return }
        let now = Date()
        if let lastZoneHapticAt,
           now.timeIntervalSince(lastZoneHapticAt) < Self.heartRateZoneHapticCooldown {
            AtriaDebugLog("ATRIADBG haptic_alert kind=hr_zone status=cooled_down from=%@ to=%@ bpm=%d max_hr=%d cooldown_s=%.0f phone_side=1 strap_write=0",
                  lastZone.name,
                  zone.name,
                  heartRate,
                  maxHR,
                  Self.heartRateZoneHapticCooldown)
            return
        }
        lastZoneHapticAt = now
        UIImpactFeedbackGenerator(style: zone.rawValue > lastZone.rawValue ? .medium : .light).impactOccurred()
        AtriaDebugLog("ATRIADBG haptic_alert kind=hr_zone from=%@ to=%@ bpm=%d max_hr=%d phone_side=1 strap_write=0",
              lastZone.name,
              zone.name,
              heartRate,
              maxHR)
    }

    private func updateLowBattery(level: Int, settings: AtriaHapticAlertSettings) {
        let isLow = level >= 0 && level <= 20
        defer { lastBatteryLow = isLow }
        guard settings.lowBattery, activeCollection, isLow, !lastBatteryLow else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        AtriaDebugLog("ATRIADBG haptic_alert kind=low_battery level=%d phone_side=1 strap_write=0", level)
    }

    nonisolated static func shouldFireRecoveryReady(percent: Int?,
                                                    isReadyForAlert: Bool,
                                                    wasReady: Bool) -> Bool {
        percent != nil && isReadyForAlert && !wasReady
    }

    private func updateRecoveryReady(percent: Int?,
                                     isReadyForAlert: Bool,
                                     settings: AtriaHapticAlertSettings) {
        let ready = percent != nil && isReadyForAlert
        defer { recoveryWasReady = ready }
        guard settings.recoveryReady,
              Self.shouldFireRecoveryReady(percent: percent,
                                           isReadyForAlert: isReadyForAlert,
                                           wasReady: recoveryWasReady),
              let percent else { return }
        let feedback: UINotificationFeedbackGenerator.FeedbackType = percent <= 33 ? .warning : .success
        UINotificationFeedbackGenerator().notificationOccurred(feedback)
        AtriaDebugLog("ATRIADBG haptic_alert kind=recovery_ready percent=%d feedback=%@ phone_side=1 strap_write=0",
                      percent,
                      percent <= 33 ? "warning" : "success")
    }

    private func updateStrainTarget(strain: Double,
                                    target: Double?,
                                    settings: AtriaHapticAlertSettings) {
        guard settings.strainTarget,
              activeCollection,
              strainTargetLatch.shouldFire(strain: strain, target: target) else {
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let fireCount = UserDefaults.standard.integer(forKey: Self.debugStrainTargetCountKey) + 1
        UserDefaults.standard.set("fired", forKey: Self.debugStrainTargetStatusKey)
        UserDefaults.standard.set(fireCount, forKey: Self.debugStrainTargetCountKey)
        UserDefaults.standard.set(strain, forKey: Self.debugStrainTargetStrainKey)
        UserDefaults.standard.set(target ?? 0, forKey: Self.debugStrainTargetTargetKey)
        AtriaDebugLog("ATRIADBG haptic_alert kind=strain_target strain=%.1f target=%.1f phone_side=1 strap_write=0",
              strain,
              target ?? 0)
    }
}

struct AtriaHapticAlertSettingsCard: View, Equatable {
    let settings: AtriaHapticAlertSettings
    let onUpdate: (AtriaHapticAlertSettings) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static func == (lhs: AtriaHapticAlertSettingsCard, rhs: AtriaHapticAlertSettingsCard) -> Bool {
        lhs.settings == rhs.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.purple)
                    .frame(width: 38, height: 38)
                    .background(AtriaIconTileBackground(cornerRadius: 12, tint: .purple))

                Text("Phone haptics")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Phone haptics. Incoming calls, zones, targets, and low strap battery.")

            LazyVGrid(columns: AtriaAlertSettingsGrid.columns(for: dynamicTypeSize), spacing: 8) {
                hapticToggle("Calls", keyPath: \.incomingCalls)
                hapticToggle("Zones", keyPath: \.heartRateZones)
                hapticToggle("Recovery", keyPath: \.recoveryReady)
                hapticToggle("Strain", keyPath: \.strainTarget)
                hapticToggle("Battery", keyPath: \.lowBattery)
            }
        }
        .padding(14)
        .atriaInsetCard(tint: .purple)
    }

    private func hapticToggle(_ title: String,
                              keyPath: WritableKeyPath<AtriaHapticAlertSettings, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { settings[keyPath: keyPath] },
            set: { enabled in
                var next = settings
                next[keyPath: keyPath] = enabled
                onUpdate(next)
            }
        ))
        .font(.caption.weight(.semibold))
        .toggleStyle(.switch)
        .tint(.purple)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .atriaInsetCard(cornerRadius: 14, tint: .purple)
    }
}

/// Self-contained "choice of notifications" card: persists straight to UserDefaults
/// (the scheduler reads the same store at schedule time), so it needs no app-model wiring.
struct AtriaNotificationSettingsCard: View {
    @State private var settings = AtriaNotificationSettings.load()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(AtriaIconTileBackground(cornerRadius: 12, tint: .blue))

                Text("Notifications")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Notifications. Choose which alerts Atria can send on this phone. Nothing leaves your device.")

            // Master gate for EVERY alert kind except diagnostics (see
            // AtriaNotificationSettings.allows(kind:)), including strap
            // battery / Bluetooth / fit-check — so it must not read as
            // coaching-only, or a user keeping safety alerts would turn it off.
            notificationToggle("Allow notifications", keyPath: \.allowNotifications, prominent: true)

            if settings.allowNotifications {
                LazyVGrid(columns: AtriaAlertSettingsGrid.columns(for: dynamicTypeSize), spacing: 8) {
                    notificationToggle("Recovery check-ins", keyPath: \.recoveryReady)
                    notificationToggle("Strain milestones", keyPath: \.strainTarget)
                    notificationToggle("Sleep review", keyPath: \.sleepReview)
                    notificationToggle("Workout review", keyPath: \.workoutReview)
                    notificationToggle("Morning summary", keyPath: \.morningSummary)
                    notificationToggle("Weekly report", keyPath: \.weeklyReport)
                    notificationToggle("Health monitor", keyPath: \.healthDeviation)
                    notificationToggle("Strap battery", keyPath: \.strapBattery)
                    notificationToggle("Bluetooth help", keyPath: \.bluetoothOff)
                    notificationToggle("Fit check reminders", keyPath: \.fitCheck)
                }
                .transition(.opacity)
            }
        }
        .padding(14)
        .atriaInsetCard(tint: .blue)
        .animation(.snappy(duration: AtriaDesignTokens.Motion.standard), value: settings.allowNotifications)
    }

    private func notificationToggle(_ title: String,
                                    keyPath: WritableKeyPath<AtriaNotificationSettings, Bool>,
                                    prominent: Bool = false) -> some View {
        Toggle(title, isOn: Binding(
            get: { settings[keyPath: keyPath] },
            set: { enabled in
                settings[keyPath: keyPath] = enabled
                settings.save()
            }
        ))
        .font((prominent ? Font.subheadline : Font.caption).weight(.semibold))
        .toggleStyle(.switch)
        .tint(.blue)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .atriaInsetCard(cornerRadius: 14, tint: .blue)
    }
}

enum AtriaAlertSettingsGrid {
    static func columnCount(for dynamicTypeSize: DynamicTypeSize) -> Int {
        dynamicTypeSize.isAccessibilitySize ? 1 : 2
    }

    static func columns(for dynamicTypeSize: DynamicTypeSize) -> [GridItem] {
        Array(repeating: GridItem(.flexible()),
              count: columnCount(for: dynamicTypeSize))
    }
}
