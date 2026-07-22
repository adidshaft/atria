import XCTest
@testable import Atria

/// RESEARCH-ONLY all-day gyro-cadence shadow. These tests pin three honesty
/// properties: spans split at every device-time discontinuity (no fabricated
/// continuity), each closed span is scored by the exact batch detector, and
/// the journal field merges monotonically without ever feeding production.
final class AtriaGyroCadenceResearchShadowTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        ActiveSessionJournal.clear()
        ActiveSessionJournal.resetCachesForTesting()
    }

    override func tearDown() {
        ActiveSessionJournal.clear()
        ActiveSessionJournal.resetCachesForTesting()
        super.tearDown()
    }

    // MARK: - Signal + ingest helpers

    private func walkingMagnitudes(seconds: Double,
                                   cadenceHz: Double = 1.75,
                                   level: Double = 90,
                                   swing: Double = 45) -> [Double] {
        let sr = Double(AtriaGyroCadenceResearchPedometer.sampleRateHz)
        return (0..<Int(seconds * sr)).map { i in
            let t = Double(i) / sr
            return max(0, level + swing * sin(2 * .pi * cadenceHz * t))
        }
    }

    private func quietFrameMagnitudes() -> [Double] {
        [Double](repeating: 5, count: 100)
    }

    /// Ingests `samples` as consecutive one-second frames starting at
    /// `startTimestamp`, returning the first unused device second.
    @discardableResult
    private func ingest(_ shadow: AtriaGyroCadenceResearchShadow,
                        samples: [Double],
                        startTimestamp: UInt32) -> UInt32 {
        var timestamp = startTimestamp
        var index = 0
        while index < samples.count {
            let end = min(index + 100, samples.count)
            shadow.ingest(deviceTimestamp: timestamp,
                          rotationMagnitudes: Array(samples[index..<end])) { _ in }
            timestamp &+= 1
            index = end
        }
        return timestamp
    }

    // MARK: - Span scoring honesty

    func testGapClosedSpanScoresExactlyLikeBatchDetector() {
        let shadow = AtriaGyroCadenceResearchShadow()
        let walk = walkingMagnitudes(seconds: 40)
        let next = ingest(shadow, samples: walk, startTimestamp: 1_000)

        // Device-time hole of one second: the walking span must close and be
        // scored as-is; the quiet frame starts a fresh span.
        shadow.ingest(deviceTimestamp: next &+ 1,
                      rotationMagnitudes: quietFrameMagnitudes()) { _ in }

        let expected = AtriaGyroCadenceResearchPedometer.steps(
            contiguousRotationMagnitudes: walk
        )
        XCTAssertGreaterThan(expected, 0, "test signal must produce a scoreable bout")
        let snapshot = shadow.snapshotSynchronously()
        XCTAssertEqual(snapshot.totalSteps, expected, accuracy: 1e-9)
        XCTAssertEqual(snapshot.closedSpans, 1)
        XCTAssertEqual(shadow.openSpanSampleCountForTesting(), 100)
    }

    func testDeviceTimeDiscontinuityNeverConcatenatesSpans() {
        let shadow = AtriaGyroCadenceResearchShadow()
        let walkA = walkingMagnitudes(seconds: 30)
        let walkB = walkingMagnitudes(seconds: 30, cadenceHz: 2.2)
        ingest(shadow, samples: walkA, startTimestamp: 1_000)
        // Large jump: reconnect-style gap.
        ingest(shadow, samples: walkB, startTimestamp: 5_000)
        let snapshot = shadow.closeOpenSpanSynchronously()

        let scoredSeparately = AtriaGyroCadenceResearchPedometer.steps(
            contiguousRotationMagnitudes: walkA
        ) + AtriaGyroCadenceResearchPedometer.steps(
            contiguousRotationMagnitudes: walkB
        )
        XCTAssertGreaterThan(scoredSeparately, 0)
        XCTAssertEqual(snapshot.totalSteps, scoredSeparately, accuracy: 1e-9)
        XCTAssertEqual(snapshot.closedSpans, 2)
        XCTAssertEqual(shadow.openSpanSampleCountForTesting(), 0)
    }

    func testDuplicateStaleAndZeroTimestampFramesNeverExtendASpan() {
        let shadow = AtriaGyroCadenceResearchShadow()
        shadow.ingest(deviceTimestamp: 1_000,
                      rotationMagnitudes: quietFrameMagnitudes()) { _ in }
        // Duplicate, stale, and zero device seconds are all dropped: none may
        // add samples whose physical position cannot be proven.
        shadow.ingest(deviceTimestamp: 1_000,
                      rotationMagnitudes: quietFrameMagnitudes()) { _ in }
        shadow.ingest(deviceTimestamp: 999,
                      rotationMagnitudes: quietFrameMagnitudes()) { _ in }
        shadow.ingest(deviceTimestamp: 0,
                      rotationMagnitudes: quietFrameMagnitudes()) { _ in }
        XCTAssertEqual(shadow.openSpanSampleCountForTesting(), 100)

        // The frame after a dropped zero-timestamp second closes the span via
        // its own delta (2), so the unproven second is bridged by nothing.
        shadow.ingest(deviceTimestamp: 1_002,
                      rotationMagnitudes: quietFrameMagnitudes()) { _ in }
        let snapshot = shadow.snapshotSynchronously()
        XCTAssertEqual(snapshot.closedSpans, 1)
        XCTAssertEqual(shadow.openSpanSampleCountForTesting(), 100)
    }

    // MARK: - Memory-bounded size close with carried tail

    func testSizeBoundScoredPrefixPolicy() {
        XCTAssertNil(AtriaGyroCadenceResearchShadow.sizeBoundScoredPrefix(
            spanSampleCount: AtriaGyroCadenceResearchShadow.maxSpanSamples - 1
        ))
        XCTAssertEqual(AtriaGyroCadenceResearchShadow.sizeBoundScoredPrefix(
            spanSampleCount: 60_000
        ), 57_000)
        XCTAssertEqual(AtriaGyroCadenceResearchShadow.sizeBoundScoredPrefix(
            spanSampleCount: 60_100
        ), 57_100)
        // Degenerate configuration can never return a negative prefix.
        XCTAssertEqual(AtriaGyroCadenceResearchShadow.sizeBoundScoredPrefix(
            spanSampleCount: 10,
            maxSpanSamples: 10,
            carrySamples: 50
        ), 0)
    }

    func testLongContiguousSpanClosesAtSizeBoundAndStaysMemoryBounded() {
        let shadow = AtriaGyroCadenceResearchShadow()
        // 601 contiguous quiet seconds cross the 60_000-sample bound once.
        for second in 0..<601 {
            shadow.ingest(deviceTimestamp: UInt32(1_000 + second),
                          rotationMagnitudes: quietFrameMagnitudes()) { _ in }
        }
        let snapshot = shadow.snapshotSynchronously()
        XCTAssertEqual(snapshot.totalSteps, 0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.closedSpans, 1)
        // Scored prefix released; only the carried tail plus the newest frame
        // remain resident.
        XCTAssertEqual(shadow.openSpanSampleCountForTesting(),
                       AtriaGyroCadenceResearchShadow.carrySamples + 100)
    }

    func testLongContiguousWalkScoresWithoutAnyGapEverArriving() {
        let shadow = AtriaGyroCadenceResearchShadow()
        let cadence = 1.75
        let walk = walkingMagnitudes(seconds: 601, cadenceHz: cadence)
        ingest(shadow, samples: walk, startTimestamp: 10_000)
        // No discontinuity occurred: the size-bound close alone must have
        // scored the 570-second prefix (the 30 s carry is still open).
        let snapshot = shadow.snapshotSynchronously()
        let scoredSeconds = 570.0
        XCTAssertGreaterThan(snapshot.totalSteps, scoredSeconds * cadence * 0.85)
        XCTAssertLessThan(snapshot.totalSteps, scoredSeconds * cadence * 1.05)
        XCTAssertEqual(snapshot.closedSpans, 1)
    }

    // MARK: - Session mapping policy

    func testGyroCadenceResearchSessionStepsPolicy() {
        XCTAssertEqual(AtriaBLEManager.gyroCadenceResearchSessionSteps(
            restoredPrefixSteps: 100, shadowTotalSteps: 40.4, sessionBaselineSteps: 10
        ), 130)
        // A rebase ahead of the total (stale snapshot) never goes negative.
        XCTAssertEqual(AtriaBLEManager.gyroCadenceResearchSessionSteps(
            restoredPrefixSteps: 100, shadowTotalSteps: 5, sessionBaselineSteps: 50
        ), 100)
        XCTAssertEqual(AtriaBLEManager.gyroCadenceResearchSessionSteps(
            restoredPrefixSteps: -3, shadowTotalSteps: 12, sessionBaselineSteps: 0
        ), 12)
        XCTAssertEqual(AtriaBLEManager.gyroCadenceResearchSessionSteps(
            restoredPrefixSteps: 10_000_000, shadowTotalSteps: 99, sessionBaselineSteps: 0
        ), 10_000_000)
    }

    // MARK: - Journal merge discipline

    func testJournalGyroCadenceResearchStepsMergeMonotonically() throws {
        var initial = record(sampleCount: 2, rrCount: 1)
        initial.gyroCadenceResearchSteps = 200
        try ActiveSessionJournal.save(initial)

        // A delayed/lower checkpoint must never downgrade the persisted total.
        var delayed = record(id: initial.id, sampleCount: 4, rrCount: 2)
        delayed.gyroCadenceResearchSteps = 5
        try ActiveSessionJournal.save(delayed, previousSampleCount: 2, previousRRCount: 1)
        ActiveSessionJournal.resetCachesForTesting()
        var restored = try XCTUnwrap(ActiveSessionJournal.load())
        XCTAssertEqual(restored.gyroCadenceResearchSteps, 200)

        var advanced = record(id: initial.id, sampleCount: 6, rrCount: 3)
        advanced.gyroCadenceResearchSteps = 260
        try ActiveSessionJournal.save(advanced, previousSampleCount: 4, previousRRCount: 2)
        ActiveSessionJournal.resetCachesForTesting()
        restored = try XCTUnwrap(ActiveSessionJournal.load())
        XCTAssertEqual(restored.gyroCadenceResearchSteps, 260)
    }

    func testPreSchemaRecordDecodesWithNilGyroCadenceResearchSteps() throws {
        let data = try JSONEncoder().encode(record(sampleCount: 2, rrCount: 1))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["gyroCadenceResearchSteps"],
                     "nil research field must be omitted so old readers stay compatible")
        let decoded = try JSONDecoder().decode(ActiveSessionJournalRecord.self, from: data)
        XCTAssertNil(decoded.gyroCadenceResearchSteps)
        XCTAssertEqual(
            AtriaBLEManager.validatedResearchAggregates(from: decoded)?.gyroCadenceResearchSteps,
            0
        )
    }

    func testValidatedResearchAggregatesFailClosedForImplausibleGyroSteps() throws {
        var malformed = record(sampleCount: 2, rrCount: 1)
        malformed.gyroCadenceResearchSteps = 10_000_001
        XCTAssertNil(AtriaBLEManager.validatedResearchAggregates(from: malformed))
        malformed.gyroCadenceResearchSteps = -1
        XCTAssertNil(AtriaBLEManager.validatedResearchAggregates(from: malformed))
        malformed.gyroCadenceResearchSteps = 4_321
        XCTAssertEqual(
            AtriaBLEManager.validatedResearchAggregates(from: malformed)?.gyroCadenceResearchSteps,
            4_321
        )
    }

    // MARK: - Research isolation source scans

    private func productionSource(_ fileName: String) throws -> String {
        let sourcesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        return try String(contentsOf: sourcesDirectory.appendingPathComponent(fileName),
                          encoding: .utf8)
    }

    func testGyroCadenceResearchShadowOnlyReachesScopedAmbulatoryWorkoutSurface() throws {
        // The calibrated challenger is authorized only as an estimated source
        // frozen by an explicit walking/running/hiking workout. It must remain
        // absent from daily totals, saved-session production fields and every
        // non-workout surface.
        let userFacingFiles = [
            "AtriaTodayScreen.swift",
            "AtriaOverviewSections.swift",
            "AtriaShareCard.swift",
            "WidgetSnapshot.swift",
            "AtriaLiveActivityAttributes.swift",
            "Sessions.swift",
            "DailyRollupStore.swift"
        ]
        for fileName in userFacingFiles {
            let source = try productionSource(fileName)
            XCTAssertFalse(source.lowercased().contains("gyrocadence"),
                           "\(fileName) must never reference the gyro-cadence research shadow")
        }
        let home = try productionSource("AtriaHomeView.swift")
        XCTAssertTrue(home.contains("strapGyroCadenceAmbulatoryV1"))
        XCTAssertFalse(home.contains("liveStrapStepResearchTodayCount = gyro"))
        let workout = try productionSource("AtriaLiveWorkoutView.swift")
        XCTAssertTrue(workout.contains("stepSourceVersion"))
    }

    func testGyroCadenceResearchShadowIsWiredReadOnlyInAtomicR10Pipeline() throws {
        let source = try productionSource("AtriaR10Motion.swift")
        XCTAssertTrue(source.contains("gyroCadenceState.ingest("),
                      "the shadow must consume accepted frames on the atomic R10 queue")
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.localizedCaseInsensitiveContains("gyroCadence") else { continue }
            for forbidden in ["dailySteps",
                              "liveStrapStep",
                              "AtriaStrapStepLedger",
                              "strapStepResearchCount =",
                              "writeValue"] {
                XCTAssertFalse(line.contains(forbidden),
                               "research shadow line must not touch production step state: \(line)")
            }
        }
    }
}

// MARK: - Journal record fixture

private extension AtriaGyroCadenceResearchShadowTests {
    func record(id: UUID = UUID(),
                sampleCount: Int,
                rrCount: Int) -> ActiveSessionJournalRecord {
        ActiveSessionJournalRecord(
            schema: ActiveSessionJournal.schema,
            id: id,
            label: "Test session",
            startedAt: baseDate,
            updatedAt: baseDate.addingTimeInterval(Double(sampleCount)),
            samples: (0..<sampleCount).map {
                ActiveSessionJournalRecord.Sample(t: baseDate.addingTimeInterval(Double($0)),
                                                  bpm: 70 + $0)
            },
            rrSamples: (0..<rrCount).map {
                ActiveSessionJournalRecord.RRSample(
                    t: baseDate.addingTimeInterval(Double($0)),
                    ms: 800 + $0,
                    source: .standardHeartRateMeasurement2A37
                )
            },
            rawHRNotifications: sampleCount,
            acceptedHRSamples: sampleCount,
            zeroHRSamples: 0,
            heldArtifacts: 0,
            droppedArtifacts: 0,
            rawHRGaps: 0,
            acceptedHRGaps: 0,
            maxRawHRGap: 1,
            maxAcceptedHRGap: 1,
            batteryLevel: 80,
            thermalState: "nominal",
            lowPowerMode: false,
            powerMode: "normal",
            cadenceMultiplier: 1,
            strengthSets: nil,
            excludedIntervals: nil
        )
    }
}
