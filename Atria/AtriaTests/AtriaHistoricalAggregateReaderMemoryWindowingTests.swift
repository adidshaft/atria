import XCTest
@testable import Atria

/// Hard gate for Phase 2 of the foreground-reopen memory-balloon fix.
///
/// `AtriaHistoricalAggregateReader.streamedWholeArchiveDigest` must produce a
/// digest that is byte-identical to the existing whole-buffer paths — both
/// `AtriaHistoricalActivityInspectionProofFactory.streamedAggregateSnapshotDigest`
/// and hashing `canonicalAggregateSnapshotData` directly — because the
/// persisted drain-completion record's `aggregateSnapshotSHA256` is compared
/// against exactly this digest. If the streaming primitive ever diverges by
/// one byte, every projection would fail closed and defer forever.
final class AtriaHistoricalAggregateReaderMemoryWindowingTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private let day0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let daySeconds: TimeInterval = 86_400

    override func tearDownWithError() throws {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories.removeAll()
    }

    private var limits: AtriaHistoricalAggregateReader.LoadLimits {
        .init(maximumManifestCount: 100,
              maximumManifestBytes: 64 * 1_024,
              maximumAggregateBytes: 2 * 1_024 * 1_024,
              maximumTotalAggregateBytes: 8 * 1_024 * 1_024)
    }

    func testStreamedWholeArchiveDigestIsByteIdenticalToWholeBufferDigestsAndDiagnostics() throws {
        let fixture = try multiChunkFixture()
        let reader = AtriaHistoricalAggregateReader(aggregateDirectoryURL: fixture.aggregates,
                                                    manifestDirectoryURL: fixture.manifests)

        let streamed = try XCTUnwrap(reader.streamedWholeArchiveDigest(limits: limits))
        XCTAssertFalse(streamed.diagnostics.limitExceeded)

        let whole = reader.load(limits: limits)
        XCTAssertFalse(whole.diagnostics.limitExceeded)

        // 1. Byte-identical to the existing streamed-from-whole-snapshot path.
        let wholeSnapshotStreamedDigest = try AtriaHistoricalActivityInspectionProofFactory
            .streamedAggregateSnapshotDigest(whole)
        XCTAssertEqual(streamed.digest, wholeSnapshotStreamedDigest)

        // 2. Byte-identical to hashing the whole-buffer canonical encoding
        // directly (the ground truth reference implementation).
        let wholeBufferData = try AtriaHistoricalActivityInspectionProofFactory
            .canonicalAggregateSnapshotData(whole)
        let wholeBufferDigest = AtriaHistoricalDrainCompletionGenerationStore.sha256(wholeBufferData)
        XCTAssertEqual(streamed.digest, wholeBufferDigest)

        // 3. `.sources` matches the whole load's accepted sources, same order.
        XCTAssertEqual(streamed.sources, whole.aggregates.map(\.source))

        // 4. Whole-archive committed/accepted/rejected diagnostics match.
        XCTAssertEqual(streamed.diagnostics, whole.diagnostics)
        XCTAssertEqual(streamed.diagnostics.committedManifests, 4)
        XCTAssertEqual(streamed.diagnostics.acceptedAggregates, 3)
        XCTAssertEqual(streamed.diagnostics.rejectedManifests, 1,
                       "the tampered aggregate must be rejected, not silently dropped")
    }

    func testWindowedLoadMatchesWholeLoadFilteredToTheSameRange() throws {
        let fixture = try multiChunkFixture()
        let reader = AtriaHistoricalAggregateReader(aggregateDirectoryURL: fixture.aggregates,
                                                    manifestDirectoryURL: fixture.manifests)
        let whole = reader.load(limits: limits)
        XCTAssertFalse(whole.diagnostics.limitExceeded)

        // A ±1h window centred on chunk 1's 10-minute span ([day1, day1+600]).
        // It straddles chunk 1 while ending well before chunk 2's window
        // ([day2, day2+600]) and starting well after chunk 0's, so exactly one
        // chunk intersects and the interior `<`/`<=` boundary is not in play.
        let since = day0.addingTimeInterval(daySeconds - 3_600) // day1 - 1h
        let until = day0.addingTimeInterval(daySeconds + 3_600) // day1 + 1h

        let windowed = reader.load(since: since, until: until, limits: limits)
        XCTAssertFalse(windowed.diagnostics.limitExceeded)

        let expected = whole.aggregates.filter {
            $0.source.lastTimestamp >= since && $0.source.firstTimestamp <= until
        }
        XCTAssertEqual(windowed.aggregates, expected)
        XCTAssertEqual(windowed.aggregates.map(\.source.chunkID), ["mem-window-1"])
    }

    /// Locks in the rationale for the coordinator's one-ULP `until` nudge:
    /// `load(since:until:)` treats `until` as EXCLUSIVE, so a dependency chunk
    /// whose `firstTimestamp` lands exactly on the window's upper bound is
    /// dropped by a naive `until: upperBound` — which would defer that source,
    /// since `prepareVerified` selects `firstTimestamp <= requestedEnd`
    /// inclusively. Nudging `until` up by one ULP restores the inclusive match.
    func testWindowedLoadUpperBoundBecomesInclusiveWithOneULPNudge() throws {
        let fixture = try multiChunkFixture()
        let reader = AtriaHistoricalAggregateReader(aggregateDirectoryURL: fixture.aggregates,
                                                    manifestDirectoryURL: fixture.manifests)
        let day1 = day0.addingTimeInterval(daySeconds)
        let day2 = day0.addingTimeInterval(2 * daySeconds) // == chunk 2's firstTimestamp

        // Exclusive upper bound exactly on chunk 2's firstTimestamp drops it.
        let exclusive = reader.load(since: day1, until: day2, limits: limits)
        XCTAssertFalse(exclusive.aggregates.map(\.source.chunkID).contains("mem-window-2"))

        // The one-ULP nudge the coordinator applies includes it.
        let inclusiveUntil = Date(timeIntervalSinceReferenceDate:
            day2.timeIntervalSinceReferenceDate.nextUp)
        let inclusive = reader.load(since: day1, until: inclusiveUntil, limits: limits)
        XCTAssertTrue(inclusive.aggregates.map(\.source.chunkID).contains("mem-window-2"))
    }

    // MARK: - Fixture

    private struct Fixture {
        let aggregates: URL
        let manifests: URL
    }

    /// Builds four committed chunks spanning four separate days (chunk
    /// indices 0...3, one day apart), then tampers chunk 3's aggregate bytes
    /// after commit so its manifest is rejected on read while remaining
    /// present on disk — exercising rejected-count parity end to end.
    private func multiChunkFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalAggregateReaderMemoryWindowingTests")
            .appendingPathComponent(UUID().uuidString)
        let aggregates = root.appendingPathComponent("aggregates")
        let manifests = root.appendingPathComponent("manifests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)

        for index in 0..<4 {
            let anchor = day0.addingTimeInterval(Double(index) * daySeconds)
            let source = root.appendingPathComponent("source-\(index).jsonl")
            let raw = Data("{\"index\":\(index)}\n{\"end\":true}\n".utf8)
            try raw.write(to: source)
            let digest = AtriaHistoricalRetentionTransaction.sha256(of: raw)
            let aggregate = makeAggregate(digest: digest,
                                          bytes: UInt64(raw.count),
                                          chunkID: "mem-window-\(index)",
                                          anchor: anchor)
            let receipt = AtriaHistoricalAggregateBuilder.semanticParityReceipt(for: aggregate)
            _ = try AtriaHistoricalRetentionTransaction(
                now: { anchor.addingTimeInterval(1_000) },
                semanticVerifier: { _, _, _ in true }
            ).commit(.init(transactionID: "mem-window-txn-\(index)",
                           sourceURL: source,
                           aggregateDirectoryURL: aggregates,
                           manifestDirectoryURL: manifests,
                           aggregate: aggregate,
                           semanticParityReceipt: receipt,
                           deleteSourceAfterCommit: false))
        }

        // Intentionally reject chunk 3: flip a byte in its committed
        // aggregate file after commit. The manifest still exists and still
        // declares the original byte count/SHA-256, so this is caught by the
        // SHA-256 mismatch guard, not skipped before hashing/decoding.
        let taperedAggregateURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: aggregates, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .last
        )
        let handle = try FileHandle(forWritingTo: taperedAggregateURL)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x20]))
        try handle.close()

        return Fixture(aggregates: aggregates, manifests: manifests)
    }

    private func makeAggregate(digest: String,
                               bytes: UInt64,
                               chunkID: String,
                               anchor: Date) -> AtriaHistoricalAggregateChunk {
        let minute = AtriaHistoricalAggregateChunk.HeartRateMinute(
            minuteStart: anchor,
            sampleCount: 2,
            sumBPM: 140,
            minimumBPM: 60,
            maximumBPM: 80,
            samplesByBPM: [60: 1, 80: 1],
            terminalBPMSeconds: [80: 10],
            transitionHalfBPMSeconds: [140: 10],
            coveredSeconds: 10,
            droppedGapSeconds: 0,
            firstSampleUnix: anchor.timeIntervalSince1970,
            firstSampleBPM: 60,
            lastSampleUnix: anchor.addingTimeInterval(10).timeIntervalSince1970,
            lastSampleBPM: 80
        )
        return .init(
            schema: AtriaHistoricalAggregateChunk.currentSchema,
            createdAt: anchor.addingTimeInterval(100),
            source: .init(chunkID: chunkID,
                          rawSHA256: digest,
                          rawByteCount: bytes,
                          rawRowCount: 2,
                          firstTimestamp: anchor,
                          lastTimestamp: anchor.addingTimeInterval(600),
                          decoderSchema: HistoricalArchive.schema,
                          validatedLayouts: [HistoricalArchive.layoutVersion]),
            heartRateMinutes: [minute],
            rrEpochs: [],
            motionEpochs: [],
            materializedProjections: [],
            parity: .init(rawRows: 2,
                          decodedRows: 2,
                          undecodableRowsRetainedRaw: 0,
                          metricUsableRows: 2,
                          heartRateSamples: 2,
                          heartRateSumBPM: 140,
                          acceptedRRBeats: 0,
                          acceptedRRSumMilliseconds: 0,
                          validatedGravityRows: 0,
                          motionEpochs: 0,
                          projectionReceipts: 0)
        )
    }
}
