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
