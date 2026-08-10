import XCTest
@testable import Atria

final class AtriaWhoop4HistoricalIngressSpoolTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaIngressSpoolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testRoundTripPreservesFrameMetadataFrameOrderAcrossReopen() throws {
        let url = directory.appendingPathComponent("ingress.bin")
        let first = try AtriaWhoop4HistoricalIngressSpool(url: url, generation: 44)
        try first.append(.frame(payload: [0x2f, 1, 2],
                                clock: .init(device: 10, wall: 17),
                                clockAuthorityEnabled: true))
        try first.append(.metadata(payload: [0x31, 9], phaseGeneration: 44))
        try first.append(.frame(payload: [0x2f, 3],
                                clock: nil,
                                clockAuthorityEnabled: false))
        try first.synchronize()

        let reopened = try AtriaWhoop4HistoricalIngressSpool(url: url, generation: 44)
        XCTAssertEqual(reopened.pendingCount, 3)
        XCTAssertEqual(try reopened.popFirst(), .frame(
            payload: [0x2f, 1, 2], clock: .init(device: 10, wall: 17), clockAuthorityEnabled: true))
        XCTAssertEqual(try reopened.popFirst(), .metadata(payload: [0x31, 9], phaseGeneration: 44))
        XCTAssertEqual(try reopened.popFirst(), .frame(
            payload: [0x2f, 3], clock: nil, clockAuthorityEnabled: false))
        XCTAssertNil(try reopened.popFirst())
    }

    func testMoreThanLegacySyncBatchPreservesExactOrderAfterExplicitWorkerDurability() throws {
        let url = directory.appendingPathComponent("large-ingress.bin")
        let spool = try AtriaWhoop4HistoricalIngressSpool(
            url: url,
            generation: 45
        )
        let events: [AtriaWhoop4HistoricalIngressSpool.Event] =
            (0..<513).map { index in
                if index.isMultiple(of: 2) {
                    return .frame(
                        payload: [0x2f, UInt8(truncatingIfNeeded: index)],
                        clock: .init(
                            device: UInt32(index),
                            wall: UInt32(index + 7)
                        ),
                        clockAuthorityEnabled: true
                    )
                }
                return .metadata(
                    payload: [0x31, UInt8(truncatingIfNeeded: index)],
                    phaseGeneration: 45
                )
            }
        for event in events {
            try spool.append(event)
        }
        // Explicit durability is permitted for an off-main archival boundary;
        // the hot BLE/MainActor append path must not fsync every 256 events.
        try spool.synchronize()

        let reopened = try AtriaWhoop4HistoricalIngressSpool(
            url: url,
            generation: 45
        )
        XCTAssertEqual(reopened.pendingCount, events.count)
        for expected in events {
            XCTAssertEqual(try reopened.popFirst(), expected)
        }
        XCTAssertNil(try reopened.popFirst())
    }

    func testOrphanHeaderGenerationCanBeReadWithoutRemovingJournal() throws {
        let url = directory.appendingPathComponent("orphan.bin")
        let spool = try AtriaWhoop4HistoricalIngressSpool(url: url, generation: 91)
        try spool.append(.frame(payload: [0x2f, 9], clock: nil,
                                clockAuthorityEnabled: false))
        try spool.synchronize()

        XCTAssertEqual(try AtriaWhoop4HistoricalIngressSpool.generation(at: url), 91)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try AtriaWhoop4HistoricalIngressSpool(
            url: url, generation: 91
        ).pendingCount, 1)
    }

    func testReopenDropsOnlyTornFinalRecord() throws {
        let url = directory.appendingPathComponent("torn.bin")
        let spool = try AtriaWhoop4HistoricalIngressSpool(url: url, generation: 6)
        try spool.append(.metadata(payload: [0x31], phaseGeneration: 6))
        try spool.synchronize()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x20, 0, 0]))
        try handle.close()

        let firstReopen = try AtriaWhoop4HistoricalIngressSpool(
            url: url,
            generation: 6
        )
        XCTAssertEqual(firstReopen.pendingCount, 1)
        let secondReopen = try AtriaWhoop4HistoricalIngressSpool(
            url: url,
            generation: 6
        )
        XCTAssertEqual(secondReopen.pendingCount, 1)
        XCTAssertEqual(
            try secondReopen.popFirst(),
            .metadata(payload: [0x31], phaseGeneration: 6)
        )
    }

    func testHardByteCapFailsClosedBeforeAppendingOverflow() throws {
        let url = directory.appendingPathComponent("cap.bin")
        // Header (16) + one clocked 96-byte frame record (124).
        let spool = try AtriaWhoop4HistoricalIngressSpool(url: url, generation: 1, maximumBytes: 140)
        try spool.append(.frame(payload: Array(repeating: 7, count: 96),
                                clock: .init(device: 1, wall: 2),
                                clockAuthorityEnabled: true))
        XCTAssertThrowsError(try spool.append(.metadata(payload: [0x31], phaseGeneration: 1))) { error in
            XCTAssertEqual(error as? AtriaWhoop4HistoricalIngressSpool.SpoolError, .capacityExceeded)
        }
        XCTAssertEqual(spool.pendingCount, 1)
    }

    func testDurableBoundaryRetiresOnlyConsumedPrefixAndReopenSeesUnreadSuffix() throws {
        let url = directory.appendingPathComponent("durable-suffix.bin")
        let spool = try AtriaWhoop4HistoricalIngressSpool(
            url: url,
            generation: 72
        )
        let consumed = (0..<200).map { index in
            AtriaWhoop4HistoricalIngressSpool.Event.frame(
                payload: [0x2f, UInt8(truncatingIfNeeded: index)],
                clock: .init(device: UInt32(index), wall: UInt32(index + 1_000)),
                clockAuthorityEnabled: true
            )
        }
        for event in consumed { try spool.append(event) }
        let unread = AtriaWhoop4HistoricalIngressSpool.Event.metadata(
            payload: [0x31, 0x74, 0x0e],
            phaseGeneration: 72
        )
        try spool.append(unread)
        for expected in consumed {
            XCTAssertEqual(try spool.popFirst(), expected)
        }
        XCTAssertEqual(spool.pendingCount, 1)
        let cleanACKBoundary = spool
            .captureDurablyAcknowledgedPrefixBoundary()
        XCTAssertFalse(cleanACKBoundary.coversEntireJournal)
        let sizeBefore = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.size]
                as? NSNumber
        ).uint64Value

        let retired = try spool.retireConsumedPrefix(
            through: cleanACKBoundary
        )
        let sizeAfter = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.size]
                as? NSNumber
        ).uint64Value

        XCTAssertGreaterThan(retired, 0)
        XCTAssertLessThan(sizeAfter, sizeBefore)
        XCTAssertEqual(spool.pendingCount, 1)
        let reopened = try AtriaWhoop4HistoricalIngressSpool(
            url: url,
            generation: 72
        )
        XCTAssertEqual(reopened.pendingCount, 1)
        XCTAssertEqual(try reopened.popFirst(), unread)
        XCTAssertNil(try reopened.popFirst())
    }

    func testEarlierACKCannotRetireDequeuedRowsFromAnUnacknowledgedLaterPage() throws {
        let url = directory.appendingPathComponent("mid-page-exit.bin")
        let spool = try AtriaWhoop4HistoricalIngressSpool(
            url: url,
            generation: 73
        )
        let acknowledgedPage = (0..<4).map { index in
            AtriaWhoop4HistoricalIngressSpool.Event.frame(
                payload: [0x2f, UInt8(index)],
                clock: nil,
                clockAuthorityEnabled: false
            )
        }
        for event in acknowledgedPage { try spool.append(event) }
        for expected in acknowledgedPage {
            XCTAssertEqual(try spool.popFirst(), expected)
        }
        let pageOneACK = spool.captureDurablyAcknowledgedPrefixBoundary()
        XCTAssertTrue(pageOneACK.coversEntireJournal)

        let unacknowledgedPage = (4..<9).map { index in
            AtriaWhoop4HistoricalIngressSpool.Event.frame(
                payload: [0x2f, UInt8(index)],
                clock: nil,
                clockAuthorityEnabled: false
            )
        }
        for event in unacknowledgedPage { try spool.append(event) }
        XCTAssertEqual(try spool.popFirst(), unacknowledgedPage[0])
        XCTAssertEqual(try spool.popFirst(), unacknowledgedPage[1])

        XCTAssertThrowsError(
            try spool.retireConsumedPrefix(through: pageOneACK)
        ) { error in
            XCTAssertEqual(
                error as? AtriaWhoop4HistoricalIngressSpool.SpoolError,
                .staleDurableBoundary
            )
        }
        try spool.synchronize()

        // A non-ACK thermal/idle/failure exit retains the append-only file.
        // Reopening therefore recovers every later-page row, including the two
        // already dequeued in memory, instead of treating ACK1 as ACK2.
        let reopened = try AtriaWhoop4HistoricalIngressSpool(
            url: url,
            generation: 73
        )
        let expectedReplay = acknowledgedPage + unacknowledgedPage
        XCTAssertEqual(reopened.pendingCount, expectedReplay.count)
        for expected in expectedReplay {
            XCTAssertEqual(try reopened.popFirst(), expected)
        }
        XCTAssertNil(try reopened.popFirst())
    }

    func testOrphanRetentionPreservesFreshJournal() throws {
        let url = directory.appendingPathComponent("fresh.bin")
        _ = try AtriaWhoop4HistoricalIngressSpool(url: url, generation: 3)

        XCTAssertFalse(AtriaWhoop4HistoricalIngressSpool.removeExpiredOrphan(
            at: url,
            now: Date(),
            retention: 60
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testOrphanRetentionRemovesOnlyExpiredRegularJournal() throws {
        let url = directory.appendingPathComponent("expired.bin")
        _ = try AtriaWhoop4HistoricalIngressSpool(url: url, generation: 3)
        let stale = Date(timeIntervalSinceNow: -61)
        try FileManager.default.setAttributes([.modificationDate: stale], ofItemAtPath: url.path)

        XCTAssertTrue(AtriaWhoop4HistoricalIngressSpool.removeExpiredOrphan(
            at: url,
            now: Date(),
            retention: 60
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOrphanRetentionFailsClosedForDirectory() throws {
        let url = directory.appendingPathComponent("not-a-journal", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let stale = Date(timeIntervalSinceNow: -61)
        try FileManager.default.setAttributes([.modificationDate: stale], ofItemAtPath: url.path)

        XCTAssertFalse(AtriaWhoop4HistoricalIngressSpool.removeExpiredOrphan(
            at: url,
            now: Date(),
            retention: 60
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
