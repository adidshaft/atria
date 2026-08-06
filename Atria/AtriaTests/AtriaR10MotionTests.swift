import XCTest
@testable import Atria

private final class AtriaR10SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: AtriaR10MotionPipeline.Snapshot?

    func store(_ snapshot: AtriaR10MotionPipeline.Snapshot) {
        lock.lock()
        storage = snapshot
        lock.unlock()
    }

    func load() -> AtriaR10MotionPipeline.Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class AtriaR10MotionTests: XCTestCase {
    func testDecoderUsesFixedR10SixAxisLayout() throws {
        let payload = makeR10Payload(timestamp: 1_750_000_123,
                                     heartRate: 74,
                                     acceleration: (4_096, -2_048, 1_024),
                                     gyroscope: (100, -200, 300))
        let decoded = try XCTUnwrap(AtriaR10MotionDecoder.decode(frame: encodeFrame(payload)))

        XCTAssertEqual(decoded.deviceTimestamp, 1_750_000_123)
        XCTAssertEqual(
            AtriaR10MotionDecoder.validatedDeviceTimestamp(frame: encodeFrame(payload)),
            1_750_000_123
        )
        XCTAssertEqual(decoded.heartRate, 74)
        XCTAssertEqual(decoded.acceleration.count, 100)
        XCTAssertEqual(decoded.acceleration[0].x, 1, accuracy: 0.000_001)
        XCTAssertEqual(decoded.acceleration[0].y, -0.5, accuracy: 0.000_001)
        XCTAssertEqual(decoded.acceleration[0].z, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(decoded.rotationRate[0].x, 6.103_515_625, accuracy: 0.000_001)
        XCTAssertEqual(decoded.rotationRate[0].y, -12.207_031_25, accuracy: 0.000_001)
        XCTAssertEqual(decoded.rotationRate[0].z, 18.310_546_875, accuracy: 0.000_001)
    }

    func testDecoderRejectsWrongRecordAndCorruptCRC() {
        var wrongRecord = makeR10Payload()
        wrongRecord[1] = 0x0B
        XCTAssertNil(AtriaR10MotionDecoder.decode(frame: encodeFrame(wrongRecord)))
        XCTAssertNil(AtriaR10MotionDecoder.validatedDeviceTimestamp(frame: encodeFrame(wrongRecord)))

        var corrupt = encodeFrame(makeR10Payload())
        corrupt[corrupt.index(before: corrupt.endIndex)] ^= 0xFF
        XCTAssertNil(AtriaR10MotionDecoder.decode(frame: corrupt))
        XCTAssertNil(AtriaR10MotionDecoder.validatedDeviceTimestamp(frame: corrupt))
    }

    func testPedometerRejectsRestAndCountsRegularGait() {
        let rest = [Double](repeating: 1, count: 2_000)
        let gait = (0..<2_000).map { sample -> Double in
            let phase = 2 * Double.pi * 2 * Double(sample) / 100
            return 1 + 0.16 * sin(phase)
        }

        XCTAssertEqual(AtriaStrapPedometer.rawStepCount(magnitudes: rest), 0)
        XCTAssertGreaterThanOrEqual(AtriaStrapPedometer.rawStepCount(magnitudes: gait), 30)
        XCTAssertLessThanOrEqual(AtriaStrapPedometer.rawStepCount(magnitudes: gait), 42)
    }

    func testCalibrationParametersPreserveProductionDefaults() {
        let gait = (0..<2_000).map { sample -> Double in
            let phase = 2 * Double.pi * 2 * Double(sample) / 100
            return 1 + 0.16 * sin(phase)
        }
        let production = AtriaStrapPedometer.rawStepCount(magnitudes: gait)
        let explicitDefaults = AtriaStrapPedometer.rawStepCount(
            magnitudes: gait,
            sensitivityG: AtriaStrapPedometer.sensitivityG,
            confirmationSteps: AtriaStrapPedometer.confirmationSteps
        )
        let calibrationCandidate = AtriaStrapPedometer.rawStepCount(
            magnitudes: gait,
            sensitivityG: 0.06,
            confirmationSteps: 4
        )

        XCTAssertEqual(explicitDefaults, production)
        XCTAssertEqual(AtriaStrapPedometer.filterLength, 8)
        XCTAssertEqual(AtriaStrapPedometer.peakWindow, 29)
        XCTAssertEqual(AtriaStrapPedometer.sensitivityG, 0.06, accuracy: 0.000_001)
        XCTAssertEqual(AtriaStrapPedometer.confirmationSteps, 6)
        XCTAssertGreaterThanOrEqual(calibrationCandidate, production)
        XCTAssertEqual(AtriaStrapPedometer.rawStepCount(
            magnitudes: [Double](repeating: 1, count: 2_000),
            sensitivityG: 0.04,
            confirmationSteps: 4
        ), 0)
    }

    func testStreamingDetectorLongContinuousMatchesArbitrarySegments() {
        let gait = makeGaitMagnitudes(sampleCount: 18_000)
        var continuous = AtriaStrapPedometer.StreamingDetector()
        continuous.ingest(gait)

        var segmented = AtriaStrapPedometer.StreamingDetector()
        let chunkSizes = [37, 100, 613, 2_047, 59, 997]
        var offset = 0
        var chunkIndex = 0
        while offset < gait.count {
            let end = min(gait.count, offset + chunkSizes[chunkIndex % chunkSizes.count])
            segmented.ingest(gait[offset..<end])
            offset = end
            chunkIndex += 1
        }

        XCTAssertGreaterThan(continuous.rawSteps, 300)
        XCTAssertEqual(AtriaStrapPedometer.rawStepCount(magnitudes: gait),
                       continuous.rawSteps,
                       "offline calibration replay must use the production streaming detector")
        XCTAssertEqual(segmented.rawSteps, continuous.rawSteps,
                       "continuous detector state must survive arbitrary delivery chunks")
    }

    func testStreamingDetectorMinuteBoundaryPhaseDoesNotChangeCount() {
        let gait = makeGaitMagnitudes(sampleCount: 18_000)
        var reference = AtriaStrapPedometer.StreamingDetector()
        reference.ingest(gait)

        // A two-minute walk crosses multiple 6,000-sample production minute
        // boundaries. Shift each artificial split through the 50-sample gait
        // cycle; no phase may reset confirmation or discard extrema.
        for phaseOffset in [0, 7, 17, 29, 43, 49] {
            var detector = AtriaStrapPedometer.StreamingDetector()
            var start = 0
            var boundary = 6_000 + phaseOffset
            while start < gait.count {
                let end = min(gait.count, boundary)
                detector.ingest(gait[start..<end])
                start = end
                boundary += 6_000
            }
            XCTAssertEqual(detector.rawSteps, reference.rawSteps,
                           "boundary phase offset \(phaseOffset) changed the count")
        }
    }

    func testPipelineDeduplicatesR10TimestampAndPublishesCumulativeCount() throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        let frames = stride(from: 0, to: 2_000, by: 100).enumerated().map { item in
            let vectors = item.element..<(item.element + 100)
            return AtriaR10MotionFrame(
                deviceTimestamp: UInt32(1_750_000_000 + item.offset),
                heartRate: 80,
                acceleration: vectors.map { sample in
                    let phase = 2 * Double.pi * 2 * Double(sample) / 100
                    return .init(x: 1 + 0.16 * sin(phase), y: 0, z: 0)
                },
                rotationRate: [AtriaR10MotionFrame.Vector3](
                    repeating: .init(x: 0, y: 0, z: 0),
                    count: 100
                )
            )
        }

        var snapshot: AtriaR10MotionPipeline.Snapshot?
        for frame in frames {
            snapshot = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(frame))
        }
        XCTAssertNil(pipeline.ingestSynchronouslyForTesting(frames[0]))
        XCTAssertEqual(snapshot?.frames, 20)
        XCTAssertEqual(snapshot?.samples, 2_000)
        XCTAssertGreaterThanOrEqual(snapshot?.steps ?? 0, 30)
        XCTAssertEqual(snapshot?.state, "r10_live_preliminary")
    }

    func testPipelineRejectsStaleFrameAfterTimestampDedupeEviction() throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        var snapshot: AtriaR10MotionPipeline.Snapshot?
        for second in 0..<600 {
            snapshot = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
                constantFrame(timestamp: UInt32(50_000 + second), magnitude: 1)
            ))
        }
        XCTAssertEqual(snapshot?.frames, 600)

        // 50_000 has fallen out of the 512-entry duplicate set, but it is
        // still older than the authoritative latest device second.
        XCTAssertNil(pipeline.ingestSynchronouslyForTesting(
            constantFrame(timestamp: 50_000, magnitude: 1)
        ))

        let next = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
            constantFrame(timestamp: 50_600, magnitude: 1)
        ))
        XCTAssertEqual(next.frames, 601,
                       "a rejected stale replay must not mutate pipeline totals")
        XCTAssertEqual(next.rawSteps, 0)
    }

    func testDeviceTimestampOrderingHandlesUInt32WrapAndRejectsBackwardReplay() {
        XCTAssertEqual(AtriaR10MotionPipeline.forwardDeviceTimestampDelta(
            from: UInt32.max - 1,
            to: 1
        ), 3)
        XCTAssertNil(AtriaR10MotionPipeline.forwardDeviceTimestampDelta(from: 100, to: 100))
        XCTAssertNil(AtriaR10MotionPipeline.forwardDeviceTimestampDelta(from: 100, to: 99))
    }

    func testPipelineDoesNotJoinShortGaitBurstsAcrossMissingFrames() throws {
        func frame(timestamp: UInt32, sampleOffset: Int) -> AtriaR10MotionFrame {
            AtriaR10MotionFrame(
                deviceTimestamp: timestamp,
                heartRate: 80,
                acceleration: (sampleOffset..<(sampleOffset + 100)).map { sample in
                    let phase = 2 * Double.pi * 2 * Double(sample) / 100
                    return .init(x: 1 + 0.16 * sin(phase), y: 0, z: 0)
                },
                rotationRate: [AtriaR10MotionFrame.Vector3](
                    repeating: .init(x: 0, y: 0, z: 0),
                    count: 100
                )
            )
        }

        let contiguous = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        var contiguousSnapshot: AtriaR10MotionPipeline.Snapshot?
        for index in 0..<6 {
            contiguousSnapshot = contiguous.ingestSynchronouslyForTesting(
                frame(timestamp: UInt32(100 + index), sampleOffset: index * 100)
            )
        }

        let interrupted = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        var interruptedSnapshot: AtriaR10MotionPipeline.Snapshot?
        for index in 0..<3 {
            interruptedSnapshot = interrupted.ingestSynchronouslyForTesting(
                frame(timestamp: UInt32(100 + index), sampleOffset: index * 100)
            )
        }
        for index in 3..<6 {
            interruptedSnapshot = interrupted.ingestSynchronouslyForTesting(
                frame(timestamp: UInt32(157 + index), sampleOffset: index * 100)
            )
        }

        XCTAssertGreaterThan(contiguousSnapshot?.rawSteps ?? 0, 0)
        XCTAssertEqual(interruptedSnapshot?.rawSteps, 0)
    }

    func testPipelineKeepsConfirmedGaitAcrossIsolatedOneSecondHoles() throws {
        let continuous = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        var continuousSnapshot: AtriaR10MotionPipeline.Snapshot?
        for second in 0..<40 {
            continuousSnapshot = try XCTUnwrap(continuous.ingestSynchronouslyForTesting(
                gaitFrame(timestamp: UInt32(10_000 + second), sampleOffset: second * 100)
            ))
        }

        let withHoles = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        var holeSnapshot: AtriaR10MotionPipeline.Snapshot?
        // After eight clean seconds establish gait, remove one frame every
        // three seconds. Each hole remains isolated, but the two-second valid
        // runs between them are too short to re-earn a six-step confirmation
        // under the old hard-reset-on-every-gap behavior.
        let missingSeconds = Set(stride(from: 8, through: 35, by: 3))
        for second in 0..<40 where !missingSeconds.contains(second) {
            holeSnapshot = try XCTUnwrap(withHoles.ingestSynchronouslyForTesting(
                gaitFrame(timestamp: UInt32(10_000 + second), sampleOffset: second * 100)
            ))
        }

        let referenceSteps = try XCTUnwrap(continuousSnapshot?.rawSteps)
        let recoveredSteps = try XCTUnwrap(holeSnapshot?.rawSteps)
        XCTAssertGreaterThan(referenceSteps, 70)
        XCTAssertLessThanOrEqual(recoveredSteps, referenceSteps,
                                 "missing samples must never create steps")
        XCTAssertGreaterThanOrEqual(recoveredSteps, referenceSteps - 38,
                                    "isolated holes should lose unavailable motion/filter warm-up, not repeatedly lose six-step confirmations")
    }

    func testPipelineDoesNotJoinUnconfirmedBurstsAcrossOneMissingSecond() throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        var snapshot: AtriaR10MotionPipeline.Snapshot?

        for second in 0..<3 {
            snapshot = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
                gaitFrame(timestamp: UInt32(20_000 + second), sampleOffset: second * 100)
            ))
        }
        XCTAssertEqual(snapshot?.rawSteps, 0)

        // Timestamp 20_003 is the missing one-second R10 frame. Although the
        // two three-second fragments together contain enough cycles to pass the
        // confirmation gate, neither fragment is independently confirmed.
        for second in 4..<7 {
            snapshot = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
                gaitFrame(timestamp: UInt32(20_000 + second), sampleOffset: second * 100)
            ))
        }
        XCTAssertEqual(snapshot?.rawSteps, 0)
    }

    func testPipelineClearsExtremaAtIsolatedGapBoundary() throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        var snapshot: AtriaR10MotionPipeline.Snapshot?
        for second in 0..<10 {
            snapshot = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
                gaitFrame(timestamp: UInt32(30_000 + second), sampleOffset: second * 100)
            ))
        }
        let confirmedPrefix = try XCTUnwrap(snapshot?.rawSteps)
        XCTAssertGreaterThan(confirmedPrefix, 0)

        // The first post-gap second is a flat low magnitude followed by flat
        // gravity. If a pre-gap maximum/filter tail leaked across the boundary,
        // that low edge could be misread as a completed step.
        snapshot = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
            constantFrame(timestamp: 30_011, magnitude: 0.70)
        ))
        snapshot = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
            constantFrame(timestamp: 30_012, magnitude: 1.00)
        ))

        XCTAssertEqual(snapshot?.rawSteps, confirmedPrefix,
                       "a discontinuity boundary must not manufacture an extremum pair")
    }

    func testPipelineIsolatedGapCarryExpiresDuringPostGapStillness() throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        var snapshot: AtriaR10MotionPipeline.Snapshot?
        for second in 0..<10 {
            snapshot = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
                gaitFrame(timestamp: UInt32(35_000 + second), sampleOffset: second * 100)
            ))
        }
        let confirmedPrefix = try XCTUnwrap(snapshot?.rawSteps)
        XCTAssertGreaterThan(confirmedPrefix, 0)

        // The isolated hole is followed by a full valid second of stillness,
        // which must consume the bounded carry. A later two-second handling/
        // gait fragment is too short to pass a fresh six-step confirmation.
        snapshot = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
            constantFrame(timestamp: 35_011, magnitude: 1)
        ))
        for second in 12..<14 {
            snapshot = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
                gaitFrame(timestamp: UInt32(35_000 + second), sampleOffset: second * 100)
            ))
        }

        XCTAssertEqual(snapshot?.rawSteps, confirmedPrefix,
                       "confirmed gait must not survive beyond the bounded post-gap resume window")
    }

    func testPipelineLongGapStillRequiresFreshGaitConfirmation() throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        var snapshot: AtriaR10MotionPipeline.Snapshot?
        for second in 0..<10 {
            snapshot = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
                gaitFrame(timestamp: UInt32(40_000 + second), sampleOffset: second * 100)
            ))
        }
        let confirmedPrefix = try XCTUnwrap(snapshot?.rawSteps)
        XCTAssertGreaterThan(confirmedPrefix, 0)

        for second in 0..<3 {
            snapshot = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
                gaitFrame(timestamp: UInt32(41_000 + second), sampleOffset: (10 + second) * 100)
            ))
        }
        XCTAssertEqual(snapshot?.rawSteps, confirmedPrefix,
                       "a reconnect/long gap must not retain confirmed gait")

        for second in 3..<7 {
            snapshot = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
                gaitFrame(timestamp: UInt32(41_000 + second), sampleOffset: (10 + second) * 100)
            ))
        }
        XCTAssertGreaterThan(snapshot?.rawSteps ?? 0, confirmedPrefix,
                             "a fresh contiguous gait segment should count after confirmation")
    }

    func testReconnectGapPreservesCommittedStepsAndContinuesMonotonically() throws {
        func gaitFrame(timestamp: UInt32, sampleOffset: Int) -> AtriaR10MotionFrame {
            AtriaR10MotionFrame(
                deviceTimestamp: timestamp,
                heartRate: 80,
                acceleration: (sampleOffset..<(sampleOffset + 100)).map { sample in
                    let phase = 2 * Double.pi * 2 * Double(sample) / 100
                    return .init(x: 1 + 0.16 * sin(phase), y: 0, z: 0)
                },
                rotationRate: [AtriaR10MotionFrame.Vector3](
                    repeating: .init(x: 0, y: 0, z: 0),
                    count: 100
                )
            )
        }

        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        var beforeReconnect: AtriaR10MotionPipeline.Snapshot?
        for index in 0..<10 {
            beforeReconnect = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
                gaitFrame(timestamp: UInt32(1_000 + index), sampleOffset: index * 100)
            ))
        }
        let prefix = try XCTUnwrap(beforeReconnect)
        XCTAssertGreaterThan(prefix.rawSteps, 0)

        var afterReconnect: AtriaR10MotionPipeline.Snapshot?
        for index in 0..<10 {
            afterReconnect = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
                gaitFrame(timestamp: UInt32(2_000 + index), sampleOffset: (10 + index) * 100)
            ))
        }
        let resumed = try XCTUnwrap(afterReconnect)

        XCTAssertGreaterThanOrEqual(resumed.rawSteps, prefix.rawSteps)
        XCTAssertGreaterThanOrEqual(resumed.steps, prefix.steps)
        XCTAssertGreaterThan(resumed.rawSteps, prefix.rawSteps,
                             "new contiguous gait after a BLE gap must add to the committed prefix")
    }

    func testLivePipelineEvaluatesExpensiveSnapshotAtMostOncePerSecond() {
        let anchor = Date(timeIntervalSinceReferenceDate: 800_000_000)

        XCTAssertTrue(AtriaR10MotionPipeline.shouldEvaluateSnapshot(
            firstFrame: true,
            lastEvaluatedAt: anchor,
            receivedAt: anchor
        ))
        XCTAssertFalse(AtriaR10MotionPipeline.shouldEvaluateSnapshot(
            firstFrame: false,
            lastEvaluatedAt: anchor,
            receivedAt: anchor.addingTimeInterval(0.999)
        ))
        XCTAssertTrue(AtriaR10MotionPipeline.shouldEvaluateSnapshot(
            firstFrame: false,
            lastEvaluatedAt: anchor,
            receivedAt: anchor.addingTimeInterval(1)
        ))
    }

    func testDetectorSnapshotClockAdvancesEvenWhenStepCountIsUnchanged() {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100,
                                              gain: 1,
                                              snapshotMinimumInterval: 0.01)
        let anchor = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let published = expectation(description: "each evaluated detector snapshot published")
        published.expectedFulfillmentCount = 2
        let latest = AtriaR10SnapshotBox()

        pipeline.ingest(constantFrame(timestamp: 70_000, magnitude: 1),
                        receivedAt: anchor) { snapshot in
            latest.store(snapshot)
            published.fulfill()
        }
        pipeline.ingest(constantFrame(timestamp: 70_001, magnitude: 1),
                        receivedAt: anchor.addingTimeInterval(1)) { snapshot in
            latest.store(snapshot)
            published.fulfill()
        }

        wait(for: [published], timeout: 5)
        XCTAssertEqual(latest.load()?.steps, 0)
        XCTAssertEqual(latest.load()?.receivedAt, anchor.addingTimeInterval(1))
    }

    func testLivePipelineTrailingSnapshotPublishesLatestCountFromBatchedFrames() {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100,
                                              gain: 1,
                                              snapshotMinimumInterval: 0.02)
        let anchor = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let latestPublished = expectation(description: "latest batched step count published")
        let finalSnapshot = AtriaR10SnapshotBox()

        // A reassembled BLE notification can contain several device-seconds
        // with the same host receipt time. The first frame publishes
        // immediately; the trailing flush must expose the final detector state
        // even if no later notification arrives to reopen the cadence gate.
        for second in 0..<10 {
            pipeline.ingest(gaitFrame(timestamp: UInt32(60_000 + second),
                                      sampleOffset: second * 100),
                            receivedAt: anchor) { snapshot in
                guard snapshot.frames == 10 else { return }
                finalSnapshot.store(snapshot)
                latestPublished.fulfill()
            }
        }

        // Full-suite simulator clones can briefly starve the utility queue
        // while several test workers launch; the production cadence remains
        // 20 ms in this test, so this only removes harness scheduling flakiness.
        wait(for: [latestPublished], timeout: 5)
        let snapshot = finalSnapshot.load()
        XCTAssertEqual(snapshot?.frames, 10)
        XCTAssertGreaterThan(snapshot?.steps ?? 0, 0)
        XCTAssertEqual(snapshot?.receivedAt, anchor,
                       "freshness must describe detector-applied input, not callback wall time")
    }

    func testCurrentSnapshotSynchronouslyDrainsCadencePendingBatch() throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100,
                                              gain: 1,
                                              snapshotMinimumInterval: 60)
        let reference = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        let anchor = Date(timeIntervalSinceReferenceDate: 800_100_000)
        var referenceSnapshot: AtriaR10MotionPipeline.Snapshot?

        for second in 0..<10 {
            let frame = gaitFrame(timestamp: UInt32(80_000 + second),
                                  sampleOffset: second * 100)
            pipeline.ingest(frame, receivedAt: anchor) { _ in }
            referenceSnapshot = reference.ingestSynchronouslyForTesting(frame)
        }

        let drained = try XCTUnwrap(pipeline.currentSnapshotSynchronously())
        let expected = try XCTUnwrap(referenceSnapshot)
        XCTAssertEqual(drained.frames, 10)
        XCTAssertEqual(drained.samples, 1_000)
        XCTAssertEqual(drained.deviceTimestamp, 80_009)
        XCTAssertEqual(drained.receivedAt, anchor)
        XCTAssertEqual(drained.rawSteps, expected.rawSteps)
        XCTAssertEqual(drained.steps, expected.steps)
        XCTAssertGreaterThan(drained.steps, 0)
        pipeline.resetSynchronously()
    }

    func testResetAdvancesGenerationAndSeparatesDelayedSnapshotEpoch() throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        let oldSnapshot = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
            gaitFrame(timestamp: 81_000, sampleOffset: 0)
        ))

        let newGeneration = pipeline.resetSynchronously()
        XCTAssertEqual(newGeneration, oldSnapshot.generation &+ 1)

        let newSnapshot = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
            gaitFrame(timestamp: 81_000, sampleOffset: 0)
        ))
        XCTAssertEqual(newSnapshot.generation, newGeneration)
        XCTAssertNotEqual(oldSnapshot.generation, newSnapshot.generation)
    }

    func testAccountingRollPreservesDetectorContinuityAndRawStepConservation() throws {
        let uninterrupted = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        let rolled = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        var uninterruptedSnapshot: AtriaR10MotionPipeline.Snapshot?
        var firstSegmentSnapshot: AtriaR10MotionPipeline.Snapshot?
        var secondSegmentSnapshot: AtriaR10MotionPipeline.Snapshot?

        for second in 0..<20 {
            let frame = gaitFrame(timestamp: UInt32(82_000 + second),
                                  sampleOffset: second * 100)
            uninterruptedSnapshot = uninterrupted.ingestSynchronouslyForTesting(frame)
            if second < 10 {
                firstSegmentSnapshot = rolled.ingestSynchronouslyForTesting(frame)
            }
        }
        let first = try XCTUnwrap(firstSegmentSnapshot)
        let transition = rolled.rollSegmentSynchronously(persistedRawSteps: first.rawSteps)
        XCTAssertEqual(transition.finalSnapshot?.rawSteps, first.rawSteps)
        XCTAssertNil(transition.carriedSnapshot)

        for second in 10..<20 {
            secondSegmentSnapshot = rolled.ingestSynchronouslyForTesting(
                gaitFrame(timestamp: UInt32(82_000 + second),
                          sampleOffset: second * 100)
            )
        }

        let uninterruptedFinal = try XCTUnwrap(uninterruptedSnapshot)
        let second = try XCTUnwrap(secondSegmentSnapshot)
        XCTAssertEqual(first.rawSteps + second.rawSteps, uninterruptedFinal.rawSteps)
        XCTAssertEqual(second.generation, transition.generation)
    }

    func testAccountingRollCarriesFramesAcceptedAfterPersistedSnapshot() throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100,
                                              gain: 1,
                                              snapshotMinimumInterval: 60)
        let anchor = Date(timeIntervalSinceReferenceDate: 800_200_000)
        var persistedSnapshot: AtriaR10MotionPipeline.Snapshot?
        for second in 0..<10 {
            persistedSnapshot = pipeline.ingestSynchronouslyForTesting(
                gaitFrame(timestamp: UInt32(83_000 + second),
                          sampleOffset: second * 100)
            )
        }
        let persisted = try XCTUnwrap(persistedSnapshot)

        for second in 10..<20 {
            pipeline.ingest(
                gaitFrame(timestamp: UInt32(83_000 + second),
                          sampleOffset: second * 100),
                receivedAt: anchor
            ) { _ in }
        }
        let transition = pipeline.rollSegmentSynchronously(
            persistedRawSteps: persisted.rawSteps
        )
        let final = try XCTUnwrap(transition.finalSnapshot)
        let carried = try XCTUnwrap(transition.carriedSnapshot)
        XCTAssertGreaterThan(carried.rawSteps, 0)
        XCTAssertEqual(persisted.rawSteps + carried.rawSteps, final.rawSteps)
        XCTAssertEqual(carried.generation, transition.generation)
        XCTAssertEqual(carried.receivedAt, anchor)
    }

    func testAsyncBoundaryCommitBuffersPostMarkerFramesAndConservesRawSteps() async throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100,
                                              gain: 1,
                                              snapshotMinimumInterval: 60)
        let reference = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        let anchor = Date(timeIntervalSinceReferenceDate: 800_300_000)
        var referenceFinal: AtriaR10MotionPipeline.Snapshot?
        for second in 0..<20 {
            let frame = gaitFrame(timestamp: UInt32(84_000 + second),
                                  sampleOffset: second * 100)
            referenceFinal = reference.ingestSynchronouslyForTesting(frame)
            if second < 10 {
                pipeline.ingest(frame, receivedAt: anchor) { _ in }
            }
        }

        let token = await pipeline.prepareBoundary()
        let secondPrepare = await pipeline.prepareBoundary()
        XCTAssertEqual(secondPrepare, token, "a concurrent prepare must join the same marker")
        let first = try XCTUnwrap(token.finalSnapshot)
        XCTAssertGreaterThan(first.rawSteps, 0)

        for second in 10..<20 {
            pipeline.ingest(
                gaitFrame(timestamp: UInt32(84_000 + second),
                          sampleOffset: second * 100),
                receivedAt: anchor.addingTimeInterval(Double(second))
            ) { _ in }
        }
        let committed = await pipeline.commitBoundary(
            token,
            handedOffRawSteps: token.markerRawSteps,
            nextGeneration: token.generation &+ 1
        )
        let transition = try XCTUnwrap(committed)
        XCTAssertEqual(transition.generation, token.generation &+ 1)
        XCTAssertNil(transition.carriedSnapshot)
        XCTAssertNil(pipeline.currentSnapshotSynchronously(),
                     "post-marker frames must stay fenced until the manager installs the generation")
        let released = await pipeline.releaseCommittedBoundaryFrames(
            token,
            generation: transition.generation
        )
        XCTAssertTrue(released)

        let second = try XCTUnwrap(pipeline.currentSnapshotSynchronously())
        let uninterrupted = try XCTUnwrap(referenceFinal)
        XCTAssertEqual(first.rawSteps + second.rawSteps, uninterrupted.rawSteps)
        XCTAssertEqual(second.generation, transition.generation)
        XCTAssertEqual(second.frames, 10)
    }

    func testAsyncBoundaryAbortRetainsGenerationAndReplaysEveryBufferedFrame() async throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100,
                                              gain: 1,
                                              snapshotMinimumInterval: 60)
        let reference = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        let anchor = Date(timeIntervalSinceReferenceDate: 800_400_000)
        var referenceFinal: AtriaR10MotionPipeline.Snapshot?
        for second in 0..<10 {
            let frame = gaitFrame(timestamp: UInt32(85_000 + second),
                                  sampleOffset: second * 100)
            pipeline.ingest(frame, receivedAt: anchor) { _ in }
            referenceFinal = reference.ingestSynchronouslyForTesting(frame)
        }
        let token = await pipeline.prepareBoundary()
        for second in 10..<20 {
            let frame = gaitFrame(timestamp: UInt32(85_000 + second),
                                  sampleOffset: second * 100)
            pipeline.ingest(frame,
                            receivedAt: anchor.addingTimeInterval(Double(second))) { _ in }
            referenceFinal = reference.ingestSynchronouslyForTesting(frame)
        }

        let aborted = await pipeline.abortBoundary(token)
        XCTAssertTrue(aborted)
        let retained = try XCTUnwrap(pipeline.currentSnapshotSynchronously())
        XCTAssertEqual(retained.generation, token.generation)
        XCTAssertEqual(retained.frames, 20)
        XCTAssertEqual(retained.rawSteps, referenceFinal?.rawSteps)

        let retry = await pipeline.prepareBoundary()
        XCTAssertNotEqual(retry.id, token.id)
        let retryAborted = await pipeline.abortBoundary(retry)
        XCTAssertTrue(retryAborted)
    }

    func testAsyncBoundaryRejectsInexactPersistedPrefixWithoutLosingAbortPath() async throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        for second in 0..<12 {
            pipeline.ingest(
                gaitFrame(timestamp: UInt32(86_000 + second),
                          sampleOffset: second * 100),
                receivedAt: Date(timeIntervalSinceReferenceDate: 800_500_000 + Double(second))
            ) { _ in }
        }
        let token = await pipeline.prepareBoundary()
        XCTAssertGreaterThan(token.markerRawSteps, 1)
        let mismatchedPrefix = token.markerRawSteps - 1
        let rejected = await pipeline.commitBoundary(
            token,
            handedOffRawSteps: mismatchedPrefix,
            nextGeneration: token.generation &+ 1
        )
        XCTAssertNil(rejected)
        let aborted = await pipeline.abortBoundary(token)
        XCTAssertTrue(aborted, "a rejected commit must leave the prepared marker abortable")
        XCTAssertEqual(pipeline.currentSnapshotSynchronously()?.generation, token.generation)
    }

    func testCommittedBoundaryForceReleaseRecoversRejectedTokenAndIsIdempotent() async throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100,
                                              gain: 1,
                                              snapshotMinimumInterval: 60)
        let anchor = Date(timeIntervalSinceReferenceDate: 800_550_000)
        for second in 0..<10 {
            pipeline.ingest(
                gaitFrame(timestamp: UInt32(86_500 + second),
                          sampleOffset: second * 100),
                receivedAt: anchor.addingTimeInterval(Double(second))
            ) { _ in }
        }
        let token = await pipeline.prepareBoundary()
        for second in 10..<16 {
            pipeline.ingest(
                gaitFrame(timestamp: UInt32(86_500 + second),
                          sampleOffset: second * 100),
                receivedAt: anchor.addingTimeInterval(Double(second))
            ) { _ in }
        }
        let committed = await pipeline.commitBoundary(
            token,
            handedOffRawSteps: token.markerRawSteps,
            nextGeneration: token.generation &+ 1
        )
        let transition = try XCTUnwrap(committed)
        let rejectedToken = AtriaR10MotionPipeline.BoundaryToken(
            id: UUID(),
            finalSnapshot: token.finalSnapshot,
            generation: token.generation,
            markerRawSteps: token.markerRawSteps
        )
        let ordinaryRelease = await pipeline.releaseCommittedBoundaryFrames(
            rejectedToken,
            generation: transition.generation
        )
        XCTAssertFalse(ordinaryRelease)
        XCTAssertNil(pipeline.currentSnapshotSynchronously(),
                     "a rejected token must leave the committed fence intact for recovery")

        let forcedRelease = await pipeline.forceReleaseCommittedBoundaryFrames(
            generation: transition.generation
        )
        XCTAssertTrue(forcedRelease)
        let recovered = try XCTUnwrap(pipeline.currentSnapshotSynchronously())
        XCTAssertEqual(recovered.generation, transition.generation)
        XCTAssertEqual(recovered.frames, 6)
        let repeatedRelease = await pipeline.forceReleaseCommittedBoundaryFrames(
            generation: transition.generation
        )
        XCTAssertTrue(repeatedRelease, "force release must be safe to repeat after recovery")
    }

    func testGyroShadowExactFiveHundredStepCalibrationIsResearchOnlyAndRestStable() throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        for second in 0..<250 { // exact control truth: 250 s × 2 Hz = 500 steps
            _ = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
                gyroCadenceFrame(timestamp: UInt32(90_000 + second),
                                 sampleOffset: second * 100,
                                 cadenceHz: 2)
            ))
        }
        let calibrated = pipeline.gyroCadenceResearchStepsSynchronously()
        let expected = Int(AtriaGyroCadenceResearchPedometer.steps(
            contiguousRotationMagnitudes: gyroMagnitudes(sampleCount: 25_000,
                                                         cadenceHz: 2)
        ).rounded())
        XCTAssertEqual(calibrated, expected,
                       "pipeline shadow must replay the exact batch calibration")
        XCTAssertGreaterThanOrEqual(calibrated, 485)
        XCTAssertLessThanOrEqual(calibrated, 510)
        XCTAssertEqual(pipeline.currentSnapshotSynchronously()?.steps, 0,
                       "gyro challenger must not alter the production accelerator count")

        for second in 250..<270 {
            _ = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
                gyroRestFrame(timestamp: UInt32(90_000 + second))
            ))
        }
        let afterRest = pipeline.gyroCadenceResearchStepsSynchronously()
        let expectedAfterRest = Int(AtriaGyroCadenceResearchPedometer.steps(
            contiguousRotationMagnitudes: gyroMagnitudes(sampleCount: 25_000,
                                                         cadenceHz: 2)
                + [Double](repeating: 5, count: 2_000)
        ).rounded())
        XCTAssertEqual(afterRest, expectedAfterRest,
                       "rest may finalize walk-edge windows but cannot invent rest steps")
        XCTAssertGreaterThanOrEqual(afterRest, calibrated)
        XCTAssertLessThanOrEqual(afterRest, 500)
    }

    func testGyroShadowBoundaryRolloverConservesOpenSpanWithoutDoubleCount() async throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        for second in 0..<125 {
            pipeline.ingest(gyroCadenceFrame(timestamp: UInt32(91_000 + second),
                                             sampleOffset: second * 100,
                                             cadenceHz: 2),
                            receivedAt: Date()) { _ in }
        }
        let token = await pipeline.prepareBoundary()
        let firstSegment = try XCTUnwrap(token.markerGyroCadenceResearchSteps)
        XCTAssertGreaterThan(firstSegment, 0)

        for second in 125..<250 {
            pipeline.ingest(gyroCadenceFrame(timestamp: UInt32(91_000 + second),
                                             sampleOffset: second * 100,
                                             cadenceHz: 2),
                            receivedAt: Date()) { _ in }
        }
        let committedTransition = await pipeline.commitBoundary(
            token,
            handedOffRawSteps: token.markerRawSteps,
            handedOffGyroCadenceResearchSteps: firstSegment,
            nextGeneration: token.generation &+ 1
        )
        let transition = try XCTUnwrap(committedTransition)
        XCTAssertEqual(transition.finalGyroCadenceResearchSteps, firstSegment)
        XCTAssertNil(transition.carriedGyroCadenceResearchSteps)
        let released = await pipeline.releaseCommittedBoundaryFrames(
            token,
            generation: transition.generation
        )
        XCTAssertTrue(released)

        let secondSegment = pipeline.gyroCadenceResearchStepsSynchronously()
        let uninterrupted = Int(AtriaGyroCadenceResearchPedometer.steps(
            contiguousRotationMagnitudes: gyroMagnitudes(sampleCount: 25_000,
                                                         cadenceHz: 2)
        ).rounded())
        XCTAssertEqual(firstSegment + secondSegment, uninterrupted,
                       "the retained open span must contribute each step to exactly one side")
    }

    func testGyroShadowRestartSeedIsIdempotentAndDoesNotRegress() throws {
        let restarted = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        XCTAssertEqual(restarted.seedSynchronously(
            committedRawSteps: 0,
            committedGyroCadenceResearchSteps: 500
        ).rawSteps, 0)
        XCTAssertEqual(restarted.gyroCadenceResearchStepsSynchronously(), 500)
        _ = restarted.seedSynchronously(committedRawSteps: 0,
                                        committedGyroCadenceResearchSteps: 500)
        XCTAssertEqual(restarted.gyroCadenceResearchStepsSynchronously(), 500,
                       "replaying the same journal/ledger prefix must not double count")
        _ = restarted.seedSynchronously(committedRawSteps: 0,
                                        committedGyroCadenceResearchSteps: 520)
        XCTAssertEqual(restarted.gyroCadenceResearchStepsSynchronously(), 520)
        for second in 0..<20 {
            _ = try XCTUnwrap(restarted.ingestSynchronouslyForTesting(
                gyroRestFrame(timestamp: UInt32(92_000 + second))
            ))
        }
        XCTAssertEqual(restarted.gyroCadenceResearchStepsSynchronously(), 520)
        XCTAssertEqual(restarted.currentSnapshotSynchronously()?.steps, 0)
    }

    func testPipelineRestoreSeedKeepsPublishedStepsMonotonic() throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1.11)
        let seeded = pipeline.seedSynchronously(committedRawSteps: 90)
        XCTAssertEqual(seeded.rawSteps, 90)
        XCTAssertEqual(seeded.steps, 100)

        let frame = AtriaR10MotionFrame(
            deviceTimestamp: 1_750_000_500,
            heartRate: 90,
            acceleration: (0..<100).map { sample in
                let phase = 2 * Double.pi * 2 * Double(sample) / 100
                return .init(x: 1 + 0.16 * sin(phase), y: 0, z: 0)
            },
            rotationRate: [AtriaR10MotionFrame.Vector3](
                repeating: .init(x: 0, y: 0, z: 0),
                count: 100
            )
        )

        let restored = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(frame))
        XCTAssertGreaterThanOrEqual(restored.rawSteps, 90)
        XCTAssertGreaterThanOrEqual(restored.steps, 100)
    }

    func testRepeatedRestoreSeedIsIdempotentAndOnlyAddsLargerDurablePrefixDelta() {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)

        XCTAssertEqual(
            pipeline.seedSynchronously(committedRawSteps: 90,
                                       lastAcceptedDeviceTimestamp: 5_000).rawSteps,
            90
        )
        XCTAssertEqual(
            pipeline.seedSynchronously(committedRawSteps: 90,
                                       lastAcceptedDeviceTimestamp: 5_000).rawSteps,
            90,
            "repeating the same durable restore must not add its prefix twice"
        )
        XCTAssertEqual(
            pipeline.seedSynchronously(committedRawSteps: 100,
                                       lastAcceptedDeviceTimestamp: 5_010).rawSteps,
            100,
            "a newer checkpoint contributes only its ten-step delta"
        )
    }

    func testRestoreWatermarkRejectsEqualAndOlderReplayAndAcceptsNextSecond() throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        _ = pipeline.seedSynchronously(committedRawSteps: 50,
                                       lastAcceptedDeviceTimestamp: 5_000)

        XCTAssertNil(pipeline.ingestSynchronouslyForTesting(constantFrame(timestamp: 5_000,
                                                                           magnitude: 1)))
        XCTAssertNil(pipeline.ingestSynchronouslyForTesting(constantFrame(timestamp: 4_999,
                                                                           magnitude: 1)))
        let next = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
            constantFrame(timestamp: 5_001, magnitude: 1)
        ))
        XCTAssertEqual(next.rawSteps, 50)
    }

    func testRestoreWatermarkAcceptsDeviceTimestampWrap() throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        _ = pipeline.seedSynchronously(committedRawSteps: 50,
                                       lastAcceptedDeviceTimestamp: UInt32.max - 1)

        let wrapped = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
            constantFrame(timestamp: 1, magnitude: 1)
        ))
        XCTAssertEqual(wrapped.rawSteps, 50)
    }

    func testFirstRestoreDiscardsBoundedPreCheckpointReplay() throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        _ = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
            gaitFrame(timestamp: 4_998, sampleOffset: 0)
        ))
        _ = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(
            gaitFrame(timestamp: 4_999, sampleOffset: 100)
        ))

        let restored = pipeline.seedSynchronously(committedRawSteps: 50,
                                                   lastAcceptedDeviceTimestamp: 5_000)
        XCTAssertEqual(restored.rawSteps, 50)
        XCTAssertNil(pipeline.ingestSynchronouslyForTesting(
            gaitFrame(timestamp: 4_999, sampleOffset: 200)
        ))
        XCTAssertNotNil(pipeline.ingestSynchronouslyForTesting(
            gaitFrame(timestamp: 5_001, sampleOffset: 300)
        ))
    }

    func testRestoreSeedPreservesFramesThatArrivedBeforeJournalLoad() throws {
        let pipeline = AtriaR10MotionPipeline(sampleRateHz: 100, gain: 1)
        let frame = AtriaR10MotionFrame(
            deviceTimestamp: 1_750_000_700,
            heartRate: 90,
            acceleration: (0..<100).map { sample in
                let phase = 2 * Double.pi * 2 * Double(sample) / 100
                return .init(x: 1 + 0.16 * sin(phase), y: 0, z: 0)
            },
            rotationRate: [AtriaR10MotionFrame.Vector3](
                repeating: .init(x: 0, y: 0, z: 0),
                count: 100
            )
        )
        _ = try XCTUnwrap(pipeline.ingestSynchronouslyForTesting(frame))

        let combined = pipeline.seedSynchronously(committedRawSteps: 50)
        XCTAssertGreaterThanOrEqual(combined.rawSteps, 50)
        XCTAssertGreaterThanOrEqual(combined.steps, 50)
        XCTAssertNil(pipeline.ingestSynchronouslyForTesting(frame),
                     "restore must retain timestamp deduplication for already-arrived frames")
    }

    func testGaitQualityChallengerRetroactivelyReleasesRegularStrapGait() throws {
        var gate = AtriaStrapGaitQualityChallenger()
        let motion = challengerMotion(sampleCount: 1_000, cadenceHz: { _ in 2 })
        let candidates = Array(stride(from: 0, to: 1_000, by: 50))
        let update = gate.ingest(acceleration: motion.acceleration,
                                 rotationRate: motion.rotation,
                                 candidateStepOffsets: candidates)

        let assessment = try XCTUnwrap(update.assessment)
        XCTAssertEqual(assessment.verdict, .accepted)
        XCTAssertGreaterThan(assessment.periodicity, 0.8)
        XCTAssertGreaterThan(assessment.walkingBandEnergyRatio, 0.8)
        XCTAssertGreaterThan(assessment.cadenceConsistency, 0.85)
        XCTAssertGreaterThan(update.releasedCandidateSteps, 0)
        XCTAssertEqual(update.releasedCandidateSteps + update.pendingCandidateSteps,
                       candidates.count)
        XCTAssertEqual(update.rejectedCandidateSteps, 0)
    }

    func testGaitQualityChallengerRejectsStillnessAndImpulseHandling() throws {
        var stillGate = AtriaStrapGaitQualityChallenger()
        let still = [AtriaR10MotionFrame.Vector3](
            repeating: .init(x: 1, y: 0, z: 0),
            count: 700
        )
        let stillUpdate = stillGate.ingest(acceleration: still,
                                           candidateStepOffsets: [0, 50, 100, 150, 200])
        XCTAssertEqual(try XCTUnwrap(stillUpdate.assessment).verdict, .rejected)
        XCTAssertGreaterThan(stillUpdate.rejectedCandidateSteps, 0)
        XCTAssertEqual(stillUpdate.releasedCandidateSteps, 0)

        var handlingGate = AtriaStrapGaitQualityChallenger()
        let handling = (0..<700).map { sample in
            AtriaR10MotionFrame.Vector3(
                x: sample.isMultiple(of: 73) ? 2.2 : (sample.isMultiple(of: 41) ? 0.35 : 1),
                y: 0,
                z: 0
            )
        }
        let handlingUpdate = handlingGate.ingest(acceleration: handling,
                                                 candidateStepOffsets: Array(stride(from: 0,
                                                                                   to: 300,
                                                                                   by: 40)))
        XCTAssertEqual(try XCTUnwrap(handlingUpdate.assessment).verdict, .rejected)
        XCTAssertEqual(handlingUpdate.releasedCandidateSteps, 0)
    }

    func testGaitQualityChallengerUsesGyroscopeToRejectRhythmicHandling() throws {
        let motion = challengerMotion(sampleCount: 800,
                                      cadenceHz: { _ in 2 },
                                      gyroscopeCadenceHz: 1)
        var gate = AtriaStrapGaitQualityChallenger()
        let update = gate.ingest(acceleration: motion.acceleration,
                                 rotationRate: motion.rotation,
                                 candidateStepOffsets: Array(stride(from: 0, to: 400, by: 50)))
        let assessment = try XCTUnwrap(update.assessment)
        XCTAssertEqual(assessment.verdict, .rejected)
        XCTAssertLessThan(try XCTUnwrap(assessment.gyroscopeAgreement), 0.72)
        XCTAssertEqual(update.releasedCandidateSteps, 0)
        XCTAssertGreaterThan(update.rejectedCandidateSteps, 0)
    }

    func testGaitQualityChallengerRejectsAbruptCadenceChange() throws {
        var gate = AtriaStrapGaitQualityChallenger()
        let motion = challengerMotion(sampleCount: 600, cadenceHz: { sample in
            sample < 300 ? 1.0 : 2.0
        })
        let update = gate.ingest(acceleration: motion.acceleration,
                                 rotationRate: nil,
                                 candidateStepOffsets: [0, 75, 150])
        let assessment = try XCTUnwrap(update.assessment)
        XCTAssertEqual(assessment.verdict, .rejected)
        XCTAssertLessThan(assessment.cadenceConsistency, 0.78)
    }

    func testGaitQualityChallengerGapRejectsPendingAndRequiresFreshWindow() throws {
        let prefix = challengerMotion(sampleCount: 350, cadenceHz: { _ in 2 })
        var gate = AtriaStrapGaitQualityChallenger()
        let prefixUpdate = gate.ingest(acceleration: prefix.acceleration,
                                       rotationRate: prefix.rotation,
                                       candidateStepOffsets: [0, 50, 100, 150, 200, 250, 300])
        XCTAssertNil(prefixUpdate.assessment)

        let isolatedGap = gate.resetForGap()
        XCTAssertEqual(isolatedGap.rejectedCandidateSteps, 7)
        let shortResume = challengerMotion(sampleCount: 400, cadenceHz: { _ in 2 })
        XCTAssertNil(gate.ingest(acceleration: shortResume.acceleration,
                                 rotationRate: shortResume.rotation,
                                 candidateStepOffsets: [0, 50, 100]).assessment)

        let longGap = gate.resetForGap()
        XCTAssertEqual(longGap.rejectedCandidateSteps, 3)
        let fullResume = challengerMotion(sampleCount: 500, cadenceHz: { _ in 2 })
        let resumed = gate.ingest(acceleration: fullResume.acceleration,
                                  rotationRate: fullResume.rotation)
        XCTAssertEqual(try XCTUnwrap(resumed.assessment).verdict, .accepted)
    }

    func testGaitQualityChallengerLiveAndReplayChunkingMatch() {
        let motion = challengerMotion(sampleCount: 1_200,
                                      cadenceHz: { sample in 1.85 + 0.15 * Double(sample) / 1_200 })
        let allCandidates = Array(stride(from: 0, to: 1_200, by: 52))
        var replay = AtriaStrapGaitQualityChallenger()
        let replayUpdate = replay.ingest(acceleration: motion.acceleration,
                                         rotationRate: motion.rotation,
                                         candidateStepOffsets: allCandidates)

        var live = AtriaStrapGaitQualityChallenger()
        var released = 0
        var rejected = 0
        var pending = 0
        var assessment: AtriaStrapGaitQualityChallenger.Assessment?
        for start in stride(from: 0, to: 1_200, by: 100) {
            let end = min(1_200, start + 100)
            let offsets = allCandidates.filter { start..<end ~= $0 }.map { $0 - start }
            let update = live.ingest(acceleration: Array(motion.acceleration[start..<end]),
                                     rotationRate: Array(motion.rotation[start..<end]),
                                     candidateStepOffsets: offsets)
            released += update.releasedCandidateSteps
            rejected += update.rejectedCandidateSteps
            pending = update.pendingCandidateSteps
            assessment = update.assessment ?? assessment
        }
        XCTAssertEqual(released, replayUpdate.releasedCandidateSteps)
        XCTAssertEqual(rejected, replayUpdate.rejectedCandidateSteps)
        XCTAssertEqual(pending, replayUpdate.pendingCandidateSteps)
        XCTAssertEqual(assessment, replayUpdate.assessment)
    }

    func testGaitQualityChallengerHundredHertzCost() {
        let motion = challengerMotion(sampleCount: 6_000, cadenceHz: { _ in 2 })
        measure {
            var gate = AtriaStrapGaitQualityChallenger()
            _ = gate.ingest(acceleration: motion.acceleration,
                            rotationRate: motion.rotation)
        }
    }

    private func makeR10Payload(timestamp: UInt32 = 1_750_000_000,
                                heartRate: UInt8 = 70,
                                acceleration: (Int16, Int16, Int16) = (0, 0, 4_096),
                                gyroscope: (Int16, Int16, Int16) = (0, 0, 0)) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 1_288)
        payload[0] = 0x2B
        payload[1] = 0x0A
        write(timestamp, to: &payload, at: 7)
        payload[17] = heartRate
        for sample in 0..<100 {
            write(acceleration.0, to: &payload, at: 85 + sample * 2)
            write(acceleration.1, to: &payload, at: 285 + sample * 2)
            write(acceleration.2, to: &payload, at: 485 + sample * 2)
            write(gyroscope.0, to: &payload, at: 688 + sample * 2)
            write(gyroscope.1, to: &payload, at: 888 + sample * 2)
            write(gyroscope.2, to: &payload, at: 1_088 + sample * 2)
        }
        return payload
    }

    private func makeGaitMagnitudes(sampleCount: Int) -> [Double] {
        (0..<sampleCount).map { sample in
            let phase = 2 * Double.pi * 2 * Double(sample) / 100
            return 1 + 0.16 * sin(phase)
        }
    }

    private func challengerMotion(
        sampleCount: Int,
        cadenceHz: (Int) -> Double,
        gyroscopeCadenceHz: Double? = nil
    ) -> (acceleration: [AtriaR10MotionFrame.Vector3],
          rotation: [AtriaR10MotionFrame.Vector3]) {
        var phase = 0.0
        var acceleration: [AtriaR10MotionFrame.Vector3] = []
        var rotation: [AtriaR10MotionFrame.Vector3] = []
        acceleration.reserveCapacity(sampleCount)
        rotation.reserveCapacity(sampleCount)
        for sample in 0..<sampleCount {
            let frequency = cadenceHz(sample)
            phase += 2 * Double.pi * frequency / 100
            acceleration.append(.init(x: 1 + 0.16 * sin(phase), y: 0, z: 0))
            let gyroFrequency = gyroscopeCadenceHz ?? frequency
            let gyroPhase = 2 * Double.pi * gyroFrequency * Double(sample) / 100
            rotation.append(.init(x: 18 * sin(gyroPhase), y: 0, z: 0))
        }
        return (acceleration, rotation)
    }

    private func gaitFrame(timestamp: UInt32, sampleOffset: Int) -> AtriaR10MotionFrame {
        AtriaR10MotionFrame(
            deviceTimestamp: timestamp,
            heartRate: 80,
            acceleration: (sampleOffset..<(sampleOffset + 100)).map { sample in
                let phase = 2 * Double.pi * 2 * Double(sample) / 100
                return .init(x: 1 + 0.16 * sin(phase), y: 0, z: 0)
            },
            rotationRate: [AtriaR10MotionFrame.Vector3](
                repeating: .init(x: 0, y: 0, z: 0),
                count: 100
            )
        )
    }

    private func constantFrame(timestamp: UInt32, magnitude: Double) -> AtriaR10MotionFrame {
        AtriaR10MotionFrame(
            deviceTimestamp: timestamp,
            heartRate: 80,
            acceleration: [AtriaR10MotionFrame.Vector3](
                repeating: .init(x: magnitude, y: 0, z: 0),
                count: 100
            ),
            rotationRate: [AtriaR10MotionFrame.Vector3](
                repeating: .init(x: 0, y: 0, z: 0),
                count: 100
            )
        )
    }

    private func gyroMagnitudes(sampleCount: Int, cadenceHz: Double) -> [Double] {
        (0..<sampleCount).map { sample in
            let phase = 2 * Double.pi * cadenceHz * Double(sample) / 100
            return max(0, 90 + 45 * sin(phase))
        }
    }

    private func gyroCadenceFrame(timestamp: UInt32,
                                  sampleOffset: Int,
                                  cadenceHz: Double) -> AtriaR10MotionFrame {
        let rotation = (sampleOffset..<(sampleOffset + 100)).map { sample in
            let phase = 2 * Double.pi * cadenceHz * Double(sample) / 100
            return max(0, 90 + 45 * sin(phase))
        }
        return AtriaR10MotionFrame(
            deviceTimestamp: timestamp,
            heartRate: 80,
            acceleration: [AtriaR10MotionFrame.Vector3](
                repeating: .init(x: 1, y: 0, z: 0), count: 100
            ),
            rotationRate: rotation.map { .init(x: $0, y: 0, z: 0) }
        )
    }

    private func gyroRestFrame(timestamp: UInt32) -> AtriaR10MotionFrame {
        AtriaR10MotionFrame(
            deviceTimestamp: timestamp,
            heartRate: 80,
            acceleration: [AtriaR10MotionFrame.Vector3](
                repeating: .init(x: 1, y: 0, z: 0), count: 100
            ),
            rotationRate: [AtriaR10MotionFrame.Vector3](
                repeating: .init(x: 5, y: 0, z: 0), count: 100
            )
        )
    }

    private func write(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func write(_ value: Int16, to bytes: inout [UInt8], at offset: Int) {
        let raw = UInt16(bitPattern: value)
        bytes[offset] = UInt8(raw & 0xFF)
        bytes[offset + 1] = UInt8((raw >> 8) & 0xFF)
    }

    // MARK: - Gyro-cadence research pedometer (research-only, never production)

    private func syntheticRotationMagnitudes(seconds: Double,
                                             cadenceHz: Double,
                                             level: Double,
                                             swing: Double) -> [Double] {
        let sr = Double(AtriaGyroCadenceResearchPedometer.sampleRateHz)
        return (0..<Int(seconds * sr)).map { i in
            let t = Double(i) / sr
            // Rectified-swing shape: |rotation| oscillates at the step rate
            // around a positive mean while walking.
            return max(0, level + swing * sin(2 * .pi * cadenceHz * t))
        }
    }

    func testGyroCadenceResearchPedometerCountsSteadyGaitByCadence() {
        let cadence = 1.75
        let seconds = 40.0
        let samples = syntheticRotationMagnitudes(seconds: seconds,
                                                  cadenceHz: cadence,
                                                  level: 90,
                                                  swing: 45)
        let steps = AtriaGyroCadenceResearchPedometer.steps(
            contiguousRotationMagnitudes: samples
        )
        // Bout integration covers the hop-quantized active span; allow the
        // window-edge loss but demand cadence-accurate counting inside it.
        let expected = seconds * cadence
        XCTAssertGreaterThan(steps, expected * 0.85)
        XCTAssertLessThan(steps, expected * 1.05)
    }

    func testGyroCadenceResearchPedometerRejectsRestAndSway() {
        // Below the rotation level gate: dead still.
        let still = [Double](repeating: 6, count: 6_000)
        XCTAssertEqual(AtriaGyroCadenceResearchPedometer.steps(
            contiguousRotationMagnitudes: still
        ), 0)
        // Posture sway: energetic but sub-band (0.5 Hz) rotation must not
        // count — the 2026-07-17 rest stages recorded exactly this shape.
        let sway = syntheticRotationMagnitudes(seconds: 40,
                                               cadenceHz: 0.5,
                                               level: 60,
                                               swing: 40)
        XCTAssertEqual(AtriaGyroCadenceResearchPedometer.steps(
            contiguousRotationMagnitudes: sway
        ), 0)
    }

    func testGyroCadenceResearchPedometerIsolatedTransientCountsZero() {
        // A brief wrist adjustment (1 s of motion inside stillness) dilutes
        // below the window-mean rotation gate and must contribute exactly
        // zero — the rest negative-control property the card session
        // verified. (A SUSTAINED clean in-band periodic rotation counts by
        // design: it is physically indistinguishable from stepping.)
        var samples = [Double](repeating: 5, count: 2_000)
        samples += syntheticRotationMagnitudes(seconds: 1,
                                               cadenceHz: 2.0,
                                               level: 80,
                                               swing: 40)
        samples += [Double](repeating: 5, count: 2_000)
        XCTAssertEqual(AtriaGyroCadenceResearchPedometer.steps(
            contiguousRotationMagnitudes: samples
        ), 0)
    }
}
