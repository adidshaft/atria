import XCTest
@testable import Atria

final class AtriaHistoricalVerifiedActivityConsumerStoreTests: XCTestCase {
    private typealias Store = AtriaHistoricalVerifiedActivityConsumerApplicationStore
    private typealias Reader = AtriaHistoricalVerifiedConsumerReader

    func testPersistsFullIdentityCandidatesFingerprintsAndFourWayParity() throws {
        let root = temporaryDirectory()
        let store = Store(directoryURL: root)
        let base = Date(timeIntervalSince1970: 1_784_400_000)
        let exactTyped = try candidate("same", base, base.addingTimeInterval(600), .typedVerifiedArtifact)
        let exactRaw = try candidate("same", base, base.addingTimeInterval(600), .rawSessionDetector)
        // Fingerprints deliberately include origin, so exact ID/window remains
        // exact semantic identity for parity without conflating provenance.
        let overlapTyped = try candidate("typed-overlap", base.addingTimeInterval(900),
                                         base.addingTimeInterval(1_500), .typedVerifiedArtifact)
        let overlapRaw = try candidate("raw-overlap", base.addingTimeInterval(1_000),
                                       base.addingTimeInterval(1_400), .rawSessionDetector)
        let typedOnly = try candidate("typed-only", base.addingTimeInterval(2_000),
                                      base.addingTimeInterval(2_300), .typedVerifiedArtifact)
        let rawOnly = try candidate("raw-only", base.addingTimeInterval(3_000),
                                    base.addingTimeInterval(3_300), .rawSessionDetector)

        let input = Store.Input(verificationIdentity: identity(generation: 1),
                                outcome: .available,
                                typedCandidates: [typedOnly, overlapTyped, exactTyped],
                                rawCandidates: [rawOnly, exactRaw, overlapRaw],
                                appliedAt: base.addingTimeInterval(4_000))
        let applied = try store.apply(input, expectedCurrentIdentitySHA256: nil)
        let loaded = try XCTUnwrap(store.loadCurrent(sourceChunkID: "chunk-a"))

        XCTAssertEqual(applied, loaded)
        XCTAssertEqual(loaded.verificationIdentity, input.verificationIdentity)
        XCTAssertEqual(loaded.artifactKind, .activity)
        XCTAssertEqual(loaded.typedCandidates.map(\.identifier),
                       ["same", "typed-overlap", "typed-only"])
        XCTAssertTrue(loaded.typedCandidates.allSatisfy { $0.fingerprintSHA256.count == 64 })
        XCTAssertEqual(loaded.parity.exactIdentifiers, ["same"])
        XCTAssertEqual(loaded.parity.overlapOnly,
                       [.init(typedIdentifier: "typed-overlap", rawIdentifier: "raw-overlap")])
        XCTAssertEqual(loaded.parity.typedOnlyIdentifiers, ["typed-only"])
        XCTAssertEqual(loaded.parity.rawOnlyIdentifiers, ["raw-only"])
    }

    func testIdenticalReplayIsIdempotentAndKeepsFirstAppliedTime() throws {
        let root = temporaryDirectory()
        let store = Store(directoryURL: root)
        let base = Date(timeIntervalSince1970: 1_784_410_000)
        let typed = try candidate("typed", base, base.addingTimeInterval(300), .typedVerifiedArtifact)
        let first = try store.apply(.init(verificationIdentity: identity(generation: 1),
                                          outcome: .available,
                                          typedCandidates: [typed],
                                          rawCandidates: [],
                                          appliedAt: base),
                                    expectedCurrentIdentitySHA256: nil)
        let second = try store.apply(.init(verificationIdentity: identity(generation: 1),
                                           outcome: .available,
                                           typedCandidates: [typed],
                                           rawCandidates: [],
                                           appliedAt: base.addingTimeInterval(999)),
                                     expectedCurrentIdentitySHA256: first.verificationIdentitySHA256)
        XCTAssertEqual(second, first)
        XCTAssertEqual(second.appliedAt, base)
    }

    func testCrashAfterGenerationPublicationLeavesOldPointerAndRetryRecovers() throws {
        enum Crash: Error { case injected }
        let root = temporaryDirectory()
        let base = Date(timeIntervalSince1970: 1_784_420_000)
        let input = Store.Input(verificationIdentity: identity(generation: 1),
                                outcome: .knownEmpty,
                                typedCandidates: [],
                                rawCandidates: [],
                                appliedAt: base)
        let crashing = Store(directoryURL: root) { checkpoint in
            if checkpoint == .generationPublished { throw Crash.injected }
        }
        XCTAssertThrowsError(try crashing.apply(input, expectedCurrentIdentitySHA256: nil))
        XCTAssertNil(try Store(directoryURL: root).loadCurrent(sourceChunkID: "chunk-a"))

        let recovered = try Store(directoryURL: root).apply(
            input, expectedCurrentIdentitySHA256: nil
        )
        XCTAssertEqual(recovered.outcome, .knownEmpty)
    }

    func testCASRejectsStaleWriterAndNewOverlapTombstonesOldIdentifier() throws {
        let root = temporaryDirectory()
        let store = Store(directoryURL: root)
        let base = Date(timeIntervalSince1970: 1_784_430_000)
        let old = try candidate("old", base, base.addingTimeInterval(600), .typedVerifiedArtifact)
        let first = try store.apply(.init(verificationIdentity: identity(generation: 1),
                                          outcome: .available,
                                          typedCandidates: [old],
                                          rawCandidates: []),
                                    expectedCurrentIdentitySHA256: nil)
        let replacement = try candidate("replacement", base.addingTimeInterval(60),
                                        base.addingTimeInterval(660), .typedVerifiedArtifact)
        let next = Store.Input(verificationIdentity: identity(generation: 2),
                               outcome: .available,
                               typedCandidates: [replacement],
                               rawCandidates: [])
        XCTAssertThrowsError(try store.apply(next, expectedCurrentIdentitySHA256: nil)) {
            XCTAssertEqual($0 as? Store.StoreError, .staleCurrentGeneration)
        }
        let applied = try store.apply(next,
                                      expectedCurrentIdentitySHA256: first.verificationIdentitySHA256)
        XCTAssertEqual(applied.typedCandidates.map(\.identifier), ["replacement"])
        XCTAssertEqual(applied.tombstonedCandidateIdentifiers, ["old"])
    }

    func testTamperedCurrentGenerationFailsClosed() throws {
        let root = temporaryDirectory()
        let store = Store(directoryURL: root)
        _ = try store.apply(.init(verificationIdentity: identity(generation: 1),
                                  outcome: .knownEmpty,
                                  typedCandidates: [],
                                  rawCandidates: []),
                            expectedCurrentIdentitySHA256: nil)
        let generation = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix("activity-consumer-generation-") })
        var bytes = try Data(contentsOf: generation)
        bytes[bytes.startIndex] ^= 0x01
        try bytes.write(to: generation)
        XCTAssertThrowsError(try store.loadCurrent(sourceChunkID: "chunk-a")) {
            XCTAssertEqual($0 as? Store.StoreError, .generationInvalid)
        }
    }

    func testPlannerDistinguishesMissingDeferredAndKnownEmptyWithoutInventingValue() throws {
        let empty = emptyBundle(activity: .knownEmpty, identity: identity(generation: 1))
        guard case .apply(let knownEmpty) = AtriaHistoricalVerifiedActivityShadowPlanner.prepare(
            source: empty, rawCandidates: []
        ) else { return XCTFail("known-empty must be durably applicable") }
        XCTAssertEqual(knownEmpty.outcome, .knownEmpty)
        XCTAssertTrue(knownEmpty.typedCandidates.isEmpty)

        let missing = emptyBundle(activity: .missing(.receiptNotPublished), identity: nil)
        XCTAssertEqual(AtriaHistoricalVerifiedActivityShadowPlanner.prepare(
            source: missing, rawCandidates: []
        ), .retainPrevious(.missingArtifact))

        let deferred = emptyBundle(activity: .deferred(.verificationFailed), identity: nil)
        XCTAssertEqual(AtriaHistoricalVerifiedActivityShadowPlanner.prepare(
            source: deferred, rawCandidates: []
        ), .retainPrevious(.deferredArtifact))
    }

    func testShadowImplementationContainsNoCanonicalOrUIWriteSurface() throws {
        let source = try String(contentsOf: projectRoot()
            .appendingPathComponent("Atria/AtriaHistoricalVerifiedActivityConsumerStore.swift"),
                                encoding: .utf8)
        for forbidden in ["UserConfirmedWorkout", "confirmedWorkoutsURL", "DailyRollupStore",
                          "WidgetCenter", "publishDashboardRevision", "cachedConfirmedWorkouts =",
                          "cachedConfirmedSleeps ="] {
            XCTAssertFalse(source.contains(forbidden), "shadow store must not reference \(forbidden)")
        }
        let sessions = try String(contentsOf: projectRoot().appendingPathComponent("Atria/Sessions.swift"),
                                  encoding: .utf8)
        let start = try XCTUnwrap(sessions.range(of: "private func runRecoveredVerifiedActivityShadowStep"))
        let end = try XCTUnwrap(sessions.range(of: "private func runRecoveredWorkoutStep",
                                              range: start.upperBound..<sessions.endIndex))
        let block = String(sessions[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(block.contains("cachedConfirmedWorkouts ="))
        XCTAssertFalse(block.contains("publishDashboardRevision"))
        XCTAssertTrue(block.contains("app_mutations=0"))
        let archiveCall = try XCTUnwrap(sessions.range(of: "self.runRecoveredVerifiedActivityShadowStep"))
        let workoutCall = try XCTUnwrap(sessions.range(of: "self.runRecoveredWorkoutStep",
                                                       range: archiveCall.upperBound..<sessions.endIndex))
        XCTAssertLessThan(sessions.distance(from: sessions.startIndex, to: archiveCall.lowerBound),
                          sessions.distance(from: sessions.startIndex, to: workoutCall.lowerBound))
    }

    func testVerifiedConsumerFacadeRejectsUnboundedZeroBudgetWithoutReading() throws {
        let root = temporaryDirectory()
        var consumed = false
        let report = try HistoricalArchive.readVerifiedConsumerSources(
            archiveRoot: root,
            catalogStore: .init(rootURL: root),
            configuration: .production(restingHeartRate: 60,
                                       maximumHeartRate: 190,
                                       timeZoneIdentifier: "UTC"),
            maximumSourceCount: 0
        ) { _ in
            consumed = true
        }
        XCTAssertFalse(consumed)
        XCTAssertEqual(report.attemptedSourceCount, 0)
        XCTAssertEqual(report.deliveredSourceCount, 0)
        XCTAssertTrue(report.wasBounded)
    }

    private func emptyBundle(
        activity: Reader.ArtifactState<AtriaHistoricalActivityProjection>,
        identity: Reader.VerificationIdentity?
    ) -> Reader.SourceArtifacts {
        .init(sourceChunkID: "chunk-a",
              verificationIdentity: identity,
              activity: activity,
              dailyMetrics: .knownEmpty,
              steps: .knownEmpty,
              sleep: .knownEmpty,
              workout: .knownEmpty)
    }

    private func identity(generation: UInt64) -> Reader.VerificationIdentity {
        let source = AtriaHistoricalConsumerReceiptLedger.Source(
            chunkID: "chunk-a",
            rawSHA256: String(repeating: "a", count: 64),
            firstTimestamp: Date(timeIntervalSince1970: 1_784_400_000),
            lastTimestamp: Date(timeIntervalSince1970: 1_784_403_600)
        )
        let kinds: [AtriaHistoricalConsumerReceiptLedger.ProjectionKind] = [
            .activity, .dailyMetrics, .sleep, .steps, .workout
        ]
        let receipts = kinds.map { kind in
            AtriaHistoricalConsumerReceiptLedger.Receipt(
                version: 1,
                source: source,
                kind: kind,
                consumerSchemaVersion: 1,
                algorithmVersion: "algorithm-\(generation)",
                configurationSHA256: String(repeating: "b", count: 64),
                dependencyStart: source.firstTimestamp.addingTimeInterval(-1_800),
                dependencyEnd: source.lastTimestamp.addingTimeInterval(1_800),
                completionWatermark: source.lastTimestamp.addingTimeInterval(3_600),
                outcome: .explicitlyEmpty,
                recordCount: 0,
                artifactFilename: "artifact-\(kind.rawValue).bin",
                artifactSHA256: String(repeating: "c", count: 64),
                artifactByteCount: 1,
                settledAt: source.lastTimestamp
            )
        }.sorted { $0.kind.rawValue < $1.kind.rawValue }
        return .init(completionGeneration: generation,
                     generationIdentifier: "generation-\(generation)",
                     catalogSnapshotSHA256: String(repeating: "d", count: 64),
                     source: source,
                     receipts: receipts)
    }

    private func candidate(_ identifier: String,
                           _ start: Date,
                           _ end: Date,
                           _ origin: Store.CandidateOrigin) throws -> Store.Candidate {
        try .init(identifier: identifier, start: start, end: end, origin: origin)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-verified-activity-store-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
