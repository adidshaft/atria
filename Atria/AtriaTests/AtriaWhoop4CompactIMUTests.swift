import XCTest
@testable import Atria

final class AtriaWhoop4CompactIMUTests: XCTestCase {
    /// Physical stream-5 notify captured 2026-09-15 while the wearer was
    /// stationary. Header-valid Harvard frame, type 0x33, planar 10+10 samples.
    private let liveStationaryFrame = Data(hex:
        "aa9400b5330100006d8ce1018840580695010100030568000a000a00" +
        "3dfa23fa30fa3cfa37fa2dfa30fa39fa2ffa25fac0f7c3f7bff7c7f7" +
        "b5f7b1f7a9f7a8f7bff7bbf785f38ff38bf390f39af392f39af38df3" +
        "95f395f30a000b000800040002000e000900050004000800fdfffcff" +
        "fdfff9fff9ff0000fdfffcfffbfffcfffefffefffdfffffffffffeff" +
        "fffffffffeffffff6b07b094"
    )

    func testLiveStationaryFrameDecodesPlanarGravityNearOneG() throws {
        let packet = try XCTUnwrap(AtriaWhoop4CompactIMUDecoder.decode(frame: liveStationaryFrame))
        XCTAssertEqual(packet.acceleration.count, 10)
        XCTAssertEqual(packet.rotationRate.count, 10)
        XCTAssertEqual(packet.deviceTimestamp, 31_558_765)
        let meanG = packet.acceleration.map(\.magnitude).reduce(0, +)
            / Double(packet.acceleration.count)
        XCTAssertEqual(meanG, 1.0, accuracy: 0.08)
        XCTAssertLessThan(packet.rotationRate.map(\.magnitude).max() ?? 99, 5)
    }

    func testLiveStream5NotifyThisMorningDecodesTenPlusTen() throws {
        let frame = Data(hex:
            "aa9400b5330100001ddce50138196b8299010300030568000a000a00" +
            "06f12af12af136f122f115f1f1f01df12cf119f17afa72fa66fa95fa" +
            "89faa0fac1faacfa94fa94fa91ff6cff79ff7effa5ffc4ffbfffbdff" +
            "a1ffa0ff930081007a007e008d00a100aa00b100ba00ca00e3ffdeff" +
            "e2ffe6fff0ff0100060010002800410007000d001100100007000000" +
            "0200fffff7ffefff132d3ffe"
        )
        let packet = try XCTUnwrap(AtriaWhoop4CompactIMUDecoder.decode(frame: frame))
        XCTAssertEqual(packet.acceleration.count, 10)
        XCTAssertEqual(packet.rotationRate.count, 10)
        XCTAssertEqual(packet.deviceTimestamp, 31_841_309)
    }

    func testTenPacketsAssembleOneHundredSampleR10Second() throws {
        let packet = try XCTUnwrap(AtriaWhoop4CompactIMUDecoder.decode(frame: liveStationaryFrame))
        let assembler = AtriaWhoop4CompactIMUAssembler()
        var assembled: AtriaR10MotionFrame?
        let receivedAt = Date()
        for _ in 0..<9 {
            XCTAssertTrue(assembler.push(packet, receivedAt: receivedAt).isEmpty)
        }
        assembled = assembler.push(packet, receivedAt: receivedAt).last
        let frame = try XCTUnwrap(assembled)
        XCTAssertEqual(frame.acceleration.count, AtriaR10MotionDecoder.sampleCount)
        XCTAssertEqual(frame.rotationRate.count, AtriaR10MotionDecoder.sampleCount)
        XCTAssertEqual(frame.deviceClock, .compactAssembled)
        XCTAssertEqual(frame.deviceTimestamp, packet.deviceTimestamp)
        let meanG = frame.acceleration.map(\.magnitude).reduce(0, +)
            / Double(frame.acceleration.count)
        XCTAssertEqual(meanG, 1.0, accuracy: 0.08)
    }

    func testAssemblerIncrementsTimestampAcrossAssembledSeconds() throws {
        let packet = try XCTUnwrap(AtriaWhoop4CompactIMUDecoder.decode(frame: liveStationaryFrame))
        let assembler = AtriaWhoop4CompactIMUAssembler()
        var timestamps: [UInt32] = []
        let start = Date()
        for i in 0..<30 {
            let frames = assembler.push(
                packet,
                receivedAt: start.addingTimeInterval(Double(i) * 0.1)
            )
            timestamps.append(contentsOf: frames.map(\.deviceTimestamp))
        }
        XCTAssertEqual(timestamps.count, 3)
        XCTAssertEqual(timestamps[1], timestamps[0] &+ 1)
        XCTAssertEqual(timestamps[2], timestamps[1] &+ 1)
    }

    func testCoalescedBurstDoesNotTimeCompressGait() throws {
        let packet = try XCTUnwrap(AtriaWhoop4CompactIMUDecoder.decode(frame: liveStationaryFrame))
        let assembler = AtriaWhoop4CompactIMUAssembler()
        let receivedAt = Date()
        var frames: [AtriaR10MotionFrame] = []
        for _ in 0..<50 {
            frames.append(contentsOf: assembler.push(packet, receivedAt: receivedAt))
        }
        XCTAssertLessThanOrEqual(
            frames.count,
            2,
            "a same-callback 50-packet burst must not emit five compressed gait seconds"
        )
        let gyroSteps = frames.reduce(0.0) { partial, frame in
            partial + AtriaGyroCadenceResearchPedometer.steps(
                contiguousRotationMagnitudes: frame.rotationRate.map(\.magnitude),
                rotationLevelGate: AtriaGyroCadenceResearchPedometer.compactAssembledRotationLevelGate
            )
        }
        XCTAssertEqual(gyroSteps, 0, accuracy: 0.01)
    }

    func testDeskRotationBelowCompactGateScoresNoSteps() {
        let samples = [Double](repeating: 18, count: 400)
        let steps = AtriaGyroCadenceResearchPedometer.steps(
            contiguousRotationMagnitudes: samples,
            rotationLevelGate: AtriaGyroCadenceResearchPedometer.compactAssembledRotationLevelGate
        )
        XCTAssertEqual(steps, 0, accuracy: 0.01)
    }

    func testCompactFramesContinuePastAStaleR10Watermark() {
        let behind = AtriaR10MotionFrame(
            deviceTimestamp: 31_561_474,
            heartRate: 0,
            acceleration: [AtriaR10MotionFrame.Vector3](
                repeating: .init(x: 0, y: 0, z: 1),
                count: 100
            ),
            rotationRate: [AtriaR10MotionFrame.Vector3](
                repeating: .init(x: 0.2, y: 0.1, z: 0),
                count: 100
            ),
            deviceClock: .compactAssembled
        )
        let remapped = AtriaR10MotionPipeline.reconcileCompactAssembledClock(
            frame: behind,
            lastAcceptedDeviceTimestamp: 32_075_883
        )
        XCTAssertEqual(remapped.deviceTimestamp, 32_075_884)
        XCTAssertEqual(remapped.deviceClock, .compactAssembled)

        let native = behind.withDeviceTimestamp(31_561_474)
        let nativeFrame = AtriaR10MotionFrame(
            deviceTimestamp: native.deviceTimestamp,
            heartRate: 0,
            acceleration: native.acceleration,
            rotationRate: native.rotationRate,
            deviceClock: .whoopR10
        )
        XCTAssertEqual(
            AtriaR10MotionPipeline.reconcileCompactAssembledClock(
                frame: nativeFrame,
                lastAcceptedDeviceTimestamp: 32_075_883
            ).deviceTimestamp,
            31_561_474
        )
        XCTAssertEqual(
            AtriaBLEManager.newestR10DeviceTimestamp(
                existing: 32_075_883,
                incoming: 31_562_616
            ),
            32_075_883,
            "compact firmware time must not win the persisted R10 watermark"
        )
    }

    func testLiveIngestPublishesRemappedCompactTimestamp() {
        let pipeline = AtriaR10MotionPipeline(snapshotMinimumInterval: 0.01)
        _ = pipeline.seedSynchronously(
            committedRawSteps: 0,
            lastAcceptedDeviceTimestamp: 32_075_883,
            committedGyroCadenceResearchSteps: 0
        )
        let published = expectation(description: "live ingest publishes remapped watermark")
        let behind = AtriaR10MotionFrame(
            deviceTimestamp: 31_562_616,
            heartRate: 0,
            acceleration: [AtriaR10MotionFrame.Vector3](
                repeating: .init(x: 0, y: 0, z: 1),
                count: 100
            ),
            rotationRate: [AtriaR10MotionFrame.Vector3](
                repeating: .init(x: 0.2, y: 0.1, z: 0),
                count: 100
            ),
            deviceClock: .compactAssembled
        )
        pipeline.ingest(behind, receivedAt: Date()) { snapshot in
            XCTAssertEqual(snapshot.deviceTimestamp, 32_075_884)
            published.fulfill()
        }
        wait(for: [published], timeout: 5)
    }

    func testLowWristSwingCompactWalkingScoresWithCompactGate() throws {
        let assembler = AtriaWhoop4CompactIMUAssembler()
        let pipeline = AtriaR10MotionPipeline(snapshotMinimumInterval: 0.01)
        _ = pipeline.seedSynchronously(
            committedRawSteps: 0,
            lastAcceptedDeviceTimestamp: 32_075_883,
            committedGyroCadenceResearchSteps: 0
        )
        let start = Date(timeIntervalSince1970: 1_800_000_100)
        var ingested = 0
        for index in 0..<(10 * 8) {
            let packet = walkingCompactPacket(
                sampleIndex: index,
                level: 18,
                swing: 8
            )
            let receivedAt = start.addingTimeInterval(Double(index) * 0.1)
            for frame in assembler.push(packet, receivedAt: receivedAt) {
                XCTAssertEqual(frame.deviceClock, .compactAssembled)
                XCTAssertNotNil(pipeline.ingestSynchronouslyForTesting(frame))
                ingested += 1
            }
        }
        XCTAssertGreaterThanOrEqual(ingested, 6)
        XCTAssertGreaterThan(
            pipeline.gyroCadenceResearchStepsSynchronously(),
            0,
            "phone-in-hand compact walking (~20 dps) must score under the compact gate"
        )
    }

    func testAssemblerGapDoesNotStretchOnePacketIntoManySeconds() throws {
        let packet = try XCTUnwrap(AtriaWhoop4CompactIMUDecoder.decode(frame: liveStationaryFrame))
        let assembler = AtriaWhoop4CompactIMUAssembler()
        let start = Date()
        XCTAssertTrue(
            assembler.push(packet, receivedAt: start).isEmpty,
            "one 10-sample slice is 0.1 s, not a gait second"
        )
        XCTAssertTrue(
            assembler.push(packet, receivedAt: start.addingTimeInterval(0.1)).isEmpty
        )
        let afterGap = assembler.push(
            packet,
            receivedAt: start.addingTimeInterval(3.6)
        )
        XCTAssertTrue(
            afterGap.isEmpty,
            "a dropped IMU interval must not upsample one compact packet across the hole"
        )
    }

    func testPacedWalkingCompactPacketsScoreGyroCadenceSteps() throws {
        let assembler = AtriaWhoop4CompactIMUAssembler()
        let pipeline = AtriaR10MotionPipeline(snapshotMinimumInterval: 0.01)
        _ = pipeline.seedSynchronously(
            committedRawSteps: 0,
            lastAcceptedDeviceTimestamp: 32_075_883,
            committedGyroCadenceResearchSteps: 0
        )
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var ingested = 0
        for index in 0..<(10 * 16) {
            let packet = walkingCompactPacket(sampleIndex: index)
            let receivedAt = start.addingTimeInterval(Double(index) * 0.1)
            for frame in assembler.push(packet, receivedAt: receivedAt) {
                XCTAssertNotNil(pipeline.ingestSynchronouslyForTesting(frame))
                ingested += 1
            }
        }
        XCTAssertGreaterThanOrEqual(ingested, 12)
        XCTAssertGreaterThan(
            pipeline.gyroCadenceResearchStepsSynchronously(),
            0,
            "native 100 Hz compact walking must score after a stale R10 watermark"
        )
    }

    func testOneHertzCompactPacketsScorePhoneInHandWalking() {
        let assembler = AtriaWhoop4CompactIMUAssembler()
        let pipeline = AtriaR10MotionPipeline(snapshotMinimumInterval: 0.01)
        _ = pipeline.seedSynchronously(
            committedRawSteps: 0,
            lastAcceptedDeviceTimestamp: 32_075_883,
            committedGyroCadenceResearchSteps: 0
        )
        let start = Date(timeIntervalSince1970: 1_800_000_300)
        var ingested = 0
        for index in 0..<(10 * 12) {
            let packet = walkingCompactPacket(
                sampleIndex: index,
                level: 18,
                swing: 8
            )
            let receivedAt = start.addingTimeInterval(Double(index) * 0.1)
            for frame in assembler.push(packet, receivedAt: receivedAt) {
                XCTAssertNotNil(pipeline.ingestSynchronouslyForTesting(frame))
                ingested += 1
            }
        }
        XCTAssertGreaterThanOrEqual(ingested, 8)
        XCTAssertGreaterThan(
            pipeline.gyroCadenceResearchStepsSynchronously(),
            0,
            "phone-in-hand compact walking (~20 dps) must score under the compact gate"
        )
    }

    func testLockScreenSlowCompactWalkScoresGyroCadenceSteps() throws {
        let assembler = AtriaWhoop4CompactIMUAssembler()
        let pipeline = AtriaR10MotionPipeline(snapshotMinimumInterval: 0.01)
        _ = pipeline.seedSynchronously(
            committedRawSteps: 0,
            lastAcceptedDeviceTimestamp: 32_075_883,
            committedGyroCadenceResearchSteps: 0
        )
        let start = Date(timeIntervalSince1970: 1_800_000_600)
        var ingested = 0
        // 16 s of 1.23 Hz / ~72 dps matches the 2026-09-17 locked walk.
        for index in 0..<(10 * 16) {
            let packet = walkingCompactPacket(
                sampleIndex: index,
                level: 72,
                swing: 40,
                cadenceHz: 1.23
            )
            let receivedAt = start.addingTimeInterval(Double(index) * 0.1)
            for frame in assembler.push(packet, receivedAt: receivedAt) {
                XCTAssertNotNil(pipeline.ingestSynchronouslyForTesting(frame))
                ingested += 1
            }
        }
        XCTAssertGreaterThanOrEqual(ingested, 12)
        let steps = pipeline.gyroCadenceResearchStepsSynchronously()
        XCTAssertGreaterThan(
            steps,
            12,
            "a lock-screen stroll (~1.23 Hz, 72 dps) must attach gyro-cadence steps"
        )
        XCTAssertLessThan(steps, 30)
    }

    func testOneSecondInterarrivalTenSamplePacketsScoreGyroCadenceSteps() throws {
        let assembler = AtriaWhoop4CompactIMUAssembler()
        let pipeline = AtriaR10MotionPipeline(snapshotMinimumInterval: 0.01)
        _ = pipeline.seedSynchronously(
            committedRawSteps: 0,
            lastAcceptedDeviceTimestamp: 32_075_883,
            committedGyroCadenceResearchSteps: 0
        )
        let start = Date(timeIntervalSince1970: 1_800_001_200)
        var ingested = 0
        for index in 0..<16 {
            let packet = walkingCompactPacket(
                sampleIndex: index,
                level: 72,
                swing: 40,
                packetPeriod: 1.0,
                cadenceHz: 1.23
            )
            let frames = assembler.push(
                packet,
                receivedAt: start.addingTimeInterval(Double(index))
            )
            for frame in frames {
                XCTAssertEqual(frame.acceleration.count, AtriaR10MotionDecoder.sampleCount)
                XCTAssertNotNil(pipeline.ingestSynchronouslyForTesting(frame))
                ingested += 1
            }
        }
        XCTAssertGreaterThanOrEqual(
            ingested,
            12,
            "1 Hz 10-sample compact packets must emit a scored second each, not wait for ten"
        )
        let steps = pipeline.gyroCadenceResearchStepsSynchronously()
        XCTAssertGreaterThan(
            steps,
            8,
            "a 1 Hz compact stroll (~1.23 Hz, 72 dps) must attach gyro-cadence steps"
        )
        XCTAssertLessThan(steps, 30)
    }

    func testSparseFifteenSecondCompactPacketsUpsampleAsTenHertzSeconds() throws {
        let assembler = AtriaWhoop4CompactIMUAssembler()
        let pipeline = AtriaR10MotionPipeline(snapshotMinimumInterval: 0.01)
        _ = pipeline.seedSynchronously(
            committedRawSteps: 0,
            lastAcceptedDeviceTimestamp: 32_075_883,
            committedGyroCadenceResearchSteps: 0
        )
        let start = Date(timeIntervalSince1970: 1_800_001_800)
        var ingested = 0
        for index in 0..<12 {
            let packet = walkingCompactPacket(
                sampleIndex: index,
                level: 72,
                swing: 40,
                packetPeriod: 15.0,
                cadenceHz: 1.23
            )
            let frames = assembler.push(
                packet,
                receivedAt: start.addingTimeInterval(Double(index) * 15)
            )
            for frame in frames {
                XCTAssertEqual(frame.acceleration.count, AtriaR10MotionDecoder.sampleCount)
                XCTAssertNotNil(pipeline.ingestSynchronouslyForTesting(frame))
                ingested += 1
            }
        }
        XCTAssertGreaterThanOrEqual(
            ingested,
            8,
            "15 s holes between 10-sample compact packets must still score as 10 Hz seconds"
        )
        XCTAssertGreaterThan(
            pipeline.gyroCadenceResearchStepsSynchronously(),
            4
        )
    }

    func testCoalescedLockScreenSlowWalkScoresGyroCadenceSteps() throws {
        let assembler = AtriaWhoop4CompactIMUAssembler()
        let pipeline = AtriaR10MotionPipeline(snapshotMinimumInterval: 0.01)
        _ = pipeline.seedSynchronously(
            committedRawSteps: 0,
            lastAcceptedDeviceTimestamp: 32_075_883,
            committedGyroCadenceResearchSteps: 0
        )
        let start = Date(timeIntervalSince1970: 1_800_000_900)
        var ingested = 0
        for second in 0..<16 {
            let receivedAt = start.addingTimeInterval(Double(second))
            for packetIndex in 0..<10 {
                let packet = walkingCompactPacket(
                    sampleIndex: second * 10 + packetIndex,
                    level: 72,
                    swing: 40,
                    cadenceHz: 1.23
                )
                for frame in assembler.push(packet, receivedAt: receivedAt) {
                    XCTAssertNotNil(pipeline.ingestSynchronouslyForTesting(frame))
                    ingested += 1
                }
            }
        }
        XCTAssertGreaterThanOrEqual(ingested, 1)
        XCTAssertGreaterThan(
            pipeline.gyroCadenceResearchStepsSynchronously(),
            12,
            "BLE-coalesced lock-screen walking packets must still score steps"
        )
    }

    func testEightMillisecondPacketFloodKeepsLockScreenCadenceInBand() throws {
        let assembler = AtriaWhoop4CompactIMUAssembler()
        let pipeline = AtriaR10MotionPipeline(snapshotMinimumInterval: 0.01)
        _ = pipeline.seedSynchronously(
            committedRawSteps: 0,
            lastAcceptedDeviceTimestamp: 32_075_883,
            committedGyroCadenceResearchSteps: 0
        )
        let start = Date(timeIntervalSince1970: 1_800_001_200)
        var ingested = 0
        // Device 2026-09-17 118 locked 105-step walk: 8.5 ms interarrival.
        let packets = Int((8.0 / 0.0085).rounded(.up))
        for index in 0..<packets {
            let packet = walkingCompactPacket(
                sampleIndex: index,
                level: 72,
                swing: 40,
                cadenceHz: 1.14
            )
            let receivedAt = start.addingTimeInterval(Double(index) * 0.0085)
            for frame in assembler.push(packet, receivedAt: receivedAt) {
                XCTAssertNotNil(pipeline.ingestSynchronouslyForTesting(frame))
                ingested += 1
            }
        }
        XCTAssertGreaterThanOrEqual(ingested, 6)
        XCTAssertLessThan(
            ingested,
            20,
            "an 8.5 ms packet flood must not emit ~12 gait seconds per wall second"
        )
        let steps = pipeline.gyroCadenceResearchStepsSynchronously()
        XCTAssertGreaterThan(
            steps,
            4,
            "a lock-screen 1.14 Hz stroll must stay in band when bursts are rate-limited"
        )
        XCTAssertLessThan(steps, 20)
    }

    private func walkingCompactPacket(sampleIndex: Int,
                                      level: Double = 90.0,
                                      swing: Double = 45.0,
                                      packetPeriod: TimeInterval = 0.1,
                                      cadenceHz: Double = 1.75) -> AtriaWhoop4CompactIMUDecoder.Packet {
        var acceleration: [AtriaR10MotionFrame.Vector3] = []
        var rotation: [AtriaR10MotionFrame.Vector3] = []
        acceleration.reserveCapacity(10)
        rotation.reserveCapacity(10)
        let samplePeriod = packetPeriod / 10.0
        for offset in 0..<10 {
            let t = Double(sampleIndex) * packetPeriod + Double(offset) * samplePeriod
            let gyro = max(0, level + swing * sin(2 * .pi * cadenceHz * t))
            // Phone-in-hand walking still has vertical gait bounce. A
            // perfectly still 1 g vector is holding the phone at a desk.
            let bounce = 0.28 * sin(2 * .pi * cadenceHz * t)
            acceleration.append(.init(x: 0, y: bounce * 0.12, z: 1 + bounce))
            rotation.append(.init(x: gyro, y: 0, z: 0))
        }
        return AtriaWhoop4CompactIMUDecoder.Packet(
            deviceTimestamp: 31_561_474,
            acceleration: acceleration,
            rotationRate: rotation
        )
    }

    func testHeuristicResearchPeaksStillDoNotBecomeUserFacingSteps() {
        XCTAssertFalse(AtriaStrapStepResearch.validatedDecoderAvailable)
    }

    func testLiveDiagnosticsPersistNativePacketRotation() {
        AtriaCompactIMULiveDiagnostics.resetDiagnosticsForTests()
        AtriaCompactIMULiveDiagnostics.note(
            rotationRate: [AtriaR10MotionFrame.Vector3(x: 18, y: 0, z: 0)],
            now: Date(timeIntervalSince1970: 1_800_000_000),
            force: true
        )
        let defaults = UserDefaults.standard
        XCTAssertEqual(defaults.double(forKey: AtriaCompactIMULiveDiagnostics.meanKey), 18, accuracy: 0.01)
        XCTAssertEqual(defaults.double(forKey: AtriaCompactIMULiveDiagnostics.maxKey), 18, accuracy: 0.01)
        XCTAssertEqual(defaults.double(forKey: AtriaCompactIMULiveDiagnostics.peak60Key), 18, accuracy: 0.01)
        XCTAssertEqual(defaults.integer(forKey: AtriaCompactIMULiveDiagnostics.samplesKey), 1)
    }

    func testCompactGyroSecondDiagnosticsSeparateSkipFromScore() {
        AtriaCompactIMULiveDiagnostics.resetDiagnosticsForTests()
        let now = Date(timeIntervalSince1970: 1_800_000_200)
        AtriaCompactIMULiveDiagnostics.noteCompactGyroSecond(
            skippedSitting: true,
            meanDps: 1.2,
            now: now
        )
        AtriaCompactIMULiveDiagnostics.noteCompactGyroSecond(
            skippedSitting: false,
            meanDps: 86,
            now: now.addingTimeInterval(1)
        )
        let defaults = UserDefaults.standard
        XCTAssertFalse(defaults.bool(forKey: AtriaCompactIMULiveDiagnostics.lastSecondSkippedKey))
        XCTAssertEqual(
            defaults.double(forKey: AtriaCompactIMULiveDiagnostics.lastScoredMeanKey),
            86,
            accuracy: 0.01
        )
        XCTAssertEqual(defaults.integer(forKey: AtriaCompactIMULiveDiagnostics.skippedSittingCountKey), 1)
        XCTAssertEqual(defaults.integer(forKey: AtriaCompactIMULiveDiagnostics.scoredSecondsCountKey), 1)
        XCTAssertEqual(
            AtriaCompactIMULiveDiagnostics.lastAssembledSecondAt()?.timeIntervalSince1970,
            now.addingTimeInterval(1).timeIntervalSince1970
        )
    }

    func testNativePacketRotationDoesNotCountAsAssembledSecond() {
        AtriaCompactIMULiveDiagnostics.resetDiagnosticsForTests()
        AtriaCompactIMULiveDiagnostics.note(
            rotationRate: [AtriaR10MotionFrame.Vector3(x: 18, y: 0, z: 0)],
            now: Date(timeIntervalSince1970: 1_800_000_000),
            force: true
        )
        XCTAssertNil(
            AtriaCompactIMULiveDiagnostics.lastAssembledSecondAt(),
            "native 0x33 rotation must not keep the assembled-second clock fresh"
        )
        XCTAssertGreaterThan(
            UserDefaults.standard.double(forKey: AtriaCompactIMULiveDiagnostics.atKey),
            0
        )
    }

    func testFreshSittingUsesRecentLowRotation() {
        AtriaCompactIMULiveDiagnostics.resetDiagnosticsForTests()
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        AtriaCompactIMULiveDiagnostics.note(
            rotationRate: [AtriaR10MotionFrame.Vector3(x: 0.5, y: 0, z: 0)],
            now: now,
            force: true
        )
        XCTAssertTrue(AtriaCompactIMULiveDiagnostics.isFreshSitting(now: now))
        XCTAssertFalse(AtriaCompactIMULiveDiagnostics.isFreshSitting(
            now: now.addingTimeInterval(30)
        ))
        AtriaCompactIMULiveDiagnostics.note(
            rotationRate: [AtriaR10MotionFrame.Vector3(x: 18, y: 0, z: 0)],
            now: now.addingTimeInterval(1),
            force: true
        )
        XCTAssertFalse(AtriaCompactIMULiveDiagnostics.isFreshSitting(
            now: now.addingTimeInterval(1)
        ))
        XCTAssertTrue(AtriaCompactIMULiveDiagnostics.isSafeForOneChunkRetention(
            now: now.addingTimeInterval(1)
        ), "desk-level 18 dps must not block one-chunk retention")
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: AtriaCompactIMULiveDiagnostics.peak60Key),
            18,
            accuracy: 0.01
        )
        AtriaCompactIMULiveDiagnostics.note(
            rotationRate: [AtriaR10MotionFrame.Vector3(x: 120, y: 0, z: 0)],
            now: now.addingTimeInterval(2),
            force: true
        )
        XCTAssertFalse(AtriaCompactIMULiveDiagnostics.isSafeForOneChunkRetention(
            now: now.addingTimeInterval(2)
        ), "a walk-level mean must keep archive I/O off the radio")
        XCTAssertEqual(
            AtriaCompactIMULiveDiagnostics.sittingIdleChunkByteCap(
                now: now.addingTimeInterval(2)
            ),
            AtriaCompactIMULiveDiagnostics.sittingIdleSmallChunkBytes
        )
        AtriaCompactIMULiveDiagnostics.resetDiagnosticsForTests()
        AtriaCompactIMULiveDiagnostics.note(
            rotationRate: [AtriaR10MotionFrame.Vector3(x: 0.6, y: 0, z: 0)],
            now: now,
            force: true
        )
        XCTAssertEqual(
            AtriaCompactIMULiveDiagnostics.sittingIdleChunkByteCap(now: now),
            AtriaCompactIMULiveDiagnostics.sittingIdleLargeChunkBytes
        )
        XCTAssertTrue(
            AtriaCompactIMULiveDiagnostics.shouldUseSittingIdleRetentionLease(now: now)
        )
        AtriaCompactIMULiveDiagnostics.note(
            rotationRate: [AtriaR10MotionFrame.Vector3(x: 18, y: 0, z: 0)],
            now: now.addingTimeInterval(1),
            force: true
        )
        XCTAssertEqual(
            AtriaCompactIMULiveDiagnostics.sittingIdleChunkByteCap(
                now: now.addingTimeInterval(1)
            ),
            AtriaCompactIMULiveDiagnostics.sittingIdleLargeChunkBytes,
            "typing may retire isolated 33 MB once ≤8 MB isolated shards are gone"
        )
        XCTAssertTrue(
            AtriaCompactIMULiveDiagnostics.shouldUseSittingIdleRetentionLease(
                now: now.addingTimeInterval(1)
            )
        )
    }

    func testLiveCompactIMUSecondsRecordRotationDiagnostics() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let bleURL = testsURL.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBLEManager.swift")
        guard FileManager.default.fileExists(atPath: bleURL.path) else { return }
        let ble = try String(contentsOf: bleURL, encoding: .utf8)
        XCTAssertTrue(ble.contains(
            "AtriaCompactIMULiveDiagnostics.note(rotationRate: packet.rotationRate)"
        ))
    }

    func testFreshSittingDoesNotAdvanceCompactGyroCadence() throws {
        let sitting = [1.2, 1.6, 1.4, 1.8, 2.1]
        let stillAccel = [0.98, 1.01, 0.99, 1.02, 0.97, 1.00]
        let walkingAccel = [0.72, 1.38, 0.71, 1.41, 0.74, 1.36]
        XCTAssertTrue(
            AtriaR10MotionPipeline.shouldSkipSittingCompactGyroCadence(
                deviceClock: .compactAssembled,
                rotationMagnitudes: sitting,
                isFreshSitting: false
            ),
            "a sitting compact second must not pad a 4 s gait window"
        )
        XCTAssertTrue(
            AtriaR10MotionPipeline.shouldSkipSittingCompactGyroCadence(
                deviceClock: .compactAssembled,
                rotationMagnitudes: [8, 9, 7, 10, 8],
                isFreshSitting: true
            ),
            "typing flicks below the 12 dps walk gate stay suppressed while sitting"
        )
        XCTAssertTrue(
            AtriaR10MotionPipeline.shouldSkipSittingCompactGyroCadence(
                deviceClock: .compactAssembled,
                rotationMagnitudes: [18, 24, 21, 19, 22],
                accelerationMagnitudes: stillAccel,
                isFreshSitting: false
            ),
            "holding the phone at a desk is still even when wrist gyro clears 12 dps"
        )
        XCTAssertFalse(
            AtriaR10MotionPipeline.shouldSkipSittingCompactGyroCadence(
                deviceClock: .compactAssembled,
                rotationMagnitudes: [80, 96, 88, 110, 86],
                accelerationMagnitudes: stillAccel,
                isFreshSitting: false
            ),
            "a walk-level wrist swing must score even when compact accel looks 1 g-still"
        )
        XCTAssertFalse(
            AtriaR10MotionPipeline.shouldSkipSittingCompactGyroCadence(
                deviceClock: .compactAssembled,
                rotationMagnitudes: [48, 52, 44, 56, 50],
                accelerationMagnitudes: stillAccel,
                isFreshSitting: false
            ),
            "a slower walk in the 40–80 dps band must still score under still-looking compact gravity"
        )
        XCTAssertFalse(
            AtriaR10MotionPipeline.shouldSkipSittingCompactGyroCadence(
                deviceClock: .compactAssembled,
                rotationMagnitudes: [18, 24, 21, 19, 22],
                accelerationMagnitudes: walkingAccel,
                isFreshSitting: true
            ),
            "a walk burst with gait bounce must still score"
        )
        XCTAssertFalse(
            AtriaR10MotionPipeline.shouldSkipSittingCompactGyroCadence(
                deviceClock: .whoopR10,
                rotationMagnitudes: sitting,
                accelerationMagnitudes: stillAccel,
                isFreshSitting: true
            )
        )
    }

    func testIsolatedNotifySurvivesStream5LeftoverWithoutPromotingR10() {
        // Physical inrange-38 lastNotifyCallbackHex. A stalled stream-5
        // header (declared length 2000) keeps the reassembler from emitting
        // the next isolated 152-byte 0x33 GATT notify.
        var stalled: [UInt8] = [0xAA, 0xD0, 0x07]
        stalled.append(crc8([0xD0, 0x07]))
        stalled.append(contentsOf: [0x32, 0x00, 0x01, 0x02, 0x03, 0x04])
        let reassembler = AtriaWhoop4FrameReassembler()
        XCTAssertTrue(reassembler.feed(Data(stalled), source: "stream5").isEmpty)

        let reassembled = reassembler.feed(liveStationaryFrame, source: "stream5")
        XCTAssertFalse(
            reassembled.contains(liveStationaryFrame),
            "a stalled stream-5 header must not swallow the isolated 0x33 notify"
        )
        XCTAssertTrue(reassembled.isEmpty)

        let admitted = AtriaWhoop4CompactIMUDecoder.completeFrames(
            isolatedNotify: liveStationaryFrame,
            reassembled: reassembled
        )
        XCTAssertEqual(admitted, [liveStationaryFrame])
        XCTAssertNotNil(AtriaWhoop4CompactIMUDecoder.decode(frame: liveStationaryFrame))

        var r10 = [UInt8](repeating: 0, count: 1_288)
        r10[0] = 0x2B
        r10[1] = 0x0A
        let r10Frame = encodeFrame(r10)
        XCTAssertEqual(
            AtriaWhoop4CompactIMUDecoder.completeFrames(
                isolatedNotify: r10Frame,
                reassembled: [r10Frame]
            ),
            [r10Frame],
            "R10 type-2B must not be relabeled as compact IMU"
        )
        XCTAssertNil(
            AtriaStrapCalibrationArchive.nativeCompactIMUDurableFrame(from: r10Frame)
        )
    }

    func testBuild240Stream5Type2BNotifyIsNotNestedHarvard33() {
        // Physical lastNotifyCallbackHex from evidence/2026-09-20-imu-240-store
        // (244 B, stream-5, lastPacketKind realtime_raw_r10_r11). Gyro/accel
        // samples in this body are not compact IMU.
        let live2B = Data(hex:
            "1701fb00e000c700b300a10091008d009500a200b500cc00e400f000" +
            "f800fc00fb00ec00d400ca00bb00a00089008b009b00b000c900d000" +
            "c30088003800e0fff1ff3d00410009000b00510062004c0026000b00" +
            "f7ffeffff7ff0e0036005e0056002d00f8ffc4ff84ff68ff5aff72ff" +
            "7bff91ff89009300b300c700b5008d005a001c00fbffd7ffa7ff71ff" +
            "44ff2dff3fff73ff8aff9cffb8ffccffc9ffc7ffc4ff9cff7aff45ff" +
            "f9fec3feb4fecefee9fe1dff6effacffefff1c0028001a00faffcdff" +
            "8dff59ff42ff39ff3bff4fff55ff3dff26ff26ff3fff67ff99ffcfff" +
            "0300260036002f001000e8ffbaff9dff9affaeff"
        )
        XCTAssertEqual(live2B.count, 244)
        XCTAssertNotEqual(live2B.first, 0xAA)
        XCTAssertFalse(live2B.contains(0x33),
                       "no inner type byte 0x33 in the 240 2B notify")
        XCTAssertNil(AtriaWhoop4CompactIMUDecoder.decode(frame: live2B))
        XCTAssertNil(AtriaWhoop4CompactIMUDecoder.decode(payload: [UInt8](live2B)))
        XCTAssertNil(
            AtriaStrapCalibrationArchive.nativeCompactIMUDurableFrame(from: live2B)
        )
        XCTAssertEqual(
            AtriaWhoop4CompactIMUDecoder.completeFrames(
                isolatedNotify: live2B,
                reassembled: []
            ),
            [],
            "must not admit R10 2B as isolated compact 0x33"
        )
        XCTAssertEqual(
            live2B.prefix(8),
            Data(hex: "1701fb00e000c700"),
            "offset 0 is R10 fragment, not AA 94 00 B5 33"
        )
        XCTAssertEqual(liveStationaryFrame[4], 0x33)
        XCTAssertNotEqual(live2B[4], 0x33)
        XCTAssertEqual(live2B[4], 0xE0, "store 240 notify offset 4 is E0, not type 33")
        XCTAssertTrue(
            AtriaWhoop4CompactIMUDecoder.nestedCompactIMUFrames(in: live2B).isEmpty
        )
    }

    func testSplicedInrange38Inside1924Type2BIsExtractedAndPersisted() throws {
        var payload = [UInt8](repeating: 0x11, count: 1_924)
        payload[0] = 0x2B
        payload[1] = 0x0A
        let spliceAt = 480
        payload.replaceSubrange(
            spliceAt..<(spliceAt + liveStationaryFrame.count),
            with: [UInt8](liveStationaryFrame)
        )
        let outer = encodeFrame(payload)
        XCTAssertEqual(payload.count, 1_924)
        XCTAssertEqual(
            AtriaWhoop4CompactIMUDecoder.nestedCompactIMUFrames(in: Data(payload)),
            [liveStationaryFrame]
        )
        let admitted = AtriaWhoop4CompactIMUDecoder.completeFrames(
            isolatedNotify: Data(payload.prefix(244)),
            reassembled: [outer]
        )
        XCTAssertTrue(admitted.contains(liveStationaryFrame))
        XCTAssertTrue(admitted.contains(outer))
        XCTAssertNotNil(
            AtriaStrapCalibrationArchive.nativeCompactIMUDurableFrame(
                from: liveStationaryFrame
            )
        )
        XCTAssertNil(
            AtriaStrapCalibrationArchive.nativeCompactIMUDurableFrame(from: outer),
            "outer 2B Harvard must not be labeled IMU"
        )

        var checksumException = liveStationaryFrame
        let last = checksumException.index(before: checksumException.endIndex)
        checksumException[last] ^= 0xff
        payload.replaceSubrange(
            spliceAt..<(spliceAt + checksumException.count),
            with: [UInt8](checksumException)
        )
        XCTAssertEqual(
            AtriaWhoop4CompactIMUDecoder.nestedCompactIMUFrames(in: Data(payload)),
            [checksumException]
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-nested-33-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = AtriaStrapCalibrationArchive(
            directoryURL: directory,
            flushInterval: 60,
            maximumBufferedBytes: 1_024 * 1_024
        )
        for frame in AtriaWhoop4CompactIMUDecoder.completeFrames(
            isolatedNotify: Data(),
            reassembled: [Data(payload)]
        ) {
            archive.recordNativeCompactIMUFrame(
                frame,
                source: "stream5",
                receivedAt: Date(timeIntervalSince1970: 1_750_000_000)
            )
        }
        archive.flushSynchronouslyForTesting()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let csv = try XCTUnwrap(files.first { $0.pathExtension == "csv" })
        let text = try String(contentsOf: csv, encoding: .utf8)
        XCTAssertTrue(text.contains("checksum_exception"), text)
        XCTAssertTrue(text.contains(",33,"), text)
        XCTAssertFalse(text.contains(",2b,"), text)
        XCTAssertFalse(text.contains(",2B,"), text)
    }

    func testPure239240Type2BHexIsNotAdmittedAsCompact33() {
        // Physical 240 store notify (244 B). Gym/store leftover is type 2B
        // samples, not Harvard 0x33. Offset 4 is E0, not 33.
        let store240 = Data(hex:
            "1701fb00e000c700b300a10091008d009500a200b500cc00e400f000" +
            "f800fc00fb00ec00d400ca00bb00a00089008b009b00b000c900d000" +
            "c30088003800e0fff1ff3d00410009000b00510062004c0026000b00" +
            "f7ffeffff7ff0e0036005e0056002d00f8ffc4ff84ff68ff5aff72ff" +
            "7bff91ff89009300b300c700b5008d005a001c00fbffd7ffa7ff71ff" +
            "44ff2dff3fff73ff8aff9cffb8ffccffc9ffc7ffc4ff9cff7aff45ff" +
            "f9fec3feb4fecefee9fe1dff6effacffefff1c0028001a00faffcdff" +
            "8dff59ff42ff39ff3bff4fff55ff3dff26ff26ff3fff67ff99ffcfff" +
            "0300260036002f001000e8ffbaff9dff9affaeff"
        )
        XCTAssertEqual(store240.count, 244)
        XCTAssertEqual(store240[4], 0xE0)
        var like1924 = Data(count: 1_924)
        like1924[0] = 0x2B
        like1924[1] = 0x0A
        let tile = [UInt8](store240)
        var offset = 2
        while offset + tile.count <= like1924.count {
            like1924.replaceSubrange(offset..<(offset + tile.count), with: tile)
            offset += tile.count
        }
        like1924[2] = 0x00
        like1924[3] = 0x00
        like1924[4] = 0x00
        XCTAssertEqual(like1924[4], 0x00, "pull-style leftover at offset 4 is 00, not 33")
        XCTAssertNil(
            like1924.range(
                of: Data(AtriaWhoop4CompactIMUDecoder.harvardCompactIMUSync)
            )
        )
        XCTAssertTrue(
            AtriaWhoop4CompactIMUDecoder.nestedCompactIMUFrames(in: like1924).isEmpty
        )
        XCTAssertEqual(
            AtriaWhoop4CompactIMUDecoder.completeFrames(
                isolatedNotify: store240,
                reassembled: [like1924]
            ),
            [like1924]
        )
        XCTAssertNil(
            AtriaStrapCalibrationArchive.nativeCompactIMUDurableFrame(from: store240)
        )
        XCTAssertNil(
            AtriaWhoop4CompactIMUDecoder.diagnosticOversizedLastPacketHex(
                payloadLength: 244,
                frame: store240,
                type: 0x2B
            )
        )
        let oversized = AtriaWhoop4CompactIMUDecoder.diagnosticOversizedLastPacketHex(
            payloadLength: 1_924,
            frame: like1924,
            type: 0x2B
        )
        XCTAssertEqual(oversized?.count, 1_924 * 2)
        XCTAssertNil(
            AtriaWhoop4CompactIMUDecoder.diagnosticOversizedLastPacketHex(
                payloadLength: 1_924,
                frame: liveStationaryFrame,
                type: 0x33
            ),
            "oversized dump must not take the IMU label"
        )
    }

    func testHistoricalInner0x33IsNotA0x2fReplayRow() {
        let inner = Array(liveStationaryFrame.dropFirst(4).prefix(144))
        XCTAssertEqual(inner.first, 0x33)
        let decoded = AtriaWhoop4HistoricalRecordDecoder.decode(inner)
        guard case .failure(let failure) = decoded else {
            return XCTFail("0x33 must not decode as historical 0x2f")
        }
        XCTAssertEqual(failure.reason, .unexpectedPacketType(0x33))
    }

    func testProvenanceTaggedImportStoresLastNotify33AndRejectsR10() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-hist-33-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = AtriaStrapCalibrationArchive(
            directoryURL: directory,
            flushInterval: 60,
            maximumBufferedBytes: 1_024 * 1_024
        )
        XCTAssertTrue(
            archive.importProvenanceTaggedCompactIMUFrame(
                liveStationaryFrame,
                provenance: .lastNotifySnapshot,
                capturedAt: Date(timeIntervalSince1970: 1_789_000_000)
            )
        )
        let leftoverR10 = Data(hex:
            "aa8407f72b0a2911789501fb73e901602b805440013e00000000000000000000"
        )
        XCTAssertFalse(
            archive.importProvenanceTaggedCompactIMUFrame(
                leftoverR10,
                provenance: .lastNotifySnapshot,
                capturedAt: Date(timeIntervalSince1970: 1_789_000_000)
            ),
            "leftover R10 must stay leftover R10"
        )
        let compactHex = liveStationaryFrame.map { String(format: "%02x", $0) }.joined()
        let jsonl = directory.appendingPathComponent("import.jsonl")
        try """
        {"hex":"\(compactHex)","provenance":"hist_lastNotify"}
        {"hex":"aa8407f72b0a2911789501fb","provenance":"hist_lastNotify"}
        {"hex":"\(compactHex)","provenance":"stream5"}
        """.write(to: jsonl, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            archive.importArchivedCompactIMUJSONL(from: jsonl),
            1,
            "JSONL imports one unique lastNotify 33 and skips 2B / live labels"
        )
        archive.flushSynchronouslyForTesting()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let csvs = files.filter { $0.pathExtension == "csv" }
        XCTAssertFalse(csvs.isEmpty)
        let text = try csvs.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(text.contains("hist_lastNotify"), text)
        XCTAssertTrue(text.contains(",33,"), text)
        XCTAssertFalse(text.contains("stream5"), text)
        XCTAssertFalse(text.contains(",2b,"), text)
        XCTAssertEqual(text.split(whereSeparator: \.isNewline).filter { $0.contains(",33,") }.count, 2)
    }

    func testImportLaunchFlagIsRequiredAndConsumedOnce() throws {
        let documents = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-hist-docs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: documents) }
        let compactHex = liveStationaryFrame.map { String(format: "%02x", $0) }.joined()
        let jsonl = documents.appendingPathComponent(
            AtriaStrapCalibrationArchive.importFilename
        )
        try "{\"hex\":\"\(compactHex)\",\"provenance\":\"hist_lastNotify\"}\n"
            .write(to: jsonl, atomically: true, encoding: .utf8)
        let archive = AtriaStrapCalibrationArchive(
            directoryURL: documents.appendingPathComponent("archive", isDirectory: true),
            flushInterval: 60,
            maximumBufferedBytes: 1_024 * 1_024
        )
        let suite = "atria-hist-import-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(
            archive.importArchivedCompactIMUFileIfRequested(
                arguments: [],
                documentsURL: documents,
                defaults: defaults
            ),
            0
        )
        XCTAssertEqual(
            archive.importArchivedCompactIMUFileIfRequested(
                arguments: [AtriaStrapCalibrationArchive.importArchivedArgument],
                documentsURL: documents,
                defaults: defaults
            ),
            1
        )
        XCTAssertEqual(
            archive.importArchivedCompactIMUFileIfRequested(
                arguments: [AtriaStrapCalibrationArchive.importArchivedArgument],
                documentsURL: documents,
                defaults: defaults
            ),
            0,
            "second launch must not duplicate last-value rows"
        )
    }

    func testMaterializeWritesHistLastNotifyScalarRowsAndSkipsR10() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-samples-33-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = AtriaStrapCalibrationArchive(
            directoryURL: directory,
            flushInterval: 60,
            maximumBufferedBytes: 1_024 * 1_024
        )
        XCTAssertTrue(
            archive.importProvenanceTaggedCompactIMUFrame(
                liveStationaryFrame,
                provenance: .lastNotifySnapshot,
                capturedAt: Date(timeIntervalSince1970: 1_789_000_000)
            )
        )
        archive.flushSynchronouslyForTesting()
        try "2,1789000000000,stream5,2b,0a,aa8407f72b0a\n"
            .write(
                to: directory.appendingPathComponent("strap-imu-r10.csv"),
                atomically: true,
                encoding: .utf8
            )
        let count = archive.materializeDecodedCompactIMUSamplesFromArchive()
        XCTAssertEqual(count, 10)
        let samples = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("strap-imu-samples-") }
        )
        let text = try String(contentsOf: samples, encoding: .utf8)
        XCTAssertTrue(text.contains("hist_lastNotify"), text)
        XCTAssertTrue(text.contains(",31558765,0,"), text)
        XCTAssertFalse(text.contains("stream5"), text)
        XCTAssertFalse(text.contains("100hz"), text)
        XCTAssertFalse(text.contains("gait"), text)
        XCTAssertEqual(text.split(whereSeparator: \.isNewline).filter { $0.contains("hist_lastNotify") }.count, 10)
        let suite = "atria-samples-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(
            archive.materializeDecodedCompactIMUSamplesIfRequested(arguments: [], defaults: defaults),
            0
        )
        XCTAssertEqual(
            archive.materializeDecodedCompactIMUSamplesIfRequested(
                arguments: [AtriaStrapCalibrationArchive.materializeSamplesArgument],
                defaults: defaults
            ),
            10
        )
        XCTAssertEqual(
            archive.materializeDecodedCompactIMUSamplesIfRequested(
                arguments: [AtriaStrapCalibrationArchive.materializeSamplesArgument],
                defaults: defaults
            ),
            0
        )
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
