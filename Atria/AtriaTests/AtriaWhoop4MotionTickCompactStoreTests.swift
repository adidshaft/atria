import XCTest
@testable import Atria

final class AtriaWhoop4MotionTickCompactStoreTests: XCTestCase {
    private enum InjectedWriteFailure: Error {
        case partialRecord
    }

    private final class StepClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func next() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private final class DecodeProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var ranges: [(start: Int, end: Int)] = []

        @discardableResult
        func record(start: Int, end: Int) -> Int {
            lock.lock()
            defer { lock.unlock() }
            ranges.append((start, end))
            return ranges.count
        }

        func snapshot() -> [(start: Int, end: Int)] {
            lock.lock()
            defer { lock.unlock() }
            return ranges
        }
    }

    private var directory: URL!
    private var store: AtriaWhoop4MotionTickCompactStore!
    private var strapIdentifier: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AtriaWhoop4MotionTickCompactStoreTests-\(UUID().uuidString)"
            )
        store = AtriaWhoop4MotionTickCompactStore(
            directoryURL: directory
        )
        strapIdentifier = UUID().uuidString
    }

    override func tearDownWithError() throws {
        store = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testDuplicateCanonicalPayloadIsIdempotent() throws {
        let unix = UInt32(Date().timeIntervalSince1970.rounded(.down))
        let record = makeRecord(unix: unix, flash: 1, tick: 1)
        let payload = payloadIdentity(unix: unix, tick: 1)

        XCTAssertTrue(
            try store.append(
                record: record,
                rawPayload: payload,
                strapIdentifier: strapIdentifier
            )
        )
        XCTAssertFalse(
            try store.append(
                record: record,
                rawPayload: payload,
                strapIdentifier: strapIdentifier
            )
        )
    }

    func testSynchronizePublishesOnlyNewDurableGenerations() async throws {
        let unix = UInt32(Date().timeIntervalSince1970.rounded(.down))
        let firstPublication = expectation(
            description: "first durable compact generation"
        )
        var observer = NotificationCenter.default.addObserver(
            forName: AtriaWhoop4MotionTickCompactStore
                .didSynchronizeNotification,
            object: nil,
            queue: .main
        ) { _ in
            firstPublication.fulfill()
        }
        try appendPoint(base: unix, second: 0)
        try store.synchronize()
        await fulfillment(of: [firstPublication], timeout: 1)
        NotificationCenter.default.removeObserver(observer)

        let duplicatePublication = expectation(
            description: "no duplicate publication without a new append"
        )
        duplicatePublication.isInverted = true
        observer = NotificationCenter.default.addObserver(
            forName: AtriaWhoop4MotionTickCompactStore
                .didSynchronizeNotification,
            object: nil,
            queue: .main
        ) { _ in
            duplicatePublication.fulfill()
        }
        try store.synchronize()
        await fulfillment(of: [duplicatePublication], timeout: 0.1)
        NotificationCenter.default.removeObserver(observer)

        let secondPublication = expectation(
            description: "second durable compact generation"
        )
        observer = NotificationCenter.default.addObserver(
            forName: AtriaWhoop4MotionTickCompactStore
                .didSynchronizeNotification,
            object: nil,
            queue: .main
        ) { _ in
            secondPublication.fulfill()
        }
        try appendPoint(base: unix, second: 1)
        try store.synchronize()
        await fulfillment(of: [secondPublication], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
    }

    func testHistoricalDrainPublishesCompactStepsAtDurableCheckpoints()
        throws
    {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let checkpointStart = try XCTUnwrap(source.range(
            of: "if let checkpoint = checkpointCoordinator.recordPersistence("
        ))
        let callbackStart = try XCTUnwrap(source.range(
            of: "Task { @MainActor [weak self] in",
            range: checkpointStart.upperBound..<source.endIndex
        ))
        let checkpoint = String(
            source[checkpointStart.lowerBound..<callbackStart.lowerBound]
        )

        let rawSync = try XCTUnwrap(checkpoint.range(
            of: ".synchronizeDurableStorage(generation: generation)"
        ))
        let admission = try XCTUnwrap(checkpoint.range(
            of: "markCurrentPrefixArchiveDurableWithReceipt"
        ))
        let compactSync = try XCTUnwrap(checkpoint.range(
            of: "AtriaWhoop4MotionTickCompactStore.shared"
        ))
        let completed = try XCTUnwrap(checkpoint.range(
            of: "checkpointCoordinator.checkpointCompleted("
        ))

        XCTAssertLessThan(rawSync.lowerBound, admission.lowerBound)
        XCTAssertLessThan(admission.lowerBound, compactSync.lowerBound)
        XCTAssertLessThan(compactSync.lowerBound, completed.lowerBound)
        XCTAssertTrue(
            checkpoint.contains("checkpoint_flush_failed"),
            "compact cache failure must not invalidate canonical durability"
        )
    }

    func testExactWindowRequiresAtLeastNinetyPercentCoverage() async throws {
        let base = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 120
        for second in 0..<89 {
            try appendPoint(base: base, second: second)
        }
        let start = Date(timeIntervalSince1970: TimeInterval(base))
        let end = Date(timeIntervalSince1970: TimeInterval(base + 99))
        let below = await coverage(
            start: start,
            end: end,
            strapIdentifier: strapIdentifier
        )
        XCTAssertEqual(below.expectedSeconds, 100)
        XCTAssertEqual(below.observedSeconds, 89)
        XCTAssertFalse(below.satisfiesNinetyPercentExactWindow)

        try appendPoint(base: base, second: 89)
        let passing = await coverage(
            start: start,
            end: end,
            strapIdentifier: strapIdentifier
        )
        XCTAssertEqual(passing.observedSeconds, 90)
        XCTAssertEqual(passing.densityPercent, 90)
        XCTAssertEqual(passing.maximumMissingRunSeconds, 10)
        XCTAssertTrue(passing.satisfiesNinetyPercentExactWindow)
    }

    func testConfirmedWorkoutWindowPublishesFromCompactCorrectedTimeline()
        async throws {
        let base = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 180
        let duration: TimeInterval = 92.3
        let count = 97
        let sampleRate = Double(count - 1) / duration
        let points = (0..<count).map { index in
            let elapsed = Double(index) / sampleRate
            let phase = 2 * Double.pi * 0.42 * elapsed
            let textureScale = 0.55
            return AtriaWhoop4MotionTickCompactStore.MigrationPoint(
                timestamp: TimeInterval(base) + elapsed,
                flash: UInt32(index),
                tick: index * 2,
                gravityX: textureScale * (
                    0.073 * sin(phase)
                        + 0.16 * pseudoNoise(index, channel: 1)
                ),
                gravityY: textureScale * (
                    0.073 * cos(phase)
                        + 0.16 * pseudoNoise(index, channel: 2)
                ),
                gravityZ: 1 + textureScale * 0.16
                    * pseudoNoise(index, channel: 3),
                unknownMotionScalar32: 0.12,
                rawPayload: payloadIdentity(
                    unix: base + UInt32(index),
                    tick: index * 2
                )
            )
        }
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        try await Task.detached(priority: .utility) {
            _ = try store.appendMigrated(
                points,
                strapIdentifier: strapIdentifier
            )
            try store.synchronize()
        }.value

        let read = await Task.detached(priority: .utility) {
            store.motionTickWindowRead(
                start: Date(timeIntervalSince1970: TimeInterval(base)),
                end: Date(
                    timeIntervalSince1970: TimeInterval(base) + duration
                ),
                strapIdentifier: strapIdentifier
            )
        }.value
        guard case .qualified(let window) = read else {
            return XCTFail("expected the compact workout window to qualify")
        }
        XCTAssertEqual(window.steps, 133)
        XCTAssertEqual(window.delta, 192)
        XCTAssertEqual(window.coverageFraction, 1, accuracy: 0.000_001)
        XCTAssertEqual(window.decodedRows, count)
    }

    func testMissingCompactWorkoutBoundaryNeverClaimsNegativeEvidence()
        async throws {
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let start = Date().addingTimeInterval(-120)
        let read = await Task.detached(priority: .utility) {
            store.motionTickWindowRead(
                start: start,
                end: start.addingTimeInterval(90),
                strapIdentifier: strapIdentifier
            )
        }.value
        XCTAssertEqual(read, .incomplete)
    }

    func testCompactWorkoutWindowRefusesMoreThanRetainedFourBuckets()
        async throws {
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let start = Date().addingTimeInterval(-5 * 86_400)
        let read = await Task.detached(priority: .utility) {
            store.motionTickWindowRead(
                start: start,
                end: Date(),
                strapIdentifier: strapIdentifier
            )
        }.value
        XCTAssertEqual(read, .incomplete)
    }

    func testStrapIdentityCannotReadAnotherStrapsShard() async throws {
        let unix = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 10
        try appendPoint(base: unix, second: 0)
        let coverage = await coverage(
            start: Date(timeIntervalSince1970: TimeInterval(unix)),
            end: Date(timeIntervalSince1970: TimeInterval(unix + 1)),
            strapIdentifier: UUID().uuidString
        )
        XCTAssertEqual(coverage.observedSeconds, 0)
        XCTAssertFalse(coverage.satisfiesNinetyPercentExactWindow)
    }

    func testSourceFingerprintChangesWhenCompactShardGrows() async throws {
        let unix = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 10
        let start = Date(timeIntervalSince1970: TimeInterval(unix))
        let end = start.addingTimeInterval(60)
        let before = await sourceFingerprint(start: start, end: end)

        try appendPoint(base: unix, second: 0)
        let afterFirstAppend = await sourceFingerprint(
            start: start,
            end: end
        )
        XCTAssertNotEqual(before, afterFirstAppend)

        let duplicate = try store.append(
            record: makeRecord(unix: unix, flash: 1, tick: 0),
            rawPayload: payloadIdentity(unix: unix, tick: 0),
            strapIdentifier: strapIdentifier
        )
        XCTAssertFalse(duplicate)
        let afterDuplicate = await sourceFingerprint(start: start, end: end)
        XCTAssertEqual(afterFirstAppend, afterDuplicate)
    }

    func testOneCompactReadCanVerifyMultipleExactTickets() async throws {
        let base = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 120
        for second in 0..<100 {
            try appendPoint(base: base, second: second)
        }
        let tickets = [
            AtriaWhoop4MotionBankCoverageLedger.OffloadTicket(
                id: "first",
                strapIdentifier: strapIdentifier,
                start: Date(timeIntervalSince1970: TimeInterval(base)),
                end: Date(timeIntervalSince1970: TimeInterval(base + 49)),
                armedConnectionStartedAt: nil,
                attempts: 1,
                lastAttemptAt: nil
            ),
            AtriaWhoop4MotionBankCoverageLedger.OffloadTicket(
                id: "second",
                strapIdentifier: strapIdentifier,
                start: Date(timeIntervalSince1970: TimeInterval(base + 50)),
                end: Date(timeIntervalSince1970: TimeInterval(base + 99)),
                armedConnectionStartedAt: nil,
                attempts: 0,
                lastAttemptAt: nil
            ),
        ]
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let coverages = await Task.detached(priority: .utility) {
            store.transportCoverages(
                tickets: tickets,
                strapIdentifier: strapIdentifier
            )
        }.value
        XCTAssertEqual(coverages.count, 2)
        XCTAssertTrue(try XCTUnwrap(coverages["first"])
            .satisfiesNinetyPercentExactWindow)
        XCTAssertTrue(try XCTUnwrap(coverages["second"])
            .satisfiesNinetyPercentExactWindow)
    }

    func testIndexedTransportCoveragesMatchLegacyOracleForLargeTicketSet() {
        let base = 10_000.0
        var points: [AtriaWhoop4MotionTickCompactStore.Point] = []
        for second in 0..<5_000 where second % 7 != 0 {
            let timestamp = base + Double(second)
                + (second.isMultiple(of: 2) ? 0.125 : 0.875)
            points.append(dayEvidencePoint(
                timestamp: timestamp,
                tick: second,
                identity: "point-\(second)"
            ))
            if second.isMultiple(of: 113) {
                points.append(dayEvidencePoint(
                    timestamp: timestamp,
                    tick: second,
                    identity: "duplicate-\(second)"
                ))
            }
        }
        let tickets = (0..<166).map { index in
            let start = Date(timeIntervalSince1970:
                base + Double(index * 23) + 0.55)
            return AtriaWhoop4MotionBankCoverageLedger.OffloadTicket(
                id: "ticket-\(index)",
                strapIdentifier: strapIdentifier,
                start: start,
                end: start.addingTimeInterval(
                    Double(45 + (index % 19) * 17)
                ),
                armedConnectionStartedAt: nil,
                attempts: index % 3,
                lastAttemptAt: nil
            )
        }
        let indexed = AtriaWhoop4MotionTickCompactStore
            .transportCoveragesForTesting(
                points: Array(points.reversed()),
                tickets: tickets,
                strapIdentifier: strapIdentifier
            )

        XCTAssertEqual(indexed.count, tickets.count)
        for ticket in tickets {
            XCTAssertEqual(
                indexed[ticket.id],
                referenceTransportCoverage(
                    points: points,
                    start: ticket.start,
                    end: ticket.end
                ),
                ticket.id
            )
        }
    }

    func testConcurrentOverlappingPrefixReadsShareOneDecoderAndDoNotHoldStoreLock()
        async throws
    {
        let base = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 120
        for second in 0..<32 {
            try appendPoint(base: base, second: second)
        }
        try store.synchronize()
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let start = Date(timeIntervalSince1970: TimeInterval(base))
        let end = Date(timeIntervalSince1970: TimeInterval(base + 60))
        let decodeEntered = DispatchSemaphore(value: 0)
        let releaseDecode = DispatchSemaphore(value: 0)
        let probe = DecodeProbe()
        store.setDecodedPrefixDecodeHookForTesting { _, start, end in
            if probe.record(start: start, end: end) == 1 {
                decodeEntered.signal()
                releaseDecode.wait()
            }
        }
        defer {
            store.setDecodedPrefixDecodeHookForTesting(nil)
            releaseDecode.signal()
        }

        let first = Task.detached(priority: .utility) {
            store.decodedPointsForTesting(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier
            )
        }
        XCTAssertEqual(
            decodeEntered.wait(timeout: .now() + 1),
            .success
        )
        let second = Task.detached(priority: .utility) {
            store.decodedPointsForTesting(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier
            )
        }

        var waiterObserved = false
        for _ in 0..<100 {
            if store.decodedPrefixCacheStatisticsForTesting().waitCount > 0 {
                waiterObserved = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(
            waiterObserved,
            "the overlapping caller must wait for the one lineage decoder"
        )

        // The decoder hook is still blocked. A successful append proves the
        // filesystem/decode wait owns neither the append nor fsync lock.
        let appendedRecord = makeRecord(
            unix: base + 40,
            flash: 41,
            tick: 40
        )
        let appendedPayload = payloadIdentity(unix: base + 40, tick: 40)
        let appendFinished = DispatchSemaphore(value: 0)
        let append = Task.detached(priority: .utility) {
            defer { appendFinished.signal() }
            return try store.append(
                record: appendedRecord,
                rawPayload: appendedPayload,
                strapIdentifier: strapIdentifier
            )
        }
        let appendCompletedWithoutDecode =
            appendFinished.wait(timeout: .now() + 1) == .success
        releaseDecode.signal()

        XCTAssertTrue(appendCompletedWithoutDecode)
        let appendSucceeded = try await append.value
        XCTAssertTrue(appendSucceeded)
        let firstPoints = await first.value
        let secondPoints = await second.value
        XCTAssertEqual(firstPoints, secondPoints)
        XCTAssertEqual(firstPoints.count, 32)
        XCTAssertFalse(
            firstPoints.contains { $0.timestamp == TimeInterval(base + 40) },
            "an append after both captures must not leak into either prefix"
        )
        let statistics = store.decodedPrefixCacheStatisticsForTesting()
        XCTAssertEqual(statistics.decodePassCount, 1)
        XCTAssertGreaterThanOrEqual(statistics.waitCount, 1)
        XCTAssertEqual(probe.snapshot().count, 1)
    }

    func testInvalidationStopsStaleOwnerAndWaiterWithoutRedecode()
        async throws
    {
        let base = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 120
        for second in 0..<32 {
            try appendPoint(base: base, second: second)
        }
        try store.synchronize()
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let start = Date(timeIntervalSince1970: TimeInterval(base))
        let end = Date(timeIntervalSince1970: TimeInterval(base + 60))
        let decodeEntered = DispatchSemaphore(value: 0)
        let releaseDecode = DispatchSemaphore(value: 0)
        let waiterFinished = DispatchSemaphore(value: 0)
        let probe = DecodeProbe()
        store.setDecodedPrefixDecodeHookForTesting { _, start, end in
            if probe.record(start: start, end: end) == 1 {
                decodeEntered.signal()
                releaseDecode.wait()
            }
        }
        defer {
            store.setDecodedPrefixDecodeHookForTesting(nil)
            releaseDecode.signal()
        }

        let owner = Task.detached(priority: .userInitiated) {
            store.decodedPointsForTesting(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier
            )
        }
        XCTAssertEqual(
            decodeEntered.wait(timeout: .now() + 1),
            .success
        )
        let waiter = Task.detached(priority: .userInitiated) {
            defer { waiterFinished.signal() }
            return store.decodedPointsForTesting(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier
            )
        }

        var waiterObserved = false
        for _ in 0..<100 {
            if store.decodedPrefixCacheStatisticsForTesting().waitCount > 0 {
                waiterObserved = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(waiterObserved)

        // Epoch invalidation wakes the stale waiter while the old owner is
        // still blocked. Neither may arbitrate another decode for that epoch.
        store.setDecodedPrefixCacheBudgetForTesting(
            maximumEntries: 2,
            maximumSourceBytes: 12 * 1_024 * 1_024,
            maximumPoints: 200_000
        )
        XCTAssertEqual(
            waiterFinished.wait(timeout: .now() + 1),
            .success
        )
        XCTAssertEqual(probe.snapshot().count, 1)
        XCTAssertEqual(
            store.decodedPrefixCacheStatisticsForTesting().entryCount,
            0
        )

        releaseDecode.signal()
        let ownerPoints = await owner.value
        let waiterPoints = await waiter.value
        XCTAssertTrue(ownerPoints.isEmpty)
        XCTAssertTrue(waiterPoints.isEmpty)
        let statistics = store.decodedPrefixCacheStatisticsForTesting()
        XCTAssertEqual(statistics.decodePassCount, 1)
        XCTAssertEqual(statistics.entryCount, 0)
        XCTAssertEqual(statistics.activeDecoderCount, 0)
        XCTAssertEqual(probe.snapshot().count, 1)
    }

    func testAppendGrowthDecodesOnlySuffixAndMatchesFreshStoreExactly()
        async throws
    {
        let base = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 60
        try appendPoint(base: base, second: 0)
        try appendPoint(base: base, second: 1)
        try store.synchronize()
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let start = Date(timeIntervalSince1970: TimeInterval(base))
        let end = Date(timeIntervalSince1970: TimeInterval(base + 10))
        let probe = DecodeProbe()
        store.setDecodedPrefixDecodeHookForTesting { _, start, end in
            probe.record(start: start, end: end)
        }
        defer { store.setDecodedPrefixDecodeHookForTesting(nil) }

        let first = await Task.detached(priority: .utility) {
            store.decodedPointsForTesting(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier
            )
        }.value
        XCTAssertEqual(first.count, 2)

        try appendPoint(base: base, second: 2)
        try store.synchronize()
        let grown = await Task.detached(priority: .utility) {
            store.decodedPointsForTesting(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier
            )
        }.value
        XCTAssertEqual(grown.count, 3)
        XCTAssertEqual(
            probe.snapshot().map { [$0.start, $0.end] },
            [[0, 104], [104, 156]],
            "append-only growth must decode only the new fixed-width suffix"
        )

        let freshStore = AtriaWhoop4MotionTickCompactStore(
            directoryURL: directory
        )
        let fresh = await Task.detached(priority: .utility) {
            freshStore.decodedPointsForTesting(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier
            )
        }.value
        XCTAssertEqual(grown, fresh)
        XCTAssertTrue(grown.allSatisfy {
            $0.identity.count == 32
                && $0.identity.allSatisfy {
                    $0.isNumber || ("a"..."f").contains(String($0))
                }
        })
    }

    func testTailRepairInvalidatesDecodedPrefixAndForcesFullDecode()
        async throws
    {
        let base = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 60
        try appendPoint(base: base, second: 0)
        try appendPoint(base: base, second: 1)
        try store.synchronize()
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let start = Date(timeIntervalSince1970: TimeInterval(base))
        let end = Date(timeIntervalSince1970: TimeInterval(base + 10))
        let probe = DecodeProbe()
        store.setDecodedPrefixDecodeHookForTesting { _, start, end in
            probe.record(start: start, end: end)
        }
        defer { store.setDecodedPrefixDecodeHookForTesting(nil) }

        let before = await Task.detached(priority: .utility) {
            store.decodedPointsForTesting(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier
            )
        }.value
        let cached = store.decodedPrefixCacheStatisticsForTesting()
        XCTAssertEqual(cached.entryCount, 1)

        let shard = try onlyShard()
        let tornWriter = try FileHandle(forWritingTo: shard)
        try tornWriter.seekToEnd()
        try tornWriter.write(contentsOf: Data([0x41]))
        try tornWriter.close()
        try store.repairPartialTailForTesting(at: shard)
        let invalidated = store.decodedPrefixCacheStatisticsForTesting()
        XCTAssertEqual(invalidated.entryCount, 0)
        XCTAssertGreaterThan(invalidated.epoch, cached.epoch)

        let after = await Task.detached(priority: .utility) {
            store.decodedPointsForTesting(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier
            )
        }.value
        XCTAssertEqual(after, before)
        XCTAssertEqual(
            probe.snapshot().map { $0.start },
            [0, 0],
            "a repaired lineage must never reuse the pre-truncate prefix"
        )
    }

    func testRetentionDeletionInvalidatesResidentDecodedPrefix()
        async throws
    {
        let now = UInt32(Date().timeIntervalSince1970.rounded(.down))
        let oldBase = now - UInt32(5 * 86_400)
        try appendPoint(base: oldBase, second: 0)
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let oldStart = Date(timeIntervalSince1970: TimeInterval(oldBase))
        let oldEnd = oldStart.addingTimeInterval(1)
        let oldPoints = await Task.detached(priority: .utility) {
            store.decodedPointsForTesting(
                start: oldStart,
                end: oldEnd,
                strapIdentifier: strapIdentifier
            )
        }.value
        XCTAssertEqual(oldPoints.count, 1)
        let cached = store.decodedPrefixCacheStatisticsForTesting()
        XCTAssertEqual(cached.entryCount, 1)

        // Moving the retention bucket forward deletes the five-day-old shard
        // and must synchronously revoke its resident decoded lineage.
        try appendPoint(base: now, second: 0)
        let invalidated = store.decodedPrefixCacheStatisticsForTesting()
        XCTAssertEqual(invalidated.entryCount, 0)
        XCTAssertGreaterThan(invalidated.epoch, cached.epoch)
        let retired = await Task.detached(priority: .utility) {
            store.decodedPointsForTesting(
                start: oldStart,
                end: oldEnd,
                strapIdentifier: strapIdentifier
            )
        }.value
        XCTAssertTrue(retired.isEmpty)
    }

    func testDecodedPrefixCacheEvictsDeterministicallyWithinBudget()
        async throws
    {
        store.setDecodedPrefixCacheBudgetForTesting(
            maximumEntries: 1,
            maximumSourceBytes: 52,
            maximumPoints: 1
        )
        let day = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let firstBase = day - UInt32(2 * 86_400) + 3_600
        let secondBase = day - UInt32(86_400) + 3_600
        try appendPoint(base: firstBase, second: 0)
        try appendPoint(base: secondBase, second: 0)
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)

        func read(_ base: UInt32) async -> [AtriaWhoop4MotionTickCompactStore.Point] {
            await Task.detached(priority: .utility) {
                store.decodedPointsForTesting(
                    start: Date(
                        timeIntervalSince1970: TimeInterval(base)
                    ),
                    end: Date(
                        timeIntervalSince1970: TimeInterval(base + 1)
                    ),
                    strapIdentifier: strapIdentifier
                )
            }.value
        }

        let firstRead = await read(firstBase)
        let secondRead = await read(secondBase)
        XCTAssertEqual(firstRead.count, 1)
        XCTAssertEqual(secondRead.count, 1)
        var statistics = store.decodedPrefixCacheStatisticsForTesting()
        XCTAssertEqual(statistics.entryCount, 1)
        XCTAssertEqual(statistics.sourceBytes, 52)
        XCTAssertEqual(statistics.pointCount, 1)
        XCTAssertEqual(statistics.decodePassCount, 2)

        let rereadFirst = await read(firstBase)
        XCTAssertEqual(rereadFirst.count, 1)
        statistics = store.decodedPrefixCacheStatisticsForTesting()
        XCTAssertEqual(statistics.entryCount, 1)
        XCTAssertEqual(statistics.sourceBytes, 52)
        XCTAssertEqual(statistics.pointCount, 1)
        XCTAssertEqual(
            statistics.decodePassCount,
            3,
            "the least-recently-used one-entry cache must evict exactly once"
        )
    }

    func testCanonicalMigrationIsIdempotentAndAdvancesFingerprint() async throws {
        let unix = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 10
        let start = Date(timeIntervalSince1970: TimeInterval(unix))
        let end = start.addingTimeInterval(60)
        let before = await sourceFingerprint(start: start, end: end)
        let point = AtriaWhoop4MotionTickCompactStore.MigrationPoint(
            timestamp: TimeInterval(unix),
            flash: 7,
            tick: 3,
            gravityX: 0,
            gravityY: 0,
            gravityZ: 1,
            unknownMotionScalar32: 0.05,
            rawPayload: payloadIdentity(unix: unix, tick: 3)
        )
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let first = try await Task.detached(priority: .utility) {
            try store.appendMigrated(
                [point],
                strapIdentifier: strapIdentifier
            )
        }.value
        let second = try await Task.detached(priority: .utility) {
            try store.appendMigrated(
                [point],
                strapIdentifier: strapIdentifier
            )
        }.value

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)
        let after = await sourceFingerprint(start: start, end: end)
        XCTAssertNotEqual(before, after)
    }

    func testLatestNightStrictReadIsBoundedAndAdmittedUnderSerious()
        async throws
    {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        for second in stride(from: 0, through: 600, by: 5) {
            try appendPoint(base: base, second: second)
        }
        try store.synchronize()

        let read = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(base)),
            end: Date(timeIntervalSince1970: TimeInterval(base + 600)),
            thermalState: .serious
        )
        guard case .qualified(let evidence) = read else {
            return XCTFail("expected strict compact evidence under serious thermal")
        }
        XCTAssertEqual(evidence.receipt.shardCount, 1)
        XCTAssertEqual(evidence.receipt.mappedBytes, 121 * 52)
        XCTAssertEqual(evidence.receipt.rowCount, 121)
        XCTAssertEqual(evidence.receipt.matchedRowCount, 121)
        XCTAssertEqual(evidence.receipt.sourceFingerprint.count, 64)
        XCTAssertTrue(evidence.epochs.contains { $0.measurementValidated })
        XCTAssertTrue(store.latestNightReceiptIsCurrent(evidence.receipt))
    }

    func testLatestNightStrictReadRejectsCriticalThermal() async throws {
        let now = Date()
        let read = await latestNightRead(
            start: now.addingTimeInterval(-60),
            end: now,
            thermalState: .critical
        )
        XCTAssertEqual(read, .incomplete(.thermalCritical))
    }

    func testLatestNightStrictReadRejectsMoreThanTwoShards() async throws {
        let bucketStart = floor(
            Date().timeIntervalSince1970 / 86_400
        ) * 86_400
        let read = await latestNightRead(
            start: Date(timeIntervalSince1970: bucketStart - 86_400),
            end: Date(timeIntervalSince1970: bucketStart + 86_400.1),
            thermalState: .nominal
        )
        XCTAssertEqual(read, .incomplete(.shardCapExceeded))
    }

    func testLatestNightStrictReadEnforcesByteAndRowCaps() async throws {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        try appendPoint(base: base, second: 0)
        try appendPoint(base: base, second: 1)
        try store.synchronize()
        let start = Date(timeIntervalSince1970: TimeInterval(base))
        let end = start.addingTimeInterval(2)

        let byteLimited = await latestNightRead(
            start: start,
            end: end,
            thermalState: .serious,
            budget: .init(
                maximumShardCount: 2,
                maximumMappedBytes: 52,
                maximumRows: 200_000,
                deadlineSeconds: 2
            )
        )
        XCTAssertEqual(byteLimited, .incomplete(.byteCapExceeded))

        let rowLimited = await latestNightRead(
            start: start,
            end: end,
            thermalState: .serious,
            budget: .init(
                maximumShardCount: 2,
                maximumMappedBytes: 10 * 1_024 * 1_024,
                maximumRows: 1,
                deadlineSeconds: 2
            )
        )
        XCTAssertEqual(rowLimited, .incomplete(.rowCapExceeded))
    }

    func testLatestNightStrictReadDoesNotRepairTornTail() async throws {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        try appendPoint(base: base, second: 0)
        try store.synchronize()
        store = nil
        let shard = try onlyShard()
        let handle = try FileHandle(forWritingTo: shard)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x41]))
        try handle.synchronize()
        try handle.close()
        store = AtriaWhoop4MotionTickCompactStore(directoryURL: directory)

        let read = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(base)),
            end: Date(timeIntervalSince1970: TimeInterval(base + 1)),
            thermalState: .serious
        )
        XCTAssertEqual(read, .incomplete(.integrityFailure))
        XCTAssertEqual(try shardSize(shard), 53)
    }

    func testLatestNightReceiptCASAllowsAppendOnlyGrowth() async throws {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        try appendPoint(base: base, second: 0)
        try store.synchronize()
        let read = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(base)),
            end: Date(timeIntervalSince1970: TimeInterval(base + 60)),
            thermalState: .serious
        )
        guard case .qualified(let evidence) = read else {
            return XCTFail("expected an initial strict receipt")
        }
        try appendPoint(base: base, second: 1)
        XCTAssertTrue(store.latestNightReceiptIsCurrent(evidence.receipt))
    }

    func testLatestNightCommitAuthorityAcceptsBackfillAfterAtomicPrefix()
        async throws
    {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        try appendPoint(base: base, second: 0)
        try store.synchronize()
        let read = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(base)),
            end: Date(timeIntervalSince1970: TimeInterval(base + 60)),
            thermalState: .serious
        )
        guard case .qualified(let evidence) = read else {
            return XCTFail("expected initial strict receipt")
        }
        try appendPoint(base: base, second: 1)
        let store = try XCTUnwrap(store)
        let authority = await Task.detached(priority: .utility) {
            store.mintLatestNightCommitAuthority(
                for: evidence.receipt,
                strapIdentifier: self.strapIdentifier,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            )
        }.value
        let unwrapped = try XCTUnwrap(authority)
        XCTAssertTrue(store.consumeLatestNightCommitAuthority(
            unwrapped,
            currentStrapIdentifier: strapIdentifier
        ))
    }

    func testLatestNightCommitAuthorityAcceptsOnlyFutureTailAndIsSingleUse()
        async throws
    {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        try appendPoint(base: base, second: 0)
        try store.synchronize()
        let read = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(base)),
            end: Date(timeIntervalSince1970: TimeInterval(base + 60)),
            thermalState: .serious
        )
        guard case .qualified(let evidence) = read else {
            return XCTFail("expected initial strict receipt")
        }
        try appendPoint(base: base, second: 61)
        let store = try XCTUnwrap(store)
        let authority = await Task.detached(priority: .utility) {
            store.mintLatestNightCommitAuthority(
                for: evidence.receipt,
                strapIdentifier: self.strapIdentifier,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            )
        }.value
        let unwrapped = try XCTUnwrap(authority)
        XCTAssertTrue(store.consumeLatestNightCommitAuthority(
            unwrapped,
            currentStrapIdentifier: strapIdentifier
        ))
        XCTAssertFalse(store.consumeLatestNightCommitAuthority(
            unwrapped,
            currentStrapIdentifier: strapIdentifier
        ))
    }

    func testLatestNightCommitConsumeDoesNotBlockOrSpendAuthorityWhenBusy()
        async throws
    {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        try appendPoint(base: base, second: 0)
        try store.synchronize()
        let read = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(base)),
            end: Date(timeIntervalSince1970: TimeInterval(base + 60)),
            thermalState: .serious
        )
        guard case .qualified(let evidence) = read else {
            return XCTFail("expected initial strict receipt")
        }
        let store = try XCTUnwrap(store)
        let mintedAuthority = await Task.detached(priority: .utility) {
            store.mintLatestNightCommitAuthority(
                for: evidence.receipt,
                strapIdentifier: self.strapIdentifier,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            )
        }.value
        let authority = try XCTUnwrap(mintedAuthority)
        let acquired = expectation(description: "store lock held")
        let release = DispatchSemaphore(value: 0)
        let holder = Task.detached(priority: .utility) {
            store.withStoreLockHeldForTesting {
                acquired.fulfill()
                release.wait()
            }
        }
        await fulfillment(of: [acquired], timeout: 1)
        let releaser = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(50))
            release.signal()
        }

        XCTAssertFalse(store.consumeLatestNightCommitAuthority(
            authority,
            currentStrapIdentifier: strapIdentifier
        ))
        _ = await releaser.value
        _ = await holder.value
        XCTAssertTrue(
            store.consumeLatestNightCommitAuthority(
                authority,
                currentStrapIdentifier: strapIdentifier
            ),
            "a failed try-lock must not spend the one-shot authority"
        )
    }

    func testLatestNightCommitAuthorityRejectsStrapReplacementAfterMint()
        async throws
    {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        try appendPoint(base: base, second: 0)
        try store.synchronize()
        let read = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(base)),
            end: Date(timeIntervalSince1970: TimeInterval(base + 60)),
            thermalState: .serious
        )
        guard case .qualified(let evidence) = read else {
            return XCTFail("expected initial strict receipt")
        }
        let store = try XCTUnwrap(store)
        let sourceStrapIdentifier = try XCTUnwrap(strapIdentifier)
        let authority = await Task.detached(priority: .utility) {
            store.mintLatestNightCommitAuthority(
                for: evidence.receipt,
                strapIdentifier: sourceStrapIdentifier,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            )
        }.value
        let unwrapped = try XCTUnwrap(authority)
        let replacementStrapIdentifier = UUID().uuidString

        XCTAssertEqual(
            unwrapped.sourceStrapIdentifier,
            UUID(uuidString: sourceStrapIdentifier)
        )
        XCTAssertFalse(store.consumeLatestNightCommitAuthority(
            unwrapped,
            currentStrapIdentifier: replacementStrapIdentifier
        ))
        XCTAssertFalse(
            store.consumeLatestNightCommitAuthority(
                unwrapped,
                currentStrapIdentifier: sourceStrapIdentifier
            ),
            "identity mismatch must consume the one-shot authority"
        )
    }

    func testLatestNightCommitAuthorityRejectsTornCurrentShard()
        async throws
    {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        try appendPoint(base: base, second: 0)
        try store.synchronize()
        let read = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(base)),
            end: Date(timeIntervalSince1970: TimeInterval(base + 60)),
            thermalState: .serious
        )
        guard case .qualified(let evidence) = read else {
            return XCTFail("expected initial strict receipt")
        }
        let store = try XCTUnwrap(store)
        let handle = try FileHandle(forWritingTo: onlyShard())
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x41]))
        try handle.synchronize()
        try handle.close()
        let torn = await Task.detached(priority: .utility) {
            store.mintLatestNightCommitAuthority(
                for: evidence.receipt,
                strapIdentifier: self.strapIdentifier,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            )
        }.value
        XCTAssertNil(torn)
    }

    func testLatestNightCommitAuthoritySurvivesAppendAfterMint()
        async throws
    {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        try appendPoint(base: base, second: 0)
        try store.synchronize()
        let read = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(base)),
            end: Date(timeIntervalSince1970: TimeInterval(base + 60)),
            thermalState: .serious
        )
        guard case .qualified(let evidence) = read else {
            return XCTFail("expected initial strict receipt")
        }
        let store = try XCTUnwrap(store)
        let mintedAuthority = await Task.detached(priority: .utility) {
            store.mintLatestNightCommitAuthority(
                for: evidence.receipt,
                strapIdentifier: self.strapIdentifier,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            )
        }.value
        let authority = try XCTUnwrap(mintedAuthority)
        try appendPoint(base: base, second: 61)
        XCTAssertTrue(store.consumeLatestNightCommitAuthority(
            authority,
            currentStrapIdentifier: strapIdentifier
        ))
    }

    func testLatestNightCommitAuthorityRejectsStructuralChangeAfterMint()
        async throws
    {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        try appendPoint(base: base, second: 0)
        try store.synchronize()
        let read = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(base)),
            end: Date(timeIntervalSince1970: TimeInterval(base + 60)),
            thermalState: .serious
        )
        guard case .qualified(let evidence) = read else {
            return XCTFail("expected initial strict receipt")
        }
        let store = try XCTUnwrap(store)
        let mintedAuthority = await Task.detached(priority: .utility) {
            store.mintLatestNightCommitAuthority(
                for: evidence.receipt,
                strapIdentifier: self.strapIdentifier,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            )
        }.value
        let authority = try XCTUnwrap(mintedAuthority)

        // Opening a new shard changes the owned file set and therefore revokes
        // every authority even though ordinary same-shard appends do not.
        try appendPoint(base: base + 86_400, second: 0)
        XCTAssertFalse(store.consumeLatestNightCommitAuthority(
            authority,
            currentStrapIdentifier: strapIdentifier
        ))
    }

    func testTailRepairInvalidatesAuthorityBeforeInjectedSyncFailure()
        async throws
    {
        enum InjectedFailure: Error { case synchronize }
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        try appendPoint(base: base, second: 0)
        try store.synchronize()
        let read = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(base)),
            end: Date(timeIntervalSince1970: TimeInterval(base + 60)),
            thermalState: .serious
        )
        guard case .qualified(let evidence) = read else {
            return XCTFail("expected initial strict receipt")
        }
        let store = try XCTUnwrap(store)
        let mintedAuthority = await Task.detached(priority: .utility) {
            store.mintLatestNightCommitAuthority(
                for: evidence.receipt,
                strapIdentifier: self.strapIdentifier,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            )
        }.value
        let authority = try XCTUnwrap(mintedAuthority)
        let shard = try onlyShard()
        let tornWriter = try FileHandle(forWritingTo: shard)
        try tornWriter.seekToEnd()
        try tornWriter.write(contentsOf: Data([0x41]))
        try tornWriter.close()
        store.setTailRepairWillSynchronizeHookForTesting {
            throw InjectedFailure.synchronize
        }
        defer {
            store.setTailRepairWillSynchronizeHookForTesting(nil)
        }

        XCTAssertThrowsError(
            try store.repairPartialTailForTesting(at: shard)
        )
        XCTAssertEqual(try shardSize(shard) % 52, 0)
        XCTAssertFalse(store.consumeLatestNightCommitAuthority(
            authority,
            currentStrapIdentifier: strapIdentifier
        ))
    }

    func testLatestNightReceiptCASRejectsTruncation() async throws {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        try appendPoint(base: base, second: 0)
        try appendPoint(base: base, second: 1)
        try store.synchronize()
        let read = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(base)),
            end: Date(timeIntervalSince1970: TimeInterval(base + 60)),
            thermalState: .serious
        )
        guard case .qualified(let evidence) = read else {
            return XCTFail("expected an initial strict receipt")
        }
        let handle = try FileHandle(forUpdating: onlyShard())
        try handle.truncate(atOffset: 52)
        try handle.synchronize()
        try handle.close()
        XCTAssertFalse(store.latestNightReceiptIsCurrent(evidence.receipt))
    }

    func testLatestNightReceiptCASRejectsFileReplacement() async throws {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        try appendPoint(base: base, second: 0)
        try store.synchronize()
        let read = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(base)),
            end: Date(timeIntervalSince1970: TimeInterval(base + 60)),
            thermalState: .serious
        )
        guard case .qualified(let evidence) = read else {
            return XCTFail("expected an initial strict receipt")
        }
        let shard = try onlyShard()
        let bytes = try Data(contentsOf: shard)
        try FileManager.default.removeItem(at: shard)
        try bytes.write(to: shard, options: .atomic)
        XCTAssertFalse(store.latestNightReceiptIsCurrent(evidence.receipt))
    }

    func testLatestNightStrictReadRemainsBoundedDuringActiveAppend()
        async throws
    {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        try appendPoint(base: base, second: 0)
        let migrationPoints = (1...250).map { second in
            AtriaWhoop4MotionTickCompactStore.MigrationPoint(
                timestamp: TimeInterval(base) + TimeInterval(second),
                flash: UInt32(second + 1),
                tick: second,
                gravityX: 0,
                gravityY: 0,
                gravityZ: 1,
                unknownMotionScalar32: 0.05,
                rawPayload: payloadIdentity(
                    unix: base + UInt32(second),
                    tick: second
                )
            )
        }
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let start = Date(timeIntervalSince1970: TimeInterval(base))
        let end = Date(timeIntervalSince1970: TimeInterval(base + 300))
        let clockStart = DispatchTime.now().uptimeNanoseconds
        async let readTask = Task.detached(priority: .utility) {
            store.latestNightMotionRead(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier,
                thermalState: .serious
            )
        }.value
        async let appendTask = Task.detached(priority: .utility) {
            try store.appendMigrated(
                migrationPoints,
                strapIdentifier: strapIdentifier
            )
        }.value
        let (read, appended) = try await (readTask, appendTask)
        XCTAssertEqual(appended, 250)
        guard case .qualified(let evidence) = read else {
            return XCTFail("append-only catch-up must not starve strict reads")
        }
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - clockStart
        ) / 1_000_000_000
        XCTAssertLessThan(elapsed, 2)
        XCTAssertLessThanOrEqual(evidence.receipt.shardCount, 2)
        XCTAssertLessThanOrEqual(
            evidence.receipt.mappedBytes,
            10 * 1_024 * 1_024
        )
        XCTAssertLessThanOrEqual(evidence.receipt.rowCount, 200_000)
        XCTAssertTrue(store.latestNightReceiptIsCurrent(evidence.receipt))
    }

    func testAtomicPrefixAuthorityConvergesDuringContinuousInWindowBackfill()
        async throws
    {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        try appendPoint(base: base, second: 0)
        try store.synchronize()
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let start = Date(timeIntervalSince1970: TimeInterval(base))
        let end = Date(timeIntervalSince1970: TimeInterval(base + 1_200))
        let initialRead = await Task.detached(priority: .utility) {
            store.latestNightMotionRead(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier,
                thermalState: .serious
            )
        }.value
        guard case .qualified(let initialEvidence) = initialRead else {
            return XCTFail("expected an atomic initial prefix")
        }
        let points = (1...600).map { second in
            AtriaWhoop4MotionTickCompactStore.MigrationPoint(
                timestamp: TimeInterval(base + UInt32(second)),
                flash: UInt32(second + 1),
                tick: second,
                gravityX: 0,
                gravityY: 0,
                gravityZ: 1,
                unknownMotionScalar32: 0.05,
                rawPayload: payloadIdentity(
                    unix: base + UInt32(second),
                    tick: second
                )
            )
        }
        let appender = Task.detached(priority: .utility) {
            var appended = 0
            for point in points {
                appended += try store.appendMigrated(
                    [point],
                    strapIdentifier: strapIdentifier
                )
                try await Task.sleep(for: .microseconds(500))
            }
            return appended
        }
        let authority = await Task.detached(priority: .utility) {
            store.mintLatestNightCommitAuthority(
                for: initialEvidence.receipt,
                strapIdentifier: strapIdentifier,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            )
        }.value
        let unwrapped = try XCTUnwrap(authority)
        let appended = try await appender.value
        XCTAssertEqual(appended, 600)
        XCTAssertTrue(
            store.consumeLatestNightCommitAuthority(
                unwrapped,
                currentStrapIdentifier: strapIdentifier
            ),
            "append-only rows after the atomic cut must not starve commit"
        )

        let convergedRead = await Task.detached(priority: .utility) {
            store.latestNightMotionRead(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier,
                thermalState: .serious
            )
        }.value
        guard case .qualified(let convergedEvidence) = convergedRead else {
            return XCTFail("expected the trailing prefix to converge")
        }
        XCTAssertEqual(convergedEvidence.receipt.rowCount, 601)
        XCTAssertGreaterThan(
            convergedEvidence.receipt.rowCount,
            initialEvidence.receipt.rowCount
        )
    }

    func testLatestNightPrefixCaptureIsAtomicAcrossTwoShards()
        async throws
    {
        let midnight = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = midnight - 60
        try appendPoint(base: base, second: 30)
        try appendPoint(base: base, second: 90)
        try store.synchronize()
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let firstBucket = Int64(floor(
            TimeInterval(base) / 86_400
        ))
        let firstCaptured = expectation(
            description: "first shard captured under vector lock"
        )
        let releaseCapture = DispatchSemaphore(value: 0)
        store.setLatestNightShardCaptureHookForTesting { bucket in
            if bucket == firstBucket {
                firstCaptured.fulfill()
                releaseCapture.wait()
            }
        }
        defer { store.setLatestNightShardCaptureHookForTesting(nil) }
        let start = Date(timeIntervalSince1970: TimeInterval(base))
        let end = Date(timeIntervalSince1970: TimeInterval(base + 120))
        let readTask = Task.detached(priority: .utility) {
            store.latestNightMotionRead(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier,
                thermalState: .serious
            )
        }
        await fulfillment(of: [firstCaptured], timeout: 1)
        let appendedPoints = [40, 100].map { second in
            AtriaWhoop4MotionTickCompactStore.MigrationPoint(
                timestamp: TimeInterval(base + UInt32(second)),
                flash: UInt32(second + 10),
                tick: second + 10,
                gravityX: 0,
                gravityY: 0,
                gravityZ: 1,
                unknownMotionScalar32: 0.05,
                rawPayload: payloadIdentity(
                    unix: base + UInt32(second),
                    tick: second + 10
                )
            )
        }
        let appendAttempted = expectation(
            description: "append attempted while vector lock is held"
        )
        let appendTask = Task.detached(priority: .utility) {
            appendAttempted.fulfill()
            return try store.appendMigrated(
                appendedPoints,
                strapIdentifier: strapIdentifier
            )
        }
        await fulfillment(of: [appendAttempted], timeout: 1)
        try await Task.sleep(for: .milliseconds(20))
        releaseCapture.signal()
        let read = await readTask.value
        let appended = try await appendTask.value
        XCTAssertEqual(appended, 2)
        guard case .qualified(let evidence) = read else {
            return XCTFail("expected an atomic two-shard prefix")
        }
        XCTAssertEqual(evidence.receipt.shardCount, 2)
        XCTAssertEqual(
            evidence.receipt.rowCount,
            2,
            "the append cannot land between the two captured prefixes"
        )
        store.setLatestNightShardCaptureHookForTesting(nil)
        let nextRead = await Task.detached(priority: .utility) {
            store.latestNightMotionRead(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier,
                thermalState: .serious
            )
        }.value
        guard case .qualified(let nextEvidence) = nextRead else {
            return XCTFail("expected trailing two-shard convergence")
        }
        XCTAssertEqual(nextEvidence.receipt.rowCount, 4)
    }

    func testLatestNightWindowIncludesExactUTCBucketBoundary()
        async throws
    {
        let midnight = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        try appendPoint(base: midnight - 1, second: 0)
        try appendPoint(base: midnight, second: 0)
        try store.synchronize()

        let before = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(midnight - 60)),
            end: Date(timeIntervalSince1970: TimeInterval(midnight)),
            thermalState: .serious
        )
        guard case .qualified(let beforeEvidence) = before else {
            return XCTFail("expected previous UTC shard")
        }
        XCTAssertEqual(beforeEvidence.receipt.shardCount, 2)
        XCTAssertEqual(
            beforeEvidence.receipt.matchedRowCount,
            2,
            "the exact-end row in the next UTC shard is terminal evidence"
        )

        let after = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(midnight)),
            end: Date(timeIntervalSince1970: TimeInterval(midnight + 60)),
            thermalState: .serious
        )
        guard case .qualified(let afterEvidence) = after else {
            return XCTFail("expected next UTC shard")
        }
        XCTAssertEqual(afterEvidence.receipt.shardCount, 1)
        XCTAssertEqual(afterEvidence.receipt.matchedRowCount, 1)
    }

    func testExactUTCBucketEndpointAllowsAbsentNextShard()
        async throws
    {
        let midnight = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        try appendPoint(base: midnight - 1, second: 0)
        try store.synchronize()

        let read = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(midnight - 60)),
            end: Date(timeIntervalSince1970: TimeInterval(midnight)),
            thermalState: .serious
        )
        guard case .qualified(let evidence) = read else {
            return XCTFail(
                "an absent zero-duration endpoint shard must be empty"
            )
        }
        XCTAssertEqual(evidence.receipt.shardCount, 1)
        XCTAssertEqual(evidence.receipt.matchedRowCount, 1)
    }

    func testConcurrentAppendAndSynchronizeKeepsAlignedReadableShard()
        async throws
    {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let points = (0..<600).map { second in
            AtriaWhoop4MotionTickCompactStore.MigrationPoint(
                timestamp: TimeInterval(base + UInt32(second)),
                flash: UInt32(second + 1),
                tick: second,
                gravityX: 0,
                gravityY: 0,
                gravityZ: 1,
                unknownMotionScalar32: 0.05,
                rawPayload: payloadIdentity(
                    unix: base + UInt32(second),
                    tick: second
                )
            )
        }
        async let appendCount = Task.detached(priority: .utility) {
            var count = 0
            for chunkStart in stride(from: 0, to: points.count, by: 25) {
                let chunkEnd = min(points.count, chunkStart + 25)
                count += try store.appendMigrated(
                    Array(points[chunkStart..<chunkEnd]),
                    strapIdentifier: strapIdentifier
                )
            }
            return count
        }.value
        async let synchronizeCount = Task.detached(priority: .utility) {
            for _ in 0..<80 { try store.synchronize() }
            return 80
        }.value
        let (appended, synchronized) = try await (
            appendCount,
            synchronizeCount
        )
        XCTAssertEqual(appended, points.count)
        XCTAssertEqual(synchronized, 80)
        try store.synchronize()
        XCTAssertEqual(try shardSize(onlyShard()) % 52, 0)
        let read = await latestNightRead(
            start: Date(timeIntervalSince1970: TimeInterval(base)),
            end: Date(timeIntervalSince1970: TimeInterval(base + 599)),
            thermalState: .serious
        )
        guard case .qualified(let evidence) = read else {
            return XCTFail("concurrent append/sync must remain readable")
        }
        XCTAssertEqual(evidence.receipt.rowCount, points.count)
    }

    func testLatestNightStrictReadEnforcesCallerDeadline() async throws {
        let now = Date()
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let read = await Task.detached(priority: .utility) {
            store.latestNightMotionRead(
                start: now.addingTimeInterval(-60),
                end: now,
                strapIdentifier: strapIdentifier,
                thermalState: .serious,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds
            )
        }.value
        XCTAssertEqual(read, .incomplete(.deadlineExceeded))
    }

    func testLatestNightReadAndMintBoundContendedLockAcquisition()
        async throws
    {
        let bucketStart = UInt32(
            floor(Date().timeIntervalSince1970 / 86_400) * 86_400
        )
        let base = bucketStart + 3_600
        try appendPoint(base: base, second: 0)
        try store.synchronize()
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let start = Date(timeIntervalSince1970: TimeInterval(base))
        let end = Date(timeIntervalSince1970: TimeInterval(base + 60))
        let initial = await Task.detached(priority: .utility) {
            store.latestNightMotionRead(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier,
                thermalState: .serious
            )
        }.value
        guard case .qualified(let evidence) = initial else {
            return XCTFail("expected initial receipt")
        }

        func holdLock(
            description: String
        ) async -> (Task<Void, Never>, DispatchSemaphore) {
            let held = expectation(description: description)
            let release = DispatchSemaphore(value: 0)
            let holder = Task.detached(priority: .utility) {
                store.withStoreLockHeldForTesting {
                    held.fulfill()
                    release.wait()
                }
            }
            await fulfillment(of: [held], timeout: 1)
            return (holder, release)
        }

        let (readHolder, readRelease) = await holdLock(
            description: "read lock contention"
        )
        let readReleaser = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(150))
            readRelease.signal()
        }
        let contendedRead = await Task.detached(priority: .utility) {
            store.latestNightMotionRead(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier,
                thermalState: .serious,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 50_000_000
            )
        }.value
        XCTAssertEqual(contendedRead, .incomplete(.deadlineExceeded))
        _ = await readReleaser.value
        _ = await readHolder.value

        let (mintHolder, mintRelease) = await holdLock(
            description: "mint lock contention"
        )
        let mintReleaser = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(150))
            mintRelease.signal()
        }
        let contendedAuthority = await Task.detached(priority: .utility) {
            store.mintLatestNightCommitAuthority(
                for: evidence.receipt,
                strapIdentifier: strapIdentifier,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 50_000_000
            )
        }.value
        XCTAssertNil(contendedAuthority)
        _ = await mintReleaser.value
        _ = await mintHolder.value

        store.setMintDidValidateReceiptHookForTesting {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let lateAuthority = await Task.detached(priority: .utility) {
            store.mintLatestNightCommitAuthority(
                for: evidence.receipt,
                strapIdentifier: strapIdentifier,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 50_000_000
            )
        }.value
        store.setMintDidValidateReceiptHookForTesting(nil)
        XCTAssertNil(
            lateAuthority,
            "filesystem validation finishing after the budget must not mint"
        )
    }

    func testLatestNightEpochProjectionAbortsInsideLargeCooperativeSort()
        throws
    {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let sampleCount = 20_000
        let samples = (0..<sampleCount).map { index in
            AtriaRecoveredMotionProjection.Sample(
                timestamp: start.addingTimeInterval(
                    Double(sampleCount - index) * 0.1
                ),
                sequence: index,
                x: 0,
                y: 0,
                z: 1,
                timestampValidated: true,
                gravityValidated: true
            )
        }
        let clock = StepClock()
        let result = store.latestNightEpochFeatures(
            samples: samples,
            start: start,
            end: start.addingTimeInterval(Double(sampleCount) * 0.1 + 1),
            deadlineUptimeNanoseconds: 3,
            monotonicNow: { clock.next() }
        )

        XCTAssertEqual(result, .failure(.deadlineExceeded))
    }

    func testRelaunchTruncatesPartialTailBeforeAppending() async throws {
        let unix = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 10
        try appendPoint(base: unix, second: 0)
        try store.synchronize()
        store = nil

        let shard = try onlyShard()
        let tornTail = try FileHandle(forWritingTo: shard)
        try tornTail.seekToEnd()
        try tornTail.write(contentsOf: Data([0x41, 0x54, 0x4D, 0x31, 0xAA]))
        try tornTail.synchronize()
        try tornTail.close()
        XCTAssertEqual(try shardSize(shard), 52 + 5)

        store = AtriaWhoop4MotionTickCompactStore(directoryURL: directory)
        try appendPoint(base: unix, second: 1)
        try store.synchronize()

        XCTAssertEqual(try shardSize(shard), 52 * 2)
        let repairedCoverage = await coverage(
            start: Date(timeIntervalSince1970: TimeInterval(unix)),
            end: Date(timeIntervalSince1970: TimeInterval(unix + 1)),
            strapIdentifier: strapIdentifier
        )
        XCTAssertEqual(repairedCoverage.observedSeconds, 2)
    }

    func testWriteFailuresRetireExactHandleAndRepairBeforeNextAppend()
        async throws
    {
        let base = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 10
        try appendPoint(base: base, second: 0)
        try store.synchronize()
        let store = try XCTUnwrap(store)
        let strapIdentifier = try XCTUnwrap(strapIdentifier)
        let shard = try onlyShard()
        store.setAppendWriteHookForTesting { handle, data in
            try handle.write(contentsOf: data.prefix(7))
            throw InjectedWriteFailure.partialRecord
        }
        defer { store.setAppendWriteHookForTesting(nil) }

        XCTAssertThrowsError(
            try store.append(
                record: makeRecord(
                    unix: base + 1,
                    flash: 2,
                    tick: 1
                ),
                rawPayload: payloadIdentity(unix: base + 1, tick: 1),
                strapIdentifier: strapIdentifier
            )
        ) { error in
            guard let injected = error as? InjectedWriteFailure,
                  case .partialRecord = injected else {
                return XCTFail("unexpected injected write error: \(error)")
            }
        }
        store.setAppendWriteHookForTesting(nil)
        XCTAssertEqual(try shardSize(shard), 52 + 7)

        try appendPoint(base: base, second: 2)
        try store.synchronize()
        XCTAssertEqual(
            try shardSize(shard),
            52 * 2,
            "normal append must reopen, trim the torn tail, then align"
        )

        let failedMigration = AtriaWhoop4MotionTickCompactStore.MigrationPoint(
            timestamp: TimeInterval(base + 3),
            flash: 4,
            tick: 3,
            gravityX: 0,
            gravityY: 0,
            gravityZ: 1,
            unknownMotionScalar32: 0.05,
            rawPayload: payloadIdentity(unix: base + 3, tick: 3)
        )
        store.setAppendWriteHookForTesting { handle, data in
            try handle.write(contentsOf: data.prefix(7))
            throw InjectedWriteFailure.partialRecord
        }
        do {
            _ = try await Task.detached(priority: .utility) {
                try store.appendMigrated(
                    [failedMigration],
                    strapIdentifier: strapIdentifier
                )
            }.value
            XCTFail("expected migrated partial-write failure")
        } catch InjectedWriteFailure.partialRecord {
            // Expected: the exact migrated shard handle must be retired.
        } catch {
            XCTFail("unexpected migrated write error: \(error)")
        }
        store.setAppendWriteHookForTesting(nil)
        XCTAssertEqual(try shardSize(shard), 52 * 2 + 7)

        let recoveredMigration =
            AtriaWhoop4MotionTickCompactStore.MigrationPoint(
                timestamp: TimeInterval(base + 4),
                flash: 5,
                tick: 4,
                gravityX: 0,
                gravityY: 0,
                gravityZ: 1,
                unknownMotionScalar32: 0.05,
                rawPayload: payloadIdentity(unix: base + 4, tick: 4)
            )
        let appended = try await Task.detached(priority: .utility) {
            try store.appendMigrated(
                [recoveredMigration],
                strapIdentifier: strapIdentifier
            )
        }.value
        XCTAssertEqual(appended, 1)
        try store.synchronize()
        XCTAssertEqual(
            try shardSize(shard),
            52 * 3,
            "migrated append must reopen, trim the torn tail, then align"
        )

        let points = await Task.detached(priority: .utility) {
            store.decodedPointsForTesting(
                start: Date(timeIntervalSince1970: TimeInterval(base)),
                end: Date(timeIntervalSince1970: TimeInterval(base + 5)),
                strapIdentifier: strapIdentifier
            )
        }.value
        XCTAssertEqual(points.map(\.tick), [0, 2, 4])
    }

    func testCorruptRecordIdentityDoesNotBlockCanonicalRepair() async throws {
        let unix = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 10
        let record = makeRecord(unix: unix, flash: 1, tick: 1)
        let payload = payloadIdentity(unix: unix, tick: 1)
        XCTAssertTrue(
            try store.append(
                record: record,
                rawPayload: payload,
                strapIdentifier: strapIdentifier
            )
        )
        try store.synchronize()
        store = nil

        let shard = try onlyShard()
        var bytes = try Data(contentsOf: shard)
        XCTAssertEqual(bytes.count, 52)
        // Keep magic and identity intact while making the timestamp NaN.
        bytes.replaceSubrange(4..<12, with: repeatElement(0xFF, count: 8))
        try bytes.write(to: shard, options: .atomic)

        store = AtriaWhoop4MotionTickCompactStore(directoryURL: directory)
        XCTAssertTrue(
            try store.append(
                record: record,
                rawPayload: payload,
                strapIdentifier: strapIdentifier
            )
        )
        try store.synchronize()

        let repairedCoverage = await coverage(
            start: Date(timeIntervalSince1970: TimeInterval(unix)),
            end: Date(timeIntervalSince1970: TimeInterval(unix + 1)),
            strapIdentifier: strapIdentifier
        )
        XCTAssertEqual(repairedCoverage.observedSeconds, 1)
    }

    func testRelaunchIdentityIndexUsesValidatedFixedRecordDigestScan()
        throws
    {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Atria/AtriaWhoop4MotionTickCompactStore.swift"
            )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(
            of: "private func loadKnownIdentitiesLocked() throws"
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func handleLocked(filename:",
            range: start.upperBound..<source.endIndex
        ))
        let loader = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(loader.contains(
            "Self.decodeKnownIdentities(data, into: &identities)"
        ))
        XCTAssertFalse(
            loader.contains("Self.decode(data)"),
            "first append must not materialize every retained Point"
        )
        XCTAssertFalse(
            loader.contains("identityData(fromHex:"),
            "the binary digest must never take a hex format/parse round trip"
        )

        let scannerStart = try XCTUnwrap(source.range(
            of: "private static func decodeKnownIdentities("
        ))
        let scannerEnd = try XCTUnwrap(source.range(
            of: "private static func isValidRecord(",
            range: scannerStart.upperBound..<source.endIndex
        ))
        let scanner = String(
            source[scannerStart.lowerBound..<scannerEnd.lowerBound]
        )
        XCTAssertTrue(scanner.contains("offset + 36"))
        XCTAssertTrue(scanner.contains("offset + 52"))
        XCTAssertTrue(scanner.contains("isValidRecord("))
    }

    func testLargeRetainedShardFirstAppendRebuildsBinaryIdentityIndex()
        throws
    {
        let unix = UInt32(Date().timeIntervalSince1970.rounded(.down)) - 10
        let record = makeRecord(unix: unix, flash: 1, tick: 1)
        let payload = payloadIdentity(unix: unix, tick: 1)
        XCTAssertTrue(try store.append(
            record: record,
            rawPayload: payload,
            strapIdentifier: strapIdentifier
        ))
        try store.synchronize()
        store = nil

        let shard = try onlyShard()
        let template = try Data(contentsOf: shard)
        XCTAssertEqual(template.count, 52)
        let rowCount = 50_000
        var fixture = Data(capacity: rowCount * 52)
        for rowIndex in 0..<rowCount {
            var row = template
            if rowIndex > 0 {
                var value = UInt64(rowIndex).littleEndian
                withUnsafeBytes(of: &value) { bytes in
                    row.replaceSubrange(36..<44, with: bytes)
                    row.replaceSubrange(44..<52, with: bytes)
                }
            }
            fixture.append(row)
        }
        try fixture.write(to: shard, options: .atomic)

        store = AtriaWhoop4MotionTickCompactStore(directoryURL: directory)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(
            try store.append(
                record: record,
                rawPayload: payload,
                strapIdentifier: strapIdentifier
            ),
            "fresh-store first append must rebuild and honor retained identity"
        )
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - started,
            2,
            "fixed-record indexing must stay bounded on a 50k-row retained shard"
        )
    }

    func testRetentionDropsDeletedShardIdentitiesInSameProcess() throws {
        let now = UInt32(Date().timeIntervalSince1970.rounded(.down))
        let oldUnix = now - UInt32(5 * 86_400)
        let oldRecord = makeRecord(unix: oldUnix, flash: 1, tick: 1)
        let oldPayload = payloadIdentity(unix: oldUnix, tick: 1)
        XCTAssertTrue(
            try store.append(
                record: oldRecord,
                rawPayload: oldPayload,
                strapIdentifier: strapIdentifier
            )
        )

        try appendPoint(base: now, second: 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "bin" }.count,
            1
        )

        // The old shard was deleted, so its digest must no longer remain in
        // the in-memory duplicate index.
        XCTAssertTrue(
            try store.append(
                record: oldRecord,
                rawPayload: oldPayload,
                strapIdentifier: strapIdentifier
            )
        )
    }

    func testConfirmedWorkoutLaunchAndForegroundPathsAreCompactOnly() throws {
        let sourcesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let sessions = try String(
            contentsOf: sourcesURL.appendingPathComponent("Sessions.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(sessions.range(
            of: "private func scheduleConfirmedWorkoutStepEvidencePublication("
        ))
        let end = try XCTUnwrap(sessions.range(
            of: "nonisolated static func workoutStepNegativeAttemptKey(",
            range: start.upperBound..<sessions.endIndex
        ))
        let publication = String(
            sessions[start.lowerBound..<end.lowerBound]
        )

        XCTAssertTrue(publication.contains(
            "AtriaWhoop4MotionTickCompactStore.shared"
        ))
        XCTAssertTrue(publication.contains(
            ".motionTickWindowRead("
        ))
        XCTAssertTrue(publication.contains(
            "Self.workoutStepEvidenceQueue.async"
        ))
        for forbidden in [
            "HistoricalArchive.motionTickWindowRead(",
            "HistoricalArchive.consumerSourceFingerprint()",
            "HistoricalArchive.consumerProjectionQueue",
            "exactRecoveryProjectionOwnsArchivePriority()",
            "UIApplication.shared.applicationState",
        ] {
            XCTAssertFalse(
                publication.contains(forbidden),
                "hot workout-step publication must not contain \(forbidden)"
            )
        }
        XCTAssertTrue(sessions.contains(
            "reason: \"session_store_init_workout_evidence\""
        ))
        XCTAssertTrue(sessions.contains(
            "reason: \"compact_generation_durable\""
        ))
        XCTAssertFalse(sessions.contains(
            "workoutStepEvidenceDeferredUntilForeground"
        ))

        let resumeStart = try XCTUnwrap(sessions.range(
            of: "func resumeDeferredForegroundArchiveWork(reason: String)"
        ))
        let resumeEnd = try XCTUnwrap(sessions.range(
            of: "private func finishConfirmedWorkoutRehydrationCompletions(",
            range: resumeStart.upperBound..<sessions.endIndex
        ))
        let resume = String(
            sessions[resumeStart.lowerBound..<resumeEnd.lowerBound]
        )
        XCTAssertFalse(resume.contains(
            "scheduleConfirmedWorkoutStepEvidencePublication("
        ), "scene-active replay must never re-arm canonical workout motion")

        let app = try String(
            contentsOf: sourcesURL.appendingPathComponent("AtriaApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(app.contains(
            "scheduleBoundedLegacyCurrentCycleStepMigrationIfSafe("
        ), "guarded BGProcessing must retain eventual recent-workout compact migration")

        let productionSources = try FileManager.default.contentsOfDirectory(
            at: sourcesURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.pathExtension == "swift"
                && $0.lastPathComponent != "HistoricalArchive.swift"
        }
        for sourceURL in productionSources {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            XCTAssertFalse(
                source.contains("HistoricalArchive.motionTickWindowRead(")
                    || source.contains("HistoricalArchive.motionTickWindow("),
                "\(sourceURL.lastPathComponent) must not call the legacy workout JSONL reader"
            )
        }
    }

    func testMotionTickDayEvidenceSweepMatchesReferenceAcrossMergedAndGappedIntervals()
        throws
    {
        let base = floor(Date().timeIntervalSince1970 / 86_400) * 86_400
            + 86_350
        var points = (0...180).map { second in
            dayEvidencePoint(
                timestamp: base + Double(second),
                tick: second * 2,
                identity: String(format: "%032x", second + 1)
            )
        }
        // Duplicate timestamps exercise the stable identity ordering retained
        // by the compact reader and by the old filter/sort implementation.
        points.append(dayEvidencePoint(
            timestamp: base + 30,
            tick: 60,
            identity: String(repeating: "f", count: 32)
        ))
        points.append(dayEvidencePoint(
            timestamp: base + 120,
            tick: 240,
            identity: String(repeating: "e", count: 32)
        ))
        points.sort {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            return $0.identity < $1.identity
        }
        let start = Date(timeIntervalSince1970: base)
        let end = start.addingTimeInterval(180)
        let coverage = [
            DateInterval(
                start: start.addingTimeInterval(1.5),
                end: start.addingTimeInterval(30.5)
            ),
            // This overlap must merge with the first interval.
            DateInterval(
                start: start.addingTimeInterval(28),
                end: start.addingTimeInterval(61.5)
            ),
            DateInterval(
                start: start.addingTimeInterval(90.5),
                end: start.addingTimeInterval(120.5)
            ),
            // Crosses the UTC shard boundary at base + 50.
            DateInterval(
                start: start.addingTimeInterval(145.5),
                end: start.addingTimeInterval(178.5)
            ),
        ]

        let swept = AtriaWhoop4MotionTickCompactStore
            .motionTickDayEvidenceReadForTesting(
                sortedPoints: points,
                start: start,
                end: end,
                bankCoverage: coverage
            )
        let reference = referenceMotionTickDayEvidenceRead(
            sortedPoints: points,
            start: start,
            end: end,
            bankCoverage: coverage
        )

        XCTAssertEqual(swept.read, reference)
        XCTAssertLessThanOrEqual(
            swept.inspectedPoints,
            4 * points.count + 4 * coverage.count
        )
    }

    func testMotionTickDayEvidenceSweepPreservesMissingBoundarySemantics() {
        let base = Date().timeIntervalSince1970.rounded(.down) - 600
        let start = Date(timeIntervalSince1970: base)
        let end = start.addingTimeInterval(120)
        let points = [
            dayEvidencePoint(
                timestamp: base + 20,
                tick: 1,
                identity: String(format: "%032x", 1)
            ),
            dayEvidencePoint(
                timestamp: base + 100,
                tick: 2,
                identity: String(format: "%032x", 2)
            ),
        ]
        let coverage = [DateInterval(
            start: start.addingTimeInterval(30),
            end: start.addingTimeInterval(90)
        )]

        let swept = AtriaWhoop4MotionTickCompactStore
            .motionTickDayEvidenceReadForTesting(
                sortedPoints: points,
                start: start,
                end: end,
                bankCoverage: coverage
            )
        XCTAssertEqual(
            swept.read,
            referenceMotionTickDayEvidenceRead(
                sortedPoints: points,
                start: start,
                end: end,
                bankCoverage: coverage
            )
        )
        XCTAssertEqual(swept.read, .completeNoQualifiedEvidence)
    }

    func testMotionTickDayEvidenceSweepHasLinearInspectionBoundAtLargeIntervalCount()
    {
        let base = Date().timeIntervalSince1970.rounded(.down) - 20_000
        let pointCount = 12_000
        let points = (0..<pointCount).map { second in
            dayEvidencePoint(
                timestamp: base + Double(second),
                tick: second % 65_536,
                identity: String(format: "%032x", second + 1)
            )
        }
        let intervalCount = 512
        let coverage = (0..<intervalCount).map { index in
            let offset = Double(index * 16 + 2)
            return DateInterval(
                start: Date(timeIntervalSince1970: base + offset),
                end: Date(timeIntervalSince1970: base + offset + 8)
            )
        }
        let start = Date(timeIntervalSince1970: base)
        let end = Date(timeIntervalSince1970: base + Double(pointCount - 1))

        let result = AtriaWhoop4MotionTickCompactStore
            .motionTickDayEvidenceReadForTesting(
                sortedPoints: points,
                start: start,
                end: end,
                bankCoverage: coverage
            )

        guard case .qualified = result.read else {
            return XCTFail("expected the large deterministic fixture to qualify")
        }
        XCTAssertLessThanOrEqual(
            result.inspectedPoints,
            4 * pointCount + 4 * intervalCount,
            "the selector must remain linear in points plus merged intervals"
        )
    }

    private func appendPoint(base: UInt32, second: Int) throws {
        let unix = base + UInt32(second)
        XCTAssertTrue(
            try store.append(
                record: makeRecord(
                    unix: unix,
                    flash: UInt32(second + 1),
                    tick: second
                ),
                rawPayload: payloadIdentity(unix: unix, tick: second),
                strapIdentifier: strapIdentifier
            )
        )
    }

    private func referenceTransportCoverage(
        points: [AtriaWhoop4MotionTickCompactStore.Point],
        start: Date,
        end: Date
    ) -> HistoricalArchive.MotionBankTransportCoverage {
        let firstBucket = Int(floor(start.timeIntervalSince1970))
        let lastBucket = Int(floor(end.timeIntervalSince1970))
        let expected = max(1, lastBucket - firstBucket + 1)
        let matching = points.compactMap { point -> TimeInterval? in
            let bucket = Int(floor(point.timestamp))
            return (firstBucket...lastBucket).contains(bucket)
                ? point.timestamp
                : nil
        }.sorted()
        let observed = Set(matching.map { Int(floor($0)) })
        var maximumMissingRun = 0
        var currentMissingRun = 0
        for bucket in firstBucket...lastBucket {
            if observed.contains(bucket) {
                currentMissingRun = 0
            } else {
                currentMissingRun += 1
                maximumMissingRun = max(
                    maximumMissingRun,
                    currentMissingRun
                )
            }
        }
        return .init(
            observedSeconds: observed.count,
            expectedSeconds: expected,
            densityPercent: min(
                100,
                Int(
                    (Double(observed.count) / Double(expected) * 100)
                        .rounded()
                )
            ),
            maximumMissingRunSeconds: maximumMissingRun,
            firstCapturedAt: matching.first.map {
                Date(timeIntervalSince1970: $0)
            },
            capturedThrough: matching.last.map {
                Date(timeIntervalSince1970: $0)
            }
        )
    }

    // MARK: - Open-tail relaxation (2026-08-22): current-cycle partial publish

    func testOpenTailPublishesPartialWhenCurrentCycleRowsLagNow() {
        let base = 1_800_000_000.0
        var points: [AtriaWhoop4MotionTickCompactStore.Point] = []
        for i in 0..<20 {
            points.append(dayEvidencePoint(
                timestamp: base + 5 + Double(i) * 10,
                tick: 60 + i * 30,
                identity: String(repeating: "a", count: 32)
            ))
        }
        let start = Date(timeIntervalSince1970: base)
        // Window ends at "now"; the newest decoded row (base+195) lags it ~405s,
        // exactly as the compact store lags the still-open bank interval.
        let now = start.addingTimeInterval(600)
        let coverage = [DateInterval(start: start.addingTimeInterval(5), end: now)]

        // Strict read (the pre-fix behavior): the now-edge veto discards the
        // whole open interval → no qualified evidence → the "--" symptom.
        let strict = AtriaWhoop4MotionTickCompactStore
            .motionTickDayEvidenceReadForTesting(
                sortedPoints: points, start: start, end: now, bankCoverage: coverage)
        XCTAssertEqual(strict.read, .completeNoQualifiedEvidence,
                       "strict read vetoes the open tail — reproduces the '--'")

        // Open-tail relaxation: publish a real partial up to the last decoded
        // row, with the undrained [lastRow, now] tail counted honestly as missing
        // so the day is never marked complete.
        let relaxed = AtriaWhoop4MotionTickCompactStore
            .motionTickDayEvidenceReadForTesting(
                sortedPoints: points, start: start, end: now,
                bankCoverage: coverage, allowOpenTail: true)
        // The relaxation's job is to STOP vetoing the open tail so a read that
        // was `.completeNoQualifiedEvidence` becomes `.qualified` over the actual
        // decoded rows. (Whether those rows resolve to nonzero step-coverage
        // seconds is the separately-tested cadence model's job; synthetic gravity
        // here need not resolve.)
        guard case .qualified(let evidence) = relaxed.read else {
            return XCTFail("open tail should publish (qualified), got \(relaxed.read)")
        }
        XCTAssertGreaterThanOrEqual(evidence.decodedRows, 2,
                                    "the open tail's real decoded rows are processed")
        XCTAssertGreaterThan(evidence.missingCoverageSeconds, 0,
                             "undrained [lastRow, now] tail stays missing; day never marked complete")
        XCTAssertLessThanOrEqual(evidence.capturedThrough, now,
                                 "captured frontier never runs past now")
    }

    func testOpenTailDoesNotRelaxAClosedIntervalShortOfTheWindowEnd() {
        let base = 1_800_000_000.0
        var points: [AtriaWhoop4MotionTickCompactStore.Point] = []
        for i in 0..<20 {
            points.append(dayEvidencePoint(
                timestamp: base + 5 + Double(i) * 10,
                tick: 60 + i * 30,
                identity: String(repeating: "a", count: 32)
            ))
        }
        let start = Date(timeIntervalSince1970: base)
        let now = start.addingTimeInterval(600)
        // A CLOSED interval ending at base+300 (well short of the window end):
        // its end-boundary has no nearby row, and it is NOT the open tail, so it
        // must stay strictly vetoed even with allowOpenTail on.
        let coverage = [DateInterval(start: start.addingTimeInterval(5),
                                     end: start.addingTimeInterval(300))]
        let relaxed = AtriaWhoop4MotionTickCompactStore
            .motionTickDayEvidenceReadForTesting(
                sortedPoints: points, start: start, end: now,
                bankCoverage: coverage, allowOpenTail: true)
        XCTAssertEqual(relaxed.read, .completeNoQualifiedEvidence,
                       "a closed interval short of the window end keeps exact both-boundary integrity")
    }

    private func dayEvidencePoint(
        timestamp: TimeInterval,
        tick: Int,
        identity: String
    ) -> AtriaWhoop4MotionTickCompactStore.Point {
        let phase = timestamp * 0.41
        return .init(
            timestamp: timestamp,
            flash: UInt32(max(0, tick)),
            tick: tick,
            gravityX: 0.08 * sin(phase),
            gravityY: 0.08 * cos(phase),
            gravityZ: 1 + 0.04 * sin(phase * 0.7),
            unknownMotionScalar32: 0.1,
            identity: identity
        )
    }

    /// The pre-optimization implementation, retained only as a parity oracle
    /// for the monotonic production sweep.
    private func referenceMotionTickDayEvidenceRead(
        sortedPoints points: [AtriaWhoop4MotionTickCompactStore.Point],
        start: Date,
        end: Date,
        bankCoverage: [DateInterval],
        tolerance: TimeInterval = 3
    ) -> HistoricalArchive.MotionTickDayEvidenceRead {
        let window = DateInterval(start: start, end: end)
        let ledgerCoverage = mergeReferenceIntervals(bankCoverage.compactMap {
            interval in
            let clippedStart = max(interval.start, window.start)
            let clippedEnd = min(interval.end, window.end)
            return clippedEnd > clippedStart
                ? DateInterval(start: clippedStart, end: clippedEnd)
                : nil
        })
        // Production credits the coverage the stored rows themselves prove,
        // unioned with whatever the bank ledger retained. The reference must
        // model the same union or it stops being a reference.
        let intervals = mergeReferenceIntervals(
            ledgerCoverage
                + AtriaWhoop4MotionTickCompactStore.rowDerivedCoverage(
                    points: points,
                    window: window
                )
        )
        guard !intervals.isEmpty, points.count >= 2 else {
            return .incomplete
        }
        typealias CounterPoint = AtriaWhoop4MotionTickSequenceReducer.Point
        typealias CadencePoint = AtriaWhoop4GravityCadenceStepModel.Point
        var totalTicks = 0
        var totalKnownDuration: TimeInterval = 0
        var totalDecodedRows = 0
        var capturedThrough: Date?
        var cadenceFragments: [[CadencePoint]] = []

        for interval in intervals {
            let nearby = points.filter {
                $0.timestamp >= interval.start.timeIntervalSince1970
                    - tolerance
                    && $0.timestamp <= interval.end.timeIntervalSince1970
                    + tolerance
            }
            guard let first = nearby.min(by: {
                abs($0.timestamp - interval.start.timeIntervalSince1970)
                    < abs($1.timestamp - interval.start.timeIntervalSince1970)
            }),
            let last = nearby.min(by: {
                abs($0.timestamp - interval.end.timeIntervalSince1970)
                    < abs($1.timestamp - interval.end.timeIntervalSince1970)
            }),
            abs(first.timestamp - interval.start.timeIntervalSince1970)
                <= tolerance,
            abs(last.timestamp - interval.end.timeIntervalSince1970)
                <= tolerance,
            last.timestamp > first.timestamp else {
                continue
            }
            let members = nearby.filter {
                $0.timestamp >= first.timestamp
                    && $0.timestamp <= last.timestamp
            }.sorted {
                if $0.timestamp != $1.timestamp {
                    return $0.timestamp < $1.timestamp
                }
                return $0.identity < $1.identity
            }
            let reduced = AtriaWhoop4MotionTickSequenceReducer.reduce(
                points: members.map {
                    CounterPoint(
                        timestamp: $0.timestamp,
                        tick: $0.tick,
                        flash: $0.flash,
                        identity: $0.identity
                    )
                },
                intervals: [DateInterval(
                    start: Date(timeIntervalSince1970: first.timestamp),
                    end: Date(timeIntervalSince1970: last.timestamp)
                )],
                boundaryTolerance: 0.001
            )
            guard let reduced else { continue }
            cadenceFragments.append(members.map {
                CadencePoint(
                    timestamp: $0.timestamp,
                    flash: $0.flash,
                    tick: $0.tick,
                    gravityX: $0.gravityX,
                    gravityY: $0.gravityY,
                    gravityZ: $0.gravityZ,
                    unknownMotionScalar32: $0.unknownMotionScalar32,
                    identity: $0.identity
                )
            })
            totalTicks += reduced.ticks
            totalKnownDuration += reduced.knownDuration
            totalDecodedRows += reduced.admittedRows
            capturedThrough = max(
                capturedThrough ?? reduced.capturedThrough,
                reduced.capturedThrough
            )
        }

        guard totalKnownDuration > 0,
              totalDecodedRows >= 2,
              let capturedThrough else {
            return .completeNoQualifiedEvidence
        }
        let estimate = AtriaWhoop4GravityCadenceStepModel
            .estimateCoveredActivityFragments(cadenceFragments)
        let unresolved = estimate?.unresolvedMotionSeconds
            ?? totalKnownDuration
        let totalSeconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        let knownSeconds = max(0, Int(totalKnownDuration.rounded()))
        let qualifiedSeconds = max(
            0,
            min(totalSeconds, knownSeconds)
                - max(0, Int(unresolved.rounded(.up)))
        )
        return .qualified(.init(
            windowStart: start,
            windowEnd: end,
            motionTicks: totalTicks,
            // Production takes the larger of the cadence estimate and the
            // counter projection, because 1 Hz drained rows make cadence
            // unrecoverable for normal walking. The reference must model the
            // same choice or it stops being a reference.
            steps: max(
                estimate?.steps ?? 0,
                AtriaWhoop4MotionTickStepModel.publishedSteps(
                    motionTicks: totalTicks,
                    validation: AtriaWhoop4MotionTickStepModel
                        .physicallyValidatedWhoop4V24
                ) ?? 0
            ),
            knownCoverageSeconds: qualifiedSeconds,
            missingCoverageSeconds: max(0, totalSeconds - qualifiedSeconds),
            decodedRows: totalDecodedRows,
            capturedThrough: min(capturedThrough, end)
        ))
    }

    private func mergeReferenceIntervals(
        _ intervals: [DateInterval]
    ) -> [DateInterval] {
        let sorted = intervals.filter { $0.end > $0.start }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        var result: [DateInterval] = []
        for interval in sorted {
            guard let last = result.last else {
                result.append(interval)
                continue
            }
            if interval.start <= last.end {
                result[result.count - 1] = .init(
                    start: last.start,
                    end: max(last.end, interval.end)
                )
            } else {
                result.append(interval)
            }
        }
        return result
    }

    private func coverage(
        start: Date,
        end: Date,
        strapIdentifier: String
    ) async -> HistoricalArchive.MotionBankTransportCoverage {
        let store = try! XCTUnwrap(store)
        return await Task.detached(priority: .utility) {
            store.transportCoverage(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier
            )
        }.value
    }

    private func sourceFingerprint(
        start: Date,
        end: Date
    ) async -> String? {
        let store = try! XCTUnwrap(store)
        let strapIdentifier = try! XCTUnwrap(strapIdentifier)
        return await Task.detached(priority: .utility) {
            store.sourceFingerprint(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier
            )
        }.value
    }

    private func latestNightRead(
        start: Date,
        end: Date,
        thermalState: ProcessInfo.ThermalState,
        budget: AtriaWhoop4MotionTickCompactStore.LatestNightReadBudget =
            .production
    ) async -> AtriaWhoop4MotionTickCompactStore.LatestNightMotionRead {
        let store = try! XCTUnwrap(store)
        let strapIdentifier = try! XCTUnwrap(strapIdentifier)
        return await Task.detached(priority: .utility) {
            store.latestNightMotionRead(
                start: start,
                end: end,
                strapIdentifier: strapIdentifier,
                thermalState: thermalState,
                budget: budget
            )
        }.value
    }

    private func onlyShard() throws -> URL {
        let shards = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "bin" }
        return try XCTUnwrap(shards.first)
    }

    private func shardSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return try XCTUnwrap(attributes[.size] as? NSNumber).intValue
    }

    private func makeRecord(
        unix: UInt32,
        flash: UInt32,
        tick: Int
    ) -> HistoricalArchive.Record {
        var record = HistoricalArchive.Record(
            schema: HistoricalArchive.schema,
            capturedAt: Date(timeIntervalSince1970: TimeInterval(unix)),
            source: "0x2f",
            layoutVersion: HistoricalArchive.layoutVersion,
            sequence: Int(AtriaWhoop4HistoricalLayout.v24.rawValue),
            command: 0x2f,
            unix7: unix,
            subsec11: 0,
            flash13: flash,
            payloadLength: 92,
            whoofHR17: 80,
            whoofRRNum18: 0,
            whoofRR19: [],
            kRR64: [],
            gravityX36: 0,
            gravityY40: 0,
            gravityZ44: 1,
            unknownMotionScalar32: 0.05,
            gravityMagnitude: 1,
            gravityValidated: true,
            candidateRR: [],
            rawPayloadHex: "",
            clockDeviceRef: unix,
            clockWallRef: unix,
            clockDriftSeconds: 0,
            clockCorrectedUnix7: unix,
            clockCorrectionStatus: "clock_ref_present",
            currentSessionUsable: true,
            metricUsable: true,
            usabilityReason: "test"
        )
        record.motionTickCounter88 = tick
        return record
    }

    private func payloadIdentity(unix: UInt32, tick: Int) -> [UInt8] {
        withUnsafeBytes(of: unix.littleEndian) { unixBytes in
            withUnsafeBytes(of: UInt16(tick).littleEndian) { tickBytes in
                Array(unixBytes) + Array(tickBytes)
            }
        }
    }

    private func pseudoNoise(_ index: Int, channel: Int) -> Double {
        let raw = sin(
            Double(index + 1)
                * (12.9898 + Double(channel) * 78.233)
        ) * 43_758.5453
        let fraction = raw - floor(raw)
        return fraction * 2 - 1
    }
}
