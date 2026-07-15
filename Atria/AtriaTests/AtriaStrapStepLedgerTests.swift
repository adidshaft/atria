import XCTest
@testable import Atria

final class AtriaStrapStepLedgerTests: XCTestCase {
    private var directory: URL!
    private var target: URL!
    private let now = Date(timeIntervalSinceReferenceDate: 810_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-step-ledger-\(UUID().uuidString)", isDirectory: true)
        target = directory.appendingPathComponent("ledger.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCheckpointIsAtomicMonotonicAndIdempotent() throws {
        let segment = UUID()
        let first = try AtriaStrapStepLedger.checkpoint(
            segmentID: segment,
            segmentStartedAt: now.addingTimeInterval(-60),
            segmentSteps: 100,
            segmentRawSteps: 90,
            deviceTimestamp: 5_000,
            state: "r10_live_preliminary",
            now: now,
            at: target
        )
        let repeated = try AtriaStrapStepLedger.checkpoint(
            segmentID: segment,
            segmentStartedAt: now.addingTimeInterval(-60),
            segmentSteps: 100,
            segmentRawSteps: 90,
            deviceTimestamp: 5_000,
            state: "r10_live_preliminary",
            now: now.addingTimeInterval(1),
            at: target
        )
        XCTAssertEqual(first.cumulativeSteps, 100)
        XCTAssertEqual(repeated.cumulativeSteps, 100)
        XCTAssertEqual(AtriaStrapStepLedger.load(now: now.addingTimeInterval(1), from: target), repeated)
        XCTAssertFalse((try Data(contentsOf: target)).isEmpty)
    }

    func testDelayedOlderWriteCannotRegressCountOrWatermark() throws {
        let segment = UUID()
        _ = try checkpoint(segment: segment, steps: 111, raw: 100, timestamp: 5_010)
        XCTAssertThrowsError(try checkpoint(segment: segment,
                                            steps: 100,
                                            raw: 90,
                                            timestamp: 5_000)) {
            XCTAssertEqual($0 as? AtriaStrapStepLedger.SaveError, .regressedCount)
        }
        XCTAssertEqual(AtriaStrapStepLedger.load(now: now, from: target)?.segmentRawSteps, 100)
        XCTAssertEqual(AtriaStrapStepLedger.load(now: now, from: target)?.deviceTimestamp, 5_010)
    }

    func testCountAdvanceRequiresForwardReplayWatermarkAndWrapIsAccepted() throws {
        let segment = UUID()
        _ = try checkpoint(segment: segment,
                           steps: 111,
                           raw: 100,
                           timestamp: UInt32.max - 1)
        let wrapped = try checkpoint(segment: segment, steps: 122, raw: 110, timestamp: 1)
        XCTAssertEqual(wrapped.deviceTimestamp, 1)
        XCTAssertThrowsError(try checkpoint(segment: segment,
                                            steps: 133,
                                            raw: 120,
                                            timestamp: UInt32.max - 2)) {
            XCTAssertEqual($0 as? AtriaStrapStepLedger.SaveError, .staleWatermark)
        }
        XCTAssertThrowsError(try checkpoint(segment: segment,
                                            steps: 133,
                                            raw: 120,
                                            timestamp: 1)) {
            XCTAssertEqual($0 as? AtriaStrapStepLedger.SaveError, .staleWatermark)
        }
    }

    func testRotationPreservesCumulativeTotalAndStartsZeroSegment() throws {
        let first = UUID()
        let second = UUID()
        _ = try checkpoint(segment: first, steps: 111, raw: 100, timestamp: 5_000)
        let rotated = try AtriaStrapStepLedger.rotate(
            from: first,
            finalizedSteps: 111,
            finalizedRawSteps: 100,
            deviceTimestamp: 5_000,
            to: second,
            nextSegmentStartedAt: now.addingTimeInterval(5),
            now: now.addingTimeInterval(5),
            at: target
        )
        XCTAssertEqual(rotated.segmentID, second)
        XCTAssertEqual(rotated.segmentSteps, 0)
        XCTAssertEqual(rotated.segmentRawSteps, 0)
        XCTAssertEqual(rotated.cumulativeSteps, 111)
        XCTAssertEqual(rotated.cumulativeRawSteps, 100)

        let advanced = try AtriaStrapStepLedger.checkpoint(
            segmentID: second,
            segmentStartedAt: now.addingTimeInterval(5),
            segmentSteps: 11,
            segmentRawSteps: 10,
            deviceTimestamp: 5_001,
            state: "r10_live_preliminary",
            now: now.addingTimeInterval(10),
            at: target
        )
        XCTAssertEqual(advanced.cumulativeSteps, 122)
        XCTAssertEqual(advanced.cumulativeRawSteps, 110)
    }

    func testUnhandedBoundaryResegmentsPrefixAndFutureCheckpointAdvances() throws {
        let first = UUID()
        let second = UUID()
        _ = try checkpoint(segment: first, steps: 111, raw: 100, timestamp: 5_000)
        let carried = try AtriaStrapStepLedger.resegmentPreservingUnhandedPrefix(
            from: first,
            observedSteps: 122,
            observedRawSteps: 110,
            deviceTimestamp: 5_001,
            to: second,
            carriedSteps: 122,
            carriedRawSteps: 110,
            nextSegmentStartedAt: now.addingTimeInterval(5),
            now: now.addingTimeInterval(5),
            at: target
        )
        XCTAssertEqual(carried.segmentID, second)
        XCTAssertEqual(carried.segmentRawSteps, 110)
        XCTAssertEqual(carried.cumulativeSteps, 122)

        let advanced = try AtriaStrapStepLedger.checkpoint(
            segmentID: second,
            segmentStartedAt: now.addingTimeInterval(5),
            segmentSteps: 133,
            segmentRawSteps: 120,
            deviceTimestamp: 5_002,
            state: "r10_live_preliminary",
            now: now.addingTimeInterval(10),
            at: target
        )
        XCTAssertEqual(advanced.cumulativeSteps, 133)
        XCTAssertEqual(advanced.cumulativeRawSteps, 120)
    }

    func testCorruptImplausibleAndStaleFilesFailClosed() throws {
        try Data("not-json".utf8).write(to: target)
        XCTAssertNil(AtriaStrapStepLedger.load(now: now, from: target))

        let malformed = AtriaStrapStepLedger.Record(
            schema: AtriaStrapStepLedger.schema,
            segmentID: UUID(),
            segmentStartedAt: now.addingTimeInterval(-10),
            updatedAt: now,
            segmentSteps: AtriaStrapStepLedger.maximumCount + 1,
            segmentRawSteps: 1,
            cumulativeSteps: AtriaStrapStepLedger.maximumCount + 1,
            cumulativeRawSteps: 1,
            deviceTimestamp: 5_000,
            state: nil
        )
        try JSONEncoder().encode(malformed).write(to: target, options: .atomic)
        XCTAssertNil(AtriaStrapStepLedger.load(now: now, from: target))

        try FileManager.default.removeItem(at: target)
        let segment = UUID()
        _ = try checkpoint(segment: segment, steps: 111, raw: 100, timestamp: 5_000)
        XCTAssertNil(AtriaStrapStepLedger.load(
            now: now.addingTimeInterval(AtriaStrapStepLedger.maximumRestoreAge + 1),
            from: target
        ))
        let resumed = try XCTUnwrap(AtriaStrapStepLedger.loadForRestore(
            now: now.addingTimeInterval(AtriaStrapStepLedger.maximumRestoreAge + 1),
            from: target
        ))
        XCTAssertEqual(resumed.segmentSteps, 111)
        XCTAssertEqual(resumed.segmentRawSteps, 100)
        XCTAssertNil(resumed.deviceTimestamp,
                     "an expired strap clock must not reject a genuine later clock reset")
    }

    func testConcurrentOutOfOrderWritersLeaveNewestCheckpoint() throws {
        let segment = UUID()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "atria-step-ledger-test", attributes: .concurrent)
        for value in 1...20 {
            group.enter()
            queue.async {
                defer { group.leave() }
                _ = try? AtriaStrapStepLedger.checkpoint(
                    segmentID: segment,
                    segmentStartedAt: self.now.addingTimeInterval(-60),
                    segmentSteps: value * 11,
                    segmentRawSteps: value * 10,
                    deviceTimestamp: UInt32(5_000 + value),
                    state: "r10_live_preliminary",
                    now: self.now.addingTimeInterval(Double(value)),
                    at: self.target
                )
            }
        }
        group.wait()
        let loaded = try XCTUnwrap(AtriaStrapStepLedger.load(now: now.addingTimeInterval(20), from: target))
        XCTAssertEqual(loaded.segmentRawSteps, 200)
        XCTAssertEqual(loaded.segmentSteps, 220)
        XCTAssertEqual(loaded.deviceTimestamp, 5_020)
    }

    func testRawOnlyAdvanceIsUnsavedAndCheckpointCadenceIsBounded() {
        XCTAssertTrue(AtriaBLEManager.strapStepLedgerHasUnsavedRawSteps(
            currentRawSteps: 101,
            persistedRawSteps: 100
        ), "raw detector progress must persist even if scaled rounding is unchanged")
        XCTAssertFalse(AtriaBLEManager.strapStepLedgerHasUnsavedRawSteps(
            currentRawSteps: 100,
            persistedRawSteps: 100
        ))
        XCTAssertEqual(AtriaBLEManager.strapStepLedgerCheckpointDelay(
            lastSavedAt: nil,
            now: now,
            minimumInterval: 15
        ), 15, accuracy: 0.001)
        XCTAssertEqual(AtriaBLEManager.strapStepLedgerCheckpointDelay(
            lastSavedAt: now.addingTimeInterval(-5),
            now: now,
            minimumInterval: 15
        ), 10, accuracy: 0.001)
    }

    func testLifecycleFlushForcesIndependentLedgerCheckpoint() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func flushLifecycleRealtimeState"))
        let end = try XCTUnwrap(source.range(of: "private func finishWhenActiveJournalFlushSettles",
                                             range: start.upperBound..<source.endIndex))
        let implementation = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(implementation.contains(
            "persistStrapStepLedgerIfNeeded(reason: reason, force: true)"
        ))
    }

    private func checkpoint(segment: UUID,
                            steps: Int,
                            raw: Int,
                            timestamp: UInt32) throws -> AtriaStrapStepLedger.Record {
        try AtriaStrapStepLedger.checkpoint(
            segmentID: segment,
            segmentStartedAt: now.addingTimeInterval(-60),
            segmentSteps: steps,
            segmentRawSteps: raw,
            deviceTimestamp: timestamp,
            state: "r10_live_preliminary",
            now: now,
            at: target
        )
    }
}
