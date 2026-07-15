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
    /// When the cumulative wake-to-wake strain projection was recomputed.
    /// This is deliberately independent of the latest live HR sample; a radio
    /// pause cannot invalidate load already accumulated from durable evidence.
    var strainCapturedAt: Date? = nil
    /// Physiological wake-to-wake cycle owning `strain`. Optional for backward
    /// decoding, but current widgets fail closed when either boundary is absent.
    var strainCycleStart: Date? = nil
    var strainCycleExpiresAt: Date? = nil
    let restingHR: Int?
    let hrvRMSSD: Int?
    let hrvState: String
    let maxHR: Int
    // Sleep duration for the Sleep h chip/column on Home Screen widgets. Optional
    // so widgets built against schema <4 payloads still decode (missing key -> nil).
    let sleepHours: Double?
    // Lock Screen single-metric widgets (Steps / BPM, alongside Strain / HRV).
    let steps: Int?
    /// `true` means a fresh strap-derived preliminary count. Widgets must
    /// prefix it with `~` and never present it as a validated exact total.
    var stepsAreEstimated: Bool? = nil
    /// Timestamp of the most recent CRC-valid strap motion frame supporting
    /// `steps`. Independent from `createdAt`, which can advance for battery,
    /// recovery, or layout changes without making the step stream fresh.
    let stepsCapturedAt: Date?
    /// Optional so schema-4 snapshots written before goals were added still
    /// decode. This is the user's all-day strap-step goal, never a workout
    /// session delta.
    var dailyStepGoal: Int? = nil
    let heartRate: Int?
    /// Timestamp of the accepted strap HR sample supporting `heartRate`.
    let heartRateCapturedAt: Date?
    /// Canonical zone computed by the app's shared HRZone model. Keeping the
    /// result in the snapshot prevents the widget extension from reimplementing
    /// thresholds and drifting from the in-app workout UI.
    var heartRateZoneIndex: Int? = nil
    var heartRateZoneName: String? = nil
    let batteryLevel: Int?
    var batteryCapturedAt: Date? = nil
    /// A current 2A19 notification lease can corroborate an unchanged accepted
    /// mid-range level without pretending that a new battery packet arrived.
    var batteryCorroboratedAt: Date? = nil
    /// Independent evidence clock for charger state. A fresh percentage or
    /// notification lease must never renew an older charging/full claim.
    var batteryChargeCapturedAt: Date? = nil
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
    private static var scheduledPublishTask: Task<Void, Never>?
#if canImport(WidgetKit)
    /// WidgetKit is not a 1 Hz surface, but dropping every change below the old
    /// 100-step bucket made short walks invisible. Keep one independent,
    /// trailing delivery lane for sensor changes: writes remain immediate in
    /// the shared container, while visible timeline reloads are coalesced to a
    /// bounded cadence. The trailing task is important when a short walk ends
    /// before the cadence window opens -- its final count still reaches the
    /// widget without waiting for an unrelated dashboard update.
    private static var lastTimelineReloadSnapshot: WidgetSnapshot?
    private static var lastTimelineReloadDate: Date?
    private static var pendingTimelineReloadSnapshot: WidgetSnapshot?
    private static var pendingTimelineReloadTask: Task<Void, Never>?
    private static var pendingTimelineReloadDeadline: Date?
#endif

    /// During an active workout the stable daily fields (recovery, HRV, sleep,
    /// layout) do not need to be rebuilt from SessionStore for every pulse.
    /// Patch only the genuinely live values in the already-durable snapshot.
    /// This keeps Lock Screen widgets current without running recovery/cycle/
    /// rollup/TRIMP scans on the main actor during workout controls or a scene
    /// return animation.
    static func scheduleLiveWorkoutPatch(heartRate: Int?,
                                         heartRateCapturedAt: Date?,
                                         steps: Int?,
                                         stepsAreEstimated: Bool,
                                         stepsCapturedAt: Date?,
                                         strain: Double,
                                         strainCapturedAt: Date? = nil,
                                         batteryLevel: Int?,
                                         batteryCapturedAt: Date? = nil,
                                         batteryCorroboratedAt: Date? = nil,
                                         batteryChargeCapturedAt: Date? = nil,
                                         batteryChargeStatus: String,
                                         batteryChargeText: String,
                                         reason: String,
                                         delay: Duration = .milliseconds(60)) {
        scheduledPublishTask?.cancel()
        scheduledPublishTask = Task { @MainActor in
            await Task.yield()
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let widgetDiagnostics = diagnostics
            let defaults = widgetDiagnostics.appGroupEnabled
                ? (UserDefaults(suiteName: appGroupID) ?? .standard)
                : .standard
            guard let data = defaults.data(forKey: key),
                  let current = try? JSONDecoder.widgetSnapshotDecoder.decode(
                    WidgetSnapshot.self,
                    from: data
                  ) else {
                scheduledPublishTask = nil
                return
            }
            let patched = liveWorkoutPatchedSnapshot(
                current: current,
                createdAt: Date(),
                heartRate: heartRate,
                heartRateCapturedAt: heartRateCapturedAt,
                steps: steps,
                stepsAreEstimated: stepsAreEstimated,
                stepsCapturedAt: stepsCapturedAt,
                strain: strain,
                strainCapturedAt: strainCapturedAt,
                batteryLevel: batteryLevel,
                batteryCapturedAt: batteryCapturedAt,
                batteryCorroboratedAt: batteryCorroboratedAt,
                batteryChargeCapturedAt: batteryChargeCapturedAt,
                batteryChargeStatus: batteryChargeStatus,
                batteryChargeText: batteryChargeText
            )
            guard let patchedData = try? JSONEncoder.widgetSnapshotEncoder.encode(patched) else {
                scheduledPublishTask = nil
                return
            }
            defaults.set(patchedData, forKey: key)
            #if canImport(WidgetKit)
            if widgetDiagnostics.appGroupEnabled {
                scheduleTimelineReload(for: patched)
            }
            #endif
            AtriaDebugLog("ATRIADBG widget_snapshot status=live_workout_patch reason=%@ bytes=%d",
                          reason,
                          patchedData.count)
            scheduledPublishTask = nil
        }
    }

    nonisolated static func liveWorkoutPatchedSnapshot(
        current: WidgetSnapshot,
        createdAt: Date,
        heartRate: Int?,
        heartRateCapturedAt: Date?,
        steps: Int?,
        stepsAreEstimated: Bool,
        stepsCapturedAt: Date?,
        strain: Double,
        strainCapturedAt: Date? = nil,
        batteryLevel: Int?,
        batteryCapturedAt: Date? = nil,
        batteryCorroboratedAt: Date? = nil,
        batteryChargeCapturedAt: Date? = nil,
        batteryChargeStatus: String,
        batteryChargeText: String
    ) -> WidgetSnapshot {
        let heartRateZone = heartRate.map { HRZone.zone(for: $0, maxHR: current.maxHR) }
        return WidgetSnapshot(
            schema: current.schema,
            createdAt: createdAt,
            recoveryPercent: current.recoveryPercent,
            recoveryConfidence: current.recoveryConfidence,
            recoveryDetail: current.recoveryDetail,
            strain: strain,
            strainCapturedAt: cumulativeStrainCaptureDate(
                previousValue: current.strain,
                previousCapturedAt: current.strainCapturedAt,
                nextValue: strain,
                nextEvidenceAt: strainCapturedAt
            ),
            strainCycleStart: current.strainCycleStart,
            strainCycleExpiresAt: current.strainCycleExpiresAt,
            restingHR: current.restingHR,
            hrvRMSSD: current.hrvRMSSD,
            hrvState: current.hrvState,
            maxHR: current.maxHR,
            sleepHours: current.sleepHours,
            steps: steps,
            stepsAreEstimated: steps == nil ? nil : stepsAreEstimated,
            stepsCapturedAt: steps == nil ? nil : stepsCapturedAt,
            dailyStepGoal: current.dailyStepGoal,
            heartRate: heartRate,
            heartRateCapturedAt: heartRate == nil ? nil : heartRateCapturedAt,
            heartRateZoneIndex: heartRate == nil ? nil : heartRateZone?.rawValue,
            heartRateZoneName: heartRate == nil ? nil : heartRateZone?.name,
            batteryLevel: batteryLevel,
            batteryCapturedAt: batteryLevel == nil ? nil : batteryCapturedAt,
            batteryCorroboratedAt: batteryLevel == nil ? nil : batteryCorroboratedAt,
            batteryChargeCapturedAt: batteryLevel == nil ? nil : batteryChargeCapturedAt,
            batteryChargeStatus: batteryChargeStatus,
            batteryChargeText: batteryChargeText,
            layoutGlanceMetrics: current.layoutGlanceMetrics,
            layoutRingCenterMetric: current.layoutRingCenterMetric,
            layoutLegendStatStyle: current.layoutLegendStatStyle,
            layoutAccent: current.layoutAccent,
            storage: current.storage,
            appGroupEnabled: current.appGroupEnabled,
            widgetTargetPresent: current.widgetTargetPresent,
            complicationTargetPresent: current.complicationTargetPresent
        )
    }

    /// Coalesces publisher bursts and lets scene/UI transitions commit before
    /// recovery, strain, JSON encoding, defaults writes, and WidgetKit reloads
    /// run on the main actor. Callers that require an immediate return value
    /// (proof/debug surfaces and bounded BG tasks) continue using `publish`.
    static func schedulePublish(store: SessionStore,
                                ble: AtriaBLEManager,
                                reason: String,
                                delay: Duration = .milliseconds(60)) {
        scheduledPublishTask?.cancel()
        scheduledPublishTask = Task { @MainActor in
            await Task.yield()
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            _ = publish(store: store, ble: ble, reason: reason)
            scheduledPublishTask = nil
        }
    }

    /// Clears only disputed battery fields immediately, even before deferred
    /// session loading permits a full snapshot rewrite.
    static func invalidateBatteryProjection(defaults injectedDefaults: UserDefaults? = nil) {
        let widgetDiagnostics = Self.diagnostics
        let defaults = injectedDefaults ?? (widgetDiagnostics.appGroupEnabled
            ? (UserDefaults(suiteName: appGroupID) ?? .standard)
            : .standard)
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder.widgetSnapshotDecoder.decode(WidgetSnapshot.self, from: data) else { return }
        let sanitized = WidgetSnapshot(schema: snapshot.schema,
                                       createdAt: Date(),
                                       recoveryPercent: snapshot.recoveryPercent,
                                       recoveryConfidence: snapshot.recoveryConfidence,
                                       recoveryDetail: snapshot.recoveryDetail,
                                       strain: snapshot.strain,
                                       strainCapturedAt: snapshot.strainCapturedAt,
                                       strainCycleStart: snapshot.strainCycleStart,
                                       strainCycleExpiresAt: snapshot.strainCycleExpiresAt,
                                       restingHR: snapshot.restingHR,
                                       hrvRMSSD: snapshot.hrvRMSSD,
                                       hrvState: snapshot.hrvState,
                                       maxHR: snapshot.maxHR,
                                       sleepHours: snapshot.sleepHours,
                                       steps: snapshot.steps,
                                       stepsAreEstimated: snapshot.stepsAreEstimated,
                                       stepsCapturedAt: snapshot.stepsCapturedAt,
                                       dailyStepGoal: snapshot.dailyStepGoal,
                                       heartRate: snapshot.heartRate,
                                       heartRateCapturedAt: snapshot.heartRateCapturedAt,
                                       heartRateZoneIndex: snapshot.heartRateZoneIndex,
                                       heartRateZoneName: snapshot.heartRateZoneName,
                                       batteryLevel: nil,
                                       batteryCapturedAt: nil,
                                       batteryCorroboratedAt: nil,
                                       batteryChargeCapturedAt: nil,
                                       batteryChargeStatus: AtriaBLEManager.BatteryChargeStatus.levelOnly.rawValue,
                                       batteryChargeText: "Unavailable",
                                       layoutGlanceMetrics: snapshot.layoutGlanceMetrics,
                                       layoutRingCenterMetric: snapshot.layoutRingCenterMetric,
                                       layoutLegendStatStyle: snapshot.layoutLegendStatStyle,
                                       layoutAccent: snapshot.layoutAccent,
                                       storage: snapshot.storage,
                                       appGroupEnabled: snapshot.appGroupEnabled,
                                       widgetTargetPresent: snapshot.widgetTargetPresent,
                                       complicationTargetPresent: snapshot.complicationTargetPresent)
        guard let sanitizedData = try? JSONEncoder.widgetSnapshotEncoder.encode(sanitized) else { return }
        defaults.set(sanitizedData, forKey: key)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        AtriaDebugLog("ATRIADBG widget_snapshot status=battery_invalidated reason=disputed_transition")
    }
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
        // Cold-start strain-flash fix (2026-07-07, device-diagnosed): the
        // volatile live BLE resting reading used to outrank the stable
        // saved-session resting, so the first widget snapshots computed
        // strain from a transient value (86 bpm -> 73) and flashed a wrong
        // number until session load. Stable sources first; the live reading
        // is only the last resort before the session_load republish.
        let rest = store.baseline.restingInt ?? store.sessions.first?.restingStable ?? ble.restingHR
        let now = Date()
        let validatedHRV = store.latestReferenceValidatedRecoveryHRV(on: now)
        let fallbackHRV = validatedHRV ?? store.latestLocalRecoveryHRV(on: now)
        let latestSleep = store.sleepHistorySnapshot.latestMainSleep
            .flatMap { _ in store.currentPhysiologicalMainSleep(on: now) }
        let calendar = Calendar.current
        let physiologicalCycle = AtriaPhysiologicalCycle.current(now: now,
                                                                 confirmedSleeps: store.confirmedSleeps,
                                                                 calendar: calendar)
        // One SessionStore projection keeps Home, widgets and notifications on
        // the same wake-to-wake value and prevents frequent widget publications
        // from repeatedly evaluating Recovery v2.
        let displayedRecovery = store.recoveryProjection(
            now: now,
            calendar: calendar,
            initialFallbackHRVSnapshot: ble.recoveryHRVSnapshot,
            liveRestingHeartRate: ble.restingHR
        )
        let recoveryPercent = displayedRecovery.percent
        let frozenRecovery = DailyRecoveryResolver.summary(
            rollups: store.dailyRollupHistory,
            metrics: store.dailyMetricHistory,
            physiologicalCycle: physiologicalCycle,
            anchorSleep: latestSleep,
            calendar: calendar
        )
        let frozenTodayRollup = store.dailyRollupHistory.first {
            physiologicalCycle.boundaryKind == .mainSleep
                && calendar.isDate($0.day, inSameDayAs: physiologicalCycle.start)
                && $0.recovery != nil
        }
        let savedAggregate = store.homeSavedAggregate(rest: rest ?? 60,
                                                       maxHR: store.profile.maxHR,
                                                       activeSessionID: ble.currentLiveSessionID)
        let strain = dayStrain(saved: savedAggregate,
                               store: store,
                               ble: ble,
                               rest: rest ?? 60)
        let strapStepsToday = AtriaHomeModel.mergedStrapStepResearchCount(
            savedToday: savedAggregate.savedTodayStrapSteps,
            savedActiveSession: savedAggregate.savedActiveSessionStrapSteps,
            savedActiveSessionTotal: savedAggregate.savedActiveSessionTotalStrapSteps,
            liveActiveSession: ble.liveStrapStepResearchCount
        )
        let liveHeartRate = AtriaHomeModel.resolvedLiveHeartRate(
            heartRate: ble.heartRate,
            sensorHasContact: ble.hasContact,
            status: ble.status,
            latestSampleHeartRate: ble.session.last?.bpm,
            latestSampleAt: ble.session.last?.t
        )
        let liveHeartRateCapturedAt = liveHeartRate > 0 ? ble.session.last?.t : nil
        let liveHeartRateZone = liveHeartRate > 0
            ? HRZone.zone(for: liveHeartRate, maxHR: store.profile.maxHR)
            : nil
        let stepsAreValidated = strapStepsAreValidated(state: ble.liveStrapStepResearchState)
        let publishedSteps = strapStepsToday > 0
            && strapStepsArePublishable(state: ble.liveStrapStepResearchState)
            ? strapStepsToday
            : nil
        let stepsCapturedAt = publishedSteps == nil
            ? nil
            : ble.liveStrapStepCountCapturedAt
        let storedDailyStepGoal = UserDefaults.standard.integer(forKey: "atria.target.steps.goal")
        let dailyStepGoal = storedDailyStepGoal > 0 ? storedDailyStepGoal : 8_000
        let hrvRMSSD: Int?
        if let frozenRecovery {
            hrvRMSSD = frozenRecovery.usesHRV
                ? frozenTodayRollup?.lnRMSSD.map { Int(exp($0).rounded()) }
                : nil
        } else if displayedRecovery.usesHRV {
            if let snapshot = ble.hrvSnapshot, snapshot.isDisplayEligible(on: now) {
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
            hrvState = displayedRecovery.confidence == .validated ? "validated" : "personal_baseline"
        }
        let layout = currentHomeLayoutConfig()
        let widgetDiagnostics = Self.diagnostics
        let defaults = widgetDiagnostics.appGroupEnabled
            ? (UserDefaults(suiteName: appGroupID) ?? .standard)
            : .standard
        let strainCycleExpiresAt = cumulativeStrainCycleExpiration(
            cycle: physiologicalCycle,
            confirmedSleeps: store.confirmedSleeps,
            calendar: calendar
        )
        // `displayableBatteryLevel` already fails closed unless the level is a
        // validated mid-range packet or the running app is renewing a proven
        // change-driven 2A19 lease. Re-applying the older "recent baseline"
        // veto here made widgets disagree with the app and show Learning while
        // the same connected strap truthfully showed 12% · Low.
        let displayableBatteryLevel = ble.displayableBatteryLevel()
        let persistedBattery = AtriaBLEManager.cachedBattery(now: now)
        let displayableChargeStatus = displayableBatteryLevel == nil
            ? AtriaBLEManager.BatteryChargeStatus.levelOnly
            : ble.batteryChargeStatus
        let batteryChargeCapturedAt = displayableBatteryLevel != nil
            && (displayableChargeStatus == .charging || displayableChargeStatus == .full)
            && persistedBattery.chargeAge >= 0
            ? now.addingTimeInterval(-persistedBattery.chargeAge)
            : nil
        let snapshot = WidgetSnapshot(schema: 4,
                                      createdAt: now,
                                      recoveryPercent: recoveryPercent,
                                      recoveryConfidence: displayedRecovery.confidence.rawValue,
                                      recoveryDetail: displayedRecovery.detail,
                                      strain: strain,
                                      // `dayStrain` was recomputed immediately
                                      // above; this is its true computation
                                      // clock, not a generic snapshot fallback.
                                      strainCapturedAt: now,
                                      strainCycleStart: physiologicalCycle.start,
                                      strainCycleExpiresAt: strainCycleExpiresAt,
                                      restingHR: rest,
                                      hrvRMSSD: hrvRMSSD,
                                      hrvState: hrvState,
                                      maxHR: store.profile.maxHR,
                                      sleepHours: latestSleep?.durationHours,
                                      steps: publishedSteps,
                                      stepsAreEstimated: publishedSteps == nil ? nil : !stepsAreValidated,
                                      stepsCapturedAt: stepsCapturedAt,
                                      dailyStepGoal: dailyStepGoal,
                                      heartRate: liveHeartRate > 0 ? liveHeartRate : nil,
                                      heartRateCapturedAt: liveHeartRateCapturedAt,
                                      heartRateZoneIndex: liveHeartRateZone?.rawValue,
                                      heartRateZoneName: liveHeartRateZone?.name,
                                      batteryLevel: displayableBatteryLevel,
                                      batteryCapturedAt: displayableBatteryLevel == nil ? nil : ble.lastVerifiedBatteryLevelAt,
                                      batteryCorroboratedAt: displayableBatteryLevel == nil
                                        ? nil : ble.batteryDisplayCorroboratedAt(),
                                      batteryChargeCapturedAt: batteryChargeCapturedAt,
                                      batteryChargeStatus: displayableChargeStatus.rawValue,
                                      batteryChargeText: displayableChargeStatus.label,
                                      layoutGlanceMetrics: layout.glanceMetrics,
                                      layoutRingCenterMetric: layout.ringCenterMetric.rawValue,
                                      layoutLegendStatStyle: layout.legendStatStyle.rawValue,
                                      layoutAccent: layout.accent.rawValue,
                                      storage: widgetDiagnostics.storage,
                                      appGroupEnabled: widgetDiagnostics.appGroupEnabled,
                                      widgetTargetPresent: widgetDiagnostics.widgetTargetPresent,
                                      complicationTargetPresent: widgetDiagnostics.complicationTargetPresent)
        // Cold-start guard (2026-07-07, device-verified residual): before the
        // deferred session load completes, day strain computes from zero saved
        // TRIMP and would overwrite last run's good snapshot with an
        // under-report (0.0 -> real over ~4s on device). Compute and return,
        // but don't persist -- the session_load republish writes the real one.
        if !store.hasLoadedSavedSessions {
            AtriaDebugLog("ATRIADBG widget_snapshot status=deferred reason=%@ awaiting=session_load", reason)
            return snapshot
        }
        if let data = try? JSONEncoder.widgetSnapshotEncoder.encode(snapshot) {
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
                scheduleTimelineReload(for: snapshot)
            }
#endif
        } else {
            AtriaDebugLog("ATRIADBG widget_snapshot status=error reason=encode_failed")
        }
        return snapshot
    }

    nonisolated static func strapStepsAreValidated(state: String) -> Bool {
        state == "validated"
            || state == "r10_live_validated"
    }

    nonisolated static func strapStepsArePublishable(state: String) -> Bool {
        strapStepsAreValidated(state: state)
            || state == "r10_live_preliminary"
    }

    /// Live writes can arrive every five seconds. WidgetKit cannot sustainably
    /// reload at that frequency, so exact step/HR progress and their independent
    /// capture clocks share a one-minute delivery cadence. Non-sensor changes
    /// (recovery, strain, battery, layout, source availability, HR zone, step
    /// goal) remain immediate.
    nonisolated static let liveSensorTimelineReloadMinimumInterval: TimeInterval = 60
    nonisolated static let timelineReloadMaximumInterval: TimeInterval = 15 * 60

    /// `0` means reload now, a positive value means preserve a trailing reload
    /// after that delay, and `nil` means there is no new visible state to send.
    /// Kept pure for regression coverage of short walks and same-value capture
    /// clock renewals.
    nonisolated static func timelineReloadDelay(previous: WidgetSnapshot?,
                                                lastReloadAt: Date?,
                                                snapshot: WidgetSnapshot,
                                                now: Date) -> TimeInterval? {
        guard let previous, let lastReloadAt else { return 0 }
        if timelineTransitionFingerprint(for: previous)
            != timelineTransitionFingerprint(for: snapshot) {
            return 0
        }

        let sensorProjectionChanged = previous.steps != snapshot.steps
            || previous.stepsCapturedAt != snapshot.stepsCapturedAt
            || previous.heartRate != snapshot.heartRate
            || previous.heartRateCapturedAt != snapshot.heartRateCapturedAt
            || previous.batteryCapturedAt != snapshot.batteryCapturedAt
            || previous.batteryCorroboratedAt != snapshot.batteryCorroboratedAt
            || previous.batteryChargeCapturedAt != snapshot.batteryChargeCapturedAt
            || previous.strainCapturedAt != snapshot.strainCapturedAt
        let elapsed = max(0, now.timeIntervalSince(lastReloadAt))
        if sensorProjectionChanged {
            return elapsed >= liveSensorTimelineReloadMinimumInterval
                ? 0
                : liveSensorTimelineReloadMinimumInterval - elapsed
        }
        return elapsed >= timelineReloadMaximumInterval ? 0 : nil
    }

    private nonisolated static func timelineTransitionFingerprint(for snapshot: WidgetSnapshot) -> String {
        var parts: [String] = []
        parts.append(snapshot.recoveryPercent.map(String.init) ?? "learning")
        parts.append(snapshot.recoveryConfidence)
        parts.append(String(format: "%.1f", snapshot.strain))
        parts.append(snapshot.strainCycleStart.map { String($0.timeIntervalSince1970) } ?? "strain_cycle_absent")
        parts.append(snapshot.strainCycleExpiresAt.map { String($0.timeIntervalSince1970) } ?? "strain_expiry_absent")
        parts.append(snapshot.restingHR.map(String.init) ?? "-")
        parts.append(snapshot.hrvRMSSD.map(String.init) ?? "-")
        parts.append(snapshot.sleepHours.map { String(format: "%.1f", $0) } ?? "-")
        // Exact step/HR values and capture clocks are handled by the bounded
        // sensor lane above. Presence and semantic transitions stay immediate.
        parts.append(snapshot.steps == nil ? "steps_absent" : "steps_present")
        parts.append(snapshot.stepsCapturedAt == nil ? "motion_clock_absent" : "motion_clock_present")
        parts.append(snapshot.stepsAreEstimated == true ? "estimated" : "validated")
        parts.append(snapshot.dailyStepGoal.map(String.init) ?? "-")
        let exactDailyStepGoalReached = snapshot.stepsAreEstimated != true
            && snapshot.dailyStepGoal.map { goal in
                goal > 0 && (snapshot.steps ?? 0) >= goal
            } == true
        parts.append(exactDailyStepGoalReached ? "step_goal_reached" : "step_goal_pending")
        parts.append(snapshot.heartRate == nil ? "hr_absent" : "hr_present")
        parts.append(snapshot.heartRateCapturedAt == nil ? "hr_clock_absent" : "hr_clock_present")
        parts.append(snapshot.heartRateZoneIndex.map(String.init) ?? "-")
        let batteryBucket: String = snapshot.batteryLevel.map { String(($0 / 10) * 10) } ?? "-"
        parts.append(batteryBucket)
        parts.append(snapshot.batteryChargeStatus ?? "-")
        parts.append(snapshot.layoutGlanceMetrics?.joined(separator: ",") ?? "-")
        parts.append(snapshot.layoutRingCenterMetric ?? "-")
        parts.append(snapshot.layoutLegendStatStyle ?? "-")
        parts.append(snapshot.layoutAccent ?? "-")
        return parts.joined(separator: "|")
    }

#if canImport(WidgetKit)
    private static func scheduleTimelineReload(for snapshot: WidgetSnapshot,
                                               now: Date = Date()) {
        let delay = timelineReloadDelay(previous: lastTimelineReloadSnapshot,
                                        lastReloadAt: lastTimelineReloadDate,
                                        snapshot: snapshot,
                                        now: now)
        guard let delay else { return }
        if delay <= 0 {
            pendingTimelineReloadTask?.cancel()
            pendingTimelineReloadTask = nil
            pendingTimelineReloadSnapshot = nil
            pendingTimelineReloadDeadline = nil
            deliverTimelineReload(snapshot, now: now)
            return
        }

        pendingTimelineReloadSnapshot = snapshot
        let deadline = now.addingTimeInterval(delay)
        if let currentDeadline = pendingTimelineReloadDeadline,
           currentDeadline <= deadline,
           pendingTimelineReloadTask != nil {
            return
        }
        pendingTimelineReloadTask?.cancel()
        pendingTimelineReloadDeadline = deadline
        pendingTimelineReloadTask = Task { @MainActor in
            let sleep = max(0, deadline.timeIntervalSinceNow)
            if sleep > 0 {
                try? await Task.sleep(for: .seconds(sleep))
            }
            guard !Task.isCancelled else { return }
            let latest = pendingTimelineReloadSnapshot ?? snapshot
            pendingTimelineReloadTask = nil
            pendingTimelineReloadSnapshot = nil
            pendingTimelineReloadDeadline = nil
            deliverTimelineReload(latest, now: Date())
        }
    }

    private static func deliverTimelineReload(_ snapshot: WidgetSnapshot,
                                              now: Date) {
        lastTimelineReloadSnapshot = snapshot
        lastTimelineReloadDate = now
        WidgetCenter.shared.reloadAllTimelines()
    }
#endif

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
    private static var liveTRIMPSex: AthleteProfile.BiologicalSex = .unspecified
    private static var liveTRIMPCycleStart: Date?
    private static var liveTRIMPValue = 0.0

    /// Preserve the cumulative clock when a live patch only changes HR, steps,
    /// battery, or another unrelated field. A changed aggregate may advance
    /// only from its explicit load-evidence clock; `createdAt` is intentionally
    /// not accepted as a fallback here.
    nonisolated static func cumulativeStrainCaptureDate(
        previousValue: Double?,
        previousCapturedAt: Date?,
        nextValue: Double,
        nextEvidenceAt: Date?
    ) -> Date? {
        guard let previousValue,
              abs(previousValue - nextValue) <= 0.000_000_001 else {
            return nextEvidenceAt
        }
        return previousCapturedAt ?? nextEvidenceAt
    }

    nonisolated static func cumulativeStrainCycleExpiration(
        cycle: AtriaPhysiologicalCycle,
        confirmedSleeps: [UserConfirmedSleep],
        calendar: Calendar
    ) -> Date {
        let cycleCalendar: Calendar
        if let anchorID = cycle.anchorSleepID,
           let anchor = confirmedSleeps.first(where: { $0.id == anchorID }) {
            cycleCalendar = EventCivilTime.eventCalendar(
                timeZoneIdentifier: anchor.eventTimeZoneIdentifier,
                fallback: calendar
            )
        } else {
            cycleCalendar = calendar
        }
        // `AtriaPhysiologicalCycle.current` advances the no-sleep boundary by
        // one civil day in this same event calendar. Persist that exact future
        // boundary so WidgetKit cannot keep yesterday's load current-looking.
        return cycleCalendar.date(byAdding: .day, value: 1, to: cycle.start)
            ?? cycle.start.addingTimeInterval(AtriaPhysiologicalCycle.maximumLearnedInterval)
    }

    private static func dayStrain(saved: SessionStore.HomeSavedAggregate,
                                  store: SessionStore,
                                  ble: AtriaBLEManager,
                                  rest: Int) -> Double {
        let live = incrementalLiveTRIMP(samples: ble.session,
                                        rest: rest,
                                        max: store.profile.maxHR,
                                        sex: store.profile.biologicalSex,
                                        cycleStart: saved.day)
        let reconciled = SessionStore.mergedTodayTRIMP(
            savedToday: saved.savedTodayTRIMP,
            savedActiveSession: saved.savedActiveSessionTRIMP,
            liveActiveSession: live
        )
        return Metrics.strain(fromTRIMP: reconciled)
    }

    /// Same TRIMP math as `Metrics.trimp` / `AtriaHomeView.liveSessionTRIMP`, but
    /// extends a cached running total instead of re-integrating the whole array.
    /// Falls back to a full recompute when the sample prefix, rest, or max HR no
    /// longer match the cached state (e.g. after a live-session rollover clears
    /// `ble.session`, or the resting/max baseline changed).
    // Internal (was private) so LocalNotificationScheduler reuses this same
    // incremental accumulator instead of re-integrating the whole live session
    // (2026-07-08 perf audit). Both are @MainActor, so the cache stays race-free.
    static func incrementalLiveTRIMP(samples: [HRSample],
                                     rest: Int,
                                     max: Int,
                                     sex: AthleteProfile.BiologicalSex = .unspecified,
                                     cycleStart: Date? = nil) -> Double {
        guard max > rest, samples.count > 1 else {
            liveTRIMPSampleCount = samples.count
            liveTRIMPLastTimestamp = samples.last?.t
            liveTRIMPRest = rest
            liveTRIMPMax = max
            liveTRIMPSex = sex
            liveTRIMPCycleStart = cycleStart
            liveTRIMPValue = 0
            return 0
        }
        let canExtend = rest == liveTRIMPRest
            && max == liveTRIMPMax
            && sex == liveTRIMPSex
            && cycleStart == liveTRIMPCycleStart
            && liveTRIMPSampleCount > 0
            && liveTRIMPSampleCount <= samples.count
            && liveTRIMPLastTimestamp == samples[liveTRIMPSampleCount - 1].t
        let span = Double(max - rest)
        var total = canExtend ? liveTRIMPValue : 0
        var index = canExtend ? liveTRIMPSampleCount : 1
        while index < samples.count {
            let dtSeconds = samples[index].t.timeIntervalSince(samples[index - 1].t)
            let insideCycle = cycleStart.map {
                samples[index - 1].t >= $0 && samples[index].t >= $0
            } ?? true
            if insideCycle,
               dtSeconds > 0,
               dtSeconds <= AtriaAnalytics.Strain.maximumLoadEvidenceGap {
                let dtMin = dtSeconds / 60.0
                let meanBPM = (Double(samples[index - 1].bpm) + Double(samples[index].bpm)) / 2
                let hrr = Swift.min(Swift.max((meanBPM - Double(rest)) / span, 0), 1)
                let coefficient = AtriaAnalytics.Strain.banisterCoefficient(for: sex)
                total += dtMin * hrr * 0.64 * exp(coefficient * hrr)
            }
            index += 1
        }
        liveTRIMPSampleCount = samples.count
        liveTRIMPLastTimestamp = samples.last?.t
        liveTRIMPRest = rest
        liveTRIMPMax = max
        liveTRIMPSex = sex
        liveTRIMPCycleStart = cycleStart
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

extension JSONDecoder {
    static let widgetSnapshotDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
