import XCTest
@testable import Atria

final class AtriaHistoricalLongTermRollupTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private let now = Date(timeIntervalSince1970: 1_830_384_000) // 2028-01-01 UTC
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    override func tearDownWithError() throws {
        temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories.removeAll()
    }

    func testDailyRollupPreservesHeartRateLoadRRSufficientStatisticsMotionAndReceipts() throws {
        let day = now.addingTimeInterval(-180 * 86_400)
        let input = try makeInput(id: "complete-day", start: day, includeReceipts: true)
        let planner = AtriaHistoricalLongTermPlanner()

        let rollup = try planner.build(group: [input], createdAt: now)

        try rollup.validate()
        let facts = try XCTUnwrap(rollup.days.first)
        XCTAssertEqual(facts.heartRate.sampleCount, 4)
        XCTAssertEqual(facts.heartRate.sumBPM, 300)
        XCTAssertEqual(facts.heartRate.samplesByBPM, [60: 1, 70: 1, 80: 1, 80 + 10: 1])
        XCTAssertEqual(facts.heartRate.terminalBPMSeconds, [80: 10, 90: 10])
        XCTAssertEqual(facts.heartRate.transitionHalfBPMSeconds, [140: 10, 170: 10])
        XCTAssertEqual(facts.rr.acceptedBeatCount, 4)
        XCTAssertEqual(facts.rr.sumNNMilliseconds, 3_550)
        XCTAssertEqual(facts.rr.adjacentDifferenceCount, 3)
        // 100² + 100² + 150² spelled as a literal: the mixed-literal
        // arithmetic sat at the type-checker's budget edge.
        XCTAssertEqual(facts.rr.sumAdjacentDifferenceSquaredMilliseconds,
                       42_500.0,
                       accuracy: 0.000_001)
        XCTAssertTrue(facts.boundaryRREpochs.isEmpty)
        XCTAssertEqual(facts.motion.epochCount, 2)
        XCTAssertEqual(facts.motion.stepKnownEpochs, 1)
        XCTAssertEqual(facts.motion.stepDeltaSum, 3)
        XCTAssertEqual(facts.motion.stillnessMissingEpochs, 1)
        XCTAssertEqual(facts.motion.stillnessDistribution, [.init(value: 0.9, count: 1)])
        XCTAssertEqual(rollup.projectionReferences.count, 6)
        XCTAssertEqual(Set(rollup.projectionReferences.map(\.kind)),
                       AtriaHistoricalAggregateChunk.rawRetirementRequiredProjectionKinds)
        XCTAssertEqual(rollup.parity.heartRateSamples, input.aggregate.parity.heartRateSamples)
        XCTAssertEqual(rollup.parity.acceptedRRBeats, input.aggregate.parity.acceptedRRBeats)
    }

    func testPlannerRetainsNinetyDaysAndFailsClosedForCrossMonthSource() throws {
        let planner = AtriaHistoricalLongTermPlanner(fullDetailHorizon: 90 * 86_400)
        let old = try makeInput(id: "old", start: now.addingTimeInterval(-120 * 86_400))
        let recent = try makeInput(id: "recent", start: now.addingTimeInterval(-10 * 86_400))
        let crossing = try makeInput(id: "crossing",
                                     start: utcDate(2027, 8, 31, hour: 23),
                                     duration: 2 * 3_600)

        let plan = try planner.plan(inputs: [recent, crossing, old], now: now)

        XCTAssertEqual(plan.groups.flatMap { $0 }.map(\.aggregate.source.chunkID), ["old"])
        XCTAssertEqual(Set(plan.retainedFullDetail.map(\.aggregate.source.chunkID)),
                       ["recent", "crossing"])
        XCTAssertEqual(plan.blockedSourceChunkIDs, ["crossing"])
    }

    func testPlannerRetainsEntireCutoffMonthUntilMonthIsClosed() throws {
        let evaluation = utcDate(2028, 1, 15)
        let planner = AtriaHistoricalLongTermPlanner(fullDetailHorizon: 90 * 86_400)
        let cutoffMonth = try makeInput(id: "cutoff-month",
                                        start: utcDate(2027, 10, 1))
        let closedMonth = try makeInput(id: "closed-month",
                                        start: utcDate(2027, 9, 1))

        let plan = try planner.plan(inputs: [cutoffMonth, closedMonth], now: evaluation)

        XCTAssertEqual(plan.groups.flatMap { $0 }.map(\.aggregate.source.chunkID),
                       ["closed-month"])
        XCTAssertEqual(plan.retainedFullDetail.map(\.aggregate.source.chunkID),
                       ["cutoff-month"])
    }

    func testStorePublishesArtifactBeforeCommitAndOnlyVerifiedCommitSelectsSource() throws {
        enum Crash: Error { case injected }
        let input = try makeInput(id: "crash-safe", start: now.addingTimeInterval(-180 * 86_400))
        let rollup = try AtriaHistoricalLongTermPlanner().build(group: [input], createdAt: now)

        for checkpoint in [AtriaHistoricalLongTermStore.Checkpoint.artifactTemporaryDurable,
                           .artifactPublished,
                           .manifestTemporaryDurable] {
            let directory = temporaryDirectory()
            let store = AtriaHistoricalLongTermStore(
                directoryURL: directory,
                checkpoint: { if $0 == checkpoint { throw Crash.injected } }
            )
            XCTAssertThrowsError(try store.publish(rollup, committedAt: now))
            XCTAssertTrue(store.verifiedRetirementCandidates(inputs: [input], now: now).isEmpty,
                          "\(checkpoint) must not expose an uncommitted replacement")
        }

        let directory = temporaryDirectory()
        let store = AtriaHistoricalLongTermStore(directoryURL: directory)
        let publication = try store.publish(rollup, committedAt: now)
        let candidates = store.verifiedRetirementCandidates(inputs: [input], now: now)

        XCTAssertFalse(publication.reusedExistingCommit)
        XCTAssertEqual(candidates, [.init(chunkID: "crash-safe",
                                          aggregateSHA256: AtriaHistoricalLongTermPlanner.sha256(
                                            input.aggregateData
                                          ),
                                          manifestURL: publication.manifestURL)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: publication.artifactURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: publication.manifestURL.path))
    }

    func testTamperedArtifactOrWrongSourceBytesNeverSelectsRetirement() throws {
        let input = try makeInput(id: "tamper", start: now.addingTimeInterval(-180 * 86_400))
        let planner = AtriaHistoricalLongTermPlanner()
        let rollup = try planner.build(group: [input], createdAt: now)
        let directory = temporaryDirectory()
        let store = AtriaHistoricalLongTermStore(directoryURL: directory)
        let publication = try store.publish(rollup, committedAt: now)
        var tamperedBytes = input.aggregateData
        tamperedBytes.append(0x20)
        let wrongInput = AtriaHistoricalLongTermPlanner.Input(aggregate: input.aggregate,
                                                               aggregateData: tamperedBytes)

        XCTAssertTrue(store.verifiedRetirementCandidates(inputs: [wrongInput], now: now).isEmpty)

        let handle = try FileHandle(forWritingTo: publication.artifactURL)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x20]))
        try handle.close()
        XCTAssertTrue(store.verifiedRetirementCandidates(inputs: [input], now: now).isEmpty)
    }

    func testManifestWithoutEverySourceInputFailsClosedForWholeMonthlyCommit() throws {
        let first = try makeInput(id: "first", start: now.addingTimeInterval(-181 * 86_400))
        let second = try makeInput(id: "second", start: now.addingTimeInterval(-180 * 86_400))
        let planner = AtriaHistoricalLongTermPlanner()
        let rollup = try planner.build(group: [first, second], createdAt: now)
        let store = AtriaHistoricalLongTermStore(directoryURL: temporaryDirectory())
        _ = try store.publish(rollup, committedAt: now)

        XCTAssertTrue(store.verifiedRetirementCandidates(inputs: [first], now: now).isEmpty)
        XCTAssertEqual(Set(store.verifiedRetirementCandidates(inputs: [first, second], now: now)
                       .map(\.chunkID)), ["first", "second"])
    }

    func testProjectionMetadataCannotAuthorizeRetirementWithoutLiveSemanticVerification() throws {
        let input = try makeInput(id: "projection-proof",
                                  start: now.addingTimeInterval(-180 * 86_400),
                                  includeReceipts: true)
        let planner = AtriaHistoricalLongTermPlanner()
        let rollup = try planner.build(group: [input], createdAt: now)
        let store = AtriaHistoricalLongTermStore(directoryURL: temporaryDirectory())
        _ = try store.publish(rollup, committedAt: now)

        XCTAssertTrue(store.verifiedRetirementCandidates(inputs: [input], now: now).isEmpty,
                      "copied receipt metadata must fail closed without its consumer artifact")

        var durableArtifactDigests = Dictionary(uniqueKeysWithValues:
            rollup.projectionReferences.map { ($0.identifier, $0.contentSHA256) })
        durableArtifactDigests.removeValue(forKey: rollup.projectionReferences[0].identifier)
        XCTAssertTrue(store.verifiedRetirementCandidates(
            inputs: [input],
            now: now,
            projectionVerifier: { reference in
                durableArtifactDigests[reference.identifier] == reference.contentSHA256
            }
        ).isEmpty, "one missing projection artifact must hold the source aggregate")

        durableArtifactDigests = Dictionary(uniqueKeysWithValues:
            rollup.projectionReferences.map { ($0.identifier, $0.contentSHA256) })
        durableArtifactDigests[rollup.projectionReferences[1].identifier] = String(repeating: "f", count: 64)
        XCTAssertTrue(store.verifiedRetirementCandidates(
            inputs: [input],
            now: now,
            projectionVerifier: { reference in
                durableArtifactDigests[reference.identifier] == reference.contentSHA256
            }
        ).isEmpty, "one hash-mismatched projection artifact must hold the source aggregate")

        durableArtifactDigests = Dictionary(uniqueKeysWithValues:
            rollup.projectionReferences.map { ($0.identifier, $0.contentSHA256) })
        XCTAssertEqual(store.verifiedRetirementCandidates(
            inputs: [input],
            now: now,
            projectionVerifier: { reference in
                durableArtifactDigests[reference.identifier] == reference.contentSHA256
            }
        ).map(\.chunkID), ["projection-proof"])
    }

    func testThirtyNinetyThreeSixtyFiveAndMultiYearFullDetailStoragePlateaus() throws {
        let planner = AtriaHistoricalLongTermPlanner(fullDetailHorizon: 90 * 86_400)
        var retainedCounts: [Int: Int] = [:]
        var retainedBytes: [Int: UInt64] = [:]
        var totalProjected: [Int: UInt64] = [:]
        var sourceBytes: [Int: UInt64] = [:]

        for dayCount in [30, 90, 365, 1_095] {
            let inputs = try (0..<dayCount).map { offset in
                try makeInput(id: "synthetic-\(offset)",
                              start: now.addingTimeInterval(-Double(offset + 1) * 86_400),
                              includeReceipts: false)
            }
            let plan = try planner.plan(inputs: inputs, now: now)
            let rollupBytes = try plan.groups.reduce(UInt64(0)) { partial, group in
                let rollup = try planner.build(group: group, createdAt: now)
                return partial + UInt64(try AtriaHistoricalLongTermPlanner.canonicalData(rollup).count)
            }
            retainedCounts[dayCount] = plan.retainedFullDetail.count
            retainedBytes[dayCount] = plan.retainedFullDetailBytes
            totalProjected[dayCount] = plan.retainedFullDetailBytes + rollupBytes
            sourceBytes[dayCount] = inputs.reduce(UInt64(0)) { $0 + UInt64($1.aggregateData.count) }
        }

        XCTAssertEqual(retainedCounts[30], 30)
        XCTAssertEqual(retainedCounts[90], 90)
        // Closed-month cutover retains the 90-day horizon plus at most one
        // incomplete UTC month, preventing an unmergeable partial rollup.
        XCTAssertLessThanOrEqual(try XCTUnwrap(retainedCounts[365]), 122)
        XCTAssertEqual(retainedCounts[365], retainedCounts[1_095])
        XCTAssertEqual(retainedBytes[365], retainedBytes[1_095],
                       "minute/motion aggregate storage must plateau at the configured horizon")
        XCTAssertLessThan(try XCTUnwrap(totalProjected[365]), try XCTUnwrap(sourceBytes[365]))
        XCTAssertLessThan(try XCTUnwrap(totalProjected[1_095]), try XCTUnwrap(sourceBytes[1_095]))
        XCTAssertLessThan(try XCTUnwrap(totalProjected[1_095]),
                          3 * (try XCTUnwrap(totalProjected[365])),
                          "multi-year decoded growth should remain below retained full-detail growth")
    }

    private func makeInput(id: String,
                           start: Date,
                           duration: TimeInterval = 3_600,
                           includeReceipts: Bool = false) throws -> AtriaHistoricalLongTermPlanner.Input {
        let minuteOne = AtriaHistoricalAggregateChunk.HeartRateMinute(
            minuteStart: start,
            sampleCount: 2,
            sumBPM: 130,
            minimumBPM: 60,
            maximumBPM: 70,
            samplesByBPM: [60: 1, 70: 1],
            terminalBPMSeconds: [80: 10],
            transitionHalfBPMSeconds: [140: 10],
            coveredSeconds: 10,
            droppedGapSeconds: 0,
            firstSampleUnix: start.timeIntervalSince1970,
            firstSampleBPM: 60,
            lastSampleUnix: start.addingTimeInterval(10).timeIntervalSince1970,
            lastSampleBPM: 70
        )
        let minuteTwo = AtriaHistoricalAggregateChunk.HeartRateMinute(
            minuteStart: start.addingTimeInterval(60),
            sampleCount: 2,
            sumBPM: 170,
            minimumBPM: 80,
            maximumBPM: 80 + 10,
            samplesByBPM: [80: 1, 80 + 10: 1],
            terminalBPMSeconds: [90: 10],
            transitionHalfBPMSeconds: [170: 10],
            coveredSeconds: 10,
            droppedGapSeconds: 1,
            firstSampleUnix: start.addingTimeInterval(60).timeIntervalSince1970,
            firstSampleBPM: 80,
            lastSampleUnix: start.addingTimeInterval(70).timeIntervalSince1970,
            lastSampleBPM: 90
        )
        let firstRR = rrEpoch(start: start.addingTimeInterval(300), intervals: [800, 900])
        let secondRR = rrEpoch(start: start.addingTimeInterval(600), intervals: [1000, 850])
        let firstMotion = motionEpoch(start: start.addingTimeInterval(900),
                                      stillness: 0.9,
                                      steps: nil)
        let secondMotion = motionEpoch(start: start.addingTimeInterval(930),
                                       stillness: nil,
                                       steps: 3)
        let projections: [AtriaHistoricalAggregateChunk.MaterializedProjection]
        if includeReceipts {
            projections = AtriaHistoricalAggregateChunk.rawRetirementRequiredProjectionKinds.map { kind in
                .init(kind: kind,
                      identifier: "consumer-receipt-\(kind.rawValue)-\(id)",
                      start: start,
                      end: start.addingTimeInterval(duration),
                      schemaVersion: 1,
                      contentSHA256: String(repeating: String(kind.rawValue.utf8.first! % 10), count: 64),
                      settledAt: start.addingTimeInterval(duration + 1))
            }.sorted { $0.kind.rawValue < $1.kind.rawValue }
        } else {
            projections = []
        }
        let aggregate = AtriaHistoricalAggregateChunk(
            schema: AtriaHistoricalAggregateChunk.currentSchema,
            createdAt: start.addingTimeInterval(duration + 10),
            source: .init(chunkID: id,
                          rawSHA256: String(repeating: "a", count: 64),
                          rawByteCount: 1_024,
                          rawRowCount: 8,
                          firstTimestamp: start,
                          lastTimestamp: start.addingTimeInterval(duration),
                          decoderSchema: HistoricalArchive.schema,
                          validatedLayouts: [HistoricalArchive.layoutVersion]),
            heartRateMinutes: [minuteOne, minuteTwo],
            rrEpochs: [firstRR, secondRR],
            motionEpochs: [firstMotion, secondMotion],
            materializedProjections: projections,
            parity: .init(rawRows: 8,
                          decodedRows: 8,
                          undecodableRowsRetainedRaw: 0,
                          metricUsableRows: 8,
                          heartRateSamples: 4,
                          heartRateSumBPM: 300,
                          acceptedRRBeats: 4,
                          acceptedRRSumMilliseconds: 3_550,
                          validatedGravityRows: 4,
                          motionEpochs: 2,
                          projectionReceipts: projections.count)
        )
        try aggregate.validateForCommit()
        return .init(aggregate: aggregate, aggregateData: try encoder.encode(aggregate))
    }

    private func rrEpoch(start: Date,
                         intervals: [Int]) -> AtriaHistoricalAggregateChunk.RREpoch {
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
                     projectionFingerprint: "rr-\(start.timeIntervalSince1970)",
                     provenance: "verified_whoop4_historical_v24")
    }

    private func motionEpoch(start: Date,
                             stillness: Double?,
                             steps: Int?) -> AtriaHistoricalAggregateChunk.MotionEpoch {
        .init(start: start,
              end: start.addingTimeInterval(30),
              rows: 3,
              validatedRows: 2,
              rejectedRows: 1,
              coverageSeconds: 30,
              maximumGapSeconds: 1,
              stillnessRatio: stillness,
              movementIntensity: stillness.map { 1 - $0 },
              p95VectorDelta: stillness.map { 0.2 + $0 },
              activityBursts: stillness == nil ? nil : 0,
              stepDelta: steps,
              measurementValidated: true,
              lowMotionQualified: stillness.map { $0 > 0.8 } ?? false,
              sleepStage: stillness == nil ? nil : "light",
              sleepStageConfidence: stillness == nil ? nil : 0.8,
              algorithmVersion: "motion-v1",
              provenance: "validated-gravity")
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalLongTermRollupTests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year,
                                                  month: month,
                                                  day: day,
                                                  hour: hour))!
    }
}
