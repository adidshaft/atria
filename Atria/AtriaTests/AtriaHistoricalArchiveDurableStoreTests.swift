import XCTest
@testable import Atria

final class AtriaHistoricalArchiveDurableStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    func testDerivedSnapshotRefreshStaysOffPerPageACKHotPath() {
        XCTAssertFalse(
            AtriaHistoricalArchiveDurableStore.shouldRefreshDerivedSnapshot(
                durableSequence: 1,
                interval: 512
            )
        )
        XCTAssertFalse(
            AtriaHistoricalArchiveDurableStore.shouldRefreshDerivedSnapshot(
                durableSequence: 511,
                interval: 512
            )
        )
        XCTAssertTrue(
            AtriaHistoricalArchiveDurableStore.shouldRefreshDerivedSnapshot(
                durableSequence: 512,
                interval: 512
            )
        )
        XCTAssertFalse(
            AtriaHistoricalArchiveDurableStore.shouldRefreshDerivedSnapshot(
                durableSequence: 512,
                interval: 0
            )
        )
    }

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
    }

    func testDuplicateReplayIsRejectedInProcessAndAfterRestart() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        let identity = frameIdentity(payload: Data([0x18, 0xaa, 0xbb]))

        var store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                           existingArchiveURLs: [archive])
        let firstBatch = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: identity,
                                        encodedJSONObject: record(sequence: 41),
                                        to: archive,
                                        batch: firstBatch), .inserted)
        let firstFlush = try store.flush(firstBatch)
        XCTAssertEqual(Set(firstFlush.synchronizedFiles), Set([archive, index]))

        let replayBatch = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: identity,
                                        encodedJSONObject: record(sequence: 41),
                                        to: archive,
                                        batch: replayBatch), .duplicate(durable: true))
        XCTAssertTrue(try store.flush(replayBatch).synchronizedFiles.isEmpty)
        XCTAssertEqual(try lineCount(at: archive), 1)

        store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                        existingArchiveURLs: [archive])
        let restartBatch = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: identity,
                                        encodedJSONObject: record(sequence: 41),
                                        to: archive,
                                        batch: restartBatch), .duplicate(durable: false))
        XCTAssertEqual(Set(try store.flush(restartBatch).synchronizedFiles), Set([archive, index]))
        let postRestartDurableReplay = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: identity,
                                        encodedJSONObject: record(sequence: 41),
                                        to: archive,
                                        batch: postRestartDurableReplay), .duplicate(durable: true))
        XCTAssertEqual(try lineCount(at: archive), 1)
    }

    func testInterruptedAdmissionReconciliationReceiptsAllExistingIdentitiesWithoutDuplicates() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        let first = frameIdentity(payload: Data([0x2f, 0x01]))
        let second = frameIdentity(payload: Data([0x2f, 0x02]))
        let store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                           existingArchiveURLs: [archive])
        let original = store.beginDrainBatch()
        _ = try store.append(identity: first,
                             encodedJSONObject: record(sequence: 1),
                             to: archive,
                             batch: original)
        _ = try store.append(identity: second,
                             encodedJSONObject: record(sequence: 2),
                             to: archive,
                             batch: original)
        _ = try store.flush(original)

        let reconciliation = store.beginDrainBatch()
        try store.includeExisting(first, in: reconciliation)
        try store.includeExisting(second, in: reconciliation)
        let receipt = try store.flush(reconciliation)

        XCTAssertEqual(receipt.raw.observedIdentityCount, 2)
        XCTAssertEqual(receipt.identity.observedIdentityCount, 2)
        XCTAssertEqual(receipt.raw.recordCount, 0)
        XCTAssertEqual(receipt.raw.batchKeysSHA256,
                       receipt.identity.batchKeysSHA256)
        XCTAssertEqual(try lineCount(at: archive), 2)

        let missing = frameIdentity(payload: Data([0x2f, 0xff]))
        XCTAssertThrowsError(try store.includeExisting(missing,
                                                       in: store.beginDrainBatch())) {
            XCTAssertEqual($0 as? AtriaHistoricalArchiveDurableStore.StoreError,
                           .missingExistingIdentity)
        }
    }

    func testRestartRebuildsDeletedIndexFromArchiveBeforeRejectingReplay() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        let identity = frameIdentity(payload: Data([1, 2, 3, 4]))

        var store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                           existingArchiveURLs: [archive])
        let batch = store.beginDrainBatch()
        _ = try store.append(identity: identity,
                             encodedJSONObject: record(sequence: 7),
                             to: archive,
                             batch: batch)
        _ = try store.flush(batch)
        try FileManager.default.removeItem(at: index)

        store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                        existingArchiveURLs: [archive])
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.path))
        XCTAssertGreaterThan(try Data(contentsOf: index).count, 0)
        let replay = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: identity,
                                        encodedJSONObject: record(sequence: 7),
                                        to: archive,
                                        batch: replay), .duplicate(durable: false))
        XCTAssertEqual(Set(try store.flush(replay).synchronizedFiles), Set([archive, index]))
        XCTAssertEqual(try lineCount(at: archive), 1)
    }

    func testTornArchiveTailIsDiscardedAndLastCompleteRecordSurvives() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        let retained = frameIdentity(payload: Data([0x10, 0x11]))

        var store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                           existingArchiveURLs: [archive])
        let first = store.beginDrainBatch()
        _ = try store.append(identity: retained,
                             encodedJSONObject: record(sequence: 1),
                             to: archive,
                             batch: first)
        _ = try store.flush(first)

        let handle = try FileHandle(forWritingTo: archive)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"sequence\":2,\"rawPayloadHex\":\"dead".utf8))
        try handle.close()
        let tornSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber
        ).uint64Value

        store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                        existingArchiveURLs: [archive])
        let repairedSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber
        ).uint64Value
        XCTAssertLessThan(repairedSize, tornSize)
        XCTAssertEqual(try lineCount(at: archive), 1)

        let replay = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: retained,
                                        encodedJSONObject: record(sequence: 1),
                                        to: archive,
                                        batch: replay), .duplicate(durable: false))
        XCTAssertEqual(Set(try store.flush(replay).synchronizedFiles), Set([archive, index]))
    }

    func testSnapshotMismatchFallsBackToRawArchiveBeforeRejectingReplay() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        let identity = frameIdentity(payload: Data([0x41, 0x42, 0x43]))

        var store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                           existingArchiveURLs: [archive])
        let first = store.beginDrainBatch()
        _ = try store.append(identity: identity,
                             encodedJSONObject: record(sequence: 11),
                             to: archive,
                             batch: first)
        _ = try store.flush(first)
        let snapshot = directory.appendingPathComponent("historical.index.snapshot.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))

        // This changes the registered raw archive after the snapshot.  A stale
        // index must never be trusted merely because it still decodes; launch
        // scans the authoritative JSONL and still rejects the known replay.
        let handle = try FileHandle(forWritingTo: archive)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"legacy\":true}\n".utf8))
        try handle.close()

        store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                        existingArchiveURLs: [archive])
        let replay = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: identity,
                                        encodedJSONObject: record(sequence: 11),
                                        to: archive,
                                        batch: replay), .duplicate(durable: false))
        XCTAssertEqual(try lineCount(at: archive), 2)
    }

    func testAppendOnlyGrowthReusesSnapshotPrefixWithoutStartupRawRebuild() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        let firstIdentity = frameIdentity(counter: 11, payload: Data([0x41, 0x42]))
        let secondIdentity = frameIdentity(counter: 12, payload: Data([0x43, 0x44]))

        var store = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [archive]
        )
        let first = store.beginDrainBatch()
        _ = try store.append(
            identity: firstIdentity,
            encodedJSONObject: record(sequence: 11),
            to: archive,
            batch: first
        )
        _ = try store.flush(first)

        // The first restart establishes a snapshot over the now-existing raw
        // file. A later page grows both raw and index beyond that snapshot.
        store = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [archive]
        )
        let second = store.beginDrainBatch()
        _ = try store.append(
            identity: secondIdentity,
            encodedJSONObject: record(sequence: 12),
            to: archive,
            batch: second
        )
        _ = try store.flush(second)

        var rebuiltRawArchive = false
        store = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [archive],
            onStartupRawArchiveRebuild: { rebuiltRawArchive = true }
        )
        XCTAssertFalse(rebuiltRawArchive)

        let replay = store.beginDrainBatch()
        XCTAssertEqual(
            try store.append(
                identity: secondIdentity,
                encodedJSONObject: record(sequence: 12),
                to: archive,
                batch: replay
            ),
            .duplicate(durable: false)
        )
        XCTAssertEqual(try lineCount(at: archive), 2)
    }

    func testNewRotatedArchiveReusesSnapshotWithoutRescanningOlderRawFiles() throws {
        let directory = try temporaryDirectory()
        let firstArchive = directory.appendingPathComponent("historical.jsonl")
        let rotatedArchive = directory.appendingPathComponent("raw-rotated.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        let firstIdentity = frameIdentity(counter: 31, payload: Data([0x31]))
        let rotatedIdentity = frameIdentity(counter: 32, payload: Data([0x32]))

        var store = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [firstArchive]
        )
        let first = store.beginDrainBatch()
        _ = try store.append(
            identity: firstIdentity,
            encodedJSONObject: record(sequence: 31),
            to: firstArchive,
            batch: first
        )
        _ = try store.flush(first)

        // Rotation registers a new path and appends its exact identity after
        // the existing snapshot's attested index prefix.
        let rotated = store.beginDrainBatch()
        _ = try store.append(
            identity: rotatedIdentity,
            encodedJSONObject: record(sequence: 32),
            to: rotatedArchive,
            batch: rotated
        )
        _ = try store.flush(rotated)

        var rebuiltRawArchive = false
        store = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [firstArchive, rotatedArchive],
            onStartupRawArchiveRebuild: { rebuiltRawArchive = true }
        )
        XCTAssertFalse(
            rebuiltRawArchive,
            "a newly rotated append-only archive must not rescan every older raw file"
        )

        let firstReplay = store.beginDrainBatch()
        XCTAssertEqual(
            try store.append(
                identity: firstIdentity,
                encodedJSONObject: record(sequence: 31),
                to: firstArchive,
                batch: firstReplay
            ),
            .duplicate(durable: false)
        )
        let rotatedReplay = store.beginDrainBatch()
        XCTAssertEqual(
            try store.append(
                identity: rotatedIdentity,
                encodedJSONObject: record(sequence: 32),
                to: rotatedArchive,
                batch: rotatedReplay
            ),
            .duplicate(durable: false)
        )
        XCTAssertEqual(try lineCount(at: firstArchive), 1)
        XCTAssertEqual(try lineCount(at: rotatedArchive), 1)
    }

    func testSnapshotLoadedIdentityVerifiesRawRowBeforeRejectingReplay() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        let identity = frameIdentity(counter: 21, payload: Data([0xaa, 0xbb, 0xcc]))

        var store = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [archive]
        )
        let original = store.beginDrainBatch()
        _ = try store.append(
            identity: identity,
            encodedJSONObject: record(sequence: 21),
            to: archive,
            batch: original
        )
        _ = try store.flush(original)

        // Establish a current snapshot, then mutate one suffix byte while
        // preserving the snapshotted inode, byte count and modification time.
        store = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [archive]
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        let modificationDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        var bytes = try Data(contentsOf: archive)
        let newline = try XCTUnwrap(bytes.lastIndex(of: 0x0a))
        let mutationIndex = bytes.index(before: newline)
        bytes[mutationIndex] = bytes[mutationIndex] == 0x7d ? 0x20 : 0x7d
        try bytes.write(to: archive, options: [])
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: archive.path
        )

        var rebuiltRawArchive = false
        store = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [archive],
            onStartupRawArchiveRebuild: { rebuiltRawArchive = true }
        )
        XCTAssertFalse(rebuiltRawArchive)

        let repair = store.beginDrainBatch()
        XCTAssertEqual(
            try store.append(
                identity: identity,
                encodedJSONObject: record(sequence: 21),
                to: archive,
                batch: repair
            ),
            .inserted,
            "a cached identity may not reject replay after its exact raw row fails CRC"
        )
        XCTAssertEqual(try lineCount(at: archive), 2)
    }

    func testOneBatchFlushSynchronizesEveryRotatedFileAndTheIndex() throws {
        let directory = try temporaryDirectory()
        let firstArchive = directory.appendingPathComponent("base.jsonl")
        let secondArchive = directory.appendingPathComponent("segments/segment-1.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        let store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                           existingArchiveURLs: [])
        let batch = store.beginDrainBatch()
        _ = try store.append(identity: frameIdentity(counter: 1, payload: Data([1])),
                             encodedJSONObject: record(sequence: 1),
                             to: firstArchive,
                             batch: batch)
        _ = try store.append(identity: frameIdentity(counter: 2, payload: Data([2])),
                             encodedJSONObject: record(sequence: 2),
                             to: secondArchive,
                             batch: batch)

        let receipt = try store.flush(batch)
        XCTAssertEqual(Set(receipt.synchronizedFiles), Set([firstArchive, secondArchive, index]))
        XCTAssertEqual(receipt.insertedOrPendingKeys, 2)
        XCTAssertEqual(try lineCount(at: firstArchive), 1)
        XCTAssertEqual(try lineCount(at: secondArchive), 1)
    }

    func testSplitSealsAreDistinctBoundToExactKeysAndMonotonic() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        let store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                           existingArchiveURLs: [])
        let first = store.beginDrainBatch()
        _ = try store.append(identity: frameIdentity(payload: Data([0x01, 0x02])),
                             encodedJSONObject: record(sequence: 1),
                             to: archive,
                             batch: first)
        let firstReceipt = try store.flush(first)

        XCTAssertTrue(firstReceipt.isPromotionAuthority)
        XCTAssertNotEqual(firstReceipt.raw.storeIdentifier,
                          firstReceipt.identity.storeIdentifier)
        XCTAssertNotEqual(firstReceipt.raw.snapshotSHA256,
                          firstReceipt.identity.snapshotSHA256)
        XCTAssertEqual(firstReceipt.raw.batchKeysSHA256,
                       firstReceipt.identity.batchKeysSHA256)
        XCTAssertEqual(firstReceipt.raw.durableSequence, 1)
        XCTAssertEqual(firstReceipt.identity.durableSequence, 1)
        XCTAssertEqual(firstReceipt.raw.recordCount, 1)
        XCTAssertEqual(firstReceipt.identity.recordCount, 1)
        XCTAssertGreaterThan(firstReceipt.raw.byteCount, 0)
        XCTAssertGreaterThan(firstReceipt.identity.byteCount, 0)

        let second = store.beginDrainBatch()
        _ = try store.append(identity: frameIdentity(counter: 100, payload: Data([0x03])),
                             encodedJSONObject: record(sequence: 2),
                             to: archive,
                             batch: second)
        let secondReceipt = try store.flush(second)
        XCTAssertEqual(secondReceipt.durableSequence, 2)
        XCTAssertNotEqual(secondReceipt.receiptChainSHA256,
                          firstReceipt.receiptChainSHA256)
        XCTAssertNotEqual(secondReceipt.raw.batchKeysSHA256,
                          firstReceipt.raw.batchKeysSHA256)
    }

    func testRestartContinuesReceiptSequenceAndTamperedStateFailsClosed() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        var store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                           existingArchiveURLs: [])
        let first = store.beginDrainBatch()
        _ = try store.append(identity: frameIdentity(payload: Data([0xaa])),
                             encodedJSONObject: record(sequence: 1),
                             to: archive,
                             batch: first)
        XCTAssertEqual(try store.flush(first).durableSequence, 1)

        store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                        existingArchiveURLs: [archive])
        let empty = store.beginDrainBatch()
        let restartedReceipt = try store.flush(empty)
        XCTAssertEqual(restartedReceipt.durableSequence, 2)
        XCTAssertEqual(restartedReceipt.raw.recordCount, 0)

        let receiptState = index.deletingPathExtension()
            .appendingPathExtension("durability.json")
        var bytes = try Data(contentsOf: receiptState)
        XCTAssertFalse(bytes.isEmpty)
        bytes[bytes.startIndex] ^= 0xff
        try bytes.write(to: receiptState)
        XCTAssertThrowsError(try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [archive]
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalArchiveDurableStore.StoreError,
                           .corruptDurabilityReceiptState)
        }
    }

    func testReplayOnlyAndEmptyTailReceiptsDoNotFabricatePositiveRows() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        let identity = frameIdentity(payload: Data([0x42]))
        let store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                           existingArchiveURLs: [])
        let inserted = store.beginDrainBatch()
        _ = try store.append(identity: identity,
                             encodedJSONObject: record(sequence: 1),
                             to: archive,
                             batch: inserted)
        _ = try store.flush(inserted)

        let replay = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: identity,
                                        encodedJSONObject: record(sequence: 1),
                                        to: archive,
                                        batch: replay), .duplicate(durable: true))
        let replayReceipt = try store.flush(replay)
        XCTAssertEqual(replayReceipt.raw.recordCount, 0)
        XCTAssertEqual(replayReceipt.identity.recordCount, 0)
        XCTAssertEqual(replayReceipt.raw.byteCount, 0)
        XCTAssertEqual(replayReceipt.raw.observedIdentityCount, 1)
        XCTAssertTrue(replayReceipt.isPromotionAuthority)

        let emptyReceipt = try store.flush(store.beginDrainBatch())
        XCTAssertEqual(emptyReceipt.raw.recordCount, 0)
        XCTAssertEqual(emptyReceipt.raw.observedIdentityCount, 0)
        XCTAssertEqual(emptyReceipt.durableSequence, replayReceipt.durableSequence + 1)
        XCTAssertTrue(emptyReceipt.isPromotionAuthority)
    }

    func testReceiptStateFsyncFailureDoesNotPromotePendingRows() throws {
        enum InjectedFault: Error { case receiptSync }
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        var failReceipt = true
        let store = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [],
            receiptFileSynchronizer: { url in
                if failReceipt { throw InjectedFault.receiptSync }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.synchronize()
            }
        )
        let identity = frameIdentity(payload: Data([0x99]))
        let failed = store.beginDrainBatch()
        _ = try store.append(identity: identity,
                             encodedJSONObject: record(sequence: 1),
                             to: archive,
                             batch: failed)
        XCTAssertThrowsError(try store.flush(failed))

        failReceipt = false
        let retry = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: identity,
                                        encodedJSONObject: record(sequence: 1),
                                        to: archive,
                                        batch: retry), .duplicate(durable: false))
        let receipt = try store.flush(retry)
        XCTAssertEqual(receipt.durableSequence, 1)
        XCTAssertEqual(receipt.raw.recordCount, 1)

        let replay = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: identity,
                                        encodedJSONObject: record(sequence: 1),
                                        to: archive,
                                        batch: replay), .duplicate(durable: true))
    }

    func testReceiptCheckpointRemainsBoundedAcrossManyEmptyFlushes() throws {
        let directory = try temporaryDirectory()
        let index = directory.appendingPathComponent("historical.index.jsonl")
        let store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                           existingArchiveURLs: [])
        for expected in 1...512 {
            let receipt = try store.flush(store.beginDrainBatch())
            XCTAssertEqual(receipt.durableSequence, UInt64(expected))
        }
        let stateURL = index.deletingPathExtension()
            .appendingPathExtension("durability.json")
        let bytes = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: stateURL.path)[.size] as? NSNumber
        ).uint64Value
        XCTAssertLessThan(bytes, 4 * 1_024,
                          "receipt chain is a fixed-size checkpoint, not an archive rescan/log")
    }

    func testReceiptBatchIdentityMemoryIsExplicitlyBoundedAndFailsClosed() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        let store = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [],
            maximumReceiptBatchIdentities: 2
        )
        let batch = store.beginDrainBatch()
        for counter in UInt32(1)...UInt32(2) {
            _ = try store.append(
                identity: frameIdentity(counter: counter, payload: Data([UInt8(counter)])),
                encodedJSONObject: record(sequence: Int(counter)),
                to: archive,
                batch: batch
            )
        }
        XCTAssertThrowsError(try store.append(
            identity: frameIdentity(counter: 3, payload: Data([3])),
            encodedJSONObject: record(sequence: 3),
            to: archive,
            batch: batch
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalArchiveDurableStore.StoreError,
                           .receiptBatchCapacityExceeded(maximum: 2))
        }
        let receipt = try store.flush(batch)
        XCTAssertEqual(receipt.raw.recordCount, 2)
        XCTAssertEqual(receipt.raw.observedIdentityCount, 2)
    }

    func testReplayOfUnflushedRowInheritsItsDurabilityWork() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        let identity = frameIdentity(payload: Data([0xfe, 0xed]))
        let store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                           existingArchiveURLs: [])
        let abandonedBatch = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: identity,
                                        encodedJSONObject: record(sequence: 9),
                                        to: archive,
                                        batch: abandonedBatch), .inserted)

        let replayBatch = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: identity,
                                        encodedJSONObject: record(sequence: 9),
                                        to: archive,
                                        batch: replayBatch), .duplicate(durable: false))
        XCTAssertEqual(Set(try store.flush(replayBatch).synchronizedFiles), Set([archive, index]))

        let durableReplay = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: identity,
                                        encodedJSONObject: record(sequence: 9),
                                        to: archive,
                                        batch: durableReplay), .duplicate(durable: true))
        XCTAssertEqual(try lineCount(at: archive), 1)
    }

    func testRestartedCompleteRowCannotBecomeDurableWhenArchiveSyncFails() throws {
        enum InjectedFault: Error {
            case archiveSynchronizeFailed
        }

        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl").standardizedFileURL
        let index = directory.appendingPathComponent("historical.index.jsonl").standardizedFileURL
        let identity = frameIdentity(payload: Data([0xCA, 0xFE]))

        // Model process death after a complete archive/index append but before
        // the generation's durability boundary.
        var store: AtriaHistoricalArchiveDurableStore? = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: []
        )
        let abandoned = try XCTUnwrap(store).beginDrainBatch()
        XCTAssertEqual(try XCTUnwrap(store).append(
            identity: identity,
            encodedJSONObject: record(sequence: 88),
            to: archive,
            batch: abandoned
        ), .inserted)
        store = nil

        var shouldFailArchiveSync = true
        var synchronizedURLs: [URL] = []
        let restarted = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [archive],
            fileSynchronizer: { url in
                let canonical = url.standardizedFileURL
                synchronizedURLs.append(canonical)
                if canonical == archive, shouldFailArchiveSync {
                    throw InjectedFault.archiveSynchronizeFailed
                }
                let handle = try FileHandle(forWritingTo: canonical)
                defer { try? handle.close() }
                try handle.synchronize()
            }
        )

        let failedReplay = restarted.beginDrainBatch()
        XCTAssertEqual(try restarted.append(
            identity: identity,
            encodedJSONObject: record(sequence: 88),
            to: archive,
            batch: failedReplay
        ), .duplicate(durable: false))
        XCTAssertThrowsError(try restarted.flush(failedReplay)) { error in
            XCTAssertTrue(error is InjectedFault)
        }
        XCTAssertTrue(synchronizedURLs.contains(archive))

        // A later replay must still inherit the pending archive+index work. It
        // becomes durable only after both synchronizations actually succeed.
        shouldFailArchiveSync = false
        synchronizedURLs.removeAll()
        let retry = restarted.beginDrainBatch()
        XCTAssertEqual(try restarted.append(
            identity: identity,
            encodedJSONObject: record(sequence: 88),
            to: archive,
            batch: retry
        ), .duplicate(durable: false))
        XCTAssertEqual(Set(try restarted.flush(retry).synchronizedFiles), Set([archive, index]))
        XCTAssertEqual(Set(synchronizedURLs), Set([archive, index]))

        let durableReplay = restarted.beginDrainBatch()
        XCTAssertEqual(try restarted.append(
            identity: identity,
            encodedJSONObject: record(sequence: 88),
            to: archive,
            batch: durableReplay
        ), .duplicate(durable: true))
        XCTAssertEqual(try lineCount(at: archive), 1)
    }

    func testRestartedCompleteRowCannotBecomeDurableWhenIndexSyncFails() throws {
        enum InjectedFault: Error {
            case indexSynchronizeFailed
        }

        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl").standardizedFileURL
        let index = directory.appendingPathComponent("historical.index.jsonl").standardizedFileURL
        let identity = frameIdentity(payload: Data([0xBA, 0xAD]))

        var store: AtriaHistoricalArchiveDurableStore? = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: []
        )
        let abandoned = try XCTUnwrap(store).beginDrainBatch()
        XCTAssertEqual(try XCTUnwrap(store).append(
            identity: identity,
            encodedJSONObject: record(sequence: 89),
            to: archive,
            batch: abandoned
        ), .inserted)
        store = nil

        // Let startup rebuild and synchronize its derived index, then fail the
        // replay batch's index boundary after its archive sync has succeeded.
        var shouldFailIndexSync = false
        var synchronizedURLs: [URL] = []
        let restarted = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [archive],
            fileSynchronizer: { url in
                let canonical = url.standardizedFileURL
                synchronizedURLs.append(canonical)
                if canonical == index, shouldFailIndexSync {
                    throw InjectedFault.indexSynchronizeFailed
                }
                let handle = try FileHandle(forWritingTo: canonical)
                defer { try? handle.close() }
                try handle.synchronize()
            }
        )
        shouldFailIndexSync = true
        synchronizedURLs.removeAll()

        let failedReplay = restarted.beginDrainBatch()
        XCTAssertEqual(try restarted.append(
            identity: identity,
            encodedJSONObject: record(sequence: 89),
            to: archive,
            batch: failedReplay
        ), .duplicate(durable: false))
        XCTAssertThrowsError(try restarted.flush(failedReplay)) { error in
            XCTAssertTrue(error is InjectedFault)
        }
        XCTAssertEqual(synchronizedURLs, [archive, index])

        // Even though this attempt synchronized the archive, the store must
        // not advertise a durable duplicate until the paired index sync also
        // succeeds in a complete flush.
        shouldFailIndexSync = false
        synchronizedURLs.removeAll()
        let retry = restarted.beginDrainBatch()
        XCTAssertEqual(try restarted.append(
            identity: identity,
            encodedJSONObject: record(sequence: 89),
            to: archive,
            batch: retry
        ), .duplicate(durable: false))
        XCTAssertEqual(Set(try restarted.flush(retry).synchronizedFiles), Set([archive, index]))
        XCTAssertEqual(Set(synchronizedURLs), Set([archive, index]))

        let durableReplay = restarted.beginDrainBatch()
        XCTAssertEqual(try restarted.append(
            identity: identity,
            encodedJSONObject: record(sequence: 89),
            to: archive,
            batch: durableReplay
        ), .duplicate(durable: true))
        XCTAssertEqual(try lineCount(at: archive), 1)
    }

    func testIdentityIncludesExactPayloadAndStrapIdentity() {
        let first = frameIdentity(payload: Data([1, 2, 3]))
        let changedPayload = frameIdentity(payload: Data([1, 2, 4]))
        let changedStrap = AtriaHistoricalArchiveDurableStore.FrameIdentity(
            strapIdentifier: "other-strap",
            protocolVersion: 24,
            counter: 99,
            unixSeconds: 1_752_000_000,
            subsecond: 512,
            payload: Data([1, 2, 3])
        )
        XCTAssertNotEqual(first.stableKey, changedPayload.stableKey)
        XCTAssertNotEqual(first.stableKey, changedStrap.stableKey)
        XCTAssertEqual(first.stableKey, frameIdentity(payload: Data([1, 2, 3])).stableKey)
    }

    func testKnownCRC32CollisionPayloadsRemainDistinct() {
        // These two byte strings both have CRC32 0x4ddb0c25. A checksum-based
        // replay identity would silently reject one as a duplicate and could
        // ACK data that was never archived.
        let first = frameIdentity(payload: Data("plumless".utf8))
        let second = frameIdentity(payload: Data("buckeroo".utf8))

        XCTAssertNotEqual(first.stableKey, second.stableKey)
    }

    func testExactIdentityHorizonUsesObservationTimeNotOldStrapTimestamp() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        let identity = AtriaHistoricalArchiveDurableStore.FrameIdentity(
            strapIdentifier: "whoop-strap-4-test",
            protocolVersion: 24,
            counter: 9,
            // A three-week-old strap record downloaded now is protected from
            // the time we first durably observe it, not its event timestamp.
            unixSeconds: UInt32(clock.addingTimeInterval(-21 * 86_400).timeIntervalSince1970),
            subsecond: 0,
            payload: Data([9, 8, 7])
        )
        let store = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [],
            identityRetention: 14 * 86_400,
            now: { clock }
        )
        let batch = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: identity,
                                        encodedJSONObject: record(sequence: 9),
                                        to: archive,
                                        batch: batch), .inserted)
        _ = try store.flush(batch)

        clock = clock.addingTimeInterval(13 * 86_400)
        XCTAssertEqual(try store.pruneExpiredIdentities(now: clock), 0)
        XCTAssertTrue(store.contains(identity))
    }

    func testIdentityAtExactCutoffIsRetainedThenExpiresOneTickLater() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        var clock = Date(timeIntervalSince1970: 10_000)
        let identity = frameIdentity(payload: Data([0x10]))
        let store = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [],
            identityRetention: 100,
            now: { clock }
        )
        let batch = store.beginDrainBatch()
        _ = try store.append(identity: identity,
                             encodedJSONObject: record(sequence: 1),
                             to: archive,
                             batch: batch)
        _ = try store.flush(batch)

        clock = Date(timeIntervalSince1970: 10_100)
        XCTAssertEqual(try store.pruneExpiredIdentities(now: clock), 0)
        XCTAssertTrue(store.contains(identity))
        clock = Date(timeIntervalSince1970: 10_100.001)
        XCTAssertEqual(try store.pruneExpiredIdentities(now: clock), 1)
        XCTAssertFalse(store.contains(identity))
    }

    func testExpiredReplayIsInsertedAndMustFlushAgainBeforeDurableDuplicate() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        var clock = Date(timeIntervalSince1970: 20_000)
        let identity = frameIdentity(payload: Data([0x20]))
        let store = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [],
            identityRetention: 10,
            now: { clock }
        )
        let original = store.beginDrainBatch()
        _ = try store.append(identity: identity,
                             encodedJSONObject: record(sequence: 2),
                             to: archive,
                             batch: original)
        _ = try store.flush(original)
        clock = Date(timeIntervalSince1970: 20_011)
        XCTAssertEqual(try store.pruneExpiredIdentities(now: clock), 1)

        let replay = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: identity,
                                        encodedJSONObject: record(sequence: 2),
                                        to: archive,
                                        batch: replay), .inserted)
        XCTAssertEqual(Set(try store.flush(replay).synchronizedFiles), Set([archive, index]))
        let durableReplay = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: identity,
                                        encodedJSONObject: record(sequence: 2),
                                        to: archive,
                                        batch: durableReplay), .duplicate(durable: true))
        XCTAssertEqual(try lineCount(at: archive), 2)
    }

    func testPendingAndOpenBatchIdentitiesCannotBePruned() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        var clock = Date(timeIntervalSince1970: 30_000)
        let pendingIdentity = frameIdentity(counter: 1, payload: Data([1]))
        let durableIdentity = frameIdentity(counter: 2, payload: Data([2]))
        let store = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: [],
            identityRetention: 10,
            now: { clock }
        )
        let pending = store.beginDrainBatch()
        _ = try store.append(identity: pendingIdentity,
                             encodedJSONObject: record(sequence: 1),
                             to: archive,
                             batch: pending)
        let firstDurable = store.beginDrainBatch()
        _ = try store.append(identity: durableIdentity,
                             encodedJSONObject: record(sequence: 2),
                             to: archive,
                             batch: firstDurable)
        _ = try store.flush(firstDurable)
        let protectingReplay = store.beginDrainBatch()
        XCTAssertEqual(try store.append(identity: durableIdentity,
                                        encodedJSONObject: record(sequence: 2),
                                        to: archive,
                                        batch: protectingReplay), .duplicate(durable: true))

        clock = Date(timeIntervalSince1970: 30_011)
        XCTAssertEqual(try store.pruneExpiredIdentities(now: clock), 0)
        XCTAssertTrue(store.contains(pendingIdentity))
        XCTAssertTrue(store.contains(durableIdentity))

        _ = try store.flush(protectingReplay)
        XCTAssertEqual(try store.pruneExpiredIdentities(now: clock), 1)
        XCTAssertTrue(store.contains(pendingIdentity))
        XCTAssertFalse(store.contains(durableIdentity))
    }

    func testExistingCodableRecordIgnoresInjectedIdentityFields() throws {
        struct ExistingReader: Decodable, Equatable {
            let sequence: Int
            let rawPayloadHex: String
        }

        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("historical.jsonl")
        let index = directory.appendingPathComponent("historical.index.jsonl")
        let store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                           existingArchiveURLs: [])
        let batch = store.beginDrainBatch()
        _ = try store.append(identity: frameIdentity(payload: Data([0xab])),
                             encodedJSONObject: record(sequence: 12),
                             to: archive,
                             batch: batch)
        _ = try store.flush(batch)

        let line = try XCTUnwrap(String(contentsOf: archive, encoding: .utf8)
            .split(separator: "\n").first)
        let decoded = try JSONDecoder().decode(ExistingReader.self, from: Data(line.utf8))
        XCTAssertEqual(decoded, ExistingReader(sequence: 12, rawPayloadHex: "aabb"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalArchiveDurableStoreTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func frameIdentity(counter: UInt32 = 99,
                               payload: Data) -> AtriaHistoricalArchiveDurableStore.FrameIdentity {
        AtriaHistoricalArchiveDurableStore.FrameIdentity(
            strapIdentifier: "whoop-strap-4-test",
            protocolVersion: 24,
            counter: counter,
            unixSeconds: 1_752_000_000,
            subsecond: 512,
            payload: payload
        )
    }

    private func record(sequence: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schema": 3,
            "sequence": sequence,
            "rawPayloadHex": "aabb"
        ], options: [.sortedKeys])
    }

    private func lineCount(at url: URL) throws -> Int {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .count
    }
}
