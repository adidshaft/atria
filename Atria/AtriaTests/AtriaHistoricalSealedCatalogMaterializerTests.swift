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
