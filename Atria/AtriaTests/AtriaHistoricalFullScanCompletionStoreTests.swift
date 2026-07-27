import XCTest
@testable import Atria

final class AtriaHistoricalFullScanCompletionStoreTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testPublishesLatestAndPreservesPriorContentAddressedRecord() throws {
        let root = try temporaryRoot()
        let store = AtriaHistoricalFullScanCompletionStore(directoryURL: root)
        let first = try store.recordCompletion(record(generation: 1))
        let second = try store.recordCompletion(record(generation: 2))

        XCTAssertEqual(try store.loadLatest(), record(generation: 2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.recordURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.recordURL.path))
        XCTAssertNotEqual(first.recordURL, second.recordURL)
    }

    func testSameGenerationIsIdempotentButConflictingRecordFails() throws {
        let root = try temporaryRoot()
        let store = AtriaHistoricalFullScanCompletionStore(directoryURL: root)
        _ = try store.recordCompletion(record(generation: 3))
        let retry = try store.recordCompletion(record(generation: 3))
        XCTAssertTrue(retry.reusedExistingGeneration)

        XCTAssertThrowsError(try store.recordCompletion(
            record(generation: 3, transportNonce: "different")
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalFullScanCompletionStore.StoreError,
                           .generationConflict)
        }
    }

    func testOlderGenerationCannotReplaceLatest() throws {
        let root = try temporaryRoot()
        let store = AtriaHistoricalFullScanCompletionStore(directoryURL: root)
        _ = try store.recordCompletion(record(generation: 4))
        XCTAssertThrowsError(try store.recordCompletion(record(generation: 3))) { error in
            XCTAssertEqual(error as? AtriaHistoricalFullScanCompletionStore.StoreError,
                           .staleGeneration)
        }
    }

    func testCrashBeforePointerPublicationLeavesOrphanUntrusted() throws {
        enum Injected: Error { case crash }
        let root = try temporaryRoot()
        let store = AtriaHistoricalFullScanCompletionStore(
            directoryURL: root,
            checkpoint: { if $0 == .recordPublished { throw Injected.crash } }
        )
        XCTAssertThrowsError(try store.recordCompletion(record(generation: 1)))
        XCTAssertThrowsError(try store.loadLatest()) { error in
            XCTAssertEqual(error as? AtriaHistoricalFullScanCompletionStore.StoreError,
                           .missingCompletion)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("historical-full-scan-completion-") }.count, 1)
    }

    func testTamperedLatestRecordFailsClosed() throws {
        let root = try temporaryRoot()
        let store = AtriaHistoricalFullScanCompletionStore(directoryURL: root)
        let published = try store.recordCompletion(record(generation: 1))
        try Data("tampered".utf8).write(to: published.recordURL)
        XCTAssertThrowsError(try store.loadLatest()) { error in
            XCTAssertEqual(error as? AtriaHistoricalFullScanCompletionStore.StoreError,
                           .recordInvalid)
        }
    }

    func testRejectsInvalidTerminalSourceAndSnapshotIdentity() throws {
        let root = try temporaryRoot()
        let store = AtriaHistoricalFullScanCompletionStore(directoryURL: root)
        let valid = record(generation: 1)
        let tooEarly = AtriaHistoricalFullScanCompletionStore.Record(
            version: valid.version,
            generation: valid.generation,
            transportGeneration: valid.transportGeneration,
            transportNonce: valid.transportNonce,
            peripheralIdentifier: valid.peripheralIdentifier,
            strapIdentity: valid.strapIdentity,
            cursorWatermark: valid.cursorWatermark,
            terminalAt: valid.sourceFirstTimestamp.addingTimeInterval(-1),
            sourceChunkID: valid.sourceChunkID,
            sourceRawSHA256: valid.sourceRawSHA256,
            sourceFirstTimestamp: valid.sourceFirstTimestamp,
            sourceLastTimestamp: valid.sourceLastTimestamp,
            observedArchiveFirstTimestamp: valid.observedArchiveFirstTimestamp,
            catalogGeneration: valid.catalogGeneration,
            catalogSnapshotSHA256: valid.catalogSnapshotSHA256,
            aggregateSnapshotSHA256: valid.aggregateSnapshotSHA256
        )
        XCTAssertThrowsError(try store.recordCompletion(tooEarly)) { error in
            XCTAssertEqual(error as? AtriaHistoricalFullScanCompletionStore.StoreError,
                           .invalidRecord)
        }

        let badHash = AtriaHistoricalFullScanCompletionStore.Record(
            version: valid.version,
            generation: valid.generation,
            transportGeneration: valid.transportGeneration,
            transportNonce: valid.transportNonce,
            peripheralIdentifier: valid.peripheralIdentifier,
            strapIdentity: valid.strapIdentity,
            cursorWatermark: valid.cursorWatermark,
            terminalAt: valid.terminalAt,
            sourceChunkID: valid.sourceChunkID,
            sourceRawSHA256: "not-a-hash",
            sourceFirstTimestamp: valid.sourceFirstTimestamp,
            sourceLastTimestamp: valid.sourceLastTimestamp,
            observedArchiveFirstTimestamp: valid.observedArchiveFirstTimestamp,
            catalogGeneration: valid.catalogGeneration,
            catalogSnapshotSHA256: valid.catalogSnapshotSHA256,
            aggregateSnapshotSHA256: valid.aggregateSnapshotSHA256
        )
        XCTAssertThrowsError(try store.recordCompletion(badHash)) { error in
            XCTAssertEqual(error as? AtriaHistoricalFullScanCompletionStore.StoreError,
                           .invalidRecord)
        }
    }

    func testAcceptsClockCorrectedLiveTailBeyondHistoricalCursor() throws {
        let root = try temporaryRoot()
        let store = AtriaHistoricalFullScanCompletionStore(directoryURL: root)
        let sourceFirst = Date(timeIntervalSince1970: 1_785_076_742)
        let cursor = Date(timeIntervalSince1970: 1_785_089_991)
        let terminal = Date(timeIntervalSince1970: 1_785_090_195.064_56)
        let record = AtriaHistoricalFullScanCompletionStore.Record(
            version: 1,
            generation: 1,
            transportGeneration: 1,
            transportNonce: "physical-terminal-attempt",
            peripheralIdentifier: "C125C62E-C432-53E7-BD19-9761251B2C3E",
            strapIdentity: "strap4Class",
            cursorWatermark: cursor,
            terminalAt: terminal,
            sourceChunkID: "faddb341-44bd-4950-b7bb-9c1fe108d042",
            sourceRawSHA256: String(repeating: "a", count: 64),
            sourceFirstTimestamp: sourceFirst,
            // The physical aggregate contained a clock-corrected live tail
            // eleven seconds beyond terminal receipt and 215 seconds beyond
            // the history cursor. Those rows do not widen cursor authority.
            sourceLastTimestamp: Date(timeIntervalSince1970: 1_785_090_206.322),
            observedArchiveFirstTimestamp: sourceFirst,
            catalogGeneration: 249,
            catalogSnapshotSHA256: String(repeating: "b", count: 64),
            aggregateSnapshotSHA256: String(repeating: "c", count: 64)
        )

        let published = try store.recordCompletion(record)

        XCTAssertFalse(published.reusedExistingGeneration)
        XCTAssertEqual(try store.loadLatest(), published.record)
        XCTAssertEqual(published.record.terminalAt.timeIntervalSince1970,
                       1_785_090_195)
        XCTAssertEqual(published.record.sourceLastTimestamp.timeIntervalSince1970,
                       1_785_090_206)
        XCTAssertGreaterThan(record.sourceLastTimestamp, record.cursorWatermark)
        XCTAssertGreaterThan(record.sourceLastTimestamp, record.terminalAt)

        let retry = try store.recordCompletion(record)
        XCTAssertTrue(retry.reusedExistingGeneration)
        XCTAssertEqual(retry.record, published.record)
    }

    func testRejectsSubsecondTerminalBeforeCursorPriorToCanonicalization() throws {
        let root = try temporaryRoot()
        let store = AtriaHistoricalFullScanCompletionStore(directoryURL: root)
        let valid = record(generation: 1)
        let invalid = AtriaHistoricalFullScanCompletionStore.Record(
            version: valid.version,
            generation: valid.generation,
            transportGeneration: valid.transportGeneration,
            transportNonce: valid.transportNonce,
            peripheralIdentifier: valid.peripheralIdentifier,
            strapIdentity: valid.strapIdentity,
            cursorWatermark: Date(timeIntervalSince1970: 2_002_003_000.9),
            terminalAt: Date(timeIntervalSince1970: 2_002_003_000.1),
            sourceChunkID: valid.sourceChunkID,
            sourceRawSHA256: valid.sourceRawSHA256,
            sourceFirstTimestamp: valid.sourceFirstTimestamp,
            sourceLastTimestamp: valid.sourceLastTimestamp,
            observedArchiveFirstTimestamp: valid.observedArchiveFirstTimestamp,
            catalogGeneration: valid.catalogGeneration,
            catalogSnapshotSHA256: valid.catalogSnapshotSHA256,
            aggregateSnapshotSHA256: valid.aggregateSnapshotSHA256
        )

        XCTAssertThrowsError(try store.recordCompletion(invalid)) { error in
            XCTAssertEqual(error as? AtriaHistoricalFullScanCompletionStore.StoreError,
                           .invalidRecord)
        }
    }

    func testRejectsReversedSourceBounds() throws {
        let root = try temporaryRoot()
        let store = AtriaHistoricalFullScanCompletionStore(directoryURL: root)
        let valid = record(generation: 1)
        let invalid = AtriaHistoricalFullScanCompletionStore.Record(
            version: valid.version,
            generation: valid.generation,
            transportGeneration: valid.transportGeneration,
            transportNonce: valid.transportNonce,
            peripheralIdentifier: valid.peripheralIdentifier,
            strapIdentity: valid.strapIdentity,
            cursorWatermark: valid.cursorWatermark,
            terminalAt: valid.terminalAt,
            sourceChunkID: valid.sourceChunkID,
            sourceRawSHA256: valid.sourceRawSHA256,
            sourceFirstTimestamp: valid.sourceLastTimestamp,
            sourceLastTimestamp: valid.sourceFirstTimestamp,
            observedArchiveFirstTimestamp: valid.observedArchiveFirstTimestamp,
            catalogGeneration: valid.catalogGeneration,
            catalogSnapshotSHA256: valid.catalogSnapshotSHA256,
            aggregateSnapshotSHA256: valid.aggregateSnapshotSHA256
        )

        XCTAssertThrowsError(try store.recordCompletion(invalid)) { error in
            XCTAssertEqual(error as? AtriaHistoricalFullScanCompletionStore.StoreError,
                           .invalidRecord)
        }
    }

    private func record(
        generation: UInt64,
        transportNonce: String = "nonce-a"
    ) -> AtriaHistoricalFullScanCompletionStore.Record {
        let first = Date(timeIntervalSince1970: 2_002_000_000)
        return .init(
            version: 1,
            generation: generation,
            transportGeneration: generation + 10,
            transportNonce: transportNonce,
            peripheralIdentifier: "peripheral-a",
            strapIdentity: "whoop-4",
            cursorWatermark: first.addingTimeInterval(3_000),
            terminalAt: first.addingTimeInterval(3_600),
            sourceChunkID: "chunk-a",
            sourceRawSHA256: String(repeating: "a", count: 64),
            sourceFirstTimestamp: first,
            sourceLastTimestamp: first.addingTimeInterval(1_800),
            observedArchiveFirstTimestamp: first.addingTimeInterval(-3_600),
            catalogGeneration: generation,
            catalogSnapshotSHA256: String(repeating: "b", count: 64),
            aggregateSnapshotSHA256: String(repeating: "c", count: 64)
        )
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "atria-full-scan-completion-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }
}
