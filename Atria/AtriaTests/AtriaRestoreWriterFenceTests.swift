import XCTest
@testable import Atria

final class AtriaRestoreWriterFenceTests: XCTestCase {
    @MainActor
    func testActiveRestoreFenceRejectsLiveSessionProducersWithoutMutation() {
        let store = SessionStore()
        let originalIDs = store.sessions.map(\.id)
        let session = SavedSession(
            id: UUID(),
            start: Date(timeIntervalSince1970: 2_200_000_000),
            end: Date(timeIntervalSince1970: 2_200_000_060),
            label: "restore-fence-live-producer",
            points: [SavedSession.Point(t: 0, bpm: 80)],
            hrv: nil,
            eventTimeZoneIdentifier: "UTC"
        )

        store.setRestorePersistenceFenceForTesting(true)
        defer { store.setRestorePersistenceFenceForTesting(false) }

        XCTAssertFalse(store.add(session))
        XCTAssertFalse(store.checkpoint(session))
        XCTAssertEqual(store.sessions.map(\.id), originalIDs)
    }

    func testManualBackupRequestsFailClosedForEveryRestoreOrOperationFence() {
        XCTAssertTrue(SessionStore.manualBackupRequestAllowed(
            restoreInitializationBlocked: false,
            restorePersistenceFenceActive: false,
            userOperationInProgress: false
        ))
        XCTAssertFalse(SessionStore.manualBackupRequestAllowed(
            restoreInitializationBlocked: true,
            restorePersistenceFenceActive: false,
            userOperationInProgress: false
        ))
        XCTAssertFalse(SessionStore.manualBackupRequestAllowed(
            restoreInitializationBlocked: false,
            restorePersistenceFenceActive: true,
            userOperationInProgress: false
        ))
        XCTAssertFalse(SessionStore.manualBackupRequestAllowed(
            restoreInitializationBlocked: false,
            restorePersistenceFenceActive: false,
            userOperationInProgress: true
        ))
    }

    func testRetainedRestoreMarkerKeepsRuntimePersistenceBlocked() {
        XCTAssertTrue(SessionStore.restoreFailureRequiresRuntimeBlock(
            reason: "restore_marker_retained"
        ))
        XCTAssertFalse(SessionStore.restoreFailureRequiresRuntimeBlock(
            reason: "store_save_failed"
        ))
        XCTAssertTrue(SessionStore.canonicalMutationAllowed(
            restoreInitializationBlocked: false,
            restorePersistenceFenceActive: false
        ))
        XCTAssertFalse(SessionStore.canonicalMutationAllowed(
            restoreInitializationBlocked: true,
            restorePersistenceFenceActive: false
        ))
        XCTAssertFalse(SessionStore.canonicalMutationAllowed(
            restoreInitializationBlocked: false,
            restorePersistenceFenceActive: true
        ))
    }

    func testWorkerFenceWaitsForInflightAndQueuedWritesWithoutDroppingCompletions() async {
        let firstWriteStarted = expectation(description: "first write started")
        let releaseFirstWrite = DispatchSemaphore(value: 0)
        let writes = LockedValues<Int>()
        let completions = LockedValues<Int>()
        let worker = AtriaCoalescingSerialWorker<Int, Int>(
            label: "com.adidshaft.atria.tests.restore-writer-fence"
        ) { value in
            if value == 1 {
                firstWriteStarted.fulfill()
                releaseFirstWrite.wait()
            }
            writes.append(value)
            return value
        }

        worker.enqueueLatest(1) { completions.append($0) }
        await fulfillment(of: [firstWriteStarted], timeout: 2)
        worker.enqueueLatest(2) { completions.append($0) }

        let fence = Task {
            await worker.fence()
        }
        await Task.yield()
        XCTAssertFalse(fence.isCancelled)
        releaseFirstWrite.signal()
        await fence.value

        XCTAssertEqual(writes.snapshot(), [1, 2])
        XCTAssertEqual(completions.snapshot(), [1, 2])
    }

    @MainActor
    func testConfirmedRecordTransactionGateResumesWaitersFIFO() async {
        let gate = AtriaConfirmedRecordTransactionGate()
        await gate.acquire()
        var order: [Int] = []

        let second = Task { @MainActor in
            await gate.acquire()
            order.append(2)
            gate.release()
        }
        await Task.yield()
        let third = Task { @MainActor in
            await gate.acquire()
            order.append(3)
            gate.release()
        }
        await Task.yield()

        gate.release()
        await second.value
        await third.value
        XCTAssertEqual(order, [2, 3])
    }

    func testRequiredConfirmedRecordWriteDoesNotBlockMainActor() async {
        let started = expectation(description: "writer started")
        let heartbeat = expectation(description: "main actor heartbeat")
        let release = DispatchSemaphore(value: 0)
        let worker = AtriaCoalescingSerialWorker<Int, Int>(
            label: "com.adidshaft.atria.tests.confirmed-record-responsiveness"
        ) { value in
            started.fulfill()
            release.wait()
            return value
        }

        let write = Task { @MainActor in
            await worker.performAsync(7)
        }
        await fulfillment(of: [started], timeout: 2)
        Task { @MainActor in heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 1)
        release.signal()
        let writtenValue = await write.value
        XCTAssertEqual(writtenValue, 7)
    }

    func testConfirmedWorkoutRebasePreservesConcurrentIndependentMutations() {
        let first = confirmedWorkout(id: "first", label: "First")
        let second = confirmedWorkout(id: "second", label: "Second")
        let editedFirst = confirmedWorkout(id: "first", label: "Edited")
        let current = [first, second]

        let rebased = SessionStore.rebasedConfirmedWorkouts(
            base: [first],
            desired: [editedFirst],
            current: current
        )

        XCTAssertEqual(rebased.first(where: { $0.id == first.id })?.label, "Edited")
        XCTAssertEqual(rebased.first(where: { $0.id == second.id })?.label, "Second")
    }

    func testConfirmedSleepRebaseDoesNotResurrectConcurrentRecord() {
        let first = confirmedSleep(id: "first")
        let second = confirmedSleep(id: "second")
        let rebased = SessionStore.rebasedConfirmedSleeps(
            base: [first],
            desired: [],
            current: [first, second]
        )

        XCTAssertEqual(rebased.map(\.id), ["second"])
    }

    func testConfirmedRecordRebaseUsesDeterministicLastDuplicateWithoutTrapping() {
        let workout = confirmedWorkout(id: "duplicate", label: "Original")
        let staleDuplicate = confirmedWorkout(id: "duplicate", label: "Stale")
        let finalDuplicate = confirmedWorkout(id: "duplicate", label: "Final")
        let workoutResult = SessionStore.rebasedConfirmedWorkouts(
            base: [workout, staleDuplicate],
            desired: [staleDuplicate, finalDuplicate],
            current: [workout, staleDuplicate]
        )
        XCTAssertEqual(workoutResult.filter { $0.id == "duplicate" }.count, 1)
        XCTAssertEqual(workoutResult.filter { $0.id == "duplicate" }.first?.label, "Final")

        let sleep = confirmedSleep(id: "duplicate")
        let sleepResult = SessionStore.rebasedConfirmedSleeps(
            base: [sleep, sleep],
            desired: [sleep, sleep],
            current: [sleep, sleep]
        )
        XCTAssertEqual(sleepResult.filter { $0.id == "duplicate" }.count, 1)
    }

    func testRestoreFenceOwnsAndDrainsConfirmedRecordLaneBeforeOtherWriters() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func beginRestorePersistenceFence() async"))
        let end = try XCTUnwrap(
            source.range(of: "private func endRestorePersistenceFence()", range: start.upperBound..<source.endIndex)
        )
        let begin = String(source[start.lowerBound..<end.lowerBound])
        let blocksProducers = try XCTUnwrap(begin.range(of: "restorePersistenceFenceActive = true"))
        let ownsLane = try XCTUnwrap(begin.range(of: "await Self.confirmedRecordTransactionGate.acquire()"))
        let drainsWriter = try XCTUnwrap(begin.range(of: "await Self.confirmedRecordWorker.fence()"))
        XCTAssertLessThan(blocksProducers.lowerBound, ownsLane.lowerBound)
        XCTAssertLessThan(ownsLane.lowerBound, drainsWriter.lowerBound)
    }

    func testConfirmedWorkoutWriterFailsClosedWhenAuthoritativeFileCannotWrite() {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-confirmed-writer-\(UUID().uuidString)")
        let result = AtriaConfirmedRecordWriter.write(.workouts(
            generation: 9,
            records: [confirmedWorkout(id: "failure", label: "Failure")],
            fileURL: missingDirectory.appendingPathComponent("confirmed-workouts.json"),
            defaultsKey: "atria.tests.confirmed-workout-failure.\(UUID().uuidString)"
        ))

        guard case .failure(let generation, let domain, _) = result else {
            return XCTFail("Expected authoritative write failure")
        }
        XCTAssertEqual(generation, 9)
        XCTAssertEqual(domain, "workouts")
    }

    func testDailyRollupFencePersistsOnlyNewestPausedCacheImage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-rollup-fence-tests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("daily-rollups.json")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let store = DailyRollupStore(url: url,
                                     recoveryMetricsURL: nil,
                                     loadPersisted: false)

        await store.beginPersistenceFence()
        store.replaceAll([DailyRollupStoreEntry(day: day, recovery: 41)])
        store.replaceAll([DailyRollupStoreEntry(day: day, recovery: 82)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        store.endPersistenceFence()
        // Starting another fence drains the serial persistence queue, giving
        // this test a deterministic durability boundary without sleeping.
        await store.beginPersistenceFence()
        let persisted = try JSONDecoder().decode([DailyRollupStoreEntry].self,
                                                 from: Data(contentsOf: url))
        store.endPersistenceFence(persistCurrentSnapshot: false)

        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.recovery, 82)
    }

    func testPreRestoreSafetyBackupPruningIsBoundedAndCanClearAfterCommit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-pre-restore-prune-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<4 {
            let url = directory.appendingPathComponent("20260715T12000\(index)Z-pre-restore.json.gz")
            try Data([UInt8(index)]).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: url.path
            )
        }

        SessionStore.prunePreRestoreBackups(in: directory, keep: 1)
        XCTAssertEqual(try preRestoreFiles(in: directory).count, 1)

        SessionStore.prunePreRestoreBackups(in: directory, keep: 0)
        XCTAssertTrue(try preRestoreFiles(in: directory).isEmpty)
    }

    private func preRestoreFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory,
                                                    includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("-pre-restore") }
    }

    private func confirmedWorkout(id: String, label: String) -> UserConfirmedWorkout {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return UserConfirmedWorkout(
            id: id,
            createdAt: start,
            start: start,
            end: start.addingTimeInterval(1_800),
            label: label,
            source: "test",
            confidence: "user_confirmed",
            sessions: 1,
            samples: 100,
            avgHR: 120,
            peakHR: 150,
            p95HR: 145,
            p99HR: 149,
            thresholdHR: 110,
            streamCoveragePercent: 95,
            observedDuration: 1_800,
            reason: "test"
        )
    }

    private func confirmedSleep(id: String) -> UserConfirmedSleep {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return UserConfirmedSleep(
            id: id,
            createdAt: start,
            start: start,
            end: start.addingTimeInterval(8 * 60 * 60),
            source: "manual_sleep",
            confidence: "manual_user_entered",
            sessions: 1,
            samples: 1_000,
            avgHR: 60,
            peakHR: 90,
            restingHR: 52,
            hrv: 48,
            hrvWindowCount: 4,
            respiratoryRate: 15.2,
            duration: 8 * 60 * 60,
            span: 8 * 60 * 60,
            reason: "fixture",
            motionSource: "manual",
            motionValidated: false,
            stageSegments: nil,
            eventTimeZoneIdentifier: "UTC"
        )
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
