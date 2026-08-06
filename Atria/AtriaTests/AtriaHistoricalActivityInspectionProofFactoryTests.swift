import XCTest
@testable import Atria

final class AtriaHistoricalActivityInspectionProofFactoryTests: XCTestCase {
    private var roots: [URL] = []
    private let start = Date(timeIntervalSince1970: 2_002_000_000)

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    // MARK: - Streamed aggregate-snapshot digest byte-identity (2026-08-01)

    /// The streamed digest MUST be byte-identical to hashing the whole
    /// re-encoded `canonicalAggregateSnapshotData` buffer. This is the memory
    /// bound behind Phase 1: the streamed path never materializes the whole
    /// archive `Data` yet the persisted SHA-256 must never change.
    func testStreamedAggregateSnapshotDigestEqualsWholeBufferDigest() throws {
        // Empty aggregates (prefix + suffix only, no elements).
        try assertStreamedDigestMatchesWholeBuffer(
            makeStreamSnapshot(aggregates: [], diagnostics: (0, 0, 0)),
            "empty aggregates must hash identically"
        )

        // Single element (prefix + one element + suffix, no separators).
        try assertStreamedDigestMatchesWholeBuffer(
            makeStreamSnapshot(
                aggregates: [makeStreamChunk(chunkID: "chunk-a", firstOffset: 0)],
                diagnostics: (1, 1, 0)
            ),
            "single aggregate must hash identically"
        )

        // Multiple elements already in canonical order (comma separators).
        try assertStreamedDigestMatchesWholeBuffer(
            makeStreamSnapshot(
                aggregates: [
                    makeStreamChunk(chunkID: "chunk-a", firstOffset: 0),
                    makeStreamChunk(chunkID: "chunk-b", firstOffset: 3_600),
                    makeStreamChunk(chunkID: "chunk-c", firstOffset: 7_200),
                ],
                diagnostics: (3, 3, 0)
            ),
            "multiple ordered aggregates must hash identically"
        )

        // Reverse-sorted input: both paths sort by (firstTimestamp, chunkID)
        // before encoding, so the digest must be independent of input order.
        try assertStreamedDigestMatchesWholeBuffer(
            makeStreamSnapshot(
                aggregates: [
                    makeStreamChunk(chunkID: "chunk-c", firstOffset: 7_200),
                    makeStreamChunk(chunkID: "chunk-b", firstOffset: 3_600),
                    makeStreamChunk(chunkID: "chunk-a", firstOffset: 0),
                ],
                diagnostics: (3, 3, 1)
            ),
            "reverse-sorted input must hash identically"
        )

        // Same firstTimestamp, reversed chunkID order exercises the chunkID
        // tie-break of the shared sort.
        try assertStreamedDigestMatchesWholeBuffer(
            makeStreamSnapshot(
                aggregates: [
                    makeStreamChunk(chunkID: "chunk-z", firstOffset: 1_000),
                    makeStreamChunk(chunkID: "chunk-a", firstOffset: 1_000),
                ],
                diagnostics: (2, 2, 0)
            ),
            "chunkID tie-break must hash identically"
        )

        // A real multi-source committed on-disk fixture.
        let committed = try makeCommittedFixture()
        try assertStreamedDigestMatchesWholeBuffer(
            committed.snapshot,
            "committed on-disk snapshot must hash identically"
        )
        XCTAssertFalse(committed.snapshot.aggregates.isEmpty)
    }

    private func assertStreamedDigestMatchesWholeBuffer(
        _ snapshot: AtriaHistoricalAggregateReader.Snapshot,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let wholeBuffer = try AtriaHistoricalActivityInspectionProofFactory
            .canonicalAggregateSnapshotData(snapshot)
        let wholeBufferDigest = AtriaHistoricalDrainCompletionGenerationStore
            .sha256(wholeBuffer)
        let streamed = try AtriaHistoricalActivityInspectionProofFactory
            .streamedAggregateSnapshotDigest(snapshot)
        XCTAssertEqual(streamed, wholeBufferDigest, message, file: file, line: line)
    }

    private func makeStreamSnapshot(
        aggregates: [AtriaHistoricalAggregateChunk],
        diagnostics: (committed: Int, accepted: Int, rejected: Int)
    ) -> AtriaHistoricalAggregateReader.Snapshot {
        .init(
            aggregates: aggregates,
            diagnostics: .init(committedManifests: diagnostics.committed,
                               acceptedAggregates: diagnostics.accepted,
                               rejectedManifests: diagnostics.rejected)
        )
    }

    private func makeStreamChunk(chunkID: String,
                                 firstOffset: TimeInterval) -> AtriaHistoricalAggregateChunk {
        let first = start.addingTimeInterval(firstOffset)
        // A populated HeartRateMinute forces nested dictionary encoding so the
        // "standalone element == its slice inside the full array" claim is
        // exercised, not just flat scalar fields.
        let minute = AtriaHistoricalAggregateChunk.HeartRateMinute(
            minuteStart: first,
            sampleCount: 2,
            sumBPM: 140,
            minimumBPM: 60,
            maximumBPM: 80,
            samplesByBPM: [60: 1, 80: 1],
            terminalBPMSeconds: [80: 10],
            transitionHalfBPMSeconds: [140: 10],
            coveredSeconds: 10,
            droppedGapSeconds: 0,
            firstSampleUnix: first.timeIntervalSince1970,
            firstSampleBPM: 60,
            lastSampleUnix: first.addingTimeInterval(10).timeIntervalSince1970,
            lastSampleBPM: 80
        )
        return .init(
            schema: AtriaHistoricalAggregateChunk.currentSchema,
            createdAt: first.addingTimeInterval(10),
            source: .init(chunkID: chunkID,
                          rawSHA256: String(repeating: "a", count: 64),
                          rawByteCount: 128,
                          rawRowCount: 4,
                          firstTimestamp: first,
                          lastTimestamp: first.addingTimeInterval(600),
                          decoderSchema: HistoricalArchive.schema,
                          validatedLayouts: [HistoricalArchive.layoutVersion]),
            heartRateMinutes: [minute],
            rrEpochs: [],
            motionEpochs: [],
            materializedProjections: [],
            parity: .init(rawRows: 4,
                          decodedRows: 4,
                          undecodableRowsRetainedRaw: 0,
                          metricUsableRows: 4,
                          heartRateSamples: 2,
                          heartRateSumBPM: 140,
                          acceptedRRBeats: 0,
                          acceptedRRSumMilliseconds: 0,
                          validatedGravityRows: 0,
                          motionEpochs: 0,
                          projectionReceipts: 0)
        )
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

    func testTerminalRetryAdvancesGenerationWhenCatalogSnapshotWasEnriched() throws {
        let requestedStart = start.addingTimeInterval(-1_800.75)
        let requestedEnd = start.addingTimeInterval(5_400.75)
        let completedAt = requestedEnd.addingTimeInterval(0.1)
        let prior = AtriaHistoricalDrainCompletionGenerationStore.Record(
            version: 1,
            generation: 1,
            terminalBatchNumber: 34,
            durableSequence: 19_295,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd,
            completedAt: completedAt,
            catalogGeneration: 249,
            catalogSnapshotSHA256: String(repeating: "a", count: 64),
            aggregateSnapshotSHA256: String(repeating: "b", count: 64),
            disposition: .terminal
        )

        let reused = try HistoricalArchive.terminalCompletionGeneration(
            prior: prior,
            terminalBatchNumber: 34,
            durableSequence: 19_295,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd,
            completedAt: completedAt,
            catalogGeneration: 249,
            catalogSnapshotSHA256: String(repeating: "a", count: 64),
            aggregateSnapshotSHA256: String(repeating: "b", count: 64)
        )
        let advanced = try HistoricalArchive.terminalCompletionGeneration(
            prior: prior,
            terminalBatchNumber: 34,
            durableSequence: 19_295,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd,
            completedAt: completedAt,
            catalogGeneration: 251,
            catalogSnapshotSHA256: String(repeating: "c", count: 64),
            aggregateSnapshotSHA256: String(repeating: "b", count: 64)
        )

        XCTAssertEqual(reused, 1)
        XCTAssertEqual(advanced, 2)
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
