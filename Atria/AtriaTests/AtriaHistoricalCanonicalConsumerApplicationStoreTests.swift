import XCTest
@testable import Atria

final class AtriaHistoricalCanonicalConsumerApplicationStoreTests: XCTestCase {
    private typealias Store = AtriaHistoricalCanonicalConsumerApplicationStore
    private typealias Kind = AtriaHistoricalConsumerReceiptLedger.ProjectionKind
    private let start = Date(timeIntervalSince1970: 1_784_500_000)

    func testPublishesAtomicFiveConsumerProofBoundToAllSixExactReceipts() throws {
        let root = temporaryDirectory()
        let identity = verificationIdentity(generation: 7)
        let applications = canonicalApplications(appliedAt: start.addingTimeInterval(8_000))
        let expectedSnapshots = Dictionary(uniqueKeysWithValues: applications.map {
            ($0.consumer, $0.snapshotSHA256)
        })
        let store = Store(directoryURL: root) { application, verifiedIdentity in
            verifiedIdentity == identity
                && expectedSnapshots[application.consumer] == application.snapshotSHA256
        }

        let committed = try store.publishCompleteSet(
            identity: identity,
            applications: applications,
            expectedCurrentIdentitySHA256: nil,
            committedAt: start.addingTimeInterval(9_000)
        )
        let loaded = try store.validatedCurrent(expectedIdentity: identity)

        XCTAssertEqual(loaded, committed)
        XCTAssertEqual(Set(loaded.applications.map(\.consumer)), Set(Store.Consumer.allCases))
        XCTAssertEqual(loaded.applications.first {
            $0.consumer == .workoutAndActivity
        }?.appliedProjectionKinds, [.activity, .workout])
        XCTAssertEqual(Set(loaded.projectionBindings.map(\.kind)), Set([
            Kind.activity, .dailyMetrics, .steps, .sleep, .workout, .replayIdentity,
        ]))
        XCTAssertEqual(loaded.verificationIdentity.completionGeneration, 7)
        XCTAssertEqual(loaded.verificationIdentity.source.chunkID, "chunk-a")
        XCTAssertTrue(loaded.projectionBindings.allSatisfy {
            $0.receiptSHA256.count == 64 && $0.artifactSHA256.count == 64
        })
    }

    func testDefaultVerifierRejectsShadowOnlyEvidenceWithoutPublishingPointer() throws {
        let root = temporaryDirectory()
        let raw = root.appendingPathComponent("sealed-source.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("retained raw\n".utf8).write(to: raw)
        let store = Store(directoryURL: root.appendingPathComponent("proof"))

        XCTAssertThrowsError(try store.publishCompleteSet(
            identity: verificationIdentity(generation: 1),
            applications: canonicalApplications(appliedAt: start.addingTimeInterval(8_000)),
            expectedCurrentIdentitySHA256: nil,
            committedAt: start.addingTimeInterval(9_000)
        )) { error in
            guard case .canonicalApplicationNotVerified = error as? Store.StoreError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertNil(try store.loadCurrent(sourceChunkID: "chunk-a"))
        XCTAssertEqual(try Data(contentsOf: raw), Data("retained raw\n".utf8))
    }

    func testIncompleteCanonicalDestinationSetFailsClosed() throws {
        let root = temporaryDirectory()
        let store = Store(directoryURL: root, canonicalStateVerifier: { _, _ in true })
        let incomplete = canonicalApplications(appliedAt: start.addingTimeInterval(8_000))
            .filter { $0.consumer != .steps }

        XCTAssertThrowsError(try store.publishCompleteSet(
            identity: verificationIdentity(generation: 1),
            applications: incomplete,
            expectedCurrentIdentitySHA256: nil,
            committedAt: start.addingTimeInterval(9_000)
        )) { error in
            XCTAssertEqual(error as? Store.StoreError, .incompleteApplicationSet)
        }
        XCTAssertNil(try store.loadCurrent(sourceChunkID: "chunk-a"))
    }

    func testReplayReceiptFromAnotherChunkCannotBeMixedIntoTypedGeneration() throws {
        let root = temporaryDirectory()
        let typed = verificationIdentity(generation: 1).typed
        let otherSource = AtriaHistoricalConsumerReceiptLedger.Source(
            chunkID: "chunk-b",
            rawSHA256: String(repeating: "f", count: 64),
            firstTimestamp: typed.source.firstTimestamp,
            lastTimestamp: typed.source.lastTimestamp
        )
        let mixed = Store.VerificationIdentity(
            typed: typed,
            replayReceipt: receipt(kind: .replayIdentity,
                                   source: otherSource,
                                   generation: 1)
        )
        let store = Store(directoryURL: root, canonicalStateVerifier: { _, _ in true })

        XCTAssertThrowsError(try store.publishCompleteSet(
            identity: mixed,
            applications: canonicalApplications(appliedAt: start.addingTimeInterval(8_000)),
            expectedCurrentIdentitySHA256: nil,
            committedAt: start.addingTimeInterval(9_000)
        )) { error in
            XCTAssertEqual(error as? Store.StoreError, .invalidIdentity)
        }
    }

    func testCrashAfterSetPublicationLeavesPriorPointerAndRetryCompletes() throws {
        enum Crash: Error { case injected }
        let root = temporaryDirectory()
        let identity = verificationIdentity(generation: 1)
        let applications = canonicalApplications(appliedAt: start.addingTimeInterval(8_000))
        let crashing = Store(
            directoryURL: root,
            canonicalStateVerifier: { _, _ in true },
            checkpoint: { if $0 == .setPublished { throw Crash.injected } }
        )

        XCTAssertThrowsError(try crashing.publishCompleteSet(
            identity: identity,
            applications: applications,
            expectedCurrentIdentitySHA256: nil,
            committedAt: start.addingTimeInterval(9_000)
        ))
        XCTAssertNil(try Store(directoryURL: root).loadCurrent(sourceChunkID: "chunk-a"))

        let recovered = try Store(
            directoryURL: root,
            canonicalStateVerifier: { _, _ in true }
        ).publishCompleteSet(
            identity: identity,
            applications: applications,
            expectedCurrentIdentitySHA256: nil,
            committedAt: start.addingTimeInterval(9_000)
        )
        XCTAssertEqual(recovered.verificationIdentity, identity)
    }

    func testCASRejectsStaleGenerationAndCanonicalReadbackIsReverified() throws {
        let root = temporaryDirectory()
        var acceptedSnapshots = Set(canonicalApplications(
            appliedAt: start.addingTimeInterval(8_000)
        ).map(\.snapshotSHA256))
        let store = Store(directoryURL: root) { application, _ in
            acceptedSnapshots.contains(application.snapshotSHA256)
        }
        let applications = canonicalApplications(appliedAt: start.addingTimeInterval(8_000))
        let first = try store.publishCompleteSet(
            identity: verificationIdentity(generation: 1),
            applications: applications,
            expectedCurrentIdentitySHA256: nil,
            committedAt: start.addingTimeInterval(9_000)
        )

        XCTAssertThrowsError(try store.publishCompleteSet(
            identity: verificationIdentity(generation: 2),
            applications: applications,
            expectedCurrentIdentitySHA256: nil,
            committedAt: start.addingTimeInterval(9_100)
        )) { error in
            XCTAssertEqual(error as? Store.StoreError, .staleCurrentGeneration)
        }

        acceptedSnapshots.remove(applications[0].snapshotSHA256)
        XCTAssertThrowsError(try store.validatedCurrent(
            expectedIdentity: first.verificationIdentity
        )) { error in
            guard case .canonicalApplicationNotVerified = error as? Store.StoreError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testTamperedAppliedSetFailsClosed() throws {
        let root = temporaryDirectory()
        let identity = verificationIdentity(generation: 1)
        let store = Store(directoryURL: root, canonicalStateVerifier: { _, _ in true })
        _ = try store.publishCompleteSet(
            identity: identity,
            applications: canonicalApplications(appliedAt: start.addingTimeInterval(8_000)),
            expectedCurrentIdentitySHA256: nil,
            committedAt: start.addingTimeInterval(9_000)
        )
        let setURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix("canonical-consumer-set-") })
        var bytes = try Data(contentsOf: setURL)
        bytes[bytes.startIndex] ^= 0x01
        try bytes.write(to: setURL)

        XCTAssertThrowsError(try store.loadCurrent(sourceChunkID: "chunk-a")) { error in
            XCTAssertEqual(error as? Store.StoreError, .setInvalid)
        }
    }

    private func verificationIdentity(generation: UInt64) -> Store.VerificationIdentity {
        let source = AtriaHistoricalConsumerReceiptLedger.Source(
            chunkID: "chunk-a",
            rawSHA256: String(repeating: "a", count: 64),
            firstTimestamp: start,
            lastTimestamp: start.addingTimeInterval(3_600)
        )
        let typedKinds: [Kind] = [.activity, .dailyMetrics, .sleep, .steps, .workout]
        let typed = AtriaHistoricalVerifiedConsumerReader.VerificationIdentity(
            completionGeneration: generation,
            generationIdentifier: "terminal-generation-\(generation)",
            catalogSnapshotSHA256: String(repeating: "b", count: 64),
            source: source,
            receipts: typedKinds.map {
                receipt(kind: $0, source: source, generation: generation)
            }.sorted { $0.kind.rawValue < $1.kind.rawValue }
        )
        return .init(typed: typed,
                     replayReceipt: receipt(kind: .replayIdentity,
                                            source: source,
                                            generation: generation))
    }

    private func receipt(
        kind: Kind,
        source: AtriaHistoricalConsumerReceiptLedger.Source,
        generation: UInt64
    ) -> AtriaHistoricalConsumerReceiptLedger.Receipt {
        let artifactDigest = String(repeating: digestCharacter(kind), count: 64)
        return .init(version: 1,
              source: source,
              kind: kind,
              consumerSchemaVersion: 1,
              algorithmVersion: "\(kind.rawValue)-generation-\(generation)",
              configurationSHA256: String(repeating: "c", count: 64),
              dependencyStart: source.firstTimestamp,
              dependencyEnd: source.lastTimestamp,
              completionWatermark: source.lastTimestamp,
              outcome: kind == .replayIdentity ? .materialized : .explicitlyEmpty,
              recordCount: kind == .replayIdentity ? 2 : 0,
              artifactFilename: "consumer-artifact-\(kind.rawValue)-\(artifactDigest).bin",
              artifactSHA256: artifactDigest,
              artifactByteCount: 1,
              settledAt: source.lastTimestamp)
    }

    private func digestCharacter(_ kind: Kind) -> Character {
        switch kind {
        case .activity: "1"
        case .dailyMetrics: "2"
        case .steps: "3"
        case .sleep: "4"
        case .workout: "5"
        case .replayIdentity: "6"
        }
    }

    private func canonicalApplications(appliedAt: Date) -> [Store.Application] {
        Store.Consumer.allCases.enumerated().map { index, consumer in
            .init(consumer: consumer,
                  appliedProjectionKinds: consumer.requiredProjectionKinds.sorted {
                      $0.rawValue < $1.rawValue
                  },
                  canonicalStoreIdentifier: "canonical.\(consumer.rawValue)",
                  canonicalStoreSchemaVersion: 1,
                  canonicalStoreGeneration: 40 + UInt64(index),
                  snapshotSHA256: String(repeating: Character(String(index + 1)), count: 64),
                  appliedAt: appliedAt)
        }
    }

    private func temporaryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-canonical-consumer-proof-tests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
