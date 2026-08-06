import XCTest
@testable import Atria

final class AtriaHistoricalAggregateReaderTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDownWithError() throws {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories.removeAll()
    }

    func testReaderAcceptsOnlyManifestCommittedAggregateAndExposesChartLoadBasis() throws {
        let fixture = try committedFixture()
        let orphan = fixture.aggregates.appendingPathComponent("aggregate-orphan.json")
        try Data("{}".utf8).write(to: orphan)
        let reader = AtriaHistoricalAggregateReader(aggregateDirectoryURL: fixture.aggregates,
                                                    manifestDirectoryURL: fixture.manifests)

        let snapshot = reader.load()
        let points = reader.heartRateChartPoints(snapshot: snapshot,
                                                since: start.addingTimeInterval(-1),
                                                until: start.addingTimeInterval(60))
        let basis = reader.loadBasis(snapshot: snapshot,
                                     since: start.addingTimeInterval(-1),
                                     until: start.addingTimeInterval(60))

        XCTAssertEqual(snapshot.diagnostics.committedManifests, 1)
        XCTAssertEqual(snapshot.diagnostics.acceptedAggregates, 1)
        XCTAssertEqual(snapshot.diagnostics.rejectedManifests, 0)
        XCTAssertEqual(points, [.init(minuteStart: start,
                                      averageBPM: 70,
                                      minimumBPM: 60,
                                      maximumBPM: 80,
                                      sampleCount: 2)])
        XCTAssertEqual(basis.terminalBPMSeconds, [80: 10])
        XCTAssertEqual(basis.transitionHalfBPMSeconds, [140: 10])
    }

    func testTamperedAggregateIsRejectedEvenWhenManifestStillExists() throws {
        let fixture = try committedFixture()
        let aggregateURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: fixture.aggregates,
                                                    includingPropertiesForKeys: nil).first
        )
        let handle = try FileHandle(forWritingTo: aggregateURL)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x20]))
        try handle.close()
        let reader = AtriaHistoricalAggregateReader(aggregateDirectoryURL: fixture.aggregates,
                                                    manifestDirectoryURL: fixture.manifests)

        let snapshot = reader.load()

        XCTAssertTrue(snapshot.aggregates.isEmpty)
        XCTAssertEqual(snapshot.diagnostics.rejectedManifests, 1)
    }

    func testOutOfRangeManifestSkipsAggregateBeforeHashOrDecode() throws {
        let fixture = try committedFixture()
        let aggregateURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: fixture.aggregates,
                                                    includingPropertiesForKeys: nil).first
        )
        // If the reader touched this aggregate it would reject the manifest.
        // The manifest's source range is enough to exclude it first.
        try Data("not-json".utf8).write(to: aggregateURL)
        let reader = AtriaHistoricalAggregateReader(aggregateDirectoryURL: fixture.aggregates,
                                                    manifestDirectoryURL: fixture.manifests)

        let snapshot = reader.load(since: start.addingTimeInterval(601))

        XCTAssertTrue(snapshot.aggregates.isEmpty)
        XCTAssertEqual(snapshot.diagnostics.committedManifests, 1)
        XCTAssertEqual(snapshot.diagnostics.acceptedAggregates, 0)
        XCTAssertEqual(snapshot.diagnostics.rejectedManifests, 0)
    }

    func testBoundedPagesReachArbitraryOlderAggregatesWithoutRereadingNewerPayloads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalAggregateReaderPageTests")
            .appendingPathComponent(UUID().uuidString)
        let aggregates = root.appendingPathComponent("aggregates")
        let manifests = root.appendingPathComponent("manifests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)

        for index in 0..<5 {
            let anchor = start.addingTimeInterval(Double(index) * 86_400)
            let source = root.appendingPathComponent("source-\(index).jsonl")
            let raw = Data("{\"index\":\(index)}\n{\"end\":true}\n".utf8)
            try raw.write(to: source)
            let aggregate = makeAggregate(
                digest: AtriaHistoricalRetentionTransaction.sha256(of: raw),
                bytes: UInt64(raw.count),
                chunkID: "page-chunk-\(index)",
                anchor: anchor
            )
            _ = try AtriaHistoricalRetentionTransaction(
                now: { anchor.addingTimeInterval(1_000) },
                semanticVerifier: { _, _, _ in true }
            ).commit(.init(transactionID: "page-\(index)",
                           sourceURL: source,
                           aggregateDirectoryURL: aggregates,
                           manifestDirectoryURL: manifests,
                           aggregate: aggregate,
                           semanticParityReceipt: AtriaHistoricalAggregateBuilder
                            .semanticParityReceipt(for: aggregate),
                           deleteSourceAfterCommit: false))
        }

        let reader = AtriaHistoricalAggregateReader(aggregateDirectoryURL: aggregates,
                                                    manifestDirectoryURL: manifests)
        let limits = AtriaHistoricalAggregateReader.LoadLimits(
            maximumManifestCount: 20,
            maximumManifestBytes: 64 * 1_024,
            maximumAggregateBytes: 2 * 1_024 * 1_024,
            maximumTotalAggregateBytes: 4 * 1_024 * 1_024
        )
        let first = reader.loadPage(maximumAggregateCount: 2, limits: limits)
        let second = reader.loadPage(after: try XCTUnwrap(first.nextCursor),
                                     maximumAggregateCount: 2,
                                     limits: limits)
        let third = reader.loadPage(after: try XCTUnwrap(second.nextCursor),
                                    maximumAggregateCount: 2,
                                    limits: limits)

        XCTAssertEqual(first.snapshot.aggregates.map(\.source.chunkID),
                       ["page-chunk-4", "page-chunk-3"])
        XCTAssertEqual(second.snapshot.aggregates.map(\.source.chunkID),
                       ["page-chunk-2", "page-chunk-1"])
        XCTAssertEqual(third.snapshot.aggregates.map(\.source.chunkID), ["page-chunk-0"])
        XCTAssertTrue(first.hasMore)
        XCTAssertTrue(second.hasMore)
        XCTAssertFalse(third.hasMore)

        let index = reader.loadCommittedChunkIDs(maximumManifestCount: 20,
                                                 pageSize: 2)
        XCTAssertFalse(index.limitExceeded)
        XCTAssertEqual(index.rejectedManifests, 0)
        XCTAssertEqual(index.chunkIDs, Set((0..<5).map { "page-chunk-\($0)" }))

        let bounded = reader.loadCommittedChunkIDs(maximumManifestCount: 4,
                                                   pageSize: 2)
        XCTAssertTrue(bounded.limitExceeded)
        XCTAssertTrue(bounded.chunkIDs.isEmpty)
    }

    func testTamperedAggregateInOlderPageIsRejectedAndCannotLeakThroughCursor() throws {
        let fixture = try committedFixture()
        let reader = AtriaHistoricalAggregateReader(aggregateDirectoryURL: fixture.aggregates,
                                                    manifestDirectoryURL: fixture.manifests)
        let aggregateURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: fixture.aggregates,
            includingPropertiesForKeys: nil
        ).first)
        var data = try Data(contentsOf: aggregateURL)
        data[data.startIndex] ^= 0x01
        try data.write(to: aggregateURL)

        let page = reader.loadPage(
            maximumAggregateCount: 1,
            limits: .init(maximumManifestCount: 10,
                          maximumManifestBytes: 64 * 1_024,
                          maximumAggregateBytes: 2 * 1_024 * 1_024,
                          maximumTotalAggregateBytes: 2 * 1_024 * 1_024)
        )

        XCTAssertTrue(page.snapshot.aggregates.isEmpty)
        XCTAssertEqual(page.snapshot.diagnostics.rejectedManifests, 1)
        XCTAssertNotNil(page.nextCursor, "the bad source is advanced past, never retried as truth")
    }

    func testRRSufficientStatisticsBridgeAdjacentEpochsExactly() {
        let first = rrEpoch(start: start, intervals: [800, 900])
        let second = rrEpoch(start: start.addingTimeInterval(300), intervals: [1000, 850])
        let aggregate = makeAggregate(digest: String(repeating: "a", count: 64),
                                      bytes: 1,
                                      rrEpochs: [first, second])
        let snapshot = AtriaHistoricalAggregateReader.Snapshot(
            aggregates: [aggregate],
            diagnostics: .init(committedManifests: 1,
                               acceptedAggregates: 1,
                               rejectedManifests: 0)
        )
        let reader = AtriaHistoricalAggregateReader(aggregateDirectoryURL: URL(fileURLWithPath: "/tmp"),
                                                    manifestDirectoryURL: URL(fileURLWithPath: "/tmp"))

        let stats = reader.rrStatisticsForCompleteEpochs(
            snapshot: snapshot,
            since: start,
            until: start.addingTimeInterval(600)
        )

        XCTAssertEqual(stats.beatCount, 4)
        XCTAssertEqual(stats.sumNNMilliseconds, 3_550)
        XCTAssertEqual(stats.adjacentDifferenceCount, 3)
        // 800→900, epoch bridge 900→1000, 1000→850.
        XCTAssertEqual(stats.sumAdjacentDifferenceSquaredMilliseconds,
                       100 * 100 + 100 * 100 + 150 * 150,
                       accuracy: 0.000_001)
        XCTAssertEqual(stats.adjacentDifferenceOver50Count, 3)
    }

    private struct Fixture {
        let aggregates: URL
        let manifests: URL
    }

    private func committedFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalAggregateReaderTests")
            .appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source.jsonl")
        let aggregates = root.appendingPathComponent("aggregates")
        let manifests = root.appendingPathComponent("manifests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let raw = Data("{\"one\":1}\n{\"two\":2}\n".utf8)
        try raw.write(to: source)
        temporaryDirectories.append(root)
        let digest = AtriaHistoricalRetentionTransaction.sha256(of: raw)
        let aggregate = makeAggregate(digest: digest, bytes: UInt64(raw.count))
        let receipt = AtriaHistoricalAggregateBuilder.semanticParityReceipt(for: aggregate)
        let transaction = AtriaHistoricalRetentionTransaction(
            now: { self.start.addingTimeInterval(100) },
            semanticVerifier: { _, _, _ in true }
        )
        _ = try transaction.commit(.init(transactionID: "reader-test",
                                         sourceURL: source,
                                         aggregateDirectoryURL: aggregates,
                                         manifestDirectoryURL: manifests,
                                         aggregate: aggregate,
                                         semanticParityReceipt: receipt,
                                         deleteSourceAfterCommit: false))
        return Fixture(aggregates: aggregates, manifests: manifests)
    }

    private func makeAggregate(digest: String,
                               bytes: UInt64,
                               chunkID: String = "reader-chunk",
                               anchor: Date? = nil,
                               rrEpochs: [AtriaHistoricalAggregateChunk.RREpoch] = []) -> AtriaHistoricalAggregateChunk {
        let start = anchor ?? self.start
        let minute = AtriaHistoricalAggregateChunk.HeartRateMinute(
            minuteStart: start,
            sampleCount: 2,
            sumBPM: 140,
            minimumBPM: 60,
            maximumBPM: 80,
            samplesByBPM: [60: 1, 80: 1],
            terminalBPMSeconds: [80: 10],
            transitionHalfBPMSeconds: [140: 10],
            coveredSeconds: 10,
            droppedGapSeconds: 0,
            firstSampleUnix: start.timeIntervalSince1970,
            firstSampleBPM: 60,
            lastSampleUnix: start.addingTimeInterval(10).timeIntervalSince1970,
            lastSampleBPM: 80
        )
        let rrCount = rrEpochs.reduce(0) { $0 + $1.acceptedBeatCount }
        let rrSum = rrEpochs.reduce(Int64(0)) { $0 + $1.sumNNMilliseconds }
        return .init(
            schema: AtriaHistoricalAggregateChunk.currentSchema,
            createdAt: start.addingTimeInterval(100),
            source: .init(chunkID: chunkID,
                          rawSHA256: digest,
                          rawByteCount: bytes,
                          rawRowCount: 2,
                          firstTimestamp: start,
                          lastTimestamp: start.addingTimeInterval(600),
                          decoderSchema: HistoricalArchive.schema,
                          validatedLayouts: [HistoricalArchive.layoutVersion]),
            heartRateMinutes: [minute],
            rrEpochs: rrEpochs,
            motionEpochs: [],
            materializedProjections: [],
            parity: .init(rawRows: 2,
                          decodedRows: 2,
                          undecodableRowsRetainedRaw: 0,
                          metricUsableRows: 2,
                          heartRateSamples: 2,
                          heartRateSumBPM: 140,
                          acceptedRRBeats: rrCount,
                          acceptedRRSumMilliseconds: rrSum,
                          validatedGravityRows: 0,
                          motionEpochs: 0,
                          projectionReceipts: 0)
        )
    }

    private func rrEpoch(start: Date, intervals: [Int]) -> AtriaHistoricalAggregateChunk.RREpoch {
        let differences = zip(intervals, intervals.dropFirst()).map { $1 - $0 }
        return .init(start: start,
                     end: start.addingTimeInterval(300),
                     sourceRecordCount: intervals.count,
                     acceptedBeatCount: intervals.count,
                     rejectedBeatCount: 0,
                     sumNNMilliseconds: intervals.reduce(Int64(0)) { $0 + Int64($1) },
                     sumNNSquaredMilliseconds: intervals.reduce(0) { $0 + Double($1 * $1) },
                     adjacentDifferenceCount: differences.count,
                     sumAdjacentDifferenceSquaredMilliseconds: differences.reduce(0) {
                         $0 + Double($1 * $1)
                     },
                     adjacentDifferenceOver50Count: differences.filter { abs($0) > 50 }.count,
                     firstNNMilliseconds: intervals.first,
                     lastNNMilliseconds: intervals.last,
                     coverageSeconds: 299,
                     maximumGapSeconds: 1,
                     projectionFingerprint: UUID().uuidString,
                     provenance: "verified_whoop4_historical_v24")
    }
}
