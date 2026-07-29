import XCTest
@testable import Atria

final class AtriaHistoricalRetentionTransactionTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)

    override func tearDownWithError() throws {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories.removeAll()
    }

    func testSuccessfulCommitPublishesVerifiedManifestBeforeDeletingRaw() throws {
        let fixture = try makeFixture()
        var checkpoints: [AtriaHistoricalRetentionTransaction.Checkpoint] = []
        let transaction = AtriaHistoricalRetentionTransaction(
            now: { self.fixedNow },
            checkpoint: { checkpoints.append($0) },
            consumerProjectionVerifier: { _ in true },
            consumerApplicationVerifier: { _ in true },
            semanticVerifier: { source, aggregate, receipt in
                XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
                XCTAssertEqual(receipt, "parity-receipt-v1")
                XCTAssertEqual(aggregate.source.rawRowCount, 1)
                return true
            }
        )

        let result = try transaction.commit(fixture.request(deleteSource: true))

        XCTAssertTrue(result.sourceDeleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.aggregateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.manifestURL.path))
        XCTAssertEqual(checkpoints, AtriaHistoricalRetentionTransaction.Checkpoint.allCases)
    }

    func testCommitVerifiesSubsecondSourceBoundsAtPersistedISO8601Precision() throws {
        let fixture = try makeFixture(timestampOffset: 0.5)
        let transaction = AtriaHistoricalRetentionTransaction(
            now: { self.fixedNow.addingTimeInterval(0.5) },
            semanticVerifier: { _, _, _ in true }
        )

        let result = try transaction.commit(fixture.request(deleteSource: false))

        XCTAssertFalse(result.sourceDeleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.aggregateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testEveryFaultBeforeDeletionLeavesRawAuthoritative() throws {
        let faultPoints = AtriaHistoricalRetentionTransaction.Checkpoint.allCases
            .filter { $0 != .sourceDeleted }
        for point in faultPoints {
            let fixture = try makeFixture()
            enum Injected: Error { case crash }
            let transaction = AtriaHistoricalRetentionTransaction(
                now: { self.fixedNow },
                checkpoint: { if $0 == point { throw Injected.crash } },
                consumerProjectionVerifier: { _ in true },
                consumerApplicationVerifier: { _ in true },
                semanticVerifier: { _, _, _ in true }
            )

            XCTAssertThrowsError(try transaction.commit(fixture.request(deleteSource: true)),
                                 "fault at \(point.rawValue) must interrupt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path),
                          "raw disappeared at pre-delete checkpoint \(point.rawValue)")
        }
    }

    func testCrashAfterAggregatePublishRetriesIdempotentlyAndThenDeletesRaw() throws {
        let fixture = try makeFixture()
        enum Injected: Error { case crash }
        let interrupted = AtriaHistoricalRetentionTransaction(
            now: { self.fixedNow },
            checkpoint: { if $0 == .aggregatePublished { throw Injected.crash } },
            consumerProjectionVerifier: { _ in true },
            consumerApplicationVerifier: { _ in true },
            semanticVerifier: { _, _, _ in true }
        )
        XCTAssertThrowsError(try interrupted.commit(fixture.request(deleteSource: true)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))

        let retry = AtriaHistoricalRetentionTransaction(
            now: { self.fixedNow },
            consumerProjectionVerifier: { _ in true },
            consumerApplicationVerifier: { _ in true },
            semanticVerifier: { _, _, _ in true }
        )
        let result = try retry.commit(fixture.request(deleteSource: true))

        XCTAssertTrue(result.sourceDeleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(try directoryFiles(fixture.aggregates, prefix: "aggregate-technical-test"), 1)
        XCTAssertEqual(try directoryFiles(fixture.manifests, prefix: "manifest-technical-test"), 1)
    }

    func testCrashAfterManifestPublishLeavesRawAndCommittedRetryCanRetireIt() throws {
        let fixture = try makeFixture()
        enum Injected: Error { case crash }
        let interrupted = AtriaHistoricalRetentionTransaction(
            now: { self.fixedNow },
            checkpoint: { if $0 == .manifestPublished { throw Injected.crash } },
            consumerProjectionVerifier: { _ in true },
            consumerApplicationVerifier: { _ in true },
            semanticVerifier: { _, _, _ in true }
        )
        XCTAssertThrowsError(try interrupted.commit(fixture.request(deleteSource: true)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))

        let retry = AtriaHistoricalRetentionTransaction(
            now: { self.fixedNow },
            consumerProjectionVerifier: { _ in true },
            consumerApplicationVerifier: { _ in true },
            semanticVerifier: { _, _, _ in XCTFail("committed retry must use the receipt"); return false }
        )
        let result = try retry.commit(fixture.request(deleteSource: true))

        XCTAssertTrue(result.reusedCommittedTransaction)
        XCTAssertTrue(result.sourceDeleted)
    }

    func testSemanticParityFailureCannotPublishManifestOrDeleteRaw() throws {
        let fixture = try makeFixture()
        let transaction = AtriaHistoricalRetentionTransaction(
            consumerProjectionVerifier: { _ in true },
            consumerApplicationVerifier: { _ in true },
            semanticVerifier: { _, _, _ in false }
        )

        XCTAssertThrowsError(try transaction.commit(fixture.request(deleteSource: true))) { error in
            XCTAssertEqual(error as? AtriaHistoricalRetentionTransaction.TransactionError,
                           .verificationFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(try directoryFiles(fixture.manifests, prefix: "manifest-"), 0)
        XCTAssertEqual(try temporaryFileCount(fixture.aggregates), 0)
        XCTAssertEqual(try temporaryFileCount(fixture.manifests), 0)
    }

    func testSourceMutationAfterAggregateConstructionFailsClosed() throws {
        let fixture = try makeFixture()
        let handle = try FileHandle(forWritingTo: fixture.source)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"late\":true}\n".utf8))
        try handle.close()
        let transaction = AtriaHistoricalRetentionTransaction(
            consumerProjectionVerifier: { _ in true },
            consumerApplicationVerifier: { _ in true },
            semanticVerifier: { _, _, _ in true }
        )

        XCTAssertThrowsError(try transaction.commit(fixture.request(deleteSource: true))) { error in
            XCTAssertEqual(error as? AtriaHistoricalRetentionTransaction.TransactionError,
                           .sourceDigestMismatch)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testUnknownRowsCannotBeAuthorizedWithoutResidualRawArtifact() throws {
        var fixture = try makeFixture()
        fixture.aggregate = aggregate(source: fixture.source,
                                      digest: fixture.aggregate.source.rawSHA256,
                                      bytes: fixture.aggregate.source.rawByteCount,
                                      decodedRows: 0,
                                      unknownRows: 1)
        let transaction = AtriaHistoricalRetentionTransaction(
            consumerProjectionVerifier: { _ in true },
            consumerApplicationVerifier: { _ in true },
            semanticVerifier: { _, _, _ in true }
        )

        XCTAssertThrowsError(try transaction.commit(fixture.request(deleteSource: true))) { error in
            XCTAssertEqual(error as? AtriaHistoricalRetentionTransaction.TransactionError,
                           .rawRetirementNotAuthorized)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testMetricAggregateWithoutEveryConsumerReceiptCannotDeleteRaw() throws {
        var fixture = try makeFixture()
        fixture.aggregate = aggregate(source: fixture.source,
                                      digest: fixture.aggregate.source.rawSHA256,
                                      bytes: fixture.aggregate.source.rawByteCount,
                                      decodedRows: 1,
                                      unknownRows: 0,
                                      includeRetirementReceipts: false)
        let transaction = AtriaHistoricalRetentionTransaction(
            semanticVerifier: { _, _, _ in true }
        )

        XCTAssertThrowsError(try transaction.commit(fixture.request(deleteSource: true))) { error in
            XCTAssertEqual(error as? AtriaHistoricalRetentionTransaction.TransactionError,
                           .rawRetirementNotAuthorized)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(try directoryFiles(fixture.manifests, prefix: "manifest-"), 0)
    }

    func testReceiptShapedValuesCannotDeleteWithoutDurableConsumerVerifier() throws {
        let fixture = try makeFixture()
        let transaction = AtriaHistoricalRetentionTransaction(
            semanticVerifier: { _, _, _ in true }
        )

        XCTAssertThrowsError(try transaction.commit(fixture.request(deleteSource: true))) { error in
            XCTAssertEqual(error as? AtriaHistoricalRetentionTransaction.TransactionError,
                           .rawRetirementNotAuthorized)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(try directoryFiles(fixture.manifests, prefix: "manifest-"), 0)
    }

    func testVerifiedProjectionReceiptsCannotDeleteBeforeEveryApplicationStoreConsumesThem() throws {
        let fixture = try makeFixture()
        var projectionChecks = 0
        var applicationChecks = 0
        let transaction = AtriaHistoricalRetentionTransaction(
            consumerProjectionVerifier: { _ in
                projectionChecks += 1
                return true
            },
            consumerApplicationVerifier: { _ in
                applicationChecks += 1
                return false
            },
            semanticVerifier: { _, _, _ in
                XCTFail("application readiness must fail before publication")
                return true
            }
        )

        XCTAssertThrowsError(try transaction.commit(fixture.request(deleteSource: true))) { error in
            XCTAssertEqual(error as? AtriaHistoricalRetentionTransaction.TransactionError,
                           .rawRetirementNotAuthorized)
        }
        XCTAssertEqual(projectionChecks, 1)
        XCTAssertEqual(applicationChecks, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(try directoryFiles(fixture.manifests, prefix: "manifest-"), 0)
    }

    func testRetainedRawShadowCommitUsesTypedProofWithoutGenericSemanticRebuild() throws {
        let fixture = try makeRetainedRawShadowFixture()
        var genericSemanticVerifierCalls = 0
        let transaction = AtriaHistoricalRetentionTransaction(
            now: { self.fixedNow },
            semanticVerifier: { _, _, _ in
                genericSemanticVerifierCalls += 1
                return false
            }
        )

        let result = try transaction.commitRetainedRawShadow(fixture.request)

        XCTAssertEqual(genericSemanticVerifierCalls, 0)
        XCTAssertFalse(result.sourceDeleted)
        XCTAssertFalse(result.reusedCommittedTransaction)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.aggregateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.manifestURL.path))
    }

    func testRetainedRawShadowRejectsMutationAfterProofWithoutPublishing() throws {
        let fixture = try makeRetainedRawShadowFixture()
        let handle = try FileHandle(forWritingTo: fixture.source)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: try encodedRecord(unix: 1_800_000_001))
        try handle.close()

        XCTAssertThrowsError(
            try AtriaHistoricalRetentionTransaction(
                semanticVerifier: { _, _, _ in true }
            ).commitRetainedRawShadow(fixture.request)
        ) { error in
            XCTAssertEqual(
                error as? AtriaHistoricalRetentionTransaction.TransactionError,
                .sourceDigestMismatch
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(try directoryFiles(fixture.manifests, prefix: "manifest-"), 0)
    }

    func testRetainedRawShadowRejectsMutationAfterTemporaryVerification() throws {
        let fixture = try makeRetainedRawShadowFixture()
        var mutated = false
        let transaction = AtriaHistoricalRetentionTransaction(
            checkpoint: { checkpoint in
                guard checkpoint == .temporaryArtifactsVerified, !mutated else {
                    return
                }
                mutated = true
                let handle = try FileHandle(forWritingTo: fixture.source)
                _ = try handle.seekToEnd()
                try handle.write(
                    contentsOf: try self.encodedRecord(unix: 1_800_000_001)
                )
                try handle.close()
            },
            semanticVerifier: { _, _, _ in true }
        )

        XCTAssertThrowsError(
            try transaction.commitRetainedRawShadow(fixture.request)
        ) { error in
            XCTAssertEqual(
                error as? AtriaHistoricalRetentionTransaction.TransactionError,
                .sourceDigestMismatch
            )
        }
        XCTAssertTrue(mutated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(try directoryFiles(fixture.manifests, prefix: "manifest-"), 0)
        XCTAssertEqual(try temporaryFileCount(fixture.aggregates), 0)
        XCTAssertEqual(try temporaryFileCount(fixture.manifests), 0)
    }

    func testRetainedRawShadowCrashRetriesRemainIdempotentAndKeepRaw() throws {
        let faultPoints: [AtriaHistoricalRetentionTransaction.Checkpoint] = [
            .aggregateTemporaryDurable,
            .manifestTemporaryDurable,
            .temporaryArtifactsVerified,
            .aggregatePublished,
            .manifestPublished,
        ]
        enum Injected: Error { case crash }

        for point in faultPoints {
            let fixture = try makeRetainedRawShadowFixture()
            let interrupted = AtriaHistoricalRetentionTransaction(
                checkpoint: {
                    if $0 == point { throw Injected.crash }
                },
                semanticVerifier: { _, _, _ in true }
            )
            XCTAssertThrowsError(
                try interrupted.commitRetainedRawShadow(fixture.request)
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fixture.source.path),
                "raw missing after \(point.rawValue)"
            )

            let result = try AtriaHistoricalRetentionTransaction(
                semanticVerifier: { _, _, _ in
                    XCTFail("typed shadow retry must not call generic verifier")
                    return false
                }
            ).commitRetainedRawShadow(fixture.request)

            XCTAssertFalse(result.sourceDeleted)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
            XCTAssertEqual(
                try directoryFiles(
                    fixture.aggregates,
                    prefix: "aggregate-retained-shadow-test"
                ),
                1
            )
            XCTAssertEqual(
                try directoryFiles(
                    fixture.manifests,
                    prefix: "manifest-retained-shadow-test"
                ),
                1
            )
        }
    }

    func testRetainedRawShadowCommittedArtifactCorruptionFailsClosed() throws {
        let fixture = try makeRetainedRawShadowFixture()
        let transaction = AtriaHistoricalRetentionTransaction(
            semanticVerifier: { _, _, _ in true }
        )
        let committed = try transaction.commitRetainedRawShadow(fixture.request)
        try Data("{\"corrupt\":true}\n".utf8).write(
            to: committed.aggregateURL,
            options: .atomic
        )

        XCTAssertThrowsError(
            try transaction.commitRetainedRawShadow(fixture.request)
        ) { error in
            XCTAssertEqual(
                error as? AtriaHistoricalRetentionTransaction.TransactionError,
                .manifestConflict
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    private struct Fixture {
        let source: URL
        let aggregates: URL
        let manifests: URL
        var aggregate: AtriaHistoricalAggregateChunk

        func request(deleteSource: Bool) -> AtriaHistoricalRetentionTransaction.Request {
            .init(transactionID: "technical-test",
                  sourceURL: source,
                  aggregateDirectoryURL: aggregates,
                  manifestDirectoryURL: manifests,
                  aggregate: aggregate,
                  semanticParityReceipt: "parity-receipt-v1",
                  deleteSourceAfterCommit: deleteSource)
        }
    }

    private struct RetainedRawShadowFixture {
        let source: URL
        let aggregates: URL
        let manifests: URL
        let proof: AtriaHistoricalAggregateBuilder.RetainedRawShadowProof

        var request: AtriaHistoricalRetentionTransaction.RetainedRawShadowRequest {
            .init(
                transactionID: "retained-shadow-test",
                sourceURL: source,
                aggregateDirectoryURL: aggregates,
                manifestDirectoryURL: manifests,
                proof: proof
            )
        }
    }

    private func makeFixture(timestampOffset: TimeInterval = 0) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalRetentionTransactionTests")
            .appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("sealed.jsonl")
        let aggregates = root.appendingPathComponent("aggregates")
        let manifests = root.appendingPathComponent("manifests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let raw = Data("{\"row\":1}\n".utf8)
        try raw.write(to: source)
        temporaryDirectories.append(root)
        let digest = AtriaHistoricalRetentionTransaction.sha256(of: raw)
        return Fixture(source: source,
                       aggregates: aggregates,
                       manifests: manifests,
                       aggregate: aggregate(source: source,
                                            digest: digest,
                                            bytes: UInt64(raw.count),
                                            decodedRows: 1,
                                            unknownRows: 0,
                                            timestampOffset: timestampOffset))
    }

    private func makeRetainedRawShadowFixture() throws
        -> RetainedRawShadowFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AtriaHistoricalRetentionTransactionShadowTests"
            )
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(root)
        let source = root.appendingPathComponent("sealed.jsonl")
        try encodedRecord(unix: 1_800_000_000).write(to: source)
        let proof = try AtriaHistoricalAggregateBuilder
            .buildRetainedRawShadowProof(
                sourceURL: source,
                chunkID: "sealed-shadow-test",
                createdAt: fixedNow
            )
        return .init(
            source: source,
            aggregates: root.appendingPathComponent("aggregates"),
            manifests: root.appendingPathComponent("manifests"),
            proof: proof
        )
    }

    private func encodedRecord(unix: UInt32) throws -> Data {
        let record = HistoricalArchive.Record(
            schema: HistoricalArchive.schema,
            capturedAt: Date(timeIntervalSince1970: TimeInterval(unix)),
            source: "0x2f",
            layoutVersion: HistoricalArchive.layoutVersion,
            sequence: 24,
            command: 0x2f,
            unix7: unix,
            subsec11: 0,
            flash13: unix,
            payloadLength: 1,
            whoofHR17: 70,
            whoofRRNum18: 0,
            whoofRR19: [],
            kRR64: [],
            gravityX36: 0,
            gravityY40: 0,
            gravityZ44: 1,
            gravityMagnitude: 1,
            gravityValidated: true,
            candidateRR: [],
            rawPayloadHex: "00",
            clockDeviceRef: 1,
            clockWallRef: 1,
            clockDriftSeconds: 0,
            clockCorrectedUnix7: unix,
            clockCorrectionStatus: "clock_ref_present",
            currentSessionUsable: true,
            metricUsable: true,
            usabilityReason: "test"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(record)
        data.append(0x0a)
        return data
    }

    private func aggregate(source: URL,
                           digest: String,
                           bytes: UInt64,
                           decodedRows: Int,
                           unknownRows: Int,
                           includeRetirementReceipts: Bool = true,
                           timestampOffset: TimeInterval = 0) -> AtriaHistoricalAggregateChunk {
        let end = fixedNow.addingTimeInterval(timestampOffset)
        let start = end.addingTimeInterval(-3_600)
        let receipts: [AtriaHistoricalAggregateChunk.MaterializedProjection] =
            includeRetirementReceipts
            ? AtriaHistoricalAggregateChunk.rawRetirementRequiredProjectionKinds
                .sorted { $0.rawValue < $1.rawValue }
                .map { kind in
                    .init(kind: kind,
                          identifier: "consumer-receipt-\(kind.rawValue)",
                          start: start,
                          end: end,
                          schemaVersion: 1,
                          contentSHA256: String(repeating: "a", count: 64),
                          settledAt: end)
                }
            : []
        return AtriaHistoricalAggregateChunk(
            schema: AtriaHistoricalAggregateChunk.currentSchema,
            createdAt: end,
            source: .init(chunkID: "sealed-test",
                          rawSHA256: digest,
                          rawByteCount: bytes,
                          rawRowCount: 1,
                          firstTimestamp: start,
                          lastTimestamp: end,
                          decoderSchema: HistoricalArchive.schema,
                          validatedLayouts: Array(HistoricalArchive.validatedMetricLayoutVersions).sorted()),
            heartRateMinutes: [],
            rrEpochs: [],
            motionEpochs: [],
            materializedProjections: receipts,
            parity: .init(rawRows: 1,
                          decodedRows: decodedRows,
                          undecodableRowsRetainedRaw: unknownRows,
                          metricUsableRows: 0,
                          heartRateSamples: 0,
                          heartRateSumBPM: 0,
                          acceptedRRBeats: 0,
                          acceptedRRSumMilliseconds: 0,
                          validatedGravityRows: 0,
                          motionEpochs: 0,
                          projectionReceipts: receipts.count))
    }

    private func directoryFiles(_ url: URL, prefix: String) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(at: url,
                                                           includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) && !$0.lastPathComponent.hasSuffix(".tmp") }
            .count
    }

    private func temporaryFileCount(_ url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".")
                && $0.lastPathComponent.hasSuffix(".tmp")
        }.count
    }
}
