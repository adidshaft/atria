import CryptoKit
import XCTest
@testable import Atria

final class AtriaHistoricalCanonicalConsumerDestinationStoreTests: XCTestCase {
    private typealias ProofStore = AtriaHistoricalCanonicalConsumerApplicationStore
    private typealias DestinationStore = AtriaHistoricalCanonicalConsumerDestinationStore
    private typealias Kind = AtriaHistoricalConsumerReceiptLedger.ProjectionKind
    private let start = Date(timeIntervalSince1970: 1_784_600_000)

    func testAdapterPersistsAndRereadsAllFiveCanonicalDestinations() throws {
        let root = temporaryDirectory()
        let identity = makeIdentity(generation: 7)
        let adapter = makeAdapter(root)

        let applied = try adapter.apply(identity: identity,
                                        artifacts: artifacts(for: identity),
                                        appliedAt: start.addingTimeInterval(7_200))
        let reread = try adapter.validatedCurrent(identity: identity)

        XCTAssertEqual(reread, applied)
        XCTAssertEqual(reread.applications.count, 5)
        XCTAssertEqual(Set(reread.applications.map(\.consumer)), Set(ProofStore.Consumer.allCases))
        XCTAssertEqual(reread.applications.first {
            $0.consumer == .workoutAndActivity
        }?.appliedProjectionKinds, [.activity, .workout])
        XCTAssertTrue(reread.applications.allSatisfy {
            $0.canonicalStoreIdentifier.hasPrefix("atria.historical.canonical.")
                && $0.canonicalStoreGeneration == 7
        })
    }

    func testTamperedDestinationInvalidatesApplicationProofReadback() throws {
        let root = temporaryDirectory()
        let identity = makeIdentity(generation: 1)
        let adapter = makeAdapter(root)
        _ = try adapter.apply(identity: identity,
                              artifacts: artifacts(for: identity),
                              appliedAt: start.addingTimeInterval(7_200))
        let destination = root.appendingPathComponent("destinations")
        let sleepSnapshot = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil
        ).first {
            $0.lastPathComponent.hasPrefix("canonical-sleep-")
                && !$0.lastPathComponent.contains("-current-")
        })
        var bytes = try Data(contentsOf: sleepSnapshot)
        bytes[bytes.startIndex] ^= 0x01
        try bytes.write(to: sleepSnapshot)

        XCTAssertThrowsError(try adapter.validatedCurrent(identity: identity))
    }

    func testMissingProjectionCannotPublishAnyApplicationProof() throws {
        let root = temporaryDirectory()
        let identity = makeIdentity(generation: 1)
        let adapter = makeAdapter(root)
        let incomplete = artifacts(for: identity).filter { $0.receipt.kind != .steps }

        XCTAssertThrowsError(try adapter.apply(identity: identity,
                                               artifacts: incomplete,
                                               appliedAt: start.addingTimeInterval(7_200))) { error in
            XCTAssertEqual(error as? DestinationStore.StoreError, .incompleteProjectionSet)
        }
        XCTAssertNil(try ProofStore(directoryURL: root.appendingPathComponent("proofs"))
            .loadCurrent(sourceChunkID: identity.source.chunkID))
    }

    func testArtifactBytesMustMatchExactIdentityReceiptDigest() throws {
        let root = temporaryDirectory()
        let identity = makeIdentity(generation: 1)
        let adapter = makeAdapter(root)
        var values = artifacts(for: identity)
        let first = try XCTUnwrap(values.first)
        values[0] = .init(receipt: first.receipt,
                          artifact: first.artifact + Data("tamper".utf8))

        XCTAssertThrowsError(try adapter.apply(identity: identity,
                                               artifacts: values,
                                               appliedAt: start.addingTimeInterval(7_200))) { error in
            XCTAssertEqual(error as? DestinationStore.StoreError, .invalidProjection)
        }
    }

    private func makeAdapter(_ root: URL) -> AtriaHistoricalCanonicalConsumerApplicationAdapter {
        .init(destinationStore: .init(directoryURL: root.appendingPathComponent("destinations")),
              proofDirectoryURL: root.appendingPathComponent("proofs"))
    }

    private func makeIdentity(generation: UInt64) -> ProofStore.VerificationIdentity {
        let source = AtriaHistoricalConsumerReceiptLedger.Source(
            chunkID: "source-a",
            rawSHA256: String(repeating: "a", count: 64),
            firstTimestamp: start,
            lastTimestamp: start.addingTimeInterval(3_600)
        )
        let typedKinds: [Kind] = [.activity, .dailyMetrics, .sleep, .steps, .workout]
        let typedReceipts = typedKinds.map { makeReceipt(kind: $0, source: source) }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
        return .init(
            typed: .init(completionGeneration: generation,
                         generationIdentifier: "generation-\(generation)",
                         catalogSnapshotSHA256: String(repeating: "b", count: 64),
                         source: source,
                         receipts: typedReceipts),
            replayReceipt: makeReceipt(kind: .replayIdentity, source: source)
        )
    }

    private func makeReceipt(
        kind: Kind,
        source: AtriaHistoricalConsumerReceiptLedger.Source
    ) -> AtriaHistoricalConsumerReceiptLedger.Receipt {
        let artifact = artifactData(kind)
        let digest = sha256(artifact)
        return .init(version: 1,
                     source: source,
                     kind: kind,
                     consumerSchemaVersion: 1,
                     algorithmVersion: "canonical-destination-test-v1",
                     configurationSHA256: String(repeating: "c", count: 64),
                     dependencyStart: source.firstTimestamp,
                     dependencyEnd: source.lastTimestamp,
                     completionWatermark: source.lastTimestamp,
                     outcome: .materialized,
                     recordCount: 1,
                     artifactFilename: "consumer-artifact-\(kind.rawValue)-\(digest).bin",
                     artifactSHA256: digest,
                     artifactByteCount: UInt64(artifact.count),
                     settledAt: source.lastTimestamp)
    }

    private func artifacts(
        for identity: ProofStore.VerificationIdentity
    ) -> [AtriaHistoricalConsumerReceiptLedger.ValidatedArtifact] {
        identity.receipts.map {
            .init(receipt: $0, artifact: artifactData($0.kind))
        }
    }

    private func artifactData(_ kind: Kind) -> Data {
        Data("canonical-value-\(kind.rawValue)".utf8)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "atria-canonical-destination-tests-\(UUID().uuidString)"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
