import Foundation
import SQLite3
import XCTest
@testable import Atria

final class AtriaWhoop4HistoryAdmissionLedgerTests: XCTestCase {
    func testIncrementalDurablePrefixesKeepTerminalReceiptCumulative() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-checkpoint")
        let frames = (0..<4).map { Data([0x2f, UInt8($0)]) }
        for frame in frames {
            _ = try ledger.classify(frame: frame, attempt: attempt)
        }

        let first = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: attempt,
            through: 1,
            archiveReceipt: fixture.archiveReceipt(recordCount: 2)
        ).receipt
        XCTAssertEqual(first.recordCount, 2)
        XCTAssertEqual(first.durableOrdinal, 1)

        let second = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: attempt,
            through: 3,
            archiveReceipt: fixture.archiveReceipt(recordCount: 2)
        ).receipt
        XCTAssertEqual(second.recordCount, 4)
        XCTAssertEqual(second.durableOrdinal, 3)

        // A HISTORY_END may follow an incremental checkpoint with no new
        // rows. Its final seal still advances the receipt chain and retains
        // the entire durable prefix for strict terminal enumeration.
        let terminal = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: attempt,
            through: 3,
            archiveReceipt: fixture.archiveReceipt(recordCount: 0)
        ).receipt
        XCTAssertEqual(terminal.recordCount, 4)
        XCTAssertEqual(terminal.durableOrdinal, 3)

        var enumerated: [Data] = []
        let report = try ledger.enumerateDurableFrames(
            attemptIdentifier: attempt.identifier,
            strapIdentifier: attempt.strapIdentifier,
            throughReceipt: terminal
        ) { _, frame in
            enumerated.append(frame)
        }
        XCTAssertEqual(report.recordCount, 4)
        XCTAssertEqual(enumerated, frames)
    }

    func testPendingFrameEnumerationCoversInterruptedAttemptPrefixExactly() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-pending")
        let frames = [Data([0x2f, 1]), Data([0x2f, 2]), Data([0x2f, 3])]
        for frame in frames {
            _ = try ledger.classify(frame: frame, attempt: attempt)
        }

        XCTAssertEqual(try ledger.pendingFrames(attempt: attempt, through: 2), frames)
        XCTAssertThrowsError(try ledger.pendingFrames(attempt: attempt,
                                                       through: 2,
                                                       maximumFrames: 2))
    }
    func testRetiredExactLookupRejectsOnlyExactKeyAndDoesOnePointLookup() throws {
        let fixture = try Fixture()
        let retired = Data([0x2f, 0x18, 0, 1, 0, 0, 0, 10, 0, 0, 0, 1, 0])
        let newFrame = Data([0x2f, 0x18, 0, 2, 0, 0, 0, 11, 0, 0, 0, 1, 0])
        var lookupCount = 0
        let ledger = try fixture.ledger(retiredReplayLookup: { strap, frame in
            lookupCount += 1
            return strap == "strap-retired" && frame == retired
        })
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-retired")

        XCTAssertEqual(try ledger.classify(frame: retired, attempt: attempt),
                       .durableReplay(ordinal: 0))
        XCTAssertEqual(try ledger.classify(frame: retired, attempt: attempt),
                       .duplicateInCurrentIncarnation(ordinal: 0))
        XCTAssertEqual(try ledger.classify(frame: newFrame, attempt: attempt),
                       .firstSeen(ordinal: 1))
        XCTAssertEqual(lookupCount, 2,
                       "only ledger misses may perform one bounded retired-index lookup")
    }

    func testRestartReplaysUnflushedAdmissionIntoPersistence() throws {
        let fixture = try Fixture()
        let firstLedger = try fixture.ledger(durable: true)
        let first = try firstLedger.beginAttempt(strapIdentifier: "strap-a")
        let frame = Data([0x2f, 0x18, 0, 1, 0, 0xaa])

        XCTAssertEqual(try firstLedger.classify(frame: frame, attempt: first),
                       .firstSeen(ordinal: 0))

        let restartedLedger = try fixture.ledger(durable: true)
        let resumed = try restartedLedger.beginAttempt(strapIdentifier: "strap-a")
        XCTAssertEqual(resumed.identifier, first.identifier)
        XCTAssertNotEqual(resumed.incarnation, first.incarnation)
        XCTAssertEqual(try restartedLedger.classify(frame: frame, attempt: resumed),
                       .needsPersistence(ordinal: 1),
                       "write-ahead identity without raw fsync must be persisted again")
    }

    func testRawFsyncPromotionMakesRestartReplaySkippable() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-a")
        let frame = Data([0x2f, 0x18, 0, 1, 0, 0xbb])
        XCTAssertEqual(try ledger.classify(frame: frame, attempt: attempt),
                       .firstSeen(ordinal: 0))
        let archiveReceipt = try fixture.archiveReceipt(recordCount: 1)
        XCTAssertEqual(try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: attempt,
            through: 0,
            archiveReceipt: archiveReceipt
        ).changedRows, 1)

        let restarted = try fixture.ledger()
        let resumed = try restarted.beginAttempt(strapIdentifier: "strap-a")
        XCTAssertEqual(try restarted.classify(frame: frame, attempt: resumed),
                       .durableReplay(ordinal: 1))
    }

    func testPromotionRequiresArchiveAndIdentityFsyncReceipt() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-required")
        _ = try ledger.classify(frame: Data([0x01]), attempt: attempt)

        XCTAssertThrowsError(try ledger.markCurrentPrefixArchiveDurable(
            attempt: attempt,
            through: 0
        )) { error in
            XCTAssertEqual(error as? AtriaWhoop4HistoryAdmissionLedger.LedgerError,
                           .archiveDurabilityReceiptRequired)
        }
        let restarted = try fixture.ledger()
        let resumed = try restarted.beginAttempt(strapIdentifier: "strap-required")
        XCTAssertEqual(try restarted.classify(frame: Data([0x01]), attempt: resumed),
                       .needsPersistence(ordinal: 1))
    }

    func testEmptyReceiptCannotPromotePositivePrefixButCanSealDurableOnlyTail() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-empty")
        _ = try ledger.classify(frame: Data([0x10]), attempt: attempt)
        let empty = try fixture.archiveReceipt(recordCount: 0)
        XCTAssertThrowsError(try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: attempt,
            through: 0,
            archiveReceipt: empty
        )) { error in
            XCTAssertEqual(error as? AtriaWhoop4HistoryAdmissionLedger.LedgerError,
                           .invalidArchiveDurabilityReceipt)
        }

        let positive = try fixture.archiveReceipt(recordCount: 1)
        let promoted = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: attempt,
            through: 0,
            archiveReceipt: positive
        )
        XCTAssertEqual(promoted.changedRows, 1)
        XCTAssertEqual(promoted.receipt.durableSequence, positive.durableSequence)
        XCTAssertEqual(promoted.receipt.rawArchiveSnapshotSHA256,
                       positive.raw.snapshotSHA256)
        XCTAssertEqual(promoted.receipt.identityIndexSnapshotSHA256,
                       positive.identity.snapshotSHA256)
        XCTAssertNotEqual(promoted.receipt.snapshotSHA256,
                          positive.raw.snapshotSHA256)

        let emptyTail = try fixture.archiveReceipt(recordCount: 0)
        let sealedTail = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: attempt,
            through: 0,
            archiveReceipt: emptyTail
        )
        XCTAssertEqual(sealedTail.changedRows, 0)
        XCTAssertEqual(sealedTail.receipt.durableSequence, emptyTail.durableSequence)
    }

    func testEmptyFirstBoundaryPreservesOrdinalZeroForLaterPositivePrefix() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-empty-first")
        let emptyArchive = try fixture.archiveReceipt(recordCount: 0)
        let emptyAdmission = try ledger.recordEmptyArchiveDurabilityBoundary(
            attempt: attempt,
            archiveReceipt: emptyArchive
        )
        XCTAssertNil(emptyAdmission.durableOrdinal)
        XCTAssertEqual(emptyAdmission.recordCount, 0)
        XCTAssertEqual(emptyAdmission.byteCount, 0)

        let frame = Data([0x2f, 0x18, 0x00, 0x01])
        XCTAssertEqual(try ledger.classify(frame: frame, attempt: attempt),
                       .firstSeen(ordinal: 0),
                       "an empty ACK boundary must not consume the first real ordinal")
        let positiveArchive = try fixture.archiveReceipt(recordCount: 1)
        let positive = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: attempt,
            through: 0,
            archiveReceipt: positiveArchive
        ).receipt
        XCTAssertEqual(positive.durableOrdinal, 0)
        XCTAssertEqual(positive.recordCount, 1)
        var recovered: [(UInt64, Data)] = []
        let report = try ledger.enumerateDurableFrames(
            attemptIdentifier: attempt.identifier,
            strapIdentifier: attempt.strapIdentifier,
            throughReceipt: positive
        ) { recovered.append(($0, $1)) }
        XCTAssertEqual(report.recordCount, 1)
        XCTAssertEqual(recovered.map(\.0), [0])
        XCTAssertEqual(recovered.map(\.1), [frame])
    }

    func testRepeatedEmptyBoundarySurvivesRestartWithoutFabricatingPrefix() throws {
        let fixture = try Fixture()
        var ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-empty-restart")
        let first = try ledger.recordEmptyArchiveDurabilityBoundary(
            attempt: attempt,
            archiveReceipt: fixture.archiveReceipt(recordCount: 0)
        )
        XCTAssertNil(first.durableOrdinal)

        ledger = try fixture.ledger()
        let resumed = try ledger.beginAttempt(strapIdentifier: "strap-empty-restart")
        XCTAssertEqual(resumed.identifier, attempt.identifier)
        let replayOnlyEmpty = try ledger.recordEmptyArchiveDurabilityBoundary(
            attempt: resumed,
            archiveReceipt: fixture.archiveReceipt(recordCount: 0)
        )
        XCTAssertNil(replayOnlyEmpty.durableOrdinal)
        XCTAssertGreaterThan(replayOnlyEmpty.durableSequence, first.durableSequence)
        XCTAssertNotEqual(replayOnlyEmpty.snapshotSHA256, first.snapshotSHA256)
        XCTAssertEqual(try ledger.classify(frame: Data([0x70]), attempt: resumed),
                       .firstSeen(ordinal: 0))
    }

    func testEmptyBoundaryRejectsReceiptReuseAndStructuralTamper() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-empty-tamper")
        let archive = try fixture.archiveReceipt(recordCount: 0)
        _ = try ledger.recordEmptyArchiveDurabilityBoundary(
            attempt: attempt,
            archiveReceipt: archive
        )
        XCTAssertThrowsError(try ledger.recordEmptyArchiveDurabilityBoundary(
            attempt: attempt,
            archiveReceipt: archive
        )) { error in
            XCTAssertEqual(error as? AtriaWhoop4HistoryAdmissionLedger.LedgerError,
                           .reusedArchiveDurabilityReceipt)
        }

        let nextArchive = try fixture.archiveReceipt(recordCount: 0)
        let tamperedRaw = AtriaHistoricalArchiveDurableStore.DurableSeal(
            storeIdentifier: nextArchive.raw.storeIdentifier,
            durableSequence: nextArchive.raw.durableSequence,
            snapshotSHA256: "tampered",
            batchKeysSHA256: nextArchive.raw.batchKeysSHA256,
            byteCount: nextArchive.raw.byteCount,
            recordCount: nextArchive.raw.recordCount,
            observedIdentityCount: nextArchive.raw.observedIdentityCount,
            fsyncedAtUnix: nextArchive.raw.fsyncedAtUnix
        )
        let tampered = AtriaHistoricalArchiveDurableStore.FlushReceipt(
            batchIdentifier: nextArchive.batchIdentifier,
            synchronizedFiles: nextArchive.synchronizedFiles,
            insertedOrPendingKeys: nextArchive.insertedOrPendingKeys,
            raw: tamperedRaw,
            identity: nextArchive.identity,
            receiptChainSHA256: nextArchive.receiptChainSHA256
        )
        XCTAssertThrowsError(try ledger.recordEmptyArchiveDurabilityBoundary(
            attempt: attempt,
            archiveReceipt: tampered
        )) { error in
            XCTAssertEqual(error as? AtriaWhoop4HistoryAdmissionLedger.LedgerError,
                           .invalidArchiveDurabilityReceipt)
        }
    }

    func testPrefixReceiptCodableRoundTripPreservesNilOrdinalAndTamperIsRejected() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-codable")
        let receipt = try ledger.recordEmptyArchiveDurabilityBoundary(
            attempt: attempt,
            archiveReceipt: fixture.archiveReceipt(recordCount: 0)
        )
        let encoded = try JSONEncoder().encode(receipt)
        let decoded = try JSONDecoder().decode(
            AtriaWhoop4HistoryAdmissionLedger.PrefixDurabilityReceipt.self,
            from: encoded
        )
        XCTAssertEqual(decoded, receipt)
        XCTAssertNil(decoded.durableOrdinal)
        let emptyReport = try ledger.enumerateDurableFrames(
            attemptIdentifier: attempt.identifier,
            strapIdentifier: attempt.strapIdentifier,
            throughReceipt: decoded
        ) { _, _ in XCTFail("empty prefix must not enumerate a frame") }
        XCTAssertEqual(emptyReport.recordCount, 0)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["snapshotSHA256"] = String(repeating: "0", count: 64)
        let tamperedData = try JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys])
        let tampered = try JSONDecoder().decode(
            AtriaWhoop4HistoryAdmissionLedger.PrefixDurabilityReceipt.self,
            from: tamperedData
        )
        XCTAssertThrowsError(try ledger.enumerateDurableFrames(
            attemptIdentifier: attempt.identifier,
            strapIdentifier: attempt.strapIdentifier,
            throughReceipt: tampered
        ) { _, _ in }) { error in
            XCTAssertEqual(error as? AtriaWhoop4HistoryAdmissionLedger.LedgerError,
                           .durablePrefixReceiptMismatch)
        }
    }

    func testAdmissionReceiptTimestampIsCapturedAfterFullCommit() throws {
        let fixture = try Fixture()
        let completedAt = Date(timeIntervalSince1970: 4_000_000_000)
        let ledger = try fixture.ledger(durabilityNow: { completedAt })
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-commit-time")
        _ = try ledger.classify(frame: Data([0x01]), attempt: attempt)
        let archive = try fixture.archiveReceipt(recordCount: 1)
        let receipt = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: attempt,
            through: 0,
            archiveReceipt: archive
        ).receipt
        XCTAssertEqual(receipt.fsyncedAtUnix, completedAt.timeIntervalSince1970)
        XCTAssertGreaterThan(receipt.fsyncedAtUnix, archive.raw.fsyncedAtUnix)
        XCTAssertGreaterThan(receipt.fsyncedAtUnix, archive.identity.fsyncedAtUnix)
    }

    func testReplayOnlyArchiveReceiptReconcilesCrashBetweenArchiveFsyncAndAdmissionPromotion() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let strap = "strap-split-boundary"
        let frames = [Data([0x18, 0x01, 0xaa]), Data([0x18, 0x02, 0xbb])]
        let attempt = try ledger.beginAttempt(strapIdentifier: strap)
        XCTAssertEqual(
            try ledger.classify(frames: frames, attempt: attempt),
            [.firstSeen(ordinal: 0), .firstSeen(ordinal: 1)]
        )

        let archive = fixture.directory.appendingPathComponent("split-history.jsonl")
        let index = fixture.directory.appendingPathComponent("split-history.index.jsonl")
        let store = try AtriaHistoricalArchiveDurableStore(
            indexURL: index,
            existingArchiveURLs: []
        )
        func append(_ frame: Data,
                    to batch: AtriaHistoricalArchiveDurableStore.DrainBatch) throws {
            let identity = AtriaHistoricalArchiveDurableStore.FrameIdentity.whoop4(
                strapIdentifier: strap,
                payload: frame
            )
            let record = try JSONSerialization.data(withJSONObject: [
                "schema": 3,
                "rawPayloadHex": frame.map { String(format: "%02x", $0) }.joined()
            ], options: [.sortedKeys])
            _ = try store.append(identity: identity,
                                 encodedJSONObject: record,
                                 to: archive,
                                 batch: batch)
        }

        // The first seal reaches disk, then the process dies before the
        // admission ledger receives/promotes that authority.
        let first = store.beginDrainBatch()
        try frames.forEach { try append($0, to: first) }
        let firstReceipt = try store.flush(first)
        XCTAssertEqual(firstReceipt.raw.recordCount, 2)

        // On retry the archive correctly reports exact durable duplicates.
        let replay = store.beginDrainBatch()
        try frames.forEach { try append($0, to: replay) }
        let replayReceipt = try store.flush(replay)
        XCTAssertEqual(replayReceipt.raw.recordCount, 0)
        XCTAssertEqual(replayReceipt.raw.observedIdentityCount, 2)

        let promoted = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: attempt,
            through: 1,
            archiveReceipt: replayReceipt
        )
        XCTAssertEqual(promoted.changedRows, 2)
        XCTAssertEqual(promoted.receipt.durableOrdinal, 1)
    }

    func testReplayOnlyReceiptCannotPromoteDifferentPendingPayloads() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-admission")
        _ = try ledger.classify(frames: [Data([0x01]), Data([0x02])], attempt: attempt)

        let otherStrap = "strap-archive"
        let archive = fixture.directory.appendingPathComponent("other-history.jsonl")
        let store = try AtriaHistoricalArchiveDurableStore(
            indexURL: fixture.directory.appendingPathComponent("other-history.index.jsonl"),
            existingArchiveURLs: []
        )
        let otherFrames = [Data([0xa1]), Data([0xa2])]
        for pass in 0..<2 {
            let batch = store.beginDrainBatch()
            for frame in otherFrames {
                let identity = AtriaHistoricalArchiveDurableStore.FrameIdentity.whoop4(
                    strapIdentifier: otherStrap,
                    payload: frame
                )
                let record = try JSONSerialization.data(withJSONObject: ["pass": pass])
                _ = try store.append(identity: identity,
                                     encodedJSONObject: record,
                                     to: archive,
                                     batch: batch)
            }
            let receipt = try store.flush(batch)
            if pass == 1 {
                XCTAssertEqual(receipt.raw.recordCount, 0)
                XCTAssertThrowsError(try ledger.markCurrentPrefixArchiveDurableWithReceipt(
                    attempt: attempt,
                    through: 1,
                    archiveReceipt: receipt
                )) { error in
                    XCTAssertEqual(error as? AtriaWhoop4HistoryAdmissionLedger.LedgerError,
                                   .invalidArchiveDurabilityReceipt)
                }
            }
        }
    }

    func testOneArchiveReceiptCannotPromoteTwoAdmissionPrefixes() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let first = try ledger.beginAttempt(strapIdentifier: "strap-one")
        _ = try ledger.classify(frame: Data([0x01]), attempt: first)
        let receipt = try fixture.archiveReceipt(recordCount: 1)
        _ = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: first,
            through: 0,
            archiveReceipt: receipt
        )

        let second = try ledger.beginAttempt(strapIdentifier: "strap-two")
        _ = try ledger.classify(frame: Data([0x02]), attempt: second)
        XCTAssertThrowsError(try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: second,
            through: 0,
            archiveReceipt: receipt
        )) { error in
            XCTAssertEqual(error as? AtriaWhoop4HistoryAdmissionLedger.LedgerError,
                           .reusedArchiveDurabilityReceipt)
        }
    }

    func testDurableFrameEnumerationExcludesStaleAttemptsAndVerifiesReceiptAfterRestart() throws {
        let fixture = try Fixture()
        var ledger = try fixture.ledger()
        let staleAttempt = try ledger.beginAttempt(strapIdentifier: "strap-stream")
        let staleOnly = Data([0xa0])
        let replayed = Data([0xb0])
        _ = try ledger.classify(frames: [staleOnly, replayed], attempt: staleAttempt)
        _ = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: staleAttempt,
            through: 1,
            archiveReceipt: fixture.archiveReceipt(recordCount: 2)
        )
        try ledger.finish(staleAttempt, succeeded: true)

        let current = try ledger.beginAttempt(strapIdentifier: "strap-stream")
        XCTAssertEqual(try ledger.classify(frame: replayed, attempt: current),
                       .durableReplay(ordinal: 0))
        let currentOnly = Data([0xc0])
        XCTAssertEqual(try ledger.classify(frame: currentOnly, attempt: current),
                       .firstSeen(ordinal: 1))
        let terminal = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: current,
            through: 1,
            archiveReceipt: fixture.archiveReceipt(recordCount: 1)
        ).receipt

        ledger = try fixture.ledger()
        var frames: [(UInt64, Data)] = []
        let report = try ledger.enumerateDurableFrames(
            attemptIdentifier: current.identifier,
            strapIdentifier: current.strapIdentifier,
            throughReceipt: terminal
        ) { frames.append(($0, $1)) }
        XCTAssertEqual(frames.map(\.0), [0, 1])
        XCTAssertEqual(frames.map(\.1), [replayed, currentOnly])
        XCTAssertFalse(frames.map(\.1).contains(staleOnly))
        XCTAssertEqual(report.recordCount, 2)
        XCTAssertEqual(report.byteCount, 2)
        XCTAssertEqual(report.durableOrdinal, 1)

        XCTAssertThrowsError(try ledger.enumerateDurableFrames(
            attemptIdentifier: staleAttempt.identifier,
            strapIdentifier: staleAttempt.strapIdentifier,
            throughReceipt: terminal
        ) { _, _ in }) { error in
            XCTAssertEqual(error as? AtriaWhoop4HistoryAdmissionLedger.LedgerError,
                           .durablePrefixReceiptMismatch)
        }
        XCTAssertThrowsError(try ledger.enumerateDurableFrames(
            attemptIdentifier: current.identifier,
            strapIdentifier: current.strapIdentifier,
            throughReceipt: terminal,
            maximumFrames: 1
        ) { _, _ in }) { error in
            XCTAssertEqual(error as? AtriaWhoop4HistoryAdmissionLedger.LedgerError,
                           .durableFrameEnumerationLimitExceeded(maximum: 1))
        }

        let tampered = AtriaWhoop4HistoryAdmissionLedger.PrefixDurabilityReceipt(
            storeIdentifier: terminal.storeIdentifier,
            snapshotSHA256: String(repeating: "f", count: 64),
            durableSequence: terminal.durableSequence,
            durableOrdinal: terminal.durableOrdinal,
            recordCount: terminal.recordCount,
            byteCount: terminal.byteCount,
            fsyncedAtUnix: terminal.fsyncedAtUnix,
            rawArchiveSnapshotSHA256: terminal.rawArchiveSnapshotSHA256,
            identityIndexSnapshotSHA256: terminal.identityIndexSnapshotSHA256,
            archiveReceiptChainSHA256: terminal.archiveReceiptChainSHA256
        )
        XCTAssertThrowsError(try ledger.enumerateDurableFrames(
            attemptIdentifier: current.identifier,
            strapIdentifier: current.strapIdentifier,
            throughReceipt: tampered
        ) { _, _ in }) { error in
            XCTAssertEqual(error as? AtriaWhoop4HistoryAdmissionLedger.LedgerError,
                           .durablePrefixReceiptMismatch)
        }
    }

    func testStreamingEnumerationExceedsFormerRetentionCapWithoutRetainingFrames() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-stream-large")
        let count = 524_289
        let byteCount = UInt64(count * 8)
        let rawDigest = String(repeating: "b", count: 64)
        let identityDigest = String(repeating: "c", count: 64)
        let prefixDigest = String(repeating: "a", count: 64)
        let chainDigest = String(repeating: "d", count: 64)
        try fixture.seedDurableEnumerationPrefix(
            attempt: attempt,
            recordCount: count,
            rawDigest: rawDigest,
            identityDigest: identityDigest,
            prefixDigest: prefixDigest,
            chainDigest: chainDigest
        )
        let receipt = AtriaWhoop4HistoryAdmissionLedger.PrefixDurabilityReceipt(
            storeIdentifier: "whoop4-exact-admission-sqlite-prefix-v2",
            snapshotSHA256: prefixDigest,
            durableSequence: 1,
            durableOrdinal: UInt64(count - 1),
            recordCount: UInt64(count),
            byteCount: byteCount,
            fsyncedAtUnix: Date().timeIntervalSince1970,
            rawArchiveSnapshotSHA256: rawDigest,
            identityIndexSnapshotSHA256: identityDigest,
            archiveReceiptChainSHA256: chainDigest
        )

        XCTAssertThrowsError(try ledger.enumerateDurableFrames(
            attemptIdentifier: attempt.identifier,
            strapIdentifier: attempt.strapIdentifier,
            throughReceipt: receipt,
            maximumFrames: 524_288
        ) { _, _ in }) { error in
            XCTAssertEqual(error as? AtriaWhoop4HistoryAdmissionLedger.LedgerError,
                           .durableFrameEnumerationLimitExceeded(maximum: 524_288))
        }

        var visited = 0
        var firstOrdinal: UInt64?
        var lastOrdinal: UInt64?
        let report = try ledger.enumerateDurableFrames(
            attemptIdentifier: attempt.identifier,
            strapIdentifier: attempt.strapIdentifier,
            throughReceipt: receipt
        ) { ordinal, frame in
            if firstOrdinal == nil { firstOrdinal = ordinal }
            lastOrdinal = ordinal
            visited += 1
            XCTAssertEqual(frame.count, 8)
        }
        XCTAssertEqual(visited, count)
        XCTAssertEqual(firstOrdinal, 0)
        XCTAssertEqual(lastOrdinal, UInt64(count - 1))
        XCTAssertEqual(report.recordCount, UInt64(count))
        XCTAssertEqual(report.byteCount, byteCount)
        XCTAssertEqual(AtriaWhoop4HistoryAdmissionLedger.productionMaximumDurableFrameEnumeration,
                       1_500_000)
    }

    func testSameIncarnationDuplicateOwnsNoSecondPersistenceCompletion() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-a")
        let frame = Data([0x2f, 0x18, 0, 7, 0])
        XCTAssertEqual(try ledger.classify(frame: frame, attempt: attempt),
                       .firstSeen(ordinal: 0))
        XCTAssertEqual(try ledger.classify(frame: frame, attempt: attempt),
                       .duplicateInCurrentIncarnation(ordinal: 0))
        XCTAssertEqual(try ledger.classify(frame: Data([0x01]), attempt: attempt),
                       .firstSeen(ordinal: 1),
                       "a duplicate must not consume an ordinal")
    }

    func testBoundedBatchGroupCommitsInOrderWithoutDuplicateOrdinal() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-batch")
        XCTAssertEqual(
            try ledger.classify(
                frames: [Data([0xa0]), Data([0xb0]), Data([0xa0]), Data([0xc0])],
                attempt: attempt
            ),
            [
                .firstSeen(ordinal: 0),
                .firstSeen(ordinal: 1),
                .duplicateInCurrentIncarnation(ordinal: 0),
                .firstSeen(ordinal: 2),
            ]
        )
        XCTAssertEqual(try ledger.countsForDiagnostics().frames, 3)

        XCTAssertThrowsError(
            try ledger.classify(
                frames: Array(repeating: Data([0xff]), count: 257),
                attempt: attempt
            )
        ) { error in
            XCTAssertEqual(
                error as? AtriaWhoop4HistoryAdmissionLedger.LedgerError,
                .classificationBatchTooLarge(maximum: 256)
            )
        }
        XCTAssertEqual(try ledger.countsForDiagnostics().frames, 3)
    }

    func testCompletePayloadAndStrapScopeAreExactIdentity() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let strapA = try ledger.beginAttempt(strapIdentifier: "strap-a")
        let prefix = Data(repeating: 0x55, count: 128)
        var distinct = prefix
        distinct.append(0x00)
        XCTAssertEqual(try ledger.classify(frame: prefix, attempt: strapA),
                       .firstSeen(ordinal: 0))
        XCTAssertEqual(try ledger.classify(frame: distinct, attempt: strapA),
                       .firstSeen(ordinal: 1),
                       "identity cannot collapse a common prefix or digest candidate")

        let strapB = try ledger.beginAttempt(strapIdentifier: "strap-b")
        XCTAssertEqual(try ledger.classify(frame: prefix, attempt: strapB),
                       .firstSeen(ordinal: 0),
                       "two physical straps may emit byte-identical records")
    }

    func testCompetingRestartInvalidatesOlderWriter() throws {
        let fixture = try Fixture()
        let firstLedger = try fixture.ledger()
        let stale = try firstLedger.beginAttempt(strapIdentifier: "strap-a")
        let secondLedger = try fixture.ledger()
        let current = try secondLedger.beginAttempt(strapIdentifier: "strap-a")
        XCTAssertEqual(current.identifier, stale.identifier)

        XCTAssertThrowsError(
            try firstLedger.classify(frame: Data([0x01]), attempt: stale)
        ) { error in
            XCTAssertEqual(error as? AtriaWhoop4HistoryAdmissionLedger.LedgerError,
                           .staleAttempt)
        }
        XCTAssertEqual(try secondLedger.classify(frame: Data([0x01]), attempt: current),
                       .firstSeen(ordinal: 0))
    }

    func testCompetingConnectionsClassifyOneExactFirstWriter() throws {
        let fixture = try Fixture()
        let firstLedger = try fixture.ledger()
        let secondLedger = try fixture.ledger()
        let attempt = try firstLedger.beginAttempt(strapIdentifier: "strap-race")
        let frame = Data([0x2f, 0x18, 0, 0x44, 0x00, 0xaa, 0xbb])
        let resultLock = NSLock()
        var results: [AtriaWhoop4HistoryAdmissionLedger.Classification] = []
        var errors: [Error] = []
        let group = DispatchGroup()
        for ledger in [firstLedger, secondLedger] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try ledger.classify(frame: frame, attempt: attempt)
                    resultLock.lock()
                    results.append(result)
                    resultLock.unlock()
                } catch {
                    resultLock.lock()
                    errors.append(error)
                    resultLock.unlock()
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(results.filter { $0 == .firstSeen(ordinal: 0) }.count, 1)
        XCTAssertEqual(
            results.filter { $0 == .duplicateInCurrentIncarnation(ordinal: 0) }.count,
            1,
            "the exact primary key must give one persistence owner under a writer race"
        )
    }

    func testCompletedAttemptDoesNotResumeButExactRowsRemainAuthoritative() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let first = try ledger.beginAttempt(strapIdentifier: "strap-a")
        let frame = Data([0x2f, 0x18, 0, 9, 0])
        _ = try ledger.classify(frame: frame, attempt: first)
        _ = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: first,
            through: 0,
            archiveReceipt: fixture.archiveReceipt(recordCount: 1)
        )
        try ledger.finish(first, succeeded: true)

        let next = try ledger.beginAttempt(strapIdentifier: "strap-a")
        XCTAssertNotEqual(next.identifier, first.identifier)
        XCTAssertEqual(try ledger.classify(frame: frame, attempt: next),
                       .durableReplay(ordinal: 0),
                       "repeated full-flash drains remain exact across attempts")
    }

    func testRetentionNeverPrunesActiveOrUndurableRowsAndReplayIsRePersisted() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let old = Date(timeIntervalSince1970: 100)

        let active = try ledger.beginAttempt(strapIdentifier: "strap-active", now: old)
        _ = try ledger.classify(frame: Data([0xa1]), attempt: active, now: old)
        _ = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: active,
            through: 0,
            archiveReceipt: fixture.archiveReceipt(recordCount: 1),
            now: old
        )

        let undurable = try ledger.beginAttempt(strapIdentifier: "strap-undurable", now: old)
        _ = try ledger.classify(frame: Data([0xb1]), attempt: undurable, now: old)
        try ledger.finish(undurable, succeeded: false, now: old)

        let durable = try ledger.beginAttempt(strapIdentifier: "strap-durable", now: old)
        _ = try ledger.classify(frame: Data([0xc1]), attempt: durable, now: old)
        _ = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: durable,
            through: 0,
            archiveReceipt: fixture.archiveReceipt(recordCount: 1),
            now: old
        )
        try ledger.finish(durable, succeeded: true, now: old)

        let pruned = try ledger.prune(
            now: Date(timeIntervalSince1970: 1_000),
            identityRetention: 10,
            maximumRows: 100
        )
        XCTAssertEqual(pruned.removedForAge, 1)
        XCTAssertEqual(pruned.remainingRows, 2)
        XCTAssertEqual(pruned.protectedRowsAboveLimit, 0)

        let replay = try ledger.beginAttempt(strapIdentifier: "strap-durable")
        XCTAssertEqual(try ledger.classify(frame: Data([0xc1]), attempt: replay),
                       .firstSeen(ordinal: 0),
                       "an expired identity must re-enter persistence, never be silently dropped")
    }

    func testRetentionEnforcesCountBoundUsingOldestEligibleRows() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-count")
        for value in 0..<5 {
            _ = try ledger.classify(
                frame: Data([UInt8(value)]),
                attempt: attempt,
                now: Date(timeIntervalSince1970: TimeInterval(value + 1))
            )
        }
        _ = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: attempt,
            through: 4,
            archiveReceipt: fixture.archiveReceipt(recordCount: 5)
        )
        try ledger.finish(attempt, succeeded: true)

        let result = try ledger.prune(
            now: Date(),
            identityRetention: .greatestFiniteMagnitude,
            maximumRows: 2
        )
        XCTAssertEqual(result.removedForAge, 0)
        XCTAssertEqual(result.removedForCount, 3)
        XCTAssertEqual(result.remainingRows, 2)
        XCTAssertEqual(result.protectedRowsAboveLimit, 0)
    }

    func testRetentionPreservesCompletedAttemptOwnedByUnresolvedTerminalAuthority() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let old = Date(timeIntervalSince1970: 100)
        let protected = try ledger.beginAttempt(
            strapIdentifier: "strap-terminal",
            now: old
        )
        for value in 0..<3 {
            _ = try ledger.classify(
                frame: Data([UInt8(value)]),
                attempt: protected,
                now: old
            )
        }
        let durable = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: protected,
            through: 2,
            archiveReceipt: fixture.archiveReceipt(recordCount: 3),
            now: old
        )
        try ledger.finish(protected, succeeded: true, now: old)

        let result = try ledger.prune(
            now: Date(timeIntervalSince1970: 1_000),
            identityRetention: 10,
            maximumRows: 1,
            protectedAttemptIdentifiers: [protected.identifier]
        )

        XCTAssertEqual(result.deletedRows, 0)
        XCTAssertEqual(result.remainingRows, 3)
        XCTAssertEqual(result.deferredEligibleRowsAboveLimit, 0)
        XCTAssertEqual(result.protectedRowsAboveLimit, 2)
        var enumerated: [Data] = []
        let report = try ledger.enumerateDurableFrames(
            attemptIdentifier: protected.identifier,
            strapIdentifier: protected.strapIdentifier,
            throughReceipt: durable.receipt
        ) { _, frame in
            enumerated.append(frame)
        }
        XCTAssertEqual(report.recordCount, 3)
        XCTAssertEqual(enumerated, [Data([0]), Data([1]), Data([2])])
    }

    func testRetentionDefersEligibleRowsAcrossBoundedMaintenancePasses() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-bounded-prune")
        for value in 0..<5 {
            _ = try ledger.classify(
                frame: Data([UInt8(value)]),
                attempt: attempt,
                now: Date(timeIntervalSince1970: TimeInterval(value + 1))
            )
        }
        _ = try ledger.markCurrentPrefixArchiveDurableWithReceipt(
            attempt: attempt,
            through: 4,
            archiveReceipt: fixture.archiveReceipt(recordCount: 5)
        )
        try ledger.finish(attempt, succeeded: true)

        let first = try ledger.prune(
            now: Date(),
            identityRetention: .greatestFiniteMagnitude,
            maximumRows: 2,
            maximumDeletesPerPass: 2
        )
        XCTAssertEqual(first.removedForCount, 2)
        XCTAssertEqual(first.remainingRows, 3)
        XCTAssertEqual(first.deferredEligibleRowsAboveLimit, 1)
        XCTAssertEqual(first.protectedRowsAboveLimit, 0,
                       "eligible durable rows are deferred, not mislabeled as protected")

        let second = try ledger.prune(
            now: Date(),
            identityRetention: .greatestFiniteMagnitude,
            maximumRows: 2,
            maximumDeletesPerPass: 2
        )
        XCTAssertEqual(second.removedForCount, 1)
        XCTAssertEqual(second.remainingRows, 2)
        XCTAssertEqual(second.deferredEligibleRowsAboveLimit, 0)
    }

    func testManagerContinuesBoundedMaintenanceForDeferredEligibleRows() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testsURL.deletingLastPathComponent().deletingLastPathComponent()
        let managerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Atria/AtriaBLEManager.swift"),
            encoding: .utf8
        )
        let methodStart = try XCTUnwrap(managerSource.range(of:
            "private func scheduleHistoricalAdmissionLedgerMaintenance(reason: String)"
        ))
        let methodEnd = try XCTUnwrap(managerSource.range(of:
            "private func finalizeFullDrainTerminalAuthority(",
            range: methodStart.lowerBound..<managerSource.endIndex
        ))
        let method = String(managerSource[methodStart.lowerBound..<methodEnd.lowerBound])

        XCTAssertTrue(method.contains("prune.deferredEligibleRowsAboveLimit > 0"))
        XCTAssertTrue(method.contains("reason: \"\\(reason)_continued\""),
                      "a bounded prune must schedule its next safe pass instead of waiting for lifecycle")
        XCTAssertTrue(method.contains(
            "protectedAttemptIdentifiers: protectedAttemptIdentifiers"
        ), "maintenance must preserve a completed prefix while terminal publication owns it")
    }

    func testRetentionReportsProtectedPressureInsteadOfDeletingUnsafeRows() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-protected")
        for value in 0..<3 {
            _ = try ledger.classify(frame: Data([UInt8(value)]), attempt: attempt)
        }
        let result = try ledger.prune(identityRetention: 0, maximumRows: 1)
        XCTAssertEqual(result.removedForAge, 0)
        XCTAssertEqual(result.removedForCount, 0)
        XCTAssertEqual(result.remainingRows, 3)
        XCTAssertEqual(result.protectedRowsAboveLimit, 2,
                       "storage pressure must fail closed rather than erase active raw authority")
    }

    func testLedgerScalesPastFormerReducerCapWithoutResidentIdentitySet() throws {
        let fixture = try Fixture()
        let ledger = try fixture.ledger()
        let attempt = try ledger.beginAttempt(strapIdentifier: "strap-large")
        let formerCap = 262_144
        for value in 0...formerCap {
            var littleEndian = UInt32(value).littleEndian
            let frame = withUnsafeBytes(of: &littleEndian) { Data($0) }
            let result = try ledger.classify(frame: frame, attempt: attempt)
            if value == formerCap {
                XCTAssertEqual(result, .firstSeen(ordinal: UInt64(value)))
            }
        }
        XCTAssertEqual(try ledger.countsForDiagnostics().frames, formerCap + 1)
    }

    func testReducerRehydratesDurablePrefixWithoutAllowingLaterReplayToRewind() {
        var reducer = AtriaWhoop4HistoryDrainState()
        _ = reducer.begin(generation: 90)
        let sequence10: [UInt8] = [0x2f, 0, 0, 10, 0]
        let sequence11: [UInt8] = [0x2f, 0, 0, 11, 0]
        let sequence12: [UInt8] = [0x2f, 0, 0, 12, 0]

        XCTAssertTrue(reducer.receiveFrame(
            generation: 90, frameKey: "ten", payload: sequence10,
            admission: .durableReplay
        ).isEmpty)
        XCTAssertTrue(reducer.receiveFrame(
            generation: 90, frameKey: "eleven", payload: sequence11,
            admission: .durableReplay
        ).isEmpty)
        XCTAssertEqual(reducer.receiveFrame(
            generation: 90, frameKey: "twelve", payload: sequence12,
            admission: .firstSeen
        ), [.persistFrame(generation: 90, frameKey: "twelve", payload: sequence12)])
        XCTAssertTrue(reducer.receiveFrame(
            generation: 90, frameKey: "ten", payload: sequence10,
            admission: .durableReplay
        ).isEmpty)
        XCTAssertEqual(reducer.sequenceRestartCount, 0,
                       "a durable replay after the new suffix starts cannot rewind the cursor")
    }

    private final class Fixture {
        let directory: URL
        let databaseURL: URL
        private let archiveURL: URL
        private let archiveStore: AtriaHistoricalArchiveDurableStore
        private var nextArchiveCounter: UInt32 = 1

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("atria-history-admission-\(UUID().uuidString)",
                                        isDirectory: true)
            databaseURL = directory.appendingPathComponent("admission.sqlite")
            archiveURL = directory.appendingPathComponent("historical.jsonl")
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            archiveStore = try AtriaHistoricalArchiveDurableStore(
                indexURL: directory.appendingPathComponent("historical.index.jsonl"),
                existingArchiveURLs: []
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        func ledger(
            durable: Bool = false,
            durabilityNow: @escaping () -> Date = Date.init,
            retiredReplayLookup: @escaping AtriaWhoop4HistoryAdmissionLedger
                .RetiredReplayLookup = { _, _ in false }
        ) throws -> AtriaWhoop4HistoryAdmissionLedger {
            try AtriaWhoop4HistoryAdmissionLedger(
                databaseURL: databaseURL,
                unsafeDisableDurabilityForTests: !durable,
                durabilityNow: durabilityNow,
                retiredReplayLookup: retiredReplayLookup
            )
        }

        func archiveReceipt(
            recordCount: Int
        ) throws -> AtriaHistoricalArchiveDurableStore.FlushReceipt {
            let batch = archiveStore.beginDrainBatch()
            for _ in 0..<recordCount {
                let counter = nextArchiveCounter
                nextArchiveCounter += 1
                var payloadCounter = counter.littleEndian
                let payload = withUnsafeBytes(of: &payloadCounter) { Data($0) }
                let identity = AtriaHistoricalArchiveDurableStore.FrameIdentity(
                    strapIdentifier: "receipt-fixture",
                    protocolVersion: 24,
                    counter: counter,
                    unixSeconds: 1_800_000_000 + counter,
                    subsecond: 0,
                    payload: payload
                )
                let record = try JSONSerialization.data(withJSONObject: [
                    "schema": 3,
                    "sequence": Int(counter),
                    "rawPayloadHex": payload.map { String(format: "%02x", $0) }.joined()
                ], options: [.sortedKeys])
                _ = try archiveStore.append(identity: identity,
                                            encodedJSONObject: record,
                                            to: archiveURL,
                                            batch: batch)
            }
            return try archiveStore.flush(batch)
        }

        /// Seeds a large, already-durable prefix in one SQLite statement so
        /// the streaming-capacity test measures enumeration rather than
        /// spending minutes issuing hundreds of thousands of Swift inserts.
        func seedDurableEnumerationPrefix(
            attempt: AtriaWhoop4HistoryAdmissionLedger.Attempt,
            recordCount: Int,
            rawDigest: String,
            identityDigest: String,
            prefixDigest: String,
            chainDigest: String
        ) throws {
            enum SeedError: Error { case open(Int32); case execute(String) }
            var database: OpaquePointer?
            let openCode = sqlite3_open_v2(
                databaseURL.path,
                &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard openCode == SQLITE_OK, let database else {
                if let database { sqlite3_close_v2(database) }
                throw SeedError.open(openCode)
            }
            defer { sqlite3_close_v2(database) }
            func execute(_ sql: String) throws {
                var message: UnsafeMutablePointer<CChar>?
                let code = sqlite3_exec(database, sql, nil, nil, &message)
                guard code == SQLITE_OK else {
                    let detail = message.map { String(cString: $0) } ?? "sqlite_\(code)"
                    sqlite3_free(message)
                    throw SeedError.execute(detail)
                }
            }
            let lastOrdinal = recordCount - 1
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("""
                    WITH RECURSIVE sequence(value) AS (
                        VALUES(0)
                        UNION ALL
                        SELECT value + 1 FROM sequence WHERE value < \(lastOrdinal)
                    )
                    INSERT INTO history_frame
                    (strap_id, frame, first_attempt_id, first_ordinal,
                     last_attempt_id, last_incarnation, last_ordinal,
                     archive_durable, last_seen_unix)
                    SELECT '\(attempt.strapIdentifier)',
                           CAST(printf('%08x', value) AS BLOB),
                           '\(attempt.identifier)', value,
                           '\(attempt.identifier)', '\(attempt.incarnation)', value,
                           1, 2000000000.0
                    FROM sequence
                    """)
                try execute("""
                    UPDATE history_attempt
                    SET next_ordinal = \(recordCount), durable_ordinal = \(lastOrdinal)
                    WHERE id = '\(attempt.identifier)'
                    """)
                try execute("""
                    INSERT INTO history_archive_receipt
                    (chain_digest, attempt_id, durable_sequence, promoted_ordinal,
                     raw_digest, identity_digest, prefix_digest, record_count,
                     byte_count, created_unix)
                    VALUES ('\(chainDigest)', '\(attempt.identifier)', 1, \(lastOrdinal),
                            '\(rawDigest)', '\(identityDigest)', '\(prefixDigest)',
                            \(recordCount), \(recordCount * 8), 2000000000.0)
                    """)
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }
}
