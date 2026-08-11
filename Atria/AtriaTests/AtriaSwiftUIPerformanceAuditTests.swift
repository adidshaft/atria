import XCTest
import UIKit
import Combine
@testable import Atria

private final class AtriaTestLockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Element] = []

    func append(_ value: Element) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class AtriaHomePresentationRevisionProbe: ObservableObject {
    @Published var revision = 0
}

final class AtriaSwiftUIPerformanceAuditTests: XCTestCase {
    private func appSource(_ relativePath: String) throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")
        return try String(contentsOf: appURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testHistoricalIngressCacheNeverSynchronizesOnMainActorHotPath() throws {
        let spool = try appSource("AtriaWhoop4HistoricalIngressSpool.swift")
        let appendStart = try XCTUnwrap(spool.range(of: "func append(_ event: Event) throws"))
        let popStart = try XCTUnwrap(spool.range(
            of: "func popFirst() throws",
            range: appendStart.upperBound..<spool.endIndex
        ))
        let createStart = try XCTUnwrap(spool.range(of: "private func create() throws"))
        let reopenStart = try XCTUnwrap(spool.range(
            of: "private func reopen() throws",
            range: createStart.upperBound..<spool.endIndex
        ))
        let encodeStart = try XCTUnwrap(spool.range(
            of: "private func encode(_ event: Event) throws",
            range: reopenStart.upperBound..<spool.endIndex
        ))
        for body in [
            String(spool[appendStart.lowerBound..<popStart.lowerBound]),
            String(spool[createStart.lowerBound..<reopenStart.lowerBound]),
            String(spool[reopenStart.lowerBound..<encodeStart.lowerBound]),
        ] {
            XCTAssertFalse(
                body.contains(".synchronize()"),
                "Non-authoritative ingress cache I/O must not fsync on the BLE/MainActor path"
            )
        }

        let manager = try appSource("AtriaBLEManager.swift")
        let finishStart = try XCTUnwrap(manager.range(
            of: "private func finishOfflineHistoricalSync("
        ))
        let finalizeStart = try XCTUnwrap(manager.range(
            of: "private func finalizeOfflineHistoricalSyncAfterLiveRestoration(",
            range: finishStart.upperBound..<manager.endIndex
        ))
        let finish = String(
            manager[finishStart.lowerBound..<finalizeStart.lowerBound]
        )
        XCTAssertFalse(finish.contains("historicalIngressSpool?.synchronize()"))
    }

    func testAutomaticSessionBackupUsesCoalescingOffMainWorker() throws {
        let sessions = try appSource("Sessions.swift")
        let start = try XCTUnwrap(sessions.range(of: "private func writeAutomaticSessionBackup("))
        let end = try XCTUnwrap(sessions.range(of: "func verifyLatestSessionBackupFromLaunchIfRequested",
                                              range: start.upperBound..<sessions.endIndex))
        let automaticBackup = String(sessions[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(automaticBackup.contains("sessionBackupWorker.enqueueLatest(request)"))
        XCTAssertFalse(automaticBackup.contains("writeSessionBackup(label:"),
                       "Automatic session/profile/workout saves must never encode a full backup on MainActor")
        XCTAssertTrue(sessions.contains("private enum SessionBackupWriter"))
        XCTAssertTrue(sessions.contains("rawExport: nil"),
                      "Schema 4 backups must regenerate raw rows from canonical sessions")
        XCTAssertFalse(sessions.contains("AtriaRawExport.hrRows(sessions: request.sessions)"),
                       "Backups must not duplicate every HR/RR sample as expanded strings")
    }

    func testBackgroundTaskWaitsForDurableBackupWorkerCompletion() throws {
        let app = try appSource("AtriaApp.swift")
        let sessions = try appSource("Sessions.swift")
        XCTAssertTrue(app.contains("let backupSucceeded = await withCheckedContinuation"))
        XCTAssertTrue(app.contains("store.performBackgroundMaintenanceAsynchronously(reason: reason) { succeeded in"))
        XCTAssertTrue(sessions.contains("flushScheduledPersistenceAsync(reason: \"\\(reason)_persistence\")"))
        XCTAssertTrue(sessions.contains("persistenceAlreadyFlushed: true"))
        XCTAssertTrue(app.contains("success: backupSucceeded"))
        XCTAssertTrue(app.contains("&& historicalRecoverySucceeded"))
        XCTAssertTrue(app.contains("&& recoveredPublicationSucceeded"))
    }

    func testSettingsManualBackupUsesWorkerWithoutBlockingMainActor() throws {
        let settings = try appSource("AtriaSettingsView.swift")
        let home = try appSource("AtriaHomeView.swift")
        let start = try XCTUnwrap(settings.range(of: "private func startBackup("))
        let end = try XCTUnwrap(settings.range(of: "private func handleBackupImport(",
                                               range: start.upperBound..<settings.endIndex))
        let action = String(settings[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(home.contains("store.writeSessionBackupAsync(label: \"settings\", completion: completion)"))
        XCTAssertFalse(home.contains("store.writeSessionBackup(label: \"settings\")"),
                       "The Settings button must never synchronously encode and write on MainActor")
        XCTAssertTrue(settings.contains("@State private var backupOperationInProgress = false"))
        XCTAssertTrue(settings.contains("ProgressView()"))
        XCTAssertTrue(settings.contains(".disabled(backupOperationInProgress)"))
        XCTAssertTrue(action.contains("guard !backupOperationInProgress else { return }"))
        XCTAssertTrue(action.contains("writer { status in"))
        XCTAssertTrue(action.contains("backupOperationInProgress = false"))
        XCTAssertTrue(action.contains("Backup saved."))
        XCTAssertTrue(action.contains("Backup failed. Try again."))
    }

    @MainActor
    func testProfileDraftPersistenceCoalescesRapidEditsAndFlushesFinalValue() async {
        let initial = AthleteProfile(age: 30,
                                     measuredMaxHR: 190,
                                     maxHRSource: .measured,
                                     biologicalSex: .male,
                                     weightKg: 72,
                                     heightCm: 178,
                                     updated: nil,
                                     hasCompletedOnboarding: true)
        var persisted: [AthleteProfile] = []
        let coordinator = AtriaProfileDraftPersistenceCoordinator(
            initialProfile: initial,
            delay: .milliseconds(40),
            persist: { persisted.append($0) }
        )

        var edit = initial
        edit.age = 31
        coordinator.schedule(edit)
        edit.age = 32
        coordinator.schedule(edit)
        edit.age = 33
        coordinator.schedule(edit)

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(persisted.map(\.age), [33],
                       "Stepper repeats should produce one store refresh/backup, not one per tick")

        edit.age = 34
        coordinator.schedule(edit)
        coordinator.flush(edit)
        XCTAssertEqual(persisted.map(\.age), [33, 34],
                       "Dismiss/navigation must synchronously preserve the final edit")

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(persisted.map(\.age), [33, 34],
                       "A canceled debounce task must not duplicate the flushed write")
    }

    @MainActor
    func testProfileDraftPersistenceAdoptsExternalSourceWithoutWriteBack() async {
        let initial = AthleteProfile(age: 30,
                                     measuredMaxHR: 190,
                                     maxHRSource: .measured,
                                     updated: nil,
                                     hasCompletedOnboarding: true)
        var persisted: [AthleteProfile] = []
        let coordinator = AtriaProfileDraftPersistenceCoordinator(
            initialProfile: initial,
            delay: .milliseconds(30),
            persist: { persisted.append($0) }
        )

        var pending = initial
        pending.age = 31
        coordinator.schedule(pending)

        var external = initial
        external.age = 45
        XCTAssertEqual(coordinator.synchronizeFromSource(external), external)
        coordinator.schedule(external)
        try? await Task.sleep(for: .milliseconds(70))

        XCTAssertTrue(persisted.isEmpty,
                      "A profile loaded by the store must not echo back into persistence")
    }

    func testBackupVerifyAndRestorePreparationUseAsyncSerialUtilityWorker() throws {
        let sessions = try appSource("Sessions.swift")
        let settings = try appSource("AtriaSettingsView.swift")
        let onboarding = try appSource("AtriaOnboardingFlow.swift")
        let ioStart = try XCTUnwrap(sessions.range(of: "private nonisolated static func performSessionBackupIO"))
        let wrapperStart = try XCTUnwrap(sessions.range(of: "func verifyLatestSessionBackupFromLaunchIfRequested",
                                                       range: ioStart.upperBound..<sessions.endIndex))
        let io = String(sessions[ioStart.lowerBound..<wrapperStart.lowerBound])
        let restoreStart = try XCTUnwrap(sessions.range(of: "private func restoreSessionBackup(request:"))
        let applyStart = try XCTUnwrap(sessions.range(of: "private func applyPreparedSessionBackupRestore",
                                                     range: restoreStart.upperBound..<sessions.endIndex))
        let restoreCoordinator = String(sessions[restoreStart.lowerBound..<applyStart.lowerBound])

        XCTAssertTrue(sessions.contains("com.adidshaft.atria.session-store.backup-read"))
        XCTAssertTrue(sessions.contains("await sessionBackupIOWorker.performAsync"))
        XCTAssertTrue(io.contains("FileManager.default.contentsOfDirectory"))
        XCTAssertTrue(io.contains("sessionBackupPayloadData(at:"))
        XCTAssertTrue(io.contains("decodeSessionBackupEnvelope"))
        XCTAssertTrue(io.contains("makeBackupContentDigest"))
        XCTAssertTrue(io.contains("SessionBackupWriter.write(snapshot.safetyWriteRequest)"))
        XCTAssertFalse(restoreCoordinator.contains("Data(contentsOf:"))
        XCTAssertFalse(restoreCoordinator.contains("JSONDecoder"))
        XCTAssertFalse(restoreCoordinator.contains("SHA256"))
        XCTAssertFalse(restoreCoordinator.contains("writeSessionBackup(label:"))
        XCTAssertFalse(sessions.contains("defaults.synchronize()"))

        XCTAssertTrue(settings.contains("let onVerifyBackup: (() async -> SessionBackupStatus)?"))
        XCTAssertTrue(settings.contains("let onRestoreBackup: ((URL) async -> SessionBackupStatus?)?"))
        XCTAssertTrue(settings.contains("if let next = await onRestoreBackup(url)"))
        XCTAssertTrue(settings.contains("if didAccess { url.stopAccessingSecurityScopedResource() }"))
        XCTAssertTrue(onboarding.contains("let onRestoreBackup: ((URL) async -> Bool)?"))
        XCTAssertTrue(onboarding.contains("if await onRestoreBackup(url)"))
    }

    @MainActor
    func testRequiredAsyncSerialWorkerNeverPerformsOnMainThread() async {
        XCTAssertTrue(Thread.isMainThread)
        let worker = AtriaCoalescingSerialWorker<Int, Bool>(
            label: "com.adidshaft.atria.tests.backup-io",
            qos: .utility
        ) { _ in
            Thread.isMainThread
        }

        let performedOnMain = await worker.performAsync(1)

        XCTAssertFalse(performedOnMain,
                       "Archive enumeration/decompression/decode/hash must stay off MainActor")
    }

    func testForegroundResearchCatchUpProjectsSessionPointsOffMainActor() throws {
        let source = try appSource("AtriaResearchBundle.swift")
        let buildStart = try XCTUnwrap(source.range(of: "static func build(store: SessionStore"))
        let payloadStart = try XCTUnwrap(source.range(of: "nonisolated static func makePayload(",
                                                      range: buildStart.upperBound..<source.endIndex))
        let finishStart = try XCTUnwrap(source.range(of: "private nonisolated static func finishBuild(",
                                                     range: payloadStart.upperBound..<source.endIndex))
        let build = String(source[buildStart.lowerBound..<payloadStart.lowerBound])
        let payload = String(source[payloadStart.lowerBound..<finishStart.lowerBound])

        XCTAssertTrue(build.contains("let input = BuildInput("))
        XCTAssertTrue(build.contains("return await Task.detached(priority: .utility)"))
        XCTAssertTrue(build.contains("guard let payload = makePayload(input: input)"))
        XCTAssertFalse(build.contains("for session in"),
                       "Foreground resume must not expand the full HR archive on MainActor")
        XCTAssertFalse(build.contains("hrPoints.append"),
                       "Per-point research projection belongs inside the detached build")
        XCTAssertTrue(payload.contains("for session in input.sessions"))
        XCTAssertTrue(payload.contains("hrPoints.append"))
        XCTAssertTrue(payload.contains("rrPoints.append"))
    }

    func testResearchOutboxFilesystemWorkUsesSerialUtilityWorker() throws {
        let source = try appSource("AtriaResearchBundle.swift")
        let queueStart = try XCTUnwrap(source.range(of: "enum AtriaResearchUploadQueue"))
        let consentStart = try XCTUnwrap(source.range(
            of: "struct AtriaResearchConsentSheet",
            range: queueStart.upperBound..<source.endIndex
        ))
        let queue = String(source[queueStart.lowerBound..<consentStart.lowerBound])

        XCTAssertTrue(queue.contains(
            "AtriaCoalescingSerialWorker<OutboxOperation, OutboxOperationResult>"
        ))
        XCTAssertTrue(queue.contains("label: \"com.adidshaft.atria.research-outbox\""))
        XCTAssertTrue(queue.contains("qos: .utility"))
        XCTAssertTrue(queue.contains("await outboxWorker.performAsync(.stats)"))
        XCTAssertTrue(queue.contains("await outboxWorker.performAsync(.persist("))
        XCTAssertTrue(queue.contains("await outboxWorker.performAsync(.clear("))
        XCTAssertTrue(queue.contains("await outboxWorker.performAsync(.prune("))

        let directoryStart = try XCTUnwrap(queue.range(of: "static var outboxDirectory: URL"))
        let configuredStart = try XCTUnwrap(queue.range(
            of: "static var configuredEndpoint",
            range: directoryStart.upperBound..<queue.endIndex
        ))
        let directoryAccessor = String(queue[directoryStart.lowerBound..<configuredStart.lowerBound])
        XCTAssertFalse(directoryAccessor.contains("createDirectory"),
                       "Reading the outbox URL on MainActor must not perform filesystem work")
    }

    func testCoalescingSerialWorkerKeepsInFlightAndNewestPendingRequest() {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let completions = expectation(description: "all coalesced callers complete")
        completions.expectedFulfillmentCount = 3
        let performed = AtriaTestLockedArray<Int>()
        let outputs = AtriaTestLockedArray<Int>()
        let worker = AtriaCoalescingSerialWorker<Int, Int>(
            label: "com.adidshaft.atria.tests.coalescing-worker",
            qos: .userInteractive
        ) { input in
            performed.append(input)
            if input == 1 {
                firstStarted.signal()
                _ = releaseFirst.wait(timeout: .now() + 2)
            }
            return input * 10
        }

        worker.enqueueLatest(1) { output in
            outputs.append(output)
            completions.fulfill()
        }
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 1), .success)
        worker.enqueueLatest(2) { output in
            outputs.append(output)
            completions.fulfill()
        }
        worker.enqueueLatest(3) { output in
            outputs.append(output)
            completions.fulfill()
        }
        releaseFirst.signal()
        wait(for: [completions], timeout: 3)

        let performedSnapshot = performed.snapshot()
        let outputSnapshot = outputs.snapshot().sorted()
        XCTAssertEqual(performedSnapshot, [1, 3])
        XCTAssertEqual(outputSnapshot, [10, 30, 30])
    }

    func testOverviewRingDoesNotRunPerpetualDecorativeAnimation() throws {
        let source = try appSource("AtriaTriRing.swift")

        XCTAssertFalse(source.contains(".repeatForever("),
                       "The always-visible overview ring must become idle after its value reveal")
        XCTAssertFalse(source.contains("ambientPulseExpanded"))
        XCTAssertTrue(source.contains("animateToFinalValues()"),
                      "Real metric changes should retain their bounded value transition")
    }

    func testConnectionDiagnosisUsesOneShotDeadlineInsteadOfPermanentTimer() throws {
        let source = try appSource("AtriaHomeView.swift")

        XCTAssertFalse(source.contains("connectionDiagnosisTimer = Timer.publish"),
                       "An idle Home screen must not wake every five seconds just to age one diagnosis")
        XCTAssertFalse(source.contains(".onReceive(Self.connectionDiagnosisTimer)"))
        XCTAssertTrue(source.contains("@State private var connectionDiagnosisPromotionTask: Task<Void, Never>?"))
        XCTAssertTrue(source.contains("Task.sleep(for: .seconds(Self.connectionDiagnosisPersistenceDelay))"))
        XCTAssertTrue(source.contains("updateConnectionDiagnosisVisibility(reason: \"candidate_deadline\")"))
        XCTAssertTrue(source.contains("updateConnectionDiagnosisVisibility(reason: \"scene_foreground_deferred\")"),
                      "Returning from suspension must re-derive a candidate whose deadline was cancelled")
    }

    @MainActor
    func testLiveWorkoutMetricStorePublishesOnlyChangedLeafState() {
        let store = AtriaLiveWorkoutMetricStore()
        var publications = 0
        let cancellable = store.$state
            .dropFirst()
            .sink { _ in publications += 1 }

        store.publishIfChanged(.empty)
        var changed = AtriaLiveWorkoutMetricProjection.empty
        changed.strain = 1.4
        changed.hasSensorEvidence = true
        store.publishIfChanged(changed)
        store.publishIfChanged(changed)

        XCTAssertEqual(publications, 1)
        XCTAssertEqual(store.state, changed)
        withExtendedLifetime(cancellable) {}
    }

    func testRapidWorkoutMetricsAreObservedOnlyByPresentedWorkoutLeaf() throws {
        let home = try appSource("AtriaHomeView.swift")
        let workout = try appSource("AtriaLiveWorkoutView.swift")
        let rootStart = try XCTUnwrap(workout.range(of: "struct AtriaLiveWorkoutView: View"))
        let rootEnd = try XCTUnwrap(workout.range(of: "private struct AtriaLiveWorkoutBackdrop",
                                                  range: rootStart.upperBound..<workout.endIndex))
        let root = String(workout[rootStart.lowerBound..<rootEnd.lowerBound])

        XCTAssertTrue(home.contains("@State private var liveWorkoutMetricStore = AtriaLiveWorkoutMetricStore()"))
        XCTAssertFalse(home.contains("@State private var liveWorkoutMetricProjection"),
                       "Rapid workout metrics must not invalidate the complete Home hierarchy")
        XCTAssertTrue(home.contains("metricStore: liveWorkoutMetricStore"))
        XCTAssertTrue(home.contains("liveWorkoutMetricStore.publishIfChanged(metricProjection)"))
        XCTAssertTrue(root.contains("let metricStore: AtriaLiveWorkoutMetricStore"))
        XCTAssertFalse(root.contains("@ObservedObject var metricStore"),
                       "Rapid metric publications must not invalidate the whole workout root")
        XCTAssertFalse(root.contains("metricStore.state"),
                       "Only metric-dependent leaf hosts may read the published projection")
        XCTAssertTrue(root.contains("AtriaLiveWorkoutRouteMetricsHost(metricStore: metricStore"))
        XCTAssertTrue(root.contains("AtriaLiveWorkoutStrainGuidanceHost(metricStore: metricStore"))

        XCTAssertTrue(workout.contains("private struct AtriaLiveWorkoutRouteMetricsHost: View"))
        XCTAssertTrue(workout.contains("private struct AtriaLiveWorkoutStrainGuidanceHost: View"))
        // 2026-07-17: pin migrated 2 -> 3. The strap-motion transport status
        // indicator ships as its own narrow leaf host (see the dated comment on
        // AtriaLiveWorkoutMotionStatusHost), which is exactly the isolation this
        // audit enforces — the root still never observes the store.
        XCTAssertTrue(workout.contains("private struct AtriaLiveWorkoutMotionStatusHost: View"))
        XCTAssertEqual(workout.components(separatedBy: "@ObservedObject var metricStore: AtriaLiveWorkoutMetricStore").count - 1,
                       3,
                       "Exactly the route HUD, stationary guidance, and motion status hosts should observe rapid metrics")
    }

    func testHealthMonitorLiveMetricsUseDeduplicatedLeafProjection() throws {
        let health = try appSource("AtriaHealthScreen.swift")
        let screenStart = try XCTUnwrap(health.range(of: "struct AtriaHealthScreen: View"))
        let screenBody = String(health[screenStart.lowerBound...])

        XCTAssertTrue(health.contains("final class AtriaHealthMonitorLiveProjectionStore: ObservableObject"))
        XCTAssertTrue(health.contains("guard next != state else { return false }"),
                      "Unrelated live Hero changes must not republish the Health Monitor subtree")
        XCTAssertTrue(health.contains("private struct AtriaHealthMonitorLiveHost<Content: View>: View"))
        XCTAssertTrue(screenBody.contains("AtriaHealthMonitorLiveHost(liveStore: liveStore"))
        XCTAssertFalse(screenBody.contains("@ObservedObject var heroStore: AtriaHomeModel.HeroStore"),
                       "Live recovery changes must not invalidate every chart on the Health screen")
        XCTAssertFalse(screenBody.contains("@ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore"),
                       "Weekly Fitness Age completion should invalidate only its leaf cards")
        XCTAssertTrue(health.contains("private struct AtriaHealthFitnessAgeCardHost: View"))
        XCTAssertTrue(health.contains("@ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore"))
        XCTAssertTrue(screenBody.contains("AtriaHealthFitnessAgeCardHost(profileMetricsStore: profileMetricsStore)"))
        XCTAssertTrue(health.contains("private struct AtriaHealthspanDetailPresentationHost: View"))
        XCTAssertTrue(screenBody.contains("AtriaHealthspanDetailPresentationHost("),
                      "An already-open Healthspan screen must receive the completed weekly cache")
    }

    func testDecorativeDetailAnimationsPauseOutsideActiveScene() throws {
        let healthspan = try appSource("AtriaHealthspanDetailView.swift")
        let overview = try appSource("AtriaOverviewSections.swift")

        XCTAssertTrue(healthspan.contains("!reduceMotion && scenePhase == .active"))
        XCTAssertTrue(healthspan.contains(".animation(orbMotionEnabled ?"))
        XCTAssertTrue(overview.contains("private var motionEnabled: Bool"))
        XCTAssertTrue(overview.contains("!reduceMotion && scenePhase == .active"))
        XCTAssertTrue(overview.contains(".animation(motionEnabled ?"))
    }

    func testHomeBodyDoesNotValidateSleepReviewByLoadingActiveJournal() throws {
        let source = try appSource("AtriaHomeView.swift")
        let start = try XCTUnwrap(source.range(of: "private var hasPendingSleepReviewAction"))
        let end = try XCTUnwrap(source.range(of: "private var workoutReviewHoldStateForDisplay",
                                             range: start.upperBound..<source.endIndex))
        let property = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(property.contains("store.pendingSleepReviewNightForUI != nil"))
        XCTAssertFalse(property.contains("store.latestSleepReviewNightForUI("),
                       "A body evaluation must not synchronously load and rebuild the active journal")
    }

    func testActiveSessionRestorePreparesAndClearsJournalOffMainActor() throws {
        let manager = try appSource("AtriaBLEManager.swift")
        let journal = try appSource("ActiveSessionJournal.swift")
        let restoreStart = try XCTUnwrap(manager.range(of: "private func restoreActiveSessionJournalIfNeeded"))
        let restoreEnd = try XCTUnwrap(manager.range(of: "nonisolated static func shouldAcceptActiveSessionJournalRestore",
                                                     range: restoreStart.upperBound..<manager.endIndex))
        let restore = String(manager[restoreStart.lowerBound..<restoreEnd.lowerBound])
        let applyStart = try XCTUnwrap(manager.range(of: "private func applyPreparedActiveSessionJournalRestore"))
        let applyEnd = try XCTUnwrap(manager.range(of: "private func clearPreparedActiveSessionJournalIfUnchanged",
                                                   range: applyStart.upperBound..<manager.endIndex))
        let apply = String(manager[applyStart.lowerBound..<applyEnd.lowerBound])

        XCTAssertTrue(restore.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(restore.contains("Self.prepareActiveSessionJournalRestore("))
        XCTAssertTrue(restore.contains("await self?.applyPreparedActiveSessionJournalRestore("))
        XCTAssertFalse(apply.contains("ActiveSessionJournal.clear()"),
                       "Journal deletion may take the I/O lock and must never run on MainActor")
        XCTAssertTrue(manager.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(manager.contains("ActiveSessionJournal.clearIfUnchanged("))
        XCTAssertTrue(journal.contains("static func clearIfUnchanged("))
        XCTAssertTrue(journal.contains("guard let current = loadLocked()"),
                      "Async cleanup must atomically reject a newer live checkpoint")
    }

    func testWorkoutEndPreparesLargeJournalWindowOffMain() async throws {
        let windowStart = Date(timeIntervalSince1970: 1_900_000_000)
        let journalStart = windowStart.addingTimeInterval(-29_400)
        let journalPoints = (0...30_000).map {
            SavedSession.Point(t: Double($0), bpm: 82 + ($0 % 31))
        }
        let activeJournal = SavedSession(
            id: UUID(),
            start: journalStart,
            end: journalStart.addingTimeInterval(30_000),
            label: "Large active journal",
            points: journalPoints,
            hrv: nil
        )
        let oldSessions = (0..<120).map { index in
            let start = windowStart.addingTimeInterval(-Double(index + 2) * 86_400)
            return SavedSession(
                id: UUID(),
                start: start,
                end: start.addingTimeInterval(999),
                label: "Historical \(index)",
                points: (0..<1_000).map { SavedSession.Point(t: Double($0), bpm: 70) },
                hrv: nil
            )
        }
        let snapshot = workoutPreparationSnapshot(
            sessions: oldSessions,
            start: windowStart,
            end: windowStart.addingTimeInterval(600),
            revision: 41
        )

        let result = await Task.detached(priority: .utility) {
            let wasMainThread = pthread_main_np() != 0
            let prepared = SessionStore.prepareWorkoutWindowConfirmation(
                snapshot: snapshot,
                activeJournalSession: activeJournal
            )
            return (wasMainThread, prepared)
        }.value

        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1.fingerprint.canonicalSessionsRevision, 41)
        XCTAssertEqual(result.1.overlappingSessionCount, 1)
        XCTAssertEqual(result.1.points.count, 601,
                       "Only the exact inclusive workout window should cross back to MainActor")
        XCTAssertEqual(result.1.points.first?.t, 0)
        XCTAssertEqual(result.1.points.last?.t, 600)
        XCTAssertNotNil(result.1.readiness)
        XCTAssertNotNil(result.1.strain)
    }

    func testConcurrentWorkoutPreparationsRemainSnapshotIsolated() async {
        let start = Date(timeIntervalSince1970: 1_900_100_000)
        let first = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(119),
            label: "First snapshot",
            points: (0..<120).map { SavedSession.Point(t: Double($0), bpm: 96) },
            hrv: nil
        )
        let second = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(239),
            label: "Second snapshot",
            points: (0..<240).map { SavedSession.Point(t: Double($0), bpm: 104) },
            hrv: nil
        )
        let firstSnapshot = workoutPreparationSnapshot(
            sessions: [first],
            start: start,
            end: start.addingTimeInterval(300),
            revision: 8
        )
        let secondSnapshot = workoutPreparationSnapshot(
            sessions: [second],
            start: start,
            end: start.addingTimeInterval(300),
            revision: 9
        )

        async let firstResult = Task.detached(priority: .utility) {
            SessionStore.prepareWorkoutWindowConfirmation(
                snapshot: firstSnapshot,
                activeJournalSession: nil
            )
        }.value
        async let secondResult = Task.detached(priority: .utility) {
            SessionStore.prepareWorkoutWindowConfirmation(
                snapshot: secondSnapshot,
                activeJournalSession: nil
            )
        }.value
        let (preparedFirst, preparedSecond) = await (firstResult, secondResult)

        XCTAssertEqual(preparedFirst.fingerprint.canonicalSessionsRevision, 8)
        XCTAssertEqual(preparedFirst.points.count, 120)
        XCTAssertEqual(preparedFirst.readiness?.avgHR, 96)
        XCTAssertEqual(preparedSecond.fingerprint.canonicalSessionsRevision, 9)
        XCTAssertEqual(preparedSecond.points.count, 240)
        XCTAssertEqual(preparedSecond.readiness?.avgHR, 104)
    }

    func testWorkoutEndFlowAwaitsOffMainPreparationBeforePersistenceAndRecap() throws {
        let home = try appSource("AtriaHomeView.swift")
        let start = try XCTUnwrap(home.range(of: "private func endWorkoutSession(startedAt: Date,"))
        let end = try XCTUnwrap(home.range(of: "private func workoutShareSnapshot(",
                                           range: start.upperBound..<home.endIndex))
        let completion = String(home[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(completion.contains("await store.confirmWorkoutWindowForUIAsync(start: startedAt,"))
        XCTAssertFalse(completion.contains("store.confirmWorkoutWindowForUI(start: startedAt,"))
        XCTAssertLessThan(try XCTUnwrap(completion.range(of: "await finalIntent.persistTerminal()")?.lowerBound),
                          try XCTUnwrap(completion.range(of: "await store.confirmWorkoutWindowForUIAsync")?.lowerBound),
                          "Pending intent must become durable before asynchronous evidence preparation")
        XCTAssertLessThan(try XCTUnwrap(completion.range(of: "await store.confirmWorkoutWindowForUIAsync")?.lowerBound),
                          try XCTUnwrap(completion.range(of: "workoutEndNotice = .persisted")?.lowerBound),
                          "Sharing/recap must remain structurally downstream of canonical confirmation")
    }

    func testWorkoutMotionBoundaryDeadlineResumesWithoutAwaitingCancelledMarkerTask() throws {
        let home = try appSource("AtriaHomeView.swift")
        let helperStart = try XCTUnwrap(
            home.range(of: "private func synchronizedWorkoutMotionBoundary(")
        )
        let helperEnd = try XCTUnwrap(
            home.range(of: "private func makeWorkoutSession(",
                       range: helperStart.upperBound..<home.endIndex)
        )
        let helper = String(home[helperStart.lowerBound..<helperEnd.lowerBound])

        XCTAssertTrue(helper.contains("deadline.finish(nil)"))
        XCTAssertTrue(helper.contains("synchronization.cancel()"))
        XCTAssertFalse(helper.contains("await synchronization.value"),
                       "The UI deadline must not wait for the cancelled FIFO marker to unwind")

        let completionStart = try XCTUnwrap(
            home.range(of: "private func endWorkoutSession(startedAt: Date,")
        )
        let completionEnd = try XCTUnwrap(
            home.range(of: "private func workoutShareSnapshot(",
                       range: completionStart.upperBound..<home.endIndex)
        )
        let completion = String(home[completionStart.lowerBound..<completionEnd.lowerBound])
        XCTAssertTrue(completion.contains("await synchronizedWorkoutMotionBoundary()"))
        XCTAssertFalse(completion.contains("await syncTask.value"))
    }

    func testOlderWorkoutCompletionCannotClearNewerPendingIntent() throws {
        let suite = "AtriaSwiftUIPerformanceAuditTests.pending.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = pendingWorkoutIntent(start: Date(timeIntervalSince1970: 1_900_000_000))
        let newer = pendingWorkoutIntent(start: old.startedAt.addingTimeInterval(3_600))
        XCTAssertTrue(old.save(defaults: defaults))
        XCTAssertTrue(newer.save(defaults: defaults))

        XCTAssertFalse(AtriaPendingWorkoutIntent.clearIfUnchanged(old, defaults: defaults))
        XCTAssertEqual(AtriaPendingWorkoutIntent.load(defaults: defaults), newer)
        XCTAssertTrue(AtriaPendingWorkoutIntent.clearIfUnchanged(newer, defaults: defaults))
        XCTAssertNil(AtriaPendingWorkoutIntent.load(defaults: defaults))
    }

    func testLibraryPhotoPreparationDownsamplesBeforeSwiftUIState() async throws {
        let source = testImage(size: CGSize(width: 800, height: 600))
        let data = try XCTUnwrap(source.jpegData(compressionQuality: 0.9))

        let result = await AtriaSharePhotoPreparation.preparedImage(from: data,
                                                                    maximumPixelDimension: 128)
        let prepared = try XCTUnwrap(result)

        XCTAssertLessThanOrEqual(largestPixelDimension(of: prepared), 128)
        XCTAssertGreaterThan(largestPixelDimension(of: prepared), 0)
    }

    func testCameraPhotoPreparationUsesBoundedAsyncThumbnail() async throws {
        let source = testImage(size: CGSize(width: 640, height: 960))

        let result = await AtriaSharePhotoPreparation.preparedImage(from: source,
                                                                    maximumPixelDimension: 160)
        let prepared = try XCTUnwrap(result)

        XCTAssertLessThanOrEqual(largestPixelDimension(of: prepared), 160)
        XCTAssertGreaterThan(largestPixelDimension(of: prepared), 0)
    }

    func testHomeCoreLiveCadenceNeverRefreshesSavedArchiveAggregate() throws {
        let source = try appSource("AtriaHomeView.swift")
        let cadenceStart = try XCTUnwrap(source.range(
            of: "let throttledCoreLiveChanges = Publishers.MergeMany(["
        ))
        let cadenceEnd = try XCTUnwrap(source.range(
            of: "let pulseRateChanges = ble.$heartRate",
            range: cadenceStart.upperBound..<source.endIndex
        ))
        let cadence = String(source[cadenceStart.lowerBound..<cadenceEnd.lowerBound])
        let mergedInputsEnd = try XCTUnwrap(source.range(
            of: "])\n        .throttle(for: .milliseconds(400)",
            range: cadenceStart.upperBound..<cadenceEnd.lowerBound
        ))
        let mergedInputs = String(
            source[cadenceStart.lowerBound..<mergedInputsEnd.lowerBound]
        )
        XCTAssertTrue(cadence.contains("ble.$sessionSampleCount"))
        XCTAssertTrue(cadence.contains("self?.publishCoreLive()"))
        XCTAssertFalse(mergedInputs.contains("ble.$historicalRecoveryPresentation"),
                       "history progress must not join unrelated BLE CoreLive churn")
        XCTAssertTrue(cadence.contains(
            "ble.$historicalRecoveryPresentation\n            .removeDuplicates()\n            .dropFirst()"
        ))
        XCTAssertTrue(cadence.contains(
            "guard UIApplication.shared.applicationState == .active"
        ), "inactive terminal/progress state waits for one foreground catch-up")
        XCTAssertTrue(cadence.contains("Task { @MainActor [weak self] in"),
                      "the CoreLive read must occur after @Published willSet completes")
        XCTAssertFalse(cadence.contains("requestSavedAggregateRefresh"))
        XCTAssertFalse(cadence.contains("refreshSavedAggregate"))

        let foregroundStart = try XCTUnwrap(source.range(
            of: "private func handleHomeScenePhaseChange(_ phase: ScenePhase)"
        ))
        let foregroundEnd = try XCTUnwrap(source.range(
            of: "private func flushWorkoutRouteAtBackgroundBoundary()",
            range: foregroundStart.upperBound..<source.endIndex
        ))
        let foreground = String(
            source[foregroundStart.lowerBound..<foregroundEnd.lowerBound]
        )
        XCTAssertTrue(foreground.contains(
            "model.refreshHistoricalRecoveryPresentationForForeground()"
        ))
        XCTAssertFalse(foreground.contains("model.forceRefresh()"),
                       "the app-switch edge must not request archive/diagnostic work")

        let catchUpStart = try XCTUnwrap(source.range(
            of: "func refreshHistoricalRecoveryPresentationForForeground()"
        ))
        let catchUpEnd = try XCTUnwrap(source.range(
            of: "func refreshDailyGuidanceClock()",
            range: catchUpStart.upperBound..<source.endIndex
        ))
        let catchUp = String(source[catchUpStart.lowerBound..<catchUpEnd.lowerBound])
        let managerCatchUp = try XCTUnwrap(catchUp.range(
            of: "ble.catchUpHistoricalRecoveryProgressForForeground()"
        ))
        let corePublish = try XCTUnwrap(catchUp.range(of: "publishCoreLive()"))
        XCTAssertLessThan(managerCatchUp.lowerBound, corePublish.lowerBound,
                          "private background rows must publish before CoreLive reads them")
        XCTAssertFalse(catchUp.contains("requestSavedAggregateRefresh"))

        let publishStart = try XCTUnwrap(source.range(
            of: "private func publishCoreLive()"
        ))
        let publishEnd = try XCTUnwrap(source.range(
            of: "func refreshDurableStepReceipt()",
            range: publishStart.upperBound..<source.endIndex
        ))
        let publish = String(source[publishStart.lowerBound..<publishEnd.lowerBound])
        XCTAssertTrue(publish.contains("refreshLiveSessionDerivedIfNeeded()"))
        XCTAssertFalse(publish.contains("requestSavedAggregateRefresh"))
        XCTAssertFalse(publish.contains("makeSavedAggregateRefreshInput"))
        XCTAssertFalse(publish.contains("homeSavedAggregate("))
        XCTAssertFalse(publish.contains("observedHeartRateUnionSeconds("))
    }

    @MainActor
    func testHomeLivePresentationAuthoritySuppressesBackgroundBurstAndCatchesUpOnce() {
        var authority = AtriaHomeLivePresentationAuthority()
        let probe = AtriaHomePresentationRevisionProbe()
        var objectWillChangeCount = 0
        let cancellable = probe.objectWillChange.sink {
            objectWillChangeCount += 1
        }

        for _ in 0..<1_000 {
            if authority.admitsMutation(applicationIsActive: true) {
                probe.revision += 1
            }
        }

        XCTAssertFalse(authority.isActive)
        XCTAssertTrue(authority.hasSuppressedMutation)
        XCTAssertEqual(probe.revision, 0)
        XCTAssertEqual(objectWillChangeCount, 0)

        var catchUpCount = 0
        XCTAssertEqual(authority.transition(to: true), .catchUpLatest)
        XCTAssertFalse(authority.beginCatchUpIfAuthorized(
            applicationIsActive: false
        ), "UIApplication inactivity must remain a final publication fence")
        XCTAssertEqual(probe.revision, 0)
        let laterDataPublicationCount = 0
        if authority.beginCatchUpIfAuthorized(applicationIsActive: true) {
            catchUpCount += 1
            probe.revision += 1
        }
        XCTAssertEqual(laterDataPublicationCount, 0,
                       "didBecomeActive retry must recover without a later data publisher")
        XCTAssertEqual(authority.transition(to: true), .unchanged,
                       "Repeated active delivery must not duplicate the foreground catch-up")
        XCTAssertEqual(catchUpCount, 1)
        XCTAssertEqual(probe.revision, 1)
        XCTAssertEqual(objectWillChangeCount, 1)
        XCTAssertTrue(authority.isActive)
        XCTAssertFalse(authority.hasSuppressedMutation)
        XCTAssertFalse(authority.catchUpIsPending)
        XCTAssertFalse(authority.beginCatchUpIfAuthorized(
            applicationIsActive: true
        ), "one foreground edge consumes its catch-up exactly once")
        withExtendedLifetime(cancellable) {}
    }

    func testHomeLivePresentationGateOwnsOnlyObservableLiveFanout() throws {
        let home = try appSource("AtriaHomeView.swift")
        let handlerStart = try XCTUnwrap(home.range(
            of: "private func handleHomeScenePhaseChange(_ phase: ScenePhase)"
        ))
        let handlerEnd = try XCTUnwrap(home.range(
            of: "private func flushWorkoutRouteAtBackgroundBoundary()",
            range: handlerStart.upperBound..<home.endIndex
        ))
        let handler = String(home[handlerStart.lowerBound..<handlerEnd.lowerBound])
        let authorityEdge = try XCTUnwrap(handler.range(
            of: "model.setScenePresentationActive(phase == .active)"
        ))
        let edgeWork = try XCTUnwrap(handler.range(of: "updateMediaRefreshLoop()"))
        XCTAssertLessThan(authorityEdge.lowerBound, edgeWork.lowerBound,
                          "The inactive edge must revoke presentation before background work")

        let catchUpStart = try XCTUnwrap(home.range(
            of: "private func performLivePresentationCatchUp()"
        ))
        let catchUpEnd = try XCTUnwrap(home.range(
            of: "func forceRefresh()",
            range: catchUpStart.upperBound..<home.endIndex
        ))
        let catchUp = String(home[catchUpStart.lowerBound..<catchUpEnd.lowerBound])
        for required in [
            "synchronizeStressPresentationPublication()",
            "todaySessionProjectionStore.setPresentationActive(true)",
            "publishStatus()",
            "publishCoreLive()",
            "publishProfile()",
            "publishProfileMetrics()",
            "publishHeroPulse()",
            "publishPulseLive()",
            "publishCollectionLive()",
            "refreshHeroSnapshot()",
            "publishSnapshotIfNeeded(",
            "scheduleActivityProjectionRefresh()",
            "scheduleDirtyDiagnosticsAfterForegroundIfNeeded()",
        ] {
            XCTAssertEqual(catchUp.components(separatedBy: required).count - 1, 1,
                           "Foreground authority must perform one \(required) catch-up")
        }
        XCTAssertFalse(catchUp.contains("forceRefresh"))
        XCTAssertFalse(catchUp.contains("requestSavedAggregateRefresh"))
        XCTAssertFalse(catchUp.contains("loadDeferredDiagnostics"))
        XCTAssertFalse(catchUp.contains("requestActivityProjectionRefresh"))
        XCTAssertFalse(catchUp.contains("updateSharedStress"),
                       "foreground presentation must not newly ingest/persist stress")
        XCTAssertFalse(catchUp.contains("scheduleDeferredDiagnosticsRefresh"),
                       "archive diagnostics must remain deferred beyond the active edge")
        XCTAssertTrue(home.contains(
            "UIApplication.shared.applicationState == .active"
        ), "every Home mutation admission includes a final process-state fence")
        XCTAssertTrue(home.contains(
            "&& !AtriaHistoricalProjectionForegroundGate.isBackgrounded"
        ), "Home, Stress, and Today must share AtriaApp's pre-rollback gate")
        XCTAssertTrue(home.contains(
            "presentationPublishingIsActive: false"
        ), "Home's shared stress mirrors must start fail-closed before scene authority")
        XCTAssertTrue(home.contains(
            "AtriaTodaySessionProjectionStore(\n            store: store,\n            presentationIsActive: false"
        ), "Today's Home-owned projection must start fail-closed")

        let applicationRetryStart = try XCTUnwrap(home.range(
            of: "private func scheduleApplicationDidBecomeActivePresentationRetry()"
        ))
        let bindStart = try XCTUnwrap(home.range(
            of: "private func bind()",
            range: applicationRetryStart.upperBound..<home.endIndex
        ))
        let applicationRetry = String(
            home[applicationRetryStart.lowerBound..<bindStart.lowerBound]
        )
        XCTAssertTrue(applicationRetry.contains("DispatchQueue.main.async"),
                      "UIKit activation must only enqueue a bounded retry")
        XCTAssertTrue(applicationRetry.contains("self.applicationPresentationIsActive"))
        XCTAssertTrue(applicationRetry.contains("self.synchronizeStressPresentationPublication()"))
        XCTAssertTrue(applicationRetry.contains("self.todaySessionProjectionStore.setPresentationActive(true)"))
        XCTAssertTrue(applicationRetry.contains("self.attemptLivePresentationCatchUpIfNeeded()"))
        XCTAssertFalse(applicationRetry.contains("updateSharedStress"))
        XCTAssertFalse(applicationRetry.contains("requestSavedAggregateRefresh"))
        XCTAssertFalse(applicationRetry.contains("scheduleDeferredDiagnosticsRefresh"))

        let applicationObserverEnd = try XCTUnwrap(home.range(
            of: "let immediateStatusChanges",
            range: bindStart.upperBound..<home.endIndex
        ))
        let applicationObserver = String(
            home[bindStart.lowerBound..<applicationObserverEnd.lowerBound]
        )
        XCTAssertTrue(applicationObserver.contains("UIApplication.didBecomeActiveNotification"))
        XCTAssertTrue(applicationObserver.contains("didBecomeForegroundNotification"))
        XCTAssertTrue(applicationObserver.contains(
            "self?.scheduleApplicationDidBecomeActivePresentationRetry()"
        ))
        XCTAssertTrue(applicationObserver.contains(".store(in: &cancellables)"),
                      "activation observer lifetime must be owned by the Home model")

        for signature in [
            "private func publishStatus()",
            "private func publishCoreLive()",
            "private func publishHeroPulse()",
            "private func publishPulseLive()",
            "private func publishPulseSparkline()",
            "private func publishCollectionLive()",
            "private func publishProfile()",
            "private func publishProfileMetrics()",
            "private func refreshHeroSnapshot()",
            "private func publishHeroSnapshotIfNeeded(_ next: HeroSnapshot)",
            "private func publishSnapshotIfNeeded(_ next: Snapshot)",
            "private func publishHomeStatsIfNeeded(_ next: HomeStatsState)",
        ] {
            let start = try XCTUnwrap(home.range(of: signature))
            let prefixEnd = home.index(start.upperBound, offsetBy: 180,
                                       limitedBy: home.endIndex) ?? home.endIndex
            let prefix = String(home[start.lowerBound..<prefixEnd])
            XCTAssertTrue(prefix.contains(
                "guard admitsLivePresentationMutation() else { return }"
            ), "\(signature) must reject work before reading or mutating its live store")
        }

        let diagnosticsStart = try XCTUnwrap(home.range(
            of: "private func scheduleDeferredDiagnosticsRefresh()"
        ))
        let diagnosticsEnd = try XCTUnwrap(home.range(
            of: "private func refreshLiveSessionDerivedIfNeeded()",
            range: diagnosticsStart.upperBound..<home.endIndex
        ))
        let diagnostics = String(
            home[diagnosticsStart.lowerBound..<diagnosticsEnd.lowerBound]
        )
        XCTAssertTrue(diagnostics.contains(
            "guard livePresentationIsCurrentlyAuthorized else { return }"
        ))
        XCTAssertTrue(diagnostics.contains(
            "guard self.livePresentationIsCurrentlyAuthorized else"
        ), "a worker admitted in foreground must reject its stale background completion")
        XCTAssertTrue(diagnostics.contains("diagnosticsPresentationIsDirty = true"))
        XCTAssertTrue(diagnostics.contains(
            "private func scheduleDirtyDiagnosticsAfterForegroundIfNeeded()"
        ), "canceled requested diagnostics must retain one deferred foreground intent")

        let stressClockStart = try XCTUnwrap(home.range(
            of: "stressMonitorStore.$lastMeasuredAt"
        ))
        let stressClockEnd = try XCTUnwrap(home.range(
            of: "let collectionLiveChanges",
            range: stressClockStart.upperBound..<home.endIndex
        ))
        let stressClock = String(
            home[stressClockStart.lowerBound..<stressClockEnd.lowerBound]
        )
        XCTAssertTrue(stressClock.contains(
            "self.livePresentationIsCurrentlyAuthorized else { return }"
        ), "inactive stress clocks must not re-arm a presentation expiry")
        let expiryStart = try XCTUnwrap(home.range(
            of: "private func scheduleStressFreshnessExpiry(lastMeasuredAt: Date?)"
        ))
        let expiryEnd = try XCTUnwrap(home.range(
            of: "private func publishPulseSparkline()",
            range: expiryStart.upperBound..<home.endIndex
        ))
        let expiry = String(home[expiryStart.lowerBound..<expiryEnd.lowerBound])
        XCTAssertGreaterThanOrEqual(
            expiry.components(separatedBy: "livePresentationIsCurrentlyAuthorized").count - 1,
            2,
            "stress expiry must fence both scheduling and delayed execution"
        )

        let activityStart = try XCTUnwrap(home.range(
            of: "private func scheduleActivityProjectionRefresh()"
        ))
        let activityEnd = try XCTUnwrap(home.range(
            of: "private func requestSavedAggregateRefresh(reason: String)",
            range: activityStart.upperBound..<home.endIndex
        ))
        let activity = String(home[activityStart.lowerBound..<activityEnd.lowerBound])
        XCTAssertGreaterThanOrEqual(
            activity.components(separatedBy: "livePresentationIsCurrentlyAuthorized").count - 1,
            2,
            "activity projection must fence both admission and queued completion"
        )

        let historyStart = try XCTUnwrap(home.range(
            of: "ble.$historicalRecoveryPresentation"
        ))
        let historyEnd = try XCTUnwrap(home.range(
            of: ".store(in: &cancellables)",
            range: historyStart.upperBound..<home.endIndex
        ))
        let history = String(home[historyStart.lowerBound..<historyEnd.upperBound])
        XCTAssertTrue(history.contains(
            "guard UIApplication.shared.applicationState == .active"
        ), "Historical progress keeps its existing separate active-only authority")
    }

    func testHomePresentationGateDoesNotPauseDurableLiveAcquisitionLanes() throws {
        let home = try appSource("AtriaHomeView.swift")
        let ble = try appSource("AtriaBLEManager.swift")

        XCTAssertTrue(home.contains("ble.$sessionSampleCount"),
                      "Accepted-count publication must remain wired into Home")
        XCTAssertTrue(home.contains("self.updateSharedStress()"),
                      "Stress ingestion/history persistence stays live behind presentation")
        XCTAssertTrue(home.contains("self.synchronizeStressPresentationPublication()"))
        XCTAssertTrue(home.contains("setPresentationPublishingActive(active)"),
                      "stress computation must release only its latest presentation on foreground")
        XCTAssertTrue(home.contains("model.stressMonitorStore.flushHistoryCheckpoint()"))
        XCTAssertTrue(home.contains("ble.flushActiveSessionJournal(reason: \"explicit_workout_scene_background\")"))
        XCTAssertTrue(home.contains("scheduleLiveSensorWidgetPatch("))
        XCTAssertTrue(home.contains("updateLiveActivity(forceActivityWrite: true)"))

        let append = try XCTUnwrap(ble.range(of: "session.append(HRSample(t: sampleTime, bpm: rate))"))
        let countPublish = try XCTUnwrap(ble.range(
            of: "publishSessionSampleCountIfNeeded(now: sampleTime)",
            range: append.upperBound..<ble.endIndex
        ))
        let journal = try XCTUnwrap(ble.range(
            of: "persistActiveSessionJournalIfNeeded(reason: \"accepted_hr\", force: false)",
            range: countPublish.upperBound..<ble.endIndex
        ))
        XCTAssertLessThan(append.lowerBound, countPublish.lowerBound)
        XCTAssertLessThan(countPublish.lowerBound, journal.lowerBound)
        XCTAssertFalse(ble.contains("AtriaHomeLivePresentationAuthority"),
                       "The UI authority must stay downstream of BLE acceptance and durability")
    }

    func testHomeDisappearDoesNotSuspendSharedStressDuringActiveTabChanges() throws {
        let home = try appSource("AtriaHomeView.swift")
        let disappearStart = try XCTUnwrap(home.range(of: ".onDisappear {"))
        let disappearEnd = try XCTUnwrap(home.range(
            of: "private var homeShellWithWorkoutPersistence",
            range: disappearStart.upperBound..<home.endIndex
        ))
        let disappear = String(home[disappearStart.lowerBound..<disappearEnd.lowerBound])
        XCTAssertTrue(disappear.contains("model.setLivePresentationActive(false)"))
        XCTAssertFalse(disappear.contains("setScenePresentationActive"))
        XCTAssertFalse(disappear.contains("setPresentationPublishingActive"),
                       "Home visibility is not scene authority for shared stress observers")
    }

    func testHomeSavedAggregateRefreshGateBoundsBurstToOneActiveAndOneTrailing() {
        var gate = AtriaHomeSavedAggregateRefreshGate()
        XCTAssertEqual(gate.request(), .start(1))

        for _ in 0..<100 {
            XCTAssertEqual(gate.request(), .coalesced)
            XCTAssertEqual(gate.outstandingWorkUpperBound, 2)
            XCTAssertEqual(gate.inFlightGeneration, 1)
        }

        XCTAssertEqual(gate.latestGeneration, 101)
        XCTAssertEqual(gate.trailingGeneration, 101)
        XCTAssertEqual(gate.complete(1), .start(101))
        XCTAssertEqual(gate.outstandingWorkUpperBound, 1)
        XCTAssertEqual(gate.complete(101), .publish)
        XCTAssertEqual(gate.outstandingWorkUpperBound, 0)
    }

    func testHomeSavedAggregateRefreshGateRejectsEveryStaleCompletion() {
        var gate = AtriaHomeSavedAggregateRefreshGate()
        XCTAssertEqual(gate.request(), .start(1))
        XCTAssertEqual(gate.request(), .coalesced)
        XCTAssertEqual(gate.complete(1), .start(2))

        XCTAssertEqual(gate.request(), .coalesced)
        XCTAssertEqual(gate.complete(1), .ignored,
                       "a duplicate old callback must not disturb the active generation")
        XCTAssertEqual(gate.complete(2), .start(3),
                       "a result made stale while running must not publish")
        XCTAssertEqual(gate.complete(2), .ignored)
        XCTAssertEqual(gate.complete(3), .publish)
    }

    func testHomeSavedAggregateRefreshUsesSerialLatestWinsAuthorityLane() throws {
        let source = try appSource("AtriaHomeView.swift")
        XCTAssertTrue(source.contains(
            "label: \"com.adidshaft.atria.home-saved-aggregate\""
        ))
        XCTAssertTrue(source.contains(
            "requestSavedAggregateRefresh(reason: \"dashboard_revision\")"
        ))
        XCTAssertTrue(source.contains(
            "requestSavedAggregateRefresh(reason: \"history_snapshot\")"
        ))
        XCTAssertTrue(source.contains(
            "requestSavedAggregateRefresh(reason: \"profile\")"
        ))
        XCTAssertTrue(source.contains(
            "requestSavedAggregateRefresh(reason: \"baseline\")"
        ))
        XCTAssertTrue(source.contains(
            "requestSavedAggregateRefresh(reason: \"physiological_cycle_rollover\")"
        ))
        XCTAssertTrue(source.contains("case .start(let nextGeneration):"))
        XCTAssertTrue(source.contains("case .publish:"))

        let snapshotStart = try XCTUnwrap(source.range(
            of: "private func savedAggregateRefreshInputSnapshot("
        ))
        let workerStart = try XCTUnwrap(source.range(
            of: "private nonisolated static func makeSavedAggregate(\n        input:",
            range: snapshotStart.upperBound..<source.endIndex
        ))
        let snapshot = String(
            source[snapshotStart.lowerBound..<workerStart.lowerBound]
        )
        XCTAssertTrue(snapshot.contains(
            "source: store.homeSavedAggregateSourceSnapshot()"
        ))
        XCTAssertTrue(snapshot.contains("baseline: store.baseline"))
        XCTAssertFalse(snapshot.contains("homeSavedAggregate("),
                       "MainActor may retain COW authority, not run the aggregate reducer")
        XCTAssertFalse(snapshot.contains("currentRestingContext("))
        XCTAssertFalse(snapshot.contains("restingStable"))
        XCTAssertFalse(snapshot.contains("freshHRVSampleCount("))
        XCTAssertFalse(snapshot.contains("observedHeartRateUnionSeconds("))

        let workerEnd = try XCTUnwrap(source.range(
            of: "private func scheduleSavedAggregateCycleRolloverRefresh()",
            range: workerStart.upperBound..<source.endIndex
        ))
        let worker = String(source[workerStart.lowerBound..<workerEnd.lowerBound])
        XCTAssertTrue(worker.contains("SessionStore.homeSavedAggregate("))
        XCTAssertTrue(worker.contains(".map(\\.restingStable)"))
        XCTAssertTrue(worker.contains(
            "archiveHeartRatePoints: input.source.archiveHeartRatePoints"
        ))
        XCTAssertTrue(worker.contains("input.baseline.freshHRVSampleCount("))
        XCTAssertTrue(worker.contains("observedHeartRateUnionSeconds("))
        XCTAssertTrue(worker.contains("sessions: input.source.rawSessions"))
        XCTAssertTrue(worker.contains(
            "rawSessionCount: input.source.rawSessionCount"
        ),
                      "the worker must preserve the captured publication authority")

        let sessionsSource = try appSource("Sessions.swift")
        let sourceCaptureStart = try XCTUnwrap(sessionsSource.range(
            of: "func homeSavedAggregateSourceSnapshot()"
        ))
        let sourceCaptureEnd = try XCTUnwrap(sessionsSource.range(
            of: "func workoutSavedStepPrefix(",
            range: sourceCaptureStart.upperBound..<sessionsSource.endIndex
        ))
        let sourceCapture = String(
            sessionsSource[sourceCaptureStart.lowerBound..<sourceCaptureEnd.lowerBound]
        )
        XCTAssertTrue(sourceCapture.contains(
            "canonicalSessions: cachedCanonicalSessions"
        ))
        XCTAssertTrue(sourceCapture.contains(
            "archiveHeartRatePoints: cachedHistoricalTodayHeartRatePoints"
        ))
        XCTAssertTrue(sourceCapture.contains("rawSessions: sessions"))
        XCTAssertFalse(sourceCapture.contains(".map"))
        XCTAssertFalse(sourceCapture.contains(".filter"))
        XCTAssertFalse(sourceCapture.contains(".sorted"))
        XCTAssertFalse(sourceCapture.contains("homeSavedAggregate("))
    }

    private func testImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemMint.setFill()
            context.fill(CGRect(x: size.width * 0.15,
                                y: size.height * 0.2,
                                width: size.width * 0.7,
                                height: size.height * 0.6))
        }
    }

    private func largestPixelDimension(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return max(cgImage.width, cgImage.height)
    }

    private func workoutPreparationSnapshot(
        sessions: [SavedSession],
        start: Date,
        end: Date,
        revision: Int
    ) -> SessionStore.WorkoutWindowPreparationSnapshot {
        let profile = AthleteProfile(
            age: 30,
            measuredMaxHR: 190,
            maxHRSource: .measured,
            biologicalSex: .male,
            weightKg: 72,
            heightCm: 178,
            updated: nil,
            hasCompletedOnboarding: true
        )
        let request = SessionStore.WorkoutWindowConfirmationRequest(
            start: start,
            end: end,
            rest: 60,
            maxHR: 190,
            source: "test",
            allowManualSave: true,
            preserveUserDeclaredActivityWithoutHeartRate: true,
            activityLabel: nil,
            activityType: AtriaWorkoutActivityType.walking.rawValue,
            activitySubtype: nil,
            exerciseNames: [],
            strengthSets: [],
            excludedIntervals: [],
            reviewSource: nil,
            reviewCandidateID: nil,
            settlingCandidateWindow: nil,
            workoutSteps: nil,
            workoutStepsAreEstimated: nil,
            workoutStepsCapturedAt: nil,
            profile: profile,
            eventTimeZoneIdentifier: "UTC"
        )
        return SessionStore.WorkoutWindowPreparationSnapshot(
            fingerprint: SessionStore.WorkoutWindowConfirmationFingerprint(
                canonicalSessionsRevision: revision,
                profile: profile
            ),
            request: request,
            canonicalSessions: sessions,
            preparedAt: end
        )
    }

    private func pendingWorkoutIntent(start: Date) -> AtriaPendingWorkoutIntent {
        AtriaPendingWorkoutIntent(
            startedAt: start,
            endedAt: start.addingTimeInterval(1_800),
            activityType: AtriaWorkoutActivityType.strength.rawValue,
            strengthSets: [],
            excludedIntervals: [],
            startingStepCount: 0,
            startingDayStrain: 0
        )
    }
}
