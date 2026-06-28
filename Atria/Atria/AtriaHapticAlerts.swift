import CallKit
import Foundation
import SwiftUI
import UIKit

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

@MainActor
final class AtriaHapticAlertCoordinator: NSObject, CXCallObserverDelegate {
    private static let heartRateZoneHapticCooldown: TimeInterval = 30

    struct Snapshot {
        let status: AtriaBLEManager.Status
        let isRecording: Bool
        let heartRate: Int
        let maxHR: Int
        let batteryLevel: Int
        let recoveryPercent: Int?
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
    private var strainWasAtTarget = false

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

    private func updateRecoveryReady(percent: Int?, settings: AtriaHapticAlertSettings) {
        let ready = percent != nil
        defer { recoveryWasReady = ready }
        guard settings.recoveryReady, ready, !recoveryWasReady else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AtriaDebugLog("ATRIADBG haptic_alert kind=recovery_ready phone_side=1 strap_write=0")
    }

    private func updateStrainTarget(strain: Double,
                                    target: Double?,
                                    settings: AtriaHapticAlertSettings) {
        let atTarget = target.map { strain >= $0 } ?? false
        defer { strainWasAtTarget = atTarget }
        guard settings.strainTarget, activeCollection, atTarget, !strainWasAtTarget else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AtriaDebugLog("ATRIADBG haptic_alert kind=strain_target strain=%.1f target=%.1f phone_side=1 strap_write=0",
              strain,
              target ?? 0)
    }
}

struct AtriaHapticAlertSettingsCard: View, Equatable {
    let settings: AtriaHapticAlertSettings
    let onUpdate: (AtriaHapticAlertSettings) -> Void

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

                VStack(alignment: .leading, spacing: 3) {
                    Text("Phone haptics")
                        .font(.subheadline.weight(.semibold))
                    Text("Incoming calls, zones, targets, and low strap battery.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
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
