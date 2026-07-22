import XCTest
@testable import Atria

final class AtriaHistoricalActivityProjectionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_001_000_000)
    private let configuration = AtriaHistoricalActivityProjection.Configuration(
        restingHeartRate: 55,
        maximumHeartRate: 190,
        timeZoneIdentifier: "Asia/Kolkata"
    )
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testProjectionIsDeterministicAndUsesPostSourceLookahead() throws {
        let fixture = makeActiveFixture()
        let proof = try completeProof(for: fixture.source)
        let watermark = fixture.source.source.lastTimestamp.addingTimeInterval(1_800)

        let first = try AtriaHistoricalActivityProjection.build(
            source: fixture.source,
            dependencyChunks: [fixture.after, fixture.source, fixture.before],
            configuration: configuration,
            inspectionProof: proof,
            completionWatermark: watermark
        )
        let second = try AtriaHistoricalActivityProjection.build(
            source: fixture.source,
            dependencyChunks: [fixture.before, fixture.after, fixture.source],
            configuration: configuration,
            inspectionProof: proof,
            completionWatermark: watermark
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(try first.encodedArtifact(), try second.encodedArtifact())
        XCTAssertEqual(first.completionState, .complete)
        XCTAssertEqual(first.candidates.count, 1)
        XCTAssertEqual(first.outcome, .materialized)
        XCTAssertEqual(first.candidates[0].activeMinutes, 5)
        XCTAssertGreaterThan(first.candidates[0].end, fixture.source.source.lastTimestamp)
        XCTAssertEqual(first.dependencies.map(\.chunkID), ["before", "source", "after"])
    }

    func testNoCandidatePublishesExplicitCompleteEmptyReceipt() throws {
        let source = makeAggregate(id: "quiet",
                                   digestCharacter: "d",
                                   first: start,
                                   last: start.addingTimeInterval(3_600),
                                   heartRates: [
                                       (start.addingTimeInterval(600), 58),
                                       (start.addingTimeInterval(660), 60),
                                   ],
                                   motion: [])
        let proof = try completeProof(for: source)
        let watermark = source.source.lastTimestamp.addingTimeInterval(1_800)
        let ledger = makeLedger()
        let published = try AtriaHistoricalActivityProjection.publishReceipt(
            source: source,
            dependencyChunks: [source],
            configuration: configuration,
            inspectionProof: proof,
            completionWatermark: watermark,
            ledger: ledger,
            settledAt: watermark
        )
        let artifact = try Data(contentsOf: published.artifactURL)
        let decoded = try JSONDecoder().decode(AtriaHistoricalActivityProjection.self,
                                               from: artifact)

        XCTAssertEqual(decoded.completionState, .complete)
        XCTAssertEqual(decoded.candidates, [])
        XCTAssertEqual(published.receipt.outcome, .explicitlyEmpty)
        XCTAssertEqual(published.receipt.recordCount, 0)
        XCTAssertTrue(try AtriaHistoricalActivityProjection.verifyReceipt(
            published.receipt,
            artifact: artifact,
            source: source,
            dependencyChunks: [source],
            configuration: configuration,
            inspectionProof: proof,
            completionWatermark: watermark
        ))
    }

    func testMissingOrGappedCoverageAndPostSourceWatermarkFailClosed() throws {
        let fixture = makeActiveFixture()
        let adequateWatermark = fixture.source.source.lastTimestamp.addingTimeInterval(1_800)
        let requiredStart = fixture.source.source.firstTimestamp.addingTimeInterval(-1_800)
        let requiredEnd = fixture.source.source.lastTimestamp.addingTimeInterval(1_800)
        let missingProof = try AtriaHistoricalActivityProjection.InspectionProof.make(
            generationIdentifier: "missing-coverage",
            catalogSnapshot: Data("catalog-missing".utf8),
            closedCoverageIntervals: []
        )

        XCTAssertThrowsError(try AtriaHistoricalActivityProjection.build(
            source: fixture.source,
            dependencyChunks: [fixture.source],
            configuration: configuration,
            inspectionProof: missingProof,
            completionWatermark: adequateWatermark
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalActivityProjection.ProjectionError,
                           .invalidInspectionProof)
        }

        let gappedProof = try AtriaHistoricalActivityProjection.InspectionProof.make(
            generationIdentifier: "gapped-coverage",
            catalogSnapshot: Data("catalog-gapped".utf8),
            closedCoverageIntervals: [
                .init(start: requiredStart, end: fixture.source.source.firstTimestamp,
                      recordCount: 0),
                .init(start: fixture.source.source.firstTimestamp.addingTimeInterval(1),
                      end: requiredEnd, recordCount: 1),
            ]
        )
        XCTAssertThrowsError(try AtriaHistoricalActivityProjection.build(
            source: fixture.source,
            dependencyChunks: [fixture.source],
            configuration: configuration,
            inspectionProof: gappedProof,
            completionWatermark: adequateWatermark
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalActivityProjection.ProjectionError,
                           .incompleteInspectionCoverage)
        }

        XCTAssertThrowsError(try AtriaHistoricalActivityProjection.build(
            source: fixture.source,
            dependencyChunks: [fixture.source],
            configuration: configuration,
            inspectionProof: try completeProof(for: fixture.source),
            completionWatermark: adequateWatermark.addingTimeInterval(-1)
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalActivityProjection.ProjectionError,
                           .insufficientLookahead)
        }
    }

    func testMissingOrMismatchedSourceDependencyFailsClosed() throws {
        let fixture = makeActiveFixture()
        let proof = try completeProof(for: fixture.source)
        let watermark = fixture.source.source.lastTimestamp.addingTimeInterval(1_800)

        XCTAssertThrowsError(try AtriaHistoricalActivityProjection.build(
            source: fixture.source,
            dependencyChunks: [fixture.before, fixture.after],
            configuration: configuration,
            inspectionProof: proof,
            completionWatermark: watermark
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalActivityProjection.ProjectionError,
                           .sourceMissing)
        }

        let mismatched = replacingDigest(fixture.source, with: String(repeating: "e", count: 64))
        XCTAssertThrowsError(try AtriaHistoricalActivityProjection.build(
            source: fixture.source,
            dependencyChunks: [mismatched],
            configuration: configuration,
            inspectionProof: proof,
            completionWatermark: watermark
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalActivityProjection.ProjectionError,
                           .sourceMismatch)
        }
    }

    func testSemanticVerificationRejectsConfigurationAndDependencyFactChanges() throws {
        let fixture = makeActiveFixture()
        let proof = try completeProof(for: fixture.source)
        let watermark = fixture.source.source.lastTimestamp.addingTimeInterval(1_800)
        let ledger = makeLedger()
        let dependencies = [fixture.before, fixture.source, fixture.after]
        let published = try AtriaHistoricalActivityProjection.publishReceipt(
            source: fixture.source,
            dependencyChunks: dependencies,
            configuration: configuration,
            inspectionProof: proof,
            completionWatermark: watermark,
            ledger: ledger,
            settledAt: watermark
        )
        let artifact = try Data(contentsOf: published.artifactURL)
        let changedConfiguration = AtriaHistoricalActivityProjection.Configuration(
            restingHeartRate: 56,
            maximumHeartRate: 190,
            timeZoneIdentifier: "Asia/Kolkata"
        )

        XCTAssertFalse(try AtriaHistoricalActivityProjection.verifyReceipt(
            published.receipt,
            artifact: artifact,
            source: fixture.source,
            dependencyChunks: dependencies,
            configuration: changedConfiguration,
            inspectionProof: proof,
            completionWatermark: watermark
        ))

        let changedAfter = makeAggregate(
            id: "after",
            digestCharacter: "c",
            first: fixture.after.source.firstTimestamp,
            last: fixture.after.source.lastTimestamp,
            heartRates: [
                (fixture.source.source.lastTimestamp.addingTimeInterval(60), 91),
                (fixture.source.source.lastTimestamp.addingTimeInterval(120), 91),
            ],
            motion: []
        )
        XCTAssertThrowsError(try AtriaHistoricalActivityProjection.verifyReceipt(
            published.receipt,
            artifact: artifact,
            source: fixture.source,
            dependencyChunks: [fixture.before, fixture.source, changedAfter],
            configuration: configuration,
            inspectionProof: proof,
            completionWatermark: watermark
        ))
    }

    func testTamperedArtifactCannotPassSemanticVerification() throws {
        let fixture = makeActiveFixture()
        let proof = try completeProof(for: fixture.source)
        let watermark = fixture.source.source.lastTimestamp.addingTimeInterval(1_800)
        let projection = try AtriaHistoricalActivityProjection.build(
            source: fixture.source,
            dependencyChunks: [fixture.before, fixture.source, fixture.after],
            configuration: configuration,
            inspectionProof: proof,
            completionWatermark: watermark
        )
        let artifact = try projection.encodedArtifact()
        let identifier = try XCTUnwrap(projection.candidates.first?.identifier)
        let tampered = Data(try XCTUnwrap(String(data: artifact, encoding: .utf8))
            .replacingOccurrences(of: identifier,
                                  with: "activity-" + String(repeating: "0", count: 64)).utf8)

        XCTAssertThrowsError(try AtriaHistoricalActivityProjection.decodeAndVerify(
            tampered,
            source: fixture.source,
            dependencyChunks: [fixture.before, fixture.source, fixture.after],
            configuration: configuration,
            inspectionProof: proof,
            completionWatermark: watermark
        ))
    }

    func testTamperedInspectionProofCannotPublishOrVerify() throws {
        let fixture = makeActiveFixture()
        let proof = try completeProof(for: fixture.source)
        let tamperedProof = AtriaHistoricalActivityProjection.InspectionProof(
            catalogSnapshot: proof.catalogSnapshot + Data("tampered".utf8),
            scanGenerationManifest: proof.scanGenerationManifest
        )
        let watermark = fixture.source.source.lastTimestamp.addingTimeInterval(1_800)

        XCTAssertThrowsError(try AtriaHistoricalActivityProjection.build(
            source: fixture.source,
            dependencyChunks: [fixture.before, fixture.source, fixture.after],
            configuration: configuration,
            inspectionProof: tamperedProof,
            completionWatermark: watermark
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalActivityProjection.ProjectionError,
                           .invalidInspectionProof)
        }

        let ledger = makeLedger()
        let published = try AtriaHistoricalActivityProjection.publishReceipt(
            source: fixture.source,
            dependencyChunks: [fixture.before, fixture.source, fixture.after],
            configuration: configuration,
            inspectionProof: proof,
            completionWatermark: watermark,
            ledger: ledger,
            settledAt: watermark
        )
        XCTAssertThrowsError(try AtriaHistoricalActivityProjection.verifyReceipt(
            published.receipt,
            artifact: Data(contentsOf: published.artifactURL),
            source: fixture.source,
            dependencyChunks: [fixture.before, fixture.source, fixture.after],
            configuration: configuration,
            inspectionProof: tamperedProof,
            completionWatermark: watermark
        ))
    }

    private struct ActiveFixture {
        let before: AtriaHistoricalAggregateChunk
        let source: AtriaHistoricalAggregateChunk
        let after: AtriaHistoricalAggregateChunk
    }

    private func makeActiveFixture() -> ActiveFixture {
        let sourceStart = start
        let sourceEnd = start.addingTimeInterval(3_600)
        let before = makeAggregate(id: "before",
                                   digestCharacter: "a",
                                   first: start.addingTimeInterval(-3_600),
                                   last: start.addingTimeInterval(-1),
                                   heartRates: [],
                                   motion: [])
        // The candidate starts in this source and continues into `after`.
        let source = makeAggregate(id: "source",
                                   digestCharacter: "b",
                                   first: sourceStart,
                                   last: sourceEnd,
                                   heartRates: [
                                       (sourceEnd.addingTimeInterval(-120), 104),
                                       (sourceEnd.addingTimeInterval(-60), 108),
                                       (sourceEnd, 110),
                                   ],
                                   motion: [
                                       (sourceEnd.addingTimeInterval(-120), 0.22),
                                       (sourceEnd.addingTimeInterval(-60), 0.24),
                                       (sourceEnd, 0.25),
                                   ])
        let after = makeAggregate(id: "after",
                                  digestCharacter: "c",
                                  first: sourceEnd.addingTimeInterval(1),
                                  last: sourceEnd.addingTimeInterval(3_600),
                                  heartRates: [
                                      (sourceEnd.addingTimeInterval(60), 112),
                                      (sourceEnd.addingTimeInterval(120), 109),
                                  ],
                                  motion: [
                                      (sourceEnd.addingTimeInterval(60), 0.23),
                                      (sourceEnd.addingTimeInterval(120), 0.21),
                                  ])
        return .init(before: before, source: source, after: after)
    }

    private func makeAggregate(
        id: String,
        digestCharacter: Character,
        first: Date,
        last: Date,
        heartRates: [(Date, Int)],
        motion: [(Date, Double)]
    ) -> AtriaHistoricalAggregateChunk {
        let heartRateMinutes = heartRates.map { heartRateMinute(start: $0.0, bpm: $0.1) }
        let motionEpochs = motion.map { motionEpoch(start: $0.0, intensity: $0.1) }
        let rows = max(1, heartRateMinutes.count + motionEpochs.count)
        return .init(
            schema: AtriaHistoricalAggregateChunk.currentSchema,
            createdAt: last.addingTimeInterval(60),
            source: .init(chunkID: id,
                          rawSHA256: String(repeating: digestCharacter, count: 64),
                          rawByteCount: UInt64(rows * 100),
                          rawRowCount: rows,
                          firstTimestamp: first,
                          lastTimestamp: last,
                          decoderSchema: HistoricalArchive.schema,
                          validatedLayouts: Array(HistoricalArchive.validatedMetricLayoutVersions).sorted()),
            heartRateMinutes: heartRateMinutes,
            rrEpochs: [],
            motionEpochs: motionEpochs,
            materializedProjections: [],
            parity: .init(rawRows: rows,
                          decodedRows: rows,
                          undecodableRowsRetainedRaw: 0,
                          metricUsableRows: heartRateMinutes.count + motionEpochs.count,
                          heartRateSamples: heartRateMinutes.reduce(0) { $0 + $1.sampleCount },
                          heartRateSumBPM: heartRateMinutes.reduce(Int64(0)) { $0 + $1.sumBPM },
                          acceptedRRBeats: 0,
                          acceptedRRSumMilliseconds: 0,
                          validatedGravityRows: motionEpochs.reduce(0) { $0 + $1.validatedRows },
                          motionEpochs: motionEpochs.count,
                          projectionReceipts: 0)
        )
    }

    private func heartRateMinute(
        start: Date,
        bpm: Int
    ) -> AtriaHistoricalAggregateChunk.HeartRateMinute {
        .init(minuteStart: start,
              sampleCount: 2,
              sumBPM: Int64(bpm * 2),
              minimumBPM: bpm,
              maximumBPM: bpm,
              samplesByBPM: [bpm: 2],
              terminalBPMSeconds: [bpm: 30],
              transitionHalfBPMSeconds: [bpm * 2: 30],
              coveredSeconds: 30,
              droppedGapSeconds: 0,
              firstSampleUnix: start.timeIntervalSince1970,
              firstSampleBPM: bpm,
              lastSampleUnix: start.addingTimeInterval(30).timeIntervalSince1970,
              lastSampleBPM: bpm)
    }

    private func motionEpoch(
        start: Date,
        intensity: Double
    ) -> AtriaHistoricalAggregateChunk.MotionEpoch {
        .init(start: start,
              end: start.addingTimeInterval(30),
              rows: 10,
              validatedRows: 10,
              rejectedRows: 0,
              coverageSeconds: 30,
              maximumGapSeconds: 2,
              stillnessRatio: 0.4,
              movementIntensity: intensity,
              p95VectorDelta: 0.1,
              activityBursts: 1,
              stepDelta: nil,
              measurementValidated: true,
              lowMotionQualified: false,
              sleepStage: nil,
              sleepStageConfidence: nil,
              algorithmVersion: "motion-test-v1",
              provenance: "validated-test")
    }

    private func replacingDigest(
        _ aggregate: AtriaHistoricalAggregateChunk,
        with digest: String
    ) -> AtriaHistoricalAggregateChunk {
        .init(schema: aggregate.schema,
              createdAt: aggregate.createdAt,
              source: .init(chunkID: aggregate.source.chunkID,
                            rawSHA256: digest,
                            rawByteCount: aggregate.source.rawByteCount,
                            rawRowCount: aggregate.source.rawRowCount,
                            firstTimestamp: aggregate.source.firstTimestamp,
                            lastTimestamp: aggregate.source.lastTimestamp,
                            decoderSchema: aggregate.source.decoderSchema,
                            validatedLayouts: aggregate.source.validatedLayouts),
              heartRateMinutes: aggregate.heartRateMinutes,
              rrEpochs: aggregate.rrEpochs,
              motionEpochs: aggregate.motionEpochs,
              materializedProjections: aggregate.materializedProjections,
              parity: aggregate.parity)
    }

    private func completeProof(
        for source: AtriaHistoricalAggregateChunk
    ) throws -> AtriaHistoricalActivityProjection.InspectionProof {
        let requiredStart = source.source.firstTimestamp.addingTimeInterval(
            -AtriaHistoricalActivityProjection.requiredHistory
        )
        let requiredEnd = source.source.lastTimestamp.addingTimeInterval(
            AtriaHistoricalActivityProjection.requiredLookahead
        )
        let catalogSnapshot = Data(
            "sealed-catalog-generation|\(source.source.chunkID)|\(source.source.rawSHA256)".utf8
        )
        return try .make(
            generationIdentifier: "scan-generation-\(source.source.chunkID)",
            catalogSnapshot: catalogSnapshot,
            closedCoverageIntervals: [
                .init(start: requiredStart,
                      end: source.source.firstTimestamp,
                      recordCount: 0),
                .init(start: source.source.firstTimestamp,
                      end: source.source.lastTimestamp,
                      recordCount: source.source.rawRowCount),
                .init(start: source.source.lastTimestamp,
                      end: requiredEnd,
                      recordCount: 0),
            ]
        )
    }

    private func makeLedger() -> AtriaHistoricalConsumerReceiptLedger {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalActivityProjectionTests")
            .appendingPathComponent(UUID().uuidString)
        roots.append(root)
        return .init(directoryURL: root)
    }
}
