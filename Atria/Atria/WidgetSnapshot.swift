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
    /// `true` means a fresh strap-derived preliminary count. Widgets must
    /// prefix it with `~` and never present it as a validated exact total.
    var stepsAreEstimated: Bool? = nil
    /// Timestamp of the most recent CRC-valid strap motion frame supporting
    /// `steps`. Independent from `createdAt`, which can advance for battery,
    /// recovery, or layout changes without making the step stream fresh.
    let stepsCapturedAt: Date?
    let heartRate: Int?
    /// Timestamp of the accepted strap HR sample supporting `heartRate`.
    let heartRateCapturedAt: Date?
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
    private static var scheduledPublishTask: Task<Void, Never>?

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
                                         batteryLevel: Int?,
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
                batteryLevel: batteryLevel,
                batteryChargeStatus: batteryChargeStatus,
                batteryChargeText: batteryChargeText
            )
            guard let patchedData = try? JSONEncoder.widgetSnapshotEncoder.encode(patched) else {
                scheduledPublishTask = nil
                return
            }
            defaults.set(patchedData, forKey: key)
            #if canImport(WidgetKit)
            if widgetDiagnostics.appGroupEnabled, shouldReloadTimelines(for: patched) {
                WidgetCenter.shared.reloadAllTimelines()
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
        batteryLevel: Int?,
        batteryChargeStatus: String,
        batteryChargeText: String
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            schema: current.schema,
            createdAt: createdAt,
            recoveryPercent: current.recoveryPercent,
            recoveryConfidence: current.recoveryConfidence,
            recoveryDetail: current.recoveryDetail,
            strain: strain,
            restingHR: current.restingHR,
            hrvRMSSD: current.hrvRMSSD,
            hrvState: current.hrvState,
            maxHR: current.maxHR,
            sleepHours: current.sleepHours,
            steps: steps,
            stepsAreEstimated: steps == nil ? nil : stepsAreEstimated,
            stepsCapturedAt: steps == nil ? nil : stepsCapturedAt,
            heartRate: heartRate,
            heartRateCapturedAt: heartRate == nil ? nil : heartRateCapturedAt,
            batteryLevel: batteryLevel,
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
                                       restingHR: snapshot.restingHR,
                                       hrvRMSSD: snapshot.hrvRMSSD,
                                       hrvState: snapshot.hrvState,
                                       maxHR: snapshot.maxHR,
                                       sleepHours: snapshot.sleepHours,
                                       steps: snapshot.steps,
                                       stepsAreEstimated: snapshot.stepsAreEstimated,
                                       stepsCapturedAt: snapshot.stepsCapturedAt,
                                       heartRate: snapshot.heartRate,
                                       heartRateCapturedAt: snapshot.heartRateCapturedAt,
                                       batteryLevel: nil,
                                       batteryChargeStatus: AtriaBLEManager.BatteryChargeStatus.levelOnly.rawValue,
                                       batteryChargeText: "Pending",
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
        let recovery = Metrics.recoveryV2(hrvSnapshot: ble.recoveryHRVSnapshot,
                                          fallbackRMSSD: fallbackHRV,
                                          restingNow: rest,
                                          baseline: store.baseline,
                                          hrvReferenceValidated: validatedHRV != nil,
                                          sleepEfficiency: latestSleep?.sleepEfficiency,
                                          sleepDurationHours: latestSleep?.durationHours,
                                          respiratoryRate: latestSleep?.respiratoryRate,
                                          respiratoryBaseline: store.sleepHistorySnapshot.respiratoryBaselineStats)
        // Recovery stability (Scope 2, 2026-07-09): the widget recomputed recovery
        // live on every publish, so its % drifted through the morning HRV window and
        // jumped at noon when the window closed -- diverging from the Today ring,
        // which shows the frozen once-a-morning value. Prefer today's frozen daily
        // recovery (the SAME scalar the ring reads via displayRecovery), falling back
        // to the live estimate only before this morning's value has been minted.
        // Resolve the complete frozen summary atomically. Mixing its score with a
        // later live confidence/detail/HRV would describe a different recovery.
        let calendar = Calendar.current
        let physiologicalCycle = AtriaPhysiologicalCycle.current(now: now,
                                                                 confirmedSleeps: store.confirmedSleeps,
                                                                 calendar: calendar)
        let frozenTodayRollup = store.dailyRollupHistory.first {
            physiologicalCycle.boundaryKind == .mainSleep
                && calendar.isDate($0.day, inSameDayAs: physiologicalCycle.start)
                && $0.recovery != nil
        }
        let frozenRecovery = frozenTodayRollup?.resolvedRecoverySummary()
        let noSleepRecovery = physiologicalCycle.boundaryKind == .noSleepFallback
            ? Metrics.RecoveryEstimate(percent: 1,
                                       confidence: .unverified,
                                       usesHRV: false,
                                       detail: "No main sleep recorded for this physiological cycle.",
                                       contributors: [
                                           Metrics.RecoveryEstimate.Contributor(kind: .sleep,
                                                                                zScore: -3,
                                                                                weight: 1,
                                                                                detail: "No main sleep recorded",
                                                                                displayValue: "0h",
                                                                                direction: -1)
                                       ])
            : nil
        let displayedRecovery = noSleepRecovery ?? frozenRecovery?.recoveryEstimate ?? recovery
        let recoveryPercent = noSleepRecovery?.percent ?? frozenRecovery?.score ?? recovery.percent
        let strain = dayStrain(store: store, ble: ble, rest: rest ?? 60)
        let savedAggregate = store.homeSavedAggregate(rest: rest ?? 60,
                                                       maxHR: store.profile.maxHR,
                                                       activeSessionID: ble.currentLiveSessionID)
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
        let stepsAreValidated = strapStepsAreValidated(state: ble.liveStrapStepResearchState)
        let publishedSteps = strapStepsToday > 0
            && strapStepsArePublishable(state: ble.liveStrapStepResearchState)
            ? strapStepsToday
            : nil
        let stepsCapturedAt = publishedSteps == nil
            ? nil
            : AtriaStrapStepLiveStatus.persistedMotionDate()
        let hrvRMSSD: Int?
        if let frozenRecovery {
            hrvRMSSD = frozenRecovery.usesHRV
                ? frozenTodayRollup?.lnRMSSD.map { Int(exp($0).rounded()) }
                : nil
        } else if recovery.usesHRV {
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
        let displayableBatteryLevel = ble.displayableBatteryLevel()
        let displayableChargeStatus = displayableBatteryLevel == nil
            ? AtriaBLEManager.BatteryChargeStatus.levelOnly
            : ble.batteryChargeStatus
        let snapshot = WidgetSnapshot(schema: 4,
                                      createdAt: Date(),
                                      recoveryPercent: recoveryPercent,
                                      recoveryConfidence: displayedRecovery.confidence.rawValue,
                                      recoveryDetail: displayedRecovery.detail,
                                      strain: strain,
                                      restingHR: rest,
                                      hrvRMSSD: hrvRMSSD,
                                      hrvState: hrvState,
                                      maxHR: store.profile.maxHR,
                                      sleepHours: latestSleep?.durationHours,
                                      steps: publishedSteps,
                                      stepsAreEstimated: publishedSteps == nil ? nil : !stepsAreValidated,
                                      stepsCapturedAt: stepsCapturedAt,
                                      heartRate: liveHeartRate > 0 ? liveHeartRate : nil,
                                      heartRateCapturedAt: liveHeartRateCapturedAt,
                                      batteryLevel: displayableBatteryLevel,
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

    nonisolated static func strapStepsAreValidated(state: String) -> Bool {
        state == "validated"
            || state == "r10_live_validated"
    }

    nonisolated static func strapStepsArePublishable(state: String) -> Bool {
        strapStepsAreValidated(state: state)
            || state == "r10_live_preliminary"
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
        parts.append(snapshot.stepsAreEstimated == true ? "estimated" : "validated")
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
    private static var liveTRIMPSex: AthleteProfile.BiologicalSex = .unspecified
    private static var liveTRIMPCycleStart: Date?
    private static var liveTRIMPValue = 0.0

    private static func dayStrain(store: SessionStore, ble: AtriaBLEManager, rest: Int) -> Double {
        let saved = store.homeSavedAggregate(rest: rest,
                                              maxHR: store.profile.maxHR,
                                              activeSessionID: ble.currentLiveSessionID)
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

private extension JSONDecoder {
    static let widgetSnapshotDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
