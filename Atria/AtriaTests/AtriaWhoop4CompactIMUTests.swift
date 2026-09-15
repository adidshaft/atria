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
        for i in 0..<20 {
            let frames = assembler.push(
                packet,
                receivedAt: start.addingTimeInterval(Double(i) * 0.1)
            )
            timestamps.append(contentsOf: frames.map(\.deviceTimestamp))
        }
        XCTAssertEqual(timestamps.count, 2)
        XCTAssertEqual(timestamps[1], timestamps[0] &+ 1)
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
            let packet = walkingCompactPacket(sampleIndex: index, level: 18, swing: 8)
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
            assembler.push(packet, receivedAt: start).isEmpty
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
        for index in 0..<(10 * 8) {
            let packet = walkingCompactPacket(sampleIndex: index)
            let receivedAt = start.addingTimeInterval(Double(index) * 0.1)
            for frame in assembler.push(packet, receivedAt: receivedAt) {
                XCTAssertNotNil(pipeline.ingestSynchronouslyForTesting(frame))
                ingested += 1
            }
        }
        XCTAssertGreaterThanOrEqual(ingested, 6)
        XCTAssertGreaterThan(
            pipeline.gyroCadenceResearchStepsSynchronously(),
            0,
            "wall-clock resampled compact walking must score after a stale R10 watermark"
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
        for index in 0..<12 {
            let packet = walkingCompactPacket(
                sampleIndex: index,
                level: 18,
                swing: 8,
                packetPeriod: 1.0
            )
            let receivedAt = start.addingTimeInterval(Double(index))
            for frame in assembler.push(packet, receivedAt: receivedAt) {
                XCTAssertNotNil(pipeline.ingestSynchronouslyForTesting(frame))
                ingested += 1
            }
        }
        XCTAssertGreaterThanOrEqual(ingested, 8)
        XCTAssertGreaterThan(
            pipeline.gyroCadenceResearchStepsSynchronously(),
            0,
            "one 10-sample compact packet per second must still score a 12-second walk"
        )
    }

    private func walkingCompactPacket(sampleIndex: Int,
                                      level: Double = 90.0,
                                      swing: Double = 45.0,
                                      packetPeriod: TimeInterval = 0.1) -> AtriaWhoop4CompactIMUDecoder.Packet {
        let cadenceHz = 1.75
        var acceleration: [AtriaR10MotionFrame.Vector3] = []
        var rotation: [AtriaR10MotionFrame.Vector3] = []
        acceleration.reserveCapacity(10)
        rotation.reserveCapacity(10)
        let samplePeriod = packetPeriod / 10.0
        for offset in 0..<10 {
            let t = Double(sampleIndex) * packetPeriod + Double(offset) * samplePeriod
            let gyro = max(0, level + swing * sin(2 * .pi * cadenceHz * t))
            acceleration.append(.init(x: 0, y: 0, z: 1))
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
    }

    func testLiveCompactIMUSecondsRecordRotationDiagnostics() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let ble = try String(
            contentsOf: testsURL.deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaBLEManager.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(ble.contains(
            "AtriaCompactIMULiveDiagnostics.note(rotationRate: packet.rotationRate)"
        ))
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
