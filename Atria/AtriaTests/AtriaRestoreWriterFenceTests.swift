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
