import XCTest
@testable import Atria

final class AtriaHistoricalConsumerReceiptLedgerTests: XCTestCase {
    private var roots: [URL] = []
    private let start = Date(timeIntervalSince1970: 2_000_000_000)

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testAllSixVerifiedArtifactsProduceRetirementReceipts() throws {
        let ledger = makeLedger()
        let source = makeSource()
        for (index, kind) in requiredKinds.enumerated() {
            _ = try ledger.publish(publication(source: source,
                                               kind: kind,
                                               artifact: Data("[{\"kind\":\"\(kind.rawValue)\"}]".utf8),
                                               recordCount: index + 1))
        }

        let projections = try ledger.validatedMaterializedProjections(for: source) { receipt, artifact in
            !artifact.isEmpty && receipt.artifactByteCount == artifact.count
        }

        XCTAssertEqual(Set(projections.map(\.kind)), Set(requiredKinds))
        XCTAssertTrue(projections.allSatisfy { $0.identifier.hasPrefix("consumer-receipt-") })
    }

    func testExplicitEmptyIsDurableAndDistinctFromMissing() throws {
        let ledger = makeLedger()
        let source = makeSource()
        _ = try ledger.publish(.init(source: source,
                                    kind: .sleep,
                                    consumerSchemaVersion: 3,
                                    algorithmVersion: "sleep-v3",
                                    configurationSHA256: String(repeating: "b", count: 64),
                                    dependencyStart: source.firstTimestamp.addingTimeInterval(-3_600),
                                    dependencyEnd: source.lastTimestamp.addingTimeInterval(3_600),
                                    completionWatermark: source.lastTimestamp.addingTimeInterval(3_600),
                                    outcome: .explicitlyEmpty,
                                    recordCount: 0,
                                    artifact: Data("{\"state\":\"complete\",\"outputs\":[]}".utf8),
                                    settledAt: source.lastTimestamp.addingTimeInterval(3_600)))

        XCTAssertThrowsError(
            try ledger.validatedMaterializedProjections(for: source) { _, _ in true }
        ) { error in
            XCTAssertEqual(error as? AtriaHistoricalConsumerReceiptLedger.LedgerError,
                           .receiptMissing(.activity))
        }
    }

    func testTamperedArtifactFailsBeforeProjectionPublication() throws {
        let ledger = makeLedger()
        let source = makeSource()
        var sleepArtifactURL: URL?
        for kind in requiredKinds {
            let published = try ledger.publish(publication(source: source,
                                                           kind: kind,
                                                           artifact: Data("[\"\(kind.rawValue)\"]".utf8)))
            if kind == .sleep { sleepArtifactURL = published.artifactURL }
        }
        try Data("tampered".utf8).write(to: try XCTUnwrap(sleepArtifactURL))

        XCTAssertThrowsError(
            try ledger.validatedMaterializedProjections(for: source) { _, _ in true }
        ) { error in
            XCTAssertEqual(error as? AtriaHistoricalConsumerReceiptLedger.LedgerError,
                           .artifactInvalid(.sleep))
        }
    }

    func testSemanticVerifierCannotBeBypassedByHashValidArtifact() throws {
        let ledger = makeLedger()
        let source = makeSource()
        for kind in requiredKinds {
            _ = try ledger.publish(publication(source: source,
                                               kind: kind,
                                               artifact: Data("[\"\(kind.rawValue)\"]".utf8)))
        }

        XCTAssertThrowsError(
            try ledger.validatedMaterializedProjections(for: source) { receipt, _ in
                receipt.kind != .steps
            }
        ) { error in
            XCTAssertEqual(error as? AtriaHistoricalConsumerReceiptLedger.LedgerError,
                           .semanticVerificationFailed(.steps))
        }
    }

    func testCrashBeforeReceiptPublishNeverCreatesCommitMarker() throws {
        enum Injected: Error { case crash }
        let source = makeSource()
        for point in [AtriaHistoricalConsumerReceiptLedger.Checkpoint.artifactTemporaryDurable,
                      .artifactPublished,
                      .receiptTemporaryDurable] {
            let ledger = makeLedger(checkpoint: { if $0 == point { throw Injected.crash } })
            XCTAssertThrowsError(try ledger.publish(publication(source: source,
                                                                kind: .replayIdentity,
                                                                artifact: Data("[\"identity\"]".utf8))))
            XCTAssertThrowsError(
                try ledger.validatedMaterializedProjections(for: source) { _, _ in true }
            )
        }
    }

    func testRetryRepairsMissingContentAddressedArtifactBeforeReusingReceipt() throws {
        let ledger = makeLedger()
        let source = makeSource()
        let value = publication(source: source,
                                kind: .activity,
                                artifact: Data("[\"activity\"]".utf8))
        let first = try ledger.publish(value)
        try FileManager.default.removeItem(at: first.artifactURL)

        let retry = try ledger.publish(value)

        XCTAssertTrue(retry.reusedExistingReceipt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retry.artifactURL.path))
    }

    private var requiredKinds: [AtriaHistoricalAggregateChunk.MaterializedProjection.Kind] {
        AtriaHistoricalAggregateChunk.rawRetirementRequiredProjectionKinds
            .sorted { $0.rawValue < $1.rawValue }
    }

    private func makeSource() -> AtriaHistoricalConsumerReceiptLedger.Source {
        .init(chunkID: "sealed-001",
              rawSHA256: String(repeating: "a", count: 64),
              firstTimestamp: start,
              lastTimestamp: start.addingTimeInterval(3_600))
    }

    private func publication(
        source: AtriaHistoricalConsumerReceiptLedger.Source,
        kind: AtriaHistoricalAggregateChunk.MaterializedProjection.Kind,
        artifact: Data,
        recordCount: Int = 1
    ) -> AtriaHistoricalConsumerReceiptLedger.Publication {
        .init(source: source,
              kind: kind,
              consumerSchemaVersion: 1,
              algorithmVersion: "\(kind.rawValue)-v1",
              configurationSHA256: String(repeating: "b", count: 64),
              dependencyStart: source.firstTimestamp,
              dependencyEnd: source.lastTimestamp,
              completionWatermark: source.lastTimestamp,
              outcome: recordCount == 0 ? .explicitlyEmpty : .materialized,
              recordCount: recordCount,
              artifact: artifact,
              settledAt: source.lastTimestamp)
    }

    private func makeLedger(
        checkpoint: @escaping (AtriaHistoricalConsumerReceiptLedger.Checkpoint) throws -> Void = { _ in }
    ) -> AtriaHistoricalConsumerReceiptLedger {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalConsumerReceiptLedgerTests")
            .appendingPathComponent(UUID().uuidString)
        roots.append(root)
        return .init(directoryURL: root, checkpoint: checkpoint)
    }
}
