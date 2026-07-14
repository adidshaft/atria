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

final class AtriaSwiftUIPerformanceAuditTests: XCTestCase {
    private func appSource(_ relativePath: String) throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")
        return try String(contentsOf: appURL.appendingPathComponent(relativePath), encoding: .utf8)
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
        XCTAssertTrue(sessions.contains("AtriaRawExport.hrRows(sessions: request.sessions)"),
                      "Raw-row expansion belongs inside the serial worker")
    }

    func testBackgroundTaskWaitsForDurableBackupWorkerCompletion() throws {
        let app = try appSource("AtriaApp.swift")
        XCTAssertTrue(app.contains("let backupSucceeded = await withCheckedContinuation"))
        XCTAssertTrue(app.contains("store.performBackgroundMaintenance(reason: reason) { succeeded in"))
        XCTAssertTrue(app.contains("completion.complete(task, success: backupSucceeded)"))
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
        XCTAssertTrue(settings.contains("@State private var backupWriteInProgress = false"))
        XCTAssertTrue(settings.contains("ProgressView()"))
        XCTAssertTrue(settings.contains(".disabled(backupWriteInProgress)"))
        XCTAssertTrue(action.contains("guard !backupWriteInProgress else { return }"))
        XCTAssertTrue(action.contains("writer { status in"))
        XCTAssertTrue(action.contains("backupWriteInProgress = false"))
        XCTAssertTrue(action.contains("Backup saved."))
        XCTAssertTrue(action.contains("Backup failed. Try again."))
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
        XCTAssertEqual(workout.components(separatedBy: "@ObservedObject var metricStore: AtriaLiveWorkoutMetricStore").count - 1,
                       2,
                       "Exactly the route HUD and stationary guidance hosts should observe rapid metrics")
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
        XCTAssertLessThan(try XCTUnwrap(completion.range(of: "finalIntent.save()")?.lowerBound),
                          try XCTUnwrap(completion.range(of: "await store.confirmWorkoutWindowForUIAsync")?.lowerBound),
                          "Pending intent must become durable before asynchronous evidence preparation")
        XCTAssertLessThan(try XCTUnwrap(completion.range(of: "await store.confirmWorkoutWindowForUIAsync")?.lowerBound),
                          try XCTUnwrap(completion.range(of: "workoutEndNotice = .persisted")?.lowerBound),
                          "Sharing/recap must remain structurally downstream of canonical confirmation")
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
