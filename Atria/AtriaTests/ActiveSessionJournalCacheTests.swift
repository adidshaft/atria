import XCTest
@testable import Atria

final class ActiveSessionJournalCacheTests: XCTestCase {
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

    func testUnchangedSegmentedLoadReconstructsOnlyOnce() throws {
        try ActiveSessionJournal.save(record(sampleCount: 2, rrCount: 2))
        ActiveSessionJournal.resetCachesForTesting()

        XCTAssertEqual(try XCTUnwrap(ActiveSessionJournal.load()).samples.count, 2)
        XCTAssertEqual(ActiveSessionJournal.segmentedReconstructionCountForTesting, 1)

        for _ in 0..<20 {
            XCTAssertEqual(try XCTUnwrap(ActiveSessionJournal.load()).samples.count, 2)
        }
        XCTAssertEqual(ActiveSessionJournal.segmentedReconstructionCountForTesting, 1)
    }

    func testSaveUpdatesCachedReconstructionExactly() throws {
        let initial = record(sampleCount: 2, rrCount: 1)
        try ActiveSessionJournal.save(initial)
        ActiveSessionJournal.resetCachesForTesting()
        _ = try XCTUnwrap(ActiveSessionJournal.load())

        var appended = record(id: initial.id, sampleCount: 5, rrCount: 4)
        appended.updatedAt = baseDate.addingTimeInterval(10)
        appended.rawHRNotifications = 8
        try ActiveSessionJournal.save(appended, previousSampleCount: 2, previousRRCount: 1)

        let loaded = try XCTUnwrap(ActiveSessionJournal.load())
        XCTAssertEqual(loaded.samples.map(\.bpm), appended.samples.map(\.bpm))
        XCTAssertEqual(loaded.rrSamples?.map(\.ms), appended.rrSamples?.map(\.ms))
        XCTAssertEqual(loaded.rawHRNotifications, 8)
        XCTAssertEqual(loaded.updatedAt, appended.updatedAt)
        XCTAssertEqual(ActiveSessionJournal.segmentedReconstructionCountForTesting, 1)
    }

    func testIncrementalSaveReconstructsExactRecordAndRejectsCursorGaps() throws {
        let initial = record(sampleCount: 3, rrCount: 2)
        try ActiveSessionJournal.save(initial)
        var complete = record(id: initial.id, sampleCount: 7, rrCount: 5)
        complete.updatedAt = baseDate.addingTimeInterval(20)
        complete.rawHRNotifications = 19
        var delta = complete
        delta.samples = Array(complete.samples.dropFirst(3))
        delta.rrSamples = Array((complete.rrSamples ?? []).dropFirst(2))

        _ = try ActiveSessionJournal.saveIncremental(delta,
                                                     sampleStartIndex: 3,
                                                     rrSampleStartIndex: 2,
                                                     maxAge: 1_000,
                                                     maxSamples: 100)
        ActiveSessionJournal.resetCachesForTesting()
        let recovered = try XCTUnwrap(ActiveSessionJournal.load())
        XCTAssertEqual(recovered.samples.map(\.bpm), complete.samples.map(\.bpm))
        XCTAssertEqual(recovered.rrSamples?.map(\.ms), complete.rrSamples?.map(\.ms))
        XCTAssertEqual(recovered.rawHRNotifications, 19)

        XCTAssertThrowsError(try ActiveSessionJournal.saveIncremental(delta,
                                                                       sampleStartIndex: 3,
                                                                       rrSampleStartIndex: 2,
                                                                       maxAge: 1_000,
                                                                       maxSamples: 100))
    }

    func testIncrementalSaveCompactsToAgeAndCountBoundsThenContinues() throws {
        let initial = record(sampleCount: 6, rrCount: 6)
        try ActiveSessionJournal.save(initial)
        var delta = record(id: initial.id, sampleCount: 8, rrCount: 8)
        delta.updatedAt = baseDate.addingTimeInterval(8)
        delta.samples = Array(delta.samples.dropFirst(6))
        delta.rrSamples = Array((delta.rrSamples ?? []).dropFirst(6))
        let compacted = try ActiveSessionJournal.saveIncremental(delta,
                                                                 sampleStartIndex: 6,
                                                                 rrSampleStartIndex: 6,
                                                                 maxAge: 4,
                                                                 maxSamples: 4)
        XCTAssertTrue(compacted.compacted)
        XCTAssertEqual(compacted.sampleCount, 4)
        XCTAssertEqual(ActiveSessionJournal.load()?.samples.map(\.bpm), [74, 75, 76, 77])

        var tail = record(id: initial.id, sampleCount: 9, rrCount: 9)
        tail.updatedAt = baseDate.addingTimeInterval(9)
        tail.samples = [tail.samples[8]]
        tail.rrSamples = [try XCTUnwrap(tail.rrSamples)[8]]
        let continued = try ActiveSessionJournal.saveIncremental(tail,
                                                                 sampleStartIndex: 4,
                                                                 rrSampleStartIndex: 4,
                                                                 maxAge: 4,
                                                                 maxSamples: 4)
        XCTAssertEqual(continued.sampleCount, 4)
        XCTAssertEqual(ActiveSessionJournal.load()?.samples.map(\.bpm), [75, 76, 77, 78])
    }

    func testCursorMismatchCanRecoverWithFreshBoundedBaseline() throws {
        let initial = record(sampleCount: 3, rrCount: 2)
        try ActiveSessionJournal.save(initial)
        XCTAssertThrowsError(try ActiveSessionJournal.saveIncremental(initial,
                                                                       sampleStartIndex: 1,
                                                                       rrSampleStartIndex: 2,
                                                                       maxAge: 100,
                                                                       maxSamples: 100))
        ActiveSessionJournal.clear()
        let recovered = try ActiveSessionJournal.saveIncremental(initial,
                                                                 sampleStartIndex: 0,
                                                                 rrSampleStartIndex: 0,
                                                                 maxAge: 100,
                                                                 maxSamples: 100)
        XCTAssertEqual(recovered.sampleCount, 3)
        XCTAssertEqual(ActiveSessionJournal.load()?.samples.map(\.bpm), initial.samples.map(\.bpm))
    }

    func testMirrorUpdatesCacheAndLightweightStateWithoutReplay() throws {
        try ActiveSessionJournal.save(record(sampleCount: 3, rrCount: 2))
        let set = LoggedSet(exercise: "Bench press",
                            weightKg: 80,
                            reps: 5,
                            rpe: 8,
                            t: baseDate.addingTimeInterval(3))
        let interval = ExcludedInterval(start: baseDate.addingTimeInterval(1),
                                        end: baseDate.addingTimeInterval(2))
        try ActiveSessionJournal.mirrorStrengthState(strengthSets: [set], excludedIntervals: [interval])
        ActiveSessionJournal.resetCachesForTesting()

        let reconstructionCountBeforeMirrorRead = ActiveSessionJournal.segmentedReconstructionCountForTesting
        let mirrored = try XCTUnwrap(ActiveSessionJournal.latestMirroredStrengthState())
        XCTAssertEqual(mirrored.strengthSets, [set])
        XCTAssertEqual(mirrored.excludedIntervals, [interval])
        XCTAssertEqual(ActiveSessionJournal.segmentedReconstructionCountForTesting,
                       reconstructionCountBeforeMirrorRead)

        let loaded = try XCTUnwrap(ActiveSessionJournal.load())
        XCTAssertEqual(loaded.samples.count, 3)
        XCTAssertEqual(loaded.strengthSets, [set])
        XCTAssertEqual(ActiveSessionJournal.segmentedReconstructionCountForTesting,
                       reconstructionCountBeforeMirrorRead + 1)
    }

    func testStrengthMirrorPersistsOffMainThread() throws {
        try ActiveSessionJournal.save(record(sampleCount: 3, rrCount: 2))
        let set = LoggedSet(exercise: "Squat",
                            weightKg: 100,
                            reps: 5,
                            rpe: 8,
                            t: baseDate)

        let enqueued = expectation(description: "mirror enqueued from main")
        DispatchQueue.main.async {
            try? ActiveSessionJournal.mirrorStrengthState(strengthSets: [set], excludedIntervals: [])
            enqueued.fulfill()
        }
        wait(for: [enqueued], timeout: 2)
        ActiveSessionJournal.drainStrengthMirrorWrites()

        XCTAssertFalse(ActiveSessionJournal.lastStrengthMirrorPersistenceWasOnMainThreadForTesting)
        XCTAssertEqual(ActiveSessionJournal.strengthMirrorGenerationsForTesting.requested, 1)
        XCTAssertEqual(ActiveSessionJournal.strengthMirrorGenerationsForTesting.persisted, 1)
        ActiveSessionJournal.resetCachesForTesting()
        XCTAssertEqual(ActiveSessionJournal.load()?.strengthSets, [set])
    }

    func testQueuedStrengthMirrorsPreserveLatestWriteOrderingAndDurability() throws {
        try ActiveSessionJournal.save(record(sampleCount: 3, rrCount: 2))
        let first = LoggedSet(exercise: "Bench press",
                              weightKg: 70,
                              reps: 8,
                              rpe: 7,
                              t: baseDate)
        let latest = LoggedSet(exercise: "Bench press",
                               weightKg: 75,
                               reps: 6,
                               rpe: 8,
                               t: baseDate.addingTimeInterval(30))
        let interval = ExcludedInterval(start: baseDate.addingTimeInterval(10),
                                        end: baseDate.addingTimeInterval(20))

        try ActiveSessionJournal.mirrorStrengthState(strengthSets: [first], excludedIntervals: [])
        try ActiveSessionJournal.mirrorStrengthState(strengthSets: [first, latest],
                                                     excludedIntervals: [interval])

        let pending = try XCTUnwrap(ActiveSessionJournal.latestMirroredStrengthState())
        XCTAssertEqual(pending.strengthSets, [first, latest])
        XCTAssertEqual(pending.excludedIntervals, [interval])

        ActiveSessionJournal.drainStrengthMirrorWrites()
        XCTAssertEqual(ActiveSessionJournal.strengthMirrorGenerationsForTesting.requested, 2)
        XCTAssertEqual(ActiveSessionJournal.strengthMirrorGenerationsForTesting.persisted, 2)
        ActiveSessionJournal.resetCachesForTesting()

        let durable = try XCTUnwrap(ActiveSessionJournal.load())
        XCTAssertEqual(durable.strengthSets, [first, latest])
        XCTAssertEqual(durable.excludedIntervals, [interval])
    }

    func testCacheResetReplaysExactSamplesAndSkipsCorruptNewestSegment() throws {
        let initial = record(sampleCount: 2, rrCount: 2)
        try ActiveSessionJournal.save(initial)
        let appended = record(id: initial.id, sampleCount: 4, rrCount: 3)
        try ActiveSessionJournal.save(appended, previousSampleCount: 2, previousRRCount: 2)

        let corruptURL = try segmentDirectoryURL()
            .appendingPathComponent("segment-00000002.json")
        try Data("interrupted write".utf8).write(to: corruptURL)
        ActiveSessionJournal.resetCachesForTesting()

        let recovered = try XCTUnwrap(ActiveSessionJournal.load())
        XCTAssertEqual(recovered.samples.map(\.bpm), appended.samples.map(\.bpm))
        XCTAssertEqual(recovered.rrSamples?.map(\.ms), appended.rrSamples?.map(\.ms))
        XCTAssertEqual(ActiveSessionJournal.segmentedReconstructionCountForTesting, 1)
    }

    func testCorruptMiddleSegmentDoesNotDiscardValidTail() throws {
        let initial = record(sampleCount: 2, rrCount: 1)
        try ActiveSessionJournal.save(initial)

        var middle = record(id: initial.id, sampleCount: 5, rrCount: 3)
        middle.updatedAt = baseDate.addingTimeInterval(5)
        try ActiveSessionJournal.save(middle, previousSampleCount: 2, previousRRCount: 1)

        var tail = record(id: initial.id, sampleCount: 8, rrCount: 5)
        tail.updatedAt = baseDate.addingTimeInterval(8)
        tail.rawHRNotifications = 12
        tail.strengthSets = [LoggedSet(exercise: "Bench press",
                                       weightKg: 80,
                                       reps: 6,
                                       rpe: 8,
                                       t: baseDate.addingTimeInterval(7))]
        try ActiveSessionJournal.save(tail, previousSampleCount: 5, previousRRCount: 3)

        let corruptMiddleURL = try segmentDirectoryURL()
            .appendingPathComponent("segment-00000001.json")
        try Data("interrupted middle write".utf8).write(to: corruptMiddleURL)
        ActiveSessionJournal.resetCachesForTesting()

        let recovered = try XCTUnwrap(ActiveSessionJournal.load())
        XCTAssertEqual(recovered.samples.map(\.bpm), tail.samples.map(\.bpm))
        XCTAssertEqual(recovered.rrSamples?.map(\.ms), tail.rrSamples?.map(\.ms))
        XCTAssertEqual(recovered.updatedAt, tail.updatedAt)
        XCTAssertEqual(recovered.rawHRNotifications, 12)
        XCTAssertEqual(recovered.strengthSets, tail.strengthSets)
        XCTAssertEqual(ActiveSessionJournal.segmentedReconstructionCountForTesting, 1)
    }

    func testNewestSegmentMetadataChangeInvalidatesLiveCache() throws {
        let initial = record(sampleCount: 2, rrCount: 1)
        try ActiveSessionJournal.save(initial)
        let appended = record(id: initial.id, sampleCount: 4, rrCount: 2)
        try ActiveSessionJournal.save(appended, previousSampleCount: 2, previousRRCount: 1)
        ActiveSessionJournal.resetCachesForTesting()
        _ = try XCTUnwrap(ActiveSessionJournal.load())
        XCTAssertEqual(ActiveSessionJournal.segmentedReconstructionCountForTesting, 1)

        let latestURL = try segmentDirectoryURL()
            .appendingPathComponent("segment-00000001.json")
        var data = try Data(contentsOf: latestURL)
        data.append(0x20)
        try data.write(to: latestURL)

        let reloaded = try XCTUnwrap(ActiveSessionJournal.load())
        XCTAssertEqual(reloaded.samples.map(\.bpm), appended.samples.map(\.bpm))
        XCTAssertEqual(ActiveSessionJournal.segmentedReconstructionCountForTesting, 2)
    }

    func testLatestMirroredStrengthStateFallsBackToLegacySnapshot() throws {
        let set = LoggedSet(exercise: "Deadlift",
                            weightKg: 120,
                            reps: 3,
                            rpe: 9,
                            t: baseDate)
        var legacy = record(sampleCount: 1, rrCount: 0)
        legacy.strengthSets = [set]
        try JSONEncoder().encode(legacy).write(to: XCTUnwrap(ActiveSessionJournal.url), options: .atomic)
        ActiveSessionJournal.resetCachesForTesting()

        let mirrored = try XCTUnwrap(ActiveSessionJournal.latestMirroredStrengthState())
        XCTAssertEqual(mirrored.strengthSets, [set])
        XCTAssertNil(mirrored.excludedIntervals)
    }

    func testClearInvalidatesSegmentedAndMirroredState() throws {
        try ActiveSessionJournal.save(record(sampleCount: 2, rrCount: 1))
        _ = ActiveSessionJournal.load()

        ActiveSessionJournal.clear()

        XCTAssertNil(ActiveSessionJournal.load())
        XCTAssertNil(ActiveSessionJournal.latestMirroredStrengthState())
    }

    func testConcurrentCachedLoadsRemainConsistent() throws {
        let expected = record(sampleCount: 20, rrCount: 10)
        try ActiveSessionJournal.save(expected)
        ActiveSessionJournal.resetCachesForTesting()

        let queue = DispatchQueue(label: "ActiveSessionJournalCacheTests", attributes: .concurrent)
        let group = DispatchGroup()
        let resultLock = NSLock()
        var sampleCounts: [Int] = []
        for _ in 0..<40 {
            group.enter()
            queue.async {
                let count = ActiveSessionJournal.load()?.samples.count ?? -1
                resultLock.lock()
                sampleCounts.append(count)
                resultLock.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(sampleCounts, Array(repeating: 20, count: 40))
        XCTAssertEqual(ActiveSessionJournal.segmentedReconstructionCountForTesting, 1)
    }

    func testRestoreAcceptanceRequiresCurrentGenerationAndNoLiveSession() {
        XCTAssertTrue(AtriaBLEManager.shouldAcceptActiveSessionJournalRestore(
            requestGeneration: 7,
            currentGeneration: 7,
            longWearRelevant: true,
            hasLiveSession: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldAcceptActiveSessionJournalRestore(
            requestGeneration: 7,
            currentGeneration: 8,
            longWearRelevant: true,
            hasLiveSession: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldAcceptActiveSessionJournalRestore(
            requestGeneration: 7,
            currentGeneration: 7,
            longWearRelevant: false,
            hasLiveSession: false
        ))
        XCTAssertFalse(AtriaBLEManager.shouldAcceptActiveSessionJournalRestore(
            requestGeneration: 7,
            currentGeneration: 7,
            longWearRelevant: true,
            hasLiveSession: true
        ))
    }

    func testResearchAggregatesRoundTripThroughSegmentReplay() throws {
        var initial = record(sampleCount: 2, rrCount: 1)
        initial.eventTimeZoneIdentifier = "Asia/Kolkata"
        initial.sensorResearchProbeFrames = 12
        initial.spo2ResearchCandidateFrames = 4
        initial.skinTempResearchCandidateFrames = 3
        initial.skinTempResearchCandidateValueSum = 10_815
        initial.skinTempResearchCandidateValueCount = 3
        initial.strapStepResearchCount = 75
        initial.strapStepResearchRawCount = 68
        initial.strapStepResearchState = "r10_live_calibrating"
        try ActiveSessionJournal.save(initial)

        var appended = record(id: initial.id, sampleCount: 4, rrCount: 2)
        appended.sensorResearchProbeFrames = 29
        appended.spo2ResearchCandidateFrames = 9
        appended.skinTempResearchCandidateFrames = 7
        appended.skinTempResearchCandidateValueSum = 25_249
        appended.skinTempResearchCandidateValueCount = 7
        appended.strapStepResearchCount = 142
        appended.strapStepResearchRawCount = 128
        appended.strapStepResearchState = "r10_live_calibrating"
        try ActiveSessionJournal.save(appended, previousSampleCount: 2, previousRRCount: 1)
        ActiveSessionJournal.resetCachesForTesting()

        let loaded = try XCTUnwrap(ActiveSessionJournal.load())
        XCTAssertEqual(loaded.sensorResearchProbeFrames, 29)
        XCTAssertEqual(loaded.eventTimeZoneIdentifier, "Asia/Kolkata")
        XCTAssertEqual(loaded.spo2ResearchCandidateFrames, 9)
        XCTAssertEqual(loaded.skinTempResearchCandidateFrames, 7)
        XCTAssertEqual(loaded.skinTempResearchCandidateValueSum, 25_249)
        XCTAssertEqual(loaded.skinTempResearchCandidateValueCount, 7)
        XCTAssertEqual(loaded.strapStepResearchCount, 142)
        XCTAssertEqual(loaded.strapStepResearchRawCount, 128)
        XCTAssertEqual(loaded.strapStepResearchState, "r10_live_calibrating")
    }

    func testDelayedLowerStepCheckpointCannotRegressJournalRestoreState() throws {
        var initial = record(sampleCount: 2, rrCount: 1)
        initial.strapStepResearchCount = 123
        initial.strapStepResearchRawCount = 111
        initial.strapStepResearchState = "r10_live_preliminary"
        try ActiveSessionJournal.save(initial)

        var delayed = record(id: initial.id, sampleCount: 4, rrCount: 2)
        delayed.strapStepResearchCount = 4
        delayed.strapStepResearchRawCount = 4
        delayed.strapStepResearchState = "connection_local"
        try ActiveSessionJournal.save(delayed, previousSampleCount: 2, previousRRCount: 1)
        ActiveSessionJournal.resetCachesForTesting()

        let restored = try XCTUnwrap(ActiveSessionJournal.load())
        XCTAssertEqual(restored.strapStepResearchCount, 123)
        XCTAssertEqual(restored.strapStepResearchRawCount, 111)
        XCTAssertEqual(restored.strapStepResearchState, "r10_live_preliminary")
    }

    func testLegacyRecordWithoutResearchAggregatesDecodesAsZeroRestoreState() throws {
        let data = try JSONEncoder().encode(record(sampleCount: 2, rrCount: 1))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["sensorResearchProbeFrames"])
        XCTAssertNil(object["skinTempResearchCandidateValueSum"])

        let decoded = try JSONDecoder().decode(ActiveSessionJournalRecord.self, from: data)
        XCTAssertEqual(AtriaBLEManager.validatedResearchAggregates(from: decoded), .zero)
    }

    func testResearchAggregateRestoreIsExactAndFailClosedForMalformedValues() {
        var valid = record(sampleCount: 2, rrCount: 1)
        valid.sensorResearchProbeFrames = 17
        valid.spo2ResearchCandidateFrames = 5
        valid.skinTempResearchCandidateFrames = 4
        valid.skinTempResearchCandidateValueSum = 14_432
        valid.skinTempResearchCandidateValueCount = 4
        valid.strapStepResearchCount = 111
        valid.strapStepResearchRawCount = 100
        valid.strapStepResearchState = "r10_live_calibrating"

        let restored = AtriaBLEManager.validatedResearchAggregates(from: valid)
        XCTAssertEqual(restored?.sensorProbeFrames, 17)
        XCTAssertEqual(restored?.spo2CandidateFrames, 5)
        XCTAssertEqual(restored?.skinTempCandidateFrames, 4)
        XCTAssertEqual(restored?.skinTempCandidateValueSum, 14_432)
        XCTAssertEqual(restored?.skinTempCandidateValueCount, 4)
        XCTAssertEqual(restored?.strapSteps, 111)
        XCTAssertEqual(restored?.strapRawSteps, 100)
        XCTAssertEqual(restored?.strapStepState, "r10_live_calibrating")

        var incompleteTemperature = valid
        incompleteTemperature.skinTempResearchCandidateValueCount = nil
        XCTAssertNil(AtriaBLEManager.validatedResearchAggregates(from: incompleteTemperature))

        var negativeCounter = valid
        negativeCounter.spo2ResearchCandidateFrames = -1
        XCTAssertNil(AtriaBLEManager.validatedResearchAggregates(from: negativeCounter))

        var malformedZeroCount = valid
        malformedZeroCount.skinTempResearchCandidateValueCount = 0
        XCTAssertNil(AtriaBLEManager.validatedResearchAggregates(from: malformedZeroCount))

        var incompleteSteps = valid
        incompleteSteps.strapStepResearchRawCount = nil
        XCTAssertNil(AtriaBLEManager.validatedResearchAggregates(from: incompleteSteps))

        XCTAssertFalse(AtriaResearchProbe.validatedSpO2DecoderAvailable)
        XCTAssertFalse(AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable)
    }

    func testRestorePreparationBuildsBoundedLiveArraysAndCachesOffActor() throws {
        var source = record(sampleCount: 100, rrCount: 0)
        source.rrSamples = (90..<100).map {
            ActiveSessionJournalRecord.RRSample(
                t: baseDate.addingTimeInterval(Double($0)),
                ms: 700 + $0
            )
        }
        source.strapStepResearchCount = 88
        source.strapStepResearchRawCount = 80
        source.strapStepResearchState = "r10_live_calibrating"

        let prepared = AtriaBLEManager.prepareActiveSessionJournalRestore(
            source,
            now: source.updatedAt.addingTimeInterval(1),
            maxAge: 1_000,
            maxSamples: 8,
            segmentGapLimit: 90,
            biologicalSex: .unspecified
        )
        guard case let .live(payload) = prepared.payload else {
            return XCTFail("Expected a live restore payload")
        }

        XCTAssertEqual(payload.session.map(\.bpm), Array(162...169))
        XCTAssertEqual(payload.sessionPoints.map(\.t), Array(0...7).map(Double.init))
        XCTAssertEqual(payload.rrArchive.count, 8)
        XCTAssertEqual(payload.rrPoints.count, 8)
        XCTAssertEqual(payload.stats.minimum, 162)
        XCTAssertEqual(payload.stats.maximum, 169)
        XCTAssertEqual(payload.stats.total, 1_324)
        XCTAssertEqual(payload.stats.count, 8)
        XCTAssertEqual(payload.stats.mean, 165.5, accuracy: 0.000_001)
        XCTAssertEqual(payload.stats.m2, 42, accuracy: 0.000_001)
        XCTAssertEqual(payload.lastHeartRates, Array(162...169))
        XCTAssertEqual(payload.recentValid, Array(165...169))
        XCTAssertEqual(payload.displayHeartRate, 167)
        XCTAssertEqual(payload.researchAggregates?.strapSteps, 88)
        XCTAssertEqual(payload.researchAggregates?.strapRawSteps, 80)
    }

    func testRestorePreparationBuildsFinishedSessionBeforeMainActorPublication() throws {
        let source = record(sampleCount: 4, rrCount: 3)
        let prepared = AtriaBLEManager.prepareActiveSessionJournalRestore(
            source,
            now: source.updatedAt.addingTimeInterval(95),
            maxAge: 1_000,
            maxSamples: 90_000,
            segmentGapLimit: 90,
            biologicalSex: .female
        )
        guard case let .staleSegment(payload) = prepared.payload else {
            return XCTFail("Expected a stale-segment save payload")
        }

        XCTAssertEqual(payload.savedSession.id, source.id)
        XCTAssertEqual(payload.savedSession.points.map(\.bpm), [70, 71, 72, 73])
        XCTAssertEqual(payload.savedSession.rrSampleCount, 3)
        XCTAssertEqual(payload.savedSession.biologicalSex, .female)
        XCTAssertEqual(payload.age, 95, accuracy: 0.000_001)
    }

    func testConditionalClearCannotEraseNewerJournalCheckpoint() throws {
        let initial = record(sampleCount: 2, rrCount: 1)
        try ActiveSessionJournal.save(initial)
        let newer = record(id: initial.id, sampleCount: 3, rrCount: 2)
        try ActiveSessionJournal.save(newer, previousSampleCount: 2, previousRRCount: 1)

        XCTAssertFalse(ActiveSessionJournal.clearIfUnchanged(
            id: initial.id,
            updatedAt: initial.updatedAt,
            schema: initial.schema,
            sampleCount: initial.samples.count,
            rrSampleCount: initial.rrSamples?.count ?? 0
        ))
        XCTAssertEqual(ActiveSessionJournal.load()?.samples.count, 3)

        XCTAssertTrue(ActiveSessionJournal.clearIfUnchanged(
            id: newer.id,
            updatedAt: newer.updatedAt,
            schema: newer.schema,
            sampleCount: newer.samples.count,
            rrSampleCount: newer.rrSamples?.count ?? 0
        ))
        XCTAssertNil(ActiveSessionJournal.load())
    }

    private func record(id: UUID = UUID(),
                        sampleCount: Int,
                        rrCount: Int) -> ActiveSessionJournalRecord {
        ActiveSessionJournalRecord(
            schema: ActiveSessionJournal.schema,
            id: id,
            label: "Test session",
            startedAt: baseDate,
            updatedAt: baseDate.addingTimeInterval(Double(sampleCount)),
            samples: (0..<sampleCount).map {
                ActiveSessionJournalRecord.Sample(t: baseDate.addingTimeInterval(Double($0)), bpm: 70 + $0)
            },
            rrSamples: (0..<rrCount).map {
                ActiveSessionJournalRecord.RRSample(t: baseDate.addingTimeInterval(Double($0)), ms: 800 + $0)
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

    private func segmentDirectoryURL() throws -> URL {
        try XCTUnwrap(ActiveSessionJournal.url?.deletingLastPathComponent()
            .appendingPathComponent("atria-active-session.segments", isDirectory: true))
    }
}
