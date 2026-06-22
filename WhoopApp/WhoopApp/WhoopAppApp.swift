import SwiftUI
import UIKit
import BackgroundTasks

@main
struct WhoopAppApp: App {
    private static let appRefreshTaskIdentifier = "com.adidshaft.atria.refresh"
    private static let processingTaskIdentifier = "com.adidshaft.atria.processing"

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var ble: WhoopBLEManager
    @StateObject private var store: SessionStore
    @State private var didScheduleLaunchWork = false
    @State private var inactiveFlushTask: Task<Void, Never>?
    private let launchStartedAt = Date()

    init() {
        let ble = WhoopBLEManager()
        let store = SessionStore()
        ble.onSessionEnd = { [store] saved in store.add(saved) }
        ble.onSessionCheckpoint = { [store] saved in store.checkpoint(saved) }
        _ble = StateObject(wrappedValue: ble)
        _store = StateObject(wrappedValue: store)
        Self.registerBackgroundTasks(store: store, ble: ble)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(ble: ble, store: store)
                .onAppear {
                    guard !didScheduleLaunchWork else { return }
                    didScheduleLaunchWork = true
                    let launchArguments = ProcessInfo.processInfo.arguments
                    let hasRequestedDeferredLaunchWork = hasRequestedDeferredLaunchWork(arguments: launchArguments)
                    let shouldRunDeferredWork = shouldRunDeferredLaunchWork(arguments: launchArguments)
                    logLaunchTiming(event: "on_appear")
                    Task { @MainActor in
                        // Yield once so SwiftUI can commit its first frame, then start
                        // the fast foreground setup without an artificial quarter-second pause.
                        await Task.yield()
                        handleFastLaunchWork(arguments: launchArguments)
                    }
                    if shouldRunDeferredWork {
                        Task { @MainActor in
                            // Normal foreground launches stay on the fast path. Only
                            // explicit diagnostics or true background-style launches
                            // pull deferred maintenance into startup.
                            try? await Task.sleep(nanoseconds: hasRequestedDeferredLaunchWork ? 450_000_000 : 1_500_000_000)
                            handleDeferredLaunchWork(arguments: launchArguments)
                        }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        inactiveFlushTask?.cancel()
                        inactiveFlushTask = nil
                        ble.handleUnattendedMode(rest: store.baseline.restingInt ?? 60,
                                                maxHR: store.profile.maxHR,
                                                reason: "scene_background")
                        performSceneBackgroundMaintenance(reason: "scene_background")
                    case .inactive:
                        // Inactive is often a short transient state during gestures,
                        // alerts, and multitasking transitions. Checkpoint the active
                        // journal immediately, then delay the heavier store flush unless
                        // the app actually stays away.
                        ble.flushActiveSessionJournal(reason: "scene_inactive_checkpoint")
                        inactiveFlushTask?.cancel()
                        inactiveFlushTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            guard !Task.isCancelled else { return }
                            guard scenePhase == .inactive else { return }
                            store.requestPersistenceFlush(reason: "scene_inactive_deferred")
                        }
                    case .active:
                        inactiveFlushTask?.cancel()
                        inactiveFlushTask = nil
                        ble.handleInteractiveForeground(rest: store.baseline.restingInt ?? 60,
                                                       maxHR: store.profile.maxHR)
                    @unknown default:
                        inactiveFlushTask?.cancel()
                        inactiveFlushTask = nil
                        ble.flushActiveSessionJournal(reason: "scene_unknown")
                        store.requestPersistenceFlush(reason: "scene_unknown")
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    inactiveFlushTask?.cancel()
                    inactiveFlushTask = nil
                    ble.flushActiveSessionJournal(reason: "app_will_terminate")
                    store.flushScheduledPersistence(reason: "app_will_terminate")
                }
        }
    }

    private static func registerBackgroundTasks(store: SessionStore, ble: WhoopBLEManager) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: appRefreshTaskIdentifier, using: nil) { task in
            handleBackgroundTask(task,
                                 store: store,
                                 ble: ble,
                                 reason: "bg_app_refresh")
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingTaskIdentifier, using: nil) { task in
            handleBackgroundTask(task,
                                 store: store,
                                 ble: ble,
                                 reason: "bg_processing")
        }
    }

    private static func handleBackgroundTask(_ task: BGTask,
                                             store: SessionStore,
                                             ble: WhoopBLEManager,
                                             reason: String) {
        scheduleBackgroundRefresh(reason: "\(reason)_reschedule")
        scheduleBackgroundProcessing(reason: "\(reason)_reschedule")
        let work = Task { @MainActor in
            ble.flushActiveSessionJournal(reason: reason)
            let syncStarted = ble.requestOfflineHistoricalSyncIfNeeded(reason: reason)
            if syncStarted {
                try? await Task.sleep(for: .seconds(185))
            }
            store.performBackgroundMaintenance(reason: reason)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    private func scheduleBackgroundMaintenance(reason: String) {
        Self.scheduleBackgroundRefresh(reason: reason)
        Self.scheduleBackgroundProcessing(reason: reason)
    }

    private func performSceneBackgroundMaintenance(reason: String) {
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Atria background flush") {
            WHOOPDebugLog("WHOOPDBG background_flush status=expired reason=%@", reason)
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }

        ble.flushActiveSessionJournal(reason: reason)
        store.requestPersistenceFlush(reason: reason)
        scheduleBackgroundMaintenance(reason: reason)

        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
        }
        WHOOPDebugLog("WHOOPDBG background_flush status=ok reason=%@", reason)
    }

    private static func scheduleBackgroundRefresh(reason: String) {
        let request = BGAppRefreshTaskRequest(identifier: appRefreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            WHOOPDebugLog("WHOOPDBG bg_task_schedule status=ok kind=refresh reason=%@", reason)
        } catch {
            WHOOPDebugLog("WHOOPDBG bg_task_schedule status=failed kind=refresh reason=%@ error=%@",
                          reason,
                          String(describing: error))
        }
    }

    private static func scheduleBackgroundProcessing(reason: String) {
        let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            WHOOPDebugLog("WHOOPDBG bg_task_schedule status=ok kind=processing reason=%@", reason)
        } catch {
            WHOOPDebugLog("WHOOPDBG bg_task_schedule status=failed kind=processing reason=%@ error=%@",
                          reason,
                          String(describing: error))
        }
    }

    @MainActor
    private func handleFastLaunchWork(arguments: [String]) {
        logLaunchTiming(event: "fast_launch_begin")
        ble.handleInteractiveForeground(rest: store.baseline.restingInt ?? 60,
                                       maxHR: store.profile.maxHR)
        logLaunchTiming(event: "fast_launch_complete")
    }

    @MainActor
    private func handleDeferredLaunchWork(arguments: [String]) {
        logLaunchTiming(event: "deferred_launch_begin")
        store.restoreLatestSessionBackupFromLaunchIfRequested()
        store.completeOnboardingFromLaunchIfRequested()
        ble.applyLaunchAutomation()
        if scenePhase != .active {
            ble.applyPersistentLongWearModeIfNeeded(rest: store.baseline.restingInt ?? 60,
                                                    maxHR: store.profile.maxHR)
        }
        ble.scheduleLiveWorkoutDiagnosticsIfRequested(rest: store.baseline.restingInt ?? 60,
                                                      maxHR: store.profile.maxHR)
        ble.scheduleWorkoutAutoSaveIfRequested(rest: store.baseline.restingInt ?? 60,
                                               maxHR: store.profile.maxHR)

        let requestedLaunchDiagnostics = arguments.contains("--whoop-log-baseline")
            || arguments.contains("--whoop-log-collection-health")
            || arguments.contains("--whoop-log-gate-readiness")
            || arguments.contains("--whoop-log-activity-detections")
            || arguments.contains("--whoop-log-daily-rollups")
            || arguments.contains("--whoop-log-workout-preflight")
            || arguments.contains("--whoop-log-strain-validation")
            || arguments.contains("--whoop-schedule-sleep-validation")
            || arguments.contains("--whoop-schedule-workout-validation")
            || arguments.contains("--whoop-log-trend-summaries")
            || arguments.contains("--whoop-write-session-backup")
            || arguments.contains("--whoop-verify-session-backup")
            || arguments.contains("--whoop-log-gate-status")
            || arguments.contains("--whoop-export-rr-reference-package")
            || arguments.contains("--whoop-export-rr-reference-ui-package")
            || arguments.contains("--whoop-export-hr-reference-package")
            || arguments.contains("--whoop-export-hr-reference-ui-package")
            || arguments.contains("--whoop-validate-rr-reference")
            || arguments.contains("--whoop-validate-hr-reference")
            || arguments.contains("--whoop-clear-reference-inputs")
            || arguments.contains("--whoop-healthkit-export")
            || arguments.contains("--whoop-healthkit-reference-audit")
            || arguments.contains("--whoop-healthkit-reset-rebuild-atria-hr")
            || arguments.contains("--whoop-confirm-best-workout-candidate")
            || arguments.contains("--whoop-confirm-best-sleep-candidate")
        guard requestedLaunchDiagnostics else {
            logLaunchTiming(event: "deferred_launch_complete")
            return
        }

        store.logBaselineMaturityFromLaunchIfRequested(arguments: arguments)
        store.logCollectionHealthFromLaunchIfRequested(arguments: arguments)
        store.logGateReadinessFromLaunchIfRequested(arguments: arguments)
        store.logActivityDetectionsFromLaunchIfRequested(arguments: arguments)
        store.logDailyRollupsFromLaunchIfRequested(arguments: arguments)
        store.logWorkoutPreflightFromLaunchIfRequested(arguments: arguments)
        store.logStrainValidationFromLaunchIfRequested(arguments: arguments)
        store.scheduleSleepValidationFromLaunchIfRequested(arguments: arguments)
        store.scheduleWorkoutValidationFromLaunchIfRequested(arguments: arguments)
        store.logTrendSummariesFromLaunchIfRequested(arguments: arguments)
        store.writeSessionBackupFromLaunchIfRequested(arguments: arguments)
        store.verifyLatestSessionBackupFromLaunchIfRequested(arguments: arguments)
        store.logGateStatusFromLaunchIfRequested(arguments: arguments)
        scheduleLaunchExportsIfRequested(store: store, arguments: arguments)
        LocalNotificationScheduler.scheduleFromLaunchIfRequested(store: store, ble: ble)
        WidgetSnapshotPublisher.publishFromLaunchIfRequested(store: store, ble: ble)
        logLaunchTiming(event: "deferred_launch_complete")
    }

    private func shouldRunDeferredLaunchWork(arguments: [String]) -> Bool {
        if hasRequestedDeferredLaunchWork(arguments: arguments) {
            return true
        }
        return UIApplication.shared.applicationState == .background
    }

    private func hasRequestedDeferredLaunchWork(arguments: [String]) -> Bool {
        arguments.contains { argument in
            guard argument.hasPrefix("--whoop-") else { return false }
            return argument != "--whoop-enable-debug-logs"
        }
    }

    private func logLaunchTiming(event: String) {
        let elapsedMS = Int(Date().timeIntervalSince(launchStartedAt) * 1000)
        WHOOPDebugLog("WHOOPDBG launch_timing event=%@ elapsed_ms=%d scene=%@",
                      event,
                      elapsedMS,
                      String(describing: scenePhase))
    }

    @MainActor
    private func scheduleLaunchExportsIfRequested(store: SessionStore, arguments: [String]) {
        let needsRR = arguments.contains("--whoop-export-rr-reference-package")
        let needsRRUI = arguments.contains("--whoop-export-rr-reference-ui-package")
        let needsHR = arguments.contains("--whoop-export-hr-reference-package")
        let needsHRUI = arguments.contains("--whoop-export-hr-reference-ui-package")
        let needsRRValidation = arguments.contains("--whoop-validate-rr-reference")
        let needsHRValidation = arguments.contains("--whoop-validate-hr-reference")
        let needsReferenceClear = arguments.contains("--whoop-clear-reference-inputs")
        let needsHealthKit = arguments.contains("--whoop-healthkit-export")
        let needsHealthKitAudit = arguments.contains("--whoop-healthkit-reference-audit")
        let needsHealthKitResetRebuild = arguments.contains("--whoop-healthkit-reset-rebuild-atria-hr")
        let needsWorkoutConfirm = arguments.contains("--whoop-confirm-best-workout-candidate")
        let needsSleepConfirm = arguments.contains("--whoop-confirm-best-sleep-candidate")
        guard needsRR || needsRRUI || needsHR || needsHRUI || needsRRValidation || needsHRValidation || needsReferenceClear || needsHealthKit || needsHealthKitAudit || needsHealthKitResetRebuild || needsWorkoutConfirm || needsSleepConfirm else { return }
        WHOOPDebugLog("WHOOPDBG launch_exports status=scheduled rr_reference=%d rr_reference_ui=%d hr_reference=%d hr_reference_ui=%d rr_reference_validation=%d hr_reference_validation=%d reference_clear=%d healthkit=%d healthkit_reference_audit=%d healthkit_reset_rebuild=%d workout_confirm=%d sleep_confirm=%d",
                      needsRR ? 1 : 0,
                      needsRRUI ? 1 : 0,
                      needsHR ? 1 : 0,
                      needsHRUI ? 1 : 0,
                      needsRRValidation ? 1 : 0,
                      needsHRValidation ? 1 : 0,
                      needsReferenceClear ? 1 : 0,
                      needsHealthKit ? 1 : 0,
                      needsHealthKitAudit ? 1 : 0,
                      needsHealthKitResetRebuild ? 1 : 0,
                      needsWorkoutConfirm ? 1 : 0,
                      needsSleepConfirm ? 1 : 0)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            store.clearReferenceInputsFromLaunchIfRequested(arguments: arguments)
            store.exportHRReferencePackageFromLaunchIfRequested(arguments: arguments)
            if needsHRUI {
                _ = store.exportHRReferencePackageForUI()
            }
            store.exportRRReferencePackageFromLaunchIfRequested(arguments: arguments)
            if needsRRUI {
                _ = store.exportRRReferencePackageForUI()
            }
            store.validateHRReferenceFromLaunchIfRequested(arguments: arguments)
            store.validateRRReferenceFromLaunchIfRequested(arguments: arguments)
            store.resetAndRebuildHealthKitHeartRateFromLaunchIfRequested(arguments: arguments)
            store.confirmBestWorkoutCandidateFromLaunchIfRequested(arguments: arguments)
            store.confirmBestSleepCandidateFromLaunchIfRequested(arguments: arguments)
            store.exportHealthKitFromLaunchIfRequested(arguments: arguments)
            store.auditHealthKitHRReferenceFromLaunchIfRequested(arguments: arguments)
            schedulePostHealthKitGateStatusIfNeeded(store: store,
                                                    arguments: arguments,
                                                    needsHealthKit: needsHealthKit || needsHealthKitAudit || needsHealthKitResetRebuild,
                                                    needsResetRebuild: needsHealthKitResetRebuild)
            WHOOPDebugLog("WHOOPDBG launch_exports status=completed rr_reference=%d rr_reference_ui=%d hr_reference=%d hr_reference_ui=%d rr_reference_validation=%d hr_reference_validation=%d reference_clear=%d healthkit=%d healthkit_reference_audit=%d healthkit_reset_rebuild=%d workout_confirm=%d sleep_confirm=%d",
                          needsRR ? 1 : 0,
                          needsRRUI ? 1 : 0,
                          needsHR ? 1 : 0,
                          needsHRUI ? 1 : 0,
                          needsRRValidation ? 1 : 0,
                          needsHRValidation ? 1 : 0,
                          needsReferenceClear ? 1 : 0,
                          needsHealthKit ? 1 : 0,
                          needsHealthKitAudit ? 1 : 0,
                          needsHealthKitResetRebuild ? 1 : 0,
                          needsWorkoutConfirm ? 1 : 0,
                          needsSleepConfirm ? 1 : 0)
        }
    }

    @MainActor
    private func schedulePostHealthKitGateStatusIfNeeded(store: SessionStore,
                                                         arguments: [String],
                                                         needsHealthKit: Bool,
                                                         needsResetRebuild: Bool) {
        guard needsHealthKit, arguments.contains("--whoop-log-gate-status") else { return }
        Task { @MainActor in
            let delaySeconds: UInt64 = needsResetRebuild ? 120 : 5
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            var statusArguments = arguments
            if !statusArguments.contains("--whoop-log-gate-status-delay-fired") {
                statusArguments.append("--whoop-log-gate-status-delay-fired")
            }
            WHOOPDebugLog("WHOOPDBG launch_exports_post_healthkit_gate_status status=scheduled delay_s=%llu", delaySeconds)
            store.logGateStatusFromLaunchIfRequested(arguments: statusArguments)
            WHOOPDebugLog("WHOOPDBG launch_exports_post_healthkit_gate_status status=completed")
        }
    }
}
