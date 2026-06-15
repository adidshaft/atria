import SwiftUI
import UIKit

@main
struct WhoopAppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var ble: WhoopBLEManager
    @StateObject private var store: SessionStore

    init() {
        let ble = WhoopBLEManager()
        let store = SessionStore()
        ble.onSessionEnd = { [store] saved in store.add(saved) }
        ble.onSessionCheckpoint = { [store] saved in store.checkpoint(saved) }
        _ble = StateObject(wrappedValue: ble)
        _store = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
                .environmentObject(store)
                .onAppear {
                    let launchArguments = ProcessInfo.processInfo.arguments
                    store.restoreLatestSessionBackupFromLaunchIfRequested()
                    store.completeOnboardingFromLaunchIfRequested()
                    store.logBaselineMaturityFromLaunchIfRequested()
                    store.logCollectionHealthFromLaunchIfRequested(arguments: launchArguments)
                    store.logGateReadinessFromLaunchIfRequested(arguments: launchArguments)
                    ble.applyLaunchAutomation()
                    ble.applyPersistentLongWearModeIfNeeded(rest: store.baseline.restingInt ?? 60,
                                                            maxHR: store.profile.maxHR)
                    ble.scheduleLiveWorkoutDiagnosticsIfRequested(rest: store.baseline.restingInt ?? 60,
                                                                  maxHR: store.profile.maxHR)
                    ble.scheduleWorkoutAutoSaveIfRequested(rest: store.baseline.restingInt ?? 60,
                                                           maxHR: store.profile.maxHR)
                    store.logActivityDetectionsFromLaunchIfRequested()
                    store.logDailyRollupsFromLaunchIfRequested()
                    store.logWorkoutPreflightFromLaunchIfRequested()
                    store.logStrainValidationFromLaunchIfRequested()
                    store.scheduleSleepValidationFromLaunchIfRequested()
                    store.scheduleWorkoutValidationFromLaunchIfRequested()
                    store.logTrendSummariesFromLaunchIfRequested()
                    store.writeSessionBackupFromLaunchIfRequested()
                    store.verifyLatestSessionBackupFromLaunchIfRequested()
                    store.logGateStatusFromLaunchIfRequested()
                    scheduleLaunchExportsIfRequested(store: store, arguments: launchArguments)
                    LocalNotificationScheduler.scheduleFromLaunchIfRequested(store: store, ble: ble)
                    WidgetSnapshotPublisher.publishFromLaunchIfRequested(store: store, ble: ble)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        ble.flushActiveSessionJournal(reason: "scene_background")
                    case .inactive:
                        ble.flushActiveSessionJournal(reason: "scene_inactive")
                    case .active:
                        break
                    @unknown default:
                        ble.flushActiveSessionJournal(reason: "scene_unknown")
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    ble.flushActiveSessionJournal(reason: "app_will_terminate")
                }
        }
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
        NSLog("WHOOPDBG launch_exports status=scheduled rr_reference=%d rr_reference_ui=%d hr_reference=%d hr_reference_ui=%d rr_reference_validation=%d hr_reference_validation=%d reference_clear=%d healthkit=%d healthkit_reference_audit=%d healthkit_reset_rebuild=%d workout_confirm=%d sleep_confirm=%d",
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
            NSLog("WHOOPDBG launch_exports status=completed rr_reference=%d rr_reference_ui=%d hr_reference=%d hr_reference_ui=%d rr_reference_validation=%d hr_reference_validation=%d reference_clear=%d healthkit=%d healthkit_reference_audit=%d healthkit_reset_rebuild=%d workout_confirm=%d sleep_confirm=%d",
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
            NSLog("WHOOPDBG launch_exports_post_healthkit_gate_status status=scheduled delay_s=%llu", delaySeconds)
            store.logGateStatusFromLaunchIfRequested(arguments: statusArguments)
            NSLog("WHOOPDBG launch_exports_post_healthkit_gate_status status=completed")
        }
    }
}
