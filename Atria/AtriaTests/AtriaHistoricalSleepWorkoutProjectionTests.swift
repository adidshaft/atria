import XCTest
@testable import Atria

final class AtriaHistoricalSleepWorkoutProjectionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_002_000_000)
    private let sleepConfiguration = AtriaHistoricalSleepProjection.Configuration(
        timeZoneIdentifier: "Asia/Kolkata",
        minimumDurationSeconds: 2 * 60 * 60,
        minimumValidatedMotionCoverage: 0.80,
        stillnessThreshold: 0.80,
        maximumMovementIntensity: 0.08
    )
    private let workoutConfiguration = AtriaHistoricalWorkoutProjection.Configuration(
        restingHeartRate: 55,
        maximumHeartRate: 190,
        timeZoneIdentifier: "Asia/Kolkata",
        minimumDurationMinutes: 10,
        minimumHeartRateCoverage: 0.80
    )
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testSleepProjectionIsDeterministicAndCrossesChunkBoundaries() throws {
        let fixture = makeSleepFixture()
        let proof = try completeProof(for: fixture.source,
                                      history: AtriaHistoricalSleepProjection.requiredHistory,
                                      lookahead: AtriaHistoricalSleepProjection.requiredLookahead)
        let watermark = fixture.source.source.lastTimestamp.addingTimeInterval(
            AtriaHistoricalSleepProjection.requiredLookahead
        )
        let first = try AtriaHistoricalSleepProjection.build(
            source: fixture.source,
            dependencyChunks: [fixture.after, fixture.before, fixture.source],
            configuration: sleepConfiguration,
            inspectionProof: proof,
            completionWatermark: watermark
        )
        let second = try AtriaHistoricalSleepProjection.build(
            source: fixture.source,
            dependencyChunks: [fixture.source, fixture.after, fixture.before],
            configuration: sleepConfiguration,
            inspectionProof: proof,
            completionWatermark: watermark
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(try first.encodedArtifact(), try second.encodedArtifact())
        XCTAssertEqual(first.candidates.count, 1)
        XCTAssertEqual(first.candidates.first?.confidence, .high)
        XCTAssertLessThan(first.candidates[0].start, fixture.source.source.firstTimestamp)
        XCTAssertGreaterThan(first.candidates[0].end, fixture.source.source.lastTimestamp)
        XCTAssertEqual(first.dependencies.map(\.chunkID), ["sleep-before", "sleep-source", "sleep-after"])
        XCTAssertTrue(first.dependencies.allSatisfy { $0.aggregateFactsSHA256.count == 64 })
        XCTAssertEqual(first.candidates[0].identifier,
                       second.candidates[0].identifier)
    }

    func testSleepSparseHeartRateAloneIsCompleteEmptyAndReceiptVerifies() throws {
        let source = makeAggregate(id: "sleep-no-motion",
                                   digestCharacter: "d",
                                   first: start,
                                   last: start.addingTimeInterval(3 * 60 * 60),
                                   heartRates: stride(from: 0, to: 180, by: 20).map {
                                       heartRateMinute(start: start.addingTimeInterval(Double($0 * 60)),
                                                       bpm: 58)
                                   },
                                   motion: [])
        let proof = try completeProof(for: source,
                                      history: AtriaHistoricalSleepProjection.requiredHistory,
                                      lookahead: AtriaHistoricalSleepProjection.requiredLookahead)
        let watermark = source.source.lastTimestamp.addingTimeInterval(
            AtriaHistoricalSleepProjection.requiredLookahead
        )
        let ledger = makeLedger(test: #function)
        let published = try AtriaHistoricalSleepProjection.publishReceipt(
            source: source,
            dependencyChunks: [source],
            configuration: sleepConfiguration,
            inspectionProof: proof,
            completionWatermark: watermark,
            ledger: ledger,
            settledAt: watermark
        )
        let artifact = try Data(contentsOf: published.artifactURL)

        XCTAssertEqual(published.receipt.outcome, .explicitlyEmpty)
        XCTAssertEqual(published.receipt.recordCount, 0)
        XCTAssertTrue(try AtriaHistoricalSleepProjection.verifyShadowReceipt(
            published.receipt,
            artifact: artifact,
            source: source,
            dependencyChunks: [source],
            configuration: sleepConfiguration,
            inspectionProof: proof,
            completionWatermark: watermark
        ))
        XCTAssertThrowsError(try AtriaHistoricalSleepProjection.verifyReceipt(
            published.receipt,
            artifact: artifact,
            source: source,
            dependencyChunks: [source],
            configuration: sleepConfiguration,
            inspectionProof: proof,
            completionWatermark: watermark
        )) {
            XCTAssertEqual($0 as? AtriaHistoricalSessionProjectionError,
                           .productionCatalogAttestationRequired)
        }
    }

    func testOverlappingMotionChunksCannotManufactureSleepCoverage() throws {
        let motion = (0...120).map {
            motionEpoch(start: start.addingTimeInterval(Double($0 * 60)), sleep: true)
        }
        let end = start.addingTimeInterval(120 * 60 + 30)
        let source = makeAggregate(id: "sleep-overlap-source",
                                   digestCharacter: "a",
                                   first: start,
                                   last: end,
                                   heartRates: [],
                                   motion: motion)
        let replayed = makeAggregate(id: "sleep-overlap-replay",
                                     digestCharacter: "b",
                                     first: start,
                                     last: end,
                                     heartRates: [],
                                     motion: motion)
        let proof = try completeProof(for: source,
                                      history: AtriaHistoricalSleepProjection.requiredHistory,
                                      lookahead: AtriaHistoricalSleepProjection.requiredLookahead)
        let projection = try AtriaHistoricalSleepProjection.build(
            source: source,
            dependencyChunks: [source, replayed],
            configuration: sleepConfiguration,
            inspectionProof: proof,
            completionWatermark: end.addingTimeInterval(
                AtriaHistoricalSleepProjection.requiredLookahead
            )
        )

        XCTAssertEqual(projection.candidates, [],
                       "overlapping/replayed epochs must count each wall-clock second once")
    }

    func testWorkoutDenseHeartRateWithoutMotionIsOnlyMediumAndSparseIsEmpty() throws {
        let denseHR = (0..<12).map {
            heartRateMinute(start: start.addingTimeInterval(Double($0 * 60)), bpm: 125)
        }
        let dense = makeAggregate(id: "workout-dense",
                                  digestCharacter: "e",
                                  first: start,
                                  last: start.addingTimeInterval(20 * 60),
                                  heartRates: denseHR,
                                  motion: [])
        let proof = try completeProof(for: dense,
                                      history: AtriaHistoricalWorkoutProjection.requiredHistory,
                                      lookahead: AtriaHistoricalWorkoutProjection.requiredLookahead)
        let watermark = dense.source.lastTimestamp.addingTimeInterval(
            AtriaHistoricalWorkoutProjection.requiredLookahead
        )
        let projection = try AtriaHistoricalWorkoutProjection.build(
            source: dense,
            dependencyChunks: [dense],
            configuration: workoutConfiguration,
            inspectionProof: proof,
            completionWatermark: watermark
        )
        XCTAssertEqual(projection.candidates.count, 1)
        XCTAssertEqual(projection.candidates.first?.confidence, .medium)
        XCTAssertEqual(projection.candidates.first?.coverage.motionCoverageRatio, 0)

        let sparse = makeAggregate(id: "workout-sparse",
                                   digestCharacter: "f",
                                   first: start,
                                   last: start.addingTimeInterval(20 * 60),
                                   heartRates: [0, 5, 11].map {
                                       heartRateMinute(start: start.addingTimeInterval(Double($0 * 60)),
                                                       bpm: 140)
                                   },
                                   motion: [])
        let sparseProjection = try AtriaHistoricalWorkoutProjection.build(
            source: sparse,
            dependencyChunks: [sparse],
            configuration: workoutConfiguration,
            inspectionProof: try completeProof(
                for: sparse,
                history: AtriaHistoricalWorkoutProjection.requiredHistory,
                lookahead: AtriaHistoricalWorkoutProjection.requiredLookahead
            ),
            completionWatermark: sparse.source.lastTimestamp.addingTimeInterval(
                AtriaHistoricalWorkoutProjection.requiredLookahead
            )
        )
        XCTAssertEqual(sparseProjection.candidates, [])
        XCTAssertEqual(sparseProjection.outcome, .explicitlyEmpty)
    }

    func testWorkoutReceiptRebuildRejectsTamperConfigurationAndDependencyChange() throws {
        let fixture = makeWorkoutFixture()
        let dependencies = [fixture.source, fixture.after]
        let proof = try completeProof(for: fixture.source,
                                      history: AtriaHistoricalWorkoutProjection.requiredHistory,
                                      lookahead: AtriaHistoricalWorkoutProjection.requiredLookahead)
        let watermark = fixture.source.source.lastTimestamp.addingTimeInterval(
            AtriaHistoricalWorkoutProjection.requiredLookahead
        )
        let ledger = makeLedger(test: #function)
        let published = try AtriaHistoricalWorkoutProjection.publishReceipt(
            source: fixture.source,
            dependencyChunks: dependencies,
            configuration: workoutConfiguration,
            inspectionProof: proof,
            completionWatermark: watermark,
            ledger: ledger,
            settledAt: watermark
        )
        let artifact = try Data(contentsOf: published.artifactURL)
        XCTAssertEqual(published.receipt.outcome, .materialized)
        XCTAssertTrue(try AtriaHistoricalWorkoutProjection.verifyShadowReceipt(
            published.receipt,
            artifact: artifact,
            source: fixture.source,
            dependencyChunks: dependencies,
            configuration: workoutConfiguration,
            inspectionProof: proof,
            completionWatermark: watermark
        ))
        XCTAssertThrowsError(try AtriaHistoricalWorkoutProjection.verifyReceipt(
            published.receipt,
            artifact: artifact,
            source: fixture.source,
            dependencyChunks: dependencies,
            configuration: workoutConfiguration,
            inspectionProof: proof,
            completionWatermark: watermark
        )) {
            XCTAssertEqual($0 as? AtriaHistoricalSessionProjectionError,
                           .productionCatalogAttestationRequired)
        }

        let identifier = try XCTUnwrap(
            JSONDecoder().decode(AtriaHistoricalWorkoutProjection.self, from: artifact)
                .candidates.first?.identifier
        )
        let tampered = Data(try XCTUnwrap(String(data: artifact, encoding: .utf8))
            .replacingOccurrences(of: identifier,
                                  with: "workout-" + String(repeating: "0", count: 64)).utf8)
        XCTAssertThrowsError(try AtriaHistoricalWorkoutProjection.decodeAndVerify(
            tampered,
            source: fixture.source,
            dependencyChunks: dependencies,
            configuration: workoutConfiguration,
            inspectionProof: proof,
            completionWatermark: watermark
        ))

        let changedConfiguration = AtriaHistoricalWorkoutProjection.Configuration(
            restingHeartRate: 56,
            maximumHeartRate: 190,
            timeZoneIdentifier: "Asia/Kolkata",
            minimumDurationMinutes: 10,
            minimumHeartRateCoverage: 0.80
        )
        XCTAssertFalse(try AtriaHistoricalWorkoutProjection.verifyShadowReceipt(
            published.receipt,
            artifact: artifact,
            source: fixture.source,
            dependencyChunks: dependencies,
            configuration: changedConfiguration,
            inspectionProof: proof,
            completionWatermark: watermark
        ))

        let changedAfter = makeAggregate(id: "workout-after",
                                         digestCharacter: "c",
                                         first: fixture.after.source.firstTimestamp,
                                         last: fixture.after.source.lastTimestamp,
                                         heartRates: [],
                                         motion: [])
        XCTAssertThrowsError(try AtriaHistoricalWorkoutProjection.decodeAndVerify(
            artifact,
            source: fixture.source,
            dependencyChunks: [fixture.source, changedAfter],
            configuration: workoutConfiguration,
            inspectionProof: proof,
            completionWatermark: watermark
        ))
    }

    func testInspectionGapTamperAndEarlyWatermarkFailClosed() throws {
        let source = makeAggregate(id: "boundary",
                                   digestCharacter: "9",
                                   first: start,
                                   last: start.addingTimeInterval(60 * 60),
                                   heartRates: [],
                                   motion: [])
        let requiredStart = source.source.firstTimestamp.addingTimeInterval(
            -AtriaHistoricalSleepProjection.requiredHistory
        )
        let requiredEnd = source.source.lastTimestamp.addingTimeInterval(
            AtriaHistoricalSleepProjection.requiredLookahead
        )
        let gapped = try AtriaHistoricalSessionInspectionProof.make(
            generationIdentifier: "gapped",
            catalogSnapshot: Data("gapped-catalog".utf8),
            closedCoverageIntervals: [
                .init(start: requiredStart, end: start, recordCount: 0),
                .init(start: start.addingTimeInterval(1), end: requiredEnd, recordCount: 0),
            ]
        )
        XCTAssertThrowsError(try AtriaHistoricalSleepProjection.build(
            source: source,
            dependencyChunks: [source],
            configuration: sleepConfiguration,
            inspectionProof: gapped,
            completionWatermark: requiredEnd
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalSessionProjectionError,
                           .incompleteInspectionCoverage)
        }

        let proof = try completeProof(for: source,
                                      history: AtriaHistoricalSleepProjection.requiredHistory,
                                      lookahead: AtriaHistoricalSleepProjection.requiredLookahead)
        let tampered = AtriaHistoricalSessionInspectionProof(
            catalogSnapshot: proof.catalogSnapshot + Data("tamper".utf8),
            scanGenerationManifest: proof.scanGenerationManifest
        )
        XCTAssertThrowsError(try AtriaHistoricalSleepProjection.build(
            source: source,
            dependencyChunks: [source],
            configuration: sleepConfiguration,
            inspectionProof: tampered,
            completionWatermark: requiredEnd
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalSessionProjectionError,
                           .invalidInspectionProof)
        }
        XCTAssertThrowsError(try AtriaHistoricalSleepProjection.build(
            source: source,
            dependencyChunks: [source],
            configuration: sleepConfiguration,
            inspectionProof: proof,
            completionWatermark: requiredEnd.addingTimeInterval(-1)
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalSessionProjectionError,
                           .insufficientLookahead)
        }
    }

    private struct SleepFixture {
        let before: AtriaHistoricalAggregateChunk
        let source: AtriaHistoricalAggregateChunk
        let after: AtriaHistoricalAggregateChunk
    }

    private func makeSleepFixture() -> SleepFixture {
        let beforeStart = start.addingTimeInterval(-60 * 60)
        let sourceEnd = start.addingTimeInterval(60 * 60)
        let afterEnd = sourceEnd.addingTimeInterval(60 * 60)
        return .init(
            before: makeAggregate(id: "sleep-before", digestCharacter: "a",
                                  first: beforeStart, last: start.addingTimeInterval(-1),
                                  heartRates: minuteHeartRates(from: beforeStart, count: 60, bpm: 58),
                                  motion: sleepMotion(from: beforeStart, count: 120)),
            source: makeAggregate(id: "sleep-source", digestCharacter: "b",
                                  first: start, last: sourceEnd,
                                  heartRates: minuteHeartRates(from: start, count: 60, bpm: 57),
                                  motion: sleepMotion(from: start, count: 120)),
            after: makeAggregate(id: "sleep-after", digestCharacter: "c",
                                 first: sourceEnd.addingTimeInterval(1), last: afterEnd,
                                 heartRates: minuteHeartRates(from: sourceEnd, count: 60, bpm: 59),
                                 motion: sleepMotion(from: sourceEnd, count: 120))
        )
    }

    private struct WorkoutFixture {
        let source: AtriaHistoricalAggregateChunk
        let after: AtriaHistoricalAggregateChunk
    }

    private func makeWorkoutFixture() -> WorkoutFixture {
        let sourceEnd = start.addingTimeInterval(8 * 60)
        return .init(
            source: makeAggregate(id: "workout-source", digestCharacter: "b",
                                  first: start, last: sourceEnd,
                                  heartRates: minuteHeartRates(from: start, count: 8, bpm: 125),
                                  motion: activeMotion(from: start, count: 16)),
            after: makeAggregate(id: "workout-after", digestCharacter: "c",
                                 first: sourceEnd.addingTimeInterval(1),
                                 last: sourceEnd.addingTimeInterval(12 * 60),
                                 heartRates: minuteHeartRates(from: sourceEnd, count: 8, bpm: 130),
                                 motion: activeMotion(from: sourceEnd, count: 16))
        )
    }

    private func minuteHeartRates(from start: Date, count: Int, bpm: Int)
        -> [AtriaHistoricalAggregateChunk.HeartRateMinute] {
        (0..<count).map {
            heartRateMinute(start: start.addingTimeInterval(Double($0 * 60)), bpm: bpm)
        }
    }

    private func sleepMotion(from start: Date, count: Int)
        -> [AtriaHistoricalAggregateChunk.MotionEpoch] {
        (0..<count).map {
            motionEpoch(start: start.addingTimeInterval(Double($0 * 30)), sleep: true)
        }
    }

    private func activeMotion(from start: Date, count: Int)
        -> [AtriaHistoricalAggregateChunk.MotionEpoch] {
        (0..<count).map {
            motionEpoch(start: start.addingTimeInterval(Double($0 * 30)), sleep: false)
        }
    }

    private func makeAggregate(
        id: String,
        digestCharacter: Character,
        first: Date,
        last: Date,
        heartRates: [AtriaHistoricalAggregateChunk.HeartRateMinute],
        motion: [AtriaHistoricalAggregateChunk.MotionEpoch]
    ) -> AtriaHistoricalAggregateChunk {
        let rows = heartRates.count + motion.count
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
            heartRateMinutes: heartRates,
            rrEpochs: [],
            motionEpochs: motion,
            materializedProjections: [],
            parity: .init(rawRows: rows,
                          decodedRows: rows,
                          undecodableRowsRetainedRaw: 0,
                          metricUsableRows: rows,
                          heartRateSamples: heartRates.reduce(0) { $0 + $1.sampleCount },
                          heartRateSumBPM: heartRates.reduce(Int64(0)) { $0 + $1.sumBPM },
                          acceptedRRBeats: 0,
                          acceptedRRSumMilliseconds: 0,
                          validatedGravityRows: motion.reduce(0) { $0 + $1.validatedRows },
                          motionEpochs: motion.count,
                          projectionReceipts: 0)
        )
    }

    private func heartRateMinute(start: Date, bpm: Int)
        -> AtriaHistoricalAggregateChunk.HeartRateMinute {
        .init(minuteStart: start,
              sampleCount: 4,
              sumBPM: Int64(bpm * 4),
              minimumBPM: bpm,
              maximumBPM: bpm,
              samplesByBPM: [bpm: 4],
              terminalBPMSeconds: [bpm: 45],
              transitionHalfBPMSeconds: [bpm * 2: 45],
              coveredSeconds: 45,
              droppedGapSeconds: 0,
              firstSampleUnix: start.timeIntervalSince1970,
              firstSampleBPM: bpm,
              lastSampleUnix: start.addingTimeInterval(45).timeIntervalSince1970,
              lastSampleBPM: bpm)
    }

    private func motionEpoch(start: Date, sleep: Bool)
        -> AtriaHistoricalAggregateChunk.MotionEpoch {
        .init(start: start,
              end: start.addingTimeInterval(30),
              rows: 10,
              validatedRows: 10,
              rejectedRows: 0,
              coverageSeconds: 30,
              maximumGapSeconds: 2,
              stillnessRatio: sleep ? 0.95 : 0.30,
              movementIntensity: sleep ? 0.02 : 0.20,
              p95VectorDelta: sleep ? 0.01 : 0.15,
              activityBursts: sleep ? 0 : 1,
              stepDelta: nil,
              measurementValidated: true,
              lowMotionQualified: sleep,
              sleepStage: nil,
              sleepStageConfidence: nil,
              algorithmVersion: "motion-fixture-v1",
              provenance: "validated-gravity-fixture")
    }

    private func completeProof(
        for source: AtriaHistoricalAggregateChunk,
        history: TimeInterval,
        lookahead: TimeInterval
    ) throws -> AtriaHistoricalSessionInspectionProof {
        let requiredStart = source.source.firstTimestamp.addingTimeInterval(-history)
        let requiredEnd = source.source.lastTimestamp.addingTimeInterval(lookahead)
        return try .make(
            generationIdentifier: "scan-\(source.source.chunkID)",
            catalogSnapshot: Data("catalog|\(source.source.chunkID)|\(source.source.rawSHA256)".utf8),
            closedCoverageIntervals: [
                .init(start: requiredStart, end: source.source.firstTimestamp, recordCount: 0),
                .init(start: source.source.firstTimestamp,
                      end: source.source.lastTimestamp,
                      recordCount: source.source.rawRowCount),
                .init(start: source.source.lastTimestamp, end: requiredEnd, recordCount: 0),
            ]
        )
    }

    private func makeLedger(test: String) -> AtriaHistoricalConsumerReceiptLedger {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalSleepWorkoutProjectionTests")
            .appendingPathComponent(test)
            .appendingPathComponent(UUID().uuidString)
        roots.append(root)
        return .init(directoryURL: root)
    }
}
