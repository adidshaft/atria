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
    struct Snapshot {
        let status: WhoopBLEManager.Status
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
            WHOOPDebugLog("WHOOPDBG haptic_alert kind=incoming_call active_collection=1 phone_side=1 strap_write=0")
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
        UIImpactFeedbackGenerator(style: zone.rawValue > lastZone.rawValue ? .medium : .light).impactOccurred()
        WHOOPDebugLog("WHOOPDBG haptic_alert kind=hr_zone from=%@ to=%@ bpm=%d max_hr=%d phone_side=1 strap_write=0",
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
        WHOOPDebugLog("WHOOPDBG haptic_alert kind=low_battery level=%d phone_side=1 strap_write=0", level)
    }

    private func updateRecoveryReady(percent: Int?, settings: AtriaHapticAlertSettings) {
        let ready = percent != nil
        defer { recoveryWasReady = ready }
        guard settings.recoveryReady, ready, !recoveryWasReady else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        WHOOPDebugLog("WHOOPDBG haptic_alert kind=recovery_ready phone_side=1 strap_write=0")
    }

    private func updateStrainTarget(strain: Double,
                                    target: Double?,
                                    settings: AtriaHapticAlertSettings) {
        let atTarget = target.map { strain >= $0 } ?? false
        defer { strainWasAtTarget = atTarget }
        guard settings.strainTarget, activeCollection, atTarget, !strainWasAtTarget else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        WHOOPDebugLog("WHOOPDBG haptic_alert kind=strain_target strain=%.1f target=%.1f phone_side=1 strap_write=0",
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
        .atriaRaisedCard(emphasis: .soft)
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
