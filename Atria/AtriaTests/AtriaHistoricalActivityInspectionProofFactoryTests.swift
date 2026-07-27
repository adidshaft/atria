import XCTest
@testable import Atria

final class AtriaHistoricalActivityInspectionProofFactoryTests: XCTestCase {
    private var roots: [URL] = []
    private let start = Date(timeIntervalSince1970: 2_002_000_000)

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testFactoryUsesActualCatalogAndCommittedAggregateSnapshot() throws {
        let fixture = try makeCommittedFixture()
        let completionStore = makeCompletionStore(root: fixture.root)
        let requestedStart = start.addingTimeInterval(-1_800)
        let requestedEnd = start.addingTimeInterval(5_400)
        _ = try completionStore.recordTerminal(
            generation: 7,
            terminalBatchNumber: 3,
            durableSequence: 11,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd,
            completedAt: requestedEnd,
            catalogStore: fixture.catalogStore,
            aggregateSnapshot: fixture.snapshot
        )

        let prepared = try AtriaHistoricalActivityInspectionProofFactory(
            completionStore: completionStore
        ).prepare(catalogStore: fixture.catalogStore,
                  aggregateSnapshot: fixture.snapshot,
                  requestedStart: requestedStart,
                  requestedEnd: requestedEnd)

        XCTAssertEqual(prepared.dependencyChunks, [fixture.aggregate])
        XCTAssertEqual(prepared.completionGeneration, 7)
        XCTAssertEqual(prepared.completionWatermark, requestedEnd)
        let projection = try AtriaHistoricalActivityProjection.build(
            source: fixture.aggregate,
            dependencyChunks: prepared.dependencyChunks,
            configuration: .init(restingHeartRate: 55,
                                 maximumHeartRate: 190,
                                 timeZoneIdentifier: "UTC"),
            inspectionProof: prepared.inspectionProof,
            completionWatermark: prepared.completionWatermark
        )
        XCTAssertEqual(projection.completionState, .complete)
        XCTAssertEqual(projection.outcome, .explicitlyEmpty)
        XCTAssertTrue(projection.inspectionEvidence.closedCoverageIntervals
            .contains(where: { $0.recordCount == 0 }))
    }

    func testCompletionStorePersistsAndCoversSubsecondTerminalBounds() throws {
        let fixture = try makeCommittedFixture()
        let completionStore = makeCompletionStore(root: fixture.root)
        let requestedStart = start.addingTimeInterval(-1_800.75)
        let requestedEnd = start.addingTimeInterval(5_400.75)
        let published = try completionStore.recordTerminal(
            generation: 8,
            terminalBatchNumber: 4,
            durableSequence: 12,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd,
            completedAt: requestedEnd.addingTimeInterval(0.1),
            catalogStore: fixture.catalogStore,
            aggregateSnapshot: fixture.snapshot
        )

        XCTAssertTrue(HistoricalArchive.catalogTimestampMatches(
            raw: requestedStart,
            catalog: published.record.requestedStart
        ))
        XCTAssertTrue(HistoricalArchive.catalogTimestampMatches(
            raw: requestedEnd,
            catalog: published.record.requestedEnd
        ))
        let prepared = try AtriaHistoricalActivityInspectionProofFactory(
            completionStore: completionStore
        ).prepare(
            catalogStore: fixture.catalogStore,
            aggregateSnapshot: fixture.snapshot,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd
        )
        XCTAssertEqual(prepared.completionGeneration, 8)
    }

    func testOrphanRecordAfterCrashIsNotTerminalEvidence() throws {
        enum Injected: Error { case crash }
        let fixture = try makeCommittedFixture()
        let store = makeCompletionStore(root: fixture.root) {
            if $0 == .recordPublished { throw Injected.crash }
        }
        let range = requestedRange()

        XCTAssertThrowsError(try store.recordTerminal(
            generation: 1,
            terminalBatchNumber: 0,
            durableSequence: 1,
            requestedStart: range.start,
            requestedEnd: range.end,
            completedAt: range.end,
            catalogStore: fixture.catalogStore,
            aggregateSnapshot: fixture.snapshot
        ))
        XCTAssertThrowsError(try store.loadLatest()) { error in
            XCTAssertEqual(error as? AtriaHistoricalDrainCompletionGenerationStore.StoreError,
                           .missingCompletion)
        }
    }

    func testTamperedCompletionRecordFailsClosed() throws {
        let fixture = try makeCommittedFixture()
        let store = makeCompletionStore(root: fixture.root)
        let range = requestedRange()
        let published = try store.recordTerminal(
            generation: 2,
            terminalBatchNumber: 1,
            durableSequence: 4,
            requestedStart: range.start,
            requestedEnd: range.end,
            completedAt: range.end,
            catalogStore: fixture.catalogStore,
            aggregateSnapshot: fixture.snapshot
        )
        try Data("tampered".utf8).write(to: published.recordURL)

        XCTAssertThrowsError(try store.loadLatest()) { error in
            XCTAssertEqual(error as? AtriaHistoricalDrainCompletionGenerationStore.StoreError,
                           .recordInvalid)
        }
    }

    func testOlderCompletionGenerationCannotReplaceLatest() throws {
        let fixture = try makeCommittedFixture()
        let store = makeCompletionStore(root: fixture.root)
        let range = requestedRange()
        _ = try store.recordTerminal(generation: 5,
                                     terminalBatchNumber: 1,
                                     durableSequence: 5,
                                     requestedStart: range.start,
                                     requestedEnd: range.end,
                                     completedAt: range.end,
                                     catalogStore: fixture.catalogStore,
                                     aggregateSnapshot: fixture.snapshot)

        XCTAssertThrowsError(try store.recordTerminal(
            generation: 4,
            terminalBatchNumber: 1,
            durableSequence: 6,
            requestedStart: range.start,
            requestedEnd: range.end,
            completedAt: range.end,
            catalogStore: fixture.catalogStore,
            aggregateSnapshot: fixture.snapshot
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalDrainCompletionGenerationStore.StoreError,
                           .staleGeneration)
        }
    }

    func testCatalogGenerationAdvanceMakesCompletionStale() throws {
        let fixture = try makeCommittedFixture()
        let store = makeCompletionStore(root: fixture.root)
        let range = requestedRange()
        _ = try store.recordTerminal(generation: 1,
                                     terminalBatchNumber: 0,
                                     durableSequence: 1,
                                     requestedStart: range.start,
                                     requestedEnd: range.end,
                                     completedAt: range.end,
                                     catalogStore: fixture.catalogStore,
                                     aggregateSnapshot: fixture.snapshot)
        _ = try fixture.catalogStore.writableChunkURL(
            now: start.addingTimeInterval(2 * 86_400)
        )

        XCTAssertThrowsError(try AtriaHistoricalActivityInspectionProofFactory(
            completionStore: store
        ).prepare(catalogStore: fixture.catalogStore,
                  aggregateSnapshot: fixture.snapshot,
                  requestedStart: range.start,
                  requestedEnd: range.end)) { error in
            XCTAssertEqual(error as? AtriaHistoricalActivityInspectionProofFactory.FactoryError,
                           .staleCompletionGeneration)
        }
    }

    func testPostTerminalAppendCannotReuseOldCompletionRecord() throws {
        let fixture = try makeCommittedFixture()
        let store = makeCompletionStore(root: fixture.root)
        let range = requestedRange()
        _ = try store.recordTerminal(generation: 1,
                                     terminalBatchNumber: 0,
                                     durableSequence: 1,
                                     requestedStart: range.start,
                                     requestedEnd: range.end,
                                     completedAt: range.end,
                                     catalogStore: fixture.catalogStore,
                                     aggregateSnapshot: fixture.snapshot)
        let active = try fixture.catalogStore.activeChunkDescriptor()
        try FileManager.default.createDirectory(at: active.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("post-terminal-row\n".utf8).write(to: active.fileURL)

        XCTAssertThrowsError(try AtriaHistoricalActivityInspectionProofFactory(
            completionStore: store
        ).prepare(catalogStore: fixture.catalogStore,
                  aggregateSnapshot: fixture.snapshot,
                  requestedStart: range.start,
                  requestedEnd: range.end)) { error in
            XCTAssertEqual(error as? AtriaHistoricalArchiveCatalogStore.StoreError,
                           .catalogFileMismatch)
        }
    }

    func testUnknownLegacyTimestampCannotBecomeClosedNoDataCoverage() throws {
        let root = try temporaryRoot()
        let legacy = root.appendingPathComponent("historical-archive.jsonl")
        try Data("legacy-row\n".utf8).write(to: legacy)
        var identifiers = ["legacy", "active"]
        let catalogStore = AtriaHistoricalArchiveCatalogStore(
            rootURL: root,
            makeIdentifier: { identifiers.removeFirst() }
        )
        _ = try catalogStore.loadOrRecover(discoveredLegacyURLs: [legacy], now: start)
        let snapshot = AtriaHistoricalAggregateReader.Snapshot(
            aggregates: [],
            diagnostics: .init(committedManifests: 0,
                               acceptedAggregates: 0,
                               rejectedManifests: 0)
        )
        let completionStore = makeCompletionStore(root: root)
        let range = requestedRange()
        _ = try completionStore.recordTerminal(generation: 1,
                                               terminalBatchNumber: 0,
                                               durableSequence: 1,
                                               requestedStart: range.start,
                                               requestedEnd: range.end,
                                               completedAt: range.end,
                                               catalogStore: catalogStore,
                                               aggregateSnapshot: snapshot)

        XCTAssertThrowsError(try AtriaHistoricalActivityInspectionProofFactory(
            completionStore: completionStore
        ).prepare(catalogStore: catalogStore,
                  aggregateSnapshot: snapshot,
                  requestedStart: range.start,
                  requestedEnd: range.end)) { error in
            XCTAssertEqual(error as? AtriaHistoricalActivityInspectionProofFactory.FactoryError,
                           .unknownCatalogTimeBounds("legacy-legacy"))
        }
    }

    func testAggregateSnapshotChangedAfterCompletionFailsClosed() throws {
        let fixture = try makeCommittedFixture()
        let store = makeCompletionStore(root: fixture.root)
        let range = requestedRange()
        _ = try store.recordTerminal(generation: 1,
                                     terminalBatchNumber: 0,
                                     durableSequence: 1,
                                     requestedStart: range.start,
                                     requestedEnd: range.end,
                                     completedAt: range.end,
                                     catalogStore: fixture.catalogStore,
                                     aggregateSnapshot: fixture.snapshot)
        let changed = AtriaHistoricalAggregateReader.Snapshot(
            aggregates: fixture.snapshot.aggregates,
            diagnostics: .init(committedManifests: 2,
                               acceptedAggregates: 1,
                               rejectedManifests: 0)
        )

        XCTAssertThrowsError(try AtriaHistoricalActivityInspectionProofFactory(
            completionStore: store
        ).prepare(catalogStore: fixture.catalogStore,
                  aggregateSnapshot: changed,
                  requestedStart: range.start,
                  requestedEnd: range.end)) { error in
            XCTAssertEqual(error as? AtriaHistoricalActivityInspectionProofFactory.FactoryError,
                           .aggregateSnapshotMismatch)
        }
    }

    private struct Fixture {
        let root: URL
        let catalogStore: AtriaHistoricalArchiveCatalogStore
        let aggregate: AtriaHistoricalAggregateChunk
        let snapshot: AtriaHistoricalAggregateReader.Snapshot
    }

    private func makeCommittedFixture() throws -> Fixture {
        let root = try temporaryRoot()
        var identifiers = ["sealed-source", "active-next", "active-later"]
        let catalogStore = AtriaHistoricalArchiveCatalogStore(
            rootURL: root,
            maximumActiveBytes: 1,
            makeIdentifier: { identifiers.removeFirst() }
        )
        _ = try catalogStore.loadOrRecover(discoveredLegacyURLs: [], now: start)
        let sourceURL = try catalogStore.writableChunkURL(now: start)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let raw = Data("{\"row\":1}\n".utf8)
        try raw.write(to: sourceURL)
        let digest = AtriaHistoricalRetentionTransaction.sha256(of: raw)
        try catalogStore.sealActiveChunkAtTerminal(
            chunkID: "sealed-source",
            rowCount: 1,
            firstTimestamp: start,
            lastTimestamp: start.addingTimeInterval(3_600),
            contentSHA256: digest,
            now: start.addingTimeInterval(3_600)
        )
        let aggregate = AtriaHistoricalAggregateChunk(
            schema: AtriaHistoricalAggregateChunk.currentSchema,
            createdAt: start.addingTimeInterval(3_601),
            source: .init(chunkID: "sealed-source",
                          rawSHA256: digest,
                          rawByteCount: UInt64(raw.count),
                          rawRowCount: 1,
                          firstTimestamp: start,
                          lastTimestamp: start.addingTimeInterval(3_600),
                          decoderSchema: HistoricalArchive.schema,
                          validatedLayouts: []),
            heartRateMinutes: [],
            rrEpochs: [],
            motionEpochs: [],
            materializedProjections: [],
            parity: .init(rawRows: 1,
                          decodedRows: 1,
                          undecodableRowsRetainedRaw: 0,
                          metricUsableRows: 0,
                          heartRateSamples: 0,
                          heartRateSumBPM: 0,
                          acceptedRRBeats: 0,
                          acceptedRRSumMilliseconds: 0,
                          validatedGravityRows: 0,
                          motionEpochs: 0,
                          projectionReceipts: 0)
        )
        let aggregates = root.appendingPathComponent("aggregates")
        let manifests = root.appendingPathComponent("manifests")
        let transaction = AtriaHistoricalRetentionTransaction(
            now: { self.start.addingTimeInterval(3_602) },
            semanticVerifier: { _, _, _ in true }
        )
        _ = try transaction.commit(.init(
            transactionID: "activity-proof-source",
            sourceURL: sourceURL,
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests,
            aggregate: aggregate,
            semanticParityReceipt: AtriaHistoricalAggregateBuilder.semanticParityReceipt(for: aggregate),
            deleteSourceAfterCommit: false
        ))
        let snapshot = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: aggregates,
            manifestDirectoryURL: manifests
        ).load()
        return .init(root: root,
                     catalogStore: catalogStore,
                     aggregate: aggregate,
                     snapshot: snapshot)
    }

    private func requestedRange() -> (start: Date, end: Date) {
        (start.addingTimeInterval(-1_800), start.addingTimeInterval(5_400))
    }

    private func makeCompletionStore(
        root: URL,
        checkpoint: @escaping (AtriaHistoricalDrainCompletionGenerationStore.Checkpoint) throws -> Void = { _ in }
    ) -> AtriaHistoricalDrainCompletionGenerationStore {
        .init(directoryURL: root.appendingPathComponent("drain-completions"),
              checkpoint: checkpoint)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalActivityInspectionProofFactoryTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }
}
