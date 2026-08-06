import XCTest
@testable import Atria

/// End-to-end proof for the crash-at-seal repair: a committed aggregate pair
/// that diverges from the sealed catalog wedges consumer publication at the
/// proof factory's exact source-identity guard, and the repair chain
/// (quarantine + rebuild + catalog-truth evidence + full-scan re-mint) clears
/// that same guard without ever touching the retained raw.
final class AtriaHistoricalCrashAtSealRepairTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    private final class IdentifierSource: @unchecked Sendable {
        private var values: [String]
        private let lock = NSLock()

        init(_ values: [String]) {
            self.values = values
        }

        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            return values.removeFirst()
        }
    }

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
    }

    private let requestedStart = Date(timeIntervalSince1970: 1_800_000_000)
    private let requestedEnd = Date(timeIntervalSince1970: 1_800_000_002)
    private let cursorWatermark = Date(timeIntervalSince1970: 1_800_000_100)

    func testDivergentPairRepairsEndToEndAndClearsFactoryMismatch() async throws {
        let fixture = try await materializedFixture()
        let rawBefore = try Data(contentsOf: fixture.source)
        let catalogGenerationBefore = try fixture.store.snapshot().generation

        // Crash-at-seal: the committed pair, and the scan record minted from
        // that terminal's evidence, both attest an identity the durable
        // catalog and retained raw disagree with.
        try makeDivergentPair(fixture)
        let crashed = try refreshedEvidence(fixture)
        let crashedSource = try XCTUnwrap(crashed.streamed.sources.first)
        let store = fullScanStore(fixture)
        _ = try store.recordCompletion(mintScanRecord(
            generation: 1,
            sourceRawSHA256: crashedSource.rawSHA256,
            sourceFirstTimestamp: crashedSource.firstTimestamp,
            sourceLastTimestamp: crashedSource.lastTimestamp,
            observedArchiveFirstTimestamp: crashedSource.firstTimestamp,
            catalogGeneration: catalogGenerationBefore,
            catalogSnapshotSHA256: crashed.catalogSnapshotSHA256,
            aggregateSnapshotSHA256: crashed.streamed.digest,
            chunkID: fixture.chunkID
        ))

        // The wedge: materialization "complete", coherent archive, and every
        // publication pass dies on the factory's exact-identity guard.
        let factory = makeFactory(fixture)
        XCTAssertThrowsError(try factory.prepareUsingFullScan(
            catalogStore: fixture.store,
            aggregateSnapshot: loadSnapshot(fixture),
            scan: try store.loadLatest(),
            requestedStart: requestedStart,
            requestedEnd: requestedEnd
        )) { error in
            XCTAssertEqual(
                error as? AtriaHistoricalActivityInspectionProofFactory
                    .FactoryError,
                .aggregateCatalogMismatch(fixture.chunkID)
            )
        }

        // Convergence: the bounded repair loop reaches a verified-complete
        // archive (the assertion is convergence itself, not any particular
        // avoided error).
        var passes = 0
        while true {
            let report = try await materializeNext(
                fixture,
                now: Date(timeIntervalSince1970: 9_000)
            )
            passes += 1
            if report.isComplete { break }
            XCTAssertLessThan(passes, 5, "repair must converge")
        }

        // The repaired archive still cannot publish through the stale record:
        // its source digest attests the quarantined pair, so the record
        // matches no accepted aggregate. The corrected re-mint is
        // load-bearing.
        XCTAssertThrowsError(try factory.prepareUsingFullScan(
            catalogStore: fixture.store,
            aggregateSnapshot: loadSnapshot(fixture),
            scan: try store.loadLatest(),
            requestedStart: requestedStart,
            requestedEnd: requestedEnd
        )) { error in
            XCTAssertEqual(
                error as? AtriaHistoricalActivityInspectionProofFactory
                    .FactoryError,
                .aggregateCatalogMismatch(fixture.chunkID)
            )
        }

        let after = try refreshedEvidence(fixture)
        XCTAssertGreaterThan(after.catalog.generation, catalogGenerationBefore)
        let resolved = try XCTUnwrap(
            HistoricalArchive.resolveCommittedFullScanSource(
                sourceChunkID: fixture.chunkID,
                catalog: after.catalog,
                streamedSources: after.streamed.sources
            )
        )
        let previous = try store.loadLatest()
        XCTAssertGreaterThan(after.catalog.generation, previous.catalogGeneration)
        XCTAssertNotEqual(resolved.rawSHA256, previous.sourceRawSHA256)
        _ = try store.recordCompletion(mintScanRecord(
            generation: previous.generation + 1,
            sourceRawSHA256: resolved.rawSHA256,
            sourceFirstTimestamp: resolved.firstTimestamp,
            sourceLastTimestamp: resolved.lastTimestamp,
            observedArchiveFirstTimestamp: try XCTUnwrap(
                after.streamed.sources.first
            ).firstTimestamp,
            catalogGeneration: after.catalog.generation,
            catalogSnapshotSHA256: after.catalogSnapshotSHA256,
            aggregateSnapshotSHA256: after.streamed.digest,
            chunkID: fixture.chunkID
        ))

        let prepared = try factory.prepareUsingFullScan(
            catalogStore: fixture.store,
            aggregateSnapshot: loadSnapshot(fixture),
            scan: try store.loadLatest(),
            requestedStart: requestedStart,
            requestedEnd: requestedEnd
        )
        XCTAssertEqual(
            prepared.dependencyChunks.map(\.source.chunkID),
            [fixture.chunkID]
        )

        XCTAssertEqual(try Data(contentsOf: fixture.source), rawBefore)
        let quarantine = fixture.root.appendingPathComponent(
            AtriaHistoricalSealedCatalogMaterializer.quarantineDirectoryName
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: quarantine.path)
                .count,
            2
        )
    }

    func testStaleScanRecordHealsWithoutRepairThroughCatalogResolutionAndRemint() async throws {
        let fixture = try await materializedFixture()
        let evidence = try refreshedEvidence(fixture)
        let truth = try XCTUnwrap(evidence.streamed.sources.first)
        let store = fullScanStore(fixture)
        // Pair-consistent variant: the archive is coherent, only the persisted
        // scan record carries a pre-crash source identity (both bounds late,
        // digest stale) — so the corrected first timestamp precedes the stale
        // observation.
        let staleFirst = truth.firstTimestamp.addingTimeInterval(60)
        let stale = mintScanRecord(
            generation: 1,
            sourceRawSHA256: String(repeating: "b", count: 64),
            sourceFirstTimestamp: staleFirst,
            sourceLastTimestamp: staleFirst.addingTimeInterval(1),
            observedArchiveFirstTimestamp: staleFirst,
            catalogGeneration: evidence.catalog.generation,
            catalogSnapshotSHA256: evidence.catalogSnapshotSHA256,
            aggregateSnapshotSHA256: evidence.streamed.digest,
            chunkID: fixture.chunkID
        )
        _ = try store.recordCompletion(stale)

        let factory = makeFactory(fixture)
        XCTAssertThrowsError(try factory.prepareUsingFullScan(
            catalogStore: fixture.store,
            aggregateSnapshot: loadSnapshot(fixture),
            scan: stale,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd
        )) { error in
            XCTAssertEqual(
                error as? AtriaHistoricalActivityInspectionProofFactory
                    .FactoryError,
                .aggregateCatalogMismatch(fixture.chunkID)
            )
        }

        // No divergent pair exists, so the repair leg must not fire: the
        // materializer reports complete without work and the catalog
        // generation stays untouched.
        let report = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 9_000)
        )
        XCTAssertNil(report.materializedChunkID)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(
            try fixture.store.snapshot().generation,
            evidence.catalog.generation
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(
                AtriaHistoricalSealedCatalogMaterializer.quarantineDirectoryName
            ).path
        ))

        // A stale-digest lookup finds nothing; the catalog-truth resolution
        // finds the exact accepted source.
        XCTAssertNil(evidence.streamed.sources.first {
            $0.chunkID == fixture.chunkID
                && $0.rawSHA256 == stale.sourceRawSHA256
        })
        let resolved = try XCTUnwrap(
            HistoricalArchive.resolveCommittedFullScanSource(
                sourceChunkID: fixture.chunkID,
                catalog: evidence.catalog,
                streamedSources: evidence.streamed.sources
            )
        )
        XCTAssertEqual(resolved, truth)

        // Copying the stale observation forward would make the corrected
        // record invalid (observedFirst must not exceed sourceFirst) — the
        // re-mint must take the observation from the refreshed evidence.
        XCTAssertThrowsError(try store.recordCompletion(mintScanRecord(
            generation: stale.generation + 1,
            sourceRawSHA256: resolved.rawSHA256,
            sourceFirstTimestamp: resolved.firstTimestamp,
            sourceLastTimestamp: resolved.lastTimestamp,
            observedArchiveFirstTimestamp: stale.observedArchiveFirstTimestamp,
            catalogGeneration: stale.catalogGeneration,
            catalogSnapshotSHA256: stale.catalogSnapshotSHA256,
            aggregateSnapshotSHA256: stale.aggregateSnapshotSHA256,
            chunkID: fixture.chunkID
        )))

        // The pair-consistent re-mint: previous digests and catalog
        // generation, corrected source fields, refreshed observation.
        _ = try store.recordCompletion(mintScanRecord(
            generation: stale.generation + 1,
            sourceRawSHA256: resolved.rawSHA256,
            sourceFirstTimestamp: resolved.firstTimestamp,
            sourceLastTimestamp: resolved.lastTimestamp,
            observedArchiveFirstTimestamp: truth.firstTimestamp,
            catalogGeneration: stale.catalogGeneration,
            catalogSnapshotSHA256: stale.catalogSnapshotSHA256,
            aggregateSnapshotSHA256: stale.aggregateSnapshotSHA256,
            chunkID: fixture.chunkID
        ))

        let prepared = try factory.prepareUsingFullScan(
            catalogStore: fixture.store,
            aggregateSnapshot: loadSnapshot(fixture),
            scan: try store.loadLatest(),
            requestedStart: requestedStart,
            requestedEnd: requestedEnd
        )
        XCTAssertEqual(
            prepared.dependencyChunks.map(\.source.chunkID),
            [fixture.chunkID]
        )
    }

    // MARK: - Fixture

    private struct Fixture: @unchecked Sendable {
        let root: URL
        let store: AtriaHistoricalArchiveCatalogStore
        let source: URL
        let aggregates: URL
        let manifests: URL
        let chunkID: String
    }

    private func materializedFixture() async throws -> Fixture {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("legacy-0.jsonl")
        try write(
            [record(unix: 1_800_000_000), record(unix: 1_800_000_001)],
            to: source
        )
        let ids = IdentifierSource(["legacy-a", "active-a"])
        let store = AtriaHistoricalArchiveCatalogStore(
            rootURL: root,
            makeIdentifier: ids.next
        )
        _ = try store.loadOrRecover(
            discoveredLegacyURLs: [source],
            now: Date(timeIntervalSince1970: 2_000)
        )
        let fixture = Fixture(
            root: root,
            store: store,
            source: source,
            aggregates: root.appendingPathComponent("aggregates-v2"),
            manifests: root.appendingPathComponent("retention-manifests-v2"),
            chunkID: "legacy-legacy-a"
        )
        let report = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 3_000)
        )
        XCTAssertTrue(report.isComplete)
        return fixture
    }

    private func materializeNext(
        _ fixture: Fixture,
        now: Date
    ) async throws -> AtriaHistoricalSealedCatalogMaterializer.Report {
        try await Task.detached {
            try AtriaHistoricalSealedCatalogMaterializer.materializeNext(
                catalogStore: fixture.store,
                archiveRoot: fixture.root,
                aggregateDirectoryURL: fixture.aggregates,
                manifestDirectoryURL: fixture.manifests,
                now: now
            )
        }.value
    }

    /// The crash-at-seal shape: replace the committed pair with a coherent
    /// pair built from altered rows, leaving catalog and retained raw intact.
    /// The altered rows keep the original timestamps and differ only in
    /// payload, so the divergence is a pure content-digest divergence — the
    /// axis the persisted scan record then carries forward.
    private func makeDivergentPair(_ fixture: Fixture) throws {
        let aggregateURL = fixture.aggregates.appendingPathComponent(
            "aggregate-\(fixture.chunkID).json"
        )
        let manifestURL = fixture.manifests.appendingPathComponent(
            "manifest-\(fixture.chunkID).json"
        )
        try FileManager.default.removeItem(at: aggregateURL)
        try FileManager.default.removeItem(at: manifestURL)
        let alteredURL = fixture.root.appendingPathComponent(
            "altered-\(UUID().uuidString).jsonl"
        )
        try write(
            [
                record(unix: 1_800_000_000, hr: 95),
                record(unix: 1_800_000_001, hr: 96),
            ],
            to: alteredURL
        )
        let proof = try AtriaHistoricalAggregateBuilder
            .buildRetainedRawShadowProof(
                sourceURL: alteredURL,
                chunkID: fixture.chunkID,
                createdAt: Date(timeIntervalSince1970: 5_000)
            )
        _ = try AtriaHistoricalRetentionTransaction(
            now: { Date(timeIntervalSince1970: 5_001) },
            semanticVerifier: AtriaHistoricalAggregateBuilder.verify
        ).commitRetainedRawShadow(.init(
            transactionID: fixture.chunkID,
            sourceURL: alteredURL,
            aggregateDirectoryURL: fixture.aggregates,
            manifestDirectoryURL: fixture.manifests,
            proof: proof
        ))
        try FileManager.default.removeItem(at: alteredURL)
    }

    // MARK: - Evidence and record helpers

    private func refreshedEvidence(_ fixture: Fixture) throws -> (
        catalog: AtriaHistoricalArchiveCatalog,
        catalogSnapshotSHA256: String,
        streamed: AtriaHistoricalAggregateReader.StreamedWholeArchiveDigest
    ) {
        let catalog = try fixture.store.snapshotVerifiedAgainstFiles()
        let catalogData = try AtriaHistoricalActivityInspectionProofFactory
            .canonicalCatalogData(catalog)
        let streamed = try XCTUnwrap(AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: fixture.aggregates,
            manifestDirectoryURL: fixture.manifests
        ).streamedWholeArchiveDigest(
            limits: AtriaHistoricalAggregateReader.LoadLimits
                .unboundedConsumerProjection
        ))
        XCTAssertEqual(streamed.diagnostics.rejectedManifests, 0)
        return (
            catalog,
            AtriaHistoricalDrainCompletionGenerationStore.sha256(catalogData),
            streamed
        )
    }

    private func loadSnapshot(
        _ fixture: Fixture
    ) -> AtriaHistoricalAggregateReader.Snapshot {
        AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: fixture.aggregates,
            manifestDirectoryURL: fixture.manifests
        ).load()
    }

    private func fullScanStore(
        _ fixture: Fixture
    ) -> AtriaHistoricalFullScanCompletionStore {
        .init(directoryURL: fixture.root.appendingPathComponent(
            "full-scan-completions"
        ))
    }

    private func makeFactory(
        _ fixture: Fixture
    ) -> AtriaHistoricalActivityInspectionProofFactory {
        .init(completionStore: .init(
            directoryURL: fixture.root.appendingPathComponent(
                "drain-completions"
            )
        ))
    }

    private func mintScanRecord(
        generation: UInt64,
        sourceRawSHA256: String,
        sourceFirstTimestamp: Date,
        sourceLastTimestamp: Date,
        observedArchiveFirstTimestamp: Date,
        catalogGeneration: UInt64,
        catalogSnapshotSHA256: String,
        aggregateSnapshotSHA256: String,
        chunkID: String
    ) -> AtriaHistoricalFullScanCompletionStore.Record {
        .init(
            version: AtriaHistoricalFullScanCompletionStore.Record
                .currentVersion,
            generation: generation,
            transportGeneration: 7,
            transportNonce: "nonce-crash-at-seal",
            peripheralIdentifier: "peripheral-1",
            strapIdentity: "strap-1",
            cursorWatermark: cursorWatermark,
            terminalAt: cursorWatermark.addingTimeInterval(1),
            sourceChunkID: chunkID,
            sourceRawSHA256: sourceRawSHA256,
            sourceFirstTimestamp: sourceFirstTimestamp,
            sourceLastTimestamp: sourceLastTimestamp,
            observedArchiveFirstTimestamp: observedArchiveFirstTimestamp,
            catalogGeneration: catalogGeneration,
            catalogSnapshotSHA256: catalogSnapshotSHA256,
            aggregateSnapshotSHA256: aggregateSnapshotSHA256
        )
    }

    // MARK: - Raw rows

    private func write(
        _ records: [HistoricalArchive.Record],
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0a)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func record(unix: UInt32, hr: Int = 70) -> HistoricalArchive.Record {
        HistoricalArchive.Record(
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
            whoofHR17: hr,
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
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalCrashAtSealRepairTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(url)
        return url
    }
}
