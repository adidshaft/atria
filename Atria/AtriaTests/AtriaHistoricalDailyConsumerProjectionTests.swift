import XCTest
@testable import Atria

final class AtriaHistoricalDailyConsumerProjectionTests: XCTestCase {
    private let utcConfiguration = AtriaHistoricalDailyConsumerProjection.Configuration(
        timeZoneIdentifier: "UTC",
        dayBoundaryPolicyVersion: "civil-midnight-v1"
    )
    private let dayStart = Date(timeIntervalSince1970: 2_001_024_000) // UTC midnight
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
    }

    func testArtifactsAreDeterministicAndPreserveExactDailyLoadFacts() throws {
        let hr = heartRateMinute(at: dayStart.addingTimeInterval(60),
                                 samples: [80: 2, 100: 1],
                                 terminal: [80: 15, 100: 20],
                                 transitions: [160: 15, 180: 20])
        let motion = motionEpoch(start: dayStart,
                                 end: dayStart.addingTimeInterval(86_400),
                                 stepDelta: 123,
                                 validated: true)
        let source = aggregate(id: "source", character: "a",
                               first: dayStart,
                               last: dayStart.addingTimeInterval(86_399),
                               heartRate: [hr], motion: [motion])
        let proof = try completeProof(chunks: [source],
                                      start: dayStart,
                                      end: dayStart.addingTimeInterval(86_400))
        let watermark = dayStart.addingTimeInterval(86_400)

        let metricsA = try AtriaHistoricalDailyConsumerProjection.buildDailyMetrics(
            source: source, dependencyChunks: [source], configuration: utcConfiguration,
            inspectionProof: proof, completionWatermark: watermark)
        let metricsB = try AtriaHistoricalDailyConsumerProjection.buildDailyMetrics(
            source: source, dependencyChunks: [source], configuration: utcConfiguration,
            inspectionProof: proof, completionWatermark: watermark)
        let steps = try AtriaHistoricalDailyConsumerProjection.buildSteps(
            source: source, dependencyChunks: [source], configuration: utcConfiguration,
            inspectionProof: proof, completionWatermark: watermark)

        XCTAssertEqual(metricsA, metricsB)
        XCTAssertEqual(try metricsA.encodedArtifact(), try metricsB.encodedArtifact())
        let observed = try XCTUnwrap(metricsA.days.first?.observedHeartRate)
        XCTAssertEqual(observed.samplesByBPM, [80: 2, 100: 1])
        XCTAssertEqual(observed.terminalBPMSeconds, [80: 15, 100: 20])
        XCTAssertEqual(observed.transitionHalfBPMSeconds, [160: 15, 180: 20])
        XCTAssertEqual(metricsA.days.first?.heartRateState, .available)
        XCTAssertEqual(steps.days.first?.state, .available)
        XCTAssertEqual(steps.days.first?.stepCount, 123)
        XCTAssertEqual(steps.days.first?.missingCoverageSeconds, 0)
    }

    func testMissingStepEvidenceNeverBecomesZeroAndNoDataRemainsExplicit() throws {
        let source = aggregate(id: "no-data", character: "b",
                               first: dayStart.addingTimeInterval(1_000),
                               last: dayStart.addingTimeInterval(2_000),
                               heartRate: [], motion: [])
        let proof = try completeProof(chunks: [source],
                                      start: dayStart,
                                      end: dayStart.addingTimeInterval(86_400),
                                      recordCount: 0)
        let watermark = dayStart.addingTimeInterval(86_400)
        let steps = try AtriaHistoricalDailyConsumerProjection.buildSteps(
            source: source, dependencyChunks: [source], configuration: utcConfiguration,
            inspectionProof: proof, completionWatermark: watermark)
        let metrics = try AtriaHistoricalDailyConsumerProjection.buildDailyMetrics(
            source: source, dependencyChunks: [source], configuration: utcConfiguration,
            inspectionProof: proof, completionWatermark: watermark)

        XCTAssertEqual(steps.days.first?.state, .missing)
        XCTAssertNil(steps.days.first?.stepCount)
        XCTAssertEqual(steps.days.first?.knownStepDeltaSum, 0)
        XCTAssertEqual(steps.days.first?.missingCoverageSeconds, 86_400)
        XCTAssertEqual(metrics.days.first?.heartRateState, .missing)
        XCTAssertNil(metrics.days.first?.observedHeartRate)

        let ledger = makeLedger()
        let published = try AtriaHistoricalDailyConsumerProjection.publishStepsReceipt(
            source: source, dependencyChunks: [source], configuration: utcConfiguration,
            inspectionProof: proof, completionWatermark: watermark, ledger: ledger,
            settledAt: watermark)
        XCTAssertEqual(published.receipt.outcome, .materialized)
        XCTAssertTrue(try AtriaHistoricalDailyConsumerProjection.verifyStepsShadowReceipt(
            published.receipt, artifact: Data(contentsOf: published.artifactURL),
            source: source, dependencyChunks: [source], configuration: utcConfiguration,
            inspectionProof: proof, completionWatermark: watermark))
        XCTAssertThrowsError(try AtriaHistoricalDailyConsumerProjection.verifyStepsReceipt(
            published.receipt, artifact: Data(contentsOf: published.artifactURL),
            source: source, dependencyChunks: [source], configuration: utcConfiguration,
            inspectionProof: proof, completionWatermark: watermark)) { error in
                XCTAssertEqual(error as? AtriaHistoricalDailyConsumerProjection.ProjectionError,
                               .productionCatalogAttestationRequired)
        }
    }

    func testFullyCoveredValidatedZeroIsKnownEmpty() throws {
        let source = aggregate(id: "zero", character: "c",
                               first: dayStart,
                               last: dayStart.addingTimeInterval(86_399),
                               heartRate: [],
                               motion: [motionEpoch(start: dayStart,
                                                    end: dayStart.addingTimeInterval(86_400),
                                                    stepDelta: 0,
                                                    validated: true)])
        let proof = try completeProof(chunks: [source], start: dayStart,
                                      end: dayStart.addingTimeInterval(86_400))
        let artifact = try AtriaHistoricalDailyConsumerProjection.buildSteps(
            source: source, dependencyChunks: [source], configuration: utcConfiguration,
            inspectionProof: proof,
            completionWatermark: dayStart.addingTimeInterval(86_400))

        XCTAssertEqual(artifact.days.first?.state, .knownEmpty)
        XCTAssertEqual(artifact.days.first?.stepCount, 0)
    }

    func testStepAccumulationOverflowFailsClosed() throws {
        let middle = dayStart.addingTimeInterval(43_200)
        let source = aggregate(id: "overflow", character: "4",
                               first: dayStart,
                               last: dayStart.addingTimeInterval(86_399),
                               heartRate: [], motion: [
                                motionEpoch(start: dayStart, end: middle,
                                            stepDelta: Int.max, validated: true),
                                motionEpoch(start: middle,
                                            end: dayStart.addingTimeInterval(86_400),
                                            stepDelta: 1, validated: true),
                               ])
        let end = dayStart.addingTimeInterval(86_400)
        let proof = try completeProof(chunks: [source], start: dayStart, end: end)

        XCTAssertThrowsError(try AtriaHistoricalDailyConsumerProjection.buildSteps(
            source: source, dependencyChunks: [source], configuration: utcConfiguration,
            inspectionProof: proof, completionWatermark: end)) { error in
                XCTAssertEqual(error as? AtriaHistoricalDailyConsumerProjection.ProjectionError,
                               .arithmeticOverflow)
        }
    }

    func testCivilBoundaryAndPostBoundaryWatermarkFailClosed() throws {
        let configuration = AtriaHistoricalDailyConsumerProjection.Configuration(
            timeZoneIdentifier: "Asia/Kolkata",
            dayBoundaryPolicyVersion: "civil-midnight-v1")
        // 00:10 local time; civil day begins at 18:30 UTC on the previous date.
        let first = Date(timeIntervalSince1970: 2_001_033_000)
        let source = aggregate(id: "india", character: "d", first: first,
                               last: first.addingTimeInterval(600), heartRate: [], motion: [])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let boundary = calendar.startOfDay(for: first)
        let end = calendar.date(byAdding: .day, value: 1, to: boundary)!
        let proof = try completeProof(chunks: [source], start: boundary, end: end)

        XCTAssertThrowsError(try AtriaHistoricalDailyConsumerProjection.buildSteps(
            source: source, dependencyChunks: [source], configuration: configuration,
            inspectionProof: proof, completionWatermark: end.addingTimeInterval(-1))) { error in
                XCTAssertEqual(error as? AtriaHistoricalDailyConsumerProjection.ProjectionError,
                               .insufficientCompletionWatermark)
        }
        let artifact = try AtriaHistoricalDailyConsumerProjection.buildSteps(
            source: source, dependencyChunks: [source], configuration: configuration,
            inspectionProof: proof, completionWatermark: end)
        XCTAssertEqual(artifact.dependencyStart, boundary)
        XCTAssertEqual(artifact.dependencyEnd, end)
        let components = calendar.dateComponents([.year, .month, .day], from: boundary)
        XCTAssertEqual(artifact.days.first?.localDay,
                       String(format: "%04d-%02d-%02d",
                              components.year!, components.month!, components.day!))
    }

    func testGappedScanAndChangedAdjacentDependencyFailVerification() throws {
        let source = aggregate(id: "source", character: "e",
                               first: dayStart.addingTimeInterval(40_000),
                               last: dayStart.addingTimeInterval(50_000),
                               heartRate: [], motion: [])
        let before = aggregate(id: "before", character: "f", first: dayStart,
                               last: dayStart.addingTimeInterval(39_999),
                               heartRate: [], motion: [])
        let after = aggregate(id: "after", character: "1",
                              first: dayStart.addingTimeInterval(50_001),
                              last: dayStart.addingTimeInterval(86_399),
                              heartRate: [], motion: [])
        let dependencies = [before, source, after]
        let end = dayStart.addingTimeInterval(86_400)
        let gapped = try AtriaHistoricalDailyConsumerProjection.InspectionProof.make(
            generationIdentifier: "gapped", catalogSnapshot: Data("catalog".utf8),
            dependencyChunks: dependencies,
            closedCoverageIntervals: [
                .init(start: dayStart, end: dayStart.addingTimeInterval(40_000), recordCount: 2),
                .init(start: dayStart.addingTimeInterval(40_001), end: end, recordCount: 1),
            ])
        XCTAssertThrowsError(try AtriaHistoricalDailyConsumerProjection.buildDailyMetrics(
            source: source, dependencyChunks: dependencies, configuration: utcConfiguration,
            inspectionProof: gapped, completionWatermark: end)) { error in
                XCTAssertEqual(error as? AtriaHistoricalDailyConsumerProjection.ProjectionError,
                               .incompleteInspectionCoverage)
        }

        let proof = try completeProof(chunks: dependencies, start: dayStart, end: end)
        let ledger = makeLedger()
        let published = try AtriaHistoricalDailyConsumerProjection.publishDailyMetricsReceipt(
            source: source, dependencyChunks: dependencies, configuration: utcConfiguration,
            inspectionProof: proof, completionWatermark: end, ledger: ledger, settledAt: end)
        let changedAfter = aggregate(id: "after", character: "2",
                                     first: after.source.firstTimestamp,
                                     last: after.source.lastTimestamp,
                                     heartRate: [], motion: [])
        XCTAssertThrowsError(try AtriaHistoricalDailyConsumerProjection.verifyDailyMetricsReceipt(
            published.receipt, artifact: Data(contentsOf: published.artifactURL),
            source: source, dependencyChunks: [before, source, changedAfter],
            configuration: utcConfiguration, inspectionProof: proof,
            completionWatermark: end))
    }

    func testReceiptVerificationRejectsConfigurationAndArtifactTampering() throws {
        let source = aggregate(id: "tamper", character: "3",
                               first: dayStart, last: dayStart.addingTimeInterval(86_399),
                               heartRate: [],
                               motion: [motionEpoch(start: dayStart,
                                                    end: dayStart.addingTimeInterval(86_400),
                                                    stepDelta: 55, validated: true)])
        let end = dayStart.addingTimeInterval(86_400)
        let proof = try completeProof(chunks: [source], start: dayStart, end: end)
        let ledger = makeLedger()
        let published = try AtriaHistoricalDailyConsumerProjection.publishStepsReceipt(
            source: source, dependencyChunks: [source], configuration: utcConfiguration,
            inspectionProof: proof, completionWatermark: end, ledger: ledger, settledAt: end)
        let bytes = try Data(contentsOf: published.artifactURL)
        let changedConfiguration = AtriaHistoricalDailyConsumerProjection.Configuration(
            timeZoneIdentifier: "UTC", dayBoundaryPolicyVersion: "changed")
        XCTAssertFalse(try AtriaHistoricalDailyConsumerProjection.verifyStepsShadowReceipt(
            published.receipt, artifact: bytes, source: source, dependencyChunks: [source],
            configuration: changedConfiguration, inspectionProof: proof,
            completionWatermark: end))

        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        let tamperedText = text.replacingOccurrences(of: "\"stepCount\":55",
                                                      with: "\"stepCount\":54")
        XCTAssertNotEqual(tamperedText, text, "fixture must actually change the artifact")
        let tampered = Data(tamperedText.utf8)
        XCTAssertFalse(try AtriaHistoricalDailyConsumerProjection.verifyStepsShadowReceipt(
            published.receipt, artifact: tampered, source: source,
            dependencyChunks: [source], configuration: utcConfiguration,
            inspectionProof: proof, completionWatermark: end))
    }

    private func completeProof(
        chunks: [AtriaHistoricalAggregateChunk], start: Date, end: Date,
        recordCount: Int? = nil
    ) throws -> AtriaHistoricalDailyConsumerProjection.InspectionProof {
        try .make(generationIdentifier: "catalog-generation",
                  catalogSnapshot: Data("canonical-catalog".utf8),
                  dependencyChunks: chunks,
                  closedCoverageIntervals: [
                    .init(start: start, end: end,
                          recordCount: recordCount ?? chunks.count),
                  ])
    }

    private func makeLedger() -> AtriaHistoricalConsumerReceiptLedger {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-projection-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return .init(directoryURL: root)
    }

    private func heartRateMinute(
        at start: Date,
        samples: [Int: Int],
        terminal: [Int: Double],
        transitions: [Int: Double]
    ) -> AtriaHistoricalAggregateChunk.HeartRateMinute {
        let count = samples.values.reduce(0, +)
        return .init(minuteStart: start,
                     sampleCount: count,
                     sumBPM: samples.reduce(Int64(0)) { $0 + Int64($1.key * $1.value) },
                     minimumBPM: samples.keys.min() ?? 0,
                     maximumBPM: samples.keys.max() ?? 0,
                     samplesByBPM: samples,
                     terminalBPMSeconds: terminal,
                     transitionHalfBPMSeconds: transitions,
                     coveredSeconds: terminal.values.reduce(0, +),
                     droppedGapSeconds: 0,
                     firstSampleUnix: start.timeIntervalSince1970,
                     firstSampleBPM: samples.keys.min(),
                     lastSampleUnix: start.addingTimeInterval(30).timeIntervalSince1970,
                     lastSampleBPM: samples.keys.max())
    }

    private func motionEpoch(
        start: Date, end: Date, stepDelta: Int?, validated: Bool
    ) -> AtriaHistoricalAggregateChunk.MotionEpoch {
        .init(start: start, end: end, rows: 1,
              validatedRows: validated ? 1 : 0,
              rejectedRows: validated ? 0 : 1,
              coverageSeconds: Int(end.timeIntervalSince(start)),
              maximumGapSeconds: 0, stillnessRatio: 0.5,
              movementIntensity: 0.2, p95VectorDelta: 0.1,
              activityBursts: 0, stepDelta: stepDelta,
              measurementValidated: validated, lowMotionQualified: false,
              sleepStage: nil, sleepStageConfidence: nil,
              algorithmVersion: "fixture-motion-v1", provenance: "test")
    }

    private func aggregate(
        id: String, character: Character, first: Date, last: Date,
        heartRate: [AtriaHistoricalAggregateChunk.HeartRateMinute],
        motion: [AtriaHistoricalAggregateChunk.MotionEpoch]
    ) -> AtriaHistoricalAggregateChunk {
        let hrCount = heartRate.reduce(0) { $0 + $1.sampleCount }
        return .init(schema: AtriaHistoricalAggregateChunk.currentSchema,
                     createdAt: last,
                     source: .init(chunkID: id,
                                   rawSHA256: String(repeating: String(character), count: 64),
                                   rawByteCount: 10, rawRowCount: 1,
                                   firstTimestamp: first, lastTimestamp: last,
                                   decoderSchema: 1, validatedLayouts: ["fixture"]),
                     heartRateMinutes: heartRate, rrEpochs: [], motionEpochs: motion,
                     materializedProjections: [],
                     parity: .init(rawRows: 1, decodedRows: 1,
                                   undecodableRowsRetainedRaw: 0, metricUsableRows: 1,
                                   heartRateSamples: hrCount,
                                   heartRateSumBPM: heartRate.reduce(Int64(0)) { $0 + $1.sumBPM },
                                   acceptedRRBeats: 0, acceptedRRSumMilliseconds: 0,
                                   validatedGravityRows: motion.reduce(0) { $0 + $1.validatedRows },
                                   motionEpochs: motion.count, projectionReceipts: 0))
    }
}
