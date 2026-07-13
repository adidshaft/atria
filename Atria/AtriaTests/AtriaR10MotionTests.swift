import XCTest
@testable import Atria

final class AtriaR10MotionTests: XCTestCase {
    func testDecoderUsesFixedR10SixAxisLayout() throws {
        let payload = makeR10Payload(timestamp: 1_750_000_123,
                                     heartRate: 74,
                                     acceleration: (4_096, -2_048, 1_024),
                                     gyroscope: (100, -200, 300))
        let decoded = try XCTUnwrap(AtriaR10MotionDecoder.decode(frame: encodeFrame(payload)))

        XCTAssertEqual(decoded.deviceTimestamp, 1_750_000_123)
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

        var corrupt = encodeFrame(makeR10Payload())
        corrupt[corrupt.index(before: corrupt.endIndex)] ^= 0xFF
        XCTAssertNil(AtriaR10MotionDecoder.decode(frame: corrupt))
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
        for second in 0..<40 where second != 12 && second != 27 {
            holeSnapshot = try XCTUnwrap(withHoles.ingestSynchronouslyForTesting(
                gaitFrame(timestamp: UInt32(10_000 + second), sampleOffset: second * 100)
            ))
        }

        let referenceSteps = try XCTUnwrap(continuousSnapshot?.rawSteps)
        let recoveredSteps = try XCTUnwrap(holeSnapshot?.rawSteps)
        XCTAssertGreaterThan(referenceSteps, 70)
        XCTAssertLessThanOrEqual(recoveredSteps, referenceSteps,
                                 "missing samples must never create steps")
        XCTAssertGreaterThanOrEqual(recoveredSteps, referenceSteps - 8,
                                    "two isolated holes should lose their actual motion, not two additional six-step confirmations")
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
}
