import XCTest
@testable import Atria

@MainActor
final class AtriaSessionStressContextPublicationTests: XCTestCase {
    private final class NotificationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ObjectIdentifier] = []

        func record(_ object: Any?) {
            guard let object = object as AnyObject? else { return }
            lock.lock()
            storage.append(ObjectIdentifier(object))
            lock.unlock()
        }

        var objectIdentifiers: [ObjectIdentifier] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private func workout(
        id: String = "stress-context-workout",
        start: Date,
        end: Date,
        confidence: String = "live_window_user_confirmed"
    ) -> UserConfirmedWorkout {
        UserConfirmedWorkout(
            id: id,
            createdAt: end,
            start: start,
            end: end,
            label: "Walk",
            source: "live_workout_window",
            confidence: confidence,
            sessions: 1,
            samples: 60,
            avgHR: 112,
            peakHR: 138,
            p95HR: 132,
            p99HR: 136,
            thresholdHR: 110,
            streamCoveragePercent: 95,
            observedDuration: end.timeIntervalSince(start),
            reason: "fixture"
        )
    }

    private func sleep(
        id: String = "stress-context-sleep",
        start: Date,
        end: Date,
        hrv: Int? = 48,
        stageSegments: [SleepStageSegment]? = nil
    ) -> UserConfirmedSleep {
        let duration = end.timeIntervalSince(start)
        return UserConfirmedSleep(
            id: id,
            createdAt: end,
            start: start,
            end: end,
            source: "manual_sleep",
            confidence: "manual_user_entered",
            sessions: 1,
            samples: 1_000,
            avgHR: 58,
            peakHR: 82,
            restingHR: 51,
            hrv: hrv,
            hrvWindowCount: hrv == nil ? nil : 4,
            respiratoryRate: 14.8,
            duration: duration,
            span: duration,
            reason: "fixture",
            motionSource: "manual",
            motionValidated: false,
            stageSegments: stageSegments,
            eventTimeZoneIdentifier: "UTC"
        )
    }

    private func recorder() -> (
        recorder: NotificationRecorder,
        token: NSObjectProtocol
    ) {
        let recorder = NotificationRecorder()
        let token = NotificationCenter.default.addObserver(
            forName: SessionStore.stressContextDidPublishNotification,
            object: nil,
            queue: nil
        ) { notification in
            recorder.record(notification.object)
        }
        return (recorder, token)
    }

    private func terminalRecorder() -> (
        recorder: NotificationRecorder,
        token: NSObjectProtocol
    ) {
        let recorder = NotificationRecorder()
        let token = NotificationCenter.default.addObserver(
            forName: SessionStore.stressReplayDidPublishNotification,
            object: nil,
            queue: nil
        ) { notification in
            recorder.record(notification.object)
        }
        return (recorder, token)
    }

    private func calibrationFenceRecorder() -> (
        recorder: NotificationRecorder,
        token: NSObjectProtocol
    ) {
        let recorder = NotificationRecorder()
        let token = NotificationCenter.default.addObserver(
            forName: SessionStore.stressCalibrationFenceDidReleaseNotification,
            object: nil,
            queue: nil
        ) { notification in
            recorder.record(notification.object)
        }
        return (recorder, token)
    }

    private func session(
        id: UUID = UUID(),
        start: Date,
        duration: TimeInterval,
        heartRateOffsets: [TimeInterval],
        rrOffsets: [TimeInterval] = []
    ) -> SavedSession {
        var value = SavedSession(
            id: id,
            start: start,
            end: start.addingTimeInterval(duration),
            label: "Stress replay fixture",
            points: heartRateOffsets.map {
                SavedSession.Point(t: $0, bpm: 72)
            }
        )
        value.rrPoints = rrOffsets.map {
            SavedSession.RRPoint(
                t: $0,
                ms: 800,
                source: .standardHeartRateMeasurement2A37
            )
        }
        return value
    }

    func testQualifiedWorkoutConfirmBoundsEditAndDeletePublishExactlyOnceEach() {
        let store = SessionStore()
        let observation = recorder()
        defer { NotificationCenter.default.removeObserver(observation.token) }

        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let confirmed = workout(
            start: start,
            end: start.addingTimeInterval(30 * 60)
        )
        let confirmationChanged = SessionStore
            .debugWorkoutStressContextAuthorityChanged(
                previous: nil,
                next: confirmed
            )
        XCTAssertTrue(confirmationChanged)
        store.debugPublishStressContextMutationForTesting(
            publicationRequested: confirmationChanged
        )

        // Re-publishing the already-installed value is not another mutation.
        let duplicateChanged = SessionStore
            .debugWorkoutStressContextAuthorityChanged(
                previous: confirmed,
                next: confirmed
            )
        XCTAssertFalse(duplicateChanged)
        store.debugPublishStressContextMutationForTesting(
            publicationRequested: duplicateChanged
        )
        var stepOnly = confirmed
        stepOnly.workoutSteps = 2_400
        stepOnly.workoutStepsAreEstimated = false
        stepOnly.workoutStepsCapturedAt = confirmed.end
        let stepOnlyChanged = SessionStore
            .debugWorkoutStressContextAuthorityChanged(
                previous: confirmed,
                next: stepOnly
            )
        XCTAssertFalse(stepOnlyChanged)
        store.debugPublishStressContextMutationForTesting(
            publicationRequested: stepOnlyChanged
        )

        let edited = workout(
            start: start.addingTimeInterval(5 * 60),
            end: start.addingTimeInterval(35 * 60)
        )
        let editChanged = SessionStore
            .debugWorkoutStressContextAuthorityChanged(
                previous: stepOnly,
                next: edited
            )
        XCTAssertTrue(editChanged)
        store.debugPublishStressContextMutationForTesting(
            publicationRequested: editChanged
        )
        let deletionChanged = SessionStore
            .debugWorkoutStressContextAuthorityChanged(
                previous: edited,
                next: nil
            )
        XCTAssertTrue(deletionChanged)
        store.debugPublishStressContextMutationForTesting(
            publicationRequested: deletionChanged
        )

        XCTAssertEqual(observation.recorder.objectIdentifiers.count, 3)
        XCTAssertTrue(observation.recorder.objectIdentifiers.allSatisfy {
            $0 == ObjectIdentifier(store)
        })
    }

    func testQualifiedSleepConfirmBoundsEditAndDeleteIgnoreHRVAndStageOnlyWrites() {
        let store = SessionStore()
        let observation = recorder()
        defer { NotificationCenter.default.removeObserver(observation.token) }

        let start = Date(timeIntervalSinceReferenceDate: 800_100_000)
        let confirmed = sleep(
            start: start,
            end: start.addingTimeInterval(8 * 60 * 60)
        )
        let confirmationChanged = SessionStore
            .debugSleepStressContextAuthorityChanged(
                previous: nil,
                next: confirmed
            )
        XCTAssertTrue(confirmationChanged)
        store.debugPublishStressContextMutationForTesting(
            publicationRequested: confirmationChanged
        )

        let stage = SleepStageSegment(
            id: "stage",
            start: confirmed.start,
            end: confirmed.end,
            stage: .light
        )
        let derivedOnly = sleep(
            start: confirmed.start,
            end: confirmed.end,
            hrv: 61,
            stageSegments: [stage]
        )
        let derivedOnlyChanged = SessionStore
            .debugSleepStressContextAuthorityChanged(
                previous: confirmed,
                next: derivedOnly
            )
        XCTAssertFalse(derivedOnlyChanged)
        store.debugPublishStressContextMutationForTesting(
            publicationRequested: derivedOnlyChanged
        )

        let edited = sleep(
            start: start.addingTimeInterval(20 * 60),
            end: start.addingTimeInterval(8 * 60 * 60 + 20 * 60),
            hrv: 61,
            stageSegments: [stage]
        )
        let editChanged = SessionStore
            .debugSleepStressContextAuthorityChanged(
                previous: derivedOnly,
                next: edited
            )
        XCTAssertTrue(editChanged)
        store.debugPublishStressContextMutationForTesting(
            publicationRequested: editChanged
        )
        let deletionChanged = SessionStore
            .debugSleepStressContextAuthorityChanged(
                previous: edited,
                next: nil
            )
        XCTAssertTrue(deletionChanged)
        store.debugPublishStressContextMutationForTesting(
            publicationRequested: deletionChanged
        )

        XCTAssertEqual(observation.recorder.objectIdentifiers.count, 3)
        XCTAssertTrue(observation.recorder.objectIdentifiers.allSatisfy {
            $0 == ObjectIdentifier(store)
        })
    }

    func testDeferredRecoveredMutationDoesNotPublishAndObjectIsExactStore() {
        let store = SessionStore()
        let otherStore = SessionStore()
        let observation = recorder()
        defer { NotificationCenter.default.removeObserver(observation.token) }

        store.debugPublishStressContextMutationForTesting(
            deferDerivedPublication: true
        )
        store.debugPublishStressContextMutationForTesting(
            publicationRequested: false
        )
        XCTAssertTrue(observation.recorder.objectIdentifiers.isEmpty)

        store.debugPublishStressContextMutationForTesting()
        otherStore.debugPublishStressContextMutationForTesting()
        XCTAssertEqual(
            observation.recorder.objectIdentifiers,
            [ObjectIdentifier(store), ObjectIdentifier(otherStore)]
        )
    }

    func testTerminalReplayNotificationCarriesTheExactPublishingStore() {
        let store = SessionStore()
        let otherStore = SessionStore()
        let observation = terminalRecorder()
        defer { NotificationCenter.default.removeObserver(observation.token) }

        store.debugPublishStressReplayTerminalEdgeForTesting(
            reason: "session_deleted"
        )
        otherStore.debugPublishStressReplayTerminalEdgeForTesting(
            reason: "backup_restore"
        )

        XCTAssertEqual(
            observation.recorder.objectIdentifiers,
            [ObjectIdentifier(store), ObjectIdentifier(otherStore)]
        )
    }

    func testCalibrationFenceReleaseCarriesTheExactPublishingStore() {
        let store = SessionStore()
        let otherStore = SessionStore()
        let observation = calibrationFenceRecorder()
        defer { NotificationCenter.default.removeObserver(observation.token) }

        store.debugPublishStressCalibrationFenceDidReleaseForTesting()
        otherStore.debugPublishStressCalibrationFenceDidReleaseForTesting()

        XCTAssertEqual(
            observation.recorder.objectIdentifiers,
            [ObjectIdentifier(store), ObjectIdentifier(otherStore)]
        )
    }

    func testSessionReplayInputShrinkDetectionCoversBoundsHRAndRR() {
        let id = UUID()
        let start = Date(timeIntervalSinceReferenceDate: 800_200_000)
        let original = session(
            id: id,
            start: start,
            duration: 300,
            heartRateOffsets: [0, 60, 120, 180, 240, 300],
            rrOffsets: [1, 2, 3, 4]
        )
        let identical = session(
            id: id,
            start: start,
            duration: 300,
            heartRateOffsets: [0, 60, 120, 180, 240, 300],
            rrOffsets: [1, 2, 3, 4]
        )
        let growth = session(
            id: id,
            start: start,
            duration: 360,
            heartRateOffsets: [0, 60, 120, 180, 240, 300, 360],
            rrOffsets: [1, 2, 3, 4, 5]
        )
        let shorterEnd = session(
            id: id,
            start: start,
            duration: 240,
            heartRateOffsets: [0, 60, 120, 180, 240],
            rrOffsets: [1, 2, 3, 4]
        )
        let fewerHR = session(
            id: id,
            start: start,
            duration: 300,
            heartRateOffsets: [0, 60, 120],
            rrOffsets: [1, 2, 3, 4]
        )
        let fewerRR = session(
            id: id,
            start: start,
            duration: 300,
            heartRateOffsets: [0, 60, 120, 180, 240, 300],
            rrOffsets: [1, 2]
        )

        XCTAssertTrue(SessionStore.stressReplaySessionHasInput(original))
        XCTAssertFalse(SessionStore.stressReplaySessionInputShrank(
            previous: nil,
            next: original
        ))
        XCTAssertFalse(SessionStore.stressReplaySessionInputShrank(
            previous: original,
            next: identical
        ))
        XCTAssertFalse(SessionStore.stressReplaySessionInputShrank(
            previous: original,
            next: growth
        ))
        XCTAssertTrue(SessionStore.stressReplaySessionInputShrank(
            previous: original,
            next: shorterEnd
        ))
        XCTAssertTrue(SessionStore.stressReplaySessionInputShrank(
            previous: original,
            next: fewerHR
        ))
        XCTAssertTrue(SessionStore.stressReplaySessionInputShrank(
            previous: original,
            next: fewerRR
        ))
    }

    func testRecoveredRollbackTerminalGatePublishesOnlyPreservedMutations() {
        var empty = AtriaStressReplayTerminalPublicationGate()
        empty.beginTransaction()
        empty.registerMutationSnapshot()
        XCTAssertEqual(
            empty.rollbackTransaction(),
            .init(
                shouldPublish: false,
                requiresSessionAuthorityPublication: false
            )
        )

        var revertedSleep = AtriaStressReplayTerminalPublicationGate()
        revertedSleep.beginTransaction()
        revertedSleep.registerMutationSnapshot()
        revertedSleep.observeNonWorkoutContextMutation()
        XCTAssertFalse(revertedSleep.rollbackTransaction().shouldPublish)

        var preservedWorkout = AtriaStressReplayTerminalPublicationGate()
        preservedWorkout.beginTransaction()
        preservedWorkout.registerMutationSnapshot()
        preservedWorkout.observeWorkoutContextMutation(
            preservesQualifiedAdditionAfterSnapshot: true
        )
        XCTAssertTrue(preservedWorkout.rollbackTransaction().shouldPublish)
        XCTAssertFalse(
            preservedWorkout.rollbackTransaction().shouldPublish,
            "one terminal transaction may produce at most one edge"
        )

        var addedThenDeleted = AtriaStressReplayTerminalPublicationGate()
        addedThenDeleted.beginTransaction()
        addedThenDeleted.registerMutationSnapshot()
        addedThenDeleted.observeWorkoutContextMutation(
            preservesQualifiedAdditionAfterSnapshot: true
        )
        addedThenDeleted.observeWorkoutContextMutation(
            preservesQualifiedAdditionAfterSnapshot: false
        )
        XCTAssertFalse(addedThenDeleted.rollbackTransaction().shouldPublish)

        var preSnapshot = AtriaStressReplayTerminalPublicationGate()
        preSnapshot.beginTransaction()
        preSnapshot.observeNonWorkoutContextMutation()
        preSnapshot.registerMutationSnapshot()
        XCTAssertTrue(preSnapshot.rollbackTransaction().shouldPublish)

        var sessionMutation = AtriaStressReplayTerminalPublicationGate()
        sessionMutation.beginTransaction()
        sessionMutation.registerMutationSnapshot()
        sessionMutation.observePreservedSessionMutation()
        XCTAssertEqual(
            sessionMutation.rollbackTransaction(),
            .init(
                shouldPublish: true,
                requiresSessionAuthorityPublication: true
            )
        )

        var committed = AtriaStressReplayTerminalPublicationGate()
        committed.beginTransaction()
        committed.observeNonWorkoutContextMutation()
        committed.commitTransaction()
        XCTAssertFalse(committed.rollbackTransaction().shouldPublish)
    }

    func testProductionHooksFollowAtomicWriteAndCanonicalPublication() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("stressContextAuthorityFingerprint"))
        let edgeStart = try XCTUnwrap(
            source.range(of: "private func publishStressContextIfNeeded(")
        )
        let edgeEnd = try XCTUnwrap(
            source.range(
                of: "private func publishStressReplayTerminalMutationIfNeeded(",
                range: edgeStart.upperBound..<source.endIndex
            )
        )
        let edge = String(source[edgeStart.lowerBound..<edgeEnd.lowerBound])
        XCTAssertFalse(edge.contains("for "))
        XCTAssertFalse(edge.contains(".filter"))
        XCTAssertFalse(edge.contains(".sorted"))

        let workoutStart = try XCTUnwrap(
            source.range(of: "private func saveConfirmedWorkouts(")
        )
        let workoutEnd = try XCTUnwrap(
            source.range(
                of: "private func confirmedWorkoutID(",
                range: workoutStart.upperBound..<source.endIndex
            )
        )
        let workoutPath = String(source[workoutStart.lowerBound..<workoutEnd.lowerBound])
        let workoutAtomic = try XCTUnwrap(
            workoutPath.range(of: "completedGeneration == generation")
        )
        let workoutCanonical = try XCTUnwrap(
            workoutPath.range(of: "cachedConfirmedWorkouts = sorted")
        )
        let workoutPublish = try XCTUnwrap(
            workoutPath.range(of: "publishStressContextIfNeeded(")
        )
        XCTAssertLessThan(workoutAtomic.lowerBound, workoutCanonical.lowerBound)
        XCTAssertLessThan(workoutCanonical.lowerBound, workoutPublish.lowerBound)

        let sleepStart = try XCTUnwrap(
            source.range(of: "private func saveConfirmedSleeps(")
        )
        let sleepEnd = try XCTUnwrap(
            source.range(
                of: "private func writeDutyCycleSleepWindow(",
                range: sleepStart.upperBound..<source.endIndex
            )
        )
        let sleepPath = String(source[sleepStart.lowerBound..<sleepEnd.lowerBound])
        let sleepAtomic = try XCTUnwrap(
            sleepPath.range(of: "completedGeneration == generation")
        )
        let sleepCanonical = try XCTUnwrap(
            sleepPath.range(of: "setCachedConfirmedSleeps(")
        )
        let sleepSnapshot = try XCTUnwrap(
            sleepPath.range(of: "sleepHistorySnapshot = SleepHistorySnapshot(")
        )
        let sleepPublish = try XCTUnwrap(
            sleepPath.range(of: "publishStressContextIfNeeded(")
        )
        XCTAssertLessThan(sleepAtomic.lowerBound, sleepCanonical.lowerBound)
        XCTAssertLessThan(sleepCanonical.lowerBound, sleepSnapshot.lowerBound)
        XCTAssertLessThan(sleepSnapshot.lowerBound, sleepPublish.lowerBound)
    }

    func testTerminalReplayHooksPublishOnlyAfterCanonicalTerminalState() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let deleteStart = try XCTUnwrap(
            source.range(of: "func delete(_ offsets: IndexSet)")
        )
        let deleteEnd = try XCTUnwrap(
            source.range(
                of: "private func invalidateDailyDerivedDays(",
                range: deleteStart.upperBound..<source.endIndex
            )
        )
        let deletePath = String(
            source[deleteStart.lowerBound..<deleteEnd.lowerBound]
        )
        let deleteCanonical = try XCTUnwrap(
            deletePath.range(of: "refreshSessionDerivedCaches()")
        )
        let deleteReplayAuthority = try XCTUnwrap(
            deletePath.range(of: "publishHistoricalStressSessionAuthority()")
        )
        let deleteTerminal = try XCTUnwrap(
            deletePath.range(
                of: "publishStressReplayTerminalMutationIfNeeded("
            )
        )
        XCTAssertLessThan(
            deleteCanonical.lowerBound,
            deleteReplayAuthority.lowerBound
        )
        XCTAssertLessThan(
            deleteReplayAuthority.lowerBound,
            deleteTerminal.lowerBound
        )

        let checkpointStart = try XCTUnwrap(
            source.range(of: "func checkpoint(_ s: SavedSession) -> Bool")
        )
        let checkpointEnd = try XCTUnwrap(
            source.range(
                of: "nonisolated static func shouldRefreshHRVOnLiveCheckpoint(",
                range: checkpointStart.upperBound..<source.endIndex
            )
        )
        let checkpointPath = String(
            source[checkpointStart.lowerBound..<checkpointEnd.lowerBound]
        )
        let checkpointCanonical = try XCTUnwrap(
            checkpointPath.range(
                of: "refreshSessionDerivedCachesAfterUpsert("
            )
        )
        let checkpointTerminal = try XCTUnwrap(
            checkpointPath.range(
                of: "publishStressReplayTerminalMutationIfNeeded("
            )
        )
        XCTAssertLessThan(
            checkpointCanonical.lowerBound,
            checkpointTerminal.lowerBound
        )

        let rollbackStart = try XCTUnwrap(
            source.range(
                of: "private func rollbackRecoveredDataMutationTransaction("
            )
        )
        let rollbackEnd = try XCTUnwrap(
            source.range(
                of: "var recoveredDataArchiveRevisionSnapshot: UInt64",
                range: rollbackStart.upperBound..<source.endIndex
            )
        )
        let rollbackPath = String(
            source[rollbackStart.lowerBound..<rollbackEnd.lowerBound]
        )
        let actualRollback = try XCTUnwrap(
            rollbackPath.range(
                of: "recoveredDataMutationTransaction.rollback(ticket: ticket)"
            )
        )
        let terminalDecision = try XCTUnwrap(
            rollbackPath.range(of: ".rollbackTransaction()")
        )
        let rollbackPublish = try XCTUnwrap(
            rollbackPath.range(of: "publishStressReplayTerminalEdge(")
        )
        let calibrationFenceRelease = try XCTUnwrap(
            rollbackPath.range(
                of: "publishStressCalibrationFenceDidRelease("
            )
        )
        XCTAssertLessThan(actualRollback.lowerBound, terminalDecision.lowerBound)
        XCTAssertLessThan(terminalDecision.lowerBound, rollbackPublish.lowerBound)
        XCTAssertLessThan(actualRollback.lowerBound,
                          calibrationFenceRelease.lowerBound)

        let commitStart = try XCTUnwrap(
            source.range(
                of: "private func commitRecoveredDataMutationTransaction("
            )
        )
        let commitPath = String(
            source[commitStart.lowerBound..<rollbackStart.lowerBound]
        )
        XCTAssertTrue(commitPath.contains(".commitTransaction()"))
        XCTAssertFalse(
            commitPath.contains("publishStressReplayTerminalEdge("),
            "recovered success already owns one complete publication edge"
        )

        let restoreStart = try XCTUnwrap(
            source.range(
                of: "private func restoreSessionBackup(request: SessionBackupIORequest)"
            )
        )
        let restoreEnd = try XCTUnwrap(
            source.range(
                of: "private func applyPreparedSessionBackupRestore(",
                range: restoreStart.upperBound..<source.endIndex
            )
        )
        let restorePath = String(
            source[restoreStart.lowerBound..<restoreEnd.lowerBound]
        )
        let fenceRelease = try XCTUnwrap(
            restorePath.range(of: "endRestorePersistenceFence()")
        )
        let restoreTerminal = try XCTUnwrap(
            restorePath.range(
                of: "publishStressReplayTerminalEdge(reason: \"backup_restore\")"
            )
        )
        let failedRestoreCalibrationRelease = try XCTUnwrap(
            restorePath.range(
                of: "publishStressCalibrationFenceDidRelease("
            )
        )
        let atomicApply = try XCTUnwrap(
            restorePath.range(of: "applyPreparedSessionBackupRestore(committed)")
        )
        let dashboardPublish = try XCTUnwrap(
            restorePath.range(of: "publishDashboardRevision()")
        )
        let armTerminal = try XCTUnwrap(
            restorePath.range(
                of: "shouldPublishStressReplayAfterRestore = true"
            )
        )
        XCTAssertLessThan(fenceRelease.lowerBound, restoreTerminal.lowerBound)
        XCTAssertLessThan(fenceRelease.lowerBound,
                          failedRestoreCalibrationRelease.lowerBound)
        XCTAssertLessThan(atomicApply.lowerBound, dashboardPublish.lowerBound)
        XCTAssertLessThan(dashboardPublish.lowerBound, armTerminal.lowerBound)
        XCTAssertEqual(
            restorePath.components(
                separatedBy:
                    "publishStressReplayTerminalEdge(reason: \"backup_restore\")"
            ).count - 1,
            1
        )
        XCTAssertTrue(
            source.contains(
                "recoveredDataMutationTransaction.activeTicket != nil\n            || restorePersistenceFenceActive"
            )
        )

        let publishStart = try XCTUnwrap(
            source.range(of: "case .publish(let ticket):")
        )
        let publishEnd = try XCTUnwrap(
            source.range(
                of: "pendingHistoryRefreshDeferredByProjectionScan = false",
                range: publishStart.upperBound..<source.endIndex
            )
        )
        let publishPath = String(
            source[publishStart.lowerBound..<publishEnd.upperBound]
        )
        let commitAttempt = try XCTUnwrap(
            publishPath.range(
                of: "guard commitRecoveredDataMutationTransaction(ticket: ticket)"
            )
        )
        let terminalCleanup = try XCTUnwrap(
            publishPath.range(
                of: "rollbackRecoveredDataMutationTransaction(ticket: ticket)"
            )
        )
        let failedPublication = try XCTUnwrap(
            publishPath.range(
                of: "recoveredDataPublicationFence.fail(through: ticket.archiveRevision)"
            )
        )
        XCTAssertLessThan(commitAttempt.lowerBound, terminalCleanup.lowerBound)
        XCTAssertLessThan(terminalCleanup.lowerBound,
                          failedPublication.lowerBound)
    }
}
