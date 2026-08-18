import XCTest
@testable import Atria

final class AtriaHistoricalLiveIdentityLookupTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    /// 2026-08-19 field pull: this database was 840 MB while holding only
    /// 14 days of retained hints. `prune` issued a DELETE and stopped there —
    /// SQLite frees the pages inside the file but never returns them to the
    /// filesystem without a vacuum. Both sibling stores
    /// (`AtriaWhoop4HistoryAdmissionLedger`, `AtriaHistoricalRetiredReplayIndex`)
    /// already handled this; this one did not.
    func testPruneActuallyReturnsBytesToTheFilesystem() throws {
        let databaseURL = try temporaryDatabaseURL()
        let lookup = try AtriaHistoricalLiveIdentityLookup(
            databaseURL: databaseURL,
            unsafeDisableDurabilityForTests: true
        )

        // Enough rows that the free-page fraction after pruning is unambiguous.
        let old: TimeInterval = 1_800_000_000
        let fresh: TimeInterval = 1_800_000_000 + 60 * 86_400
        for index in 0..<4_000 {
            try lookup.upsert(entry(
                stableKey: identity(payload: Data([
                    UInt8(index & 0xff), UInt8((index >> 8) & 0xff), 0x11
                ])).stableKey,
                observedAtUnix: old,
                archivePath: "/archive/raw-20260712-\(index).jsonl",
                lineOffset: UInt64(index) * 512,
                lineLength: 700,
                lineCRC32: 0x1234abcd
            ))
        }
        try lookup.upsert(entry(
            stableKey: identity(payload: Data([0xff, 0xfe, 0xfd])).stableKey,
            observedAtUnix: fresh,
            archivePath: "/archive/raw-20260819.jsonl",
            lineOffset: 0,
            lineLength: 700,
            lineCRC32: 0x1234abcd
        ))
        try lookup.compact()
        let bytesBefore = try databaseBytes(at: databaseURL)
        XCTAssertGreaterThan(bytesBefore, 0)

        let removed = try lookup.prune(
            observedBefore: Date(timeIntervalSince1970: old + 86_400)
        )
        XCTAssertEqual(removed, 4_000)
        XCTAssertEqual(try lookup.count(), 1, "the fresh hint must survive")

        let bytesAfter = try databaseBytes(at: databaseURL)
        XCTAssertLessThan(bytesAfter, bytesBefore,
                          "pruning 4,000 of 4,001 rows must shrink the file on disk")
    }

    private func databaseBytes(at url: URL) throws -> UInt64 {
        var total: UInt64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let candidate = URL(fileURLWithPath: url.path + suffix)
            guard let size = (try? FileManager.default.attributesOfItem(
                atPath: candidate.path
            )[.size]) as? NSNumber else { continue }
            total += size.uint64Value
        }
        return total
    }

    func testExactEntryPersistsAcrossRestartInWALMode() throws {
        let databaseURL = try temporaryDatabaseURL()
        let stableKey = identity(payload: Data([0x2f, 0x18, 0xaa])).stableKey
        let expected = entry(
            stableKey: stableKey,
            observedAtUnix: 1_800_000_000,
            archivePath: "/archive/raw-20260726.jsonl",
            lineOffset: 8_192,
            lineLength: 713,
            lineCRC32: 0xaabbccdd
        )

        var lookup: AtriaHistoricalLiveIdentityLookup? =
            try AtriaHistoricalLiveIdentityLookup(
                databaseURL: databaseURL,
                unsafeDisableDurabilityForTests: true
            )
        XCTAssertEqual(try lookup?.journalMode(), "wal")
        try lookup?.upsert(expected)
        XCTAssertEqual(try lookup?.lookup(stableKey: stableKey), expected)
        lookup = nil

        lookup = try AtriaHistoricalLiveIdentityLookup(
            databaseURL: databaseURL,
            unsafeDisableDurabilityForTests: true
        )
        XCTAssertEqual(try lookup?.lookup(stableKey: stableKey), expected)
        XCTAssertEqual(try lookup?.count(), 1)
    }

    func testFullStableIdentityKeepsKnownCRC32CollisionPayloadsDistinct() throws {
        let databaseURL = try temporaryDatabaseURL()
        let lookup = try AtriaHistoricalLiveIdentityLookup(
            databaseURL: databaseURL,
            unsafeDisableDurabilityForTests: true
        )
        let firstKey = identity(payload: Data("plumless".utf8)).stableKey
        let secondKey = identity(payload: Data("buckeroo".utf8)).stableKey
        XCTAssertNotEqual(firstKey, secondKey)

        let first = entry(
            stableKey: firstKey,
            observedAtUnix: 100,
            archivePath: "/archive/first.jsonl",
            lineOffset: 10,
            lineLength: 20,
            lineCRC32: 0x4ddb0c25
        )
        let second = entry(
            stableKey: secondKey,
            observedAtUnix: 101,
            archivePath: "/archive/second.jsonl",
            lineOffset: 30,
            lineLength: 40,
            lineCRC32: 0x4ddb0c25
        )
        try lookup.upsert([first, second])

        XCTAssertEqual(try lookup.lookup(stableKey: firstKey), first)
        XCTAssertEqual(try lookup.lookup(stableKey: secondKey), second)
        XCTAssertEqual(try lookup.count(), 2)
    }

    func testBatchCapacityAndValidationFailBeforeAnyPartialWrite() throws {
        let databaseURL = try temporaryDatabaseURL()
        let lookup = try AtriaHistoricalLiveIdentityLookup(
            databaseURL: databaseURL,
            maximumBatchEntries: 2,
            unsafeDisableDurabilityForTests: true
        )
        let entries = (1...3).map { value in
            entry(
                stableKey: identity(
                    counter: UInt32(value),
                    payload: Data([UInt8(value)])
                ).stableKey,
                observedAtUnix: TimeInterval(value),
                archivePath: "/archive/\(value).jsonl",
                lineOffset: UInt64(value),
                lineLength: value,
                lineCRC32: UInt32(value)
            )
        }

        XCTAssertThrowsError(try lookup.upsert(entries)) {
            XCTAssertEqual(
                $0 as? AtriaHistoricalLiveIdentityLookup.LookupError,
                .batchCapacityExceeded(maximum: 2)
            )
        }
        XCTAssertEqual(try lookup.count(), 0)

        var invalid = entries[1]
        invalid = entry(
            stableKey: invalid.stableKey,
            observedAtUnix: .nan,
            archivePath: invalid.archivePath,
            lineOffset: invalid.lineOffset,
            lineLength: invalid.lineLength,
            lineCRC32: invalid.lineCRC32
        )
        XCTAssertThrowsError(try lookup.upsert([entries[0], invalid])) {
            XCTAssertEqual(
                $0 as? AtriaHistoricalLiveIdentityLookup.LookupError,
                .invalidEntry
            )
        }
        XCTAssertEqual(try lookup.count(), 0)
    }

    func testUpsertKeepsNewestObservationAndRawLocation() throws {
        let databaseURL = try temporaryDatabaseURL()
        let lookup = try AtriaHistoricalLiveIdentityLookup(
            databaseURL: databaseURL,
            unsafeDisableDurabilityForTests: true
        )
        let stableKey = identity(payload: Data([0x44])).stableKey
        let newest = entry(
            stableKey: stableKey,
            observedAtUnix: 300,
            archivePath: "/archive/new.jsonl",
            lineOffset: 300,
            lineLength: 30,
            lineCRC32: 30
        )
        let older = entry(
            stableKey: stableKey,
            observedAtUnix: 200,
            archivePath: "/archive/old.jsonl",
            lineOffset: 200,
            lineLength: 20,
            lineCRC32: 20
        )
        try lookup.upsert(newest)
        try lookup.upsert(older)
        XCTAssertEqual(try lookup.lookup(stableKey: stableKey), newest)

        let replacement = entry(
            stableKey: stableKey,
            observedAtUnix: 400,
            archivePath: "/archive/replacement.jsonl",
            lineOffset: 400,
            lineLength: 40,
            lineCRC32: 40
        )
        try lookup.upsert(replacement)
        XCTAssertEqual(try lookup.lookup(stableKey: stableKey), replacement)
        XCTAssertEqual(try lookup.count(), 1)
    }

    func testDeleteAndPruneTouchOnlyLookupRows() throws {
        let databaseURL = try temporaryDatabaseURL()
        let lookup = try AtriaHistoricalLiveIdentityLookup(
            databaseURL: databaseURL,
            unsafeDisableDurabilityForTests: true
        )
        let old = entry(
            stableKey: identity(counter: 1, payload: Data([1])).stableKey,
            observedAtUnix: 99,
            archivePath: "/archive/old.jsonl",
            lineOffset: 1,
            lineLength: 1,
            lineCRC32: 1
        )
        let boundary = entry(
            stableKey: identity(counter: 2, payload: Data([2])).stableKey,
            observedAtUnix: 100,
            archivePath: "/archive/boundary.jsonl",
            lineOffset: 2,
            lineLength: 2,
            lineCRC32: 2
        )
        let current = entry(
            stableKey: identity(counter: 3, payload: Data([3])).stableKey,
            observedAtUnix: 101,
            archivePath: "/archive/current.jsonl",
            lineOffset: 3,
            lineLength: 3,
            lineCRC32: 3
        )
        try lookup.upsert([old, boundary, current])

        XCTAssertEqual(
            try lookup.prune(
                observedBefore: Date(timeIntervalSince1970: 100)
            ),
            1
        )
        XCTAssertNil(try lookup.lookup(stableKey: old.stableKey))
        XCTAssertEqual(try lookup.lookup(stableKey: boundary.stableKey), boundary)
        XCTAssertTrue(try lookup.delete(stableKey: current.stableKey))
        XCTAssertFalse(try lookup.delete(stableKey: current.stableKey))
        XCTAssertEqual(try lookup.count(), 1)
    }

    func testMalformedStableIdentityIsRejectedWithoutWriting() throws {
        let databaseURL = try temporaryDatabaseURL()
        let lookup = try AtriaHistoricalLiveIdentityLookup(
            databaseURL: databaseURL,
            unsafeDisableDurabilityForTests: true
        )
        let malformed = entry(
            stableKey: "02ff",
            observedAtUnix: 100,
            archivePath: "/archive/raw.jsonl",
            lineOffset: 0,
            lineLength: 1,
            lineCRC32: 1
        )

        XCTAssertThrowsError(try lookup.upsert(malformed)) {
            XCTAssertEqual(
                $0 as? AtriaHistoricalLiveIdentityLookup.LookupError,
                .invalidIdentity
            )
        }
        XCTAssertThrowsError(try lookup.lookup(stableKey: "not-hex")) {
            XCTAssertEqual(
                $0 as? AtriaHistoricalLiveIdentityLookup.LookupError,
                .invalidIdentity
            )
        }
        XCTAssertEqual(try lookup.count(), 0)
    }

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AtriaHistoricalLiveIdentityLookupTests",
                isDirectory: true
            )
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("live-identity.sqlite")
    }

    private func identity(
        counter: UInt32 = 99,
        payload: Data
    ) -> AtriaHistoricalArchiveDurableStore.FrameIdentity {
        AtriaHistoricalArchiveDurableStore.FrameIdentity(
            strapIdentifier: "whoop-strap-4-test",
            protocolVersion: 24,
            counter: counter,
            unixSeconds: 1_752_000_000,
            subsecond: 512,
            payload: payload
        )
    }

    private func entry(
        stableKey: String,
        observedAtUnix: TimeInterval,
        archivePath: String,
        lineOffset: UInt64,
        lineLength: Int,
        lineCRC32: UInt32
    ) -> AtriaHistoricalLiveIdentityLookup.Entry {
        .init(
            stableKey: stableKey,
            observedAtUnix: observedAtUnix,
            archivePath: archivePath,
            lineOffset: lineOffset,
            lineLength: lineLength,
            lineCRC32: lineCRC32
        )
    }
}
