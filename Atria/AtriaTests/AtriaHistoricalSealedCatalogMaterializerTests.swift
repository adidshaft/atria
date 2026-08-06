import XCTest
@testable import Atria

final class AtriaHistoricalSealedCatalogMaterializerTests: XCTestCase {
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

    func testOneInvocationMaterializesExactlyOneChunkAndRetainsEveryRawSource() async throws {
        let fixture = try legacyFixture(
            rowsBySource: [
                [record(unix: 1_800_000_000), record(unix: 1_800_000_001)],
                [record(unix: 1_800_000_100), record(unix: 1_800_000_101)],
            ]
        )
        let rawBefore = try fixture.sources.map {
            try Data(contentsOf: $0)
        }

        let first = try await materializeNext(fixture, now: Date(timeIntervalSince1970: 2_100))

        XCTAssertEqual(first.materializedChunkID, "legacy-legacy-a")
        XCTAssertEqual(first.remainingChunkCount, 1)
        XCTAssertEqual(
            AtriaHistoricalAggregateReader(
                aggregateDirectoryURL: fixture.aggregates,
                manifestDirectoryURL: fixture.manifests
            ).load().aggregates.map(\.source.chunkID),
            ["legacy-legacy-a"]
        )
        XCTAssertEqual(try fixture.sources.map { try Data(contentsOf: $0) }, rawBefore)

        let second = try await materializeNext(fixture, now: Date(timeIntervalSince1970: 9_900))
        XCTAssertEqual(second.materializedChunkID, "legacy-legacy-b")
        XCTAssertTrue(second.isComplete)
        XCTAssertEqual(try fixture.sources.map { try Data(contentsOf: $0) }, rawBefore)

        let noOp = try await materializeNext(fixture, now: Date(timeIntervalSince1970: 20_000))
        XCTAssertNil(noOp.materializedChunkID)
        XCTAssertTrue(noOp.isComplete)
        XCTAssertEqual(try fixture.sources.map { try Data(contentsOf: $0) }, rawBefore)
    }

    func testCrashAfterMetadataPublicationRetriesWithStableAggregateIdentity() async throws {
        let fixture = try legacyFixture(
            rowsBySource: [[
                record(unix: 1_800_000_000),
                record(unix: 1_800_000_001),
            ]]
        )
        enum Injected: Error { case crash }

        do {
            _ = try await Task.detached {
                try AtriaHistoricalSealedCatalogMaterializer.materializeNext(
                    catalogStore: fixture.store,
                    archiveRoot: fixture.root,
                    aggregateDirectoryURL: fixture.aggregates,
                    manifestDirectoryURL: fixture.manifests,
                    now: Date(timeIntervalSince1970: 2_100),
                    checkpoint: {
                        if $0 == .metadataPublished("legacy-legacy-a") {
                            throw Injected.crash
                        }
                    }
                )
            }.value
            XCTFail("expected injected crash")
        } catch Injected.crash {}

        let metadataAfterCrash = try XCTUnwrap(
            try fixture.store.snapshot().chunks.first { $0.id == "legacy-legacy-a" }
        )
        XCTAssertNotNil(metadataAfterCrash.rowCount)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.manifests
                .appendingPathComponent("manifest-legacy-legacy-a.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sources[0].path))

        let retry = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 99_000)
        )
        XCTAssertTrue(retry.isComplete)
        let aggregate = try XCTUnwrap(
            AtriaHistoricalAggregateReader(
                aggregateDirectoryURL: fixture.aggregates,
                manifestDirectoryURL: fixture.manifests
            ).load().aggregates.first
        )
        XCTAssertEqual(aggregate.createdAt, metadataAfterCrash.sealedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sources[0].path))
    }

    func testCrashAfterAggregatePublicationRetriesCommittedShadowIdempotently() async throws {
        let fixture = try legacyFixture(
            rowsBySource: [[
                record(unix: 1_800_000_000),
                record(unix: 1_800_000_001),
            ]]
        )
        enum Injected: Error { case crash }

        do {
            _ = try await Task.detached {
                try AtriaHistoricalSealedCatalogMaterializer.materializeNext(
                    catalogStore: fixture.store,
                    archiveRoot: fixture.root,
                    aggregateDirectoryURL: fixture.aggregates,
                    manifestDirectoryURL: fixture.manifests,
                    now: Date(timeIntervalSince1970: 2_100),
                    checkpoint: {
                        if $0 == .aggregatePublished("legacy-legacy-a") {
                            throw Injected.crash
                        }
                    }
                )
            }.value
            XCTFail("expected injected crash")
        } catch Injected.crash {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sources[0].path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.manifests
                .appendingPathComponent("manifest-legacy-legacy-a.json").path
        ))

        let retry = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 99_000)
        )
        XCTAssertNil(retry.materializedChunkID)
        XCTAssertTrue(retry.isComplete)
        XCTAssertEqual(retry.aggregateCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sources[0].path))
    }

    func testConsecutiveMixedLegacyChunksConvergeWhileEveryRawStaysAuthoritative() async throws {
        let root = try temporaryDirectory()
        let sources = [
            root.appendingPathComponent("mixed-a.jsonl"),
            root.appendingPathComponent("mixed-b.jsonl"),
        ]
        try writeMixed(
            [record(unix: 1_800_000_000)],
            unknownRows: 2,
            to: sources[0]
        )
        try writeMixed(
            [record(unix: 1_800_000_100), record(unix: 1_800_000_101)],
            unknownRows: 1,
            to: sources[1]
        )
        let rawBefore = try sources.map { try Data(contentsOf: $0) }
        let ids = IdentifierSource(["legacy-a", "legacy-b", "active-a"])
        let store = AtriaHistoricalArchiveCatalogStore(
            rootURL: root,
            makeIdentifier: ids.next
        )
        _ = try store.loadOrRecover(
            discoveredLegacyURLs: sources,
            now: Date(timeIntervalSince1970: 2_000)
        )
        let fixture = Fixture(
            root: root,
            store: store,
            sources: sources,
            aggregates: root.appendingPathComponent("aggregates-v2"),
            manifests: root.appendingPathComponent("retention-manifests-v2")
        )

        let first = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 3_000)
        )
        XCTAssertEqual(first.materializedChunkID, "legacy-legacy-a")
        XCTAssertEqual(first.remainingChunkCount, 1)
        let second = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 4_000)
        )
        XCTAssertEqual(second.materializedChunkID, "legacy-legacy-b")
        XCTAssertTrue(second.isComplete)

        let aggregates = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: fixture.aggregates,
            manifestDirectoryURL: fixture.manifests
        ).load().aggregates.sorted {
            $0.source.chunkID < $1.source.chunkID
        }
        XCTAssertEqual(
            aggregates.map(\.parity.undecodableRowsRetainedRaw),
            [2, 1]
        )
        XCTAssertEqual(try sources.map { try Data(contentsOf: $0) }, rawBefore)
        XCTAssertTrue(aggregates.allSatisfy { !$0.authorizesRawRetirement })
    }

    func testBacklogDefersUnrelatedGlobalReaderFailureButCompletionFailsClosed() async throws {
        let fixture = try legacyFixture(
            rowsBySource: [
                [record(unix: 1_800_000_000)],
                [record(unix: 1_800_000_100)],
            ]
        )
        try FileManager.default.createDirectory(
            at: fixture.manifests,
            withIntermediateDirectories: true
        )
        let corruptManifest = fixture.manifests
            .appendingPathComponent("manifest-unrelated-corrupt.json")
        try Data("{\"not\":\"a committed manifest\"}".utf8).write(
            to: corruptManifest
        )

        // A pending backlog turn must touch only its selected source/artifacts.
        // An unrelated committed-catalog audit cannot multiply every turn into
        // an O(total archive) read.
        let first = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 3_000)
        )
        XCTAssertEqual(first.materializedChunkID, "legacy-legacy-a")
        XCTAssertEqual(first.remainingChunkCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sources[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sources[1].path))

        // The last bounded turn is not allowed to report complete until one
        // global reader pass validates every committed manifest.
        do {
            _ = try await materializeNext(
                fixture,
                now: Date(timeIntervalSince1970: 4_000)
            )
            XCTFail("completion must fail closed on the corrupt manifest")
        } catch AtriaHistoricalSealedCatalogMaterializer
            .MaterializationError.rejectedAggregateCatalog {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sources[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sources[1].path))
    }

    func testDigestOnlySizeRotationAndOneRowSourceBecomeComplete() async throws {
        let root = try temporaryDirectory()
        let aggregates = root.appendingPathComponent("aggregates-v2")
        let manifests = root.appendingPathComponent("retention-manifests-v2")
        let ids = IdentifierSource(["active-a", "active-b"])
        let store = AtriaHistoricalArchiveCatalogStore(
            rootURL: root,
            maximumActiveBytes: 1,
            makeIdentifier: ids.next
        )
        let created = Date(timeIntervalSince1970: 2_000)
        _ = try store.loadOrRecover(discoveredLegacyURLs: [], now: created)
        let source = try store.writableChunkURL(now: created)
        try write([record(unix: 1_800_000_000)], to: source)
        try store.recordAppendCompleted(at: source)
        _ = try store.writableChunkURL(now: created.addingTimeInterval(1))

        let partial = try XCTUnwrap(
            try store.snapshot().chunks.first { $0.id == "active-a" }
        )
        XCTAssertNotNil(partial.contentSHA256)
        XCTAssertNil(partial.rowCount)
        XCTAssertNil(partial.firstTimestamp)
        XCTAssertNil(partial.lastTimestamp)

        let report = try await Task.detached {
            try AtriaHistoricalSealedCatalogMaterializer.materializeNext(
                catalogStore: store,
                archiveRoot: root,
                aggregateDirectoryURL: aggregates,
                manifestDirectoryURL: manifests,
                now: Date(timeIntervalSince1970: 99_000)
            )
        }.value

        XCTAssertTrue(report.isComplete)
        let complete = try XCTUnwrap(
            try store.snapshot().chunks.first { $0.id == "active-a" }
        )
        XCTAssertEqual(complete.rowCount, 1)
        XCTAssertEqual(complete.firstTimestamp, complete.lastTimestamp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCompressedLogicalRawSourceMaterializesAndRemainsAuthoritative() async throws {
        let fixture = try legacyFixture(
            rowsBySource: [[
                record(unix: 1_800_000_000),
                record(unix: 1_800_000_001),
            ]]
        )
        let chunkID = "legacy-legacy-a"
        let source = fixture.sources[0]
        let build = try AtriaHistoricalAggregateBuilder.build(
            sourceURL: source,
            chunkID: chunkID,
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        try fixture.store.recordSealedMetadata(
            chunkID: chunkID,
            rowCount: build.aggregate.source.rawRowCount,
            firstTimestamp: build.aggregate.source.firstTimestamp,
            lastTimestamp: build.aggregate.source.lastTimestamp,
            contentSHA256: build.aggregate.source.rawSHA256
        )
        let active = try fixture.store.activeChunkDescriptor().fileURL
        let compressed = try AtriaHistoricalSealedJSONLCompression().commit(
            chunkID: chunkID,
            sourceURL: source,
            archiveRootURL: fixture.root,
            activeSourceURL: active
        )
        try fixture.store.recordCompressedStorage(
            chunkID: chunkID,
            manifestURL: compressed.manifestURL,
            artifactURL: compressed.artifactURL
        )

        let catalogChunk = try XCTUnwrap(
            try fixture.store.snapshot().chunks.first { $0.id == chunkID }
        )
        XCTAssertNotNil(catalogChunk.compressedStorage)
        XCTAssertNotEqual(catalogChunk.byteCount, catalogChunk.storedByteCount)

        let report = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 3_000)
        )

        XCTAssertEqual(report.materializedChunkID, chunkID)
        XCTAssertTrue(report.isComplete)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: compressed.artifactURL.path)
        )
        let aggregate = try XCTUnwrap(
            AtriaHistoricalAggregateReader(
                aggregateDirectoryURL: fixture.aggregates,
                manifestDirectoryURL: fixture.manifests
            ).load().aggregates.first
        )
        XCTAssertEqual(aggregate.source.rawSHA256, compressed.manifest.decodedSHA256)
        XCTAssertEqual(
            aggregate.source.rawByteCount,
            compressed.manifest.decodedByteCount
        )
    }

    func testMalformedSelectedSourceFailsWithoutCatalogOrRawMutation() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("malformed.jsonl")
        try Data("{\"torn\":true".utf8).write(to: source)
        let ids = IdentifierSource(["legacy-a", "active-a"])
        let store = AtriaHistoricalArchiveCatalogStore(
            rootURL: root,
            makeIdentifier: ids.next
        )
        let before = try store.loadOrRecover(
            discoveredLegacyURLs: [source],
            now: Date(timeIntervalSince1970: 2_000)
        )

        do {
            _ = try await Task.detached {
                try AtriaHistoricalSealedCatalogMaterializer.materializeNext(
                    catalogStore: store,
                    archiveRoot: root,
                    aggregateDirectoryURL: root.appendingPathComponent("aggregates-v2"),
                    manifestDirectoryURL: root.appendingPathComponent("retention-manifests-v2"),
                    now: Date(timeIntervalSince1970: 3_000)
                )
            }.value
            XCTFail("expected torn-row failure")
        } catch AtriaHistoricalAggregateBuilder.BuildError.tornTrailingRow {}

        XCTAssertEqual(try store.snapshot(), before)
        XCTAssertEqual(try Data(contentsOf: source), Data("{\"torn\":true".utf8))
    }

    // MARK: - Crash-at-seal divergent committed pair repair (2026-08-05)

    func testDivergentCommittedPairIsQuarantinedRebuiltAndConverges() async throws {
        let (fixture, chunkID) = try await divergentPairFixture()
        let rawBefore = try Data(contentsOf: fixture.sources[0])
        let generationBefore = try fixture.store.snapshot().generation
        let artifacts = artifactURLs(fixture, chunkID: chunkID)
        let divergentAggregateBytes = try Data(contentsOf: artifacts.aggregate)
        let divergentManifestBytes = try Data(contentsOf: artifacts.manifest)
        let digestBefore = streamedDigest(fixture)

        let report = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 9_000)
        )

        XCTAssertEqual(report.materializedChunkID, chunkID)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.aggregateCount, 1)

        let quarantined = try quarantinedFilenames(fixture)
        XCTAssertEqual(quarantined.count, 2)
        let quarantinedAggregate = try XCTUnwrap(quarantined.first {
            $0.hasPrefix("quarantined-aggregate-\(chunkID)-")
        })
        let quarantinedManifest = try XCTUnwrap(quarantined.first {
            $0.hasPrefix("quarantined-manifest-\(chunkID)-")
        })
        XCTAssertEqual(
            try Data(contentsOf: quarantineDirectory(fixture)
                .appendingPathComponent(quarantinedAggregate)),
            divergentAggregateBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: quarantineDirectory(fixture)
                .appendingPathComponent(quarantinedManifest)),
            divergentManifestBytes
        )

        let accepted = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: fixture.aggregates,
            manifestDirectoryURL: fixture.manifests
        ).load()
        XCTAssertEqual(accepted.diagnostics.rejectedManifests, 0)
        let rebuilt = try XCTUnwrap(accepted.aggregates.first)
        let chunk = try XCTUnwrap(
            try fixture.store.snapshot().chunks.first { $0.id == chunkID }
        )
        XCTAssertEqual(rebuilt.source.rawSHA256, chunk.contentSHA256)
        XCTAssertEqual(rebuilt.source.rawByteCount, chunk.byteCount)
        XCTAssertEqual(rebuilt.source.rawRowCount, chunk.rowCount)

        XCTAssertEqual(try Data(contentsOf: fixture.sources[0]), rawBefore)
        XCTAssertGreaterThan(
            try fixture.store.snapshot().generation,
            generationBefore
        )
        XCTAssertNotEqual(streamedDigest(fixture), digestBefore)
    }

    func testDivergentPairRepairFailsClosedWhenRawDoesNotMatchCatalog() async throws {
        let (fixture, chunkID) = try await divergentPairFixture()
        var tampered = try Data(contentsOf: fixture.sources[0])
        tampered.append(Data("{\"tampered\":true}\n".utf8))
        try tampered.write(to: fixture.sources[0])
        let generationBefore = try fixture.store.snapshot().generation
        let artifacts = artifactURLs(fixture, chunkID: chunkID)
        let aggregateBytes = try Data(contentsOf: artifacts.aggregate)
        let manifestBytes = try Data(contentsOf: artifacts.manifest)

        do {
            _ = try await materializeNext(
                fixture,
                now: Date(timeIntervalSince1970: 9_000)
            )
            XCTFail("a raw/catalog divergence must fail closed")
        } catch AtriaHistoricalSealedCatalogMaterializer
            .MaterializationError.repairSourceMismatch(let id) {
            XCTAssertEqual(id, chunkID)
        }

        XCTAssertEqual(try Data(contentsOf: artifacts.aggregate), aggregateBytes)
        XCTAssertEqual(try Data(contentsOf: artifacts.manifest), manifestBytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: quarantineDirectory(fixture).path
        ))
        XCTAssertEqual(
            try fixture.store.snapshot().generation,
            generationBefore
        )
        XCTAssertEqual(try Data(contentsOf: fixture.sources[0]), tampered)
    }

    func testCrashAfterRepairGenerationAdvanceRetriesQuarantineIdempotently() async throws {
        let (fixture, chunkID) = try await divergentPairFixture()
        let artifacts = artifactURLs(fixture, chunkID: chunkID)
        enum Injected: Error { case crash }

        do {
            _ = try await Task.detached {
                try AtriaHistoricalSealedCatalogMaterializer.materializeNext(
                    catalogStore: fixture.store,
                    archiveRoot: fixture.root,
                    aggregateDirectoryURL: fixture.aggregates,
                    manifestDirectoryURL: fixture.manifests,
                    now: Date(timeIntervalSince1970: 9_000),
                    checkpoint: {
                        if $0 == .repairGenerationAdvanced(chunkID) {
                            throw Injected.crash
                        }
                    }
                )
            }.value
            XCTFail("expected injected crash")
        } catch Injected.crash {}

        // The bump is durable but no artifact moved yet.
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.aggregate.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.manifest.path))

        let retry = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 9_100)
        )
        XCTAssertEqual(retry.materializedChunkID, chunkID)
        XCTAssertTrue(retry.isComplete)

        let accepted = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: fixture.aggregates,
            manifestDirectoryURL: fixture.manifests
        ).load()
        XCTAssertEqual(accepted.aggregates.count, 1)
        XCTAssertEqual(accepted.diagnostics.rejectedManifests, 0)
        XCTAssertEqual(try quarantinedFilenames(fixture).count, 2)
    }

    func testOrphanDivergentManifestIsClaimedAndConverges() async throws {
        let (fixture, chunkID) = try await divergentPairFixture()
        let artifacts = artifactURLs(fixture, chunkID: chunkID)
        // Crash shape: the aggregate move completed, the manifest move did
        // not. The aggregate's quarantine name is derived from its own bytes
        // at move time, so the resume pass must converge without it.
        let quarantine = quarantineDirectory(fixture)
        try FileManager.default.createDirectory(
            at: quarantine,
            withIntermediateDirectories: true
        )
        let digest = try AtriaHistoricalRetentionTransaction.sha256(
            of: artifacts.aggregate
        )
        try FileManager.default.moveItem(
            at: artifacts.aggregate,
            to: quarantine.appendingPathComponent(
                "quarantined-aggregate-\(chunkID)-\(digest.prefix(16)).json"
            )
        )

        let report = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 9_000)
        )
        XCTAssertEqual(report.materializedChunkID, chunkID)
        XCTAssertTrue(report.isComplete)

        let accepted = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: fixture.aggregates,
            manifestDirectoryURL: fixture.manifests
        ).load()
        XCTAssertEqual(accepted.aggregates.count, 1)
        XCTAssertEqual(accepted.diagnostics.rejectedManifests, 0)
        XCTAssertEqual(try quarantinedFilenames(fixture).count, 2)

        let noOp = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 9_200)
        )
        XCTAssertNil(noOp.materializedChunkID)
        XCTAssertTrue(noOp.isComplete)
    }

    func testDivergentAggregateWithoutManifestIsClaimedBeforeIdentityConflict() async throws {
        let (fixture, chunkID) = try await divergentPairFixture()
        let artifacts = artifactURLs(fixture, chunkID: chunkID)
        try FileManager.default.removeItem(at: artifacts.manifest)

        let report = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 9_000)
        )
        XCTAssertEqual(report.materializedChunkID, chunkID)
        XCTAssertTrue(report.isComplete)

        let quarantined = try quarantinedFilenames(fixture)
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertTrue(try XCTUnwrap(quarantined.first)
            .hasPrefix("quarantined-aggregate-\(chunkID)-"))
        let accepted = AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: fixture.aggregates,
            manifestDirectoryURL: fixture.manifests
        ).load()
        XCTAssertEqual(accepted.aggregates.count, 1)
        XCTAssertEqual(accepted.diagnostics.rejectedManifests, 0)
    }

    func testConsistentCommittedPairIsNeverQuarantined() async throws {
        let fixture = try legacyFixture(
            rowsBySource: [[
                record(unix: 1_800_000_000),
                record(unix: 1_800_000_001),
            ]]
        )
        let first = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 3_000)
        )
        XCTAssertTrue(first.isComplete)
        let generationBefore = try fixture.store.snapshot().generation
        let digestBefore = streamedDigest(fixture)

        let noOp = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 4_000)
        )

        XCTAssertNil(noOp.materializedChunkID)
        XCTAssertTrue(noOp.isComplete)
        XCTAssertEqual(try fixture.store.snapshot().generation, generationBefore)
        XCTAssertEqual(streamedDigest(fixture), digestBefore)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: quarantineDirectory(fixture).path
        ))
    }

    func testRemainingCountIncludesDivergentPairsSoCompletionIsNotReportedEarly() async throws {
        let fixture = try legacyFixture(
            rowsBySource: [
                [record(unix: 1_800_000_000)],
                [record(unix: 1_800_000_100)],
            ]
        )
        _ = try await materializeNext(fixture, now: Date(timeIntervalSince1970: 3_000))
        let healthy = try await materializeNext(fixture, now: Date(timeIntervalSince1970: 3_100))
        XCTAssertTrue(healthy.isComplete)
        try makeDivergentPair(
            fixture,
            chunkID: "legacy-legacy-a",
            alteredRows: [record(unix: 1_800_000_050)],
            createdAt: Date(timeIntervalSince1970: 5_000)
        )
        try makeDivergentPair(
            fixture,
            chunkID: "legacy-legacy-b",
            alteredRows: [record(unix: 1_800_000_150)],
            createdAt: Date(timeIntervalSince1970: 5_000)
        )

        let firstRepair = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 9_000)
        )
        XCTAssertEqual(firstRepair.materializedChunkID, "legacy-legacy-a")
        XCTAssertEqual(firstRepair.remainingChunkCount, 1)
        XCTAssertFalse(firstRepair.isComplete)

        let secondRepair = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 9_100)
        )
        XCTAssertEqual(secondRepair.materializedChunkID, "legacy-legacy-b")
        XCTAssertTrue(secondRepair.isComplete)

        let noOp = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 9_200)
        )
        XCTAssertNil(noOp.materializedChunkID)
        XCTAssertTrue(noOp.isComplete)
        XCTAssertEqual(try quarantinedFilenames(fixture).count, 4)
    }

    func testRebuiltAggregateIdentityPinsToSealedAtNotQuarantinedCreatedAt() async throws {
        let quarantinedCreatedAt = Date(timeIntervalSince1970: 7_777)
        let (fixture, chunkID) = try await divergentPairFixture(
            alteredCreatedAt: quarantinedCreatedAt
        )
        let sealedAt = try XCTUnwrap(
            try fixture.store.snapshot().chunks
                .first { $0.id == chunkID }?.sealedAt
        )
        let wallClock = Date(timeIntervalSince1970: 999_999)

        let report = try await materializeNext(fixture, now: wallClock)

        XCTAssertTrue(report.isComplete)
        let rebuilt = try XCTUnwrap(
            AtriaHistoricalAggregateReader(
                aggregateDirectoryURL: fixture.aggregates,
                manifestDirectoryURL: fixture.manifests
            ).load().aggregates.first
        )
        XCTAssertEqual(rebuilt.createdAt, sealedAt)
        XCTAssertNotEqual(rebuilt.createdAt, quarantinedCreatedAt)
        XCTAssertNotEqual(rebuilt.createdAt, wallClock)
    }

    private struct Fixture: @unchecked Sendable {
        let root: URL
        let store: AtriaHistoricalArchiveCatalogStore
        let sources: [URL]
        let aggregates: URL
        let manifests: URL
    }

    private func legacyFixture(
        rowsBySource: [[HistoricalArchive.Record]]
    ) throws -> Fixture {
        let root = try temporaryDirectory()
        let sources = try rowsBySource.enumerated().map { index, rows in
            let url = root.appendingPathComponent("legacy-\(index).jsonl")
            try write(rows, to: url)
            return url
        }
        let labels = rowsBySource.indices.map {
            "legacy-\(Character(UnicodeScalar(97 + $0)!))"
        } + ["active-a"]
        let ids = IdentifierSource(labels)
        let store = AtriaHistoricalArchiveCatalogStore(
            rootURL: root,
            makeIdentifier: ids.next
        )
        _ = try store.loadOrRecover(
            discoveredLegacyURLs: sources,
            now: Date(timeIntervalSince1970: 2_000)
        )
        return .init(
            root: root,
            store: store,
            sources: sources,
            aggregates: root.appendingPathComponent("aggregates-v2"),
            manifests: root.appendingPathComponent("retention-manifests-v2")
        )
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

    /// A fully materialized single-chunk archive whose committed pair was then
    /// replaced by a coherent pair built from altered rows — the crash-at-seal
    /// shape: the pair verifies against itself while the sealed catalog and
    /// the retained raw disagree with it on every identity axis.
    private func divergentPairFixture(
        alteredCreatedAt: Date = Date(timeIntervalSince1970: 5_000)
    ) async throws -> (fixture: Fixture, chunkID: String) {
        let fixture = try legacyFixture(
            rowsBySource: [[
                record(unix: 1_800_000_000),
                record(unix: 1_800_000_001),
            ]]
        )
        let initial = try await materializeNext(
            fixture,
            now: Date(timeIntervalSince1970: 3_000)
        )
        XCTAssertTrue(initial.isComplete)
        let chunkID = "legacy-legacy-a"
        try makeDivergentPair(
            fixture,
            chunkID: chunkID,
            alteredRows: [
                record(unix: 1_800_000_050),
                record(unix: 1_800_000_051),
                record(unix: 1_800_000_052),
            ],
            createdAt: alteredCreatedAt
        )
        return (fixture, chunkID)
    }

    private func makeDivergentPair(
        _ fixture: Fixture,
        chunkID: String,
        alteredRows: [HistoricalArchive.Record],
        createdAt: Date
    ) throws {
        let artifacts = artifactURLs(fixture, chunkID: chunkID)
        try? FileManager.default.removeItem(at: artifacts.aggregate)
        try? FileManager.default.removeItem(at: artifacts.manifest)
        let alteredURL = fixture.root.appendingPathComponent(
            "altered-\(chunkID)-\(UUID().uuidString).jsonl"
        )
        try write(alteredRows, to: alteredURL)
        let proof = try AtriaHistoricalAggregateBuilder
            .buildRetainedRawShadowProof(
                sourceURL: alteredURL,
                chunkID: chunkID,
                createdAt: createdAt
            )
        _ = try AtriaHistoricalRetentionTransaction(
            now: { createdAt },
            semanticVerifier: AtriaHistoricalAggregateBuilder.verify
        ).commitRetainedRawShadow(.init(
            transactionID: chunkID,
            sourceURL: alteredURL,
            aggregateDirectoryURL: fixture.aggregates,
            manifestDirectoryURL: fixture.manifests,
            proof: proof
        ))
        try FileManager.default.removeItem(at: alteredURL)
    }

    private func artifactURLs(
        _ fixture: Fixture,
        chunkID: String
    ) -> (aggregate: URL, manifest: URL) {
        (
            fixture.aggregates.appendingPathComponent(
                "aggregate-\(chunkID).json"
            ),
            fixture.manifests.appendingPathComponent(
                "manifest-\(chunkID).json"
            )
        )
    }

    private func quarantineDirectory(_ fixture: Fixture) -> URL {
        fixture.root.appendingPathComponent(
            AtriaHistoricalSealedCatalogMaterializer.quarantineDirectoryName
        )
    }

    private func quarantinedFilenames(_ fixture: Fixture) throws -> [String] {
        let url = quarantineDirectory(fixture)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(atPath: url.path)
            .sorted()
    }

    private func streamedDigest(_ fixture: Fixture) -> String? {
        AtriaHistoricalAggregateReader(
            aggregateDirectoryURL: fixture.aggregates,
            manifestDirectoryURL: fixture.manifests
        ).streamedWholeArchiveDigest(
            limits: AtriaHistoricalAggregateReader.LoadLimits
                .unboundedConsumerProjection
        )?.digest
    }

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

    private func writeMixed(
        _ records: [HistoricalArchive.Record],
        unknownRows: Int,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0a)
        }
        for index in 0..<unknownRows {
            data.append(Data("{\"legacyEnvelope\":\(index)}\n".utf8))
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func record(unix: UInt32) -> HistoricalArchive.Record {
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
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalSealedCatalogMaterializerTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(url)
        return url
    }
}
