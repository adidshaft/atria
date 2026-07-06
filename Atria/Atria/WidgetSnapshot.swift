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
    // Sleep duration for the Sleep h chip/column on Home Screen widgets. Optional
    // so widgets built against schema <4 payloads still decode (missing key -> nil).
    let sleepHours: Double?
    // Lock Screen single-metric widgets (Steps / BPM, alongside Strain / HRV).
    let steps: Int?
    let heartRate: Int?
    let batteryLevel: Int?
    let batteryChargeStatus: String?
    let batteryChargeText: String?
    let layoutGlanceMetrics: [String]?
    let layoutRingCenterMetric: String?
    let layoutLegendStatStyle: String?
    let layoutAccent: String?
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
    // Perf (docs/26 follow-up): bundle layout + entitlements are immutable for
    // the process lifetime, but `diagnostics` was recomputed on every widget
    // publish — a synchronous FileManager.contentsOfDirectory + bundle reads +
    // mobileprovision Data(contentsOf:) on the main thread. Compute once and
    // cache (MainActor-isolated, so the cache write is race-free).
    private static var cachedDiagnostics: Diagnostics?
    static var diagnostics: Diagnostics {
        if let cached = cachedDiagnostics { return cached }
        let computed = computeDiagnostics()
        cachedDiagnostics = computed
        return computed
    }

    private static func computeDiagnostics() -> Diagnostics {
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
        Task {
            await store.waitForDeferredSessionLoadIfNeeded(timeoutSeconds: 120)
            publish(store: store, ble: ble, reason: "session_load")
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
        let recovery = Metrics.recoveryV2(hrvSnapshot: ble.recoveryHRVSnapshot,
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
        let layout = currentHomeLayoutConfig()
        let widgetDiagnostics = Self.diagnostics
        let snapshot = WidgetSnapshot(schema: 4,
                                      createdAt: Date(),
                                      recoveryPercent: recovery.percent,
                                      recoveryConfidence: recovery.confidence.rawValue,
                                      recoveryDetail: recovery.detail,
                                      strain: strain,
                                      restingHR: rest,
                                      hrvRMSSD: hrvRMSSD,
                                      hrvState: hrvState,
                                      maxHR: store.profile.maxHR,
                                      sleepHours: latestSleep?.durationHours,
                                      steps: store.imuAuditSummary.strapStepCount > 0 ? store.imuAuditSummary.strapStepCount : nil,
                                      heartRate: ble.heartRate > 0 ? ble.heartRate : nil,
                                      batteryLevel: ble.batteryLevel >= 0 ? ble.batteryLevel : nil,
                                      batteryChargeStatus: ble.batteryChargeStatus.rawValue,
                                      batteryChargeText: ble.batteryChargeStatus.label,
                                      layoutGlanceMetrics: layout.glanceMetrics,
                                      layoutRingCenterMetric: layout.ringCenterMetric.rawValue,
                                      layoutLegendStatStyle: layout.legendStatStyle.rawValue,
                                      layoutAccent: layout.accent.rawValue,
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
            if widgetDiagnostics.appGroupEnabled, shouldReloadTimelines(for: snapshot) {
                WidgetCenter.shared.reloadAllTimelines()
            }
#endif
        } else {
            AtriaDebugLog("ATRIADBG widget_snapshot status=error reason=encode_failed")
        }
        return snapshot
    }

    // WidgetKit throttles reloads (~40-70/day); reloading on every publish burns
    // that budget and leaves the widget stale when it matters. Reload only when a
    // user-visible field changed, or 15+ minutes passed since the last reload.
    private static var lastReloadFingerprint: String?
    private static var lastReloadDate: Date?

    private static func shouldReloadTimelines(for snapshot: WidgetSnapshot, now: Date = Date()) -> Bool {
        var parts: [String] = []
        parts.append(snapshot.recoveryPercent.map(String.init) ?? "learning")
        parts.append(snapshot.recoveryConfidence)
        parts.append(String(format: "%.1f", snapshot.strain))
        parts.append(snapshot.restingHR.map(String.init) ?? "-")
        parts.append(snapshot.hrvRMSSD.map(String.init) ?? "-")
        parts.append(snapshot.sleepHours.map { String(format: "%.1f", $0) } ?? "-")
        // Steps and heart rate are bucketed like battery: they tick continuously,
        // and an unbucketed value would defeat this throttle while walking.
        parts.append(snapshot.steps.map { String(($0 / 100) * 100) } ?? "-")
        parts.append(snapshot.heartRate.map { String(($0 / 5) * 5) } ?? "-")
        let batteryBucket: String = snapshot.batteryLevel.map { String(($0 / 10) * 10) } ?? "-"
        parts.append(batteryBucket)
        parts.append(snapshot.batteryChargeStatus ?? "-")
        parts.append(snapshot.layoutGlanceMetrics?.joined(separator: ",") ?? "-")
        parts.append(snapshot.layoutRingCenterMetric ?? "-")
        parts.append(snapshot.layoutLegendStatStyle ?? "-")
        parts.append(snapshot.layoutAccent ?? "-")
        let fingerprint = parts.joined(separator: "|")
        let staleEnough = lastReloadDate.map { now.timeIntervalSince($0) >= 15 * 60 } ?? true
        guard fingerprint != lastReloadFingerprint || staleEnough else { return false }
        lastReloadFingerprint = fingerprint
        lastReloadDate = now
        return true
    }

    // Perf (overnight-hang fix): dayStrain previously recomputed live-session
    // TRIMP over the ENTIRE in-memory `ble.session` array on every publish (~3s
    // cadence while foregrounded). Across a night that array grows to tens of
    // thousands of samples, so the O(n) map + exp() loop ran on the main actor
    // and produced accumulating frame hangs. We now keep an incremental
    // accumulator (mirrors AtriaHomeView.nextLiveSessionDerived) keyed on the
    // sample prefix, so each publish only integrates the NEW samples. State is
    // MainActor-isolated like `cachedDiagnostics`, so writes are race-free.
    private static var liveTRIMPSampleCount = 0
    private static var liveTRIMPLastTimestamp: Date?
    private static var liveTRIMPRest = 0
    private static var liveTRIMPMax = 0
    private static var liveTRIMPValue = 0.0

    private static func dayStrain(store: SessionStore, ble: AtriaBLEManager, rest: Int) -> Double {
        let saved = store.todayTRIMP(rest: rest, max: store.profile.maxHR)
        let live = incrementalLiveTRIMP(samples: ble.session, rest: rest, max: store.profile.maxHR)
        return Metrics.strain(fromTRIMP: saved + live)
    }

    /// Same TRIMP math as `Metrics.trimp` / `AtriaHomeView.liveSessionTRIMP`, but
    /// extends a cached running total instead of re-integrating the whole array.
    /// Falls back to a full recompute when the sample prefix, rest, or max HR no
    /// longer match the cached state (e.g. after a live-session rollover clears
    /// `ble.session`, or the resting/max baseline changed).
    private static func incrementalLiveTRIMP(samples: [HRSample], rest: Int, max: Int) -> Double {
        guard max > rest, samples.count > 1 else {
            liveTRIMPSampleCount = samples.count
            liveTRIMPLastTimestamp = samples.last?.t
            liveTRIMPRest = rest
            liveTRIMPMax = max
            liveTRIMPValue = 0
            return 0
        }
        let canExtend = rest == liveTRIMPRest
            && max == liveTRIMPMax
            && liveTRIMPSampleCount > 0
            && liveTRIMPSampleCount <= samples.count
            && liveTRIMPLastTimestamp == samples[liveTRIMPSampleCount - 1].t
        let span = Double(max - rest)
        var total = canExtend ? liveTRIMPValue : 0
        var index = canExtend ? liveTRIMPSampleCount : 1
        while index < samples.count {
            let dtMin = samples[index].t.timeIntervalSince(samples[index - 1].t) / 60.0
            if dtMin > 0, dtMin < 5 {
                let hrr = Swift.min(Swift.max((Double(samples[index].bpm) - Double(rest)) / span, 0), 1)
                total += dtMin * hrr * 0.64 * exp(1.92 * hrr)
            }
            index += 1
        }
        liveTRIMPSampleCount = samples.count
        liveTRIMPLastTimestamp = samples.last?.t
        liveTRIMPRest = rest
        liveTRIMPMax = max
        liveTRIMPValue = total
        return total
    }

    private static func currentHomeLayoutConfig() -> AtriaHomeLayoutConfig {
        guard let data = UserDefaults.standard.string(forKey: AtriaHomeLayoutConfig.storageKey)?.data(using: .utf8),
              let config = try? AtriaHomeLayoutConfig.decoded(from: data) else {
            return .default.validated()
        }
        return config
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
    // Perf (docs/26 follow-up): stored static so the encoder is configured once
    // rather than allocated on every widget publish during live use. Read-only
    // concurrent encodes on an immutable-config encoder are safe.
    static let widgetSnapshotEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
