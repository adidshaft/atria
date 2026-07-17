import SwiftUI
import UIKit
import BackgroundTasks
import AppIntents

enum AtriaSceneResumePolicy {
    static let inactiveCheckpointDelay: TimeInterval = 1.5

    /// `.inactive` is commonly only the app-switch animation, Control Center,
    /// or a system alert. Durable work belongs either after the state remains
    /// inactive for a bounded grace period or on the real background edge.
    static func shouldRunInactiveCheckpoint(isStillInactive: Bool,
                                            elapsed: TimeInterval) -> Bool {
        isStillInactive && elapsed >= inactiveCheckpointDelay
    }

    static func shouldStopMotionMonitor(isBackground: Bool) -> Bool {
        isBackground
    }
}

final class AtriaAppDelegate: NSObject, UIApplicationDelegate {
    static var supportedOrientations: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Must happen before UIKit delivers a cold-launch notification
        // response. Scheduling-time registration is too late and can leave the
        // app open on its launch surface without applying the requested route.
        LocalNotificationScheduler.configureForApplicationLaunch()
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.supportedOrientations
    }
}

/// Stable ownership for the two long-lived runtime services. Keeping these
/// references in `@State` (rather than owning each service with `@StateObject`
/// at the `App` scene root) prevents every BLE and session-store publish from
/// invalidating the entire WindowGroup. Screens observe narrow projections or
/// leaf objects where their values are actually rendered.
@MainActor
private final class AtriaAppDependencies {
    let ble: AtriaBLEManager
    let store: SessionStore
    let workoutRouteRecorder: AtriaWorkoutRouteRecorder
    let workoutRuntime: AtriaWorkoutRuntime

    init() {
        let store = SessionStore()
        // A retained restore marker means canonical files may disagree. Do not
        // start any producer that could append new evidence until recovery can
        // resolve that transaction on a later launch.
        if !store.restoreInitializationBlocked {
            // Queue the tiny crash-recovery hydration before CoreBluetooth
            // starts; later BLE policy reads remain lock-only.
            AtriaPendingWorkoutIntentStore.shared.beginPreparing()
        }
        let ble = AtriaBLEManager(startsBluetooth: !store.restoreInitializationBlocked)
        let workoutRouteRecorder = AtriaWorkoutRouteRecorder()
        let workoutRuntime = AtriaWorkoutRuntime(ble: ble,
                                                 store: store,
                                                 routeRecorder: workoutRouteRecorder)
        if !store.restoreInitializationBlocked {
            ble.onSessionEnd = { [store] saved in store.add(saved) }
            ble.onSessionEndDurably = { [store] saved in
                guard store.add(saved) else { return false }
                return await withCheckedContinuation { continuation in
                    store.flushScheduledPersistenceAsync(reason: "ble_session_boundary") { succeeded in
                        continuation.resume(returning: succeeded)
                    }
                }
            }
            ble.onSessionCheckpoint = { [store] saved in store.checkpoint(saved) }
        }
        self.ble = ble
        self.store = store
        self.workoutRouteRecorder = workoutRouteRecorder
        self.workoutRuntime = workoutRuntime
        if !store.restoreInitializationBlocked {
            AppDependencyManager.shared.add(
                dependency: AtriaLiveWorkoutCommandHandler { [workoutRuntime] action, startedAt, issuedAt in
                    await workoutRuntime.handleLiveActivityCommand(
                        action,
                        workoutStartedAt: startedAt,
                        issuedAt: issuedAt
                    )
                }
            )
        }
    }
}

private final class AtriaBackgroundTaskCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func complete(_ task: BGTask, success: Bool) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        task.setTaskCompleted(success: success)
    }
}

@main
struct AtriaApp: App {
    private static let appRefreshTaskIdentifier = "com.adidshaft.atria.refresh"
    private static let processingTaskIdentifier = "com.adidshaft.atria.processing"

    private enum SceneDefaults {
        static let phase = "atria.scene.phase"
        static let reason = "atria.scene.reason"
        static let updatedAt = "atria.scene.updatedAt"
        static let lastActiveAt = "atria.scene.lastActiveAt"
        static let lastInactiveAt = "atria.scene.lastInactiveAt"
        static let lastBackgroundAt = "atria.scene.lastBackgroundAt"
        static let fastLaunchAt = "atria.scene.fastLaunchAt"
        static let applicationState = "atria.scene.applicationState"
        static let lastDidBecomeActiveAt = "atria.scene.lastDidBecomeActiveAt"
        static let lastWillEnterForegroundAt = "atria.scene.lastWillEnterForegroundAt"
    }

    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AtriaAppDelegate.self) private var appDelegate
    @State private var dependencies: AtriaAppDependencies
    @State private var didScheduleLaunchWork = false
    @State private var inactiveFlushTask: Task<Void, Never>?
    @State private var foregroundBLETransitionTask: Task<Void, Never>?
    @State private var notificationMaintenanceTask: Task<Void, Never>?
    private let launchStartedAt = Date()

    private var ble: AtriaBLEManager { dependencies.ble }
    private var store: SessionStore { dependencies.store }

    init() {
        let dependencies = AtriaAppDependencies()
        _dependencies = State(initialValue: dependencies)
        Self.registerBackgroundTasks(store: dependencies.store, ble: dependencies.ble)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if store.restoreInitializationBlocked {
                    ZStack {
                        Color(.systemBackground).ignoresSafeArea()
                        VStack(spacing: 12) {
                            Image(systemName: "externaldrive.badge.exclamationmark")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(.orange)
                            Text("Atria needs recovery")
                                .font(.title3.weight(.semibold))
                            Text("Your health history is protected. Reopen Atria to retry the interrupted restore.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 300)
                        }
                        .padding(24)
                    }
                } else {
                    ContentView(ble: ble,
                                store: store,
                                workoutRouteRecorder: dependencies.workoutRouteRecorder)
                }
            }
                .onAppear {
                    guard !didScheduleLaunchWork else { return }
                    didScheduleLaunchWork = true
                    guard !store.restoreInitializationBlocked else {
                        AtriaDebugLog("ATRIADBG app_launch status=blocked reason=restore_marker_retained")
                        return
                    }
                    dependencies.workoutRuntime.schedulePendingActionReplay()
                    recordScenePhase("appear", reason: "content_on_appear")
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
                    guard !store.restoreInitializationBlocked else { return }
                    switch phase {
                    case .background:
                        foregroundBLETransitionTask?.cancel()
                        foregroundBLETransitionTask = nil
                        recordScenePhase("background", reason: "scene_background")
                        AtriaStrapCalibrationArchive.shared.flush()
                        inactiveFlushTask?.cancel()
                        inactiveFlushTask = nil
                        ble.handleSceneBackgroundTransition(reason: "scene_background",
                                                            rest: store.baseline.restingInt ?? 60,
                                                            maxHR: store.profile.maxHR,
                                                            flushRealtimeState: false)
                        performSceneBackgroundMaintenance(reason: "scene_background")
                    case .inactive:
                        foregroundBLETransitionTask?.cancel()
                        foregroundBLETransitionTask = nil
                        recordScenePhase("inactive", reason: "scene_inactive")
                        AtriaStrapCalibrationArchive.shared.flush()
                        // Inactive is often a short transient state during gestures,
                        // alerts, and multitasking transitions. Keep the BLE manager in
                        // its current mode here; true backgrounding is handled by the
                        // `.background` case. Flipping modes on every app-switch gesture
                        // can restart long-wear supervision while the app is still live.
                        inactiveFlushTask?.cancel()
                        inactiveFlushTask = Task { @MainActor in
                            let startedAt = Date()
                            try? await Task.sleep(for: .seconds(AtriaSceneResumePolicy.inactiveCheckpointDelay))
                            guard !Task.isCancelled else { return }
                            guard AtriaSceneResumePolicy.shouldRunInactiveCheckpoint(
                                isStillInactive: scenePhase == .inactive,
                                elapsed: Date().timeIntervalSince(startedAt)
                            ) else { return }
                            ble.flushLifecycleRealtimeState(reason: "scene_inactive_deferred_checkpoint")
                            store.requestPersistenceFlush(reason: "scene_inactive_deferred")
                        }
                    case .active:
                        recordScenePhase("active", reason: "scene_active")
                        dependencies.workoutRuntime.schedulePendingActionReplay()
                        scheduleProductionNotificationMaintenance(reason: "scene_active")
                        inactiveFlushTask?.cancel()
                        inactiveFlushTask = nil
                        foregroundBLETransitionTask?.cancel()
                        foregroundBLETransitionTask = Task { @MainActor in
                            // Give SwiftUI one interactive frame before watchdog,
                            // defaults and service-repair orchestration. The
                            // existing CoreBluetooth subscription remains live.
                            await Task.yield()
                            try? await Task.sleep(for: .milliseconds(120))
                            guard !Task.isCancelled, scenePhase == .active else { return }
                            ble.handleInteractiveForeground(rest: store.baseline.restingInt ?? 60,
                                                           maxHR: store.profile.maxHR)
                            foregroundBLETransitionTask = nil
                        }
                    @unknown default:
                        foregroundBLETransitionTask?.cancel()
                        foregroundBLETransitionTask = nil
                        recordScenePhase("unknown", reason: "scene_unknown")
                        inactiveFlushTask?.cancel()
                        inactiveFlushTask = nil
                        ble.flushLifecycleRealtimeState(reason: "scene_unknown")
                        store.requestPersistenceFlush(reason: "scene_unknown")
                    }
                }
                .onChange(of: store.restoreInitializationBlocked) { _, blocked in
                    guard blocked else { return }
                    dependencies.workoutRuntime.suspendForCanonicalRestoreFailure()
                    ble.suspendForCanonicalRestoreFailure()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    guard !store.restoreInitializationBlocked else { return }
                    inactiveFlushTask?.cancel()
                    inactiveFlushTask = nil
                    AtriaStrapCalibrationArchive.shared.flush()
                    ble.flushLifecycleRealtimeState(reason: "app_will_terminate")
                    store.flushScheduledPersistence(reason: "app_will_terminate")
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    recordScenePhase(scenePhaseLabel(scenePhase), reason: "ui_will_enter_foreground")
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    recordScenePhase("active", reason: "ui_did_become_active")
                    inactiveFlushTask?.cancel()
                    inactiveFlushTask = nil
                    // `scenePhase == .active` is the single owner of foreground
                    // BLE restoration. Calling it again from this notification
                    // duplicated journal restore, watchdog setup and notification
                    // reassertion during the same app-switch transition.
                }
        }
    }

    private static func registerBackgroundTasks(store: SessionStore, ble: AtriaBLEManager) {
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
                                             ble: AtriaBLEManager,
                                             reason: String) {
        guard !store.restoreInitializationBlocked else {
            task.setTaskCompleted(success: false)
            AtriaDebugLog("ATRIADBG bg_task status=blocked reason=restore_marker_retained kind=%@", reason)
            return
        }
        scheduleBackgroundRefresh(reason: "\(reason)_reschedule")
        scheduleBackgroundProcessing(reason: "\(reason)_reschedule")
        let completion = AtriaBackgroundTaskCompletionGate()
        let work = Task { @MainActor in
            // A suspended app on a stable-but-idle link gets no BLE wakes, so
            // this window is the only chance to notice a silent stream or a
            // stale HR subscription before the user next opens the app.
            ble.performBackgroundLinkAudit(reason: reason)
            ble.flushActiveSessionJournal(reason: reason)
            // Settlement and durable state come first. BGAppRefresh may receive
            // only a short execution window, so it must never wait on backfill
            // before finalizing already-collected overnight evidence.
            let backupSucceeded = await withCheckedContinuation { continuation in
                store.performBackgroundMaintenance(reason: reason) { succeeded in
                    continuation.resume(returning: succeeded)
                }
            }
            guard !Task.isCancelled else {
                completion.complete(task, success: false)
                return
            }
            // Refresh the shared widget snapshot so the morning recovery number
            // is on the Lock Screen before the app is ever opened.
            WidgetSnapshotPublisher.publish(store: store, ble: ble, reason: reason)
            // Nightly research-sharing upload piggybacks the processing task
            // only (app-refresh's budget is too short for a build+network
            // round trip); gated to the sleep window and once per day inside.
            if reason == "bg_processing" {
                _ = ble.requestOfflineHistoricalSyncIfNeeded(reason: reason)
                await AtriaResearchUploadQueue.runNightlyIfDue(store: store, reason: reason)
            }
            guard !Task.isCancelled else {
                completion.complete(task, success: false)
                return
            }
            completion.complete(task, success: backupSucceeded)
        }
        task.expirationHandler = {
            work.cancel()
            completion.complete(task, success: false)
        }
    }

    private func scheduleBackgroundMaintenance(reason: String) {
        Self.scheduleBackgroundRefresh(reason: reason)
        Self.scheduleBackgroundProcessing(reason: reason)
    }

    private func performSceneBackgroundMaintenance(reason: String) {
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Atria background flush") {
            AtriaDebugLog("ATRIADBG background_flush status=expired reason=%@", reason)
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }

        let syncStarted = ble.requestOfflineHistoricalSyncIfNeeded(reason: "\(reason)_opportunistic")
        // Scene backgrounding is a durability boundary, but lifecycle callbacks
        // must never wait synchronously for JSON encoding or disk I/O. Keep the
        // UIKit task alive until both the session snapshot and active journal
        // have settled, allowing the return animation to remain interactive.
        var sessionFlushFinished = false
        var journalFlushFinished = false
        func finishBackgroundTaskIfReady() {
            guard sessionFlushFinished, journalFlushFinished else { return }
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
            AtriaDebugLog("ATRIADBG background_flush status=completed reason=%@ offline_sync_started=%d",
                          reason,
                          syncStarted ? 1 : 0)
        }
        store.flushScheduledPersistenceAsync(reason: reason) {
            sessionFlushFinished = true
            finishBackgroundTaskIfReady()
        }
        scheduleBackgroundMaintenance(reason: reason)
        ble.flushLifecycleRealtimeState(reason: reason) {
            journalFlushFinished = true
            finishBackgroundTaskIfReady()
        }
        AtriaDebugLog("ATRIADBG background_flush status=awaiting_durable_writes reason=%@ offline_sync_started=%d timeout_s=3",
                      reason,
                      syncStarted ? 1 : 0)
    }

    private static func scheduleBackgroundRefresh(reason: String) {
        let request = BGAppRefreshTaskRequest(identifier: appRefreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            AtriaDebugLog("ATRIADBG bg_task_schedule status=ok kind=refresh reason=%@", reason)
        } catch {
            AtriaDebugLog("ATRIADBG bg_task_schedule status=failed kind=refresh reason=%@ error=%@",
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
            AtriaDebugLog("ATRIADBG bg_task_schedule status=ok kind=processing reason=%@", reason)
        } catch {
            AtriaDebugLog("ATRIADBG bg_task_schedule status=failed kind=processing reason=%@ error=%@",
                          reason,
                          String(describing: error))
        }
    }

    @MainActor
    private func handleFastLaunchWork(arguments: [String]) {
        guard !store.restoreInitializationBlocked else { return }
        let isInteractiveForeground = isInteractiveForegroundLaunch()
        let fastLaunchReason = isInteractiveForeground ? "fast_launch_active" : "fast_launch_background"
        recordScenePhase(isInteractiveForeground ? "active" : scenePhaseLabel(scenePhase), reason: fastLaunchReason)
        logLaunchTiming(event: "fast_launch_begin")
        if isInteractiveForeground {
            ble.handleInteractiveForeground(rest: store.baseline.restingInt ?? 60,
                                            maxHR: store.profile.maxHR)
        } else {
            ble.applyPersistentLongWearModeIfNeeded(rest: store.baseline.restingInt ?? 60,
                                                    maxHR: store.profile.maxHR)
        }
        // Do not synchronously decode sessions.json and the latest backup on
        // the main actor immediately after the first frame. Deferred loading
        // already merges the durable store, and every add/checkpoint that can
        // arrive before it completes performs the same lossless reconciliation
        // before writing. The redundant fast-launch merge caused a visible
        // freeze when reopening Atria with a multi-megabyte wear history.
        LocalNotificationScheduler.scheduleFastLaunchHealthDeviationDebugFixtureIfRequested(arguments: arguments)
        LocalNotificationScheduler.scheduleFastLaunchWeeklyReportDebugFixtureIfRequested(arguments: arguments)
        LocalNotificationScheduler.scheduleFastLaunchMorningSummaryDebugFixtureIfRequested(arguments: arguments)
        store.generateWeeklyReportProductionFixtureFromLaunchIfRequested(arguments: arguments)
        scheduleProductionNotificationMaintenance(reason: fastLaunchReason, arguments: arguments)
        logLaunchTiming(event: "fast_launch_complete")
    }

    @MainActor
    private func scheduleProductionNotificationMaintenance(
        reason: String,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        notificationMaintenanceTask?.cancel()
        notificationMaintenanceTask = Task { @MainActor in
            await store.waitForDeferredSessionLoadIfNeeded()
            guard !Task.isCancelled, !store.restoreInitializationBlocked else { return }
            AtriaDebugLog("ATRIADBG notification_maintenance reason=%@", reason)
            LocalNotificationScheduler.scheduleFromLaunchIfRequested(store: store,
                                                                      ble: ble,
                                                                      arguments: arguments)
            notificationMaintenanceTask = nil
        }
    }

    private func isInteractiveForegroundLaunch() -> Bool {
        UIApplication.shared.applicationState == .active || scenePhase == .active
    }

    private func scenePhaseLabel(_ phase: ScenePhase) -> String {
        switch phase {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }

    private func recordScenePhase(_ phase: String, reason: String) {
        let now = Date().timeIntervalSince1970
        let defaults = UserDefaults.standard
        defaults.set(phase, forKey: SceneDefaults.phase)
        defaults.set(reason, forKey: SceneDefaults.reason)
        defaults.set(applicationStateLabel(UIApplication.shared.applicationState),
                     forKey: SceneDefaults.applicationState)
        defaults.set(now, forKey: SceneDefaults.updatedAt)
        switch phase {
        case "active":
            defaults.set(now, forKey: SceneDefaults.lastActiveAt)
        case "inactive":
            defaults.set(now, forKey: SceneDefaults.lastInactiveAt)
        case "background":
            defaults.set(now, forKey: SceneDefaults.lastBackgroundAt)
        default:
            break
        }
        if reason == "fast_launch" {
            defaults.set(now, forKey: SceneDefaults.fastLaunchAt)
        }
        if reason == "ui_did_become_active" {
            defaults.set(now, forKey: SceneDefaults.lastDidBecomeActiveAt)
        } else if reason == "ui_will_enter_foreground" {
            defaults.set(now, forKey: SceneDefaults.lastWillEnterForegroundAt)
        }
        AtriaDebugLog("ATRIADBG scene_phase phase=%@ reason=%@", phase, reason)
    }

    private func applicationStateLabel(_ state: UIApplication.State) -> String {
        switch state {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }

    @MainActor
    private func handleDeferredLaunchWork(arguments: [String]) {
        guard !store.restoreInitializationBlocked else { return }
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

        let requestedLaunchDiagnostics = arguments.contains("--atria-log-baseline")
            || arguments.contains("--atria-log-collection-health")
            || arguments.contains("--atria-log-gate-readiness")
            || arguments.contains("--atria-log-activity-detections")
            || arguments.contains("--atria-log-daily-rollups")
            || arguments.contains("--atria-log-daily-rollups-deep")
            || arguments.contains("--atria-log-workout-preflight")
            || arguments.contains("--atria-log-strain-validation")
            || arguments.contains("--atria-verify-sleep")
            || arguments.contains("--atria-schedule-sleep-validation")
            || arguments.contains("--atria-verify-workout-label")
            || arguments.contains("--atria-schedule-workout-validation")
            || arguments.contains("--atria-log-trends")
            || arguments.contains("--atria-log-trend-summaries")
            || arguments.contains("--atria-backup-sessions")
            || arguments.contains("--atria-write-session-backup")
            || arguments.contains("--atria-verify-backup")
            || arguments.contains("--atria-verify-session-backup")
            || arguments.contains("--atria-restore-backup")
            || arguments.contains("--atria-log-gate-status")
            || arguments.contains("--atria-export-rr-reference-package")
            || arguments.contains("--atria-export-rr-reference-ui-package")
            || arguments.contains("--atria-export-hr-reference-package")
            || arguments.contains("--atria-export-hr-reference-ui-package")
            || arguments.contains("--atria-export-raw-package")
            || arguments.contains("--atria-validate-rr-reference")
            || arguments.contains("--atria-validate-hr-reference")
            || arguments.contains("--atria-clear-reference-inputs")
            || arguments.contains("--atria-healthkit-export")
            || arguments.contains("--atria-healthkit-reference-audit")
            || arguments.contains("--atria-healthkit-reset-rebuild-atria-hr")
            || arguments.contains("--atria-analytics-calibration-audit")
            || arguments.contains("--atria-confirm-best-workout-candidate")
            || arguments.contains("--atria-confirm-workout-window")
            || arguments.contains("--atria-confirm-best-sleep-candidate")
            || arguments.contains("--atria-schedule-notifications")
            || arguments.contains("--atria-test-health-deviation-notification")
            || arguments.contains("--atria-test-weekly-report-notification")
            || arguments.contains("--atria-test-weekly-report-production-maintenance")
            || arguments.contains("--atria-test-morning-summary-notification")
            || arguments.contains("--atria-test-morning-summary-toggle-off")
            || arguments.contains("--atria-test-notification")
        guard requestedLaunchDiagnostics else {
            logLaunchTiming(event: "deferred_launch_complete")
            return
        }

        if arguments.contains("--atria-export-raw-package") {
            store.scheduleRawDataPackageFromLaunchIfRequested(arguments: arguments)
        }

        store.queueSessionBackupAfterDeferredLoadFromLaunchIfRequested(arguments: arguments)
        Task { @MainActor in
            await store.waitForDeferredSessionLoadIfNeeded()
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
            store.restoreLatestSessionBackupFromLaunchIfRequested(arguments: arguments)
            store.logGateStatusFromLaunchIfRequested(arguments: arguments)
            logAnalyticsCalibrationAuditIfRequested(arguments: arguments)
            scheduleLaunchExportsIfRequested(store: store, arguments: arguments)
            LocalNotificationScheduler.scheduleFromLaunchIfRequested(store: store, ble: ble)
            WidgetSnapshotPublisher.publishFromLaunchIfRequested(store: store, ble: ble)
            logLaunchTiming(event: "deferred_launch_complete")
        }
    }

    private func shouldRunDeferredLaunchWork(arguments: [String]) -> Bool {
        if hasRequestedDeferredLaunchWork(arguments: arguments) {
            return true
        }
        return UIApplication.shared.applicationState == .background
    }

    private func hasRequestedDeferredLaunchWork(arguments: [String]) -> Bool {
        arguments.contains { argument in
            guard argument.hasPrefix("--atria-") else { return false }
            return argument != "--atria-enable-debug-logs"
        }
    }

    private func logAnalyticsCalibrationAuditIfRequested(arguments: [String]) {
        guard arguments.contains("--atria-analytics-calibration-audit") else { return }
        let numericChecks = AtriaAnalytics.CalibrationExamples.numericChecks
        let labelChecks = AtriaAnalytics.CalibrationExamples.labelChecks
        for check in numericChecks {
            AtriaDebugLog("ATRIADBG analytics_calibration_check kind=numeric name=%@ actual=%.3f expected=%.3f tolerance=%.3f passed=%d",
                          check.name,
                          check.actual,
                          check.expected,
                          check.tolerance,
                          check.passed ? 1 : 0)
        }
        for check in labelChecks {
            AtriaDebugLog("ATRIADBG analytics_calibration_check kind=label name=%@ actual=%@ expected=%@ passed=%d",
                          check.name,
                          check.actual,
                          check.expected,
                          check.passed ? 1 : 0)
        }
        AtriaDebugLog("ATRIADBG analytics_calibration_audit status=%@ numeric_checks=%d label_checks=%d",
                      AtriaAnalytics.CalibrationExamples.allPassed ? "ok" : "failed",
                      numericChecks.count,
                      labelChecks.count)
    }

    private func logLaunchTiming(event: String) {
        let elapsedMS = Int(Date().timeIntervalSince(launchStartedAt) * 1000)
        AtriaDebugLog("ATRIADBG launch_timing event=%@ elapsed_ms=%d scene=%@",
                      event,
                      elapsedMS,
                      String(describing: scenePhase))
    }

    @MainActor
    private func scheduleLaunchExportsIfRequested(store: SessionStore, arguments: [String]) {
        let needsRR = arguments.contains("--atria-export-rr-reference-package")
        let needsRRUI = arguments.contains("--atria-export-rr-reference-ui-package")
        let needsHR = arguments.contains("--atria-export-hr-reference-package")
        let needsHRUI = arguments.contains("--atria-export-hr-reference-ui-package")
        let needsRawExport = arguments.contains("--atria-export-raw-package")
        let needsRRValidation = arguments.contains("--atria-validate-rr-reference")
        let needsHRValidation = arguments.contains("--atria-validate-hr-reference")
        let needsReferenceClear = arguments.contains("--atria-clear-reference-inputs")
        let needsHealthKit = arguments.contains("--atria-healthkit-export")
        let needsHealthKitAudit = arguments.contains("--atria-healthkit-reference-audit")
        let needsHealthKitResetRebuild = arguments.contains("--atria-healthkit-reset-rebuild-atria-hr")
        let needsWorkoutConfirm = arguments.contains("--atria-confirm-best-workout-candidate")
        let needsWorkoutWindowConfirm = arguments.contains("--atria-confirm-workout-window")
        let needsSleepConfirm = arguments.contains("--atria-confirm-best-sleep-candidate")
        guard needsRR || needsRRUI || needsHR || needsHRUI || needsRawExport || needsRRValidation || needsHRValidation || needsReferenceClear || needsHealthKit || needsHealthKitAudit || needsHealthKitResetRebuild || needsWorkoutConfirm || needsWorkoutWindowConfirm || needsSleepConfirm else { return }
        AtriaDebugLog("ATRIADBG launch_exports status=scheduled rr_reference=%d rr_reference_ui=%d hr_reference=%d hr_reference_ui=%d raw_export=%d rr_reference_validation=%d hr_reference_validation=%d reference_clear=%d healthkit=%d healthkit_reference_audit=%d healthkit_reset_rebuild=%d workout_confirm=%d sleep_confirm=%d",
                      needsRR ? 1 : 0,
                      needsRRUI ? 1 : 0,
                      needsHR ? 1 : 0,
                      needsHRUI ? 1 : 0,
                      needsRawExport ? 1 : 0,
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
            let rawExportURL = store.exportRawDataPackageFromLaunchIfRequested(arguments: arguments)
            if needsRawExport, rawExportURL == nil {
                scheduleRawExportRetryIfNeeded(store: store, arguments: arguments)
            }
            store.validateHRReferenceFromLaunchIfRequested(arguments: arguments)
            store.validateRRReferenceFromLaunchIfRequested(arguments: arguments)
            store.resetAndRebuildHealthKitHeartRateFromLaunchIfRequested(arguments: arguments)
            store.confirmBestWorkoutCandidateFromLaunchIfRequested(arguments: arguments)
            store.confirmWorkoutWindowFromLaunchIfRequested(arguments: arguments)
            store.confirmBestSleepCandidateFromLaunchIfRequested(arguments: arguments)
            store.exportHealthKitFromLaunchIfRequested(arguments: arguments)
            store.auditHealthKitHRReferenceFromLaunchIfRequested(arguments: arguments)
            schedulePostHealthKitGateStatusIfNeeded(store: store,
                                                    arguments: arguments,
                                                    needsHealthKit: needsHealthKit || needsHealthKitAudit || needsHealthKitResetRebuild,
                                                    needsResetRebuild: needsHealthKitResetRebuild)
            AtriaDebugLog("ATRIADBG launch_exports status=completed rr_reference=%d rr_reference_ui=%d hr_reference=%d hr_reference_ui=%d raw_export=%d rr_reference_validation=%d hr_reference_validation=%d reference_clear=%d healthkit=%d healthkit_reference_audit=%d healthkit_reset_rebuild=%d workout_confirm=%d sleep_confirm=%d",
                          needsRR ? 1 : 0,
                          needsRRUI ? 1 : 0,
                          needsHR ? 1 : 0,
                          needsHRUI ? 1 : 0,
                          needsRawExport ? 1 : 0,
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
    private func scheduleRawExportRetryIfNeeded(store: SessionStore, arguments: [String]) {
        guard arguments.contains("--atria-export-raw-package") else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            AtriaDebugLog("ATRIADBG raw_export_launch_retry status=attempt")
            let exportURL = store.exportRawDataPackageFromLaunchIfRequested(arguments: arguments)
            AtriaDebugLog("ATRIADBG raw_export_launch_retry status=%@",
                          exportURL == nil ? "failed" : "ok")
        }
    }

    @MainActor
    private func schedulePostHealthKitGateStatusIfNeeded(store: SessionStore,
                                                         arguments: [String],
                                                         needsHealthKit: Bool,
                                                         needsResetRebuild: Bool) {
        guard needsHealthKit, arguments.contains("--atria-log-gate-status") else { return }
        Task { @MainActor in
            let delaySeconds: UInt64 = needsResetRebuild ? 120 : 5
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            var statusArguments = arguments
            if !statusArguments.contains("--atria-log-gate-status-delay-fired") {
                statusArguments.append("--atria-log-gate-status-delay-fired")
            }
            AtriaDebugLog("ATRIADBG launch_exports_post_healthkit_gate_status status=scheduled delay_s=%llu", delaySeconds)
            store.logGateStatusFromLaunchIfRequested(arguments: statusArguments)
            AtriaDebugLog("ATRIADBG launch_exports_post_healthkit_gate_status status=completed")
        }
    }
}
