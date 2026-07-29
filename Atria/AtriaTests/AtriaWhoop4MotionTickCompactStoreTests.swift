import XCTest
@testable import Atria

final class AtriaWhoop4MotionTickCompactStoreTests: XCTestCase {
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
}
