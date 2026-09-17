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
