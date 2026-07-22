import XCTest
@testable import Atria

final class AtriaHistoricalReplayIdentityShardTests: XCTestCase {
    private var roots: [URL] = []
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testExactIdentityShardSurvivesRawIndependentDecode() throws {
        let fixture = try makeFixture(frameCount: 3)
        let shard = try AtriaHistoricalReplayIdentityShard.build(sourceURL: fixture.archive,
                                                                  source: fixture.source)
        let artifact = try shard.encodedArtifact()
        let decoded = try JSONDecoder().decode(AtriaHistoricalReplayIdentityShard.self,
                                               from: artifact)

        XCTAssertEqual(decoded, shard)
        XCTAssertEqual(decoded.entries.count, 3)
        XCTAssertTrue(decoded.contains(stableKey: fixture.identities[1].stableKey))
        XCTAssertFalse(decoded.contains(stableKey: fixture.identities[1].stableKey + "00"))
    }

    func testReplayIdentityShardRebuildsIdenticallyFromCompressedArtifact() throws {
        let fixture = try makeFixture(frameCount: 4)
        // The durable identity shard built from the plaintext sealed source.
        let plaintextShard = try AtriaHistoricalReplayIdentityShard.build(
            sourceURL: fixture.archive, source: fixture.source
        )

        // Substitute the sealed source's storage with a DEFLATE artifact.
        let root = fixture.archive.deletingLastPathComponent()
        let compressed = try AtriaHistoricalSealedJSONLCompression().commit(
            chunkID: "replay-compressed",
            sourceURL: fixture.archive,
            archiveRootURL: root,
            activeSourceURL: root.appendingPathComponent("active.jsonl"),
            chunkSize: 64
        )
        XCTAssertEqual(compressed.artifactURL.pathExtension,
                       AtriaHistoricalSealedJSONLCompression.artifactExtension)

        // Rebuilding from the artifact — using the same decoded-identity source —
        // must reconstruct a byte-for-byte identical shard. The durable replay
        // index is therefore independent of whether the shard is stored plaintext
        // or compressed: transparent decode yields the same exact identities.
        let compressedShard = try AtriaHistoricalReplayIdentityShard.build(
            sourceURL: compressed.artifactURL, source: fixture.source
        )
        XCTAssertEqual(compressedShard, plaintextShard)
        XCTAssertEqual(compressedShard.entries.count, 4)
        XCTAssertTrue(compressedShard.contains(stableKey: fixture.identities[2].stableKey))
    }

    func testRetiredIndexMatchesCompleteIdentityNotPayloadAlone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalRetiredReplayIndexTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        roots.append(root)
        let payload = Data([0x2f, 0x18, 0x01, 0x02, 0x03])
        let exact = AtriaHistoricalArchiveDurableStore.FrameIdentity(
            strapIdentifier: "strap-a",
            protocolVersion: 24,
            counter: 100,
            unixSeconds: 2_000_000_000,
            subsecond: 50,
            payload: payload
        )
        let differentCounterAndTime = AtriaHistoricalArchiveDurableStore.FrameIdentity(
            strapIdentifier: "strap-a",
            protocolVersion: 24,
            counter: 101,
            unixSeconds: 2_000_000_001,
            subsecond: 51,
            payload: payload
        )
        let source = AtriaHistoricalAggregateChunk.Source(
            chunkID: "chunk-exact-identity",
            rawSHA256: String(repeating: "a", count: 64),
            rawByteCount: 4_096,
            rawRowCount: 1,
            firstTimestamp: now,
            lastTimestamp: now,
            decoderSchema: HistoricalArchive.schema,
            validatedLayouts: [HistoricalArchive.layoutVersion]
        )
        let shard = AtriaHistoricalReplayIdentityShard(
            schema: AtriaHistoricalReplayIdentityShard.currentSchema,
            source: .init(chunkID: source.chunkID,
                          rawSHA256: source.rawSHA256,
                          rawRowCount: 1),
            entries: [.init(stableKey: exact.stableKey,
                            observedAtUnix: now.timeIntervalSince1970)]
        )
        let index = try AtriaHistoricalRetiredReplayIndex(
            databaseURL: root.appendingPathComponent("retired.sqlite"),
            unsafeDisableDurabilityForTests: true
        )

        do {
            _ = try index.importAndVerify(shard: shard, source: source)
        } catch {
            XCTFail("exact index import failed: \(String(reflecting: error))")
            return
        }

        XCTAssertTrue(try index.contains(stableKey: exact.stableKey))
        XCTAssertFalse(try index.contains(stableKey: differentCounterAndTime.stableKey))
        XCTAssertNotEqual(exact.stableKey, differentCounterAndTime.stableKey)
    }

    func testRetiredIndexPrunesOnlyWhenNoUnexpiredMembershipRemains() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalRetiredReplayIndexPruneTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        roots.append(root)
        let index = try AtriaHistoricalRetiredReplayIndex(
            databaseURL: root.appendingPathComponent("retired.sqlite"),
            unsafeDisableDurabilityForTests: true
        )
        let old = now.addingTimeInterval(-20 * 24 * 60 * 60)
        let recent = now.addingTimeInterval(-2 * 24 * 60 * 60)
        let shared = AtriaHistoricalArchiveDurableStore.FrameIdentity(
            strapIdentifier: "strap-prune", protocolVersion: 24,
            counter: 1, unixSeconds: 1_800_000_000, subsecond: 0,
            payload: Data([0x2f, 0x18, 1])
        )
        let expiredOnly = AtriaHistoricalArchiveDurableStore.FrameIdentity(
            strapIdentifier: "strap-prune", protocolVersion: 24,
            counter: 2, unixSeconds: 1_800_000_001, subsecond: 0,
            payload: Data([0x2f, 0x18, 2])
        )
        func source(_ id: String, digest: Character, rows: Int) ->
            AtriaHistoricalAggregateChunk.Source {
            .init(chunkID: id,
                  rawSHA256: String(repeating: String(digest), count: 64),
                  rawByteCount: 8_192,
                  rawRowCount: rows,
                  firstTimestamp: old,
                  lastTimestamp: recent,
                  decoderSchema: HistoricalArchive.schema,
                  validatedLayouts: [HistoricalArchive.layoutVersion])
        }
        func shard(_ source: AtriaHistoricalAggregateChunk.Source,
                   _ entries: [AtriaHistoricalReplayIdentityShard.Entry]) ->
            AtriaHistoricalReplayIdentityShard {
            .init(schema: AtriaHistoricalReplayIdentityShard.currentSchema,
                  source: .init(chunkID: source.chunkID,
                                rawSHA256: source.rawSHA256,
                                rawRowCount: source.rawRowCount),
                  entries: entries.sorted { $0.stableKey < $1.stableKey })
        }
        let firstSource = source("retired-old", digest: "a", rows: 2)
        let firstShard = shard(firstSource, [
            .init(stableKey: shared.stableKey,
                  observedAtUnix: old.timeIntervalSince1970),
            .init(stableKey: expiredOnly.stableKey,
                  observedAtUnix: old.timeIntervalSince1970),
        ])
        let secondSource = source("retired-recent", digest: "b", rows: 1)
        let secondShard = shard(secondSource, [
            .init(stableKey: shared.stableKey,
                  observedAtUnix: recent.timeIntervalSince1970),
        ])
        let firstReceipt: AtriaHistoricalRetiredReplayIndex.ImportReceipt
        let secondReceipt: AtriaHistoricalRetiredReplayIndex.ImportReceipt
        do {
            firstReceipt = try index.importAndVerify(shard: firstShard,
                                                     source: firstSource,
                                                     importedAt: old)
            secondReceipt = try index.importAndVerify(shard: secondShard,
                                                      source: secondSource,
                                                      importedAt: recent)
        } catch {
            XCTFail("prune fixture import failed: \(String(reflecting: error))")
            return
        }
        try index.markCatalogRetired(receipt: firstReceipt, retiredAt: old)
        try index.markCatalogRetired(receipt: secondReceipt, retiredAt: recent)

        let result = try index.pruneExpired(
            observedBefore: now.addingTimeInterval(-14 * 24 * 60 * 60)
        )

        XCTAssertEqual(result.removedSourceMemberships, 2)
        XCTAssertEqual(result.removedExactIdentities, 1)
        XCTAssertEqual(result.remainingExactIdentities, 1)
        XCTAssertTrue(try index.contains(stableKey: shared.stableKey))
        XCTAssertFalse(try index.contains(stableKey: expiredOnly.stableKey))
    }

    func testMaintenanceKeepsBoundedSourceTombstoneAndBlocksSameSourceReimport() throws {
        let root = try makeRoot(named: "AtriaHistoricalReplayMaintenanceTests")
        let database = root.appendingPathComponent("retired.sqlite")
        let old = now.addingTimeInterval(-20 * 86_400)
        let identity = AtriaHistoricalArchiveDurableStore.FrameIdentity(
            strapIdentifier: "strap-maintenance", protocolVersion: 24,
            counter: 7, unixSeconds: 1_800_000_007, subsecond: 0,
            payload: Data([0x2f, 0x18, 7])
        )
        let source = replaySource(id: "bounded-tombstone", digest: "c", date: old)
        let shard = replayShard(source: source, identity: identity, observedAt: old)
        var index: AtriaHistoricalRetiredReplayIndex? = try .init(
            databaseURL: database, unsafeDisableDurabilityForTests: true
        )
        let receipt = try index!.importAndVerify(shard: shard, source: source, importedAt: old)
        try index!.markCatalogRetired(receipt: receipt, retiredAt: old)

        let result = try index!.maintainStorage(
            identityCutoff: now.addingTimeInterval(-14 * 86_400),
            sourceTombstoneCutoff: now.addingTimeInterval(-90 * 86_400)
        )

        XCTAssertEqual(result.remainingExactIdentities, 0)
        XCTAssertEqual(result.remainingSourceTombstones, 1)
        XCTAssertFalse(try index!.contains(stableKey: identity.stableKey))
        XCTAssertThrowsError(try index!.importAndVerify(shard: shard, source: source)) {
            XCTAssertEqual($0 as? AtriaHistoricalRetiredReplayIndex.IndexError,
                           .importVerificationFailed)
        }
        index = nil
        XCTAssertLessThanOrEqual(fileBytes(database), result.bytesBefore)
    }

    func testMaintenanceRestartAfterCommittedPruneIsIdempotentAndReclaimsPages() throws {
        enum Injected: Error { case crash }
        let root = try makeRoot(named: "AtriaHistoricalReplayMaintenanceRestartTests")
        let database = root.appendingPathComponent("retired.sqlite")
        let old = now.addingTimeInterval(-120 * 86_400)
        let source = replaySource(id: "restart-old", digest: "d", date: old)
        let identity = AtriaHistoricalArchiveDurableStore.FrameIdentity(
            strapIdentifier: "strap-restart", protocolVersion: 24,
            counter: 9, unixSeconds: 1_800_000_009, subsecond: 0,
            payload: Data(repeating: 0xab, count: 2_048)
        )
        let shard = replayShard(source: source, identity: identity, observedAt: old)
        var faulting: AtriaHistoricalRetiredReplayIndex? = try .init(
            databaseURL: database,
            unsafeDisableDurabilityForTests: true,
            maintenanceCheckpoint: { if $0 == .logicalPruneCommitted { throw Injected.crash } }
        )
        let receipt = try faulting!.importAndVerify(shard: shard, source: source, importedAt: old)
        try faulting!.markCatalogRetired(receipt: receipt, retiredAt: old)
        XCTAssertThrowsError(try faulting!.maintainStorage(
            identityCutoff: now.addingTimeInterval(-14 * 86_400),
            sourceTombstoneCutoff: now.addingTimeInterval(-90 * 86_400),
            sourceTombstoneRetirementAuthorizedChunkIDs: [source.chunkID]
        ))
        faulting = nil

        let restarted = try AtriaHistoricalRetiredReplayIndex(
            databaseURL: database, unsafeDisableDurabilityForTests: true
        )
        let completed = try restarted.maintainStorage(
            identityCutoff: now.addingTimeInterval(-14 * 86_400),
            sourceTombstoneCutoff: now.addingTimeInterval(-90 * 86_400),
            sourceTombstoneRetirementAuthorizedChunkIDs: [source.chunkID]
        )
        XCTAssertEqual(completed.remainingExactIdentities, 0)
        XCTAssertEqual(completed.remainingSourceTombstones, 0)
        XCTAssertFalse(try restarted.contains(stableKey: identity.stableKey))
        let replay = try restarted.maintainStorage(
            identityCutoff: now.addingTimeInterval(-14 * 86_400),
            sourceTombstoneCutoff: now.addingTimeInterval(-90 * 86_400)
        )
        XCTAssertEqual(replay.removedExactIdentities, 0)
        XCTAssertEqual(replay.removedSourceTombstones, 0)
        XCTAssertLessThanOrEqual(replay.bytesAfter, replay.bytesBefore)
    }

    func testSyntheticMultiYearExpiredReplayPlateausAfterVacuum() throws {
        let root = try makeRoot(named: "AtriaHistoricalReplayMultiYearTests")
        let database = root.appendingPathComponent("retired.sqlite")
        let index = try AtriaHistoricalRetiredReplayIndex(
            databaseURL: database, unsafeDisableDurabilityForTests: true
        )
        var authorizedSourceIDs = Set<String>()
        for day in stride(from: 100, through: 1_100, by: 10) {
            let date = now.addingTimeInterval(-Double(day) * 86_400)
            let source = replaySource(id: "multi-year-\(day)",
                                      digest: Character(String(format: "%x", day % 16)),
                                      date: date)
            let identity = AtriaHistoricalArchiveDurableStore.FrameIdentity(
                strapIdentifier: "strap-multi-year", protocolVersion: 24,
                counter: UInt32(day), unixSeconds: UInt32(1_700_000_000 + day),
                subsecond: 0, payload: Data(repeating: UInt8(day % 251), count: 512)
            )
            let shard = replayShard(source: source, identity: identity, observedAt: date)
            let receipt = try index.importAndVerify(shard: shard, source: source, importedAt: date)
            try index.markCatalogRetired(receipt: receipt, retiredAt: date)
            authorizedSourceIDs.insert(source.chunkID)
        }
        let result = try index.maintainStorage(
            identityCutoff: now.addingTimeInterval(-14 * 86_400),
            sourceTombstoneCutoff: now.addingTimeInterval(-90 * 86_400),
            sourceTombstoneRetirementAuthorizedChunkIDs: authorizedSourceIDs
        )
        XCTAssertEqual(result.remainingExactIdentities, 0)
        XCTAssertEqual(result.remainingSourceTombstones, 0)
        XCTAssertLessThan(result.bytesAfter, result.bytesBefore)
        XCTAssertLessThan(result.bytesAfter, 512 * 1_024,
                          "expired multi-year replay must plateau near empty schema size")
    }

    func testMissingDecoratedIdentityBlocksRetirementShard() throws {
        let fixture = try makeFixture(frameCount: 2)
        let legacy = Data("{\"legacy\":true}\n".utf8)
        let handle = try FileHandle(forWritingTo: fixture.archive)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: legacy)
        try handle.close()
        let digest = try AtriaHistoricalRetentionTransaction.sha256(of: fixture.archive)
        let source = replacingSource(fixture.source, rawSHA256: digest, rawRowCount: 3)

        XCTAssertThrowsError(
            try AtriaHistoricalReplayIdentityShard.build(sourceURL: fixture.archive, source: source)
        ) { error in
            XCTAssertEqual(error as? AtriaHistoricalReplayIdentityShard.ShardError,
                           .missingExactIdentity(row: 2))
        }
    }

    func testTamperedArtifactCannotVerifyAgainstRaw() throws {
        let fixture = try makeFixture(frameCount: 2)
        let shard = try AtriaHistoricalReplayIdentityShard.build(sourceURL: fixture.archive,
                                                                  source: fixture.source)
        var artifact = try shard.encodedArtifact()
        let key = try XCTUnwrap(shard.entries.first?.stableKey)
        let replacement = String(repeating: "0", count: key.count)
        artifact = Data(try XCTUnwrap(String(data: artifact, encoding: .utf8))
            .replacingOccurrences(of: key, with: replacement).utf8)

        XCTAssertThrowsError(try AtriaHistoricalReplayIdentityShard.decodeAndVerify(
            artifact,
            sourceURL: fixture.archive,
            source: fixture.source
        ))
    }

    func testPublishedReceiptIsVerifiedAgainstExactRawKeys() throws {
        let fixture = try makeFixture(frameCount: 2)
        let ledgerRoot = fixture.archive.deletingLastPathComponent()
            .appendingPathComponent("consumer-receipts")
        let ledger = AtriaHistoricalConsumerReceiptLedger(directoryURL: ledgerRoot)
        let published = try AtriaHistoricalReplayIdentityShard.publishReceipt(
            sourceURL: fixture.archive,
            source: fixture.source,
            ledger: ledger,
            settledAt: fixture.source.lastTimestamp
        )
        let artifact = try Data(contentsOf: published.artifactURL)

        XCTAssertTrue(try AtriaHistoricalReplayIdentityShard.verifyReceipt(
            published.receipt,
            artifact: artifact,
            sourceURL: fixture.archive,
            source: fixture.source
        ))
        XCTAssertEqual(published.receipt.recordCount, fixture.source.rawRowCount)
        XCTAssertEqual(published.receipt.outcome, .materialized)
    }

    private struct Fixture {
        let archive: URL
        let source: AtriaHistoricalAggregateChunk.Source
        let identities: [AtriaHistoricalArchiveDurableStore.FrameIdentity]
    }

    private func makeRoot(named: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(named).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func replaySource(id: String, digest: Character, date: Date)
        -> AtriaHistoricalAggregateChunk.Source {
        .init(chunkID: id,
              rawSHA256: String(repeating: String(digest), count: 64),
              rawByteCount: 8_192,
              rawRowCount: 1,
              firstTimestamp: date,
              lastTimestamp: date,
              decoderSchema: HistoricalArchive.schema,
              validatedLayouts: [HistoricalArchive.layoutVersion])
    }

    private func replayShard(source: AtriaHistoricalAggregateChunk.Source,
                             identity: AtriaHistoricalArchiveDurableStore.FrameIdentity,
                             observedAt: Date) -> AtriaHistoricalReplayIdentityShard {
        .init(schema: AtriaHistoricalReplayIdentityShard.currentSchema,
              source: .init(chunkID: source.chunkID,
                            rawSHA256: source.rawSHA256,
                            rawRowCount: 1),
              entries: [.init(stableKey: identity.stableKey,
                              observedAtUnix: observedAt.timeIntervalSince1970)])
    }

    private func fileBytes(_ url: URL) -> UInt64 {
        UInt64(max(0, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
    }

    private func makeFixture(frameCount: Int) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalReplayIdentityShardTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        let archive = root.appendingPathComponent("sealed.jsonl")
        let index = root.appendingPathComponent("identity.jsonl")
        let store = try AtriaHistoricalArchiveDurableStore(indexURL: index,
                                                           existingArchiveURLs: [],
                                                           identityRetention: .infinity,
                                                           now: { self.now })
        let batch = store.beginDrainBatch()
        let identities = (0..<frameCount).map { value in
            AtriaHistoricalArchiveDurableStore.FrameIdentity(
                strapIdentifier: "strap-1",
                protocolVersion: 24,
                counter: UInt32(value + 1),
                unixSeconds: UInt32(1_800_000_000 + value),
                subsecond: UInt16(value),
                payload: Data([UInt8(value), 0xaa, 0x55])
            )
        }
        for (index, identity) in identities.enumerated() {
            _ = try store.append(identity: identity,
                                 encodedJSONObject: Data("{\"schema\":5,\"row\":\(index)}".utf8),
                                 to: archive,
                                 batch: batch)
        }
        _ = try store.flush(batch)
        let digest = try AtriaHistoricalRetentionTransaction.sha256(of: archive)
        let source = AtriaHistoricalAggregateChunk.Source(
            chunkID: "sealed-identity-test",
            rawSHA256: digest,
            rawByteCount: UInt64((try archive.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0),
            rawRowCount: frameCount,
            firstTimestamp: now,
            lastTimestamp: now.addingTimeInterval(TimeInterval(max(1, frameCount))),
            decoderSchema: HistoricalArchive.schema,
            validatedLayouts: []
        )
        return .init(archive: archive, source: source, identities: identities)
    }

    private func replacingSource(_ source: AtriaHistoricalAggregateChunk.Source,
                                 rawSHA256: String,
                                 rawRowCount: Int) -> AtriaHistoricalAggregateChunk.Source {
        .init(chunkID: source.chunkID,
              rawSHA256: rawSHA256,
              rawByteCount: source.rawByteCount,
              rawRowCount: rawRowCount,
              firstTimestamp: source.firstTimestamp,
              lastTimestamp: source.lastTimestamp,
              decoderSchema: source.decoderSchema,
              validatedLayouts: source.validatedLayouts)
    }
}
