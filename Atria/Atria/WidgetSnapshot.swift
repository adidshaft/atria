import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

struct WidgetSnapshot: Codable {
    let schema: Int
    let createdAt: Date
    let recoveryPercent: Int?
    let recoveryConfidence: String
    let recoveryDetail: String
    let strain: Double
    let restingHR: Int?
    let hrvRMSSD: Int?
    let hrvState: String
    let maxHR: Int
    // Lock Screen single-metric widgets (Steps / BPM, alongside Strain / HRV).
    let steps: Int?
    let heartRate: Int?
    let batteryLevel: Int?
    let batteryChargeStatus: String?
    let batteryChargeText: String?
    let storage: String
    let appGroupEnabled: Bool
    let widgetTargetPresent: Bool
    let complicationTargetPresent: Bool
}

@MainActor
enum WidgetSnapshotPublisher {
    struct Diagnostics {
        let storage: String
        let appGroupEnabled: Bool
        let widgetTargetPresent: Bool
        let complicationTargetPresent: Bool
    }

    private static let key = "atria.widgetSnapshot.v1"
    private static let appGroupID = "group.com.adidshaft.atria"
    static var diagnostics: Diagnostics {
        let extensions = bundledExtensionInfos()
        let widgetTargetPresent = extensions.contains { $0.extensionPoint == "com.apple.widgetkit-extension" }
        let complicationTargetPresent = extensions.contains { info in
            info.extensionPoint == "com.apple.watchkit"
                || (info.extensionPoint == "com.apple.widgetkit-extension" && info.supportsAccessoryFamilies)
        }
        let appGroupEnabled = hasAppGroupEntitlement()
        return Diagnostics(storage: appGroupEnabled ? "app_group_userdefaults" : "app_local_userdefaults",
                           appGroupEnabled: appGroupEnabled,
                           widgetTargetPresent: widgetTargetPresent,
                           complicationTargetPresent: complicationTargetPresent)
    }

    static func publishFromLaunchIfRequested(store: SessionStore,
                                             ble: AtriaBLEManager,
                                             arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--atria-log-widget-snapshot") else { return }
        publish(store: store, ble: ble, reason: "launch")
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            publish(store: store, ble: ble, reason: "delayed")
        }
    }

    @discardableResult
    static func publish(store: SessionStore,
                        ble: AtriaBLEManager,
                        reason: String = "update") -> WidgetSnapshot {
        let rest = store.baseline.restingInt ?? ble.restingHR ?? store.sessions.first?.restingStable
        let validatedHRV = store.latestReferenceValidatedHRV
        let fallbackHRV = validatedHRV ?? store.latestLocalRMSSD
        let latestSleep = store.sleepHistorySnapshot.latest
        let recovery = Metrics.recoveryV2(hrvSnapshot: ble.hrvSnapshot,
                                          fallbackRMSSD: fallbackHRV,
                                          restingNow: rest,
                                          baseline: store.baseline,
                                          hrvReferenceValidated: validatedHRV != nil,
                                          sleepEfficiency: latestSleep?.sleepEfficiency,
                                          sleepDurationHours: latestSleep?.durationHours,
                                          respiratoryRate: latestSleep?.respiratoryRate,
                                          respiratoryBaseline: store.sleepHistorySnapshot.respiratoryBaselineStats)
        let strain = dayStrain(store: store, ble: ble, rest: rest ?? 60)
        let hrvRMSSD: Int?
        if recovery.usesHRV {
            if let snapshot = ble.hrvSnapshot, snapshot.isReady {
                hrvRMSSD = Int(snapshot.rmssd.rounded())
            } else {
                hrvRMSSD = fallbackHRV
            }
        } else {
            hrvRMSSD = nil
        }
        let hrvState: String
        if hrvRMSSD == nil {
            hrvState = "learning"
        } else {
            hrvState = recovery.confidence == .validated ? "validated" : "personal_baseline"
        }
        let widgetDiagnostics = Self.diagnostics
        let snapshot = WidgetSnapshot(schema: 2,
                                      createdAt: Date(),
                                      recoveryPercent: recovery.percent,
                                      recoveryConfidence: recovery.confidence.rawValue,
                                      recoveryDetail: recovery.detail,
                                      strain: strain,
                                      restingHR: rest,
                                      hrvRMSSD: hrvRMSSD,
                                      hrvState: hrvState,
                                      maxHR: store.profile.maxHR,
                                      steps: ble.phoneStepsToday > 0 ? ble.phoneStepsToday : nil,
                                      heartRate: ble.heartRate > 0 ? ble.heartRate : nil,
                                      batteryLevel: ble.batteryLevel >= 0 ? ble.batteryLevel : nil,
                                      batteryChargeStatus: ble.batteryChargeStatus.rawValue,
                                      batteryChargeText: ble.batteryChargeStatus.label,
                                      storage: widgetDiagnostics.storage,
                                      appGroupEnabled: widgetDiagnostics.appGroupEnabled,
                                      widgetTargetPresent: widgetDiagnostics.widgetTargetPresent,
                                      complicationTargetPresent: widgetDiagnostics.complicationTargetPresent)
        if let data = try? JSONEncoder.widgetSnapshotEncoder.encode(snapshot) {
            let defaults = widgetDiagnostics.appGroupEnabled
                ? (UserDefaults(suiteName: appGroupID) ?? .standard)
                : .standard
            defaults.set(data, forKey: key)
            AtriaDebugLog("ATRIADBG widget_snapshot status=ok reason=%@ schema=%d recovery=%@ confidence=%@ hrv=%@ strain=%.1f rhr=%@ max_hr=%d battery=%@ charge=%@ bytes=%d storage=%@ app_group=%d widget_target=%d complication_target=%d",
                          reason,
                          snapshot.schema,
                          formatInt(snapshot.recoveryPercent),
                          snapshot.recoveryConfidence,
                          hrvState,
                          snapshot.strain,
                          formatInt(snapshot.restingHR),
                          snapshot.maxHR,
                          formatInt(snapshot.batteryLevel),
                          snapshot.batteryChargeStatus ?? "unknown",
                          data.count,
                          snapshot.storage,
                          snapshot.appGroupEnabled ? 1 : 0,
                          snapshot.widgetTargetPresent ? 1 : 0,
                          snapshot.complicationTargetPresent ? 1 : 0)
            let readinessAction = widgetReadinessAction(diagnostics: widgetDiagnostics)
            let readinessStatus = widgetDiagnostics.appGroupEnabled
                && widgetDiagnostics.widgetTargetPresent
                && widgetDiagnostics.complicationTargetPresent ? "ready" : "diagnostic_only"
            AtriaDebugLog("ATRIADBG widget_readiness status=%@ storage=%@ app_group=%d widget_target=%d complication_target=%d action=%@",
                          readinessStatus,
                          snapshot.storage,
                          snapshot.appGroupEnabled ? 1 : 0,
                          snapshot.widgetTargetPresent ? 1 : 0,
                          snapshot.complicationTargetPresent ? 1 : 0,
                          readinessAction)
#if canImport(WidgetKit)
            if widgetDiagnostics.appGroupEnabled {
                WidgetCenter.shared.reloadAllTimelines()
            }
#endif
        } else {
            AtriaDebugLog("ATRIADBG widget_snapshot status=error reason=encode_failed")
        }
        return snapshot
    }

    private static func dayStrain(store: SessionStore, ble: AtriaBLEManager, rest: Int) -> Double {
        let saved = store.todayTRIMP(rest: rest, max: store.profile.maxHR)
        let live = ble.session.first.map { first in
            Metrics.trimp(ble.session.map { (t: $0.t.timeIntervalSince(first.t), bpm: $0.bpm) },
                          rest: rest,
                          max: store.profile.maxHR)
        } ?? 0
        return Metrics.strain(fromTRIMP: saved + live)
    }

    private static func formatInt(_ value: Int?) -> String {
        value.map(String.init) ?? "learning"
    }

    private static func widgetReadinessAction(diagnostics: Diagnostics) -> String {
        var actions: [String] = []
        if !diagnostics.widgetTargetPresent {
            actions.append("add_widgetkit_target")
        }
        if !diagnostics.appGroupEnabled {
            actions.append("enable_shared_app_group")
        }
        if !diagnostics.complicationTargetPresent {
            actions.append("add_complication_target")
        }
        return actions.isEmpty ? "verify_widget_on_device" : actions.joined(separator: "+")
    }

    private struct BundledExtensionInfo {
        let extensionPoint: String
        let supportsAccessoryFamilies: Bool
    }

    private static func bundledExtensionInfos() -> [BundledExtensionInfo] {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL,
              let urls = try? FileManager.default.contentsOfDirectory(at: pluginsURL,
                                                                       includingPropertiesForKeys: nil) else {
            return []
        }
        return urls.compactMap { url in
            guard url.pathExtension == "appex",
                  let bundle = Bundle(url: url),
                  let extensionInfo = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                  let identifier = extensionInfo["NSExtensionPointIdentifier"] as? String else {
                return nil
            }
            let supportsAccessory =
                (bundle.object(forInfoDictionaryKey: "AtriaWidgetSupportsAccessoryFamilies") as? Bool) == true
                || (bundle.object(forInfoDictionaryKey: "AtriaWidgetSupportsAccessoryFamilies") as? Bool) == true
            return BundledExtensionInfo(extensionPoint: identifier,
                                        supportsAccessoryFamilies: supportsAccessory)
        }
    }

    private static func hasAppGroupEntitlement() -> Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1) ?? String(data: data, encoding: .utf8) else {
            return false
        }
        return text.contains(appGroupID)
    }
}

private extension JSONEncoder {
    static var widgetSnapshotEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
